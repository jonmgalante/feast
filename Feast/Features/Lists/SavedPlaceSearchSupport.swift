import CoreData
import SwiftUI

struct SavedPlaceFilterSheet: View {
    @Environment(\.dismiss) private var dismiss

    @Binding private var committedFilters: SavedPlaceSearchFilters
    @State private var filters: SavedPlaceSearchFilters

    let availableLists: [FeastList]
    let availableCuisines: [String]
    let fixedFeastList: FeastList?
    let availableTags: [String]
    let showsQuery: Bool

    init(filters: Binding<SavedPlaceSearchFilters>, availableLists: [FeastList], availableCuisines: [String], fixedFeastList: FeastList?, availableTags: [String] = [], showsQuery: Bool = false) {
        _committedFilters = filters
        _filters = State(initialValue: filters.wrappedValue)
        self.availableLists = availableLists
        self.availableCuisines = availableCuisines
        self.fixedFeastList = fixedFeastList
        self.availableTags = availableTags
        self.showsQuery = showsQuery
    }

    var body: some View {
        List {
            if showsQuery {
                Section("Search saved places") {
                    TextField("Name, city, neighborhood, note, tag, cuisine or link", text: $filters.queryText)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                }
            }
            scopeSection
            statusSection
            placeTypeSection
            cuisineSection
            tagsSection
        }
        .feastScrollableChrome()
        .listStyle(.insetGrouped)
        .navigationTitle("Filters")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItemGroup(placement: .cancellationAction) {
                Button("Reset") {
                    filters.reset()
                }
                .disabled(!filters.hasCriteria)
                Button("Cancel") { dismiss() }
            }

            ToolbarItem(placement: .confirmationAction) {
                Button {
                    committedFilters = filters
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
                    ForEach(PlaceStatus.allCases) { status in
                        Button {
                            if filters.selectedStatuses.contains(status) { filters.selectedStatuses.remove(status) }
                            else { filters.selectedStatuses.insert(status) }
                        } label: {
                            HStack {
                                Text(status.rawValue)
                                Spacer()
                                if filters.selectedStatuses.contains(status) { Image(systemName: "checkmark") }
                            }
                        }
                        .tint(FeastTheme.Colors.primaryText)
                    }
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

                            ForEach(Array(Set(availableCuisines + [filters.selectedCuisine].compactMap { $0 })).sorted(), id: \.self) { cuisine in
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
    private var tagsSection: some View {
        Section("Tags") {
            ForEach(FeastTag.catalog(from: [availableTags, Array(filters.selectedTags)]), id: \.self) { tag in
                Button {
                    if filters.selectedTags.contains(tag) { filters.selectedTags.remove(tag) }
                    else { filters.selectedTags.insert(tag) }
                } label: {
                    HStack {
                        Text(tag)
                        Spacer()
                        if filters.selectedTags.contains(tag) { Image(systemName: "checkmark") }
                    }
                }
                .tint(FeastTheme.Colors.primaryText)
            }
        }
    }

}
