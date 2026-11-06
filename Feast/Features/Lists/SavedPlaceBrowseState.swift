import CoreData
import Foundation
import Combine

struct SavedPlaceSearchFilters: Equatable {
    var selectedListURIString: String?
    var queryText = ""
    var selectedStatuses: Set<PlaceStatus> = []
    var selectedTags: Set<String> = []
    var selectedPlaceType: PlaceType?
    var selectedCuisine: String?

    var hasActiveFilters: Bool {
        selectedListURIString != nil
            || hasCriteria

    }

    var hasCriteria: Bool {
        !queryText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !selectedStatuses.isEmpty ||
            !selectedTags.isEmpty || selectedPlaceType != nil || selectedCuisine != nil
    }

    var hasContentFilters: Bool {
        !selectedStatuses.isEmpty || !selectedTags.isEmpty || selectedPlaceType != nil || selectedCuisine != nil
    }

    mutating func clearFiltersKeepingScopeAndQuery() {
        let scope = selectedListURIString, query = queryText
        self = .init()
        selectedListURIString = scope
        queryText = query
    }

    var summary: String? {
        var values: [String] = []
        if !selectedStatuses.isEmpty { values.append(selectedStatuses.map(\.rawValue).sorted().joined(separator: ", ")) }
        if let selectedPlaceType { values.append(selectedPlaceType.rawValue) }
        if let selectedCuisine { values.append(selectedCuisine) }
        if !selectedTags.isEmpty { values.append(selectedTags.sorted().joined(separator: ", ")) }
        return values.isEmpty ? nil : values.joined(separator: " • ")
    }

    func activeFilterCount(usingFixedListScope: Bool) -> Int {
        [!selectedStatuses.isEmpty, !selectedTags.isEmpty, selectedPlaceType != nil, selectedCuisine != nil].filter { $0 }.count
    }

    mutating func reset() {
        let city = selectedListURIString
        self = .init()
        selectedListURIString = city
    }

}

enum SavedPlaceSearchEngine {
    static func matchingPlaceIDs(from places: [SavedPlace], filters: SavedPlaceSearchFilters) -> Set<NSManagedObjectID> {
        Set(filteredPlaces(from: places, query: filters.queryText, filters: filters).map(\.objectID))
    }

    static func mappedPlaceIDs(from places: [SavedPlace], filters: SavedPlaceSearchFilters, resolvedIDs: Set<NSManagedObjectID>) -> Set<NSManagedObjectID> {
        matchingPlaceIDs(from: places, filters: filters).intersection(resolvedIDs)
    }

    static func filteredPlaces(
        from places: [SavedPlace],
        query: String,
        filters: SavedPlaceSearchFilters,
        fixedFeastList: FeastList? = nil
    ) -> [SavedPlace] {
        let queryTokens = normalizedTokens(in: query)

        return places
            .filter { place in
                matchesListScope(place, filters: filters, fixedFeastList: fixedFeastList)
                    && matchesFilters(place, filters: filters)
                    && matchesQuery(place, queryTokens: queryTokens)
            }
            .sorted { lhs, rhs in
                lhs.updatedAtValue > rhs.updatedAtValue
            }
    }

    static func availableCuisines(
        from places: [SavedPlace],
        filters: SavedPlaceSearchFilters = .init(),
        fixedFeastList: FeastList? = nil
    ) -> [String] {
        let scopedPlaces = places.filter {
            matchesListScope($0, filters: filters, fixedFeastList: fixedFeastList)
        }

        var deduplicated: [String: String] = [:]

        for cuisine in scopedPlaces.flatMap(\.cuisines) {
            let trimmed = cuisine.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else {
                continue
            }

            let key = trimmed.folding(
                options: [.caseInsensitive, .diacriticInsensitive],
                locale: .current
            )

            if deduplicated[key] == nil {
                deduplicated[key] = trimmed
            }
        }

        return deduplicated.values.sorted {
            $0.localizedCaseInsensitiveCompare($1) == .orderedAscending
        }
    }

    private static func matchesListScope(
        _ place: SavedPlace,
        filters: SavedPlaceSearchFilters,
        fixedFeastList: FeastList?
    ) -> Bool {
        if let fixedFeastList {
            return place.feastList?.objectID == fixedFeastList.objectID
        }

        guard let selectedListURIString = filters.selectedListURIString else {
            return true
        }

        return place.feastList?.objectURIString == selectedListURIString
    }

    private static func matchesFilters(_ place: SavedPlace, filters: SavedPlaceSearchFilters) -> Bool {
        if !filters.selectedStatuses.isEmpty, !filters.selectedStatuses.contains(place.placeStatus) {
            return false
        }

        let tagKeys = Set(filters.selectedTags.compactMap { FeastTag.normalizedKey(for: $0) })
        if !tagKeys.isEmpty, !place.tags.contains(where: { tagKeys.contains(FeastTag.normalizedKey(for: $0) ?? "") }) { return false }

        if let selectedPlaceType = filters.selectedPlaceType, place.placeTypeValue != selectedPlaceType {
            return false
        }

        if let selectedCuisine = normalized(filters.selectedCuisine),
           !place.cuisines.contains(where: { matches($0, selectedCuisine) }) {
            return false
        }

        return true
    }

    private static func matchesQuery(_ place: SavedPlace, queryTokens: [String]) -> Bool {
        guard !queryTokens.isEmpty else {
            return true
        }

        let searchableText = searchableFields(for: place)
            .joined(separator: " ")
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)

        return queryTokens.allSatisfy { searchableText.contains($0) }
    }

    private static func searchableFields(for place: SavedPlace) -> [String] {
        [
            place.displayName,
            place.displayCityName,
            place.displayNeighborhoodName,
            place.placeStatus.rawValue,
            place.placeTypeValue.rawValue,
            place.note,
            place.websiteURL,
            place.instagramURL
        ]
        .compactMap { normalized($0) }
        + place.cuisines
        + place.tags
    }

    private static func normalizedTokens(in query: String) -> [String] {
        query
            .split(whereSeparator: \.isWhitespace)
            .map(String.init)
            .compactMap { token in
                normalized(token)
            }
    }

    private static func normalized(_ value: String?) -> String? {
        guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else {
            return nil
        }

        return trimmed.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
    }

    private static func matches(_ lhs: String, _ rhs: String) -> Bool {
        lhs.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            == rhs.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
    }
}


enum SavedPlaceEmptyReason: Equatable {
    case emptyScope
    case queryHasNoMatches
    case filtersHideMatches
    case hasMatches

    static func evaluate(places: [SavedPlace], filters: SavedPlaceSearchFilters, fixedCity: FeastList? = nil) -> Self {
        var scopeOnly = SavedPlaceSearchFilters()
        scopeOnly.selectedListURIString = filters.selectedListURIString
        guard !SavedPlaceSearchEngine.filteredPlaces(from: places, query: "", filters: scopeOnly, fixedFeastList: fixedCity).isEmpty else { return .emptyScope }
        guard SavedPlaceSearchEngine.filteredPlaces(from: places, query: filters.queryText, filters: filters, fixedFeastList: fixedCity).isEmpty else { return .hasMatches }
        var queryOnly = filters
        queryOnly.clearFiltersKeepingScopeAndQuery()
        if SavedPlaceSearchEngine.filteredPlaces(from: places, query: queryOnly.queryText, filters: queryOnly, fixedFeastList: fixedCity).isEmpty {
            return .queryHasNoMatches
        }
        return .filtersHideMatches
    }
}

enum SavedMapEmptyPresentation: Equatable {
    case savedContent(SavedPlaceEmptyReason)
    case loading
    case locationsUnavailable
    case hasPins

    static func evaluate(reason: SavedPlaceEmptyReason, resolving: Bool, pinCount: Int) -> Self {
        if reason != .hasMatches { return .savedContent(reason) }
        if pinCount > 0 { return .hasPins }
        return resolving ? .loading : .locationsUnavailable
    }
}

enum SavedPlaceBrowseRoute: Hashable {
    case city(String)
    case place(String)
    var isPlace: Bool { if case .place = self { return true }; return false }
}

struct SavedMapViewport: Equatable {
    let latitude: Double
    let longitude: Double
    let latitudeDelta: Double
    let longitudeDelta: Double
}

@MainActor final class SavedPlaceBrowseState: ObservableObject {
    @Published var filters = SavedPlaceSearchFilters()
    @Published var selectedTab = 0
    @Published var citiesPath: [SavedPlaceBrowseRoute] = []
    @Published var showingCityFilters = false
    var scrollAnchors: [String: String] = [:]
    var viewports: [String: SavedMapViewport] = [:]
    private var hasEnteredMap = false

    /// Consume before requesting permission, so task restarts and denied fixes
    /// cannot repeat the first-entry request. A remembered map camera wins.
    func consumeInitialNearbyRequest() -> Bool {
        guard selectedTab == 1, !hasEnteredMap else { return false }
        hasEnteredMap = true
        return viewports[scopeKey] == nil
    }
    /// A location fix may change only the current map viewport, never content scope.
    @discardableResult func rememberNearbyViewport(_ viewport: SavedMapViewport, requestedScope: String) -> Bool {
        guard selectedTab == 1, scopeKey == requestedScope else { return false }
        viewports[scopeKey] = viewport
        return true
    }
    /// Native map initialization can report a region before any camera intent.
    /// Only the currently displayed scope may turn such callbacks into memory.
    @discardableResult func rememberDisplayedMapViewport(_ viewport: SavedMapViewport, displayedScope: String?) -> Bool {
        guard displayedScope == scopeKey else { return false }
        return rememberNearbyViewport(viewport, requestedScope: scopeKey)
    }
    var scopeKey: String { filters.selectedListURIString ?? "all-cities" }

    func scopeDidChange() {
        // The root sheet edits shared filters immediately. Keep its presenter
        // in place until dismissal, then reconcile navigation to the live city.
        guard !showingCityFilters, !citiesPath.contains(where: \.isPlace) else { return }
        let desired = filters.selectedListURIString.map { [SavedPlaceBrowseRoute.city($0)] } ?? []
        if citiesPath != desired { citiesPath = desired }
    }

    func pathDidChange(from previous: [SavedPlaceBrowseRoute]) {
        guard !showingCityFilters, !citiesPath.contains(where: \.isPlace) else { return }
        if previous.contains(where: \.isPlace) { scopeDidChange(); return }
        if case let .city(uri) = citiesPath.last { filters.selectedListURIString = uri }
        else { filters.selectedListURIString = nil }
    }

    func validateCities(_ validURIs: Set<String>) {
        if let selected = filters.selectedListURIString, !validURIs.contains(selected) {
            filters.selectedListURIString = nil
            scopeDidChange()
        }
    }
}
