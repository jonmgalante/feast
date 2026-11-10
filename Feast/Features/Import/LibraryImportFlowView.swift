import CoreData
import SwiftUI
import UniformTypeIdentifiers

/// Preview is read-only. Only the explicit restore action writes to the private store.
struct LibraryImportFlowView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.managedObjectContext) private var viewContext
    @Environment(\.persistenceController) private var persistenceController
    @State private var choosingFile = false
    @State private var archive: PlaceExport?
    @State private var isRestoring = false
    @State private var isReading = false
    @State private var previewRequestID = UUID()
    @State private var previewWorker: Task<PlaceExport, Error>?
    @State private var previewTask: Task<Void, Never>?
    @State private var errorMessage: String?
    @State private var completionMessage: String?

    private let onClose: (() -> Void)?

    init(onClose: (() -> Void)? = nil) { self.onClose = onClose }

    var body: some View {
        List {
            Section {
                Button { choosingFile = true } label: {
                    NotesImportMethodRow(title: "Choose Backup File", systemName: "doc")
                }
            } footer: {
                Text("Feast JSON files, up to 32 MB.")
            }
            .feastSectionSurface()
            if isReading {
                Section { ProgressView("Reading export…") }
            }
            if let archive {
                Section("Export preview") {
                    LabeledContent("Exported", value: archive.exportedAt.formatted(date: .abbreviated, time: .shortened))
                    LabeledContent("Cities", value: String(archive.cities.count))
                    LabeledContent("Neighborhoods", value: String(archive.neighborhoods.count))
                    LabeledContent("Places", value: String(archive.places.count))
                    if archive.places.contains(where: { $0.cityID == nil }) {
                        LabeledContent("Places without a city", value: String(archive.places.filter { $0.cityID == nil }.count))
                    }
                    if archive.neighborhoods.contains(where: { $0.cityID == nil }) {
                        LabeledContent("Neighborhoods without a city", value: String(archive.neighborhoods.filter { $0.cityID == nil }.count))
                    }
                    if archive.places.contains(where: { $0.cityID == nil }) || archive.neighborhoods.contains(where: { $0.cityID == nil }) {
                        Text("Records without a city stay saved but aren’t shown in city browsing.")
                            .font(.footnote).foregroundStyle(FeastTheme.Colors.secondaryText)
                    }
                    if archive.neighborhoods.contains(where: { $0.parentID != nil }) {
                        Text("Nested neighborhoods appear as flat paths; their saved hierarchy is unchanged.")
                            .font(.footnote).foregroundStyle(FeastTheme.Colors.secondaryText)
                    }
                }
                if !archive.cities.isEmpty {
                    Section("Cities in this file") {
                        ForEach(archive.cities.prefix(100), id: \.id) { city in
                            Text(city.name ?? "Unnamed city")
                                .lineLimit(3)
                        }
                        if archive.cities.count > 100 {
                            Text("And \(archive.cities.count - 100) more cities")
                        }
                    }
                }
                Section {
                    Button(action: restore) {
                        if isRestoring { ProgressView("Restoring…") }
                        else { Text("Restore private copies") }
                    }
                    .disabled(isReading || (archive.cities.isEmpty && archive.neighborhoods.isEmpty && archive.places.isEmpty))
                } footer: {
                    Text("Adds private copies without replacing your library. Sharing and invitations aren’t restored.")
                }
                Section {
                    DisclosureGroup("About this backup") {
                        LabeledContent("Format version", value: String(archive.version))
                        Text("This is the library saved on the export device. Unsynced changes may be missing.")
                        Text("Reimporting the same snapshot won’t add duplicates while its restored records remain.")
                        Text("Ask Feast chats and app settings aren’t included. Keep the original file: it contains private notes and isn’t password-encrypted.")
                    }
                }
                .font(.footnote)
                .foregroundStyle(FeastTheme.Colors.secondaryText)
            }
        }
        .feastScrollableChrome()
        .listStyle(.insetGrouped)
        .navigationTitle("Import Backup")
        .navigationBarTitleDisplayMode(.inline)
        .disabled(isRestoring)
        .interactiveDismissDisabled(isRestoring)
        .navigationBarBackButtonHidden(isRestoring)
        .toolbar {
            ToolbarItem(placement: onClose == nil ? .cancellationAction : .confirmationAction) {
                Button("Close", action: closeFlow).disabled(isRestoring)
            }
        }
        .onDisappear { cancelPreview() }
        .fileImporter(isPresented: $choosingFile, allowedContentTypes: [.json]) { result in
            switch result {
            case .success(let url): readPreview(from: url)
            case .failure(let error):
                guard !isUserCancellation(error) else { return }
                cancelPreview()
                archive = nil
                errorMessage = fileErrorMessage(error)
            }
        }
        .alert("Couldn't Import Library", isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })) {
            Button("OK") { errorMessage = nil }
        } message: { Text(errorMessage ?? "") }
        .alert("Library import", isPresented: Binding(get: { completionMessage != nil }, set: { if !$0 { completionMessage = nil } })) {
            Button("Done") { completionMessage = nil; closeFlow() }
        } message: { Text(completionMessage ?? "") }
    }

    private func closeFlow() {
        guard !isRestoring else { return }
        cancelPreview()
        if let onClose { onClose() } else { dismiss() }
    }

    private func cancelPreview() {
        previewRequestID = UUID()
        previewTask?.cancel()
        previewWorker?.cancel()
        previewTask = nil
        previewWorker = nil
        isReading = false
    }

    private func readPreview(from url: URL) {
        cancelPreview()
        errorMessage = nil
        let requestID = UUID()
        previewRequestID = requestID
        isReading = true
        let worker = Task.detached(priority: .userInitiated) {
            try Task.checkCancellation()
            let accessed = url.startAccessingSecurityScopedResource()
            defer { if accessed { url.stopAccessingSecurityScopedResource() } }
            let result = try PlaceImport.readFile(at: url)
            try Task.checkCancellation()
            return result
        }
        previewWorker = worker
        previewTask = Task { @MainActor in
            do {
                let result = try await worker.value
                guard !Task.isCancelled, previewRequestID == requestID else { return }
                archive = result
            } catch {
                guard !Task.isCancelled, previewRequestID == requestID else { return }
                if !(error is CancellationError) && !isUserCancellation(error) {
                    archive = nil
                    errorMessage = fileErrorMessage(error)
                }
            }
            guard previewRequestID == requestID else { return }
            isReading = false
            previewTask = nil
            previewWorker = nil
        }
    }

    private func isUserCancellation(_ error: Error) -> Bool {
        let nsError = error as NSError
        return nsError.domain == NSCocoaErrorDomain && nsError.code == NSUserCancelledError
    }

    private func fileErrorMessage(_ error: Error) -> String {
        (error as? PlaceExport.ExportError)?.errorDescription
            ?? "Feast couldn’t read this file. Choose a valid Feast JSON export that is available on this device. Nothing was imported."
    }

    private func restore() {
        guard let archive, !isRestoring, !isReading else { return }
        guard let persistence = persistenceController,
              let privateStore = persistence.privateCloudKitStore ?? persistence.localPersistentStore else {
            errorMessage = "The private library store is unavailable. Try again after Feast has finished loading. Nothing was imported."
            return
        }
        isRestoring = true
        Task { @MainActor in
            defer { isRestoring = false }
            do {
                switch try await PlaceImport.restoreInBackground(archive, into: viewContext, privateStore: privateStore) {
                case .restored:
                    completionMessage = "Restored private copies of \(archive.cities.count) cities, \(archive.neighborhoods.count) neighborhoods, and \(archive.places.count) places. Your existing library was left unchanged."
                case .alreadyImported:
                    completionMessage = "This saved-library snapshot was already imported. No duplicate copies were added."
                }
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }
}
