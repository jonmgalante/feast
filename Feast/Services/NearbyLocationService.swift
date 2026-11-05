import CoreLocation
import Combine
import Foundation

/// Explicit, one-shot location requests. Never starts continuous/background updates.
@MainActor final class NearbyLocationService: NSObject, ObservableObject, @preconcurrency CLLocationManagerDelegate {
    @Published private(set) var isRequesting = false
    @Published private(set) var location: CLLocation?
    @Published private(set) var resultID = UUID()
    @Published var errorMessage: String?
    private let requestTimeout: Duration
    private let makeManager: () -> CLLocationManager
    private var awaitingFix = false
    private var manager: CLLocationManager?
    private var timeout: Task<Void, Never>?

    init(requestTimeout: Duration = .seconds(15), makeManager: @escaping () -> CLLocationManager = { CLLocationManager() }) {
        self.requestTimeout = requestTimeout
        self.makeManager = makeManager
        super.init()
    }

    /// Opening the map uses an already granted permission only. Explicit Nearby
    /// retains the existing permission prompt and error explanation.
    func requestIfAuthorized() {
        let status = makeManager().authorizationStatus
        switch status {
        case .authorizedAlways, .authorizedWhenInUse: request()
        default: return
        }
    }

    func request() {
        cancel()
        errorMessage = nil
        let manager = makeManager()
        self.manager = manager
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyHundredMeters
        isRequesting = true
        switch manager.authorizationStatus {
        case .notDetermined: manager.requestWhenInUseAuthorization()
        case .authorizedAlways, .authorizedWhenInUse: requestFix(manager)
        case .denied, .restricted: fail(Self.deniedMessage)
        @unknown default: fail("Location isn't available on this device.")
        }
    }

    private func requestFix(_ manager: CLLocationManager) {
        guard !awaitingFix else { return }
        awaitingFix = true
        timeout = Task { [weak self] in
            try? await Task.sleep(for: self?.requestTimeout ?? .seconds(15))
            guard !Task.isCancelled else { return }
            self?.fail("Your location isn't available yet. Try again when you have a location signal.")
        }
        manager.requestLocation()
    }

    func cancel() {
        timeout?.cancel(); timeout = nil
        manager?.delegate = nil
        manager?.stopUpdatingLocation()
        manager = nil
        awaitingFix = false
        isRequesting = false
    }

    private static let deniedMessage = "Allow location access for Feast in Settings to center the map nearby. Your saved places and filters are unchanged."
    private func fail(_ message: String) { cancel(); errorMessage = message }

    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        guard self.manager === manager, isRequesting else { return }
        switch manager.authorizationStatus {
        case .authorizedAlways, .authorizedWhenInUse: requestFix(manager)
        case .denied, .restricted: fail(Self.deniedMessage)
        default: break
        }
    }
    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard self.manager === manager, isRequesting,
              let fix = locations.last, fix.horizontalAccuracy >= 0,
              abs(fix.timestamp.timeIntervalSinceNow) < 60,
              CLLocationCoordinate2DIsValid(fix.coordinate) else { return }
        cancel()
        location = fix
        resultID = UUID()
    }
    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        guard self.manager === manager, isRequesting else { return }
        fail((error as? CLError)?.code == .denied ? Self.deniedMessage : "Your location couldn't be found. Check Location Services and try again. Your saved places are unchanged.")
    }
}
