import Foundation
import MapKit
import SwiftUI

struct ApplePlaceCoordinate: Hashable {
    let latitude: Double
    let longitude: Double

    var clLocationCoordinate2D: CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
    }
}

struct ApplePlaceMatch: Identifiable, Hashable {
    let applePlaceID: String
    let displayName: String
    let secondaryText: String
    let coordinate: ApplePlaceCoordinate?
    let suggestedSectionPath: ApplePlaceSectionPathSuggestion

    var id: String { applePlaceID }
}

struct ApplePlaceSectionPathSuggestion: Hashable {
    let cityOrRegion: String?
    let neighborhood: String?

    var displayText: String? {
        let components = [cityOrRegion, neighborhood].compactMap { value in
            let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return trimmed.isEmpty ? nil : trimmed
        }

        guard !components.isEmpty else {
            return nil
        }

        return components.joined(separator: " • ")
    }
}

struct ApplePlacesService {
    private enum Mode {
        case live
        case preview
    }

    private let mode: Mode

    init() {
        self.mode = .live
    }

    private init(mode: Mode) {
        self.mode = mode
    }

    @MainActor
    func search(query: String) async throws -> [ApplePlaceMatch] {
        switch mode {
        case .live:
            let request = MKLocalSearch.Request(naturalLanguageQuery: query)
            request.resultTypes = .pointOfInterest

            let response = try await Self.startSearch(request: request)
            return response.mapItems.compactMap(Self.makeMatch(from:))
        case .preview:
            let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else {
                return []
            }

            return Self.previewMatches.filter { match in
                match.displayName.localizedCaseInsensitiveContains(trimmed)
                    || match.secondaryText.localizedCaseInsensitiveContains(trimmed)
            }
        }
    }

    @MainActor
    func resolve(placeID: String) async throws -> ApplePlaceMatch? {
        switch mode {
        case .live:
            guard let mapItem = try await Self.resolvedMapItem(for: placeID) else {
                return nil
            }
            return Self.makeMatch(from: mapItem)
        case .preview:
            return Self.previewMatches.first { $0.applePlaceID == placeID }
        }
    }

    @MainActor
    func openInMaps(placeID: String) async throws -> Bool {
        switch mode {
        case .live:
            guard let mapItem = try await Self.resolvedMapItem(for: placeID) else {
                return false
            }

            return mapItem.openInMaps(launchOptions: nil)
        case .preview:
            return false
        }
    }
}

extension ApplePlacesService {
    static let preview = ApplePlacesService(mode: .preview)

    private static let previewMatches: [ApplePlaceMatch] = [
        ApplePlaceMatch(
            applePlaceID: "applemaps-rolo-s-ridgewood",
            displayName: "Rolo's",
            secondaryText: "Ridgewood, Queens, NY",
            coordinate: ApplePlaceCoordinate(latitude: 40.7068, longitude: -73.9215),
            suggestedSectionPath: ApplePlaceSectionPathSuggestion(
                cityOrRegion: "Brooklyn",
                neighborhood: "Ridgewood"
            )
        ),
        ApplePlaceMatch(
            applePlaceID: "applemaps-dhamaka-les",
            displayName: "Dhamaka",
            secondaryText: "Lower East Side, New York, NY",
            coordinate: ApplePlaceCoordinate(latitude: 40.7180, longitude: -73.9897),
            suggestedSectionPath: ApplePlaceSectionPathSuggestion(
                cityOrRegion: "Manhattan",
                neighborhood: "Lower East Side"
            )
        ),
        ApplePlaceMatch(
            applePlaceID: "applemaps-librae-bakery",
            displayName: "Librae Bakery",
            secondaryText: "East Williamsburg, Brooklyn, NY",
            coordinate: ApplePlaceCoordinate(latitude: 40.7147, longitude: -73.9377),
            suggestedSectionPath: ApplePlaceSectionPathSuggestion(
                cityOrRegion: "Brooklyn",
                neighborhood: nil
            )
        ),
        ApplePlaceMatch(
            applePlaceID: "applemaps-bar-etoile-la",
            displayName: "Bar Etoile",
            secondaryText: "Los Angeles, CA",
            coordinate: ApplePlaceCoordinate(latitude: 34.0407, longitude: -118.2468),
            suggestedSectionPath: ApplePlaceSectionPathSuggestion(
                cityOrRegion: "California",
                neighborhood: "Los Angeles"
            )
        ),
        ApplePlaceMatch(
            applePlaceID: "applemaps-koffee-mameya-kakeru",
            displayName: "Koffee Mameya Kakeru",
            secondaryText: "Shibuya, Tokyo",
            coordinate: ApplePlaceCoordinate(latitude: 35.6595, longitude: 139.7005),
            suggestedSectionPath: ApplePlaceSectionPathSuggestion(
                cityOrRegion: "Tokyo",
                neighborhood: "Shibuya"
            )
        )
    ]

    @MainActor
    private static func startSearch(request: MKLocalSearch.Request) async throws -> MKLocalSearch.Response {
        try await withCheckedThrowingContinuation { continuation in
            let search = MKLocalSearch(request: request)
            search.start { response, error in
                if let response {
                    continuation.resume(returning: response)
                } else {
                    continuation.resume(throwing: error ?? ApplePlacesError.searchFailed)
                }
            }
        }
    }

    @MainActor
    private static func mapItem(for request: MKMapItemRequest) async throws -> MKMapItem {
        try await withCheckedThrowingContinuation { continuation in
            request.getMapItem { mapItem, error in
                if let mapItem {
                    continuation.resume(returning: mapItem)
                } else {
                    continuation.resume(throwing: error ?? ApplePlacesError.resolveFailed)
                }
            }
        }
    }

    @MainActor
    private static func resolvedMapItem(for applePlaceID: String) async throws -> MKMapItem? {
        guard let identifier = MKMapItem.Identifier(rawValue: applePlaceID) else {
            return nil
        }

        let request = MKMapItemRequest(mapItemIdentifier: identifier)
        return try await mapItem(for: request)
    }

    nonisolated private static func makeMatch(from mapItem: MKMapItem) -> ApplePlaceMatch? {
        guard let applePlaceID = mapItem.identifier?.rawValue else {
            return nil
        }

        let displayName = normalized(mapItem.name) ?? "Unnamed Place"
        let secondaryText = normalized(mapItem.address?.shortAddress)
            ?? normalized(mapItem.address?.fullAddress)
            ?? ""

        return ApplePlaceMatch(
            applePlaceID: applePlaceID,
            displayName: displayName,
            secondaryText: secondaryText,
            coordinate: coordinate(from: mapItem),
            suggestedSectionPath: ApplePlaceSectionPathSuggestion(
                cityOrRegion: suggestedCityOrRegion(from: mapItem),
                neighborhood: suggestedNeighborhood(from: mapItem)
            )
        )
    }

    nonisolated private static func coordinate(from mapItem: MKMapItem) -> ApplePlaceCoordinate? {
        let coordinate = mapItem.location.coordinate
        guard CLLocationCoordinate2DIsValid(coordinate) else {
            return nil
        }

        return ApplePlaceCoordinate(
            latitude: coordinate.latitude,
            longitude: coordinate.longitude
        )
    }

    nonisolated private static func suggestedCityOrRegion(from mapItem: MKMapItem) -> String? {
        normalized(mapItem.placemark.locality)
            ?? normalized(mapItem.addressRepresentations?.cityName)
            ?? normalized(mapItem.placemark.subAdministrativeArea)
            ?? normalized(mapItem.placemark.administrativeArea)
    }

    nonisolated private static func suggestedNeighborhood(from mapItem: MKMapItem) -> String? {
        normalized(mapItem.placemark.subLocality)
    }

    nonisolated private static func normalized(_ value: String?) -> String? {
        guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else {
            return nil
        }

        return trimmed
    }
}

private enum ApplePlacesError: LocalizedError {
    case searchFailed
    case resolveFailed

    var errorDescription: String? {
        switch self {
        case .searchFailed:
            return "Apple Maps search failed."
        case .resolveFailed:
            return "Apple Maps could not resolve this place."
        }
    }
}

private struct ApplePlacesServiceKey: EnvironmentKey {
    static let defaultValue: ApplePlacesService = .preview
}

extension EnvironmentValues {
    var applePlacesService: ApplePlacesService {
        get { self[ApplePlacesServiceKey.self] }
        set { self[ApplePlacesServiceKey.self] = newValue }
    }
}
