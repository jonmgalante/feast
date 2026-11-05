import Foundation
import MapKit
import Combine
import os

/// Lookup failures never describe whether the user's saved record still exists.
enum MapPlaceLookupFailure: Error, Equatable {
    case throttled, connection, service, unavailable
    var pausesBatch: Bool { self != .unavailable }
    var message: String {
        switch self {
        case .throttled: return "Apple Maps is busy. Loaded pins remain available; retry the remaining locations shortly."
        case .connection: return "Check your connection to load more pins. Your places are still saved."
        case .service: return "Some locations couldn't be loaded from Apple Maps. Your places are still saved."
        case .unavailable: return "Some saved locations aren't available from Apple Maps. Your places are still saved."
        }
    }
    static func classify(_ error: Error) -> Self {
        if let failure = error as? Self { return failure }
        let value = error as NSError
        if value.domain == MKErrorDomain {
            if value.code == MKError.Code.loadingThrottled.rawValue { return .throttled }
            if value.code == MKError.Code.serverFailure.rawValue { return .service }
            if value.code == MKError.Code.placemarkNotFound.rawValue { return .unavailable }
        }
        if value.domain == NSURLErrorDomain,
           [NSURLErrorNotConnectedToInternet, NSURLErrorNetworkConnectionLost, NSURLErrorTimedOut,
            NSURLErrorCannotConnectToHost, NSURLErrorCannotFindHost, NSURLErrorDNSLookupFailed].contains(value.code) { return .connection }
        return .service
    }
}

/// Shared by map and detail, not by AI research. Only demand-driven Apple results;
/// at most 2,048 successes, five minutes from retrieval, RAM only. Background clears
/// entries and subscribers. No coordinates, names or IDs are logged or persisted.
@MainActor final class MapPlaceLookup: ObservableObject {
    static let shared = MapPlaceLookup()
    @Published private(set) var revision = 0
    @Published private(set) var expiration = 0
    var visibleViewport: SavedMapViewport?
    private var resolvedAt: [String: TimeInterval] = [:]
    var recentlyResolvedIDs: Set<String> { Set(resolvedAt.filter { now() - $0.value < ttl }.keys) }
    func retryEvictedLocations() { resolvedAt.removeAll() }

    enum Value { case place(ApplePlaceMatch), city(SavedMapViewport) }
    struct Metrics {
        var calls = 0, cacheHits = 0, joined = 0, cancelled = 0, successes = 0
        var throttled = 0, connection = 0, service = 0, unavailable = 0
        var totalProviderSeconds: TimeInterval = 0
        var maxActive = 0
    }
    private struct Entry { let value: Value; let expires: TimeInterval; var touched: TimeInterval }
    private final class Job {
        let id = UUID(), key: String, lookup: () async throws -> Value?
        var subscribers: [UUID: CheckedContinuation<Value?, Error>] = [:]
        var task: Task<Void, Never>?
        var attempts = 0
        init(key: String, lookup: @escaping () async throws -> Value?) { self.key = key; self.lookup = lookup }
    }
    private var cache: [String: Entry] = [:]
    private var jobs: [String: Job] = [:]
    private var queue: [Job] = []
    private var active = 0
    private var concurrency: Int
    private var nextAllowed: TimeInterval = 0
    private var consecutiveFailures = 0, healthyCompletions = 0
    private var wake: Task<Void, Never>?, expiry: Task<Void, Never>?
    private let maximumConcurrent: Int, capacity: Int, ttl: TimeInterval
    private let now: () -> TimeInterval
    private let sleep: (TimeInterval) async throws -> Void
    private let emit: (String, TimeInterval, Int) -> Void
    private(set) var metrics = Metrics()
    private static let logger = Logger(subsystem: "com.jongalante.Feast", category: "SavedMapLookup")

    init(maximumConcurrent: Int = 3, capacity: Int = 2048, ttl: TimeInterval = 300,
         now: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
         sleep: @escaping (TimeInterval) async throws -> Void = { try await Task.sleep(for: .seconds(max(0, $0))) },
         emit: ((String, TimeInterval, Int) -> Void)? = nil) {
        self.maximumConcurrent = max(1, maximumConcurrent); concurrency = max(1, maximumConcurrent)
        self.capacity = max(1, capacity); self.ttl = max(0.01, ttl); self.now = now; self.sleep = sleep
        self.emit = emit ?? { outcome, seconds, active in
            Self.logger.info("outcome=\(outcome, privacy: .public) duration_ms=\(Int(seconds * 1000), privacy: .public) active=\(active, privacy: .public)")
        }
    }
    var cachedCount: Int { prune(); return cache.count }
    func cachedPlace(_ id: String) -> ApplePlaceMatch? {
        guard case let .place(match)? = cached("place:" + id, countHit: false) else { return nil }; return match
    }
    func cachedCity(_ name: String) -> SavedMapViewport? {
        guard case let .city(region)? = cached("city:" + name, countHit: false) else { return nil }; return region
    }
    func resolve(placeID: String, lookup: @escaping (String) async throws -> ApplePlaceMatch?) async throws -> ApplePlaceMatch? {
        let value = try await value(key: "place:" + placeID) {
            guard let match = try await lookup(placeID), let coordinate = match.coordinate,
                  CLLocationCoordinate2DIsValid(.init(latitude: coordinate.latitude, longitude: coordinate.longitude)) else { return nil }
            return .place(match)
        }
        guard case let .place(match)? = value else { return nil }; return match
    }
    func city(name: String, lookup: @escaping (String) async throws -> SavedMapViewport?) async throws -> SavedMapViewport? {
        let value = try await value(key: "city:" + name) {
            guard let region = try await lookup(name), region.isValid else { return nil }; return .city(region)
        }
        guard case let .city(region)? = value else { return nil }; return region
    }
    private func value(key: String, lookup: @escaping () async throws -> Value?) async throws -> Value? {
        try Task.checkCancellation()
        if let result = cached(key) { return result }
        let subscriber = UUID()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                guard !Task.isCancelled else { continuation.resume(throwing: CancellationError()); return }
                if let job = jobs[key] { metrics.joined += 1; job.subscribers[subscriber] = continuation }
                else {
                    let job = Job(key: key, lookup: lookup); job.subscribers[subscriber] = continuation
                    jobs[key] = job; queue.append(job)
                }
                pump()
            }
        } onCancel: { Task { @MainActor in self.cancel(key: key, subscriber: subscriber) } }
    }
    private func cancel(key: String, subscriber: UUID) {
        guard let job = jobs[key], let continuation = job.subscribers.removeValue(forKey: subscriber) else { return }
        metrics.cancelled += 1; continuation.resume(throwing: CancellationError())
        if job.subscribers.isEmpty {
            jobs.removeValue(forKey: key); queue.removeAll { $0 === job }; job.task?.cancel()
        }
        pump()
    }
    /// Background/lifecycle deletion leaves cooldown intact; navigation cannot bypass backoff.
    func clear() {
        expiry?.cancel(); expiry = nil; cache.removeAll(); resolvedAt.removeAll(); visibleViewport = nil; revision += 1; expiration += 1
        wake?.cancel(); wake = nil
        let abandoned = Array(jobs.values); jobs.removeAll(); queue.removeAll()
        for job in abandoned {
            for continuation in job.subscribers.values { continuation.resume(throwing: CancellationError()) }
            metrics.cancelled += job.subscribers.count; job.subscribers.removeAll(); job.task?.cancel()
        }
    }
    private func prune() {
        let previousCount = cache.count
        cache = cache.filter { $0.value.expires > now() }
        resolvedAt = resolvedAt.filter { now() - $0.value < ttl }
        if cache.count != previousCount { revision += 1; expiration += 1 }
    }
    private func cached(_ key: String, countHit: Bool = true) -> Value? {
        guard var entry = cache[key], entry.expires > now() else { return nil }
        if countHit { entry.touched = now(); cache[key] = entry }
        if countHit { metrics.cacheHits += 1 }
        return entry.value
    }
    private func store(_ value: Value, key: String) {
        prune()
        if case .place = value {
            // Requested identity stays authoritative even if Apple returns a new canonical ID.
            resolvedAt[String(key.dropFirst("place:".count))] = now()
            resolvedAt = resolvedAt.filter { now() - $0.value < ttl }
            if resolvedAt.count > capacity * 4, let oldest = resolvedAt.min(by: {$0.value < $1.value})?.key { resolvedAt.removeValue(forKey: oldest) }
        }
        func isVisible(_ value: Value) -> Bool {
            guard case let .place(match) = value, let coordinate = match.coordinate else { return false }
            return visibleViewport?.contains(coordinate) == true
        }
        if cache.count >= capacity, cache[key] == nil {
            let distant = cache.filter { !isVisible($0.value.value) }
            if distant.isEmpty && !isVisible(value) { revision += 1; return }
            let candidates = distant.isEmpty ? cache : distant
            if let oldest = candidates.min(by: {$0.value.touched < $1.value.touched})?.key { cache.removeValue(forKey: oldest) }
        }
        cache[key] = Entry(value: value, expires: now() + ttl, touched: now()); revision += 1; scheduleExpiry()
    }
    private func scheduleExpiry() {
        expiry?.cancel()
        guard let deadline = cache.values.map(\.expires).min() else { expiry = nil; return }
        let delay = max(0, deadline - now())
        expiry = Task { [weak self] in
            // Real lifecycle timer; injected provider clock is separately testable with prune().
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled, let self else { return }; self.prune(); self.scheduleExpiry()
        }
    }
    private func pump() {
        guard !queue.isEmpty else { wake?.cancel(); wake = nil; return }
        guard active < concurrency else { return }
        let delay = nextAllowed - now()
        if delay > 0 {
            guard wake == nil else { return }
            wake = Task { [weak self] in
                guard let self else { return }
                do { try await self.sleep(delay) } catch { return }
                guard !Task.isCancelled else { return }; self.wake = nil; self.pump()
            }; return
        }
        while active < concurrency, !queue.isEmpty {
            let job = queue.removeFirst()
            guard jobs[job.key] === job, !job.subscribers.isEmpty else { continue }
            active += 1; metrics.maxActive = max(metrics.maxActive, active)
            job.task = Task { [weak self] in await self?.run(job) }
        }
    }
    private func run(_ job: Job) async {
        guard jobs[job.key] === job, !job.subscribers.isEmpty, !Task.isCancelled else { active -= 1; pump(); return }
        let start = now(); metrics.calls += 1; job.attempts += 1
        let result: Result<Value?, Error>
        do { result = .success(try await job.lookup()) } catch { result = .failure(error) }
        let elapsed = max(0, now() - start); metrics.totalProviderSeconds += elapsed
        active -= 1
        guard jobs[job.key] === job, !job.subscribers.isEmpty else { emit("cancelled", elapsed, active); pump(); return }
        var outcome = "success"
        switch result {
        case .success(let value):
            if let value { store(value, key: job.key); metrics.successes += 1 }
            else { metrics.unavailable += 1; outcome = "unavailable" }
            healthyCompletions += 1
            if healthyCompletions >= 6 { concurrency = min(maximumConcurrent, concurrency + 1); consecutiveFailures = 0; healthyCompletions = 0 }
        case .failure(let error):
            if error is CancellationError { outcome = "cancelled" }
            else {
                let failure = MapPlaceLookupFailure.classify(error); outcome = String(describing: failure)
                switch failure { case .throttled: metrics.throttled += 1; case .connection: metrics.connection += 1; case .service: metrics.service += 1; case .unavailable: metrics.unavailable += 1 }
                if failure.pausesBatch {
                    healthyCompletions = 0; consecutiveFailures = min(consecutiveFailures + 1, 5)
                    concurrency = 1
                    let delay = min(60, (failure == .throttled ? 5.0 : 1.0) * pow(2, Double(consecutiveFailures - 1)))
                    nextAllowed = max(nextAllowed, now() + delay)
                    if job.attempts < 3 && failure != .connection {
                        // Retry only this failed request, with the shared cooldown.
                        // Other callers cannot defeat backoff by navigating or retrying.
                        queue.insert(job, at: 0); emit(outcome, elapsed, active); pump(); return
                    }
                    // Do not send every queued location into an outage. Caller can retry;
                    // outstanding successes are retained and there is no immediate retry storm.
                    let waiting = queue; queue.removeAll()
                    for queued in waiting {
                        jobs.removeValue(forKey: queued.key)
                        for subscriber in queued.subscribers.values { subscriber.resume(throwing: failure) }
                        queued.subscribers.removeAll()
                    }
                }
            }
        }
        jobs.removeValue(forKey: job.key)
        emit(outcome, elapsed, active)
        for continuation in job.subscribers.values { continuation.resume(with: result) }
        job.subscribers.removeAll(); pump()
    }
}

/// Bridges MapKit's callback without leaving an obsolete request running or resuming
/// a continuation twice. The injectable adapter supports offline cancellation tests.
@MainActor final class AppleMapItemOperation {
    typealias Completion = @MainActor @Sendable (MKMapItem?, Error?) -> Void
    private let start: (@escaping Completion) -> Void
    private let cancelRequest: () -> Void
    private var continuation: CheckedContinuation<MKMapItem, Error>?
    private var cancelled = false
    private var timeout: Task<Void, Never>?
    private let timeoutDuration: Duration
    init(request: MKMapItemRequest) {
        timeoutDuration = .seconds(20)
        start = { completion in request.getMapItem(completionHandler: completion) }
        cancelRequest = { request.cancel() }
    }
    init(timeoutDuration: Duration = .seconds(20), start: @escaping (@escaping Completion) -> Void, cancel: @escaping () -> Void) {
        self.timeoutDuration = timeoutDuration
        self.start = start; self.cancelRequest = cancel
    }
    func value() async throws -> MKMapItem {
        try await withTaskCancellationHandler {
            try Task.checkCancellation()
            return try await withCheckedThrowingContinuation { continuation in
                self.continuation = continuation
                if cancelled || Task.isCancelled { cancel(); return }
                timeout = Task { [weak self] in
                    guard let self else { return }
                    try? await Task.sleep(for: timeoutDuration)
                    guard !Task.isCancelled, self.continuation != nil else { return }
                    finish(.failure(NSError(domain: NSURLErrorDomain, code: NSURLErrorTimedOut)))
                    cancelRequest()
                }
                start { [self] item, error in
                    if let item { finish(.success(item)) }
                    else { finish(.failure(error ?? MapPlaceLookupFailure.service)) }
                }
            }
        } onCancel: {
            Task { @MainActor in self.cancel() }
        }
    }
    private func cancel() {
        guard !cancelled else { return }
        cancelled = true
        cancelRequest()
        finish(.failure(CancellationError()))
    }
    private func finish(_ result: Result<MKMapItem, Error>) {
        guard let continuation else { return }
        self.continuation = nil; timeout?.cancel(); timeout = nil
        continuation.resume(with: cancelled ? .failure(CancellationError()) : result)
    }
}

@MainActor final class AppleMapSearchOperation {
    private let search: MKLocalSearch
    private var continuation: CheckedContinuation<MKLocalSearch.Response, Error>?
    private var timeout: Task<Void, Never>?
    private var cancelled = false
    init(search: MKLocalSearch) { self.search = search }
    func value() async throws -> MKLocalSearch.Response {
        try await withTaskCancellationHandler {
            try Task.checkCancellation()
            return try await withCheckedThrowingContinuation { continuation in
                self.continuation = continuation
                if cancelled || Task.isCancelled { cancel(); return }
                timeout = Task { [weak self] in
                    try? await Task.sleep(for: .seconds(20))
                    guard !Task.isCancelled, let self, self.continuation != nil else { return }
                    self.finish(.failure(NSError(domain: NSURLErrorDomain, code: NSURLErrorTimedOut)))
                    self.search.cancel()
                }
                search.start { response, error in
                    if let response { self.finish(.success(response)) }
                    else { self.finish(.failure(error ?? MapPlaceLookupFailure.service)) }
                }
            }
        } onCancel: { Task { @MainActor in self.cancel() } }
    }
    private func finish(_ result: Result<MKLocalSearch.Response, Error>) {
        guard let pending = continuation else { return }; continuation = nil
        timeout?.cancel(); timeout = nil
        pending.resume(with: cancelled ? .failure(CancellationError()) : result)
    }
    private func cancel() {
        guard !cancelled else { return }; cancelled = true
        finish(.failure(CancellationError())); search.cancel()
    }
}
