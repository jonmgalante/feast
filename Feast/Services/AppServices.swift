import Foundation
import CoreData

struct AppServices {
    let persistenceController: PersistenceController
    let repository: FeastRepository
    let applePlacesService: ApplePlacesService
    var startupError: String? = nil

    static let live: AppServices = {
        let persistenceController = PersistenceController.shared
        let repository = FeastRepository(
            context: persistenceController.viewContext,
            persistenceController: persistenceController
        )
        var approvedSavedConfiguration = ProcessInfo.processInfo.arguments.contains("-feastHostedSavedPlaces")
#if DEBUG && targetEnvironment(simulator)
        approvedSavedConfiguration = AskHostedSimulator.savedPlaces
#endif
        var startupError: String?
        if let storeLoadError = persistenceController.storeLoadError {
            startupError = storeLoadError
        } else if case .localFallback = persistenceController.storeMode {
            startupError = "Feast couldn't open all iCloud stores. Your shared cities may be unavailable. Close Feast and try again."
        } else if approvedSavedConfiguration {
            // This read-only metadata rollout must not transform an existing collection.
            // Store URLs, CloudKit scopes, model and ordinary startup behavior stay unchanged.
        } else {
            let migrationContext = NSManagedObjectContext(concurrencyType: .mainQueueConcurrencyType)
            migrationContext.persistentStoreCoordinator = persistenceController.container.persistentStoreCoordinator
            do {
                try FeastRepository(context: migrationContext).runStartupMigrations()
            } catch {
                startupError = "Feast couldn't finish preparing your saved collection. No pending migration edits were kept. Close Feast and try again. \(error.localizedDescription)"
            }
        }
        return AppServices(
            persistenceController: persistenceController,
            repository: repository,
            applePlacesService: ApplePlacesService(),
            startupError: startupError
        )
    }()

    static let preview: AppServices = {
        let persistenceController = PersistenceController.preview
        let repository = FeastRepository(
            context: persistenceController.viewContext,
            persistenceController: persistenceController
        )
        return AppServices(
            persistenceController: persistenceController,
            repository: repository,
            applePlacesService: .preview
        )
    }()
}
