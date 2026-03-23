import SwiftUI

struct FeastListDetailView: View {
    @Environment(\.managedObjectContext) private var viewContext
    @Environment(\.persistenceController) private var persistenceController
    @ObservedObject var feastList: FeastList
    @State private var sectionEditor: SectionEditorState?
    @State private var sectionPendingDeletion: ListSection?
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
            .searchable(text: $searchText, prompt: "Search in \(feastList.displayName)")
            .sheet(item: $sectionEditor) { editor in
                NavigationStack {
                    SectionNameEditorSheet(
                        title: editor.title,
                        initialName: editor.initialName
                    ) { newName in
                        if let section = editor.section {
                            rename(section, to: newName)
                        } else {
                            createSection(named: newName, parent: editor.parentSection)
                        }
                    }
                }
            }
            .confirmationDialog(
                "Delete this section?",
                isPresented: deleteDialogBinding,
                titleVisibility: .visible,
                presenting: sectionPendingDeletion
            ) { section in
                Button("Delete Section", role: .destructive) {
                    delete(section)
                }
                Button("Cancel", role: .cancel) {
                    sectionPendingDeletion = nil
                }
            } message: { section in
                Text(deleteMessage(for: section))
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
                if feastList.sortedSavedPlaces.isEmpty && feastList.topLevelSections.isEmpty {
                    emptyStateSection
                } else {
                    ForEach(feastList.topLevelSections) { section in
                        topLevelSection(section)
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
            get: { sectionPendingDeletion != nil },
            set: { isPresented in
                if !isPresented {
                    sectionPendingDeletion = nil
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
                Text("This list is ready for sections and places.")
                    .font(FeastTheme.Typography.body.weight(.semibold))
                    .foregroundStyle(FeastTheme.Colors.primaryText)

                Text("Create sections for geographic groupings like city and neighborhood, then add places from Apple Maps.")
                    .font(FeastTheme.Typography.supporting)
                    .foregroundStyle(FeastTheme.Colors.secondaryText)

                Button("Create Section") {
                    presentNewTopLevelSectionEditor()
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
                SectionHeaderView(
                    title: "Unsorted",
                    kind: .unsorted,
                    subtitle: "Places without a section"
                ) {
                    EmptyView()
                }
            }
            .feastSectionSurface()
        }
    }

    private func topLevelSection(_ section: ListSection) -> some View {
        Section {
            sectionContent(section, nested: false)
        } header: {
            SectionHeaderView(
                title: section.displayName,
                kind: .topLevel
            ) {
                Menu {
                    Button("Add Subsection") {
                        presentNewChildSectionEditor(parent: section)
                    }

                    Button("Rename Section") {
                        sectionEditor = SectionEditorState(
                            title: "Rename Section",
                            initialName: section.displayName,
                            parentSection: section.parent,
                            section: section
                        )
                    }

                    Button("Delete Section", role: .destructive) {
                        sectionPendingDeletion = section
                    }
                } label: {
                    Image(systemName: "ellipsis")
                        .feastUtilitySymbol()
                }
            }
        }
        .feastSectionSurface()
    }

    @ViewBuilder
    private func sectionContent(_ section: ListSection, nested: Bool) -> some View {
        if section.sortedSavedPlaces.isEmpty && section.sortedChildren.isEmpty {
            EmptySectionRow(isNested: nested)
        } else {
            ForEach(section.sortedSavedPlaces) { place in
                SavedPlaceListRow(place: place, isNested: nested)
            }

            ForEach(section.sortedChildren) { child in
                ChildSectionBlock(
                    section: child,
                    onRename: {
                        sectionEditor = SectionEditorState(
                            title: "Rename Section",
                            initialName: child.displayName,
                            parentSection: child.parent,
                            section: child
                        )
                    },
                    onDelete: {
                        sectionPendingDeletion = child
                    }
                )
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
                Button("New Top-Level Section") {
                    presentNewTopLevelSectionEditor()
                }

                if !feastList.topLevelSections.isEmpty {
                    Menu("Add Subsection") {
                        ForEach(feastList.topLevelSections) { section in
                            Button(section.displayName) {
                                presentNewChildSectionEditor(parent: section)
                            }
                        }
                    }
                }
            } label: {
                FeastToolbarSymbol(systemName: "folder.badge.plus")
            }
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

    private func presentNewTopLevelSectionEditor() {
        sectionEditor = SectionEditorState(
            title: "New Section",
            initialName: "",
            parentSection: nil,
            section: nil
        )
    }

    private func presentNewChildSectionEditor(parent: ListSection) {
        sectionEditor = SectionEditorState(
            title: "New Subsection",
            initialName: "",
            parentSection: parent,
            section: nil
        )
    }

    private func createSection(named name: String, parent: ListSection?) {
        do {
            try repository.createListSection(named: name, in: feastList, parent: parent)
            sectionEditor = nil
        } catch {
            assertionFailure("Failed to create section: \(error.localizedDescription)")
        }
    }

    private func rename(_ section: ListSection, to name: String) {
        do {
            try repository.rename(section, to: name)
            sectionEditor = nil
        } catch {
            assertionFailure("Failed to rename section: \(error.localizedDescription)")
        }
    }

    private func delete(_ section: ListSection) {
        do {
            try repository.delete(section)
            sectionPendingDeletion = nil
        } catch {
            assertionFailure("Failed to delete section: \(error.localizedDescription)")
        }
    }

    private func deleteMessage(for section: ListSection) -> String {
        if section.sortedChildren.isEmpty {
            return "Saved places in \(section.displayName) will stay in \(feastList.displayName) and move to Unsorted."
        }

        return "This removes \(section.displayName) and its subsections. Saved places will stay in \(feastList.displayName) and move to Unsorted."
    }
}

private struct SectionEditorState: Identifiable {
    let id = UUID()
    let title: String
    let initialName: String
    let parentSection: ListSection?
    let section: ListSection?
}

private enum SectionHeaderKind: Equatable {
    case topLevel
    case nested
    case unsorted

    var labelText: String {
        switch self {
        case .topLevel:
            return "Section"
        case .nested:
            return "Subsection"
        case .unsorted:
            return "Unsorted"
        }
    }

    var labelColor: Color {
        switch self {
        case .topLevel, .nested:
            return FeastTheme.Colors.secondaryText
        case .unsorted:
            return FeastTheme.Colors.tertiaryText
        }
    }

    var titleFont: Font {
        switch self {
        case .topLevel, .unsorted:
            return FeastTheme.Typography.sectionTitle
        case .nested:
            return FeastTheme.Typography.sectionHeader
        }
    }
}

private struct SectionHeaderView<TrailingContent: View>: View {
    let title: String
    let kind: SectionHeaderKind
    let subtitle: String?
    let trailingContent: TrailingContent

    init(
        title: String,
        kind: SectionHeaderKind,
        subtitle: String? = nil,
        @ViewBuilder trailingContent: () -> TrailingContent
    ) {
        self.title = title
        self.kind = kind
        self.subtitle = subtitle
        self.trailingContent = trailingContent()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline, spacing: FeastTheme.Spacing.small) {
                Text(kind.labelText.uppercased())
                    .font(FeastTheme.Typography.sectionLabel)
                    .tracking(0.8)
                    .foregroundStyle(kind.labelColor)

                Spacer()

                trailingContent
            }

            HStack(spacing: FeastTheme.Spacing.small) {
                if kind == .nested {
                    Image(systemName: "arrow.turn.down.right")
                        .font(FeastTheme.Typography.caption.weight(.semibold))
                        .foregroundStyle(FeastTheme.Colors.secondaryText)
                }

                Text(title)
                    .font(kind.titleFont)
                    .foregroundStyle(FeastTheme.Colors.primaryText)
            }

            if let subtitle {
                Text(subtitle)
                    .font(FeastTheme.Typography.rowUtility)
                    .foregroundStyle(FeastTheme.Colors.secondaryText)
                    .lineLimit(2)
            }
        }
        .padding(.top, kind == .topLevel ? FeastTheme.Spacing.small : 2)
        .padding(.bottom, kind == .topLevel ? FeastTheme.Spacing.xSmall : 2)
        .textCase(nil)
    }
}

private struct EmptySectionRow: View {
    let isNested: Bool

    var body: some View {
        Text("No saved places in this section yet.")
            .font(FeastTheme.Typography.rowMetadata)
            .foregroundStyle(FeastTheme.Colors.secondaryText)
            .padding(.vertical, FeastTheme.Spacing.xSmall)
            .padding(.leading, isNested ? FeastTheme.Spacing.xLarge : 0)
    }
}

private struct ChildSectionBlock: View {
    let section: ListSection
    let onRename: () -> Void
    let onDelete: () -> Void

    var body: some View {
        SectionHeaderView(
            title: section.displayName,
            kind: .nested
        ) {
            Menu {
                Button("Rename Section") {
                    onRename()
                }

                Button("Delete Section", role: .destructive) {
                    onDelete()
                }
            } label: {
                Image(systemName: "ellipsis")
                    .feastUtilitySymbol()
            }
        }
        .padding(.vertical, FeastTheme.Spacing.xSmall)

        if section.sortedSavedPlaces.isEmpty {
            EmptySectionRow(isNested: true)
        } else {
            ForEach(section.sortedSavedPlaces) { place in
                SavedPlaceListRow(place: place, isNested: true)
            }
        }
    }
}

private struct SectionNameEditorSheet: View {
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
                        title: "Section Name",
                        helper: "Use clear geographic names like city, region, or neighborhood."
                    ) {
                        TextField("Section name", text: $name)
                            .textInputAutocapitalization(.words)
                            .autocorrectionDisabled()
                            .feastFieldSurface(minHeight: 52)
                    }
                }
            } header: {
                FeastFormSectionHeader(
                    title: "Name",
                    subtitle: "Sections organize places inside a list"
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
