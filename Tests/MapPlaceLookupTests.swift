import Foundation
import MapKit

@MainActor enum MapPlaceLookupTests {
    final class Clock {
        var time: TimeInterval = 100
        var delays: [TimeInterval] = []
        func sleep(_ seconds: TimeInterval) async throws {
            try Task.checkCancellation(); delays.append(seconds); time += seconds
        }
    }
    static func pin(_ id: String, latitude: Double = 40) -> ApplePlaceMatch {
        .init(applePlaceID: id, displayName: "Test location", secondaryText: "",
              coordinate: .init(latitude: latitude, longitude: -73),
              suggestedSectionPath: .init(cityOrRegion: nil, neighborhood: nil), websiteURL: nil, instagramURL: nil)
    }
    static func run() async throws {
        let clock = Clock(), lane = MapPlaceLookup(now: {clock.time}, sleep: {try await clock.sleep($0)})
        var starts: [TimeInterval] = [], attempts = 0
        for id in ["one", "two", "three", "one"] {
            _ = try await lane.resolve(placeID: id) { id in starts.append(clock.time); return pin(id) }
        }
        precondition(starts.count == 3 && zip(starts.dropFirst(), starts).allSatisfy { $0.0 - $0.1 >= 0.299 })
        lane.retainOnly(["three"])
        _ = try await lane.resolve(placeID: "one") { id in attempts += 1; return pin(id) }
        lane.clear()
        _ = try await lane.resolve(placeID: "one") { id in attempts += 1; return pin(id) }
        precondition(attempts == 2)
        print("PASS map pacing and temporary scope-only successes; cleanup forces fresh resolution")

        let backoffClock = Clock(), backoff = MapPlaceLookup(now:{backoffClock.time},sleep:{try await backoffClock.sleep($0)})
        var throttleCalls = 0
        _ = try await backoff.resolve(placeID:"recover") { id in
            throttleCalls += 1
            if throttleCalls < 3 { throw NSError(domain:MKErrorDomain,code:Int(MKError.Code.loadingThrottled.rawValue)) }
            return pin(id)
        }
        precondition(throttleCalls == 3 && backoffClock.delays == [5,10])
        var failedCalls = 0
        do {
            _ = try await backoff.resolve(placeID:"paused") { _ in failedCalls += 1; throw MapPlaceLookupFailure.throttled }
            preconditionFailure("Persistent throttle accepted")
        } catch let error as MapPlaceLookupFailure { precondition(error == .throttled && error.pausesBatch) }
        precondition(failedCalls == 3)
        let prior = backoffClock.time
        backoff.clear() // Navigation or Retry cannot erase an active cooldown.
        _ = try await backoff.resolve(placeID:"after") { id in precondition(backoffClock.time - prior >= 20);return pin(id) }
        print("PASS throttling exponential backoff, bounded attempts and cooldown survives Retry/navigation")

        let errorClock = Clock(), errors = MapPlaceLookup(now:{errorClock.time},sleep:{try await errorClock.sleep($0)})
        var offlineCalls = 0
        do {
            _ = try await errors.resolve(placeID:"offline") { _ in offlineCalls += 1; throw NSError(domain:NSURLErrorDomain,code:NSURLErrorNotConnectedToInternet) }
            preconditionFailure("Offline accepted")
        } catch let error as MapPlaceLookupFailure { precondition(error == .connection && error.pausesBatch) }
        precondition(offlineCalls == 1)
        var serverCalls = 0
        _ = try await errors.resolve(placeID:"server") { id in
            serverCalls += 1
            if serverCalls == 1 {throw NSError(domain:MKErrorDomain,code:Int(MKError.Code.serverFailure.rawValue))}
            return pin(id)
        }
        precondition(serverCalls == 2)
        var missingCalls = 0
        for _ in 0..<2 {
            let result = try await errors.resolve(placeID:"missing") { _ in missingCalls += 1;return nil }
            precondition(result == nil)
        }
        precondition(missingCalls == 2)
        let invalid = try await errors.resolve(placeID:"invalid") { id in pin(id,latitude:Double.nan) }
        precondition(invalid == nil)
        do {_ = try await errors.resolve(placeID:"unknown") {_ in throw NSError(domain:"Unrecognized",code:1)};preconditionFailure()}
        catch let error as MapPlaceLookupFailure {precondition(error == .service && error.pausesBatch)}
        print("PASS offline stops promptly, transient server retry, missing/invalid result retryable and unknown errors stop as temporary service failures")

        let queueClock = Clock(), queue = MapPlaceLookup(now:{queueClock.time},sleep:{try await queueClock.sleep($0)})
        var completion: CheckedContinuation<ApplePlaceMatch?, Never>?, firstCalls = 0, secondCalls = 0
        let first = Task { @MainActor in
            try await queue.resolve(placeID:"shared") { _ in
                firstCalls += 1
                return await withCheckedContinuation {completion = $0}
            }
        }
        while completion == nil {await Task.yield()}
        let second = Task { @MainActor in try await queue.resolve(placeID:"shared") {id in secondCalls += 1;return pin(id)} }
        await Task.yield()
        precondition(firstCalls == 1 && secondCalls == 0)
        completion!.resume(returning:pin("shared"))
        _ = try await first.value; _ = try await second.value
        precondition(secondCalls == 0)
        print("PASS concurrent duplicate pin lookups share completed success and never overlap provider calls")

        completion = nil
        let obsolete = Task { @MainActor in try await queue.resolve(placeID:"old") {_ in await withCheckedContinuation {completion=$0}} }
        while completion == nil {await Task.yield()}
        var obsoleteQueuedCalls = 0
        let waiting = Task { @MainActor in try await queue.resolve(placeID:"old-queued") { id in obsoleteQueuedCalls += 1;return pin(id)} }
        await Task.yield()
        obsolete.cancel(); waiting.cancel(); queue.retainOnly(["new"])
        let next = Task { @MainActor in try await queue.resolve(placeID:"new") {id in pin(id)} }
        completion!.resume(returning:pin("old"))
        for task in [obsolete,waiting] {
            do {_ = try await task.value;preconditionFailure("Cancelled scope returned") } catch is CancellationError {}
        }
        _ = try await next.value
        precondition(obsoleteQueuedCalls == 0)
        var refreshedCalls = 0
        _ = try await queue.resolve(placeID:"old") {id in refreshedCalls += 1;return pin(id)}
        precondition(refreshedCalls == 1)
        print("PASS city-switch cancellation suppresses late results, queued dispatch and stale cache publication")

        let partialClock = Clock(), partial = MapPlaceLookup(now:{partialClock.time},sleep:{try await partialClock.sleep($0)})
        partial.retainOnly(["good","later"])
        var goodCalls = 0, laterCalls = 0
        _ = try await partial.resolve(placeID:"good") {id in goodCalls += 1;return pin(id)}
        _ = try await partial.resolve(placeID:"later") {_ in laterCalls += 1;return nil}
        partial.retainOnly(["good","later"])
        _ = try await partial.resolve(placeID:"good") {id in goodCalls += 1;return pin(id)}
        _ = try await partial.resolve(placeID:"later") {id in laterCalls += 1;return pin(id)}
        precondition(goodCalls == 1 && laterCalls == 2)
        print("PASS partial pin Retry preserves successful work and retries only missing locations")
        precondition(MapPlaceLookupFailure.classify(NSError(domain: MKErrorDomain, code: Int(MKError.Code.placemarkNotFound.rawValue))) == .unavailable)
        try await cancellationAdapter()

    }
    static func cancellationAdapter() async throws {
        var callback: AppleMapItemOperation.Completion?, cancels = 0
        let operation = AppleMapItemOperation(start: { callback = $0 }, cancel: { cancels += 1 })
        let task = Task { @MainActor in try await operation.value() }
        while callback == nil { await Task.yield() }
        task.cancel()
        do { _ = try await task.value; preconditionFailure("Cancelled native adapter completed") } catch is CancellationError {}
        precondition(cancels == 1)
        callback?(MKMapItem(), nil) // Late success must not double-resume.
        callback?(nil, NSError(domain: MKErrorDomain, code: Int(MKError.Code.serverFailure.rawValue)))
        var synchronousCallback: AppleMapItemOperation.Completion?
        let synchronous = AppleMapItemOperation(start: { synchronousCallback = $0 }, cancel: { synchronousCallback?(MKMapItem(), nil) })
        let synchronousTask = Task { @MainActor in try await synchronous.value() }
        while synchronousCallback == nil { await Task.yield() }
        synchronousTask.cancel()
        do { _ = try await synchronousTask.value; preconditionFailure("Synchronous cancel callback accepted") } catch is CancellationError {}
        let success = AppleMapItemOperation(start: { $0(MKMapItem(), nil) }, cancel: { preconditionFailure("Successful request cancelled") })
        _ = try await success.value()
        let empty = AppleMapItemOperation(start: { $0(nil, nil) }, cancel: {})
        do { _ = try await empty.value(); preconditionFailure("Empty response accepted") } catch let error as MapPlaceLookupFailure { precondition(error == .service) }
        print("PASS native MapKit adapter cancellation, synchronous/late duplicate callbacks and empty/success results without network")
    }

}
