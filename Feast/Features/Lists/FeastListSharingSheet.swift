import CloudKit
import SwiftUI
import UIKit

struct FeastListSharingSheet: View {
    @Environment(\.dismiss) private var dismiss

    let preparedShare: PreparedFeastListShare
    let persistenceController: PersistenceController
    let onDidSaveShare: () -> Void
    let onDidStopSharing: () -> Void
    let onError: (Error) -> Void

    @State private var inviteRecipient = ""
    @State private var isInviting = false
    @State private var inviteResultMessage: String?
    @State private var showingSystemSharingSheet = false
    @State private var alertState: FeastListSharingAlertState?

    private var invitedEditorCount: Int {
        preparedShare.share.participants.filter { $0.role != .owner }.count
    }

    private var invitedEditorSummary: String {
        switch invitedEditorCount {
        case 0:
            return "No editors invited yet."
        case 1:
            return "1 editor invited."
        default:
            return "\(invitedEditorCount) editors invited."
        }
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    FeastFormGroup {
                        VStack(alignment: .leading, spacing: FeastTheme.Spacing.small) {
                            Text("Private, Invite-Only")
                                .font(FeastTheme.Typography.formTitle)
                                .foregroundStyle(FeastTheme.Colors.primaryText)

                            Text("Invite people directly by Apple Account email or phone number. Editors can add and edit city content. Only the owner manages sharing.")
                                .font(FeastTheme.Typography.supporting)
                                .foregroundStyle(FeastTheme.Colors.secondaryText)

                            Text(invitedEditorSummary)
                                .font(FeastTheme.Typography.rowUtility)
                                .foregroundStyle(FeastTheme.Colors.tertiaryText)
                        }
                    }
                } header: {
                    FeastFormSectionHeader(
                        title: "Sharing",
                        subtitle: "Cities stay private and invite-only in Feast v1"
                    )
                }

                Section {
                    FeastFormGroup {
                        VStack(alignment: .leading, spacing: FeastTheme.Spacing.large) {
                            FeastFormField(
                                title: "Invite Person",
                                helper: "Use the Apple Account email address or phone number for the person you want to add as an editor."
                            ) {
                                TextField("Email address or phone number", text: $inviteRecipient)
                                    .textInputAutocapitalization(.never)
                                    .autocorrectionDisabled()
                                    .submitLabel(.done)
                                    .onSubmit(invitePerson)
                                    .feastFieldSurface(minHeight: 52)
                            }

                            Button(action: invitePerson) {
                                Group {
                                    if isInviting {
                                        HStack(spacing: FeastTheme.Spacing.small) {
                                            ProgressView()
                                            Text("Inviting")
                                        }
                                        .frame(maxWidth: .infinity)
                                    } else {
                                        Text("Invite Person")
                                            .frame(maxWidth: .infinity)
                                    }
                                }
                            }
                            .buttonStyle(FeastProminentButtonStyle())
                            .disabled(isInviting || trimmedInviteRecipient.isEmpty)

                            if let inviteResultMessage {
                                Text(inviteResultMessage)
                                    .font(FeastTheme.Typography.formHelper)
                                    .foregroundStyle(FeastTheme.Colors.tertiaryText)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                    }
                } header: {
                    FeastFormSectionHeader(
                        title: "Invite",
                        subtitle: "Direct person-to-person invite for private sharing"
                    )
                }

                Section {
                    FeastFormGroup {
                        VStack(alignment: .leading, spacing: FeastTheme.Spacing.small) {
                            Button("Manage in Apple Sharing") {
                                showingSystemSharingSheet = true
                            }
                            .buttonStyle(FeastInlineActionButtonStyle())

                            Text("Use the standard Apple sharing sheet to review participants or stop sharing. Feast now uses direct invites above as the primary path.")
                                .font(FeastTheme.Typography.formHelper)
                                .foregroundStyle(FeastTheme.Colors.secondaryText)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                } header: {
                    FeastFormSectionHeader(
                        title: "Manage",
                        subtitle: "Keep the standard Apple sharing UI available where it helps"
                    )
                }
            }
            .feastScrollableChrome()
            .listStyle(.insetGrouped)
            .scrollDismissesKeyboard(.interactively)
            .navigationTitle(preparedShare.feastListName)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") {
                        dismiss()
                    }
                }
            }
        }
        .sheet(isPresented: $showingSystemSharingSheet) {
            AppleCloudSharingSheet(
                preparedShare: preparedShare,
                persistenceController: persistenceController,
                onDidSaveShare: onDidSaveShare,
                onDidStopSharing: handleDidStopSharing,
                onError: handleSystemSharingError
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

    private var trimmedInviteRecipient: String {
        inviteRecipient.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func invitePerson() {
        let lookupValue = trimmedInviteRecipient
        guard !lookupValue.isEmpty else {
            return
        }

        inviteResultMessage = nil
        isInviting = true

        Task { @MainActor in
            defer {
                isInviting = false
            }

            do {
                try await persistenceController.inviteParticipant(
                    matching: lookupValue,
                    to: preparedShare
                )
                inviteRecipient = ""
                inviteResultMessage = "Added as an editor to this city share."
                onDidSaveShare()
            } catch {
                alertState = FeastListSharingAlertState(
                    title: alertTitle(for: error),
                    message: error.localizedDescription
                )
            }
        }
    }

    private func handleDidStopSharing() {
        showingSystemSharingSheet = false
        onDidStopSharing()
        dismiss()
    }

    private func handleSystemSharingError(_ error: Error) {
        onError(error)
        alertState = FeastListSharingAlertState(
            title: alertTitle(for: error),
            message: error.localizedDescription
        )
    }

    private func alertTitle(for error: Error) -> String {
        guard let sharingError = error as? PersistenceController.SharingError else {
            return "Couldn't Update Sharing"
        }

        switch sharingError {
        case .invalidInviteRecipient:
            return "Enter an Email or Phone Number"
        case .shareParticipantNotFound:
            return "Couldn't Find iCloud Participant"
        case .shareParticipantAlreadyAdded:
            return "Already Invited"
        case .noCloudKitAccount, .restrictedCloudKitAccount, .cloudKitTemporarilyUnavailable:
            return "iCloud Sharing Unavailable"
        case .unavailable, .missingCloudKitContainer, .missingSharedPersistentStore, .missingPersistentStore, .failedToPrepareShare:
            return "Couldn't Update Sharing"
        }
    }
}

private struct FeastListSharingAlertState: Identifiable {
    let id = UUID()
    let title: String
    let message: String
}

private struct AppleCloudSharingSheet: UIViewControllerRepresentable {
    let preparedShare: PreparedFeastListShare
    let persistenceController: PersistenceController
    let onDidSaveShare: () -> Void
    let onDidStopSharing: () -> Void
    let onError: (Error) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(
            preparedShare: preparedShare,
            persistenceController: persistenceController,
            onDidSaveShare: onDidSaveShare,
            onDidStopSharing: onDidStopSharing,
            onError: onError
        )
    }

    func makeUIViewController(context: Context) -> UICloudSharingController {
        let controller = UICloudSharingController(
            share: preparedShare.share,
            container: preparedShare.container
        )
        controller.availablePermissions = [.allowPrivate, .allowReadWrite]
        controller.delegate = context.coordinator
        return controller
    }

    func updateUIViewController(_ uiViewController: UICloudSharingController, context: Context) { }
}

private extension AppleCloudSharingSheet {
    final class Coordinator: NSObject, UICloudSharingControllerDelegate {
        private let preparedShare: PreparedFeastListShare
        private let persistenceController: PersistenceController
        private let onDidSaveShare: () -> Void
        private let onDidStopSharing: () -> Void
        private let onError: (Error) -> Void

        init(
            preparedShare: PreparedFeastListShare,
            persistenceController: PersistenceController,
            onDidSaveShare: @escaping () -> Void,
            onDidStopSharing: @escaping () -> Void,
            onError: @escaping (Error) -> Void
        ) {
            self.preparedShare = preparedShare
            self.persistenceController = persistenceController
            self.onDidSaveShare = onDidSaveShare
            self.onDidStopSharing = onDidStopSharing
            self.onError = onError
        }

        func itemTitle(for csc: UICloudSharingController) -> String? {
            preparedShare.feastListName
        }

        func cloudSharingController(
            _ csc: UICloudSharingController,
            failedToSaveShareWithError error: Error
        ) {
            onError(error)
        }

        func cloudSharingControllerDidSaveShare(_ csc: UICloudSharingController) {
            guard let share = csc.share else {
                onDidSaveShare()
                return
            }

            Task { @MainActor in
                do {
                    try await persistenceController.persistUpdatedShare(
                        share,
                        forManagedObjectWith: preparedShare.feastListObjectID
                    )
                    onDidSaveShare()
                } catch {
                    onError(error)
                }
            }
        }

        func cloudSharingControllerDidStopSharing(_ csc: UICloudSharingController) {
            onDidStopSharing()
        }
    }
}
