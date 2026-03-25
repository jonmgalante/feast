import SwiftUI

struct FeastListDetailView: View {
    @Environment(\.managedObjectContext) private var viewContext
    @Environment(\.persistenceController) private var persistenceController
    @ObservedObject var feastList: FeastList
    @State private var neighborhoodEditor: NeighborhoodEditorState?
    @State private var neighborhoodPendingDeletion: ListSection?
    @State private var showingAddPlaceSheet = false
    @State private var searchText = ""
    @State private var searchFilters = SavedPlaceSearchFilters()
    @State private var showingSearchFilters = false

    var body: some View {
        content
            .feastScrollableChrome()
            .toolbar { toolbarContent }
            .listStyle(.insetGrouped)
            .navigationTitle(feastList.displayName)
            .navigationBarTitleDisplayMode(.inline)
            .searchable(text: $searchText, prompt: "Search places in \(feastList.displayName)")
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
                        filters: $searchFilters,
                        availableLists: [],
                        availableCuisines: availableCuisines,
                        fixedFeastList: feastList
                    )
                }
            }
            .safeAreaInset(edge: .bottom) {
                addPlaceCallToAction
            }
    }

    private var content: some View {
        List {
            if isShowingSearchResults {
                searchResultsSection
            } else {
                if feastList.sortedSavedPlaces.isEmpty && feastList.neighborhoodSections.isEmpty {
                    emptyStateSection
                } else {
                    ForEach(feastList.neighborhoodSections) { section in
                        neighborhoodSection(section)
                    }
                    unsortedSection
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

    private var filteredSavedPlaces: [SavedPlace] {
        SavedPlaceSearchEngine.filteredPlaces(
            from: feastList.sortedSavedPlaces,
            query: searchText,
            filters: searchFilters,
            fixedFeastList: feastList
        )
    }

    private var isShowingSearchResults: Bool {
        !searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || searchFilters.hasActiveFilters
    }

    private var availableCuisines: [String] {
        SavedPlaceSearchEngine.availableCuisines(
            from: feastList.sortedSavedPlaces,
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
        .buttonStyle(FeastProminentButtonStyle())
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
                ContentUnavailableView(
                    "No Matching Places",
                    systemImage: "magnifyingglass",
                    description: Text("Try a different search or adjust your filters.")
                )
            } else {
                ForEach(filteredSavedPlaces) { place in
                    SavedPlaceListRow(place: place)
                }
            }
        }
        .feastSectionSurface()
    }

    private var emptyStateSection: some View {
        Section {
            VStack(alignment: .leading, spacing: FeastTheme.Spacing.medium) {
                Text("This city is ready for neighborhoods.")
                    .font(FeastTheme.Typography.body.weight(.semibold))
                    .foregroundStyle(FeastTheme.Colors.primaryText)

                Text("Add neighborhoods like Ridgewood or Lower East Side, then save places from Apple Maps.")
                    .font(FeastTheme.Typography.supporting)
                    .foregroundStyle(FeastTheme.Colors.secondaryText)

                Button("Add Neighborhood") {
                    presentAddNeighborhoodEditor()
                }
                .buttonStyle(FeastInlineActionButtonStyle())
            }
            .padding(.vertical, FeastTheme.Spacing.xSmall)
        }
        .feastSectionSurface()
    }

    @ViewBuilder
    private var unsortedSection: some View {
        if !feastList.unsortedSavedPlaces.isEmpty {
            Section {
                ForEach(feastList.unsortedSavedPlaces) { place in
                    SavedPlaceListRow(place: place)
                }
            } header: {
                NeighborhoodHeaderView(
                    title: "Unsorted",
                    kind: .unsorted,
                    subtitle: "Places without a neighborhood"
                ) {
                    EmptyView()
                }
            }
            .feastSectionSurface()
        }
    }

    private func neighborhoodSection(_ neighborhood: ListSection) -> some View {
        Section {
            neighborhoodContent(neighborhood)
        } header: {
            NeighborhoodHeaderView(
                title: neighborhood.displayName,
                kind: .neighborhood
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
    private func neighborhoodContent(_ neighborhood: ListSection) -> some View {
        if neighborhood.sortedSavedPlaces.isEmpty {
            EmptyNeighborhoodRow()
        } else {
            ForEach(neighborhood.sortedSavedPlaces) { place in
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
                    systemName: "line.3.horizontal.decrease",
                    isEmphasized: searchFilters.hasActiveFilters
                )
            }

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

    private var searchSummaryText: String? {
        var components: [String] = []

        let trimmedSearchText = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedSearchText.isEmpty {
            components.append("Search: \(trimmedSearchText)")
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
            assertionFailure("Failed to create neighborhood: \(error.localizedDescription)")
        }
    }

    private func renameNeighborhood(_ neighborhood: ListSection, to name: String) {
        do {
            try repository.rename(neighborhood, to: name)
            neighborhoodEditor = nil
        } catch {
            assertionFailure("Failed to rename neighborhood: \(error.localizedDescription)")
        }
    }

    private func deleteNeighborhood(_ neighborhood: ListSection) {
        do {
            try repository.delete(neighborhood)
            neighborhoodPendingDeletion = nil
        } catch {
            assertionFailure("Failed to delete neighborhood: \(error.localizedDescription)")
        }
    }

    private func deleteMessage(for neighborhood: ListSection) -> String {
        "Places in \(neighborhood.displayName) will stay in \(feastList.displayName) and move to Unsorted."
    }
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

    var labelText: String {
        switch self {
        case .neighborhood:
            return "Neighborhood"
        case .unsorted:
            return "Unsorted"
        }
    }

    var labelColor: Color {
        switch self {
        case .neighborhood:
            return FeastTheme.Colors.secondaryText
        case .unsorted:
            return FeastTheme.Colors.tertiaryText
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
            return 5
        case .unsorted:
            return 4
        }
    }

    var topPadding: CGFloat {
        switch self {
        case .neighborhood:
            return 10
        case .unsorted:
            return 2
        }
    }

    var bottomPadding: CGFloat {
        switch self {
        case .neighborhood:
            return 6
        case .unsorted:
            return 2
        }
    }

    var actionTopPadding: CGFloat {
        switch self {
        case .neighborhood:
            return 6
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
                Text(kind.labelText.uppercased())
                    .font(FeastTheme.Typography.sectionLabel)
                    .tracking(0.8)
                    .foregroundStyle(kind.labelColor)

                Text(title)
                    .font(kind.titleFont)
                    .foregroundStyle(FeastTheme.Colors.primaryText)

                if let subtitle {
                    Text(subtitle)
                        .font(FeastTheme.Typography.rowUtility)
                        .foregroundStyle(FeastTheme.Colors.secondaryText)
                        .lineLimit(2)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            trailingContent
                .padding(.top, kind.actionTopPadding)
        }
        .padding(.top, kind.topPadding)
        .padding(.bottom, kind.bottomPadding)
        .textCase(nil)
    }
}

private struct NeighborhoodHeaderActionLabel: View {
    var body: some View {
        Image(systemName: "ellipsis")
            .font(.system(size: 15, weight: .semibold))
            .symbolRenderingMode(.hierarchical)
            .foregroundStyle(FeastTheme.Colors.secondaryText)
            .frame(width: 32, height: 32)
            .contentShape(Rectangle())
            .offset(y: -1)
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
