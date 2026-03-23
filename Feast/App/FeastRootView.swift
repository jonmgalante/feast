import SwiftUI

struct FeastRootView: View {
    let services: AppServices

    var body: some View {
        ZStack {
            FeastTheme.Colors.appBackground
                .ignoresSafeArea()

            TabView {
                NavigationStack {
                    ListsRootView()
                }
                .tabItem {
                    Label("Lists", systemImage: "text.badge.plus")
                }

                NavigationStack {
                    MapRootView()
                }
                .tabItem {
                    Label("Map", systemImage: "map")
                }
            }
            .tint(FeastTheme.Colors.primaryAccent)
        }
        .environment(\.managedObjectContext, services.persistenceController.viewContext)
        .environment(\.persistenceController, services.persistenceController)
        .environment(\.applePlacesService, services.applePlacesService)
    }
}

#Preview {
    FeastPreviewContainer {
        FeastRootView(services: .preview)
    }
}
