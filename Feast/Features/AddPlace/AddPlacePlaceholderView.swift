import CoreData
import SwiftUI

struct AddPlaceView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.applePlacesService) private var applePlacesService

    @ObservedObject var feastList: FeastList
    let onSelectPlace: ((ApplePlaceMatch) -> Void)?

    @State private var searchQuery = ""
    @State private var searchResults: [ApplePlaceMatch] = []
    @State private var selectedPlace: ApplePlaceMatch?
    @State private var searchState: SearchState = .idle
    @FocusState private var isSearchFieldFocused: Bool

    init(
        feastList: FeastList,
        initialSearchQuery: String = "",
        onSelectPlace: ((ApplePlaceMatch) -> Void)? = nil
    ) {
        self.feastList = feastList
        self.onSelectPlace = onSelectPlace
        _searchQuery = State(initialValue: initialSearchQuery)
    }

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

                    Text("Add a place to \(feastList.displayName) by choosing the exact Apple Maps match first.")
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
                            if let onSelectPlace {
                                onSelectPlace(place)
                            } else {
                                selectedPlace = place
                            }
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
    @Environment(\.openURL) private var openURL
    @Environment(\.persistenceController) private var persistenceController

    @ObservedObject var feastList: FeastList
    @FetchRequest(fetchRequest: Self.savedPlacesFetchRequest) private var savedPlaces: FetchedResults<SavedPlace>

    let place: ApplePlaceMatch
    let onSaveComplete: () -> Void

    @State private var status: PlaceStatus = .wantToTry
    @State private var placeType: PlaceType = .restaurant
    @State private var cuisinesText = ""
    @State private var tags: [String] = []
    @State private var note = ""
    @State private var websiteURL = ""
    @State private var instagramURL = ""
    @State private var selectedNeighborhoodSelection: AddPlaceNeighborhoodSelection = .unsorted
    @State private var committedNeighborhoodSelection: AddPlaceNeighborhoodSelection = .unsorted
    @State private var showingNewNeighborhoodSheet = false
    @State private var newNeighborhoodName = ""
    @State private var alertState: AddPlaceAlertState?

    init(
        feastList: FeastList,
        place: ApplePlaceMatch,
        onSaveComplete: @escaping () -> Void
    ) {
        self.feastList = feastList
        self.place = place
        self.onSaveComplete = onSaveComplete
        _websiteURL = State(initialValue: place.websiteURL ?? "")
        _instagramURL = State(initialValue: place.instagramURL ?? "")
        _selectedNeighborhoodSelection = State(
            initialValue: PlaceNeighborhoodSuggestionSupport.initialNeighborhoodSelection(
                in: feastList,
                for: place
            )
        )
        _committedNeighborhoodSelection = State(
            initialValue: PlaceNeighborhoodSuggestionSupport.initialNeighborhoodSelection(
                in: feastList,
                for: place
            )
        )
    }

    var body: some View {
        List {
            matchSection
            metadataSection
            categoriesSection
            notesSection
            neighborhoodAssignmentSection
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
        .onChange(of: selectedNeighborhoodSelection) { _, newSelection in
            handleNeighborhoodSelectionChange(newSelection)
        }
        .sheet(isPresented: $showingNewNeighborhoodSheet) {
            NavigationStack {
                NeighborhoodNamePromptSheet(
                    initialName: newNeighborhoodName,
                    onConfirm: applyManualNeighborhoodName(_:)
                )
            }
        }
        .alert(item: $alertState) { alert in
            Alert(
                title: Text(alert.title),
                message: Text(alert.message),
                dismissButton: .default(Text("OK"))
            )
        }
    }

    private var repository: FeastRepository {
        FeastRepository(
            context: viewContext,
            persistenceController: persistenceController
        )
    }

    private static let savedPlacesFetchRequest: NSFetchRequest<SavedPlace> = {
        let request = SavedPlace.fetchRequest()
        request.sortDescriptors = [
            NSSortDescriptor(key: "updatedAt", ascending: false),
            NSSortDescriptor(key: "displayNameSnapshot", ascending: true)
        ]
        return request
    }()

    private var allNeighborhoods: [ListSection] {
        feastList.neighborhoodSections
    }

    private var selectedNeighborhood: ListSection? {
        switch selectedNeighborhoodSelection {
        case .unsorted:
            return nil
        case .manualEntry:
            return nil
        case let .existing(objectID):
            return allNeighborhoods.first { $0.objectID == objectID }
        case let .create(neighborhoodName):
            return allNeighborhoods.first { neighborhood in
                FeastNeighborhoodName.matches(
                    neighborhood.displayName,
                    neighborhoodName
                )
            }
        }
    }

    private var suggestedNeighborhood: FeastNeighborhoodName.Suggestion? {
        PlaceNeighborhoodSuggestionSupport.suggestedNeighborhoodSuggestion(
            in: feastList,
            for: place
        )
    }

    private var suggestedNeighborhoodToCreate: String? {
        guard let suggestedNeighborhood, suggestedNeighborhood.existingMatch == nil else {
            return nil
        }

        return suggestedNeighborhood.displayName
    }

    private var manualNeighborhoodToCreate: String? {
        guard
            case let .create(neighborhoodName) = selectedNeighborhoodSelection,
            let canonicalNeighborhoodName = FeastNeighborhoodName.canonicalDisplayName(for: neighborhoodName)
        else {
            return nil
        }

        if let suggestedNeighborhoodToCreate,
           FeastNeighborhoodName.matches(canonicalNeighborhoodName, suggestedNeighborhoodToCreate) {
            return nil
        }

        return canonicalNeighborhoodName
    }

    private var neighborhoodHelperText: String {
        "Choose Unsorted to keep it at the city level for now."
    }

    private var existingTags: [String] {
        FeastTag.catalog(from: savedPlaces.map(\.tags))
    }

    private var hasWebsiteURL: Bool {
        normalizedOptional(websiteURL) != nil
    }

    private var hasInstagramURL: Bool {
        normalizedOptional(instagramURL) != nil
    }

    private var instagramSearchQueryComponents: [String] {
        var queryComponents = [place.displayName]

        if let neighborhoodName = selectedNeighborhood?.displayName ?? suggestedNeighborhood?.displayName,
           !neighborhoodName.isEmpty {
            queryComponents.append(neighborhoodName)
        }

        queryComponents.append(feastList.displayName)
        return queryComponents
    }

    private var instagramSearchQuery: String {
        instagramSearchQueryComponents.joined(separator: " ")
    }

    private var instagramSearchURL: URL? {
        var components = URLComponents(string: "https://www.google.com/search")
        components?.queryItems = [
            URLQueryItem(
                name: "q",
                value: (["site:instagram.com"] + instagramSearchQueryComponents).joined(separator: " ")
            )
        ]
        return components?.url
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
                subtitle: "This is the exact place you're saving"
            )
        }
    }

    private var metadataSection: some View {
        Section {
            FeastFormGroup {
                FeastFormField(
                    title: "Status",
                    helper: "How this place shows up in this city."
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
                    helper: "Helps keep places organized."
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
                title: "Status And Type",
                subtitle: "Choose how this place should be organized"
            )
        }
    }

    private var categoriesSection: some View {
        Section {
            FeastFormGroup {
                FeastFormField(title: "Cuisines") {
                    TextField("Italian, Japanese, Seafood", text: $cuisinesText)
                        .textInputAutocapitalization(.words)
                        .feastFieldSurface()
                }

                FeastFormDivider()

                FeastFormField(
                    title: "Tags",
                    helper: "Press Return or comma to add a tag."
                ) {
                    FeastTagInputView(
                        tags: $tags,
                        existingTags: existingTags,
                        placeholder: "Date Night, Brunch, Worth a Detour"
                    )
                }
            }
        } header: {
            FeastFormSectionHeader(
                title: "Cuisines And Tags",
                subtitle: "Add details that make this easier to find later"
            )
        }
    }

    private var notesSection: some View {
        Section {
            FeastFormGroup {
                FeastFormField(title: "Note", helper: "Anything useful to remember.") {
                    FeastMultilineTextEditor(
                        placeholder: "What to order, who recommended it, or why you'd skip it",
                        text: $note,
                        minHeight: 92
                    )
                }

                FeastFormDivider()

                FeastFormField(title: "Website") {
                    VStack(alignment: .leading, spacing: FeastTheme.Spacing.small) {
                        FeastSingleLineTextField(
                            placeholder: "https://example.com",
                            text: $websiteURL,
                            keyboardType: .URL,
                            textInputAutocapitalization: .never,
                            autocorrectionDisabled: true
                        )

                        if hasWebsiteURL {
                            FeastFieldInlineAction(
                                title: "Open Website",
                                systemImage: "globe"
                            ) {
                                openExternalURL(
                                    from: websiteURL,
                                    failureTitle: "Website Unavailable",
                                    failureMessage: "Feast couldn't open this website link."
                                )
                            }
                        }
                    }
                }

                FeastFormDivider()

                FeastFormField(title: "Instagram") {
                    VStack(alignment: .leading, spacing: FeastTheme.Spacing.small) {
                        FeastSingleLineTextField(
                            placeholder: "https://instagram.com/...",
                            text: $instagramURL,
                            keyboardType: .URL,
                            textInputAutocapitalization: .never,
                            autocorrectionDisabled: true
                        )

                        if hasInstagramURL {
                            FeastFieldInlineAction(
                                title: "Open Instagram",
                                systemImage: "camera"
                            ) {
                                openExternalURL(
                                    from: instagramURL,
                                    failureTitle: "Instagram Unavailable",
                                    failureMessage: "Feast couldn't open this Instagram link."
                                )
                            }
                        } else {
                            FeastFieldInlineAction(
                                title: "Search Instagram",
                                systemImage: "magnifyingglass"
                            ) {
                                searchInstagram()
                            }
                        }
                    }
                }
            }
        } header: {
            FeastFormSectionHeader(
                title: "Notes And Links",
                subtitle: "Add quick context you'll want later"
            )
        }
    }

    private var neighborhoodAssignmentSection: some View {
        Section {
            FeastFormGroup {
                FeastFormField(
                    title: "Neighborhood",
                    helper: neighborhoodHelperText,
                    helperColor: FeastTheme.Colors.secondaryText
                ) {
                    Picker("Neighborhood", selection: $selectedNeighborhoodSelection) {
                        Text("Unsorted").tag(AddPlaceNeighborhoodSelection.unsorted)

                        if let suggestedNeighborhoodToCreate {
                            Text("Create “\(suggestedNeighborhoodToCreate)”")
                                .tag(AddPlaceNeighborhoodSelection.create(suggestedNeighborhoodToCreate))
                        }

                        if let manualNeighborhoodToCreate {
                            Text("Create “\(manualNeighborhoodToCreate)”")
                                .tag(AddPlaceNeighborhoodSelection.create(manualNeighborhoodToCreate))
                        }

                        Text("New Neighborhood…")
                            .tag(AddPlaceNeighborhoodSelection.manualEntry)

                        ForEach(allNeighborhoods) { neighborhood in
                            Text(neighborhood.displayName)
                                .tag(AddPlaceNeighborhoodSelection.existing(neighborhood.objectID))
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                    .tint(FeastTheme.Colors.primaryText)
                }
            }
        } header: {
            FeastFormSectionHeader(
                title: "Neighborhood",
                subtitle: "Choose where to save this place in \(feastList.displayName)"
            )
        }
    }

    private func savePlace() {
        do {
            let selectedNeighborhood = try resolvedNeighborhoodForSave()
            try repository.createSavedPlace(
                from: FeastRepository.SavedPlaceDraft(
                    applePlaceID: place.applePlaceID,
                    displayNameSnapshot: place.displayName,
                    status: status,
                    placeType: placeType,
                    cuisines: splitValues(from: cuisinesText),
                    tags: tags,
                    note: normalizedOptional(note),
                    websiteURL: normalizedOptional(websiteURL),
                    instagramURL: normalizedOptional(instagramURL),
                    feastList: feastList,
                    listSection: selectedNeighborhood
                )
            )
            onSaveComplete()
        } catch {
            alertState = AddPlaceAlertState(
                title: "Couldn’t Save Place",
                message: errorMessage(for: error)
            )
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

    private func validatedURL(from rawValue: String) -> URL? {
        guard
            let normalizedURL = normalizedOptional(rawValue),
            let url = URL(string: normalizedURL)
        else {
            return nil
        }

        return url
    }

    private func handleNeighborhoodSelectionChange(_ newSelection: AddPlaceNeighborhoodSelection) {
        guard newSelection == .manualEntry else {
            committedNeighborhoodSelection = newSelection
            return
        }

        if case let .create(existingName) = committedNeighborhoodSelection {
            newNeighborhoodName = existingName
        } else {
            newNeighborhoodName = ""
        }

        showingNewNeighborhoodSheet = true
        selectedNeighborhoodSelection = committedNeighborhoodSelection
    }

    private func applyManualNeighborhoodName(_ rawValue: String) {
        guard let canonicalNeighborhoodName = FeastNeighborhoodName.canonicalDisplayName(for: rawValue) else {
            return
        }

        if let existingNeighborhood = allNeighborhoods.first(where: { neighborhood in
            FeastNeighborhoodName.matches(
                neighborhood.displayName,
                canonicalNeighborhoodName
            )
        }) {
            selectedNeighborhoodSelection = .existing(existingNeighborhood.objectID)
            return
        }

        selectedNeighborhoodSelection = .create(canonicalNeighborhoodName)
    }

    private func resolvedNeighborhoodForSave() throws -> ListSection? {
        switch selectedNeighborhoodSelection {
        case .unsorted:
            return nil
        case .manualEntry:
            return nil
        case let .existing(objectID):
            return allNeighborhoods.first { $0.objectID == objectID }
        case let .create(neighborhoodName):
            if let existingNeighborhood = selectedNeighborhood {
                return existingNeighborhood
            }

            return try repository.createListSection(
                named: neighborhoodName,
                in: feastList
            )
        }
    }

    private func errorMessage(for error: Error) -> String {
        let message = error.localizedDescription.trimmingCharacters(in: .whitespacesAndNewlines)
        if !message.isEmpty {
            return message
        }

        return "Feast couldn't save this place. Your edits are still on screen."
    }

    private func openExternalURL(
        _ url: URL,
        failureTitle: String,
        failureMessage: String
    ) {
        openURL(url) { accepted in
            if !accepted {
                alertState = AddPlaceAlertState(
                    title: failureTitle,
                    message: failureMessage
                )
            }
        }
    }

    private func openExternalURL(
        from rawValue: String,
        failureTitle: String,
        failureMessage: String
    ) {
        guard let url = validatedURL(from: rawValue) else {
            alertState = AddPlaceAlertState(
                title: failureTitle,
                message: failureMessage
            )
            return
        }

        openExternalURL(
            url,
            failureTitle: failureTitle,
            failureMessage: failureMessage
        )
    }

    private func searchInstagram() {
        guard let instagramSearchURL else {
            alertState = AddPlaceAlertState(
                title: "Instagram Search Unavailable",
                message: "Feast couldn't open this Instagram search."
            )
            return
        }

        InstagramSearchLauncher.openSearch(
            query: instagramSearchQuery,
            fallbackURL: instagramSearchURL
        ) { accepted in
            if !accepted {
                alertState = AddPlaceAlertState(
                    title: "Instagram Search Unavailable",
                    message: "Feast couldn't open this Instagram search."
                )
            }
        }
    }
}

private struct AddPlaceAlertState: Identifiable {
    let id = UUID()
    let title: String
    let message: String
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

                if let neighborhood = FeastNeighborhoodName.trustworthyNeighborhood(
                    from: place.suggestedSectionPath.neighborhood,
                    rejectedContextNames: [place.suggestedSectionPath.cityOrRegion].compactMap { $0 }
                ) {
                    Text("Suggested neighborhood: \(neighborhood)")
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

enum PlaceNeighborhoodSuggestionSupport {
    static func initialNeighborhoodSelection(
        in feastList: FeastList,
        for place: ApplePlaceMatch
    ) -> AddPlaceNeighborhoodSelection {
        guard
            let suggestedNeighborhood = suggestedNeighborhoodSuggestion(
                in: feastList,
                for: place
            ),
            let existingNeighborhoodName = suggestedNeighborhood.existingMatch,
            let existingNeighborhood = feastList.neighborhoodSections.first(where: { neighborhood in
                FeastNeighborhoodName.matches(
                    neighborhood.displayName,
                    existingNeighborhoodName
                )
            })
        else {
            return .unsorted
        }

        return .existing(existingNeighborhood.objectID)
    }

    static func suggestedNeighborhoodSuggestion(
        in feastList: FeastList,
        for place: ApplePlaceMatch
    ) -> FeastNeighborhoodName.Suggestion? {
        FeastNeighborhoodName.suggestion(
            primary: place.suggestedSectionPath.neighborhood,
            existingNeighborhoodNames: feastList.neighborhoodSections.map(\.displayName),
            rejectedContextNames: [
                feastList.displayName,
                place.suggestedSectionPath.cityOrRegion
            ]
            .compactMap { $0 }
        )
    }
}

enum AddPlaceNeighborhoodSelection: Hashable {
    case unsorted
    case existing(NSManagedObjectID)
    case create(String)
    case manualEntry
}

struct NeighborhoodNamePromptSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State private var name: String

    let onConfirm: (String) -> Void

    init(initialName: String, onConfirm: @escaping (String) -> Void) {
        self.onConfirm = onConfirm
        _name = State(initialValue: initialName)
    }

    var body: some View {
        List {
            Section {
                FeastFormGroup {
                    FeastFormField(
                        title: "Neighborhood Name",
                        helper: "Use the neighborhood name you want to group places under."
                    ) {
                        TextField("Neighborhood name", text: $name)
                            .textInputAutocapitalization(.words)
                            .autocorrectionDisabled()
                            .feastFieldSurface(minHeight: 52)
                    }
                }
            } header: {
                FeastFormSectionHeader(
                    title: "New Neighborhood",
                    subtitle: "Create a neighborhood for this place"
                )
            }
        }
        .feastScrollableChrome()
        .listStyle(.insetGrouped)
        .scrollDismissesKeyboard(.interactively)
        .navigationTitle("New Neighborhood")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Cancel") {
                    dismiss()
                }
            }

            ToolbarItem(placement: .confirmationAction) {
                Button {
                    onConfirm(name)
                    dismiss()
                } label: {
                    Text("Use")
                        .fontWeight(.semibold)
                }
                .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
    }
}

#Preview {
    FeastPreviewContainer {
        NavigationStack {
            AddPlaceView(feastList: AppServices.preview.repository.fetchPreviewFeastList(named: "NYC"))
        }
    }
}
