import CoreData
import SwiftUI

struct SavedPlaceDetailView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.managedObjectContext) private var viewContext
    @Environment(\.persistenceController) private var persistenceController
    @Environment(\.applePlacesService) private var applePlacesService

    @ObservedObject var savedPlace: SavedPlace

    @State private var resolvedPlace: ApplePlaceMatch?
    @State private var isResolvingPlace = false
    @State private var isOpeningInMaps = false
    @State private var showingDeleteConfirmation = false
    @State private var detailAlert: DetailAlertState?

    @State private var status: PlaceStatus
    @State private var placeType: PlaceType
    @State private var cuisinesText: String
    @State private var tagsText: String
    @State private var note: String
    @State private var skipNote: String
    @State private var instagramURL: String
    @State private var selectedSectionObjectID: NSManagedObjectID?

    init(savedPlace: SavedPlace) {
        self.savedPlace = savedPlace
        _status = State(initialValue: savedPlace.placeStatus)
        _placeType = State(initialValue: savedPlace.placeTypeValue)
        _cuisinesText = State(initialValue: savedPlace.cuisines.joined(separator: ", "))
        _tagsText = State(initialValue: savedPlace.tags.joined(separator: ", "))
        _note = State(initialValue: savedPlace.note ?? "")
        _skipNote = State(initialValue: savedPlace.skipNote ?? "")
        _instagramURL = State(initialValue: savedPlace.instagramURL ?? "")
        _selectedSectionObjectID = State(initialValue: savedPlace.listSection?.objectID)
    }

    var body: some View {
        List {
            headerSection
            metadataSection
            categoriesSection
            notesSection
            sectionAssignmentSection
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
        .confirmationDialog(
            "Delete this place?",
            isPresented: $showingDeleteConfirmation,
            titleVisibility: .visible
        ) {
            Button("Delete Place", role: .destructive) {
                deletePlace()
            }
            Button("Cancel", role: .cancel) { }
        } message: {
            Text("This deletes the place from \(savedPlace.displayListName).")
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

    private var headerTitle: String {
        resolvedPlace?.displayName ?? savedPlace.displayName
    }

    private var headerSubtitle: String? {
        if let resolvedPlace, !resolvedPlace.secondaryText.isEmpty {
            return resolvedPlace.secondaryText
        }

        return nil
    }

    private var sectionContextText: String {
        let sectionName = selectedSection?.pathDisplay ?? "Unsorted"
        return "\(savedPlace.displayListName) • \(sectionName)"
    }

    private var headerStatusSummary: String {
        "\(status.rawValue) • \(placeType.rawValue)"
    }

    private var allSections: [ListSection] {
        savedPlace.feastList?.sortedSections ?? []
    }

    private var selectedSection: ListSection? {
        allSections.first { $0.objectID == selectedSectionObjectID }
    }

    private var headerSection: some View {
        Section {
            FeastFormGroup {
                HStack(alignment: .top, spacing: FeastTheme.Spacing.medium) {
                    VStack(alignment: .leading, spacing: FeastTheme.Spacing.small) {
                        Text(sectionContextText.uppercased())
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

                        if resolvedPlace == nil {
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
            }
        } header: {
            FeastFormSectionHeader(
                title: "Place Profile",
                subtitle: "Apple Maps context and editable notes together"
            )
        }
    }

    private var metadataSection: some View {
        Section {
            FeastFormGroup {
                FeastFormField(
                    title: "Status",
                    helper: "How this place should read in your list."
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
                    helper: "Keeps the place profile consistent across Feast."
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
                subtitle: "Update the way the place is categorized"
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
                    TextField("Date night, lunch, worth a detour", text: $tagsText)
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
                FeastFormField(title: "Note", helper: "What makes the place worth returning to?") {
                    TextField("Why it matters", text: $note, axis: .vertical)
                        .lineLimit(3...6)
                        .feastFieldSurface(minHeight: 92)
                }

                FeastFormDivider()

                FeastFormField(title: "Skip Note", helper: "What would make you pass on it next time?") {
                    TextField("Why you might skip it", text: $skipNote, axis: .vertical)
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
                subtitle: "Keep the place profile useful and easy to scan"
            )
        }
    }

    private var sectionAssignmentSection: some View {
        Section {
            FeastFormGroup {
                FeastFormField(
                    title: "Section",
                    helper: "Choose Unsorted if the place should stay on the list without a section for now."
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
                subtitle: "Move the place without changing its list"
            )
        }
    }

    private var actionsSection: some View {
        Section {
            FeastFormGroup {
                Button(role: .destructive) {
                    showingDeleteConfirmation = true
                } label: {
                    Text("Delete Place")
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        } header: {
            FeastFormSectionHeader(
                title: "Actions",
                subtitle: "Deleting removes the place from \(savedPlace.displayListName)"
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

    private func saveChanges() {
        do {
            try repository.update(
                savedPlace,
                with: FeastRepository.SavedPlaceMetadata(
                    status: status,
                    placeType: placeType,
                    cuisines: splitValues(from: cuisinesText),
                    tags: splitValues(from: tagsText),
                    note: normalizedOptional(note),
                    skipNote: normalizedOptional(skipNote),
                    instagramURL: normalizedOptional(instagramURL),
                    listSection: selectedSection
                )
            )
        } catch {
            detailAlert = DetailAlertState(
                title: "Couldn't Save Changes",
                message: error.localizedDescription
            )
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
