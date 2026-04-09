import CoreData
import SwiftUI

struct SavedPlaceDetailView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.managedObjectContext) private var viewContext
    @Environment(\.openURL) private var openURL
    @Environment(\.persistenceController) private var persistenceController
    @Environment(\.applePlacesService) private var applePlacesService

    @ObservedObject var savedPlace: SavedPlace
    @FetchRequest(fetchRequest: Self.savedPlacesFetchRequest) private var savedPlaces: FetchedResults<SavedPlace>

    @State private var resolvedPlace: ApplePlaceMatch?
    @State private var selectedReplacementPlace: ApplePlaceMatch?
    @State private var isResolvingPlace = false
    @State private var isOpeningInMaps = false
    @State private var showingDeleteConfirmation = false
    @State private var showingLocationPicker = false
    @State private var hasAlternativeLocations: Bool?
    @State private var detailAlert: DetailAlertState?

    @State private var status: PlaceStatus
    @State private var placeType: PlaceType
    @State private var cuisinesText: String
    @State private var tags: [String]
    @State private var note: String
    @State private var websiteURL: String
    @State private var instagramURL: String
    @State private var selectedNeighborhoodSelection: AddPlaceNeighborhoodSelection
    @State private var committedNeighborhoodSelection: AddPlaceNeighborhoodSelection
    @State private var showingNewNeighborhoodSheet = false
    @State private var newNeighborhoodName = ""
    @State private var lastLoadedUpdatedAt: Date

    init(savedPlace: SavedPlace) {
        let initialNeighborhoodSelection = Self.initialNeighborhoodSelection(for: savedPlace)
        self.savedPlace = savedPlace
        _status = State(initialValue: savedPlace.placeStatus)
        _placeType = State(initialValue: savedPlace.placeTypeValue)
        _cuisinesText = State(initialValue: savedPlace.cuisines.joined(separator: ", "))
        _tags = State(initialValue: savedPlace.tags)
        _note = State(initialValue: savedPlace.note ?? "")
        _websiteURL = State(initialValue: savedPlace.websiteURL ?? "")
        _instagramURL = State(initialValue: savedPlace.instagramURL ?? "")
        _selectedNeighborhoodSelection = State(initialValue: initialNeighborhoodSelection)
        _committedNeighborhoodSelection = State(initialValue: initialNeighborhoodSelection)
        _lastLoadedUpdatedAt = State(initialValue: savedPlace.updatedAtValue)
    }

    var body: some View {
        List {
            headerSection
            neighborhoodAssignmentSection
            metadataSection
            categoriesSection
            notesSection
            actionsSection
        }
        .feastScrollableChrome()
        .listStyle(.insetGrouped)
        .scrollDismissesKeyboard(.interactively)
        .navigationTitle("Place")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button {
                    saveChanges()
                } label: {
                    Text("Save")
                        .fontWeight(.semibold)
                }
            }
        }
        .task(id: savedPlace.applePlaceIDValue) {
            await resolvePlace()
        }
        .task(id: alternativeLocationCheckKey) {
            await refreshAlternativeLocationAvailability()
        }
        .onAppear {
            reloadFormStateIfNeeded()
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
        .sheet(isPresented: $showingLocationPicker) {
            if let feastList = savedPlace.feastList {
                NavigationStack {
                    AddPlaceView(
                        feastList: feastList,
                        initialSearchQuery: displayedPlace?.displayName ?? savedPlace.displayName,
                        excludingSavedPlace: savedPlace,
                        onSelectPlace: { place in
                            selectedReplacementPlace = place
                            showingLocationPicker = false
                        }
                    )
                }
            }
        }
        .confirmationDialog(
            "Delete this place?",
            isPresented: $showingDeleteConfirmation,
            titleVisibility: .visible
        ) {
            Button("Remove from City", role: .destructive) {
                deletePlace()
            }
            Button("Cancel", role: .cancel) { }
        } message: {
            Text("This deletes the place from \(savedPlace.displayCityName).")
        }
        .alert(item: $detailAlert) { alert in
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

    private var headerTitle: String {
        displayedPlace?.displayName ?? savedPlace.displayName
    }

    private var selectedNeighborhoodName: String? {
        if let selectedNeighborhood {
            return selectedNeighborhood.displayName
        }

        guard case let .create(neighborhoodName) = selectedNeighborhoodSelection else {
            return nil
        }

        return FeastNeighborhoodName.canonicalDisplayName(for: neighborhoodName)
    }

    private var headerSubtitle: String? {
        if let displayedPlace, !displayedPlace.secondaryText.isEmpty {
            return displayedPlace.secondaryText
        }

        return nil
    }

    private var displayedPlace: ApplePlaceMatch? {
        selectedReplacementPlace ?? resolvedPlace
    }

    private var replacementLocationSearchQuery: String {
        resolvedPlace?.displayName ?? savedPlace.displayName
    }

    private var alternativeLocationCheckKey: String {
        let cityKey = savedPlace.feastList?.objectID.uriRepresentation().absoluteString ?? "nil"
        let placeKey = savedPlace.applePlaceIDValue ?? "nil"
        return "\(cityKey)|\(placeKey)|\(replacementLocationSearchQuery)"
    }

    private var shouldShowPickDifferentLocation: Bool {
        guard savedPlace.feastList != nil else {
            return false
        }

        return hasAlternativeLocations == true
    }

    private var neighborhoodContextText: String {
        let neighborhoodName = selectedNeighborhoodName ?? "Unsorted"
        return "\(savedPlace.displayCityName) • \(neighborhoodName)"
    }

    private var headerStatusSummary: String {
        "\(status.rawValue) • \(placeType.rawValue)"
    }

    private var allNeighborhoods: [ListSection] {
        savedPlace.feastList?.neighborhoodSections ?? []
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

    private var manualNeighborhoodToCreate: String? {
        guard
            case let .create(neighborhoodName) = selectedNeighborhoodSelection,
            let canonicalNeighborhoodName = FeastNeighborhoodName.canonicalDisplayName(for: neighborhoodName)
        else {
            return nil
        }

        return canonicalNeighborhoodName
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
        var queryComponents = [headerTitle]

        if let neighborhoodName = selectedNeighborhoodName, !neighborhoodName.isEmpty {
            queryComponents.append(neighborhoodName)
        }

        queryComponents.append(savedPlace.displayCityName)
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

    private var headerSection: some View {
        Section {
            FeastFormGroup {
                HStack(alignment: .top, spacing: FeastTheme.Spacing.medium) {
                    VStack(alignment: .leading, spacing: FeastTheme.Spacing.small) {
                        Text(neighborhoodContextText.uppercased())
                            .font(FeastTheme.Typography.sectionLabel)
                            .tracking(0.8)
                            .foregroundStyle(FeastTheme.Colors.secondaryText)
                            .fixedSize(horizontal: false, vertical: true)

                        Text(headerTitle)
                            .font(FeastTheme.Typography.formTitle)
                            .foregroundStyle(FeastTheme.Colors.primaryText)
                            .fixedSize(horizontal: false, vertical: true)

                        if let headerSubtitle {
                            Text(headerSubtitle)
                                .font(FeastTheme.Typography.supporting)
                                .foregroundStyle(FeastTheme.Colors.secondaryText)
                                .fixedSize(horizontal: false, vertical: true)
                        }

                        Text(headerStatusSummary)
                            .font(FeastTheme.Typography.rowMetadata)
                            .foregroundStyle(FeastTheme.Colors.secondaryText)

                        if displayedPlace == nil {
                            Text("Using saved snapshot")
                                .font(FeastTheme.Typography.rowUtility)
                                .foregroundStyle(FeastTheme.Colors.tertiaryText)
                        }
                    }

                    Spacer(minLength: 0)

                    if isResolvingPlace {
                        ProgressView()
                            .controlSize(.small)
                            .padding(.top, 2)
                    }
                }

                if savedPlace.applePlaceIDValue != nil {
                    FeastFormDivider()

                    Button {
                        Task {
                            await openInMaps()
                        }
                    } label: {
                        Label(
                            isOpeningInMaps ? "Opening Maps..." : "Open in Apple Maps",
                            systemImage: "map"
                        )
                    }
                    .buttonStyle(FeastInlineActionButtonStyle())
                    .disabled(isOpeningInMaps)
                }

                if shouldShowPickDifferentLocation {
                    FeastFormDivider()

                    Button {
                        showingLocationPicker = true
                    } label: {
                        Label("Pick Different Location", systemImage: "mappin.circle")
                    }
                    .buttonStyle(FeastInlineActionButtonStyle())
                }
            }
        } header: {
            FeastFormSectionHeader(
                title: "Place Profile",
                subtitle: "City, neighborhood, and place details"
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
                    helper: "Choose Unsorted to keep it at the city level for now."
                ) {
                    Picker("Neighborhood", selection: $selectedNeighborhoodSelection) {
                        Text("Unsorted").tag(AddPlaceNeighborhoodSelection.unsorted)

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
                subtitle: "Move this place without changing its city"
            )
        }
    }

    private var actionsSection: some View {
        Section {
            FeastFormGroup {
                Button(role: .destructive) {
                    showingDeleteConfirmation = true
                } label: {
                    Text("Remove from City")
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        } header: {
            FeastFormSectionHeader(
                title: "Actions",
                subtitle: "Deleting removes the place from \(savedPlace.displayCityName)"
            )
        }
    }

    @MainActor
    private func resolvePlace() async {
        guard let applePlaceID = savedPlace.applePlaceIDValue else {
            resolvedPlace = nil
            return
        }

        isResolvingPlace = true

        defer {
            isResolvingPlace = false
        }

        do {
            resolvedPlace = try await applePlacesService.resolve(placeID: applePlaceID)
            applySuggestedNeighborhoodIfNeeded()
        } catch {
            resolvedPlace = nil
        }
    }

    @MainActor
    private func openInMaps() async {
        guard let applePlaceID = savedPlace.applePlaceIDValue else {
            return
        }

        isOpeningInMaps = true

        defer {
            isOpeningInMaps = false
        }

        do {
            let didOpen = try await applePlacesService.openInMaps(placeID: applePlaceID)
            if !didOpen {
                detailAlert = DetailAlertState(
                    title: "Apple Maps Unavailable",
                    message: "Feast couldn't open this saved place in Apple Maps."
                )
            }
        } catch {
            detailAlert = DetailAlertState(
                title: "Apple Maps Unavailable",
                message: error.localizedDescription
            )
        }
    }

    @MainActor
    private func refreshAlternativeLocationAvailability() async {
        guard
            let feastList = savedPlace.feastList,
            savedPlace.applePlaceIDValue != nil,
            let query = AddPlaceSearchSupport.normalizedSearchQuery(
                from: replacementLocationSearchQuery
            )
        else {
            hasAlternativeLocations = nil
            return
        }

        hasAlternativeLocations = nil

        do {
            let matches = try await AddPlaceSearchSupport.searchMatches(
                for: query,
                using: applePlacesService
            )

            if Task.isCancelled {
                return
            }

            let savedResultIDs = AddPlaceSearchSupport.savedSearchResultIDs(
                for: matches,
                in: feastList,
                excluding: savedPlace,
                repository: repository
            )
            let validAlternatives = AddPlaceSearchSupport.visibleMatches(
                from: matches,
                excluding: savedPlace
            )
            .filter { !savedResultIDs.contains($0.applePlaceID) }

            hasAlternativeLocations = !validAlternatives.isEmpty
        } catch is CancellationError {
            return
        } catch {
            hasAlternativeLocations = nil
        }
    }

    private func saveChanges() {
        do {
            try validateUniqueReplacementLocation()
            let selectedNeighborhood = try resolvedNeighborhoodForSave()
            try repository.update(
                savedPlace,
                with: FeastRepository.SavedPlaceMetadata(
                    status: status,
                    placeType: placeType,
                    cuisines: splitValues(from: cuisinesText),
                    tags: tags,
                    note: normalizedOptional(note),
                    websiteURL: normalizedOptional(websiteURL),
                    instagramURL: normalizedOptional(instagramURL),
                    listSection: selectedNeighborhood,
                    location: selectedReplacementPlace.map { place in
                        FeastRepository.SavedPlaceMetadata.SavedPlaceLocation(
                            applePlaceID: place.applePlaceID,
                            displayNameSnapshot: place.displayName
                        )
                    }
                )
            )
            dismiss()
        } catch {
            detailAlert = DetailAlertState(
                title: "Couldn't Save Changes",
                message: errorMessage(for: error)
            )
        }
    }

    private func validateUniqueReplacementLocation() throws {
        guard
            let replacementPlace = selectedReplacementPlace,
            let feastList = savedPlace.feastList
        else {
            return
        }

        if replacementPlace.applePlaceID == savedPlace.applePlaceIDValue {
            return
        }

        if try repository.hasSavedPlace(
            withApplePlaceID: replacementPlace.applePlaceID,
            in: feastList,
            excluding: savedPlace
        ) {
            throw FeastRepository.SavedPlaceError.duplicateLocationInCity
        }
    }

    private func deletePlace() {
        do {
            try repository.delete(savedPlace)
            dismiss()
        } catch {
            detailAlert = DetailAlertState(
                title: "Couldn't Delete Place",
                message: error.localizedDescription
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

            guard let feastList = savedPlace.feastList else {
                assertionFailure("Attempted to create a neighborhood for a place without a city.")
                return nil
            }

            return try repository.createListSection(
                named: neighborhoodName,
                in: feastList
            )
        }
    }

    private func openExternalURL(
        _ url: URL,
        failureTitle: String,
        failureMessage: String
    ) {
        openURL(url) { accepted in
            if !accepted {
                detailAlert = DetailAlertState(
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
            detailAlert = DetailAlertState(
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

    private func reloadFormStateIfNeeded() {
        guard savedPlace.updatedAtValue != lastLoadedUpdatedAt else {
            return
        }

        let initialNeighborhoodSelection = Self.initialNeighborhoodSelection(for: savedPlace)

        status = savedPlace.placeStatus
        placeType = savedPlace.placeTypeValue
        cuisinesText = savedPlace.cuisines.joined(separator: ", ")
        tags = savedPlace.tags
        note = savedPlace.note ?? ""
        websiteURL = savedPlace.websiteURL ?? ""
        instagramURL = savedPlace.instagramURL ?? ""
        selectedNeighborhoodSelection = initialNeighborhoodSelection
        committedNeighborhoodSelection = initialNeighborhoodSelection
        selectedReplacementPlace = nil
        lastLoadedUpdatedAt = savedPlace.updatedAtValue
    }

    private func applySuggestedNeighborhoodIfNeeded() {
        guard
            savedPlace.listSection == nil,
            selectedReplacementPlace == nil,
            selectedNeighborhoodSelection == .unsorted,
            committedNeighborhoodSelection == .unsorted,
            let feastList = savedPlace.feastList,
            let resolvedPlace
        else {
            return
        }

        let suggestedSelection = PlaceNeighborhoodSuggestionSupport.initialNeighborhoodSelection(
            in: feastList,
            for: resolvedPlace
        )
        guard suggestedSelection != .unsorted else {
            return
        }

        selectedNeighborhoodSelection = suggestedSelection
        committedNeighborhoodSelection = suggestedSelection
    }

    private static func initialNeighborhoodSelection(
        for savedPlace: SavedPlace
    ) -> AddPlaceNeighborhoodSelection {
        guard let neighborhood = savedPlace.listSection else {
            return .unsorted
        }

        return .existing(neighborhood.objectID)
    }

    private func searchInstagram() {
        guard let instagramSearchURL else {
            detailAlert = DetailAlertState(
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
                detailAlert = DetailAlertState(
                    title: "Instagram Search Unavailable",
                    message: "Feast couldn't open this Instagram search."
                )
            }
        }
    }

    private func errorMessage(for error: Error) -> String {
        let message = error.localizedDescription.trimmingCharacters(in: .whitespacesAndNewlines)
        if !message.isEmpty {
            return message
        }

        return "Feast couldn't save this place. Your edits are still on screen."
    }
}

private struct DetailAlertState: Identifiable {
    let id = UUID()
    let title: String
    let message: String
}

#Preview {
    FeastPreviewContainer {
        NavigationStack {
            if let previewPlace = (try? AppServices.preview.repository.fetchSavedPlaces())?.first {
                SavedPlaceDetailView(savedPlace: previewPlace)
            }
        }
    }
}
