import Foundation
import MapKit

extension SavedMapViewport {
    var isValid: Bool {
        latitude.isFinite && longitude.isFinite && latitudeDelta.isFinite && longitudeDelta.isFinite &&
        (-90...90).contains(latitude) && (-180...180).contains(longitude) &&
        latitudeDelta > 0 && latitudeDelta <= 180 && longitudeDelta > 0 && longitudeDelta <= 360
    }
    var region: MKCoordinateRegion {
        MKCoordinateRegion(center: .init(latitude: latitude, longitude: longitude),
            span: .init(latitudeDelta: latitudeDelta, longitudeDelta: longitudeDelta))
    }
    init(_ region: MKCoordinateRegion) {
        latitude = region.center.latitude; longitude = region.center.longitude
        latitudeDelta = min(180, region.span.latitudeDelta); longitudeDelta = min(360, region.span.longitudeDelta)
    }
    static let overview = SavedMapViewport(latitude: 20, longitude: 0, latitudeDelta: 150, longitudeDelta: 300)
    static func nearby(_ coordinate: CLLocationCoordinate2D) -> Self {
        Self(MKCoordinateRegion(center: coordinate, latitudinalMeters: 3_000, longitudinalMeters: 3_000))
    }
    /// Wrapped longitude handles both sides of the date line, including padded views.
    func contains(_ coordinate: ApplePlaceCoordinate, padding: Double = 1.25) -> Bool {
        guard isValid, CLLocationCoordinate2DIsValid(.init(latitude: coordinate.latitude, longitude: coordinate.longitude)) else { return false }
        let d = abs(coordinate.longitude - longitude).truncatingRemainder(dividingBy: 360)
        return abs(coordinate.latitude - latitude) <= latitudeDelta * padding / 2 && min(d, 360 - d) <= longitudeDelta * padding / 2
    }
    var loadsUnknownPlaces: Bool { latitudeDelta <= 3 && longitudeDelta <= 4 }
    var queryKey: String { "\(latitude),\(longitude),\(latitudeDelta),\(longitudeDelta)" }
}

/// Metadata-only plan. A city anchor is a demand hint, not proof of a record's
/// location. Unknown places outside these hints stay unattempted, never 'missing'.
enum SavedMapPlan {
    static func acceptsCameraResult(requestedScope: String, currentScope: String,
                                    requestedRevision: Int, currentRevision: Int, active: Bool) -> Bool {
        active && requestedScope == currentScope && requestedRevision == currentRevision
    }
    static func clusterNeedsList(coordinates: [ApplePlaceCoordinate], latitudeDelta: Double) -> Bool {
        Set(coordinates).count <= 1 || latitudeDelta < 0.001
    }
    struct Place: Equatable {
        let id: String, appleID: String, cityID: String
    }
    static func lookupIDs(places: [Place], selectedCity: String?, viewport: SavedMapViewport,
                          cityHints: [String: SavedMapViewport], known: Set<String>) -> [String] {
        let cities: Set<String>
        if let selectedCity { cities = [selectedCity] }
        else if viewport.loadsUnknownPlaces {
            cities = Set(cityHints.filter { _, hint in
                let expanded = SavedMapViewport(latitude: viewport.latitude, longitude: viewport.longitude,
                    latitudeDelta: max(viewport.latitudeDelta * 1.5, 0.6), longitudeDelta: max(viewport.longitudeDelta * 1.5, 0.8))
                return expanded.contains(.init(latitude: hint.latitude, longitude: hint.longitude), padding: 1)
            }.keys)
        } else { cities = [] }
        // Note edits/reordered rows do not change identity or repeat network lookups.
        return Set(places.filter { cities.contains($0.cityID) && !known.contains($0.appleID) && !$0.appleID.isEmpty }.map(\.appleID)).sorted()
    }
    static func identity(_ places: [Place]) -> String {
        places.map { "\($0.id):\($0.appleID):\($0.cityID)" }.sorted().joined(separator: "|")
    }
}

/// MapKit's clustering stays in Apple's map renderer. Input is already restricted
/// to the padded viewport; changing annotations never changes its camera.
#if canImport(UIKit)
import SwiftUI
import UIKit
struct SavedPinsMap: UIViewRepresentable {
    struct Pin: Equatable { let id: String, title: String, coordinate: ApplePlaceCoordinate }
    let viewport: SavedMapViewport
    let cameraRevision: UUID
    let pins: [Pin]
    let location: ApplePlaceCoordinate?
    let interactionBegan: () -> Void
    let moved: (SavedMapViewport, Bool) -> Void
    let clusterSelected: ([String]) -> Void
    let selected: (String) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(self) }
    func makeUIView(context: Context) -> MKMapView {
        let map = MKMapView(); map.delegate = context.coordinator
        map.register(MKMarkerAnnotationView.self, forAnnotationViewWithReuseIdentifier: "saved")
        map.register(MKMarkerAnnotationView.self, forAnnotationViewWithReuseIdentifier: "cluster")
        map.pointOfInterestFilter = .includingAll; map.isRotateEnabled = false
        context.coordinator.applyingCamera = true
        map.setRegion(viewport.region, animated: false)
        context.coordinator.cameraRevision = cameraRevision
        return map
    }
    func updateUIView(_ map: MKMapView, context: Context) {
        let coordinator = context.coordinator; coordinator.parent = self
        if coordinator.cameraRevision != cameraRevision {
            coordinator.cameraRevision = cameraRevision
            coordinator.applyingCamera = true
            map.setRegion(viewport.region, animated: false)
        }
        let oldLocations = map.annotations.compactMap { $0 as? LocationAnnotation }
        if oldLocations.first?.value != location {
            map.removeAnnotations(oldLocations)
            if let location { map.addAnnotation(LocationAnnotation(location)) }
        }
        let incoming = Dictionary(uniqueKeysWithValues: pins.map { ($0.id, $0) })
        let old = map.annotations.compactMap { $0 as? Annotation }
        map.removeAnnotations(old.filter { incoming[$0.pin.id] != $0.pin })
        let surviving = Set(old.filter { incoming[$0.pin.id] == $0.pin }.map { $0.pin.id })
        map.addAnnotations(pins.filter { !surviving.contains($0.id) }.map(Annotation.init))
    }
    static func dismantleUIView(_ map: MKMapView, coordinator: Coordinator) {
        map.delegate = nil; map.showsUserLocation = false; map.removeAnnotations(map.annotations)
    }
    final class Annotation: NSObject, MKAnnotation {
        let pin: Pin
        var coordinate: CLLocationCoordinate2D { pin.coordinate.clLocationCoordinate2D }
        var title: String? { pin.title }
        init(_ pin: Pin) { self.pin = pin }
    }
    final class LocationAnnotation: NSObject, MKAnnotation {
        let value: ApplePlaceCoordinate
        var coordinate: CLLocationCoordinate2D { value.clLocationCoordinate2D }
        var title: String? { "Your last requested location" }
        init(_ value: ApplePlaceCoordinate) { self.value = value }
    }
    final class Coordinator: NSObject, MKMapViewDelegate {
        var parent: SavedPinsMap
        var cameraRevision: UUID?
        var applyingCamera = false
        init(_ parent: SavedPinsMap) { self.parent = parent }
        func mapView(_ mapView: MKMapView, regionWillChangeAnimated animated: Bool) {
            func interacting(_ view: UIView) -> Bool {
                (view.gestureRecognizers ?? []).contains { $0.state == .began || $0.state == .changed }
                    || view.subviews.contains(where: interacting)
            }
            if !applyingCamera && interacting(mapView) { parent.interactionBegan() }
        }
        func mapView(_ mapView: MKMapView, regionDidChangeAnimated animated: Bool) {
            let viewport = SavedMapViewport(mapView.region)
            if viewport.isValid { parent.moved(viewport, !applyingCamera) }; applyingCamera = false
        }
        func mapView(_ mapView: MKMapView, viewFor annotation: MKAnnotation) -> MKAnnotationView? {
            if annotation is MKUserLocation { return nil }
            if annotation is LocationAnnotation {
                let view = MKMarkerAnnotationView(annotation: annotation, reuseIdentifier: nil)
                view.glyphImage = UIImage(systemName: "location.fill"); view.markerTintColor = .systemBlue
                view.accessibilityLabel = "Your last requested location"; return view
            }
            let cluster = annotation as? MKClusterAnnotation
            let view = mapView.dequeueReusableAnnotationView(withIdentifier: cluster == nil ? "saved" : "cluster", for: annotation) as! MKMarkerAnnotationView
            view.clusteringIdentifier = cluster == nil ? "saved-places" : nil
            view.markerTintColor = UIColor(FeastTheme.Colors.mapPinTint)
            view.canShowCallout = false
            view.glyphText = cluster.map { String($0.memberAnnotations.count) }
            view.titleVisibility = .adaptive
            view.accessibilityLabel = cluster.map { "\($0.memberAnnotations.count) saved places. Double tap to explore these places." } ?? annotation.title ?? "Saved place"
            return view
        }
        func mapView(_ mapView: MKMapView, didSelect view: MKAnnotationView) {
            guard let annotation = view.annotation else { return }
            defer { mapView.deselectAnnotation(annotation, animated: false) }
            if let cluster = annotation as? MKClusterAnnotation {
                let members = cluster.memberAnnotations.compactMap { $0 as? Annotation }
                if SavedMapPlan.clusterNeedsList(coordinates: members.map { $0.pin.coordinate }, latitudeDelta: mapView.region.span.latitudeDelta) {
                    parent.clusterSelected(members.map { $0.pin.id }.sorted()); return
                }
                // Explicit user action, never annotation arrival, changes the camera.
                parent.interactionBegan()
                var region = mapView.region; region.center = cluster.coordinate
                region.span.latitudeDelta = max(0.0005, region.span.latitudeDelta / 2)
                region.span.longitudeDelta = max(0.0005, region.span.longitudeDelta / 2)
                mapView.setRegion(region, animated: true)
            } else if let pin = annotation as? Annotation { parent.selected(pin.pin.id) }
        }
    }
}
#endif
