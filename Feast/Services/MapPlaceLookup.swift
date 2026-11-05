import Foundation
import MapKit

/// Failures describe the lookup, never whether a saved record still exists.
enum MapPlaceLookupFailure: Error, Equatable {
    case throttled, connection, service, unavailable

    var pausesBatch: Bool { self != .unavailable }
    var message: String {
        switch self {
        case .throttled: return "Apple Maps is busy. Some pins couldn't be loaded. Your places are still saved; try again shortly."
        case .connection: return "Check your connection to load the remaining pins. Your places are still saved."
        case .service: return "Apple Maps couldn't finish loading the pins. Your places are still saved; try again shortly."
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

/// One paced lane for this map's pin lookups, including obsolete city tasks. Only
/// successes are retained, in memory, for the current map scope. No disk/Core Data cache.
@MainActor final class MapPlaceLookup {
    private var cache: [String: ApplePlaceMatch] = [:]
    private var generation = UUID()
    private var busy = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private var nextAllowed: TimeInterval = 0
    private let now: () -> TimeInterval
    private let sleep: (TimeInterval) async throws -> Void

    init(now: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
         sleep: @escaping (TimeInterval) async throws -> Void = { seconds in
             try await Task.sleep(nanoseconds: UInt64(max(0, seconds) * 1_000_000_000))
         }) {
        self.now = now; self.sleep = sleep
    }

    func retainOnly(_ ids: Set<String>) {
        generation = UUID()
        cache = cache.filter { ids.contains($0.key) }
    }
    func clear() { retainOnly([]) } // Deliberately retains cooldown across navigation/retry.

    private func acquire() async {
        if !busy { busy = true; return }
        await withCheckedContinuation { waiters.append($0) }
    }
    private func release() {
        if waiters.isEmpty { busy = false }
        else { waiters.removeFirst().resume() }
    }
    private func check(_ expected: UUID) throws {
        try Task.checkCancellation()
        if generation != expected { throw CancellationError() }
    }

    func resolve(placeID: String, lookup: (String) async throws -> ApplePlaceMatch?) async throws -> ApplePlaceMatch? {
        let expected = generation
        try check(expected)
        if let cached = cache[placeID] { return cached }
        await acquire()
        defer { release() }
        try check(expected)
        if let cached = cache[placeID] { return cached }
        // At most three attempts per ID. This is conservative client pacing, not a
        // claimed Apple quota. A persistent service/network failure stops the batch.
        for attempt in 0..<3 {
            let delay = nextAllowed - now()
            if delay > 0 { try await sleep(delay) }
            try check(expected)
            do {
                let match = try await lookup(placeID)
                nextAllowed = max(nextAllowed, now() + 0.3)
                try check(expected)
                guard let match, let coordinate = match.coordinate,
                      coordinate.latitude.isFinite, coordinate.longitude.isFinite,
                      (-90...90).contains(coordinate.latitude), (-180...180).contains(coordinate.longitude) else { return nil }
                cache[placeID] = match
                return match
            } catch {
                nextAllowed = max(nextAllowed, now() + 0.3)
                try check(expected)
                if error is CancellationError { throw error }
                let failure = MapPlaceLookupFailure.classify(error)
                guard failure.pausesBatch else { throw failure }
                let backoff = failure == .throttled ? 5.0 * pow(2, Double(attempt)) : pow(2, Double(attempt))
                nextAllowed = max(nextAllowed, now() + backoff)
                // Offline is not helped by immediate repeated network calls.
                let ns = error as NSError
                if attempt == 2 || (ns.domain == NSURLErrorDomain && ns.code == NSURLErrorNotConnectedToInternet) { throw failure }
            }
        }
        throw MapPlaceLookupFailure.service
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
    init(request: MKMapItemRequest) {
        start = { completion in request.getMapItem(completionHandler: completion) }
        cancelRequest = { request.cancel() }
    }
    init(start: @escaping (@escaping Completion) -> Void, cancel: @escaping () -> Void) {
        self.start = start; self.cancelRequest = cancel
    }
    func value() async throws -> MKMapItem {
        try await withTaskCancellationHandler {
            try Task.checkCancellation()
            return try await withCheckedThrowingContinuation { continuation in
                self.continuation = continuation
                if cancelled || Task.isCancelled { cancel(); return }
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
        self.continuation = nil
        continuation.resume(with: cancelled ? .failure(CancellationError()) : result)
    }
}
