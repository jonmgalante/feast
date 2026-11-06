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
    static func pin(_ id: String, latitude: Double = 40, longitude: Double = -73) -> ApplePlaceMatch {
        .init(applePlaceID: id, displayName: "Test location", secondaryText: "",
              coordinate: .init(latitude: latitude, longitude: longitude),
              suggestedSectionPath: .init(cityOrRegion: nil, neighborhood: nil), websiteURL: nil, instagramURL: nil)
    }
    static func spin(_ ready: () -> Bool) async {
        for _ in 0..<10_000 { if ready() { return }; await Task.yield() }
        preconditionFailure("Async fixture did not reach expected state")
    }
    static func run() async throws {
        let clock = Clock()
        let lane = MapPlaceLookup(capacity: 2, ttl: 10, now: {clock.time}, sleep: {try await clock.sleep($0)}, emit: {_,_,_ in})
        for id in ["one", "two", "one"] { _ = try await lane.resolve(placeID: id) { pin($0) } }
        precondition(lane.metrics.calls == 2 && lane.metrics.cacheHits == 1 && clock.delays.isEmpty)
        clock.time += 1
        _ = try await lane.resolve(placeID: "three") { pin($0) }
        precondition(lane.cachedCount == 2)
        clock.time += 11
        precondition(lane.cachedCount == 0)
        _ = try await lane.resolve(placeID: "one") {pin($0)}
        lane.clear(); precondition(lane.cachedCount == 0)
        print("PASS map successes have zero fixed scheduling delay; bounded RAM cache, fixed expiry and background clear")

        let expiry = MapPlaceLookup(ttl: 0.02, emit: {_,_,_ in})
        _ = try await expiry.resolve(placeID: "expiry") {pin($0)}
        let revision = expiry.revision
        try await Task.sleep(for: .milliseconds(60))
        precondition(expiry.cachedCount == 0 && expiry.revision > revision)
        print("PASS physical timed eviction publishes removal for map and detail without user interaction")

        let shared = MapPlaceLookup(emit: {_,_,_ in})
        var completion: CheckedContinuation<ApplePlaceMatch?, Never>?
        let first = Task { try await shared.resolve(placeID: "shared") { _ in await withCheckedContinuation {completion = $0} } }
        await spin { completion != nil }
        let second = Task { try await shared.resolve(placeID: "shared") { _ in preconditionFailure("Duplicate request") } }
        await spin { shared.metrics.joined == 1 }
        first.cancel()
        do {_ = try await first.value; preconditionFailure()} catch is CancellationError {}
        completion!.resume(returning: pin("shared")); completion = nil
        _ = try await second.value
        precondition(shared.metrics.calls == 1 && shared.cachedPlace("shared") != nil)
        print("PASS shared map/detail request survives one subscriber cancellation and reuses its success")

        let cancel = MapPlaceLookup(maximumConcurrent: 1, emit: {_,_,_ in})
        var callbacks: [String: AppleMapItemOperation.Completion] = [:], cancelled = 0, queuedStarted = false
        let active = Task { try await cancel.resolve(placeID: "active") {id in
            let op = AppleMapItemOperation(start: {callbacks[id]=$0}, cancel: {cancelled += 1})
            _ = try await op.value(); return pin(id)
        } }
        await spin { callbacks["active"] != nil }
        let queued = Task { try await cancel.resolve(placeID: "queued") {id in queuedStarted = true; return pin(id)} }
        await Task.yield(); queued.cancel()
        do {_ = try await queued.value; preconditionFailure()} catch is CancellationError {}
        precondition(!queuedStarted)
        active.cancel()
        do {_ = try await active.value; preconditionFailure()} catch is CancellationError {}
        await spin { cancelled == 1 }
        callbacks["active"]?(MKMapItem(),nil)
        _ = try await cancel.resolve(placeID: "next") {pin($0)}
        precondition(cancel.cachedPlace("active") == nil)
        print("PASS queued cancellation is prompt, last subscriber cancels MapKit, late result cannot populate cache")

        let backoffClock = Clock()
        let backoff = MapPlaceLookup(now: {backoffClock.time},sleep:{try await backoffClock.sleep($0)},emit:{_,_,_ in})
        do { _ = try await backoff.resolve(placeID:"throttle") {_ in throw MapPlaceLookupFailure.throttled};preconditionFailure() }
        catch let error as MapPlaceLookupFailure {precondition(error == .throttled)}
        backoff.clear()
        _ = try await backoff.resolve(placeID:"recovery") {pin($0)}
        precondition(backoffClock.delays == [5, 10, 20] && backoff.metrics.throttled == 3)
        var offlineCalls = 0
        do { _ = try await backoff.resolve(placeID:"offline") {_ in offlineCalls += 1;throw NSError(domain:NSURLErrorDomain,code:NSURLErrorNotConnectedToInternet)};preconditionFailure() }
        catch {precondition(MapPlaceLookupFailure.classify(error) == .connection)}
        precondition(offlineCalls == 1)
        for failure in [MapPlaceLookupFailure.service, .unavailable] {
            do {_ = try await backoff.resolve(placeID:"failure") {_ in throw failure};preconditionFailure()}
            catch {precondition(MapPlaceLookupFailure.classify(error) == failure)}
        }
        let invalid = try await backoff.resolve(placeID:"invalid") {pin($0, latitude: .nan)}
        precondition(invalid == nil)
        print("PASS throttle reduces scheduling and preserves cooldown across Retry/navigation; offline has no retry storm; errors distinguished")

        try await capacityAndLifecycle()
        for count in [284, 1500] { try await scale(count) }
        planTests()
        try await cityAnchors()
        try await cancellationAdapter()
        await connectionRecovery()
        try await unavailableRecovery()
    }

    static func connectionRecovery() async {
        let recovery = MapConnectionRecovery(monitorsNetwork: false, settlingDelay: .zero)
        recovery.receive(isSatisfied: false); recovery.receive(isSatisfied: true)
        await Task.yield()
        precondition(recovery.restoration == 0 && !recovery.claim(hasConnectionFailure: true))
        recovery.setActive(true)
        recovery.receive(isSatisfied: true) // Initial path snapshot is not a restoration.
        await Task.yield()
        precondition(recovery.restoration == 0)
        recovery.receive(isSatisfied: false); recovery.receive(isSatisfied: true)
        recovery.receive(isSatisfied: true)
        await spin { recovery.restoration == 1 }
        precondition(!recovery.claim(hasConnectionFailure: false)) // An in-flight batch may report failure later.
        precondition(recovery.claim(hasConnectionFailure: true))
        precondition(!recovery.claim(hasConnectionFailure: true))
        recovery.receive(isSatisfied: true)
        await Task.yield()
        precondition(recovery.restoration == 1)
        // A later genuine outage can recover even if the earlier retry failed.
        recovery.receive(isSatisfied: false); recovery.receive(isSatisfied: true)
        await spin { recovery.restoration == 2 }
        precondition(recovery.claim(hasConnectionFailure: true))
        // Rapid flaps cancel the unsettled event and coalesce to one allowance.
        recovery.receive(isSatisfied: false); recovery.receive(isSatisfied: true)
        recovery.receive(isSatisfied: false); recovery.receive(isSatisfied: true)
        await spin { recovery.restoration == 3 }
        precondition(recovery.claim(hasConnectionFailure: true) && !recovery.claim(hasConnectionFailure: true))
        recovery.receive(isSatisfied: false); recovery.receive(isSatisfied: true)
        recovery.setActive(false)
        await Task.yield()
        precondition(recovery.restoration == 3 && !recovery.claim(hasConnectionFailure: true))
        recovery.receive(isSatisfied: false); recovery.receive(isSatisfied: true)
        recovery.setActive(true); recovery.receive(isSatisfied: true)
        await Task.yield()
        precondition(recovery.restoration == 3 && !recovery.claim(hasConnectionFailure: true))
        recovery.receive(isSatisfied: false); recovery.receive(isSatisfied: true)
        await spin { recovery.restoration == 4 }
        recovery.receive(isSatisfied: false) // New outage invalidates an unclaimed older restoration.
        precondition(!recovery.claim(hasConnectionFailure: true))
        recovery.receive(isSatisfied: true)
        await spin { recovery.restoration == 5 }
        recovery.discardRestoration()
        precondition(!recovery.claim(hasConnectionFailure: true)) // Healthy/idle event cannot recover an unrelated future failure.
        recovery.setActive(false)
        print("PASS connection recovery requires active settled offline-to-online transition, coalesces flaps, grants once, rearms after later outage and rejects inactive/stale events")
    }

    static func unavailableRecovery() async throws {
        let clock = Clock()
        let lookup = MapPlaceLookup(capacity: 2, ttl: 10, now: { clock.time }, sleep: { try await clock.sleep($0) }, emit: { _,_,_ in })
        _ = try await lookup.resolve(placeID: "loaded") { pin($0) }
        _ = try await lookup.resolve(placeID: "missing") { _ in nil }
        do { _ = try await lookup.resolve(placeID: "offline") { _ in throw MapPlaceLookupFailure.connection }; preconditionFailure() }
        catch { precondition(MapPlaceLookupFailure.classify(error) == .connection) }
        precondition(lookup.recentlyUnavailableIDs == ["missing"])
        let records = ["loaded", "missing", "offline"].map { SavedMapPlan.Place(id: $0, appleID: $0, cityID: "city") }
        let recoverable = records.filter { !lookup.recentlyUnavailableIDs.contains($0.appleID) }
        let ids = SavedMapPlan.lookupIDs(places: recoverable, selectedCity: "city", viewport: .overview,
                                        cityHints: [:], known: lookup.recentlyResolvedIDs)
        precondition(ids == ["offline"])
        let calls = lookup.metrics.calls
        for id in ids { _ = try await lookup.resolve(placeID: id) { pin($0) } }
        precondition(lookup.metrics.calls == calls + 1 && lookup.cachedPlace("loaded") != nil)
        precondition(clock.delays == [1]) // Recovery still observes the shared connection cooldown.
        for index in 0..<12 { _ = try await lookup.resolve(placeID: "missing-\(index)") { _ in nil } }
        precondition(lookup.recentlyUnavailableIDs.count <= 8)
        clock.time += 11
        precondition(lookup.recentlyUnavailableIDs.isEmpty)
        _ = try await lookup.resolve(placeID: "missing") { _ in nil }
        _ = try await lookup.resolve(placeID: "missing") { pin($0) }
        precondition(!lookup.recentlyUnavailableIDs.contains("missing"))
        lookup.clear(); precondition(lookup.recentlyUnavailableIDs.isEmpty)
        print("PASS connectivity recovery skips successful/unavailable IDs, preserves pins/cooldown, and unavailable metadata is bounded, expiring and cleared")
    }
    static func capacityAndLifecycle() async throws {
        let clock = Clock()
        let cache = MapPlaceLookup(capacity: 2, ttl: 10, now: {clock.time}, sleep: {try await clock.sleep($0)},emit:{_,_,_ in})
        cache.visibleViewport = .init(latitude:40,longitude:-73,latitudeDelta:0.1,longitudeDelta:0.1)
        _ = try await cache.resolve(placeID:"visible-one") {pin($0)}
        _ = try await cache.resolve(placeID:"visible-two") {pin($0)}
        for i in 0..<8 { clock.time += 0.1; _ = try await cache.resolve(placeID:"far-\(i)") {pin($0,latitude:51)} }
        precondition(cache.cachedPlace("visible-one") != nil && cache.cachedPlace("visible-two") != nil)
        precondition(cache.cachedCount == 2 && cache.recentlyResolvedIDs.count <= 8)
        let plan = [SavedMapPlan.Place(id:"record",appleID:"far-7",cityID:"city")]
        precondition(SavedMapPlan.lookupIDs(places:plan,selectedCity:"city",viewport:.overview,cityHints:[:],known:cache.recentlyResolvedIDs).isEmpty)
        let expiryBeforeStore = cache.expiration
        clock.time += 11
        _ = try await cache.resolve(placeID:"fresh") {pin($0)}
        precondition(cache.expiration > expiryBeforeStore)
        cache.retryEvictedLocations()
        precondition(SavedMapPlan.lookupIDs(places:plan,selectedCity:"city",viewport:.overview,cityHints:[:],known:cache.recentlyResolvedIDs) == ["far-7"])
        clock.time += 11; precondition(cache.cachedCount == 0 && cache.recentlyResolvedIDs.isEmpty)
        let canonical = MapPlaceLookup(emit:{_,_,_ in})
        _ = try await canonical.resolve(placeID:"requested") {_ in pin("canonical")}
        precondition(canonical.cachedPlace("requested")?.applePlaceID == "canonical")
        precondition(canonical.recentlyResolvedIDs.contains("requested"))
        print("PASS capacity preserves visible pins, memo bounded/expiring/retryable, requested ID remains cache identity after canonical redirect")
        let late = MapPlaceLookup(emit:{_,_,_ in})
        var completion: CheckedContinuation<ApplePlaceMatch?, Never>?
        let task = Task { try await late.resolve(placeID:"late") {_ in await withCheckedContinuation {completion=$0}} }
        await spin {completion != nil}; late.clear()
        do {_ = try await task.value;preconditionFailure()} catch is CancellationError {}
        completion!.resume(returning:pin("late")); await Task.yield()
        precondition(late.cachedCount == 0)
        var callback: AppleMapItemOperation.Completion?, cancellations = 0
        let timeout = AppleMapItemOperation(timeoutDuration:.milliseconds(20),start:{callback=$0},cancel:{cancellations += 1})
        do {_ = try await timeout.value();preconditionFailure()} catch {precondition(MapPlaceLookupFailure.classify(error) == .connection)}
        callback?(MKMapItem(),nil); precondition(cancellations == 1)
        print("PASS background clears subscribers and rejects late results; native request deadline cancels once and classifies timeout")
    }
    static func scale(_ count: Int) async throws {
        let service = MapPlaceLookup(capacity:512,emit:{_,_,_ in})
        var active = 0, maximum = 0, next = 0
        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<3 {
                group.addTask { @MainActor in
                    while next < count {
                        let id = "scale-\(next)"; next += 1
                        _ = try? await service.resolve(placeID:id) {id in
                            active += 1; maximum = max(maximum, active)
                            await Task.yield(); active -= 1; return pin(id)
                        }
                    }
                }
            }
        }
        precondition(service.metrics.calls == count && service.metrics.successes == count)
        precondition(maximum <= 3 && service.metrics.maxActive <= 3 && service.cachedCount <= 512)
        print("PASS \(count)-place fixture complete, at most three shared requests, bounded cache; no records written")
    }
    static func planTests() {
        let viewport = SavedMapViewport(latitude:40,longitude:-73,latitudeDelta:0.04,longitudeDelta:0.04)
        let hints = ["near": viewport, "far":SavedMapViewport(latitude:51,longitude:0,latitudeDelta:0.1,longitudeDelta:0.1)]
        let places = (0..<284).map { SavedMapPlan.Place(id:"record-\($0)",appleID:"apple-\($0)",cityID:$0<100 ? "near":"far") }
        let ids = SavedMapPlan.lookupIDs(places:places,selectedCity:nil,viewport:viewport,cityHints:hints,known:[])
        precondition(ids.count == 100)
        precondition(SavedMapPlan.lookupIDs(places:Array(places.prefix(7)),selectedCity:"near",viewport:.overview,cityHints:[:],known:["apple-0"]).count == 6)
        precondition(SavedMapPlan.lookupIDs(places:places,selectedCity:nil,viewport:.overview,cityHints:hints,known:[]).isEmpty)
        precondition(SavedMapPlan.lookupIDs(places:places,selectedCity:nil,viewport:viewport,cityHints:[:],known:[]).isEmpty)
        precondition(SavedMapPlan.identity(places) == SavedMapPlan.identity(places.reversed()))
        let dateLine = SavedMapViewport(latitude:0,longitude:179,latitudeDelta:10,longitudeDelta:10)
        precondition(dateLine.contains(.init(latitude:0,longitude:-179)))
        precondition(!dateLine.contains(.init(latitude:0,longitude:0)))
        precondition(!viewport.contains(.init(latitude:.nan,longitude:-73)))
        let same = [ApplePlaceCoordinate(latitude:40,longitude:-73), .init(latitude:40,longitude:-73)]
        precondition(SavedMapPlan.clusterNeedsList(coordinates:same,latitudeDelta:1))
        precondition(!SavedMapPlan.clusterNeedsList(coordinates:[same[0],.init(latitude:41,longitude:-73)],latitudeDelta:1))
        precondition(SavedMapPlan.acceptsCameraResult(requestedScope:"city",currentScope:"city",requestedRevision:1,currentRevision:1,active:true))
        for test in [("other",1,true),("city",2,true),("city",1,false)] {
            precondition(!SavedMapPlan.acceptsCameraResult(requestedScope:"city",currentScope:test.0,requestedRevision:1,currentRevision:test.1,active:test.2))
        }
        print("PASS camera results reject newer pan/Nearby/scope/background intent; coincident clusters remain selectable")
        print("PASS filter/city demand excludes unrelated 184 lookups, known hits reused, wide zoom defers unknowns, date-line viewport and order-invariant identity")
    }
    static func cityAnchors() async throws {
        let service = MapPlaceLookup(emit: {_,_,_ in})
        let coordinates = ["ny": ApplePlaceCoordinate(latitude:40.72,longitude:-73.98),
                           "london": .init(latitude:51.51,longitude:-0.12),
                           "paris": .init(latitude:48.86,longitude:2.35)]
        let counts = ["ny":152, "london":100, "paris":32]
        let places = counts.flatMap { city, count in
            (0..<count).map { SavedMapPlan.Place(id:"\(city)-record-\($0)",
                appleID:String(format:"%@-%03d",city,$0),cityID:city) }
        }
        var requested: [String] = []
        func resolve(_ id: String) async throws -> ApplePlaceMatch? {
            requested.append(id); await Task.yield()
            let coordinate = coordinates[String(id.split(separator:"-")[0])]!
            return pin(id,latitude:coordinate.latitude,longitude:coordinate.longitude)
        }
        var anchors: [String: SavedMapViewport] = [:]
        try await withThrowingTaskGroup(of:(String,SavedMapViewport).self) { group in
            for city in counts.keys {
                let ids = places.filter {$0.cityID==city}.map(\.appleID)
                group.addTask { @MainActor in
                    (city,try await service.cityAnchor(placeIDs:ids,lookup:resolve).viewport!)
                }
            }
            for try await (city,anchor) in group { anchors[city]=anchor }
        }
        precondition(requested.count == 3 && service.cachedCount == 3)
        precondition(service.metrics.maxActive <= 3)
        precondition(SavedMapPlan.lookupIDs(places:places,selectedCity:nil,viewport:.overview,
            cityHints:anchors,known:service.recentlyResolvedIDs).isEmpty)
        let london = SavedMapViewport(latitude:51.5,longitude:-0.1,latitudeDelta:0.8,longitudeDelta:1.1)
        let needed = SavedMapPlan.lookupIDs(places:places,selectedCity:nil,viewport:london,
            cityHints:anchors,known:service.recentlyResolvedIDs)
        precondition(needed.count == 99 && needed.allSatisfy {$0.hasPrefix("london-")})
        for id in needed { _ = try await service.resolve(placeID:id,lookup:resolve) }
        let calls = requested.count
        let again = try await service.cityAnchor(placeIDs:places.filter {$0.cityID=="london"}.map(\.appleID),near:london,lookup:resolve)
        precondition(again.viewport?.contains(coordinates["london"]!) == true && requested.count == calls)
        precondition(SavedMapPlan.lookupIDs(places:places,selectedCity:nil,viewport:london,
            cityHints:anchors,known:service.recentlyResolvedIDs).isEmpty)
        // A name-only result for London, Ontario rejects UK demand in build 10.
        // The exact saved-place anchor selects the correct UK records instead.
        let wrongNameHint = SavedMapViewport(latitude:42.98,longitude:-81.25,latitudeDelta:0.09,longitudeDelta:0.12)
        precondition(SavedMapPlan.lookupIDs(places:places,selectedCity:nil,viewport:london,
            cityHints:["london":wrongNameHint],known:[]).isEmpty)
        precondition(SavedMapPlan.lookupIDs(places:places,selectedCity:nil,viewport:london,
            cityHints:anchors,known:[]).count == 100)
        print("PASS cold All Cities resolves one exact saved-place anchor per city; 284 records avoid a whole-library sweep; London pan loads its 99 remaining records and reuses them")

        let fallback = MapPlaceLookup(emit: {_,_,_ in}); var tried: [String] = []
        let anchor = try await fallback.cityAnchor(placeIDs:["c","a","b","d","","a"]) { id in
            tried.append(id)
            if id == "a" { throw MapPlaceLookupFailure.unavailable }
            if id == "b" { return nil }
            return pin(id,latitude:51.51,longitude:-0.12)
        }
        precondition(tried == ["a","b","c"] && anchor.viewport?.contains(coordinates["london"]!) == true)
        let unavailable = MapPlaceLookup(emit:{_,_,_ in}); var missing=0
        let absent = try await unavailable.cityAnchor(placeIDs:["d","c","b","a"]) {_ in missing += 1;return nil}
        precondition(absent.viewport == nil && missing == 3)
        let offline = MapPlaceLookup(emit:{_,_,_ in}); var attempts=0
        do {_ = try await offline.cityAnchor(placeIDs:["a","b","c"]) {_ in attempts += 1;throw MapPlaceLookupFailure.connection};preconditionFailure()}
        catch {precondition(MapPlaceLookupFailure.classify(error) == .connection)}
        precondition(attempts==1)
        let blank = try await service.cityAnchor(placeIDs:["",""]) {_ in preconditionFailure("Blank anchor called provider")}
        precondition(blank.viewport == nil)
        print("PASS saved-place city camera anchors try at most three unavailable candidates, stop on connectivity failure, ignore duplicate/blank IDs and never query an ambiguous city label")

        let spread = MapPlaceLookup(emit:{_,_,_ in})
        _ = try await spread.resolve(placeID:"a") {pin($0,latitude:40.72,longitude:-73.98)}
        _ = try await spread.resolve(placeID:"b") {pin($0,latitude:51.51,longitude:-0.12)}
        let nearest = try await spread.cityAnchor(placeIDs:["a","b"],near:london) {_ in preconditionFailure("Cached anchor queried provider")}
        precondition(nearest.viewport?.contains(coordinates["london"]!) == true)
        precondition(SavedMapPlan.anchorIDs(["b","","a","b","d","c"]) == ["a","b","c"])
        print("PASS city anchors prefer a cached saved place near the current viewport and remain stable under record reordering")

        let clock = Clock()
        let full = MapPlaceLookup(capacity:1,ttl:10,now:{clock.time},emit:{_,_,_ in})
        full.visibleViewport = .city(around:coordinates["ny"]!)
        _ = try await full.resolve(placeID:"ny") {pin($0,latitude:40.72,longitude:-73.98)}
        let first = try await full.cityAnchor(placeIDs:["london-a","london-b"]) {pin($0,latitude:51.51,longitude:-0.12)}
        precondition(first.viewport != nil && full.cachedPlace("london-a") == nil)
        for _ in 0..<10 {
            let deferred = try await full.cityAnchor(placeIDs:["london-a","london-b"]) {_ in preconditionFailure("Evicted anchor refetched automatically")}
            guard case .deferred = deferred else {preconditionFailure("Capacity classified as unavailable")}
        }
        precondition(full.metrics.calls == 2 && full.cachedPlace("ny") != nil)
        full.retryEvictedLocations()
        _ = try await full.cityAnchor(placeIDs:["london-a"]) {pin($0,latitude:51.51,longitude:-0.12)}
        precondition(full.metrics.calls == 3)
        clock.time += 11
        _ = try await full.cityAnchor(placeIDs:["london-a"]) {pin($0,latitude:51.51,longitude:-0.12)}
        precondition(full.metrics.calls == 4)
        print("PASS evicted city anchors defer without repeated pan lookups, preserve visible pins and become retryable after explicit Retry or TTL expiry")
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
