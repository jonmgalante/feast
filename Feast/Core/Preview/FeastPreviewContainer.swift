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
        FeastTheme.applyAppearance()
    }

    var body: some View {
        content
            .environment(\.managedObjectContext, services.persistenceController.viewContext)
            .environment(\.persistenceController, services.persistenceController)
            .environment(\.applePlacesService, services.applePlacesService)
            .tint(FeastTheme.Colors.secondaryAction)
            .background(FeastTheme.Colors.appBackground)
    }
}
