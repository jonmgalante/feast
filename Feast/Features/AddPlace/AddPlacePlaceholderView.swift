import CoreData
import SwiftUI

struct AddPlaceView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.applePlacesService) private var applePlacesService

    @ObservedObject var feastList: FeastList

    @State private var searchQuery = ""
    @State private var searchResults: [ApplePlaceMatch] = []
    @State private var selectedPlace: ApplePlaceMatch?
    @State private var searchState: SearchState = .idle

    var body: some View {
        List {
            searchIntroSection
            searchResultsSection
        }
        .listStyle(.insetGrouped)
        .navigationTitle("Add Place")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Cancel") {
                    dismiss()
                }
            }
        }
        .searchable(text: $searchQuery, prompt: "Search Apple Maps")
        .textInputAutocapitalization(.words)
        .autocorrectionDisabled()
        .task(id: searchQuery) {
            await search(for: searchQuery)
        }
        .navigationDestination(item: $selectedPlace) { place in
            AddPlaceSaveView(
                feastList: feastList,
                place: place,
                onSaveComplete: { dismiss() }
            )
        }
    }

    private var searchIntroSection: some View {
        Section {
            VStack(alignment: .leading, spacing: FeastTheme.Spacing.small) {
                Text("Search Apple Maps to add a place to \(feastList.displayName).")
                    .font(FeastTheme.Typography.body.weight(.semibold))
                    .foregroundStyle(FeastTheme.Colors.primaryText)

                Text("Only Apple Maps matches can be saved in Feast v1.")
                    .font(FeastTheme.Typography.supporting)
                    .foregroundStyle(FeastTheme.Colors.secondaryNeutral)
            }
            .padding(.vertical, FeastTheme.Spacing.xSmall)
        }
    }

    @ViewBuilder
    private var searchResultsSection: some View {
        switch searchState {
        case .idle:
            Section {
                Text("Start typing a place name to search Apple Maps.")
                    .font(FeastTheme.Typography.supporting)
                    .foregroundStyle(FeastTheme.Colors.secondaryNeutral)
            }
        case .loading:
            Section {
                HStack {
                    Spacer()
                    ProgressView()
                    Spacer()
                }
                .padding(.vertical, FeastTheme.Spacing.medium)
            }
        case .loaded:
            if searchResults.isEmpty {
                Section {
                    ContentUnavailableView(
                        "No Matches",
                        systemImage: "mappin.slash",
                        description: Text("Try a more specific place name.")
                    )
                }
            } else {
                Section("Apple Maps Matches") {
                    ForEach(searchResults) { place in
                        Button {
                            selectedPlace = place
                        } label: {
                            SearchResultRow(place: place)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        case let .failed(message):
            Section {
                ContentUnavailableView(
                    "Search Unavailable",
                    systemImage: "exclamationmark.triangle",
                    description: Text(message)
                )
            }
        }
    }

    @MainActor
    private func search(for rawQuery: String) async {
        let trimmedQuery = rawQuery.trimmingCharacters(in: .whitespacesAndNewlines)

        guard trimmedQuery.count >= 2 else {
            searchResults = []
            searchState = .idle
            return
        }

        searchState = .loading

        do {
            try await Task.sleep(nanoseconds: 300_000_000)
            let matches = try await applePlacesService.searchPlaces(matching: trimmedQuery)

            if Task.isCancelled {
                return
            }

            searchResults = matches
            searchState = .loaded
        } catch is CancellationError {
            return
        } catch {
            searchResults = []
            searchState = .failed(error.localizedDescription)
        }
    }
}

private struct AddPlaceSaveView: View {
    @Environment(\.managedObjectContext) private var viewContext
    @Environment(\.persistenceController) private var persistenceController

    @ObservedObject var feastList: FeastList

    let place: ApplePlaceMatch
    let onSaveComplete: () -> Void

    @State private var status: PlaceStatus = .wantToTry
    @State private var placeType: PlaceType = .restaurant
    @State private var cuisinesText = ""
    @State private var tagsText = ""
    @State private var note = ""
    @State private var skipNote = ""
    @State private var instagramURL = ""
    @State private var selectedSectionObjectID: NSManagedObjectID?
    @State private var showingSaveError = false
    @State private var saveErrorMessage = ""

    init(
        feastList: FeastList,
        place: ApplePlaceMatch,
        onSaveComplete: @escaping () -> Void
    ) {
        self.feastList = feastList
        self.place = place
        self.onSaveComplete = onSaveComplete
        _selectedSectionObjectID = State(
            initialValue: Self.suggestedSection(in: feastList, for: place)?.objectID
        )
    }

    var body: some View {
        Form {
            matchSection
            metadataSection
            categoriesSection
            notesSection
            sectionAssignmentSection
        }
        .navigationTitle("Save Place")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("Save") {
                    savePlace()
                }
            }
        }
        .alert("Couldn’t Save Place", isPresented: $showingSaveError) {
            Button("OK", role: .cancel) { }
        } message: {
            Text(saveErrorMessage)
        }
    }

    private var repository: FeastRepository {
        FeastRepository(
            context: viewContext,
            persistenceController: persistenceController
        )
    }

    private var allSections: [ListSection] {
        feastList.sortedSections
    }

    private var selectedSection: ListSection? {
        allSections.first { $0.objectID == selectedSectionObjectID }
    }

    private var sectionSuggestionMessage: String? {
        if let suggestedSection = Self.suggestedSection(in: feastList, for: place) {
            return "Apple Maps suggests \(suggestedSection.pathDisplay)."
        }

        if let path = place.suggestedSectionPath.displayText {
            return "Apple Maps suggests \(path), but no matching section exists yet. You can save this to Unsorted for now."
        }

        return nil
    }

    private var matchSection: some View {
        Section("Apple Maps Match") {
            VStack(alignment: .leading, spacing: FeastTheme.Spacing.xSmall) {
                Text(place.displayName)
                    .font(FeastTheme.Typography.body.weight(.semibold))
                    .foregroundStyle(FeastTheme.Colors.primaryText)

                if !place.secondaryText.isEmpty {
                    Text(place.secondaryText)
                        .font(FeastTheme.Typography.supporting)
                        .foregroundStyle(FeastTheme.Colors.secondaryNeutral)
                }

                if let sectionSuggestionMessage {
                    Text(sectionSuggestionMessage)
                        .font(FeastTheme.Typography.caption)
                        .foregroundStyle(FeastTheme.Colors.secondaryAccent)
                }
            }
            .padding(.vertical, FeastTheme.Spacing.xSmall)
        }
    }

    private var metadataSection: some View {
        Section("Metadata") {
            Picker("Status", selection: $status) {
                ForEach(PlaceStatus.allCases) { status in
                    Text(status.rawValue).tag(status)
                }
            }

            Picker("Place Type", selection: $placeType) {
                ForEach(PlaceType.allCases) { placeType in
                    Text(placeType.rawValue).tag(placeType)
                }
            }
        }
    }

    private var categoriesSection: some View {
        Section("Cuisines And Tags") {
            TextField("Cuisines", text: $cuisinesText)
                .textInputAutocapitalization(.words)

            TextField("Tags", text: $tagsText)
                .textInputAutocapitalization(.words)

            Text("Use commas for multiple values.")
                .font(FeastTheme.Typography.caption)
                .foregroundStyle(FeastTheme.Colors.secondaryNeutral)
        }
    }

    private var notesSection: some View {
        Section("Notes") {
            TextField("Note", text: $note, axis: .vertical)
                .lineLimit(3...6)

            TextField("Skip Note", text: $skipNote, axis: .vertical)
                .lineLimit(2...4)

            TextField("Instagram URL", text: $instagramURL)
                .keyboardType(.URL)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
        }
    }

    private var sectionAssignmentSection: some View {
        Section("Section Assignment") {
            Picker("Section", selection: $selectedSectionObjectID) {
                Text("Unsorted").tag(nil as NSManagedObjectID?)

                ForEach(allSections) { section in
                    Text(section.pathDisplay).tag(section.objectID as NSManagedObjectID?)
                }
            }
        }
    }

    private func savePlace() {
        do {
            try repository.createSavedPlace(
                from: FeastRepository.SavedPlaceDraft(
                    applePlaceID: place.applePlaceID,
                    displayNameSnapshot: place.displayName,
                    status: status,
                    placeType: placeType,
                    cuisines: splitValues(from: cuisinesText),
                    tags: splitValues(from: tagsText),
                    note: normalizedOptional(note),
                    skipNote: normalizedOptional(skipNote),
                    instagramURL: normalizedOptional(instagramURL),
                    feastList: feastList,
                    listSection: selectedSection
                )
            )
            onSaveComplete()
        } catch {
            saveErrorMessage = error.localizedDescription
            showingSaveError = true
        }
    }

    private func splitValues(from rawValue: String) -> [String] {
        rawValue
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    private func normalizedOptional(_ rawValue: String) -> String? {
        let trimmed = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func suggestedSection(
        in feastList: FeastList,
        for place: ApplePlaceMatch
    ) -> ListSection? {
        guard let cityOrRegion = normalized(place.suggestedSectionPath.cityOrRegion) else {
            return nil
        }

        guard let topLevelSection = feastList.topLevelSections.first(where: {
            matches($0.displayName, cityOrRegion)
        }) else {
            return nil
        }

        if let neighborhood = normalized(place.suggestedSectionPath.neighborhood),
           let childSection = topLevelSection.sortedChildren.first(where: {
               matches($0.displayName, neighborhood)
           }) {
            return childSection
        }

        return topLevelSection
    }

    private static func normalized(_ rawValue: String?) -> String? {
        guard let trimmed = rawValue?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else {
            return nil
        }

        return trimmed
    }

    private static func matches(_ lhs: String, _ rhs: String) -> Bool {
        lhs.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            == rhs.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
    }
}

private struct SearchResultRow: View {
    let place: ApplePlaceMatch

    var body: some View {
        VStack(alignment: .leading, spacing: FeastTheme.Spacing.xSmall) {
            Text(place.displayName)
                .font(FeastTheme.Typography.body.weight(.semibold))
                .foregroundStyle(FeastTheme.Colors.primaryText)

            if !place.secondaryText.isEmpty {
                Text(place.secondaryText)
                    .font(FeastTheme.Typography.supporting)
                    .foregroundStyle(FeastTheme.Colors.secondaryNeutral)
            }

            if let suggestedPath = place.suggestedSectionPath.displayText {
                Text("Suggested section: \(suggestedPath)")
                    .font(FeastTheme.Typography.caption)
                    .foregroundStyle(FeastTheme.Colors.secondaryAccent)
            }
        }
        .padding(.vertical, FeastTheme.Spacing.xSmall)
    }
}

private enum SearchState {
    case idle
    case loading
    case loaded
    case failed(String)
}

#Preview {
    FeastPreviewContainer {
        NavigationStack {
            AddPlaceView(feastList: AppServices.preview.repository.fetchPreviewFeastList(named: "NYC"))
        }
    }
}
