import CoreData
import SwiftUI
import UniformTypeIdentifiers

struct NotesImportFlowView: View {
    @Environment(\.dismiss) private var dismiss

    let onViewImportedCity: ((String) -> Void)?

    init(onViewImportedCity: ((String) -> Void)? = nil) {
        self.onViewImportedCity = onViewImportedCity
    }

    var body: some View {
        List {
            introSection
            methodsSection
            guidanceSection
        }
        .feastScrollableChrome()
        .listStyle(.insetGrouped)
        .navigationTitle("Import from Notes")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Close") {
                    dismiss()
                }
            }
        }
    }

    private var introSection: some View {
        Section {
            FeastFormGroup {
                VStack(alignment: .leading, spacing: FeastTheme.Spacing.small) {
                    Text("Bring places you already track into Feast.")
                        .font(FeastTheme.Typography.body.weight(.semibold))
                        .foregroundStyle(FeastTheme.Colors.primaryText)

                    Text("Import one city at a time for the cleanest review.")
                        .font(FeastTheme.Typography.supporting)
                        .foregroundStyle(FeastTheme.Colors.secondaryText)
                }
            }
        }
        .feastSectionSurface()
    }

    private var methodsSection: some View {
        Section {
            NavigationLink {
                NotesPasteImportView(
                    onDone: closeFlow,
                    onViewImportedCity: viewImportedCity
                )
            } label: {
                NotesImportMethodRow(
                    title: "Paste from Notes",
                    subtitle: "Paste a note and review the parsed places before saving.",
                    systemName: "doc.on.clipboard"
                )
            }

            NavigationLink {
                NotesMarkdownImportView(
                    onDone: closeFlow,
                    onViewImportedCity: viewImportedCity
                )
            } label: {
                NotesImportMethodRow(
                    title: "Import Markdown File",
                    subtitle: "Open a Markdown export and review the parsed places before saving.",
                    systemName: "doc.text"
                )
            }
        } header: {
            FeastFormSectionHeader(
                title: "Choose Method",
                subtitle: "Pick the source that matches how you already keep your notes"
            )
        }
        .feastSectionSurface()
    }

    private var guidanceSection: some View {
        Section {
            DisclosureGroup {
                VStack(alignment: .leading, spacing: FeastTheme.Spacing.small) {
                    NotesImportGuidanceBullet(text: "Keep Neighborhood headings when you have them.")
                    NotesImportGuidanceBullet(text: "Leave links in place so Feast can carry them into review.")
                    NotesImportGuidanceBullet(text: "Check ambiguous places in Apple Maps before importing.")
                }
                .padding(.top, FeastTheme.Spacing.small)
            } label: {
                Text("Best results")
                    .font(FeastTheme.Typography.supporting.weight(.semibold))
                    .foregroundStyle(FeastTheme.Colors.primaryText)
            }
            .tint(FeastTheme.Colors.secondaryAction)
        }
        .feastSectionSurface()
    }

    private func closeFlow() {
        dismiss()
    }

    private func viewImportedCity(_ cityURIString: String) {
        dismiss()

        guard let onViewImportedCity else {
            return
        }

        DispatchQueue.main.async {
            onViewImportedCity(cityURIString)
        }
    }
}

private struct NotesPasteImportView: View {
    @FetchRequest(fetchRequest: NotesImportSupport.feastListsFetchRequest, animation: .default)
    private var feastLists: FetchedResults<FeastList>

    let onDone: () -> Void
    let onViewImportedCity: (String) -> Void

    @State private var selectedCityURIString: String?
    @State private var pastedText = ""
    @State private var reviewDestination: NotesImportReviewDestination?

    var body: some View {
        List {
            destinationSection
            contentSection
        }
        .feastScrollableChrome()
        .listStyle(.insetGrouped)
        .scrollDismissesKeyboard(.interactively)
        .navigationTitle("Paste from Notes")
        .navigationBarTitleDisplayMode(.inline)
        .navigationDestination(item: $reviewDestination) { reviewDestination in
            NotesImportReviewView(
                destination: reviewDestination,
                onDone: onDone,
                onViewImportedCity: onViewImportedCity
            )
        }
        .safeAreaInset(edge: .bottom) {
            bottomCallToAction
        }
    }

    private var selectedCity: FeastList? {
        NotesImportSupport.feastList(
            matching: selectedCityURIString,
            in: feastLists
        )
    }

    private var trimmedPastedText: String {
        NotesImportSupport.trimmed(pastedText)
    }

    private var canReview: Bool {
        selectedCity != nil && !trimmedPastedText.isEmpty
    }

    private var reviewReadinessMessage: String {
        if selectedCity == nil && trimmedPastedText.isEmpty {
            return "Choose a City and paste note text to continue."
        }

        if selectedCity == nil {
            return "Choose a City to continue."
        }

        if trimmedPastedText.isEmpty {
            return "Paste note text to continue."
        }

        return "Feast will build a review before anything is saved."
    }

    private var destinationSection: some View {
        Section {
            FeastFormGroup {
                FeastFormField(
                    title: "City",
                    helper: "Choose the City for this import."
                ) {
                    NavigationLink {
                        NotesImportCityPickerView(selectedCityURIString: $selectedCityURIString)
                    } label: {
                        NotesImportSelectionField(
                            title: selectedCity?.displayName ?? "Choose a City",
                            subtitle: selectedCity == nil ? "Required before review" : "Tap to change City",
                            systemName: "building.2"
                        )
                    }
                    .buttonStyle(.plain)
                }
            }
        } header: {
            FeastFormSectionHeader(
                title: "Destination",
                subtitle: "Choose where this import should land"
            )
        }
        .feastSectionSurface()
    }

    private var contentSection: some View {
        Section {
            FeastFormGroup {
                FeastFormField(
                    title: "Notes",
                    helper: "Feast will pull out Neighborhoods, places, notes, and links for review."
                ) {
                    FeastMultilineTextEditor(
                        placeholder: "Paste note text",
                        text: $pastedText,
                        minHeight: 220
                    )
                    .textInputAutocapitalization(.sentences)
                }
            }
        } header: {
            FeastFormSectionHeader(
                title: "Paste Note",
                subtitle: "Bring in the note you already keep in Apple Notes"
            )
        }
        .feastSectionSurface()
    }

    private var bottomCallToAction: some View {
        FeastFormGroup {
            VStack(alignment: .leading, spacing: FeastTheme.Spacing.small) {
                Text(reviewReadinessMessage)
                    .font(FeastTheme.Typography.rowMetadata)
                    .foregroundStyle(FeastTheme.Colors.secondaryText)
                    .frame(maxWidth: .infinity, alignment: .leading)

                Button {
                    reviewImport()
                } label: {
                    Text("Review Import")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(FeastProminentButtonStyle())
                .disabled(!canReview)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .feastBottomBarChrome()
    }

    private func reviewImport() {
        guard
            let selectedCity,
            let selectedCityURIString
        else {
            return
        }

        reviewDestination = NotesImportReviewDestination(
            cityURIString: selectedCityURIString,
            reviewState: NotesImportParser.parse(
                text: trimmedPastedText,
                cityName: selectedCity.displayName,
                source: NotesImportSourceDescriptor(
                    title: "Pasted Note",
                    detailTitle: "Contents",
                    detail: "\(trimmedPastedText.count) characters"
                )
            )
        )
    }
}

private struct NotesMarkdownImportView: View {
    @FetchRequest(fetchRequest: NotesImportSupport.feastListsFetchRequest, animation: .default)
    private var feastLists: FetchedResults<FeastList>

    let onDone: () -> Void
    let onViewImportedCity: (String) -> Void

    @State private var selectedCityURIString: String?
    @State private var selectedFileURL: URL?
    @State private var showingFileImporter = false
    @State private var reviewDestination: NotesImportReviewDestination?
    @State private var alertState: NotesImportAlertState?

    var body: some View {
        List {
            destinationSection
            fileSection
            actionSection
        }
        .feastScrollableChrome()
        .listStyle(.insetGrouped)
        .navigationTitle("Import Markdown File")
        .navigationBarTitleDisplayMode(.inline)
        .fileImporter(
            isPresented: $showingFileImporter,
            allowedContentTypes: NotesImportSupport.markdownContentTypes,
            allowsMultipleSelection: false,
            onCompletion: handleFileImport
        )
        .navigationDestination(item: $reviewDestination) { reviewDestination in
            NotesImportReviewView(
                destination: reviewDestination,
                onDone: onDone,
                onViewImportedCity: onViewImportedCity
            )
        }
        .alert(item: $alertState) { alert in
            Alert(
                title: Text(alert.title),
                message: Text(alert.message),
                dismissButton: .default(Text("OK"))
            )
        }
    }

    private var selectedCity: FeastList? {
        NotesImportSupport.feastList(
            matching: selectedCityURIString,
            in: feastLists
        )
    }

    private var canReview: Bool {
        selectedCity != nil && selectedFileURL != nil
    }

    private var reviewReadinessMessage: String {
        if selectedCity == nil && selectedFileURL == nil {
            return "Choose a City and a file to continue."
        }

        if selectedCity == nil {
            return "Choose a City to continue."
        }

        if selectedFileURL == nil {
            return "Choose a file to continue."
        }

        return "Feast will build a review before anything is saved."
    }

    private var destinationSection: some View {
        Section {
            FeastFormGroup {
                FeastFormField(
                    title: "City",
                    helper: "Choose the City for this import."
                ) {
                    NavigationLink {
                        NotesImportCityPickerView(selectedCityURIString: $selectedCityURIString)
                    } label: {
                        NotesImportSelectionField(
                            title: selectedCity?.displayName ?? "Choose a City",
                            subtitle: selectedCity == nil ? "Required before review" : "Tap to change City",
                            systemName: "building.2"
                        )
                    }
                    .buttonStyle(.plain)
                }
            }
        } header: {
            FeastFormSectionHeader(
                title: "Destination",
                subtitle: "Choose where this import should land"
            )
        }
        .feastSectionSurface()
    }

    private var fileSection: some View {
        Section {
            FeastFormGroup {
                FeastFormField(
                    title: "Markdown File",
                    helper: "Apple Notes Markdown usually preserves headings and checklists best."
                ) {
                    Button {
                        showingFileImporter = true
                    } label: {
                        NotesImportSelectionField(
                            title: selectedFileURL?.lastPathComponent ?? "Choose a Markdown File",
                            subtitle: selectedFileURL == nil ? "Open Files to choose an export" : "Tap to choose another file",
                            systemName: "doc.text"
                        )
                    }
                    .buttonStyle(.plain)
                }
            }
        } header: {
            FeastFormSectionHeader(
                title: "Source",
                subtitle: "Pick the markdown export you want Feast to review"
            )
        }
        .feastSectionSurface()
    }

    private var actionSection: some View {
        Section {
            FeastFormGroup {
                VStack(alignment: .leading, spacing: FeastTheme.Spacing.small) {
                    Text(reviewReadinessMessage)
                        .font(FeastTheme.Typography.rowMetadata)
                        .foregroundStyle(FeastTheme.Colors.secondaryText)

                    Button("Review Import") {
                        reviewImport()
                    }
                    .buttonStyle(FeastProminentButtonStyle())
                    .disabled(!canReview)
                }
            }
        }
        .feastSectionSurface()
    }

    private func handleFileImport(_ result: Result<[URL], Error>) {
        switch result {
        case let .success(urls):
            selectedFileURL = urls.first
        case let .failure(error):
            alertState = NotesImportAlertState(
                title: "Couldn't Open File",
                message: error.localizedDescription
            )
        }
    }

    private func reviewImport() {
        guard
            let selectedCity,
            let selectedCityURIString,
            let selectedFileURL
        else {
            return
        }

        do {
            let fileContents = try NotesImportSupport.readText(from: selectedFileURL)
            let trimmedContents = NotesImportSupport.trimmed(fileContents)

            guard !trimmedContents.isEmpty else {
                alertState = NotesImportAlertState(
                    title: "File Is Empty",
                    message: "Choose a file with note text Feast can review."
                )
                return
            }

            reviewDestination = NotesImportReviewDestination(
                cityURIString: selectedCityURIString,
                reviewState: NotesImportParser.parse(
                    text: fileContents,
                    cityName: selectedCity.displayName,
                    source: NotesImportSourceDescriptor(
                        title: "Markdown File",
                        detailTitle: "File",
                        detail: selectedFileURL.lastPathComponent
                    )
                )
            )
        } catch {
            alertState = NotesImportAlertState(
                title: "Couldn't Read File",
                message: error.localizedDescription
            )
        }
    }
}

private struct NotesImportCityPickerView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.managedObjectContext) private var viewContext
    @Environment(\.persistenceController) private var persistenceController

    @FetchRequest(fetchRequest: NotesImportSupport.feastListsFetchRequest, animation: .default)
    private var feastLists: FetchedResults<FeastList>

    @Binding var selectedCityURIString: String?

    @State private var showingCityEditor = false
    @State private var alertState: NotesImportAlertState?

    var body: some View {
        List {
            if feastLists.isEmpty {
                Section {
                    ContentUnavailableView {
                        Label("No cities yet", systemImage: "building.2")
                    } description: {
                        Text("Add a City before you start importing.")
                    } actions: {
                        Button("Add City") {
                            showingCityEditor = true
                        }
                        .buttonStyle(FeastProminentButtonStyle())
                    }
                }
                .feastSectionSurface()
            } else {
                Section("Cities") {
                    ForEach(feastLists) { feastList in
                        Button {
                            selectedCityURIString = feastList.objectURIString
                            dismiss()
                        } label: {
                            HStack(spacing: FeastTheme.Spacing.medium) {
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(feastList.displayName)
                                        .font(FeastTheme.Typography.rowTitle)
                                        .foregroundStyle(FeastTheme.Colors.primaryText)

                                    Text(NotesImportSupport.cityMetadata(for: feastList))
                                        .font(FeastTheme.Typography.rowMetadata)
                                        .foregroundStyle(FeastTheme.Colors.secondaryText)
                                }

                                Spacer(minLength: FeastTheme.Spacing.small)

                                if selectedCityURIString == feastList.objectURIString {
                                    Image(systemName: "checkmark")
                                        .font(.system(size: 14, weight: .semibold))
                                        .foregroundStyle(FeastTheme.Colors.secondaryAction)
                                }
                            }
                            .padding(.vertical, 4)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
                .feastSectionSurface()
            }
        }
        .feastScrollableChrome()
        .listStyle(.insetGrouped)
        .navigationTitle("Choose City")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    showingCityEditor = true
                } label: {
                    Image(systemName: "plus")
                }
                .accessibilityLabel("Add City")
            }
        }
        .sheet(isPresented: $showingCityEditor) {
            NavigationStack {
                CityNameEditorSheet(
                    title: "New City",
                    initialName: ""
                ) { newName in
                    createCity(named: newName)
                }
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

    private func createCity(named name: String) {
        do {
            let city = try repository.createFeastList(named: name)
            selectedCityURIString = city.objectURIString
            DispatchQueue.main.async {
                dismiss()
            }
        } catch {
            alertState = NotesImportAlertState(
                title: "Couldn't Create City",
                message: error.localizedDescription
            )
        }
    }
}

private struct NotesImportReviewView: View {
    @Environment(\.managedObjectContext) private var viewContext
    @Environment(\.persistenceController) private var persistenceController
    @Environment(\.applePlacesService) private var applePlacesService

    @FetchRequest(fetchRequest: NotesImportSupport.feastListsFetchRequest, animation: .default)
    private var feastLists: FetchedResults<FeastList>

    let destination: NotesImportReviewDestination
    let onDone: () -> Void
    let onViewImportedCity: (String) -> Void

    @State private var reviewItems: [NotesImportReviewItem] = []
    @State private var isMatchingAll = false
    @State private var isImporting = false
    @State private var editorItem: NotesImportReviewItem?
    @State private var alertState: NotesImportAlertState?
    @State private var commitSuccess: NotesImportCommitSuccess?

    var body: some View {
        List {
            summarySection
            reviewBucketsSection
            importSection
        }
        .feastScrollableChrome()
        .listStyle(.insetGrouped)
        .navigationTitle("Review Import")
        .navigationBarTitleDisplayMode(.inline)
        .task(id: selectedCity?.objectURIString ?? destination.id.uuidString) {
            await prepareReviewItemsIfNeeded()
        }
        .sheet(item: $editorItem) { item in
            NavigationStack {
                NotesImportReviewItemEditorSheet(
                    item: item,
                    cityName: selectedCity?.displayName ?? destination.reviewState.cityName,
                    neighborhoodNames: availableNeighborhoodNames,
                    onSave: updateReviewItem
                )
            }
        }
        .navigationDestination(item: $commitSuccess) { success in
            NotesImportSuccessView(
                success: success,
                onDone: onDone,
                onViewImportedCity: onViewImportedCity
            )
        }
        .alert(item: $alertState) { alert in
            Alert(
                title: Text(alert.title),
                message: Text(alert.message),
                dismissButton: .default(Text("OK"))
            )
        }
    }

    private var selectedCity: FeastList? {
        NotesImportSupport.feastList(
            matching: destination.cityURIString,
            in: feastLists
        )
    }

    private var matchedCount: Int {
        reviewItems.filter { $0.bucket == .matched }.count
    }

    private var needsReviewCount: Int {
        reviewItems.filter { $0.bucket == .needsReview }.count
    }

    private var skippedCount: Int {
        reviewItems.filter { $0.bucket == .skipped }.count
    }

    private var availableNeighborhoodNames: [String] {
        NotesImportReviewBuilder.sessionNeighborhoodNames(
            existingNeighborhoodNames: selectedCity?.neighborhoodSections.map(\.displayName) ?? [],
            reviewItems: reviewItems
        )
    }

    private var readyImportDrafts: [FeastRepository.ImportedSavedPlaceDraft] {
        reviewItems.compactMap { item in
            importDraft(from: item)
        }
    }

    private var canImport: Bool {
        selectedCity != nil && !isMatchingAll && !isImporting && !readyImportDrafts.isEmpty
    }

    private var repository: FeastRepository {
        FeastRepository(
            context: viewContext,
            persistenceController: persistenceController
        )
    }

    private var summarySection: some View {
        Section {
            FeastFormGroup {
                FeastFormField(title: "City") {
                    Text(destination.reviewState.cityName)
                        .font(FeastTheme.Typography.supporting.weight(.semibold))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .feastFieldSurface(minHeight: 52)
                }

                FeastFormDivider()

                FeastFormField(title: "Source") {
                    Text(destination.reviewState.source.title)
                        .font(FeastTheme.Typography.supporting.weight(.semibold))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .feastFieldSurface(minHeight: 52)
                }

                FeastFormDivider()

                FeastFormField(title: destination.reviewState.source.detailTitle) {
                    Text(destination.reviewState.source.detail)
                        .font(FeastTheme.Typography.supporting)
                        .foregroundStyle(FeastTheme.Colors.secondaryText)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .feastFieldSurface(minHeight: 52)
                }

                FeastFormDivider()

                FeastFormField(
                    title: "Parsed",
                    helper: destination.reviewState.parsedNeighborhoodCount == 0
                        ? "No Neighborhood headings found yet."
                        : "Neighborhood headings stay separate during review."
                ) {
                    Text(parsedSummary)
                        .font(FeastTheme.Typography.supporting.weight(.semibold))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .feastFieldSurface(minHeight: 52)
                }

                FeastFormDivider()

                FeastFormField(
                    title: "Review Buckets",
                    helper: isMatchingAll
                        ? "Checking Apple Maps matches for each parsed place."
                        : "Nothing is saved until you import confirmed matches."
                ) {
                    Text(bucketSummary)
                        .font(FeastTheme.Typography.supporting.weight(.semibold))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .feastFieldSurface(minHeight: 52)
                }
            }
        } header: {
            FeastFormSectionHeader(
                title: "Summary",
                subtitle: "Feast parsed your note and organized the results for review"
            )
        }
        .feastSectionSurface()
    }

    @ViewBuilder
    private var reviewBucketsSection: some View {
        if let selectedCity {
            if reviewItems.isEmpty, destination.reviewState.placeCount == 0 {
                Section {
                    FeastFormGroup {
                        VStack(alignment: .leading, spacing: FeastTheme.Spacing.small) {
                            Label("Nothing to review yet", systemImage: "text.magnifyingglass")
                                .font(FeastTheme.Typography.body.weight(.semibold))
                                .foregroundStyle(FeastTheme.Colors.primaryText)

                            Text("Feast couldn't find any checklist or bullet place lines to review.")
                                .font(FeastTheme.Typography.supporting)
                                .foregroundStyle(FeastTheme.Colors.secondaryText)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                } header: {
                    FeastFormSectionHeader(
                        title: "Review",
                        subtitle: "Add place lines to the note and try again"
                    )
                }
                .feastSectionSurface()
            } else if reviewItems.isEmpty {
                Section {
                    FeastFormGroup {
                        HStack(spacing: FeastTheme.Spacing.medium) {
                            ProgressView()
                            Text("Checking Apple Maps for \(destination.reviewState.placeCount) parsed \(destination.reviewState.placeCount == 1 ? "place" : "places") in \(selectedCity.displayName).")
                                .font(FeastTheme.Typography.supporting)
                                .foregroundStyle(FeastTheme.Colors.secondaryText)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                } header: {
                    FeastFormSectionHeader(
                        title: "Matching",
                        subtitle: "Feast is preparing the review buckets"
                    )
                }
                .feastSectionSurface()
            } else {
                ForEach(NotesImportReviewBucket.allCases) { bucket in
                    let items = items(in: bucket)

                    if !items.isEmpty {
                        Section {
                            FeastFormGroup {
                                ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                                    Button {
                                        editorItem = item
                                    } label: {
                                        NotesImportReviewItemRow(item: item)
                                    }
                                    .buttonStyle(.plain)

                                    if index < items.count - 1 {
                                        FeastFormDivider()
                                    }
                                }
                            }
                        } header: {
                            FeastFormSectionHeader(
                                title: bucket.rawValue,
                                subtitle: sectionSubtitle(for: bucket, count: items.count, cityName: selectedCity.displayName)
                            )
                        }
                        .feastSectionSurface()
                    }
                }
            }
        } else {
            Section {
                FeastFormGroup {
                    ContentUnavailableView(
                        "City Unavailable",
                        systemImage: "building.2.slash",
                        description: Text("The selected city is no longer available for this import review.")
                    )
                }
            } header: {
                FeastFormSectionHeader(
                    title: "Review",
                    subtitle: "Choose a City again before continuing"
                )
            }
        }
    }

    private var importSection: some View {
        Section {
            FeastFormGroup {
                VStack(alignment: .leading, spacing: FeastTheme.Spacing.small) {
                    Label(importTitle, systemImage: importIconName)
                        .font(FeastTheme.Typography.body.weight(.semibold))
                        .foregroundStyle(FeastTheme.Colors.primaryText)

                    Text(importMessage)
                        .font(FeastTheme.Typography.supporting)
                        .foregroundStyle(FeastTheme.Colors.secondaryText)
                        .fixedSize(horizontal: false, vertical: true)

                    Button {
                        commitImport()
                    } label: {
                        HStack(spacing: FeastTheme.Spacing.small) {
                            if isImporting {
                                ProgressView()
                                    .controlSize(.small)
                            }

                            Text(importButtonTitle)
                                .frame(maxWidth: .infinity)
                        }
                    }
                    .buttonStyle(FeastProminentButtonStyle())
                    .disabled(!canImport)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        } header: {
            FeastFormSectionHeader(
                title: "Import",
                subtitle: "Only confirmed Apple Maps matches move into Feast"
            )
        }
        .feastSectionSurface()
    }

    private var parsedSummary: String {
        let placeLabel = destination.reviewState.placeCount == 1
            ? "1 place"
            : "\(destination.reviewState.placeCount) places"
        let neighborhoodLabel: String

        if destination.reviewState.parsedNeighborhoodCount == 1 {
            neighborhoodLabel = "1 neighborhood"
        } else if destination.reviewState.parsedNeighborhoodCount > 1 {
            neighborhoodLabel = "\(destination.reviewState.parsedNeighborhoodCount) neighborhoods"
        } else {
            neighborhoodLabel = "No neighborhoods inferred"
        }

        return "\(placeLabel) • \(neighborhoodLabel) • \(destination.reviewState.nonEmptyLineCount) lines"
    }

    private var bucketSummary: String {
        "\(matchedCount) matched • \(needsReviewCount) need review • \(skippedCount) skipped"
    }

    private func items(in bucket: NotesImportReviewBucket) -> [NotesImportReviewItem] {
        reviewItems
            .filter { $0.bucket == bucket }
            .sorted { lhs, rhs in
                lhs.sourceLineNumber < rhs.sourceLineNumber
            }
    }

    private func sectionSubtitle(
        for bucket: NotesImportReviewBucket,
        count: Int,
        cityName: String
    ) -> String {
        let countLabel = count == 1 ? "1 item" : "\(count) items"

        switch bucket {
        case .matched:
            return "\(countLabel) look ready to import into \(cityName)"
        case .needsReview:
            return "\(countLabel) still need a match, a cleaner name, or a clearer Neighborhood"
        case .skipped:
            return "\(countLabel) will stay out of this import"
        }
    }

    @MainActor
    private func prepareReviewItemsIfNeeded() async {
        guard
            reviewItems.isEmpty,
            let selectedCity
        else {
            return
        }

        reviewItems = NotesImportReviewBuilder.makeItems(
            from: destination.reviewState,
            in: selectedCity
        )

        guard !reviewItems.isEmpty else {
            return
        }

        isMatchingAll = true

        for index in reviewItems.indices {
            let updatedItem = await NotesImportMatcher.match(
                reviewItems[index],
                cityName: selectedCity.displayName,
                neighborhoodNames: selectedCity.neighborhoodSections.map(\.displayName),
                using: applePlacesService
            )
            reviewItems[index] = updatedItem
        }

        isMatchingAll = false
    }

    private func updateReviewItem(_ updatedItem: NotesImportReviewItem) {
        guard let index = reviewItems.firstIndex(where: { $0.id == updatedItem.id }) else {
            return
        }

        var normalizedItem = updatedItem
        normalizedItem.selectedNeighborhoodName = canonicalNeighborhoodName(
            for: updatedItem.selectedNeighborhoodName
        )
        reviewItems[index] = normalizedItem
        synchronizeNeighborhoodSelection(from: normalizedItem)
    }

    private func synchronizeNeighborhoodSelection(from updatedItem: NotesImportReviewItem) {
        guard
            let canonicalNeighborhoodName = updatedItem.selectedNeighborhoodName,
            let parsedNeighborhoodKey = NotesImportReviewBuilder.normalizedKey(
                for: updatedItem.parsedNeighborhoodName
            ),
            let selectedNeighborhoodKey = NotesImportReviewBuilder.normalizedKey(
                for: canonicalNeighborhoodName
            )
        else {
            return
        }

        for index in reviewItems.indices where reviewItems[index].id != updatedItem.id {
            let rowParsedNeighborhoodKey = NotesImportReviewBuilder.normalizedKey(
                for: reviewItems[index].parsedNeighborhoodName
            )
            guard rowParsedNeighborhoodKey == parsedNeighborhoodKey else {
                continue
            }

            let currentSelectionKey = NotesImportReviewBuilder.normalizedKey(
                for: reviewItems[index].selectedNeighborhoodName
            )

            if currentSelectionKey == nil || currentSelectionKey == selectedNeighborhoodKey {
                reviewItems[index].selectedNeighborhoodName = canonicalNeighborhoodName
            }
        }
    }

    private func canonicalNeighborhoodName(for rawValue: String?) -> String? {
        NotesImportReviewBuilder.matchedNeighborhoodName(
            for: rawValue,
            in: availableNeighborhoodNames
        ) ?? NotesImportReviewBuilder.canonicalNeighborhoodName(for: rawValue)
    }

    private var importTitle: String {
        if isMatchingAll {
            return "Matching Apple Maps"
        }

        if readyImportDrafts.isEmpty {
            return "Nothing Ready Yet"
        }

        return readyImportDrafts.count == 1 ? "1 Place Ready" : "\(readyImportDrafts.count) Places Ready"
    }

    private var importIconName: String {
        if isMatchingAll {
            return "magnifyingglass.circle"
        }

        return readyImportDrafts.isEmpty ? "tray" : "square.and.arrow.down"
    }

    private var importMessage: String {
        if isMatchingAll {
            return "Wait for Apple Maps matching to finish before importing reviewed places."
        }

        let heldBackCount = reviewItems.count - readyImportDrafts.count

        if readyImportDrafts.isEmpty {
            if needsReviewCount > 0 {
                return "Review each place, choose an Apple Maps match, and confirm the Neighborhood before importing."
            }

            if skippedCount > 0 {
                return "Everything in this pass is currently skipped. Restore any places you want to import."
            }

            return "Choose Apple Maps matches for the places you want to bring in."
        }

        if heldBackCount == 0 {
            return "Everything reviewed is ready for \(selectedCity?.displayName ?? destination.reviewState.cityName)."
        }

        return "\(readyImportDrafts.count) ready to import • \(heldBackCount) still need review or are skipped."
    }

    private var importButtonTitle: String {
        if isImporting {
            return readyImportDrafts.count == 1 ? "Importing 1 Place" : "Importing \(readyImportDrafts.count) Places"
        }

        return readyImportDrafts.count == 1 ? "Import 1 Place" : "Import \(readyImportDrafts.count) Places"
    }

    private func importDraft(from item: NotesImportReviewItem) -> FeastRepository.ImportedSavedPlaceDraft? {
        guard
            !item.isSkipped,
            let matchedPlace = item.matchedPlace
        else {
            return nil
        }

        let displayName = NotesImportSupport.trimmed(matchedPlace.displayName).isEmpty
            ? NotesImportSupport.trimmed(item.parsedPlaceName)
            : matchedPlace.displayName
        guard !displayName.isEmpty else {
            return nil
        }

        return FeastRepository.ImportedSavedPlaceDraft(
            applePlaceID: matchedPlace.applePlaceID,
            displayNameSnapshot: displayName,
            status: item.status,
            placeType: item.placeType ?? .other,
            cuisines: item.cuisines,
            tags: item.tags,
            note: item.note,
            websiteURL: item.websiteURL ?? matchedPlace.websiteURL,
            instagramURL: item.instagramURL ?? matchedPlace.instagramURL,
            neighborhoodName: item.selectedNeighborhoodName
        )
    }

    private func commitImport() {
        guard
            let selectedCity,
            canImport
        else {
            return
        }

        isImporting = true

        do {
            let result = try repository.importSavedPlaces(
                from: readyImportDrafts,
                into: selectedCity
            )
            let skippedCount = max(reviewItems.count - readyImportDrafts.count + result.duplicateCount, 0)

            commitSuccess = NotesImportCommitSuccess(
                cityURIString: result.cityURIString,
                cityName: result.cityName,
                addedCount: result.addedCount,
                skippedCount: skippedCount,
                duplicateCount: result.duplicateCount
            )
        } catch {
            alertState = NotesImportAlertState(
                title: "Couldn't Import Places",
                message: error.localizedDescription
            )
        }

        isImporting = false
    }
}

private struct NotesImportReviewItemRow: View {
    let item: NotesImportReviewItem

    var body: some View {
        HStack(alignment: .top, spacing: FeastTheme.Spacing.medium) {
            ZStack {
                RoundedRectangle(
                    cornerRadius: FeastTheme.CornerRadius.small,
                    style: .continuous
                )
                .fill(iconBackground)
                .frame(width: 38, height: 38)

                Image(systemName: iconSystemName)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(iconForeground)
            }

            VStack(alignment: .leading, spacing: 6) {
                Text(item.parsedPlaceName)
                    .font(FeastTheme.Typography.body.weight(.semibold))
                    .foregroundStyle(FeastTheme.Colors.primaryText)
                    .fixedSize(horizontal: false, vertical: true)

                Text(metadataLine)
                    .font(FeastTheme.Typography.rowMetadata)
                    .foregroundStyle(FeastTheme.Colors.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)

                if let matchedPlace = item.matchedPlace {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Apple Maps: \(matchedPlace.displayName)")
                            .font(FeastTheme.Typography.rowMetadata.weight(.semibold))
                            .foregroundStyle(FeastTheme.Colors.primaryText)

                        if !matchedPlace.secondaryText.isEmpty {
                            Text(matchedPlace.secondaryText)
                                .font(FeastTheme.Typography.rowUtility)
                                .foregroundStyle(FeastTheme.Colors.tertiaryText)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                } else if item.bucket == .needsReview {
                    Text("Choose an Apple Maps match")
                        .font(FeastTheme.Typography.rowUtility.weight(.semibold))
                        .foregroundStyle(FeastTheme.Colors.secondaryAction)
                }

                if let notePreview = item.notePreview {
                    Text(notePreview)
                        .font(FeastTheme.Typography.supporting)
                        .foregroundStyle(FeastTheme.Colors.secondaryText)
                        .fixedSize(horizontal: false, vertical: true)
                }

                if let matchingErrorMessage = item.matchingErrorMessage, !matchingErrorMessage.isEmpty {
                    Text(matchingErrorMessage)
                        .font(FeastTheme.Typography.rowUtility)
                        .foregroundStyle(FeastTheme.Colors.secondaryAction)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            Spacer(minLength: FeastTheme.Spacing.small)

            Image(systemName: "chevron.right")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(FeastTheme.Colors.tertiaryText)
                .padding(.top, 6)
        }
        .padding(.vertical, FeastTheme.Spacing.small)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var metadataLine: String {
        var components = ["Line \(item.sourceLineNumber)", item.status.rawValue]

        if let selectedNeighborhoodName = item.selectedNeighborhoodName {
            components.append(selectedNeighborhoodName)
        } else if let proposedNeighborhoodName = item.parsedNeighborhoodName {
            components.append("Proposed: \(proposedNeighborhoodName)")
        }

        if let placeType = item.placeType {
            components.append(placeType.rawValue)
        }

        return components.joined(separator: " • ")
    }

    private var iconSystemName: String {
        switch item.bucket {
        case .matched:
            return "mappin.and.ellipse"
        case .needsReview:
            return "mappin.slash"
        case .skipped:
            return "arrow.uturn.backward.circle"
        }
    }

    private var iconBackground: Color {
        switch item.bucket {
        case .matched:
            return FeastTheme.Colors.accentSelection.opacity(0.22)
        case .needsReview:
            return FeastTheme.Colors.groupedBackground
        case .skipped:
            return FeastTheme.Colors.surfaceBackground
        }
    }

    private var iconForeground: Color {
        switch item.bucket {
        case .matched:
            return FeastTheme.Colors.primaryActionLabel
        case .needsReview:
            return FeastTheme.Colors.secondaryAction
        case .skipped:
            return FeastTheme.Colors.tertiaryText
        }
    }
}

private struct NotesImportReviewItemEditorSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.applePlacesService) private var applePlacesService

    private static let newNeighborhoodPromptToken = "__feast_new_neighborhood__"

    let item: NotesImportReviewItem
    let cityName: String
    let neighborhoodNames: [String]
    let onSave: (NotesImportReviewItem) -> Void

    @State private var parsedPlaceName: String
    @State private var selectedNeighborhoodName: String?
    @State private var committedNeighborhoodSelection: String?
    @State private var matchedPlace: ApplePlaceMatch?
    @State private var suggestedMatches: [ApplePlaceMatch]
    @State private var isSkipped: Bool
    @State private var searchQuery: String
    @State private var searchResults: [ApplePlaceMatch] = []
    @State private var searchState: NotesImportMatchSearchState = .idle
    @State private var validationMessage: String?
    @State private var followsParsedName = true
    @State private var showingNewNeighborhoodSheet = false
    @State private var newNeighborhoodName = ""

    init(
        item: NotesImportReviewItem,
        cityName: String,
        neighborhoodNames: [String],
        onSave: @escaping (NotesImportReviewItem) -> Void
    ) {
        self.item = item
        self.cityName = cityName
        self.neighborhoodNames = neighborhoodNames
        self.onSave = onSave
        _parsedPlaceName = State(initialValue: item.parsedPlaceName)
        _selectedNeighborhoodName = State(
            initialValue: NotesImportReviewBuilder.matchedNeighborhoodName(
                for: item.selectedNeighborhoodName,
                in: neighborhoodNames
            )
                ?? NotesImportReviewBuilder.canonicalNeighborhoodName(for: item.selectedNeighborhoodName)
                ?? NotesImportReviewBuilder.suggestedNeighborhoodSuggestion(
                    for: item,
                    matchedPlace: item.matchedPlace,
                    cityName: cityName,
                    existingNeighborhoodNames: neighborhoodNames
                )?.existingMatch
        )
        _committedNeighborhoodSelection = State(
            initialValue: NotesImportReviewBuilder.matchedNeighborhoodName(
                for: item.selectedNeighborhoodName,
                in: neighborhoodNames
            )
                ?? NotesImportReviewBuilder.canonicalNeighborhoodName(for: item.selectedNeighborhoodName)
                ?? NotesImportReviewBuilder.suggestedNeighborhoodSuggestion(
                    for: item,
                    matchedPlace: item.matchedPlace,
                    cityName: cityName,
                    existingNeighborhoodNames: neighborhoodNames
                )?.existingMatch
        )
        _matchedPlace = State(initialValue: item.matchedPlace)
        _suggestedMatches = State(initialValue: item.suggestedMatches)
        _isSkipped = State(initialValue: item.isSkipped)
        _searchQuery = State(
            initialValue: NotesImportMatcher.searchQueries(for: item, cityName: cityName).first
                ?? item.parsedPlaceName
        )
    }

    var body: some View {
        List {
            parsedSection
            matchSection
            neighborhoodSection
            skipSection
        }
        .feastScrollableChrome()
        .listStyle(.insetGrouped)
        .navigationTitle("Review Place")
        .navigationBarTitleDisplayMode(.inline)
        .scrollDismissesKeyboard(.interactively)
        .task(id: searchQuery) {
            await search(for: searchQuery)
        }
        .onChange(of: selectedNeighborhoodName) { _, newValue in
            handleNeighborhoodSelectionChange(newValue)
        }
        .onChange(of: parsedPlaceName) { _, newValue in
            validationMessage = nil

            guard followsParsedName else {
                return
            }

            searchQuery = NotesImportMatcher.searchQueries(
                for: previewItem(with: newValue),
                cityName: cityName
            ).first ?? newValue
        }
        .onChange(of: searchQuery) { _, newValue in
            let preferredQuery = NotesImportMatcher.searchQueries(
                for: previewItem(with: parsedPlaceName),
                cityName: cityName
            ).first ?? parsedPlaceName

            if NotesImportSupport.trimmed(newValue) != NotesImportSupport.trimmed(preferredQuery) {
                followsParsedName = false
            }
        }
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Cancel") {
                    dismiss()
                }
            }

            ToolbarItem(placement: .confirmationAction) {
                Button("Save") {
                    saveChanges()
                }
                .fontWeight(.semibold)
            }
        }
        .sheet(isPresented: $showingNewNeighborhoodSheet) {
            NavigationStack {
                NeighborhoodNamePromptSheet(
                    initialName: newNeighborhoodName,
                    onConfirm: applyManualNeighborhoodName(_:)
                )
            }
        }
    }

    private var parsedSection: some View {
        Section {
            FeastFormGroup {
                FeastFormField(
                    title: "Place Name",
                    helper: validationMessage ?? "Clean up the parsed place name if needed.",
                    helperColor: validationMessage == nil
                        ? FeastTheme.Colors.secondaryText
                        : FeastTheme.Colors.secondaryAction
                ) {
                    TextField("Place Name", text: $parsedPlaceName)
                        .textInputAutocapitalization(.words)
                        .autocorrectionDisabled()
                        .feastFieldSurface(minHeight: 52)
                }

                FeastFormDivider()

                FeastFormField(title: "Parsed Context") {
                    Text(contextSummary)
                        .font(FeastTheme.Typography.supporting)
                        .foregroundStyle(FeastTheme.Colors.secondaryText)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .feastFieldSurface(minHeight: 52)
                }
            }
        } header: {
            FeastFormSectionHeader(
                title: "Parsed Item",
                subtitle: "Clean up the parsed place before import"
            )
        }
        .feastSectionSurface()
    }

    private var matchSection: some View {
        Section {
            FeastFormGroup {
                FeastFormField(
                    title: "Apple Maps Match",
                    helper: matchedPlace == nil
                        ? "Choose the exact Apple Maps place before this can be imported."
                        : "You can keep this match or choose a different one."
                ) {
                    VStack(alignment: .leading, spacing: FeastTheme.Spacing.small) {
                        if let matchedPlace {
                            NotesImportMatchResultRow(
                                place: matchedPlace,
                                isSelected: true
                            )

                            Button("Clear Match") {
                                self.matchedPlace = nil
                            }
                            .font(FeastTheme.Typography.rowMetadata.weight(.semibold))
                            .foregroundStyle(FeastTheme.Colors.secondaryAction)
                        } else {
                            Text("No match selected yet")
                                .font(FeastTheme.Typography.supporting.weight(.semibold))
                                .foregroundStyle(FeastTheme.Colors.secondaryText)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }

                FeastFormDivider()

                FeastFormField(
                    title: "Search Apple Maps",
                    helper: "Try the parsed name, a cleaner spelling, or add a Neighborhood."
                ) {
                    VStack(alignment: .leading, spacing: FeastTheme.Spacing.medium) {
                        HStack(spacing: FeastTheme.Spacing.small) {
                            Image(systemName: "magnifyingglass")
                                .font(.system(size: 16, weight: .semibold))
                                .foregroundStyle(FeastTheme.Colors.tertiaryText)

                            TextField("Search Apple Maps", text: $searchQuery)
                                .textInputAutocapitalization(.words)
                                .autocorrectionDisabled()

                            if !searchQuery.isEmpty {
                                Button {
                                    followsParsedName = false
                                    searchQuery = ""
                                } label: {
                                    Image(systemName: "xmark.circle.fill")
                                        .foregroundStyle(FeastTheme.Colors.secondaryAction)
                                }
                                .buttonStyle(.plain)
                            }
                        }
                        .feastFieldSurface(minHeight: 52)

                        matchResultsBody
                    }
                }
            }
        } header: {
            FeastFormSectionHeader(
                title: "Apple Maps",
                subtitle: "Choose the exact place Feast should carry forward"
            )
        }
        .feastSectionSurface()
    }

    private var neighborhoodSection: some View {
        Section {
            FeastFormGroup {
                FeastFormField(
                    title: "Neighborhood",
                    helper: neighborhoodHelper
                ) {
                    Picker("Neighborhood", selection: $selectedNeighborhoodName) {
                        Text("Unsorted").tag(nil as String?)

                        if let proposedNeighborhoodOption {
                            Text("Create “\(proposedNeighborhoodOption)”").tag(proposedNeighborhoodOption as String?)
                        }

                        if let manualNeighborhoodToCreate {
                            Text("Create “\(manualNeighborhoodToCreate)”").tag(manualNeighborhoodToCreate as String?)
                        }

                        Text("New Neighborhood…")
                            .tag(Self.newNeighborhoodPromptToken as String?)

                        ForEach(neighborhoodNames, id: \.self) { neighborhoodName in
                            Text(neighborhoodName).tag(neighborhoodName as String?)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                    .tint(FeastTheme.Colors.primaryText)
                }
            }
        } header: {
            FeastFormSectionHeader(
                title: "Neighborhood Assignment",
                subtitle: "Choose where this place should land in the City"
            )
        }
        .feastSectionSurface()
    }

    private var skipSection: some View {
        Section {
            FeastFormGroup {
                Button {
                    isSkipped.toggle()
                } label: {
                    HStack {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(isSkipped ? "Restore Place" : "Skip for Now")
                                .font(FeastTheme.Typography.supporting.weight(.semibold))
                                .foregroundStyle(FeastTheme.Colors.primaryText)

                            Text(isSkipped
                                ? "Move it back into review when you're ready."
                                : "Keep it in review but out of this import.")
                                .font(FeastTheme.Typography.rowMetadata)
                                .foregroundStyle(FeastTheme.Colors.secondaryText)
                                .fixedSize(horizontal: false, vertical: true)
                        }

                        Spacer(minLength: FeastTheme.Spacing.small)

                        Image(systemName: isSkipped ? "arrow.uturn.backward.circle.fill" : "arrow.right.circle")
                            .foregroundStyle(FeastTheme.Colors.secondaryAction)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .buttonStyle(.plain)
            }
        } header: {
            FeastFormSectionHeader(
                title: "Skip",
                subtitle: "Skipped places stay visible and out of this import"
            )
        }
        .feastSectionSurface()
    }

    @ViewBuilder
    private var matchResultsBody: some View {
        switch searchState {
        case .idle:
            if availableMatches.isEmpty {
                Text("Search results appear here.")
                    .font(FeastTheme.Typography.rowMetadata)
                    .foregroundStyle(FeastTheme.Colors.secondaryText)
            } else {
                matchesList(availableMatches)
            }
        case .loading:
            HStack(spacing: FeastTheme.Spacing.medium) {
                ProgressView()
                Text("Searching Apple Maps...")
                    .font(FeastTheme.Typography.supporting)
                    .foregroundStyle(FeastTheme.Colors.secondaryText)
            }
        case .loaded:
            if availableMatches.isEmpty {
                Text("No matches yet. Try a more specific search.")
                    .font(FeastTheme.Typography.rowMetadata)
                    .foregroundStyle(FeastTheme.Colors.secondaryText)
            } else {
                matchesList(availableMatches)
            }
        case let .failed(message):
            Text(message)
                .font(FeastTheme.Typography.rowMetadata)
                .foregroundStyle(FeastTheme.Colors.secondaryAction)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var availableMatches: [ApplePlaceMatch] {
        var orderedMatches: [ApplePlaceMatch] = []
        var seenIDs: Set<String> = []

        for match in [matchedPlace].compactMap({ $0 }) + searchResults + suggestedMatches {
            guard !seenIDs.contains(match.applePlaceID) else {
                continue
            }

            seenIDs.insert(match.applePlaceID)
            orderedMatches.append(match)
        }

        return orderedMatches
    }

    private var contextSummary: String {
        var components = [item.status.rawValue]

        if let parsedNeighborhoodName = item.parsedNeighborhoodName {
            components.append(parsedNeighborhoodName)
        }

        if let placeType = item.placeType {
            components.append(placeType.rawValue)
        }

        components.append(contentsOf: item.tags)
        return components.joined(separator: " • ")
    }

    private var suggestedNeighborhood: FeastNeighborhoodName.Suggestion? {
        NotesImportReviewBuilder.suggestedNeighborhoodSuggestion(
            for: item,
            matchedPlace: matchedPlace,
            cityName: cityName,
            existingNeighborhoodNames: neighborhoodNames
        )
    }

    private var proposedNeighborhoodOption: String? {
        guard
            let suggestedNeighborhood,
            suggestedNeighborhood.existingMatch == nil
        else {
            return nil
        }

        return suggestedNeighborhood.displayName
    }

    private var manualNeighborhoodToCreate: String? {
        guard
            let selectedNeighborhoodName,
            matchedNeighborhoodName(for: selectedNeighborhoodName) == nil,
            let canonicalNeighborhoodName = NotesImportReviewBuilder.canonicalNeighborhoodName(
                for: selectedNeighborhoodName
            )
        else {
            return nil
        }

        if let proposedNeighborhoodOption,
           FeastNeighborhoodName.matches(canonicalNeighborhoodName, proposedNeighborhoodOption) {
            return nil
        }

        return canonicalNeighborhoodName
    }

    private var neighborhoodHelper: String {
        if let selectedNeighborhoodName {
            if matchedNeighborhoodName(for: selectedNeighborhoodName) != nil {
                return "This place will import into \(selectedNeighborhoodName)."
            }

            return "\(selectedNeighborhoodName) will be created during import."
        }

        if let proposedNeighborhoodOption {
            return "Suggested Neighborhood: \(proposedNeighborhoodOption). Choose it to create that Neighborhood during import, pick an existing neighborhood, or use New Neighborhood…."
        }

        if let suggestedNeighborhood, suggestedNeighborhood.existingMatch != nil {
            return "Suggested Neighborhood: \(suggestedNeighborhood.displayName)."
        }

        return "Leave it Unsorted, choose an existing neighborhood, or use New Neighborhood…."
    }

    private func matchesList(_ matches: [ApplePlaceMatch]) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(matches.enumerated()), id: \.element.id) { index, match in
                Button {
                    matchedPlace = match
                } label: {
                    NotesImportMatchResultRow(
                        place: match,
                        isSelected: matchedPlace?.applePlaceID == match.applePlaceID
                    )
                }
                .buttonStyle(.plain)

                if index < matches.count - 1 {
                    FeastFormDivider()
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @MainActor
    private func search(for rawQuery: String) async {
        let trimmedQuery = NotesImportSupport.trimmed(rawQuery)

        guard trimmedQuery.count >= 2 else {
            searchResults = []
            searchState = .idle
            return
        }

        searchState = .loading

        do {
            try await Task.sleep(nanoseconds: 250_000_000)
            let matches = try await applePlacesService.search(query: trimmedQuery)

            if Task.isCancelled {
                return
            }

            searchResults = Array(matches.prefix(6))
            searchState = .loaded
        } catch is CancellationError {
            return
        } catch {
            searchResults = []
            searchState = .failed(error.localizedDescription)
        }
    }

    private func matchedNeighborhoodName(for rawValue: String?) -> String? {
        NotesImportReviewBuilder.matchedNeighborhoodName(
            for: rawValue,
            in: neighborhoodNames
        )
    }

    private func previewItem(with parsedName: String) -> NotesImportReviewItem {
        var previewItem = item
        previewItem.parsedPlaceName = parsedName
        return previewItem
    }

    private func handleNeighborhoodSelectionChange(_ newValue: String?) {
        guard newValue == Self.newNeighborhoodPromptToken else {
            committedNeighborhoodSelection = newValue
            return
        }

        if let committedNeighborhoodSelection,
           matchedNeighborhoodName(for: committedNeighborhoodSelection) == nil {
            newNeighborhoodName = committedNeighborhoodSelection
        } else {
            newNeighborhoodName = ""
        }

        showingNewNeighborhoodSheet = true
        selectedNeighborhoodName = committedNeighborhoodSelection
    }

    private func applyManualNeighborhoodName(_ rawValue: String) {
        guard let canonicalNeighborhoodName = NotesImportReviewBuilder.canonicalNeighborhoodName(
            for: rawValue
        ) else {
            return
        }

        selectedNeighborhoodName = matchedNeighborhoodName(for: canonicalNeighborhoodName)
            ?? canonicalNeighborhoodName
    }

    private func saveChanges() {
        let trimmedPlaceName = NotesImportSupport.trimmed(parsedPlaceName)

        guard !trimmedPlaceName.isEmpty else {
            validationMessage = "Place name can't be blank."
            return
        }

        var updatedItem = item
        updatedItem.parsedPlaceName = trimmedPlaceName
        updatedItem.selectedNeighborhoodName = NotesImportReviewBuilder.matchedNeighborhoodName(
            for: selectedNeighborhoodName,
            in: neighborhoodNames
        ) ?? NotesImportReviewBuilder.canonicalNeighborhoodName(for: selectedNeighborhoodName)
        updatedItem.suggestedMatches = availableMatches
        updatedItem.isSkipped = isSkipped
        updatedItem.matchingErrorMessage = nil

        let nameChanged = NotesImportReviewBuilder.normalizedKey(for: trimmedPlaceName)
            != NotesImportReviewBuilder.normalizedKey(for: item.parsedPlaceName)
        let keptOriginalMatch = matchedPlace?.applePlaceID == item.matchedPlace?.applePlaceID

        if nameChanged && keptOriginalMatch {
            updatedItem.matchedPlace = nil
        } else {
            updatedItem.matchedPlace = matchedPlace
        }

        onSave(updatedItem)
        dismiss()
    }
}

private struct NotesImportSuccessView: View {
    let success: NotesImportCommitSuccess
    let onDone: () -> Void
    let onViewImportedCity: (String) -> Void

    var body: some View {
        GeometryReader { proxy in
            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: 0) {
                    summarySection

                    Spacer(minLength: FeastTheme.Spacing.xLarge)

                    actionSection
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .frame(minHeight: proxy.size.height, alignment: .top)
                .padding(.horizontal, FeastTheme.Spacing.large)
                .padding(.top, FeastTheme.Spacing.large)
                .padding(.bottom, FeastTheme.Spacing.xxLarge)
            }
        }
        .feastScrollableChrome()
        .navigationTitle("Import Complete")
        .navigationBarTitleDisplayMode(.inline)
        .navigationBarBackButtonHidden(true)
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Button {
                    onDone()
                } label: {
                    FeastToolbarSymbol(systemName: "xmark")
                }
                .accessibilityLabel("Close")
            }
        }
    }

    private var summarySection: some View {
        VStack(alignment: .leading, spacing: FeastTheme.Spacing.large) {
            HStack(alignment: .top, spacing: FeastTheme.Spacing.medium) {
                ZStack {
                    Circle()
                        .fill(successIconBackground)
                        .frame(width: 44, height: 44)

                    Image(systemName: successIconName)
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundStyle(successIconForeground)
                }

                VStack(alignment: .leading, spacing: FeastTheme.Spacing.small) {
                    Text(successTitle)
                        .font(FeastTheme.Typography.sectionTitle)
                        .foregroundStyle(FeastTheme.Colors.primaryText)

                    Text(successMessage)
                        .font(FeastTheme.Typography.supporting)
                        .foregroundStyle(FeastTheme.Colors.secondaryText)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            VStack(alignment: .leading, spacing: FeastTheme.Spacing.medium) {
                summaryRow(title: "City", value: success.cityName)

                HStack(alignment: .top, spacing: FeastTheme.Spacing.large) {
                    summaryMetric(title: "Added", value: addedSummaryValue)

                    if success.skippedCount > 0 {
                        Rectangle()
                            .fill(FeastTheme.Colors.dividerBorder.opacity(0.8))
                            .frame(width: 1)
                            .padding(.vertical, 2)

                        summaryMetric(title: "Skipped", value: skippedSummaryValue)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.top, FeastTheme.Spacing.xSmall)

                if let skippedDetailText {
                    Text(skippedDetailText)
                        .font(FeastTheme.Typography.rowUtility)
                        .foregroundStyle(FeastTheme.Colors.tertiaryText)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(.top, FeastTheme.Spacing.small)
            .overlay(alignment: .top) {
                Rectangle()
                    .fill(FeastTheme.Colors.dividerBorder.opacity(0.7))
                    .frame(height: 1)
                    .offset(y: -FeastTheme.Spacing.small)
            }
        }
        .padding(FeastTheme.Spacing.large)
        .feastCardSurface()
    }

    private var actionSection: some View {
        VStack(alignment: .leading, spacing: FeastTheme.Spacing.large) {
            Rectangle()
                .fill(FeastTheme.Colors.dividerBorder.opacity(0.65))
                .frame(height: 1)

            Button {
                onViewImportedCity(success.cityURIString)
            } label: {
                Text("View City")
                    .frame(maxWidth: .infinity, alignment: .center)
            }
            .buttonStyle(FeastProminentButtonStyle())
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var successTitle: String {
        if success.addedCount > 0 {
            return success.addedCount == 1 ? "1 place imported" : "\(success.addedCount) places imported"
        }

        return "Nothing new imported"
    }

    private var successMessage: String {
        if success.addedCount > 0, success.duplicateCount > 0 {
            return "Added confirmed places to \(success.cityName). \(duplicateSummaryText) already there."
        }

        if success.addedCount > 0, success.skippedCount > 0 {
            return "Added confirmed places to \(success.cityName). Some items stayed out for now."
        }

        if success.addedCount > 0 {
            return "Added confirmed places to \(success.cityName)."
        }

        if success.duplicateCount > 0 {
            return "Everything you confirmed is already in \(success.cityName)."
        }

        return "This import didn’t add anything new to \(success.cityName)."
    }

    private var successIconName: String {
        success.addedCount > 0 ? "checkmark.circle.fill" : "tray.fill"
    }

    private var successIconBackground: Color {
        success.addedCount > 0
            ? FeastTheme.Colors.accentSelection.opacity(0.22)
            : FeastTheme.Colors.surfaceBackground
    }

    private var successIconForeground: Color {
        success.addedCount > 0
            ? FeastTheme.Colors.primaryActionLabel
            : FeastTheme.Colors.secondaryText
    }

    private var addedSummaryValue: String {
        success.addedCount == 1 ? "1 place" : "\(success.addedCount) places"
    }

    private var skippedSummaryValue: String {
        success.skippedCount == 1 ? "1 item" : "\(success.skippedCount) items"
    }

    private var skippedDetailText: String? {
        guard success.skippedCount > 0 else {
            return nil
        }

        if success.duplicateCount > 0 {
            return "\(duplicateSummaryText) already in this City."
        }

        return "Skipped items stayed out of this import."
    }

    private var duplicateSummaryText: String {
        success.duplicateCount == 1 ? "1 place was" : "\(success.duplicateCount) places were"
    }

    @ViewBuilder
    private func summaryRow(title: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title.uppercased())
                .font(FeastTheme.Typography.sectionLabel)
                .tracking(0.8)
                .foregroundStyle(FeastTheme.Colors.secondaryText)

            Text(value)
                .font(FeastTheme.Typography.body.weight(.semibold))
                .foregroundStyle(FeastTheme.Colors.primaryText)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private func summaryMetric(title: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title.uppercased())
                .font(FeastTheme.Typography.sectionLabel)
                .tracking(0.8)
                .foregroundStyle(FeastTheme.Colors.secondaryText)

            Text(value)
                .font(FeastTheme.Typography.sectionTitle)
                .foregroundStyle(FeastTheme.Colors.primaryText)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct NotesImportMatchResultRow: View {
    let place: ApplePlaceMatch
    let isSelected: Bool

    var body: some View {
        HStack(alignment: .top, spacing: FeastTheme.Spacing.small) {
            Image(systemName: isSelected ? "checkmark.circle.fill" : "mappin.circle.fill")
                .font(.system(size: 16))
                .foregroundStyle(
                    isSelected
                        ? FeastTheme.Colors.secondaryAction
                        : FeastTheme.Colors.accentSelection
                )
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
                        .fixedSize(horizontal: false, vertical: true)
                }

                if let neighborhood = place.suggestedSectionPath.neighborhood {
                    Text("Suggested Neighborhood: \(neighborhood)")
                        .font(FeastTheme.Typography.rowUtility)
                        .foregroundStyle(FeastTheme.Colors.tertiaryText)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            Spacer(minLength: 0)
        }
        .padding(.vertical, FeastTheme.Spacing.small)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private enum NotesImportMatchSearchState {
    case idle
    case loading
    case loaded
    case failed(String)
}

private struct NotesImportMethodRow: View {
    let title: String
    let subtitle: String
    let systemName: String

    var body: some View {
        HStack(spacing: FeastTheme.Spacing.medium) {
            ZStack {
                Circle()
                    .fill(FeastTheme.Colors.surfaceBackground)
                    .frame(width: 38, height: 38)

                Image(systemName: systemName)
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(FeastTheme.Colors.secondaryAction)
            }

            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(FeastTheme.Typography.rowTitle)
                    .foregroundStyle(FeastTheme.Colors.primaryText)

                Text(subtitle)
                    .font(FeastTheme.Typography.rowMetadata)
                    .foregroundStyle(FeastTheme.Colors.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.vertical, 4)
    }
}

private struct NotesImportSelectionField: View {
    let title: String
    let subtitle: String
    let systemName: String

    var body: some View {
        HStack(spacing: FeastTheme.Spacing.medium) {
            Image(systemName: systemName)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(FeastTheme.Colors.secondaryAction)
                .frame(width: 18)

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(FeastTheme.Typography.supporting.weight(.semibold))
                    .foregroundStyle(FeastTheme.Colors.primaryText)
                    .lineLimit(1)

                Text(subtitle)
                    .font(FeastTheme.Typography.rowMetadata)
                    .foregroundStyle(FeastTheme.Colors.secondaryText)
                    .lineLimit(2)
            }

            Spacer(minLength: FeastTheme.Spacing.small)

            Image(systemName: "chevron.right")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(FeastTheme.Colors.tertiaryText)
        }
        .feastFieldSurface(minHeight: 52)
    }
}

private struct NotesImportGuidanceBullet: View {
    let text: String

    var body: some View {
        HStack(alignment: .top, spacing: FeastTheme.Spacing.small) {
            Circle()
                .fill(FeastTheme.Colors.secondaryAction.opacity(0.78))
                .frame(width: 6, height: 6)
                .padding(.top, 6)

            Text(text)
                .font(FeastTheme.Typography.rowMetadata)
                .foregroundStyle(FeastTheme.Colors.secondaryText)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

private struct NotesImportAlertState: Identifiable {
    let id = UUID()
    let title: String
    let message: String
}

private struct NotesImportCommitSuccess: Identifiable, Hashable {
    let id = UUID()
    let cityURIString: String
    let cityName: String
    let addedCount: Int
    let skippedCount: Int
    let duplicateCount: Int
}

private enum NotesImportSupport {
    static let markdownContentTypes: [UTType] = {
        var contentTypes: [UTType] = []

        if let markdownType = UTType(filenameExtension: "md") {
            contentTypes.append(markdownType)
        }

        contentTypes.append(.plainText)
        return contentTypes
    }()

    static let feastListsFetchRequest: NSFetchRequest<FeastList> = {
        let request = FeastList.fetchRequest()
        request.sortDescriptors = [
            NSSortDescriptor(key: "createdAt", ascending: true),
            NSSortDescriptor(key: "name", ascending: true)
        ]
        return request
    }()

    static func trimmed(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func readText(from fileURL: URL) throws -> String {
        let accessedSecurityScope = fileURL.startAccessingSecurityScopedResource()
        defer {
            if accessedSecurityScope {
                fileURL.stopAccessingSecurityScopedResource()
            }
        }

        let data = try Data(contentsOf: fileURL)

        if let string = String(data: data, encoding: .utf8) {
            return string
        }

        if let string = String(data: data, encoding: .unicode) {
            return string
        }

        return String(decoding: data, as: UTF8.self)
    }

    static func feastList(
        matching uriString: String?,
        in feastLists: FetchedResults<FeastList>
    ) -> FeastList? {
        guard let uriString else {
            return nil
        }

        return feastLists.first(where: { $0.objectURIString == uriString })
    }

    static func cityMetadata(for feastList: FeastList) -> String {
        let savedCountLabel = "\(feastList.savedPlaceCount) saved"
        let neighborhoodCount = feastList.neighborhoodSections.count

        guard neighborhoodCount > 0 else {
            return savedCountLabel
        }

        let neighborhoodLabel = neighborhoodCount == 1 ? "1 neighborhood" : "\(neighborhoodCount) neighborhoods"
        return "\(savedCountLabel) • \(neighborhoodLabel)"
    }
}

#Preview {
    FeastPreviewContainer {
        NavigationStack {
            NotesImportFlowView()
        }
    }
}

#Preview("Review Import") {
    let services = AppServices.preview
    let previewCity = services.repository.fetchPreviewFeastList(named: "NYC")

    return FeastPreviewContainer(services: services) {
        NavigationStack {
            NotesImportReviewView(
                destination: NotesImportReviewDestination(
                    cityURIString: previewCity.objectURIString,
                    reviewState: .previewSample
                ),
                onDone: {},
                onViewImportedCity: { _ in }
            )
        }
    }
}
