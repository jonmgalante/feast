import CloudKit
import MessageUI
import SwiftUI
import UIKit
import os

struct FeastListSharingSheet: View {
    private static let logger = Logger(subsystem: "com.jongalante.Feast", category: "Sharing")

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
    @State private var activeDeliveryPresentation: InviteDeliveryPresentation?
    @State private var activeAlert: FeastListSharingAlert?

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
                        subtitle: "Cities stay private and invite-only in Feast"
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
        .sheet(item: $activeDeliveryPresentation) { presentation in
            switch presentation.kind {
            case .messages:
                MessageInviteComposeSheet(draft: presentation.draft)
            case .mail:
                MailInviteComposeSheet(draft: presentation.draft)
            case .share:
                InviteLinkShareSheet(draft: presentation.draft)
            }
        }
        .alert(item: $activeAlert) { alert in
            switch alert {
            case let .error(errorAlert):
                Alert(
                    title: Text(errorAlert.title),
                    message: Text(errorAlert.message),
                    dismissButton: .default(Text("OK"))
                )
            case let .manualFallback(fallback):
                Alert(
                    title: Text("Invite Created"),
                    message: Text(fallback.message),
                    primaryButton: .default(Text("Open Share Sheet")) {
                        activeDeliveryPresentation = InviteDeliveryPresentation(
                            kind: .share,
                            draft: fallback.draft
                        )
                    },
                    secondaryButton: .cancel(Text("Not Now"))
                )
            }
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
                let delivery = try await persistenceController.inviteParticipant(
                    matching: lookupValue,
                    to: preparedShare
                )
                inviteRecipient = ""
                onDidSaveShare()
                beginDelivery(using: delivery)
            } catch {
                activeAlert = .error(
                    FeastListSharingErrorAlert(
                        title: alertTitle(for: error),
                        message: error.localizedDescription
                    )
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
        activeAlert = .error(
            FeastListSharingErrorAlert(
                title: alertTitle(for: error),
                message: error.localizedDescription
            )
        )
    }

    private func beginDelivery(using delivery: PrivateShareInvitationDelivery) {
        let draft = InviteDeliveryDraft(
            feastListName: preparedShare.feastListName,
            delivery: delivery
        )

        switch delivery.contact {
        case .phoneNumber:
            if MFMessageComposeViewController.canSendText() {
                Self.logger.log(
                    "Using direct text invite delivery for city \(preparedShare.feastListName, privacy: .public)."
                )
                inviteResultMessage = "Invite created. Finish sending it in Messages."
                activeDeliveryPresentation = InviteDeliveryPresentation(
                    kind: .messages,
                    draft: draft
                )
            } else {
                presentFallbackDelivery(
                    draft,
                    unavailableReason: "Messages isn't available here."
                )
            }
        case .emailAddress:
            if MFMailComposeViewController.canSendMail() {
                Self.logger.log(
                    "Using direct mail invite delivery for city \(preparedShare.feastListName, privacy: .public)."
                )
                inviteResultMessage = "Invite created. Finish sending it in Mail."
                activeDeliveryPresentation = InviteDeliveryPresentation(
                    kind: .mail,
                    draft: draft
                )
            } else {
                presentFallbackDelivery(
                    draft,
                    unavailableReason: "Mail isn't available here."
                )
            }
        }
    }

    private func presentFallbackDelivery(
        _ draft: InviteDeliveryDraft,
        unavailableReason: String
    ) {
        let fallbackMessage = "Invite created. \(unavailableReason) Send it manually from the share sheet."
        Self.logger.log(
            "Using generic share-sheet fallback for city \(preparedShare.feastListName, privacy: .public). Reason: \(unavailableReason, privacy: .public)"
        )
        inviteResultMessage = fallbackMessage
        activeAlert = .manualFallback(
            ManualInviteFallback(
                draft: draft,
                message: fallbackMessage
            )
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
        case .missingShareURL:
            return "Couldn't Prepare Invite Link"
        case .noCloudKitAccount, .restrictedCloudKitAccount, .cloudKitTemporarilyUnavailable:
            return "iCloud Sharing Unavailable"
        case .unavailable, .missingCloudKitContainer, .missingSharedPersistentStore, .missingPersistentStore, .failedToPrepareShare:
            return "Couldn't Update Sharing"
        }
    }
}

private enum FeastListSharingAlert: Identifiable {
    case error(FeastListSharingErrorAlert)
    case manualFallback(ManualInviteFallback)

    var id: UUID {
        switch self {
        case let .error(errorAlert):
            return errorAlert.id
        case let .manualFallback(fallback):
            return fallback.id
        }
    }
}

private struct FeastListSharingErrorAlert {
    let id = UUID()
    let title: String
    let message: String
}

private struct ManualInviteFallback {
    let id = UUID()
    let draft: InviteDeliveryDraft
    let message: String
}

private struct InviteDeliveryDraft {
    let feastListName: String
    let delivery: PrivateShareInvitationDelivery

    var messageBody: String {
        "I'm inviting you to collaborate on \(feastListName) in Feast. Open this private invite on your iPhone: \(delivery.shareURL.absoluteString)"
    }

    var mailSubject: String {
        "Feast invite: \(feastListName)"
    }
}

private struct InviteDeliveryPresentation: Identifiable {
    enum Kind {
        case messages
        case mail
        case share
    }

    let id = UUID()
    let kind: Kind
    let draft: InviteDeliveryDraft
}

private struct MessageInviteComposeSheet: UIViewControllerRepresentable {
    @Environment(\.dismiss) private var dismiss

    let draft: InviteDeliveryDraft

    func makeCoordinator() -> Coordinator {
        Coordinator {
            dismiss()
        }
    }

    func makeUIViewController(context: Context) -> MFMessageComposeViewController {
        let controller = MFMessageComposeViewController()
        controller.recipients = [draft.delivery.contact.value]
        controller.body = draft.messageBody
        controller.messageComposeDelegate = context.coordinator
        return controller
    }

    func updateUIViewController(_ uiViewController: MFMessageComposeViewController, context: Context) { }
}

private extension MessageInviteComposeSheet {
    final class Coordinator: NSObject, MFMessageComposeViewControllerDelegate {
        private let onDismiss: () -> Void

        init(onDismiss: @escaping () -> Void) {
            self.onDismiss = onDismiss
        }

        func messageComposeViewController(
            _ controller: MFMessageComposeViewController,
            didFinishWith result: MessageComposeResult
        ) {
            onDismiss()
        }
    }
}

private struct MailInviteComposeSheet: UIViewControllerRepresentable {
    @Environment(\.dismiss) private var dismiss

    let draft: InviteDeliveryDraft

    func makeCoordinator() -> Coordinator {
        Coordinator {
            dismiss()
        }
    }

    func makeUIViewController(context: Context) -> MFMailComposeViewController {
        let controller = MFMailComposeViewController()
        controller.setToRecipients([draft.delivery.contact.value])
        controller.setSubject(draft.mailSubject)
        controller.setMessageBody(draft.messageBody, isHTML: false)
        controller.mailComposeDelegate = context.coordinator
        return controller
    }

    func updateUIViewController(_ uiViewController: MFMailComposeViewController, context: Context) { }
}

private extension MailInviteComposeSheet {
    final class Coordinator: NSObject, MFMailComposeViewControllerDelegate {
        private let onDismiss: () -> Void

        init(onDismiss: @escaping () -> Void) {
            self.onDismiss = onDismiss
        }

        func mailComposeController(
            _ controller: MFMailComposeViewController,
            didFinishWith result: MFMailComposeResult,
            error: Error?
        ) {
            onDismiss()
        }
    }
}

private struct InviteLinkShareSheet: UIViewControllerRepresentable {
    @Environment(\.dismiss) private var dismiss

    let draft: InviteDeliveryDraft

    func makeUIViewController(context: Context) -> UIActivityViewController {
        let controller = UIActivityViewController(
            activityItems: [draft.messageBody, draft.delivery.shareURL],
            applicationActivities: nil
        )
        controller.completionWithItemsHandler = { _, _, _, _ in
            dismiss()
        }
        return controller
    }

    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) { }
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
