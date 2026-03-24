import CoreData
import SwiftUI

struct ListsRootView: View {
    @Environment(\.managedObjectContext) private var viewContext
    @Environment(\.persistenceController) private var persistenceController
    @Environment(\.scenePhase) private var scenePhase

    @FetchRequest(fetchRequest: Self.feastListsFetchRequest, animation: .default)
    private var feastLists: FetchedResults<FeastList>

    @FetchRequest(fetchRequest: Self.savedPlacesFetchRequest, animation: .default)
    private var savedPlaces: FetchedResults<SavedPlace>

    @State private var showingImportPlaceholder = false
    @State private var cityEditor: CityEditorState?
    @State private var listPendingDeletion: FeastList?
    @State private var searchText = ""
    @State private var searchFilters = SavedPlaceSearchFilters()
    @State private var showingSearchFilters = false
    @State private var listSharingPresentation: PreparedFeastListShare?
    @State private var listSharingStates: [NSManagedObjectID: FeastListSharingState] = [:]
    @State private var listPreparingShareObjectID: NSManagedObjectID?
    @State private var alertState: ListsAlertState?

    private static let feastListsFetchRequest: NSFetchRequest<FeastList> = {
        let request = FeastList.fetchRequest()
        request.sortDescriptors = [
            NSSortDescriptor(key: "createdAt", ascending: true),
            NSSortDescriptor(key: "name", ascending: true)
        ]
        return request
    }()

    private static let savedPlacesFetchRequest: NSFetchRequest<SavedPlace> = {
        let request = SavedPlace.fetchRequest()
        request.sortDescriptors = []
        return request
    }()

    var body: some View {
        content
            .feastScrollableChrome()
            .toolbar { toolbarContent }
            .listStyle(.insetGrouped)
            .navigationBarTitleDisplayMode(.inline)
            .searchable(text: $searchText, prompt: "Search places across cities")
            .sheet(item: $cityEditor) { editor in
                NavigationStack {
                    CityNameEditorSheet(
                        title: editor.title,
                        initialName: editor.initialName
                    ) { newName in
                        if let feastList = editor.feastList {
                            renameCity(feastList, to: newName)
                        } else {
                            createCity(named: newName)
                        }
                    }
                }
            }
            .sheet(isPresented: $showingSearchFilters) {
                NavigationStack {
                    SavedPlaceFilterSheet(
                        filters: $searchFilters,
                        availableLists: Array(feastLists),
                        availableCuisines: availableCuisines,
                        fixedFeastList: nil
                    )
                }
            }
            .sheet(item: $listSharingPresentation, onDismiss: refreshSharingStates) { preparedShare in
                FeastListSharingSheet(
                    preparedShare: preparedShare,
                    persistenceController: activePersistenceController,
                    onDidSaveShare: refreshSharingStates,
                    onDidStopSharing: refreshSharingStates,
                    onError: { error in
                        alertState = ListsAlertState(
                            title: "Couldn't Update Sharing",
                            message: error.localizedDescription
                        )
                    }
                )
            }
            .confirmationDialog(
                "Delete this city?",
                isPresented: deleteDialogBinding,
                titleVisibility: .visible,
                presenting: listPendingDeletion
            ) { feastList in
                Button("Delete City", role: .destructive) {
                    delete(feastList)
                }
                Button("Cancel", role: .cancel) {
                    listPendingDeletion = nil
                }
            } message: { feastList in
                Text("This will remove \(feastList.displayName), its neighborhoods, and its saved places.")
            }
            .alert("Import from Notes", isPresented: $showingImportPlaceholder) {
                Button("OK", role: .cancel) { }
            } message: {
                Text("Import is part of the locked Feast v1 plan, but the flow is not implemented yet.")
            }
            .alert(item: $alertState) { alert in
                Alert(
                    title: Text(alert.title),
                    message: Text(alert.message),
                    dismissButton: .default(Text("OK"))
                )
            }
            .task(id: feastListRefreshKey) {
                refreshSharingStates()
            }
            .onChange(of: scenePhase) { _, newPhase in
                if newPhase == .active {
                    refreshSharingStates()
                }
            }
    }

    private var content: some View {
        List {
            importCallToActionSection
            searchResultsSection
            citiesSection
        }
    }

    private var filteredSavedPlaces: [SavedPlace] {
        SavedPlaceSearchEngine.filteredPlaces(
            from: Array(savedPlaces),
            query: searchText,
            filters: searchFilters
        )
    }

    private var isShowingSearchResults: Bool {
        !searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || searchFilters.hasActiveFilters
    }

    private var availableCuisines: [String] {
        SavedPlaceSearchEngine.availableCuisines(
            from: Array(savedPlaces),
            filters: searchFilters
        )
    }

    @ViewBuilder
    private var importCallToActionSection: some View {
        if savedPlaces.isEmpty {
            Section {
                VStack(alignment: .leading, spacing: FeastTheme.Spacing.small) {
                    Text("Start by importing places")
                        .font(FeastTheme.Typography.body.weight(.semibold))
                        .foregroundStyle(FeastTheme.Colors.primaryText)

                    Text("Your starter cities are ready. Import from Notes when you want to bring in your first saved places.")
                        .font(FeastTheme.Typography.supporting)
                        .foregroundStyle(FeastTheme.Colors.secondaryText)

                    Button("Import from Notes") {
                        showingImportPlaceholder = true
                    }
                    .buttonStyle(FeastProminentButtonStyle())
                }
                .padding(.vertical, FeastTheme.Spacing.xSmall)
            }
            .feastSectionSurface()
        }
    }

    @ViewBuilder
    private var searchResultsSection: some View {
        if isShowingSearchResults {
            Section("Places") {
                if let searchSummaryText {
                    Text(searchSummaryText)
                        .font(FeastTheme.Typography.rowUtility)
                        .foregroundStyle(FeastTheme.Colors.tertiaryText)
                }

                if filteredSavedPlaces.isEmpty {
                    ContentUnavailableView(
                        "No Matching Places",
                        systemImage: "magnifyingglass",
                        description: Text("Try a different search or adjust your filters.")
                    )
                } else {
                    ForEach(filteredSavedPlaces) { place in
                        SavedPlaceListRow(place: place, showsLocationContext: true)
                    }
                }
            }
            .feastSectionSurface()
        }
    }

    private var citiesSection: some View {
        Section {
            if feastLists.isEmpty {
                ContentUnavailableView(
                    "No Cities Yet",
                    systemImage: "square.stack",
                    description: Text("Create a city to start organizing places.")
                )
            } else {
                ForEach(feastLists) { feastList in
                    listLink(for: feastList)
                }
            }
        }
        .feastSectionSurface()
    }

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItem(placement: .principal) {
            HStack(spacing: 0) {
                BrandWordmarkView()
                    .frame(maxWidth: .infinity, alignment: .leading)

                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }

        ToolbarItem(placement: .topBarTrailing) {
            FeastToolbarActionCluster {
                Button {
                    showingSearchFilters = true
                } label: {
                    FeastToolbarSymbol(
                        systemName: "line.3.horizontal.decrease",
                        isEmphasized: searchFilters.hasActiveFilters
                    )
                    .frame(width: 36, height: 36)
                    .contentShape(Rectangle())
                }

                Button {
                    cityEditor = CityEditorState(title: "New City", initialName: "", feastList: nil)
                } label: {
                    FeastToolbarSymbol(systemName: "plus")
                        .frame(width: 36, height: 36)
                        .contentShape(Rectangle())
                }

                Menu {
                    Button("Import from Notes") {
                        showingImportPlaceholder = true
                    }
                } label: {
                    FeastToolbarSymbol(systemName: "ellipsis")
                        .frame(width: 36, height: 36)
                        .contentShape(Rectangle())
                }
            }
        }
    }

    private var repository: FeastRepository {
        FeastRepository(
            context: viewContext,
            persistenceController: persistenceController
        )
    }

    private var activePersistenceController: PersistenceController {
        guard let persistenceController else {
            preconditionFailure("Missing persistence controller in ListsRootView.")
        }

        return persistenceController
    }

    private var feastListRefreshKey: String {
        feastLists.map(\.objectURIString).joined(separator: "|")
    }

    private var searchSummaryText: String? {
        var components: [String] = []

        let trimmedSearchText = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedSearchText.isEmpty {
            components.append("Search: \(trimmedSearchText)")
        }

        if let feastList = feastLists.first(where: { $0.objectURIString == searchFilters.selectedListURIString }) {
            components.append("City: \(feastList.displayName)")
        }

        if let status = searchFilters.selectedStatus {
            components.append("Status: \(status.rawValue)")
        }

        if let placeType = searchFilters.selectedPlaceType {
            components.append("Type: \(placeType.rawValue)")
        }

        if let cuisine = searchFilters.selectedCuisine {
            components.append("Cuisine: \(cuisine)")
        }

        guard !components.isEmpty else {
            return nil
        }

        return components.joined(separator: " • ")
    }

    private var deleteDialogBinding: Binding<Bool> {
        Binding(
            get: { listPendingDeletion != nil },
            set: { isPresented in
                if !isPresented {
                    listPendingDeletion = nil
                }
            }
        )
    }

    private func listRow(for feastList: FeastList) -> some View {
        let sharingState = listSharingState(for: feastList)

        return HStack(alignment: .top, spacing: FeastTheme.Spacing.small) {
            VStack(alignment: .leading, spacing: 3) {
                Text(feastList.displayName)
                    .font(FeastTheme.Typography.listTitle)
                    .foregroundStyle(FeastTheme.Colors.primaryText)
                    .lineLimit(1)
                    .minimumScaleFactor(0.82)

                Text(listPrimaryMetadata(for: feastList))
                    .font(FeastTheme.Typography.rowMetadata)
                    .foregroundStyle(FeastTheme.Colors.secondaryText)
                    .lineLimit(1)
                    .minimumScaleFactor(0.88)

                if let listSecondaryMetadata = listSecondaryMetadata(for: feastList) {
                    Text(listSecondaryMetadata)
                        .font(FeastTheme.Typography.rowUtility)
                        .foregroundStyle(FeastTheme.Colors.tertiaryText)
                        .lineLimit(2)
                }

                if let roleBadgeText = sharingState.roleBadgeText {
                    Text(roleBadgeText)
                        .font(FeastTheme.Typography.rowUtility)
                        .foregroundStyle(FeastTheme.Colors.tertiaryText)
                        .lineLimit(2)
                }
            }

            Spacer(minLength: FeastTheme.Spacing.small)

            if listPreparingShareObjectID == feastList.objectID {
                ProgressView()
                    .controlSize(.small)
                    .padding(.top, 2)
            } else if sharingState.isShared {
                Image(systemName: "person.2.fill")
                    .foregroundStyle(FeastTheme.Colors.tertiaryText)
                    .padding(.top, 2)
            }
        }
        .padding(.vertical, 6)
    }

    private func listLink(for feastList: FeastList) -> some View {
        let sharingState = listSharingState(for: feastList)

        return NavigationLink {
            FeastListDetailView(feastList: feastList)
        } label: {
            listRow(for: feastList)
        }
        .contextMenu {
            if sharingState.canManageSharing {
                Button(sharingState.shareActionTitle) {
                    beginSharing(for: feastList)
                }
            } else {
                Button("Sharing Managed by Owner") { }
                    .disabled(true)
            }

            Button("Rename City") {
                cityEditor = CityEditorState(
                    title: "Rename City",
                    initialName: feastList.displayName,
                    feastList: feastList
                )
            }

            if sharingState.canDeleteList {
                Button("Delete City", role: .destructive) {
                    listPendingDeletion = feastList
                }
            } else {
                Button("Only the Owner Can Delete This City") { }
                    .disabled(true)
            }
        }
        .swipeActions(edge: .leading, allowsFullSwipe: false) {
            if sharingState.canManageSharing {
                Button(sharingState.shareActionTitle) {
                    beginSharing(for: feastList)
                }
                .tint(FeastTheme.Colors.secondaryAction)
            }
        }
        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
            if sharingState.canDeleteList {
                Button("Delete City", role: .destructive) {
                    listPendingDeletion = feastList
                }
            }

            Button("Rename City") {
                cityEditor = CityEditorState(
                    title: "Rename City",
                    initialName: feastList.displayName,
                    feastList: feastList
                )
            }
            .tint(FeastTheme.Colors.secondaryAction)
        }
    }

    private func createCity(named name: String) {
        do {
            try repository.createFeastList(named: name)
            cityEditor = nil
            refreshSharingStates()
        } catch {
            alertState = ListsAlertState(
                title: "Couldn't Create City",
                message: error.localizedDescription
            )
        }
    }

    private func renameCity(_ feastList: FeastList, to name: String) {
        do {
            try repository.rename(feastList, to: name)
            cityEditor = nil
        } catch {
            alertState = ListsAlertState(
                title: "Couldn't Rename City",
                message: error.localizedDescription
            )
        }
    }

    private func delete(_ feastList: FeastList) {
        do {
            try repository.delete(feastList)
            listPendingDeletion = nil
            refreshSharingStates()
        } catch {
            alertState = ListsAlertState(
                title: "Couldn't Delete City",
                message: error.localizedDescription
            )
        }
    }

    private func listSharingState(for feastList: FeastList) -> FeastListSharingState {
        listSharingStates[feastList.objectID] ?? activePersistenceController.sharingState(for: feastList)
    }

    private func refreshSharingStates() {
        listSharingStates = Dictionary(
            uniqueKeysWithValues: feastLists.map { feastList in
                (feastList.objectID, activePersistenceController.sharingState(for: feastList))
            }
        )
    }

    private func beginSharing(for feastList: FeastList) {
        guard listPreparingShareObjectID == nil else {
            return
        }

        listPreparingShareObjectID = feastList.objectID

        Task { @MainActor in
            defer {
                listPreparingShareObjectID = nil
            }

            do {
                let preparedShare = try await activePersistenceController.prepareShare(for: feastList)
                listSharingStates[feastList.objectID] = .shared(role: .owner)
                listSharingPresentation = preparedShare
            } catch {
                alertState = ListsAlertState(
                    title: "Couldn't Open Sharing",
                    message: error.localizedDescription
                )
            }
        }
    }

    private func listPrimaryMetadata(for feastList: FeastList) -> String {
        let savedPlacesLabel = "\(feastList.savedPlaceCount) saved"
        let topLevelSectionCount = feastList.neighborhoodSections.count

        guard topLevelSectionCount > 0 else {
            return savedPlacesLabel
        }

        let neighborhoodLabel = topLevelSectionCount == 1 ? "1 neighborhood" : "\(topLevelSectionCount) neighborhoods"
        return "\(savedPlacesLabel) • \(neighborhoodLabel)"
    }

    private func listSecondaryMetadata(for feastList: FeastList) -> String? {
        let topLevelSectionNames = feastList.neighborhoodSections.map(\.displayName)

        guard !topLevelSectionNames.isEmpty else {
            return "Add neighborhoods to organize places"
        }

        let visibleNames = Array(topLevelSectionNames.prefix(2))
        let remainingCount = topLevelSectionNames.count - visibleNames.count
        let remainingSuffix = remainingCount > 0 ? " +\(remainingCount)" : ""

        return visibleNames.joined(separator: " • ") + remainingSuffix
    }
}

private struct CityEditorState: Identifiable {
    let id = UUID()
    let title: String
    let initialName: String
    let feastList: FeastList?
}

private struct ListsAlertState: Identifiable {
    let id = UUID()
    let title: String
    let message: String
}

private struct CityNameEditorSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State private var name: String

    let title: String
    let onSave: (String) -> Void

    init(title: String, initialName: String, onSave: @escaping (String) -> Void) {
        self.title = title
        self.onSave = onSave
        _name = State(initialValue: initialName)
    }

    var body: some View {
        List {
            Section {
                FeastFormGroup {
                    FeastFormField(
                        title: "City Name",
                        helper: "Use a city name people will recognize quickly, like NYC, London, or Philadelphia."
                    ) {
                        TextField("City name", text: $name)
                            .textInputAutocapitalization(.words)
                            .autocorrectionDisabled()
                            .feastFieldSurface(minHeight: 52)
                    }
                }
            } header: {
                FeastFormSectionHeader(
                    title: "Name",
                    subtitle: "Cities are the top-level buckets in Feast"
                )
            }
        }
        .feastScrollableChrome()
        .listStyle(.insetGrouped)
        .scrollDismissesKeyboard(.interactively)
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Cancel") {
                    dismiss()
                }
            }

            ToolbarItem(placement: .confirmationAction) {
                Button {
                    onSave(name)
                    dismiss()
                } label: {
                    Text("Save")
                        .fontWeight(.semibold)
                }
            }
        }
    }
}

#Preview {
    FeastPreviewContainer {
        NavigationStack {
            ListsRootView()
        }
    }
}
