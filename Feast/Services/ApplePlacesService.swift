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
    let websiteURL: String?
    let instagramURL: String?

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

            let queryTokens = Self.searchTokens(from: trimmed)
            let rankedMatches = Self.previewMatches
                .compactMap { match -> (match: ApplePlaceMatch, score: Int)? in
                    let searchableText = [
                        match.displayName,
                        match.secondaryText,
                        match.suggestedSectionPath.cityOrRegion,
                        match.suggestedSectionPath.neighborhood
                    ]
                    .compactMap { $0 }
                    .joined(separator: " ")

                    let searchableTokens = Self.searchTokens(from: searchableText)
                    let sharedTokenCount = queryTokens.intersection(searchableTokens).count

                    guard sharedTokenCount > 0 else {
                        return nil
                    }

                    let score = sharedTokenCount * 20
                        + (match.displayName.localizedCaseInsensitiveContains(trimmed) ? 12 : 0)
                        + (match.secondaryText.localizedCaseInsensitiveContains(trimmed) ? 8 : 0)

                    return (match, score)
                }
                .sorted { lhs, rhs in
                    if lhs.score != rhs.score {
                        return lhs.score > rhs.score
                    }

                    return lhs.match.displayName.localizedCaseInsensitiveCompare(rhs.match.displayName) == .orderedAscending
                }

            return rankedMatches.map { $0.match }
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
                cityOrRegion: "NYC",
                neighborhood: "Ridgewood"
            ),
            websiteURL: nil,
            instagramURL: nil
        ),
        ApplePlaceMatch(
            applePlaceID: "applemaps-dhamaka-les",
            displayName: "Dhamaka",
            secondaryText: "Lower East Side, New York, NY",
            coordinate: ApplePlaceCoordinate(latitude: 40.7180, longitude: -73.9897),
            suggestedSectionPath: ApplePlaceSectionPathSuggestion(
                cityOrRegion: "NYC",
                neighborhood: "Lower East Side"
            ),
            websiteURL: nil,
            instagramURL: nil
        ),
        ApplePlaceMatch(
            applePlaceID: "applemaps-librae-bakery",
            displayName: "Librae Bakery",
            secondaryText: "East Williamsburg, Brooklyn, NY",
            coordinate: ApplePlaceCoordinate(latitude: 40.7147, longitude: -73.9377),
            suggestedSectionPath: ApplePlaceSectionPathSuggestion(
                cityOrRegion: "NYC",
                neighborhood: "East Williamsburg"
            ),
            websiteURL: nil,
            instagramURL: nil
        ),
        ApplePlaceMatch(
            applePlaceID: "applemaps-st-john-soho",
            displayName: "St. JOHN",
            secondaryText: "Soho, London",
            coordinate: ApplePlaceCoordinate(latitude: 51.5146, longitude: -0.1357),
            suggestedSectionPath: ApplePlaceSectionPathSuggestion(
                cityOrRegion: "London",
                neighborhood: "Soho"
            ),
            websiteURL: nil,
            instagramURL: nil
        ),
        ApplePlaceMatch(
            applePlaceID: "applemaps-middle-child-clubhouse",
            displayName: "Middle Child Clubhouse",
            secondaryText: "Fishtown, Philadelphia, PA",
            coordinate: ApplePlaceCoordinate(latitude: 39.9692, longitude: -75.1336),
            suggestedSectionPath: ApplePlaceSectionPathSuggestion(
                cityOrRegion: "Philadelphia",
                neighborhood: "Fishtown"
            ),
            websiteURL: nil,
            instagramURL: nil
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
        let urlAutofill = classifiedPlaceURL(from: mapItem.url)

        return ApplePlaceMatch(
            applePlaceID: applePlaceID,
            displayName: displayName,
            secondaryText: secondaryText,
            coordinate: coordinate(from: mapItem),
            suggestedSectionPath: ApplePlaceSectionPathSuggestion(
                cityOrRegion: suggestedCityOrRegion(from: mapItem),
                neighborhood: suggestedNeighborhood(from: mapItem)
            ),
            websiteURL: urlAutofill.websiteURL,
            instagramURL: urlAutofill.instagramURL
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

    nonisolated private static func classifiedPlaceURL(from url: URL?) -> ClassifiedPlaceURL {
        guard
            let url,
            let scheme = url.scheme?.lowercased(),
            scheme == "http" || scheme == "https",
            let host = normalizedHost(for: url)
        else {
            return ClassifiedPlaceURL(websiteURL: nil, instagramURL: nil)
        }

        let absoluteString = url.absoluteString
        if isInstagramHost(host) {
            return ClassifiedPlaceURL(websiteURL: nil, instagramURL: absoluteString)
        }

        return ClassifiedPlaceURL(websiteURL: absoluteString, instagramURL: nil)
    }

    nonisolated private static func normalizedHost(for url: URL) -> String? {
        guard let host = url.host?.trimmingCharacters(in: CharacterSet(charactersIn: ".")), !host.isEmpty else {
            return nil
        }

        return host.lowercased()
    }

    nonisolated private static func isInstagramHost(_ host: String) -> Bool {
        host == "instagram.com"
            || host.hasSuffix(".instagram.com")
            || host == "instagr.am"
            || host.hasSuffix(".instagr.am")
    }

    nonisolated private static func searchTokens(from rawValue: String) -> Set<String> {
        let folded = rawValue.folding(
            options: [.caseInsensitive, .diacriticInsensitive],
            locale: .current
        )

        let normalized = folded.unicodeScalars.map { scalar -> Character in
            if CharacterSet.alphanumerics.contains(scalar) {
                return Character(scalar)
            }

            return " "
        }

        return Set(
            String(normalized)
                .split(whereSeparator: \.isWhitespace)
                .map(String.init)
        )
    }
}

private struct ClassifiedPlaceURL {
    let websiteURL: String?
    let instagramURL: String?
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
