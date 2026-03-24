import Foundation

struct AppServices {
    let persistenceController: PersistenceController
    let repository: FeastRepository
    let applePlacesService: ApplePlacesService

    static let live: AppServices = {
        let persistenceController = PersistenceController.shared
        let repository = FeastRepository(
            context: persistenceController.viewContext,
            persistenceController: persistenceController
        )
        do {
            try repository.seedIfNeeded(mode: .defaultListsOnly)
            try repository.migrateToCityNeighborhoodModelIfNeeded()
        } catch {
            assertionFailure("Failed to initialize Feast data: \(error.localizedDescription)")
        }
        return AppServices(
            persistenceController: persistenceController,
            repository: repository,
            applePlacesService: ApplePlacesService()
        )
    }()

    static let preview: AppServices = {
        let persistenceController = PersistenceController.preview
        let repository = FeastRepository(
            context: persistenceController.viewContext,
            persistenceController: persistenceController
        )
        do {
            try repository.seedIfNeeded(mode: .previewDemoContent)
            try repository.migrateToCityNeighborhoodModelIfNeeded()
        } catch {
            assertionFailure("Failed to initialize Feast preview data: \(error.localizedDescription)")
        }
        return AppServices(
            persistenceController: persistenceController,
            repository: repository,
            applePlacesService: .preview
        )
    }()
}
