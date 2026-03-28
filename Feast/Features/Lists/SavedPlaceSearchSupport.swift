import CoreData
import SwiftUI

struct SavedPlaceSearchFilters: Equatable {
    var selectedListURIString: String?
    var selectedStatus: PlaceStatus?
    var selectedPlaceType: PlaceType?
    var selectedCuisine: String?

    var hasActiveFilters: Bool {
        selectedListURIString != nil
            || selectedStatus != nil
            || selectedPlaceType != nil
            || selectedCuisine != nil
    }

    func activeFilterCount(usingFixedListScope hasFixedListScope: Bool) -> Int {
        [
            hasFixedListScope ? nil : selectedListURIString,
            selectedStatus?.rawValue,
            selectedPlaceType?.rawValue,
            selectedCuisine
        ]
        .compactMap { $0 }
        .count
    }

    mutating func reset() {
        self = .init()
    }
}

enum SavedPlaceSearchEngine {
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
        if let selectedStatus = filters.selectedStatus, place.placeStatus != selectedStatus {
            return false
        }

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

struct SavedPlaceFilterSheet: View {
    @Environment(\.dismiss) private var dismiss

    @Binding var filters: SavedPlaceSearchFilters

    let availableLists: [FeastList]
    let availableCuisines: [String]
    let fixedFeastList: FeastList?

    var body: some View {
        List {
            scopeSection
            statusSection
            placeTypeSection
            cuisineSection
        }
        .feastScrollableChrome()
        .listStyle(.insetGrouped)
        .navigationTitle("Filters")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Reset") {
                    filters.reset()
                }
                .disabled(!filters.hasActiveFilters)
            }

            ToolbarItem(placement: .confirmationAction) {
                Button {
                    dismiss()
                } label: {
                    Text("Done")
                        .fontWeight(.semibold)
                }
            }
        }
    }

    @ViewBuilder
    private var scopeSection: some View {
        if let fixedFeastList {
            Section {
                FeastFormGroup {
                    FeastFormField(
                        title: "City",
                        helper: "Search is already scoped to this city."
                    ) {
                        Text(fixedFeastList.displayName)
                            .font(FeastTheme.Typography.supporting.weight(.semibold))
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .feastFieldSurface(minHeight: 52)
                    }
                }
            } header: {
                FeastFormSectionHeader(
                    title: "Scope",
                    subtitle: "These filters only affect the current city"
                )
            }
        } else {
            Section {
                FeastFormGroup {
                    FeastFormField(
                        title: "City",
                        helper: "Choose which city to search."
                    ) {
                        Picker("City", selection: $filters.selectedListURIString) {
                            Text("All Cities").tag(nil as String?)

                            ForEach(availableLists) { feastList in
                                Text(feastList.displayName)
                                    .tag(feastList.objectURIString as String?)
                            }
                        }
                        .labelsHidden()
                        .pickerStyle(.menu)
                        .tint(FeastTheme.Colors.primaryText)
                    }
                }
            } header: {
                FeastFormSectionHeader(
                    title: "Scope",
                    subtitle: "Choose which saved places should be included"
                )
            }
        }
    }

    private var statusSection: some View {
        Section {
            FeastFormGroup {
                FeastFormField(
                    title: "Status",
                    helper: "Filter by your saved-place status."
                ) {
                    Picker("Status", selection: $filters.selectedStatus) {
                        Text("Any Status").tag(nil as PlaceStatus?)

                        ForEach(PlaceStatus.allCases) { status in
                            Text(status.rawValue).tag(status as PlaceStatus?)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                    .tint(FeastTheme.Colors.primaryText)
                }
            }
        } header: {
            FeastFormSectionHeader(
                title: "Status",
                subtitle: "Narrow results by how you track the place"
            )
        }
    }

    private var placeTypeSection: some View {
        Section {
            FeastFormGroup {
                FeastFormField(
                    title: "Place Type",
                    helper: "Filter by the kind of place."
                ) {
                    Picker("Place Type", selection: $filters.selectedPlaceType) {
                        Text("Any Type").tag(nil as PlaceType?)

                        ForEach(PlaceType.allCases) { placeType in
                            Text(placeType.rawValue).tag(placeType as PlaceType?)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                    .tint(FeastTheme.Colors.primaryText)
                }
            }
        } header: {
            FeastFormSectionHeader(
                title: "Place Type",
                subtitle: "Keep results focused on the kind of stop you need"
            )
        }
    }

    private var cuisineSection: some View {
        Section {
            FeastFormGroup {
                if availableCuisines.isEmpty {
                    FeastFormField(
                        title: "Cuisine",
                        helper: "Saved places with cuisine metadata will appear here."
                    ) {
                        Text("No cuisines available yet")
                            .font(FeastTheme.Typography.supporting.weight(.semibold))
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .feastFieldSurface(minHeight: 52)
                    }
                } else {
                    FeastFormField(
                        title: "Cuisine",
                        helper: "Use cuisine metadata to narrow the results."
                    ) {
                        Picker("Cuisine", selection: $filters.selectedCuisine) {
                            Text("Any Cuisine").tag(nil as String?)

                            ForEach(availableCuisines, id: \.self) { cuisine in
                                Text(cuisine).tag(cuisine as String?)
                            }
                        }
                        .labelsHidden()
                        .pickerStyle(.menu)
                        .tint(FeastTheme.Colors.primaryText)
                    }
                }
            }
        } header: {
            FeastFormSectionHeader(
                title: "Cuisine",
                subtitle: "Filter by cuisine tags when available"
            )
        }
    }
}
