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
                .tint(FeastTheme.Colors.secondaryAction)
                .tabItem {
                    Label("Cities", systemImage: "building.2")
                }

                NavigationStack {
                    MapRootView()
                }
                .tint(FeastTheme.Colors.secondaryAction)
                .tabItem {
                    Label("Map", systemImage: "map")
                }
            }
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
