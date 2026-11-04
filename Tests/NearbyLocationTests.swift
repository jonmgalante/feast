import CoreLocation
import Foundation

@MainActor private final class FixtureLocationManager: CLLocationManager {
    var fixtureAuthorization: CLAuthorizationStatus = .authorizedAlways
    var requests = 0
    var permissionRequests = 0
    override var authorizationStatus: CLAuthorizationStatus { fixtureAuthorization }
    override func requestLocation() { requests += 1 }
    override func requestWhenInUseAuthorization() { permissionRequests += 1 }
    override func stopUpdatingLocation() {}
    override func startUpdatingLocation() { preconditionFailure("Continuous tracking forbidden") }
    override func requestAlwaysAuthorization() { preconditionFailure("Always authorization forbidden") }
}

@MainActor enum NearbyLocationTests {
    static func run() async {
        var managers: [FixtureLocationManager] = []
        let service = NearbyLocationService(makeManager: {
            let manager = FixtureLocationManager(); managers.append(manager); return manager
        })
        service.request()
        let first = managers.last!
        service.locationManagerDidChangeAuthorization(first)
        precondition(first.requests == 1 && service.isRequesting)
        service.cancel()
        let fix = CLLocation(latitude: 40.725, longitude: -73.992)
        service.locationManager(first, didUpdateLocations: [fix])
        precondition(service.location == nil && !service.isRequesting)
        service.request()
        let second = managers.last!
        service.locationManager(first, didFailWithError: CLError(.denied))
        precondition(service.errorMessage == nil && service.isRequesting)
        service.locationManager(second, didUpdateLocations: [CLLocation(coordinate: fix.coordinate, altitude: 0, horizontalAccuracy: 10, verticalAccuracy: -1, timestamp: Date(timeIntervalSinceNow: -120))])
        precondition(service.location == nil && service.isRequesting)
        service.locationManager(second, didUpdateLocations: [fix])
        precondition(service.location == fix && !service.isRequesting)
        service.request()
        let third = managers.last!
        third.fixtureAuthorization = .denied
        service.locationManagerDidChangeAuthorization(third)
        precondition(service.errorMessage != nil && !service.isRequesting && service.location == fix)
        service.request()
        let fourth = managers.last!
        service.locationManager(fourth, didFailWithError: CLError(.locationUnknown))
        precondition(service.errorMessage != nil && !service.isRequesting)
        let pending = FixtureLocationManager()
        pending.fixtureAuthorization = .notDetermined
        let permission = NearbyLocationService(requestTimeout: .milliseconds(20), makeManager: { pending })
        permission.request()
        precondition(pending.permissionRequests == 1 && pending.requests == 0)
        try? await Task.sleep(for: .milliseconds(60))
        precondition(permission.isRequesting && permission.errorMessage == nil)
        pending.fixtureAuthorization = .authorizedAlways
        permission.locationManagerDidChangeAuthorization(pending)
        precondition(pending.requests == 1)
        permission.cancel()
        let timed = FixtureLocationManager()
        let timeout = NearbyLocationService(requestTimeout: .milliseconds(20), makeManager: { timed })
        timeout.request()
        try? await Task.sleep(for: .milliseconds(60))
        precondition(!timeout.isRequesting && timeout.errorMessage != nil)
        timeout.locationManager(timed, didUpdateLocations: [fix])
        precondition(timeout.location == nil)
        let browse = SavedPlaceBrowseState()
        browse.selectedTab = 1
        browse.filters.selectedListURIString = "synthetic-city"
        browse.filters.queryText = " exact query "
        browse.filters.selectedStatuses = [.love, .been]
        browse.filters.selectedTags = ["One"]
        browse.filters.selectedPlaceType = .cafe
        browse.filters.selectedCuisine = "Synthetic"
        let criteria = browse.filters
        let viewport = SavedMapViewport(latitude: 40.725, longitude: -73.992, latitudeDelta: 0.02, longitudeDelta: 0.02)
        precondition(browse.rememberNearbyViewport(viewport, requestedScope: browse.scopeKey))
        precondition(browse.filters == criteria && browse.viewports[browse.scopeKey] == viewport)
        precondition(!browse.rememberNearbyViewport(viewport, requestedScope: "obsolete-city"))
        browse.selectedTab = 0
        precondition(!browse.rememberNearbyViewport(viewport, requestedScope: browse.scopeKey))
        precondition(browse.filters == criteria)
        print("PASS Nearby viewport retains exact city/query/status/tag/type/cuisine and rejects interrupted scope/tab requests")
        print("PASS nearby one-shot requests, duplicate authorization callbacks, cancellation/stale callbacks, stale fixes and denied/unavailable errors")
    }
}
