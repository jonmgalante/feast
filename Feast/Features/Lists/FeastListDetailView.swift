import CoreData
import SwiftUI

struct FeastListDetailView: View {
    @EnvironmentObject private var browse: SavedPlaceBrowseState
    @Environment(\.managedObjectContext) private var viewContext
    @Environment(\.persistenceController) private var persistenceController
    @ObservedObject var feastList: FeastList
    @FetchRequest private var neighborhoodSections: FetchedResults<ListSection>
    @FetchRequest private var savedPlaces: FetchedResults<SavedPlace>
    @State private var neighborhoodEditor: NeighborhoodEditorState?
    @State private var neighborhoodPendingDeletion: ListSection?
    @State private var showingAddPlaceSheet = false
    private var searchText: String { browse.filters.queryText }
    private var searchFilters: SavedPlaceSearchFilters { browse.filters }
    @State private var showingSearchFilters = false
    @State private var listSharingPresentation: PreparedFeastListShare?
    @State private var listPreparingShare = false
    @State private var alertState: FeastListDetailAlertState?

    init(feastList: FeastList) {
        self.feastList = feastList
        _neighborhoodSections = FetchRequest(
            fetchRequest: Self.neighborhoodSectionsFetchRequest(for: feastList),
            animation: .default
        )
        _savedPlaces = FetchRequest(
            fetchRequest: Self.savedPlacesFetchRequest(for: feastList),
            animation: .default
        )
    }

    var body: some View {
        content
            .rememberBrowseScroll(feastList.objectURIString)
            .feastScrollableChrome()
            .toolbar { toolbarContent }
            .listStyle(.insetGrouped)
            .navigationTitle(feastList.displayName)
            .navigationBarTitleDisplayMode(.inline)
            .searchable(text: $browse.filters.queryText, prompt: "Search places in \(feastList.displayName)")
            .sheet(item: $neighborhoodEditor) { editor in
                NavigationStack {
                    NeighborhoodNameEditorSheet(
                        title: editor.title,
                        initialName: editor.initialName
                    ) { newName in
                        if let neighborhood = editor.neighborhood {
                            renameNeighborhood(neighborhood, to: newName)
                        } else {
                            createNeighborhood(named: newName)
                        }
                    }
                }
            }
            .confirmationDialog(
                "Delete this neighborhood?",
                isPresented: deleteDialogBinding,
                titleVisibility: .visible,
                presenting: neighborhoodPendingDeletion
            ) { neighborhood in
                Button("Delete Neighborhood", role: .destructive) {
                    deleteNeighborhood(neighborhood)
                }
                Button("Cancel", role: .cancel) {
                    neighborhoodPendingDeletion = nil
                }
            } message: { neighborhood in
                Text(deleteMessage(for: neighborhood))
            }
            .sheet(isPresented: $showingAddPlaceSheet) {
                NavigationStack {
                    AddPlaceView(feastList: feastList)
                }
            }
            .sheet(isPresented: $showingSearchFilters) {
                NavigationStack {
                    SavedPlaceFilterSheet(
                        filters: $browse.filters,
                        availableLists: [],
                        availableCuisines: availableCuisines,
                        fixedFeastList: feastList,
                        availableTags: FeastTag.catalog(from: citySavedPlaces.map(\.tags))
                    )
                }
            }
            .sheet(item: $listSharingPresentation) { preparedShare in
                FeastListSharingSheet(
                    preparedShare: preparedShare,
                    persistenceController: activePersistenceController,
                    onDidSaveShare: { },
                    onDidStopSharing: { },
                    onError: { error in
                        alertState = FeastListDetailAlertState(
                            title: "Couldn't Update Sharing",
                            message: error.localizedDescription
                        )
                    }
                )
            }
            .alert(item: $alertState) { alert in
                Alert(
                    title: Text(alert.title),
                    message: Text(alert.message),
                    dismissButton: .default(Text("OK"))
                )
            }
            .safeAreaInset(edge: .bottom) {
                addPlaceCallToAction
            }
    }

    private var content: some View {
        List {
            if isShowingSearchResults {
                if searchFilters.hasContentFilters {
                    groupedSearchResults
                } else {
                    searchResultsSection
                }
            } else {
                if citySavedPlaces.isEmpty {
                    emptyStateSection
                }
                if !citySavedPlaces.isEmpty || !neighborhoodSections.isEmpty {
                    ForEach(neighborhoodSections) { section in
                        neighborhoodSection(section)
                    }
                    unsortedSection(unsortedSavedPlaces)
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
            preconditionFailure("Missing persistence controller in FeastListDetailView.")
        }

        return persistenceController
    }

    private var sharingState: FeastListSharingState {
        activePersistenceController.sharingState(for: feastList)
    }

    private static func neighborhoodSectionsFetchRequest(
        for feastList: FeastList
    ) -> NSFetchRequest<ListSection> {
        let request = ListSection.fetchRequest()
        request.sortDescriptors = [
            NSSortDescriptor(key: "name", ascending: true),
            NSSortDescriptor(key: "createdAt", ascending: true)
        ]
        request.predicate = NSCompoundPredicate(andPredicateWithSubpredicates: [
            NSPredicate(format: "feastList == %@", feastList),
            NSPredicate(format: "parent == nil")
        ])
        return request
    }

    private static func savedPlacesFetchRequest(
        for feastList: FeastList
    ) -> NSFetchRequest<SavedPlace> {
        let request = SavedPlace.fetchRequest()
        request.sortDescriptors = [
            NSSortDescriptor(key: "updatedAt", ascending: false),
            NSSortDescriptor(key: "displayNameSnapshot", ascending: true)
        ]
        request.predicate = NSPredicate(format: "feastList == %@", feastList)
        return request
    }

    private var citySavedPlaces: [SavedPlace] {
        Array(savedPlaces)
    }

    private var unsortedSavedPlaces: [SavedPlace] {
        citySavedPlaces.filter { $0.listSection == nil }
    }

    private var savedPlacesByNeighborhoodID: [NSManagedObjectID: [SavedPlace]] {
        citySavedPlaces.reduce(into: [NSManagedObjectID: [SavedPlace]]()) { groupedPlaces, place in
            guard let neighborhoodID = place.listSection?.objectID else {
                return
            }

            groupedPlaces[neighborhoodID, default: []].append(place)
        }
    }

    private var filteredSavedPlaces: [SavedPlace] {
        SavedPlaceSearchEngine.filteredPlaces(
            from: citySavedPlaces,
            query: searchText,
            filters: searchFilters,
            fixedFeastList: feastList
        )
    }

    private var isShowingSearchResults: Bool {
        !searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || searchFilters.hasCriteria
    }

    private var availableCuisines: [String] {
        SavedPlaceSearchEngine.availableCuisines(
            from: citySavedPlaces,
            fixedFeastList: feastList
        )
    }

    private var deleteDialogBinding: Binding<Bool> {
        Binding(
            get: { neighborhoodPendingDeletion != nil },
            set: { isPresented in
                if !isPresented {
                    neighborhoodPendingDeletion = nil
                }
            }
        )
    }

    private var addPlaceCallToAction: some View {
        Button {
            showingAddPlaceSheet = true
        } label: {
            Label("Add Place", systemImage: "plus")
                .font(FeastTheme.Typography.rowTitle)
                .frame(maxWidth: .infinity)
        }
        .buttonStyle(FeastProminentButtonStyle(size: .compactBottomBar))
        .feastBottomBarChrome()
    }

    private var searchResultsSection: some View {
        Section("Places") {
            if let searchSummaryText {
                Text(searchSummaryText)
                    .font(FeastTheme.Typography.rowUtility)
                    .foregroundStyle(FeastTheme.Colors.tertiaryText)
            }

            if filteredSavedPlaces.isEmpty {
                SavedPlaceEmptyState(
                    reason: SavedPlaceEmptyReason.evaluate(places: citySavedPlaces, filters: searchFilters, fixedCity: feastList),
                    scopeName: feastList.displayName
                )
            } else {
                ForEach(filteredSavedPlaces) { place in
                    SavedPlaceListRow(place: place)
                }
            }
        }
        .feastSectionSurface()
    }

    @ViewBuilder
    private var groupedSearchResults: some View {
        let matches = filteredSavedPlaces
        let groups = CityFilteredPlaceGroups(
            matchingPlaces: matches,
            neighborhoods: Array(neighborhoodSections)
        )

        Section("Places") {
            if let searchSummaryText {
                Text(searchSummaryText)
                    .font(FeastTheme.Typography.rowUtility)
                    .foregroundStyle(FeastTheme.Colors.tertiaryText)
            }
            Text(matchingPlaceCount(matches.count))
                .font(FeastTheme.Typography.rowUtility)
                .foregroundStyle(FeastTheme.Colors.secondaryText)

            if matches.isEmpty {
                SavedPlaceEmptyState(
                    reason: SavedPlaceEmptyReason.evaluate(places: citySavedPlaces, filters: searchFilters, fixedCity: feastList),
                    scopeName: feastList.displayName
                )
            }
        }
        .feastSectionSurface()

        ForEach(groups.neighborhoods) { group in
            neighborhoodSection(group.section, matchingPlaces: group.places)
        }
        unsortedSection(groups.unsorted, isFiltered: true)

        if !groups.otherMatches.isEmpty {
            Section("Other matching places") {
                ForEach(groups.otherMatches) { place in
                    SavedPlaceListRow(place: place, showsLocationContext: true)
                }
            }
            .feastSectionSurface()
        }
    }

    private func matchingPlaceCount(_ count: Int) -> String {
        "\(count) matching \(count == 1 ? "place" : "places")"
    }

    private var emptyStateSection: some View {
        Section {
            VStack(alignment: .leading, spacing: FeastTheme.Spacing.medium) {
                Text("No saved places in \(feastList.displayName) yet.")
                    .font(FeastTheme.Typography.body.weight(.semibold))
                    .foregroundStyle(FeastTheme.Colors.primaryText)

                Text("Use Add Place below to save your first Apple Maps match. Neighborhoods are optional.")
                    .font(FeastTheme.Typography.supporting)
                    .foregroundStyle(FeastTheme.Colors.secondaryText)

            }
            .padding(.vertical, FeastTheme.Spacing.xSmall)
        }
        .feastSectionSurface()
    }

    @ViewBuilder
    private func unsortedSection(_ places: [SavedPlace], isFiltered: Bool = false) -> some View {
        if !places.isEmpty {
            Section {
                ForEach(places) { place in
                    SavedPlaceListRow(place: place)
                }
            } header: {
                NeighborhoodHeaderView(
                    title: "Unsorted",
                    kind: .unsorted,
                    subtitle: isFiltered ? matchingPlaceCount(places.count) : "Places without a neighborhood"
                ) {
                    EmptyView()
                }
            }
            .feastSectionSurface()
        }
    }

    private func neighborhoodSection(_ neighborhood: ListSection, matchingPlaces: [SavedPlace]? = nil) -> some View {
        Section {
            neighborhoodContent(neighborhood, matchingPlaces: matchingPlaces)
        } header: {
            NeighborhoodHeaderView(
                title: neighborhood.displayName,
                kind: .neighborhood,
                subtitle: matchingPlaces.map { matchingPlaceCount($0.count) }
            ) {
                Menu {
                    Button("Rename Neighborhood") {
                        neighborhoodEditor = NeighborhoodEditorState(
                            title: "Rename Neighborhood",
                            initialName: neighborhood.displayName,
                            neighborhood: neighborhood
                        )
                    }

                    Button("Delete Neighborhood", role: .destructive) {
                        neighborhoodPendingDeletion = neighborhood
                    }
                } label: {
                    NeighborhoodHeaderActionLabel()
                }
                .accessibilityLabel("Neighborhood Actions")
            }
        }
        .feastSectionSurface()
    }

    @ViewBuilder
    private func neighborhoodContent(_ neighborhood: ListSection, matchingPlaces: [SavedPlace]? = nil) -> some View {
        let places = matchingPlaces ?? savedPlacesByNeighborhoodID[neighborhood.objectID] ?? []

        if places.isEmpty {
            EmptyNeighborhoodRow()
        } else {
            ForEach(places) { place in
                SavedPlaceListRow(place: place)
            }
        }
    }

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItemGroup(placement: .topBarTrailing) {
            Button {
                showingSearchFilters = true
            } label: {
                FeastToolbarSymbol(
                    systemName: "slider.horizontal.3",
                    isEmphasized: searchFilters.hasCriteria
                )
            }
            .accessibilityLabel("Filter places")

            Menu {
                Button("Add Neighborhood") {
                    presentAddNeighborhoodEditor()
                }
            } label: {
                AddNeighborhoodIcon()
            }
            .accessibilityLabel("Add Neighborhood")
        }
    }

    private var sharingToolbarSymbolName: String {
        sharingState.isShared ? "person.2.fill" : "square.and.arrow.up"
    }

    private var sharingToolbarAccessibilityLabel: String {
        if sharingState.canManageSharing {
            return sharingState.shareActionTitle
        }

        return "Sharing Managed by Owner"
    }

    private var searchSummaryText: String? {
        var components: [String] = []

        let trimmedSearchText = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedSearchText.isEmpty {
            components.append("Search: \(trimmedSearchText)")
        }

        if let criteria = searchFilters.summary { components.append(criteria) }

        guard !components.isEmpty else {
            return nil
        }

        return components.joined(separator: " • ")
    }

    private func presentAddNeighborhoodEditor() {
        neighborhoodEditor = NeighborhoodEditorState(
            title: "Add Neighborhood",
            initialName: "",
            neighborhood: nil
        )
    }

    private func createNeighborhood(named name: String) {
        do {
            try repository.createListSection(named: name, in: feastList)
            neighborhoodEditor = nil
        } catch {
            alertState = FeastListDetailAlertState(title: "Couldn't Save Neighborhood", message: error.localizedDescription)
        }
    }

    private func renameNeighborhood(_ neighborhood: ListSection, to name: String) {
        do {
            try repository.rename(neighborhood, to: name)
            neighborhoodEditor = nil
        } catch {
            alertState = FeastListDetailAlertState(title: "Couldn't Save Neighborhood", message: error.localizedDescription)
        }
    }

    private func deleteNeighborhood(_ neighborhood: ListSection) {
        do {
            try repository.delete(neighborhood)
            neighborhoodPendingDeletion = nil
        } catch {
            alertState = FeastListDetailAlertState(title: "Couldn't Save Neighborhood", message: error.localizedDescription)
        }
    }

    private func beginSharing() {
        guard !listPreparingShare else {
            return
        }

        listPreparingShare = true

        Task { @MainActor in
            defer {
                listPreparingShare = false
            }

            do {
                listSharingPresentation = try await activePersistenceController.prepareShare(for: feastList)
            } catch {
                alertState = FeastListDetailAlertState(
                    title: sharingAlertTitle(for: error),
                    message: error.localizedDescription
                )
            }
        }
    }

    private func sharingAlertTitle(for error: Error) -> String {
        guard
            let sharingError = error as? PersistenceController.SharingError,
            sharingError.isAvailabilityFailure
        else {
            return "Couldn't Open Sharing"
        }

        return "iCloud Sharing Unavailable"
    }

    private func deleteMessage(for neighborhood: ListSection) -> String {
        "Places in \(neighborhood.displayName) will stay in \(feastList.displayName) and move to Unsorted."
    }
}

private struct FeastListDetailAlertState: Identifiable {
    let id = UUID()
    let title: String
    let message: String
}

private struct NeighborhoodEditorState: Identifiable {
    let id = UUID()
    let title: String
    let initialName: String
    let neighborhood: ListSection?
}

private enum NeighborhoodHeaderKind: Equatable {
    case neighborhood
    case unsorted

    var accessibilityPrefix: String {
        switch self {
        case .neighborhood:
            return "Neighborhood"
        case .unsorted:
            return "Unsorted section"
        }
    }

    var titleFont: Font {
        switch self {
        case .neighborhood, .unsorted:
            return FeastTheme.Typography.sectionTitle
        }
    }

    var contentSpacing: CGFloat {
        switch self {
        case .neighborhood:
            return 4
        case .unsorted:
            return 4
        }
    }

    var topPadding: CGFloat {
        switch self {
        case .neighborhood:
            return 0
        case .unsorted:
            return 1
        }
    }

    var bottomPadding: CGFloat {
        switch self {
        case .neighborhood:
            return 1
        case .unsorted:
            return 2
        }
    }

    var actionTopPadding: CGFloat {
        switch self {
        case .neighborhood:
            return -1
        case .unsorted:
            return 0
        }
    }
}

private struct NeighborhoodHeaderView<TrailingContent: View>: View {
    let title: String
    let kind: NeighborhoodHeaderKind
    let subtitle: String?
    let trailingContent: TrailingContent

    init(
        title: String,
        kind: NeighborhoodHeaderKind,
        subtitle: String? = nil,
        @ViewBuilder trailingContent: () -> TrailingContent
    ) {
        self.title = title
        self.kind = kind
        self.subtitle = subtitle
        self.trailingContent = trailingContent()
    }

    var body: some View {
        HStack(alignment: .top, spacing: FeastTheme.Spacing.medium) {
            VStack(alignment: .leading, spacing: kind.contentSpacing) {
                Text(title)
                    .font(kind.titleFont)
                    .foregroundStyle(FeastTheme.Colors.primaryText)
                    .fixedSize(horizontal: false, vertical: true)

                if let subtitle {
                    Text(subtitle)
                        .font(FeastTheme.Typography.rowUtility)
                        .foregroundStyle(FeastTheme.Colors.secondaryText)
                        .lineLimit(2)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityElement(children: .combine)
            .accessibilityAddTraits(.isHeader)
            .accessibilityLabel(accessibilityLabel)

            trailingContent
                .padding(.top, kind.actionTopPadding)
        }
        .padding(.top, kind.topPadding)
        .padding(.bottom, kind.bottomPadding)
        .textCase(nil)
    }

    private var accessibilityLabel: String {
        if let subtitle {
            return "\(kind.accessibilityPrefix), \(title). \(subtitle)"
        }

        return "\(kind.accessibilityPrefix), \(title)"
    }
}

private struct NeighborhoodHeaderActionLabel: View {
    var body: some View {
        Image(systemName: "ellipsis")
            .font(.system(size: 15, weight: .semibold))
            .symbolRenderingMode(.hierarchical)
            .foregroundStyle(FeastTheme.Colors.secondaryText)
            .frame(width: 36, height: 36)
            .contentShape(Rectangle())
            .accessibilityHidden(true)
    }
}

private struct AddNeighborhoodIcon: View {
    var body: some View {
        ZStack(alignment: .topTrailing) {
            FeastToolbarSymbol(systemName: "map")

            Image(systemName: "plus.circle.fill")
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(FeastTheme.Colors.accentSelection)
                .background {
                    Circle()
                        .fill(FeastTheme.Colors.surfaceBackground)
                }
                .offset(x: 3.5, y: -2.5)
        }
        .frame(width: 18, height: 18)
        .accessibilityHidden(true)
    }
}

private struct EmptyNeighborhoodRow: View {
    var body: some View {
        Text("No saved places in this neighborhood yet.")
            .font(FeastTheme.Typography.rowMetadata)
            .foregroundStyle(FeastTheme.Colors.secondaryText)
            .padding(.vertical, FeastTheme.Spacing.xSmall)
    }
}

private struct NeighborhoodNameEditorSheet: View {
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
                    title: "Name",
                    subtitle: "Neighborhoods organize places inside a city"
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
            FeastListDetailView(feastList: AppServices.preview.repository.fetchPreviewFeastList(named: "NYC"))
        }
    }
}
