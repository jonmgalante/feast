import Foundation
import MapKit
import SwiftUI
import os

struct ApplePlaceCoordinate: Hashable {
    let latitude: Double
    let longitude: Double

    nonisolated var clLocationCoordinate2D: CLLocationCoordinate2D {
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
    nonisolated private static let logger = Logger(subsystem: "com.jongalante.Feast", category: "ApplePlaces")

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
        let cityOrRegion = suggestedCityOrRegion(from: mapItem)
        let neighborhoodContext = NeighborhoodSuggestionContext(
            displayName: displayName,
            cityOrRegion: cityOrRegion,
            locality: normalized(mapItem.placemark.locality),
            subAdministrativeArea: normalized(mapItem.placemark.subAdministrativeArea),
            administrativeArea: normalized(mapItem.placemark.administrativeArea),
            country: normalized(mapItem.placemark.country),
            isoCountryCode: normalized(mapItem.placemark.isoCountryCode),
            postalCode: normalized(mapItem.placemark.postalCode)
        )
        let neighborhood = suggestedNeighborhood(
            from: mapItem,
            context: neighborhoodContext
        )
        let urlAutofill = classifiedPlaceURL(from: mapItem.url)

        return ApplePlaceMatch(
            applePlaceID: applePlaceID,
            displayName: displayName,
            secondaryText: secondaryText,
            coordinate: coordinate(from: mapItem),
            suggestedSectionPath: ApplePlaceSectionPathSuggestion(
                cityOrRegion: cityOrRegion,
                neighborhood: neighborhood
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

    nonisolated private static func suggestedNeighborhood(
        from mapItem: MKMapItem,
        context: NeighborhoodSuggestionContext
    ) -> String? {
        let coordinateResolutionAttempted = coordinate(from: mapItem) != nil
        let coordinateResolution = coordinateResolvedNeighborhood(from: mapItem)
        let candidates = neighborhoodCandidates(
            from: mapItem,
            context: context,
            coordinateResolution: coordinateResolution
        )

        let selectedCandidate = candidates
            .lazy
            .compactMap { candidate -> (source: String, neighborhood: String)? in
                guard let neighborhood = FeastNeighborhoodName.trustworthyNeighborhood(
                    from: candidate.value,
                    rejectedContextNames: context.rejectedContextNames
                ) else {
                    return nil
                }

                return (source: candidate.source, neighborhood: neighborhood)
            }
            .first

        #if DEBUG
        logger.debug(
            """
            Add Place neighborhood suggestion \
            name=\(context.displayName, privacy: .public) \
            city=\(context.cityOrRegion ?? "nil", privacy: .public) \
            coordinateResolverAttempted=\(coordinateResolutionAttempted ? "true" : "false", privacy: .public) \
            coordinateResolverDataset=\(coordinateResolution?.datasetName ?? "nil", privacy: .public) \
            coordinateResolverMatch=\(coordinateResolution?.displayName ?? "nil", privacy: .public) \
            subLocality=\(normalized(mapItem.placemark.subLocality) ?? "nil", privacy: .public) \
            areasOfInterest=\(joinedDebugValues(mapItem.placemark.areasOfInterest), privacy: .public) \
            shortAddress=\(normalized(mapItem.address?.shortAddress) ?? "nil", privacy: .public) \
            fullAddress=\(normalized(mapItem.address?.fullAddress) ?? "nil", privacy: .public) \
            administrativeArea=\(context.administrativeArea ?? "nil", privacy: .public) \
            subAdministrativeArea=\(context.subAdministrativeArea ?? "nil", privacy: .public) \
            country=\(context.country ?? "nil", privacy: .public) \
            isoCountryCode=\(context.isoCountryCode ?? "nil", privacy: .public) \
            postalCode=\(context.postalCode ?? "nil", privacy: .public) \
            candidates=\(joinedCandidateDebugValues(candidates), privacy: .public) \
            chosenSource=\(selectedCandidate?.source ?? "nil", privacy: .public) \
            chosenNeighborhood=\(selectedCandidate?.neighborhood ?? "nil", privacy: .public)
            """
        )
        #endif

        return selectedCandidate?.neighborhood
    }

    nonisolated private static func coordinateResolvedNeighborhood(
        from mapItem: MKMapItem
    ) -> NeighborhoodBoundaryMatch? {
        guard let coordinate = coordinate(from: mapItem)?.clLocationCoordinate2D else {
            return nil
        }

        return NeighborhoodBoundaryResolver.resolveNeighborhood(at: coordinate)
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

    nonisolated private static func neighborhoodCandidates(
        from mapItem: MKMapItem,
        context: NeighborhoodSuggestionContext,
        coordinateResolution: NeighborhoodBoundaryMatch?
    ) -> [NeighborhoodSuggestionCandidate] {
        var candidates: [NeighborhoodSuggestionCandidate] = []
        var seenKeys: Set<String> = []

        appendNeighborhoodCandidate(
            coordinateResolution?.displayName,
            source: coordinateResolution?.source ?? "coordinateResolver",
            seenKeys: &seenKeys,
            to: &candidates
        )
        appendNeighborhoodCandidate(
            normalized(mapItem.placemark.subLocality),
            source: "placemark.subLocality",
            seenKeys: &seenKeys,
            to: &candidates
        )
        appendNeighborhoodCandidates(
            mapItem.placemark.areasOfInterest,
            source: "placemark.areasOfInterest",
            seenKeys: &seenKeys,
            to: &candidates
        )
        appendNeighborhoodCandidates(
            fromAddress: mapItem.address?.shortAddress,
            source: "address.shortAddress",
            context: context,
            seenKeys: &seenKeys,
            to: &candidates
        )
        appendNeighborhoodCandidates(
            fromAddress: mapItem.address?.fullAddress,
            source: "address.fullAddress",
            context: context,
            seenKeys: &seenKeys,
            to: &candidates
        )

        return candidates
    }

    nonisolated private static func appendNeighborhoodCandidates(
        _ rawValues: [String]?,
        source: String,
        seenKeys: inout Set<String>,
        to candidates: inout [NeighborhoodSuggestionCandidate]
    ) {
        for rawValue in rawValues ?? [] {
            appendNeighborhoodCandidate(
                rawValue,
                source: source,
                seenKeys: &seenKeys,
                to: &candidates
            )
        }
    }

    nonisolated private static func appendNeighborhoodCandidates(
        fromAddress rawAddress: String?,
        source: String,
        context: NeighborhoodSuggestionContext,
        seenKeys: inout Set<String>,
        to candidates: inout [NeighborhoodSuggestionCandidate]
    ) {
        for component in addressComponents(from: rawAddress)
        where !looksLikeStreetAddress(component)
            && !isAdministrativeOrCountryComponent(component, context: context)
        {
            appendNeighborhoodCandidate(
                component,
                source: source,
                seenKeys: &seenKeys,
                to: &candidates
            )
        }
    }

    nonisolated private static func appendNeighborhoodCandidate(
        _ rawValue: String?,
        source: String,
        seenKeys: inout Set<String>,
        to candidates: inout [NeighborhoodSuggestionCandidate]
    ) {
        guard
            let value = normalized(rawValue),
            let key = FeastNeighborhoodName.normalizedKey(for: value),
            !seenKeys.contains(key)
        else {
            return
        }

        seenKeys.insert(key)
        candidates.append(
            NeighborhoodSuggestionCandidate(
                source: source,
                value: value
            )
        )
    }

    nonisolated private static func addressComponents(from rawAddress: String?) -> [String] {
        guard let rawAddress = normalized(rawAddress) else {
            return []
        }

        let separators = CharacterSet(charactersIn: ",\n")
        return rawAddress
            .components(separatedBy: separators)
            .compactMap(normalized)
    }

    nonisolated private static func isAdministrativeOrCountryComponent(
        _ value: String,
        context: NeighborhoodSuggestionContext
    ) -> Bool {
        if isPostalCodeOnly(value) {
            return true
        }

        if looksLikeAdministrativeCode(value) {
            return true
        }

        if
            let key = FeastNeighborhoodName.normalizedKey(for: value),
            countryKeys.contains(key)
        {
            return true
        }

        return context.rejectedContextNames.contains { rejectedValue in
            FeastNeighborhoodName.matches(value, rejectedValue)
        }
    }

    nonisolated private static func isPostalCodeOnly(_ value: String) -> Bool {
        let compactValue = value
            .components(separatedBy: CharacterSet.whitespacesAndNewlines.union(.punctuationCharacters))
            .joined()

        guard !compactValue.isEmpty else {
            return false
        }

        let alphanumerics = compactValue.unicodeScalars.filter {
            CharacterSet.alphanumerics.contains($0)
        }

        guard !alphanumerics.isEmpty else {
            return false
        }

        return alphanumerics.allSatisfy { CharacterSet.decimalDigits.contains($0) }
    }

    nonisolated private static func looksLikeAdministrativeCode(_ value: String) -> Bool {
        let compactValue = value
            .components(separatedBy: CharacterSet.whitespacesAndNewlines.union(.punctuationCharacters))
            .joined()

        guard compactValue.count == 2 else {
            return false
        }

        let letters = compactValue.unicodeScalars.filter {
            CharacterSet.letters.contains($0)
        }

        return letters.count == 2
    }

    nonisolated private static func looksLikeStreetAddress(_ value: String) -> Bool {
        if value.rangeOfCharacter(from: .decimalDigits) != nil {
            return true
        }

        let tokens = value
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }

        return tokens.contains(where: { streetAddressTokens.contains($0) })
    }

    nonisolated private static func joinedDebugValues(_ rawValues: [String]?) -> String {
        let values = (rawValues ?? []).compactMap(normalized)
        guard !values.isEmpty else {
            return "nil"
        }

        return values.joined(separator: " | ")
    }

    nonisolated private static func joinedCandidateDebugValues(
        _ candidates: [NeighborhoodSuggestionCandidate]
    ) -> String {
        guard !candidates.isEmpty else {
            return "nil"
        }

        return candidates.map { "\($0.source):\($0.value)" }.joined(separator: " | ")
    }

    nonisolated private static let streetAddressTokens: Set<String> = [
        "ave",
        "avenue",
        "blvd",
        "boulevard",
        "court",
        "ct",
        "drive",
        "dr",
        "highway",
        "hwy",
        "lane",
        "ln",
        "parkway",
        "pkwy",
        "road",
        "rd",
        "street",
        "st",
        "terrace",
        "ter",
        "trail",
        "trl",
        "way"
    ]

    nonisolated private static let countryKeys: Set<String> = {
        let locales = [
            Locale(identifier: "en_US_POSIX"),
            Locale.current
        ]
        var keys: Set<String> = []

        for regionCode in Locale.isoRegionCodes {
            if let key = FeastNeighborhoodName.normalizedKey(for: regionCode) {
                keys.insert(key)
            }

            for locale in locales {
                guard
                    let countryName = locale.localizedString(forRegionCode: regionCode),
                    let key = FeastNeighborhoodName.normalizedKey(for: countryName)
                else {
                    continue
                }

                keys.insert(key)
            }
        }

        keys.formUnion([
            "united states",
            "united states of america",
            "us",
            "usa"
        ])

        return keys
    }()
}

private struct ClassifiedPlaceURL {
    let websiteURL: String?
    let instagramURL: String?
}

private struct NeighborhoodSuggestionCandidate {
    let source: String
    let value: String
}

private struct NeighborhoodSuggestionContext {
    let displayName: String
    let cityOrRegion: String?
    let locality: String?
    let subAdministrativeArea: String?
    let administrativeArea: String?
    let country: String?
    let isoCountryCode: String?
    let postalCode: String?

    nonisolated var rejectedContextNames: [String] {
        [
            displayName,
            cityOrRegion,
            locality,
            subAdministrativeArea,
            administrativeArea,
            country,
            isoCountryCode,
            postalCode
        ]
        .compactMap { $0 }
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
