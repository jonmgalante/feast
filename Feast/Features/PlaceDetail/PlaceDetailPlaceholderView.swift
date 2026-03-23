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
        Form {
            headerSection
            metadataSection
            categoriesSection
            notesSection
            sectionAssignmentSection
            actionsSection
        }
        .navigationTitle("Place")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("Save") {
                    saveChanges()
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

        return savedPlace.displaySectionPath
    }

    private var allSections: [ListSection] {
        savedPlace.feastList?.sortedSections ?? []
    }

    private var selectedSection: ListSection? {
        allSections.first { $0.objectID == selectedSectionObjectID }
    }

    private var headerSection: some View {
        Section {
            VStack(alignment: .leading, spacing: FeastTheme.Spacing.small) {
                HStack(alignment: .top, spacing: FeastTheme.Spacing.medium) {
                    VStack(alignment: .leading, spacing: FeastTheme.Spacing.xSmall) {
                        Text(headerTitle)
                            .font(FeastTheme.Typography.sectionTitle)
                            .foregroundStyle(FeastTheme.Colors.primaryText)

                        if let headerSubtitle {
                            Text(headerSubtitle)
                                .font(FeastTheme.Typography.supporting)
                                .foregroundStyle(FeastTheme.Colors.secondaryNeutral)
                        }

                        if resolvedPlace == nil {
                            Text("Using saved snapshot")
                                .font(FeastTheme.Typography.caption)
                                .foregroundStyle(FeastTheme.Colors.secondaryAccent)
                        }
                    }

                    Spacer(minLength: 0)

                    if isResolvingPlace {
                        ProgressView()
                            .controlSize(.small)
                    }
                }

                if savedPlace.applePlaceIDValue != nil {
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
                    .disabled(isOpeningInMaps)
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

    private var actionsSection: some View {
        Section {
            Button("Delete Place", role: .destructive) {
                showingDeleteConfirmation = true
            }
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
            resolvedPlace = try await applePlacesService.resolvePlace(applePlaceID: applePlaceID)
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
            let didOpen = try await applePlacesService.openInMaps(applePlaceID: applePlaceID)
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
