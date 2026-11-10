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

    var body: some View {
        List {
            Section {
                Button("From a Feast export file", systemImage: "doc") { choosingFile = true }
                Text("Choose a Feast JSON export, up to 32 MB. Your library will not change until you review it and restore.")
                    .font(.footnote).foregroundStyle(FeastTheme.Colors.secondaryText)
            }
            if isReading {
                Section { ProgressView("Reading export…") }
            }
            if let archive {
                Section("Export preview") {
                    LabeledContent("Exported", value: archive.exportedAt.formatted(date: .abbreviated, time: .shortened))
                    LabeledContent("Cities", value: String(archive.cities.count))
                    LabeledContent("Neighborhoods", value: String(archive.neighborhoods.count))
                    LabeledContent("Places", value: String(archive.places.count))
                    LabeledContent("Format version", value: String(archive.version))
                    if archive.places.contains(where: { $0.cityID == nil }) {
                        LabeledContent("Places without a city", value: String(archive.places.filter { $0.cityID == nil }.count))
                    }
                    if archive.neighborhoods.contains(where: { $0.cityID == nil }) {
                        LabeledContent("Neighborhoods without a city", value: String(archive.neighborhoods.filter { $0.cityID == nil }.count))
                    }
                    if archive.places.contains(where: { $0.cityID == nil }) || archive.neighborhoods.contains(where: { $0.cityID == nil }) {
                        Text("Records without a city will be retained, but may not appear in city browsing. Keep the original export.")
                            .font(.footnote).foregroundStyle(FeastTheme.Colors.secondaryText)
                    }
                    if archive.neighborhoods.contains(where: { $0.parentID != nil }) {
                        Text("This file has legacy nested neighborhoods. Their raw hierarchy will be retained and shown as flat neighborhood paths in city browsing.")
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
                    Text("Importing the same snapshot again will not add another copy while its restored records remain. Existing cities and places will not be replaced, merged, or deleted.")
                }
            }
            Section("Before restoring") {
                Text("Restored cities are independent private copies with new identifiers. Sharing information covers only participants visible when exported and is for reference only: owners, invitations, and permissions are not restored.")
                Text("An export reflects the data available on its device, not necessarily the latest iCloud data. Shared or unsynced changes may be missing.")
                Text("Only the saved library is included, not Ask Feast conversations or app settings. Export files contain private notes and are not password-encrypted.")
            }
            .font(.footnote)
            .foregroundStyle(FeastTheme.Colors.secondaryText)
        }
        .feastScrollableChrome()
        .listStyle(.insetGrouped)
        .navigationTitle("Import library")
        .navigationBarTitleDisplayMode(.inline)
        .disabled(isRestoring)
        .interactiveDismissDisabled(isRestoring)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Close") { cancelPreview(); dismiss() }.disabled(isRestoring)
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
            Button("Done") { completionMessage = nil; dismiss() }
        } message: { Text(completionMessage ?? "") }
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
