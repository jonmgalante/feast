import CloudKit
import SwiftUI
import UIKit
import os

final class FeastAppDelegate: NSObject, UIApplicationDelegate {
    static var persistenceController: PersistenceController?
    private static let logger = Logger(subsystem: "com.jongalante.Feast", category: "Sharing")

    func application(
        _ application: UIApplication,
        configurationForConnecting connectingSceneSession: UISceneSession,
        options: UIScene.ConnectionOptions
    ) -> UISceneConfiguration {
        let configuration = UISceneConfiguration(
            name: nil,
            sessionRole: connectingSceneSession.role
        )
        configuration.delegateClass = FeastSceneDelegate.self
        return configuration
    }

    static func acceptCloudKitShare(_ cloudKitShareMetadata: CKShare.Metadata) {
        guard let persistenceController = persistenceController else {
            return
        }

        Task { @MainActor in
            do {
                try await persistenceController.acceptShareInvitations(from: [cloudKitShareMetadata])
            } catch {
                logger.error("Failed to accept CloudKit share invitation. Error: \(error.localizedDescription, privacy: .public)")
            }
        }
    }
}

final class FeastSceneDelegate: NSObject, UIWindowSceneDelegate {
    func scene(
        _ scene: UIScene,
        willConnectTo session: UISceneSession,
        options connectionOptions: UIScene.ConnectionOptions
    ) {
        if let cloudKitShareMetadata = connectionOptions.cloudKitShareMetadata {
            FeastAppDelegate.acceptCloudKitShare(cloudKitShareMetadata)
        }
    }

    func windowScene(
        _ windowScene: UIWindowScene,
        userDidAcceptCloudKitShareWith cloudKitShareMetadata: CKShare.Metadata
    ) {
        FeastAppDelegate.acceptCloudKitShare(cloudKitShareMetadata)
    }
}

@main
struct FeastApp: App {
    @UIApplicationDelegateAdaptor(FeastAppDelegate.self) private var appDelegate
    private let services: AppServices

    init() {
        let services = AppServices.live
        self.services = services
        FeastAppDelegate.persistenceController = services.persistenceController
    }

    var body: some Scene {
        WindowGroup {
            FeastRootView(services: services)
        }
    }
}
