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
    @FocusState private var isSearchFieldFocused: Bool

    var body: some View {
        List {
            searchSection
            searchResultsSection
        }
        .feastScrollableChrome()
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
        .scrollDismissesKeyboard(.interactively)
        .task(id: searchQuery) {
            await search(for: searchQuery)
        }
        .task {
            guard searchQuery.isEmpty else {
                return
            }

            try? await Task.sleep(nanoseconds: 200_000_000)
            if !Task.isCancelled {
                isSearchFieldFocused = true
            }
        }
        .navigationDestination(item: $selectedPlace) { place in
            AddPlaceSaveView(
                feastList: feastList,
                place: place,
                onSaveComplete: { dismiss() }
            )
        }
    }

    private var searchSection: some View {
        Section {
            FeastFormGroup {
                VStack(alignment: .leading, spacing: FeastTheme.Spacing.medium) {
                    Text("Search Apple Maps")
                        .font(FeastTheme.Typography.formTitle)
                        .foregroundStyle(FeastTheme.Colors.primaryText)

                    Text("Add a place to \(feastList.displayName) by finding the exact Apple Maps match first.")
                        .font(FeastTheme.Typography.rowMetadata)
                        .foregroundStyle(FeastTheme.Colors.secondaryText)

                    HStack(spacing: FeastTheme.Spacing.small) {
                        Image(systemName: "magnifyingglass")
                            .font(.system(size: 16, weight: .semibold))
                            .foregroundStyle(FeastTheme.Colors.tertiaryText)

                        TextField("Restaurant, cafe, bar, neighborhood", text: $searchQuery)
                            .focused($isSearchFieldFocused)
                            .textInputAutocapitalization(.words)
                            .autocorrectionDisabled()
                            .submitLabel(.search)

                        if !searchQuery.isEmpty {
                            Button {
                                searchQuery = ""
                            } label: {
                                Image(systemName: "xmark.circle.fill")
                                    .foregroundStyle(FeastTheme.Colors.secondaryAction)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .feastFieldSurface(minHeight: 52)

                    Text("Only Apple Maps matches can be saved in Feast v1.")
                        .font(FeastTheme.Typography.formHelper)
                        .foregroundStyle(FeastTheme.Colors.tertiaryText)
                }
            }
        }
    }

    @ViewBuilder
    private var searchResultsSection: some View {
        switch searchState {
        case .idle:
            Section {
                FeastFormGroup {
                    Label("Results appear here as you type a place name, address, or neighborhood.", systemImage: "magnifyingglass.circle")
                        .font(FeastTheme.Typography.supporting)
                        .foregroundStyle(FeastTheme.Colors.secondaryText)
                }
            } header: {
                FeastFormSectionHeader(
                    title: "Matches",
                    subtitle: "Search is ready as soon as you start typing"
                )
            }
        case .loading:
            Section {
                FeastFormGroup {
                    HStack(spacing: FeastTheme.Spacing.medium) {
                        ProgressView()
                        Text("Searching Apple Maps...")
                            .font(FeastTheme.Typography.supporting)
                            .foregroundStyle(FeastTheme.Colors.secondaryText)
                    }
                }
            } header: {
                FeastFormSectionHeader(
                    title: "Matches",
                    subtitle: "Looking for the closest Apple Maps results"
                )
            }
        case .loaded:
            if searchResults.isEmpty {
                Section {
                    FeastFormGroup {
                        ContentUnavailableView(
                            "No Matches",
                            systemImage: "mappin.slash",
                            description: Text("Try a more specific place name.")
                        )
                    }
                } header: {
                    FeastFormSectionHeader(
                        title: "Matches",
                        subtitle: "Apple Maps didn’t return any places yet"
                    )
                }
            } else {
                Section {
                    ForEach(searchResults) { place in
                        Button {
                            selectedPlace = place
                        } label: {
                            SearchResultRow(place: place)
                        }
                        .buttonStyle(.plain)
                    }
                } header: {
                    FeastFormSectionHeader(
                        title: "Apple Maps Matches",
                        subtitle: "\(searchResults.count) \(searchResults.count == 1 ? "result" : "results")"
                    )
                }
                .feastSectionSurface()
            }
        case let .failed(message):
            Section {
                FeastFormGroup {
                    ContentUnavailableView(
                        "Search Unavailable",
                        systemImage: "exclamationmark.triangle",
                        description: Text(message)
                    )
                }
            } header: {
                FeastFormSectionHeader(
                    title: "Matches",
                    subtitle: "Apple Maps search couldn’t be completed"
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
            let matches = try await applePlacesService.search(query: trimmedQuery)

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
        List {
            matchSection
            metadataSection
            categoriesSection
            notesSection
            sectionAssignmentSection
        }
        .feastScrollableChrome()
        .listStyle(.insetGrouped)
        .scrollDismissesKeyboard(.interactively)
        .navigationTitle("Save Place")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button {
                    savePlace()
                } label: {
                    Text("Save")
                        .fontWeight(.semibold)
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
        Section {
            FeastFormGroup {
                HStack(alignment: .top, spacing: FeastTheme.Spacing.medium) {
                    Image(systemName: "mappin.and.ellipse")
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundStyle(FeastTheme.Colors.primaryActionLabel)
                        .frame(width: 40, height: 40)
                        .background(
                            RoundedRectangle(
                                cornerRadius: FeastTheme.CornerRadius.small,
                                style: .continuous
                            )
                            .fill(FeastTheme.Colors.accentSelection.opacity(0.22))
                        )

                    VStack(alignment: .leading, spacing: 6) {
                        Text(feastList.displayName.uppercased())
                            .font(FeastTheme.Typography.sectionLabel)
                            .tracking(0.8)
                            .foregroundStyle(FeastTheme.Colors.secondaryText)
                            .fixedSize(horizontal: false, vertical: true)

                        Text(place.displayName)
                            .font(FeastTheme.Typography.formTitle)
                            .foregroundStyle(FeastTheme.Colors.primaryText)
                            .fixedSize(horizontal: false, vertical: true)

                        if !place.secondaryText.isEmpty {
                            Text(place.secondaryText)
                                .font(FeastTheme.Typography.supporting)
                                .foregroundStyle(FeastTheme.Colors.secondaryText)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
            }
        } header: {
            FeastFormSectionHeader(
                title: "Apple Maps Match",
                subtitle: "This is the exact place Feast will save"
            )
        }
    }

    private var metadataSection: some View {
        Section {
            FeastFormGroup {
                FeastFormField(
                    title: "Status",
                    helper: "Choose how the place should read in your list."
                ) {
                    Picker("Status", selection: $status) {
                        ForEach(PlaceStatus.allCases) { status in
                            Text(status.rawValue).tag(status)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                    .tint(FeastTheme.Colors.primaryText)
                }

                FeastFormDivider()

                FeastFormField(
                    title: "Place Type",
                    helper: "This helps Feast describe the place consistently."
                ) {
                    Picker("Place Type", selection: $placeType) {
                        ForEach(PlaceType.allCases) { placeType in
                            Text(placeType.rawValue).tag(placeType)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                    .tint(FeastTheme.Colors.primaryText)
                }
            }
        } header: {
            FeastFormSectionHeader(
                title: "Metadata",
                subtitle: "The quick descriptors used across Feast"
            )
        }
    }

    private var categoriesSection: some View {
        Section {
            FeastFormGroup {
                FeastFormField(title: "Cuisines") {
                    TextField("Italian, sushi, bakery", text: $cuisinesText)
                        .textInputAutocapitalization(.words)
                        .feastFieldSurface()
                }

                FeastFormDivider()

                FeastFormField(title: "Tags") {
                    TextField("Date night, walk-in, worth a detour", text: $tagsText)
                        .textInputAutocapitalization(.words)
                        .feastFieldSurface()
                }
            }
        } header: {
            FeastFormSectionHeader(
                title: "Cuisines And Tags",
                subtitle: "Use commas to separate multiple values"
            )
        }
    }

    private var notesSection: some View {
        Section {
            FeastFormGroup {
                FeastFormField(title: "Note", helper: "Why it’s worth saving.") {
                    TextField("What stood out?", text: $note, axis: .vertical)
                        .lineLimit(3...6)
                        .feastFieldSurface(minHeight: 92)
                }

                FeastFormDivider()

                FeastFormField(title: "Skip Note", helper: "Why you might pass on it next time.") {
                    TextField("What gave you pause?", text: $skipNote, axis: .vertical)
                        .lineLimit(2...4)
                        .feastFieldSurface(minHeight: 76)
                }

                FeastFormDivider()

                FeastFormField(title: "Instagram URL") {
                    TextField("https://instagram.com/...", text: $instagramURL)
                        .keyboardType(.URL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .feastFieldSurface()
                }
            }
        } header: {
            FeastFormSectionHeader(
                title: "Notes",
                subtitle: "Keep the save useful and easy to revisit later"
            )
        }
    }

    private var sectionAssignmentSection: some View {
        Section {
            FeastFormGroup {
                FeastFormField(
                    title: "Section",
                    helper: sectionSuggestionMessage ?? "Choose Unsorted if you want to organize this place later.",
                    helperColor: sectionSuggestionMessage == nil
                        ? FeastTheme.Colors.secondaryText
                        : FeastTheme.Colors.tertiaryText
                ) {
                    Picker("Section", selection: $selectedSectionObjectID) {
                        Text("Unsorted").tag(nil as NSManagedObjectID?)

                        ForEach(allSections) { section in
                            Text(section.pathDisplay).tag(section.objectID as NSManagedObjectID?)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                    .tint(FeastTheme.Colors.primaryText)
                }
            }
        } header: {
            FeastFormSectionHeader(
                title: "Section Assignment",
                subtitle: "Place it where it belongs in \(feastList.displayName)"
            )
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
        HStack(alignment: .top, spacing: FeastTheme.Spacing.small) {
            Image(systemName: "mappin.circle.fill")
                .font(.system(size: 16))
                .foregroundStyle(FeastTheme.Colors.accentSelection)
                .padding(.top, 2)

            VStack(alignment: .leading, spacing: 3) {
                Text(place.displayName)
                    .font(FeastTheme.Typography.rowTitle)
                    .foregroundStyle(FeastTheme.Colors.primaryText)
                    .fixedSize(horizontal: false, vertical: true)

                if !place.secondaryText.isEmpty {
                    Text(place.secondaryText)
                        .font(FeastTheme.Typography.rowMetadata)
                        .foregroundStyle(FeastTheme.Colors.secondaryText)
                }

                if let suggestedPath = place.suggestedSectionPath.displayText {
                    Text("Suggested section: \(suggestedPath)")
                        .font(FeastTheme.Typography.rowUtility)
                        .foregroundStyle(FeastTheme.Colors.tertiaryText)
                }
            }

            Spacer(minLength: 0)

            Image(systemName: "chevron.right")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(FeastTheme.Colors.secondaryText)
        }
        .padding(.vertical, FeastTheme.Spacing.small)
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
