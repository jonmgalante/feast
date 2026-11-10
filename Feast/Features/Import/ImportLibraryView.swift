import SwiftUI

/// A source chooser only; each existing import flow owns its review and save steps.
struct ImportLibraryView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var path: [Source] = []

    let onViewImportedCity: ((String) -> Void)?

    private enum Source: Hashable { case notes, backup }

    var body: some View {
        NavigationStack(path: $path) {
            List {
                Section {
                    NavigationLink(value: Source.notes) {
                        NotesImportMethodRow(title: "From Notes", systemName: "doc.on.clipboard")
                    }
                    NavigationLink(value: Source.backup) {
                        NotesImportMethodRow(title: "From Feast Backup", systemName: "doc")
                    }
                }
                .feastSectionSurface()
            }
            .feastScrollableChrome()
            .listStyle(.insetGrouped)
            .navigationTitle("Import Library")
            .navigationBarTitleDisplayMode(.inline)
            .navigationDestination(for: Source.self) { source in
                switch source {
                case .notes:
                    NotesImportFlowView(onViewImportedCity: onViewImportedCity, onClose: closeFlow)
                case .backup:
                    LibraryImportFlowView(onClose: closeFlow)
                }
            }
            .toolbar {
                // Do not leave a parent Close action available during a child's restore.
                if path.isEmpty {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Close", action: closeFlow)
                    }
                }
            }
        }
    }

    private func closeFlow() { dismiss() }
}
