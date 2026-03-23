import SwiftUI

struct FeastPreviewContainer<Content: View>: View {
    private let services: AppServices
    private let content: Content

    init(
        services: AppServices = .preview,
        @ViewBuilder content: @escaping () -> Content
    ) {
        self.services = services
        self.content = content()
    }

    var body: some View {
        content
            .environment(\.managedObjectContext, services.persistenceController.viewContext)
            .environment(\.persistenceController, services.persistenceController)
            .environment(\.applePlacesService, services.applePlacesService)
            .tint(FeastTheme.Colors.primaryAccent)
            .background(FeastTheme.Colors.appBackground)
    }
}
