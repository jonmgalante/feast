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
        try? repository.seedIfNeeded(mode: .defaultListsOnly)
        return AppServices(
            persistenceController: persistenceController,
            repository: repository,
            applePlacesService: .live
        )
    }()

    static let preview: AppServices = {
        let persistenceController = PersistenceController.preview
        let repository = FeastRepository(
            context: persistenceController.viewContext,
            persistenceController: persistenceController
        )
        try? repository.seedIfNeeded(mode: .previewDemoContent)
        return AppServices(
            persistenceController: persistenceController,
            repository: repository,
            applePlacesService: .preview
        )
    }()
}
