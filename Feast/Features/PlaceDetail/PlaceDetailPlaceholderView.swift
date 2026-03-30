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
    @State private var isResolvingPlace = false
    @State private var isOpeningInMaps = false
    @State private var showingDeleteConfirmation = false
    @State private var detailAlert: DetailAlertState?

    @State private var status: PlaceStatus
    @State private var placeType: PlaceType
    @State private var cuisinesText: String
    @State private var tags: [String]
    @State private var note: String
    @State private var websiteURL: String
    @State private var instagramURL: String
    @State private var selectedNeighborhoodObjectID: NSManagedObjectID?

    init(savedPlace: SavedPlace) {
        self.savedPlace = savedPlace
        _status = State(initialValue: savedPlace.placeStatus)
        _placeType = State(initialValue: savedPlace.placeTypeValue)
        _cuisinesText = State(initialValue: savedPlace.cuisines.joined(separator: ", "))
        _tags = State(initialValue: savedPlace.tags)
        _note = State(initialValue: savedPlace.note ?? "")
        _websiteURL = State(initialValue: savedPlace.websiteURL ?? "")
        _instagramURL = State(initialValue: savedPlace.instagramURL ?? "")
        _selectedNeighborhoodObjectID = State(initialValue: savedPlace.listSection?.objectID)
    }

    var body: some View {
        List {
            headerSection
            metadataSection
            categoriesSection
            notesSection
            neighborhoodAssignmentSection
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
        resolvedPlace?.displayName ?? savedPlace.displayName
    }

    private var headerSubtitle: String? {
        if let resolvedPlace, !resolvedPlace.secondaryText.isEmpty {
            return resolvedPlace.secondaryText
        }

        return nil
    }

    private var neighborhoodContextText: String {
        let neighborhoodName = selectedNeighborhood?.displayName ?? "Unsorted"
        return "\(savedPlace.displayCityName) • \(neighborhoodName)"
    }

    private var headerStatusSummary: String {
        "\(status.rawValue) • \(placeType.rawValue)"
    }

    private var allNeighborhoods: [ListSection] {
        savedPlace.feastList?.neighborhoodSections ?? []
    }

    private var selectedNeighborhood: ListSection? {
        allNeighborhoods.first { $0.objectID == selectedNeighborhoodObjectID }
    }

    private var existingTags: [String] {
        FeastTag.catalog(from: savedPlaces.map(\.tags))
    }

    private var websiteURLValue: URL? {
        validatedURL(from: websiteURL)
    }

    private var instagramURLValue: URL? {
        validatedURL(from: instagramURL)
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
                    TextField("https://example.com", text: $websiteURL)
                        .keyboardType(.URL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .feastFieldSurface()
                }

                FeastFormDivider()

                FeastFormField(title: "Instagram") {
                    TextField("https://instagram.com/...", text: $instagramURL)
                        .keyboardType(.URL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .feastFieldSurface()
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
                    Picker("Neighborhood", selection: $selectedNeighborhoodObjectID) {
                        Text("Unsorted").tag(nil as NSManagedObjectID?)

                        ForEach(allNeighborhoods) { neighborhood in
                            Text(neighborhood.displayName).tag(neighborhood.objectID as NSManagedObjectID?)
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
                if let websiteURLValue {
                    Button {
                        openExternalURL(
                            websiteURLValue,
                            failureTitle: "Website Unavailable",
                            failureMessage: "Feast couldn't open this website."
                        )
                    } label: {
                        Label("Open Website", systemImage: "globe")
                    }
                    .buttonStyle(FeastInlineActionButtonStyle())
                }

                if websiteURLValue != nil, instagramURLValue != nil {
                    FeastFormDivider()
                }

                if let instagramURLValue {
                    Button {
                        openExternalURL(
                            instagramURLValue,
                            failureTitle: "Instagram Unavailable",
                            failureMessage: "Feast couldn't open this Instagram link."
                        )
                    } label: {
                        Label("Open Instagram", systemImage: "camera")
                    }
                    .buttonStyle(FeastInlineActionButtonStyle())
                }

                if websiteURLValue != nil || instagramURLValue != nil {
                    FeastFormDivider()
                }

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
                    tags: tags,
                    note: normalizedOptional(note),
                    websiteURL: normalizedOptional(websiteURL),
                    instagramURL: normalizedOptional(instagramURL),
                    listSection: selectedNeighborhood
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
