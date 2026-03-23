import CoreData
import SwiftUI

struct ListsRootView: View {
    @Environment(\.managedObjectContext) private var viewContext
    @Environment(\.persistenceController) private var persistenceController
    @Environment(\.scenePhase) private var scenePhase

    @FetchRequest(
        sortDescriptors: [
            NSSortDescriptor(key: "createdAt", ascending: true),
            NSSortDescriptor(key: "name", ascending: true)
        ],
        animation: .default
    )
    private var feastLists: FetchedResults<FeastList>

    @FetchRequest(
        sortDescriptors: [],
        animation: .default
    )
    private var savedPlaces: FetchedResults<SavedPlace>

    @State private var showingImportPlaceholder = false
    @State private var listEditor: ListEditorState?
    @State private var listPendingDeletion: FeastList?
    @State private var searchText = ""
    @State private var searchFilters = SavedPlaceSearchFilters()
    @State private var showingSearchFilters = false
    @State private var listSharingPresentation: PreparedFeastListShare?
    @State private var listSharingStates: [NSManagedObjectID: FeastListSharingState] = [:]
    @State private var listPreparingShareObjectID: NSManagedObjectID?
    @State private var alertState: ListsAlertState?

    var body: some View {
        content
            .toolbar { toolbarContent }
            .listStyle(.insetGrouped)
            .navigationTitle("Lists")
            .navigationBarTitleDisplayMode(.large)
            .searchable(text: $searchText, prompt: "Search saved places")
            .sheet(item: $listEditor) { editor in
                NavigationStack {
                    ListNameEditorSheet(
                        title: editor.title,
                        initialName: editor.initialName
                    ) { newName in
                        if let feastList = editor.feastList {
                            rename(feastList, to: newName)
                        } else {
                            createList(named: newName)
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
                    persistenceController: persistenceController,
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
                "Delete this list?",
                isPresented: deleteDialogBinding,
                titleVisibility: .visible,
                presenting: listPendingDeletion
            ) { feastList in
                Button("Delete List", role: .destructive) {
                    delete(feastList)
                }
                Button("Cancel", role: .cancel) {
                    listPendingDeletion = nil
                }
            } message: { feastList in
                Text("This will remove \(feastList.displayName), its sections, and its saved places.")
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
            listsSection
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

                    Text("Your default lists are ready. Import from Notes when you want to bring in your first saved places.")
                        .font(FeastTheme.Typography.supporting)
                        .foregroundStyle(FeastTheme.Colors.secondaryNeutral)

                    Button("Import from Notes") {
                        showingImportPlaceholder = true
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(FeastTheme.Colors.primaryAccent)
                }
                .padding(.vertical, FeastTheme.Spacing.xSmall)
            }
        }
    }

    @ViewBuilder
    private var searchResultsSection: some View {
        if isShowingSearchResults {
            Section("Places") {
                if let searchSummaryText {
                    Text(searchSummaryText)
                        .font(FeastTheme.Typography.supporting)
                        .foregroundStyle(FeastTheme.Colors.secondaryNeutral)
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
        }
    }

    private var listsSection: some View {
        Section("Lists") {
            if feastLists.isEmpty {
                ContentUnavailableView(
                    "No Lists Yet",
                    systemImage: "square.stack",
                    description: Text("Create a list to start organizing places.")
                )
            } else {
                ForEach(feastLists) { feastList in
                    listLink(for: feastList)
                }
            }
        }
    }

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItemGroup(placement: .topBarTrailing) {
            Button {
                showingSearchFilters = true
            } label: {
                Image(systemName: searchFilters.hasActiveFilters ? "line.3.horizontal.decrease.circle.fill" : "line.3.horizontal.decrease.circle")
            }

            Button {
                listEditor = ListEditorState(title: "New List", initialName: "", feastList: nil)
            } label: {
                Image(systemName: "plus")
            }

            Menu {
                Button("Import from Notes") {
                    showingImportPlaceholder = true
                }
            } label: {
                Image(systemName: "ellipsis.circle")
            }
        }
    }

    private var repository: FeastRepository {
        FeastRepository(
            context: viewContext,
            persistenceController: persistenceController
        )
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
            components.append("List: \(feastList.displayName)")
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
            VStack(alignment: .leading, spacing: FeastTheme.Spacing.xSmall) {
                Text(feastList.displayName)
                    .font(FeastTheme.Typography.body.weight(.semibold))
                    .foregroundStyle(FeastTheme.Colors.primaryText)

                Text("\(feastList.savedPlaceCount) saved • \(feastList.sectionSummary)")
                    .font(FeastTheme.Typography.supporting)
                    .foregroundStyle(FeastTheme.Colors.secondaryNeutral)

                if let roleBadgeText = sharingState.roleBadgeText {
                    Text(roleBadgeText)
                        .font(FeastTheme.Typography.caption)
                        .foregroundStyle(FeastTheme.Colors.secondaryAccent)
                }
            }

            Spacer(minLength: FeastTheme.Spacing.small)

            if listPreparingShareObjectID == feastList.objectID {
                ProgressView()
                    .controlSize(.small)
                    .padding(.top, 2)
            } else if sharingState.isShared {
                Image(systemName: "person.2.fill")
                    .foregroundStyle(FeastTheme.Colors.secondaryAccent)
                    .padding(.top, 2)
            }
        }
        .padding(.vertical, FeastTheme.Spacing.xSmall)
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

            Button("Rename") {
                listEditor = ListEditorState(
                    title: "Rename List",
                    initialName: feastList.displayName,
                    feastList: feastList
                )
            }

            if sharingState.canDeleteList {
                Button("Delete List", role: .destructive) {
                    listPendingDeletion = feastList
                }
            } else {
                Button("Only the Owner Can Delete This List") { }
                    .disabled(true)
            }
        }
        .swipeActions(edge: .leading, allowsFullSwipe: false) {
            if sharingState.canManageSharing {
                Button(sharingState.shareActionTitle) {
                    beginSharing(for: feastList)
                }
                .tint(FeastTheme.Colors.primaryAccent)
            }
        }
        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
            if sharingState.canDeleteList {
                Button("Delete", role: .destructive) {
                    listPendingDeletion = feastList
                }
            }

            Button("Rename") {
                listEditor = ListEditorState(
                    title: "Rename List",
                    initialName: feastList.displayName,
                    feastList: feastList
                )
            }
            .tint(FeastTheme.Colors.secondaryAccent)
        }
    }

    private func createList(named name: String) {
        do {
            try repository.createFeastList(named: name)
            listEditor = nil
            refreshSharingStates()
        } catch {
            alertState = ListsAlertState(
                title: "Couldn't Create List",
                message: error.localizedDescription
            )
        }
    }

    private func rename(_ feastList: FeastList, to name: String) {
        do {
            try repository.rename(feastList, to: name)
            listEditor = nil
        } catch {
            alertState = ListsAlertState(
                title: "Couldn't Rename List",
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
                title: "Couldn't Delete List",
                message: error.localizedDescription
            )
        }
    }

    private func listSharingState(for feastList: FeastList) -> FeastListSharingState {
        listSharingStates[feastList.objectID] ?? persistenceController.sharingState(for: feastList)
    }

    private func refreshSharingStates() {
        listSharingStates = Dictionary(
            uniqueKeysWithValues: feastLists.map { feastList in
                (feastList.objectID, persistenceController.sharingState(for: feastList))
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
                let preparedShare = try await persistenceController.prepareShare(for: feastList)
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
}

private struct ListEditorState: Identifiable {
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

private struct ListNameEditorSheet: View {
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
        Form {
            TextField("List name", text: $name)
                .textInputAutocapitalization(.words)
                .autocorrectionDisabled()
        }
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Cancel") {
                    dismiss()
                }
            }

            ToolbarItem(placement: .confirmationAction) {
                Button("Save") {
                    onSave(name)
                    dismiss()
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
