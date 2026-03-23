import SwiftUI
import UIKit

struct FeastListSharingSheet: UIViewControllerRepresentable {
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

extension FeastListSharingSheet {
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
