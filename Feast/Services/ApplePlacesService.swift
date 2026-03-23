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
    private let searchHandler: @Sendable (String) async throws -> [ApplePlaceMatch]
    private let resolveHandler: @Sendable (String) async throws -> ApplePlaceMatch?
    private let openInMapsHandler: @Sendable (String) async throws -> Bool

    init(
        searchHandler: @escaping @Sendable (String) async throws -> [ApplePlaceMatch],
        resolveHandler: @escaping @Sendable (String) async throws -> ApplePlaceMatch?,
        openInMapsHandler: @escaping @Sendable (String) async throws -> Bool
    ) {
        self.searchHandler = searchHandler
        self.resolveHandler = resolveHandler
        self.openInMapsHandler = openInMapsHandler
    }

    func searchPlaces(matching query: String) async throws -> [ApplePlaceMatch] {
        try await searchHandler(query)
    }

    func resolvePlace(applePlaceID: String) async throws -> ApplePlaceMatch? {
        try await resolveHandler(applePlaceID)
    }

    func openInMaps(applePlaceID: String) async throws -> Bool {
        try await openInMapsHandler(applePlaceID)
    }
}

extension ApplePlacesService {
    static let live = ApplePlacesService(
        searchHandler: { query in
            let request = MKLocalSearch.Request()
            request.naturalLanguageQuery = query
            request.resultTypes = .pointOfInterest

            let response = try await startSearch(request: request)
            return response.mapItems.compactMap(makeMatch(from:))
        },
        resolveHandler: { applePlaceID in
            guard let mapItem = try await resolvedMapItem(for: applePlaceID) else {
                return nil
            }
            return makeMatch(from: mapItem)
        },
        openInMapsHandler: { applePlaceID in
            guard let mapItem = try await resolvedMapItem(for: applePlaceID) else {
                return false
            }

            return mapItem.openInMaps(launchOptions: nil)
        }
    )

    static let preview = ApplePlacesService(
        searchHandler: { query in
            let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else {
                return []
            }

            return previewMatches.filter { match in
                match.displayName.localizedCaseInsensitiveContains(trimmed)
                    || match.secondaryText.localizedCaseInsensitiveContains(trimmed)
            }
        },
        resolveHandler: { applePlaceID in
            previewMatches.first { $0.applePlaceID == applePlaceID }
        },
        openInMapsHandler: { _ in
            false
        }
    )

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

    nonisolated private static func startSearch(request: MKLocalSearch.Request) async throws -> MKLocalSearch.Response {
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

    nonisolated private static func mapItem(for request: MKMapItemRequest) async throws -> MKMapItem {
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

    nonisolated private static func resolvedMapItem(for applePlaceID: String) async throws -> MKMapItem? {
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
