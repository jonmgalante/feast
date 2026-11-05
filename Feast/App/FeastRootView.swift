import SwiftUI
import CoreData

struct FeastRootView: View {
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.colorScheme) private var colorScheme
    let services: AppServices
    @StateObject private var ask = AskFeastTabState()
    @StateObject private var browse: SavedPlaceBrowseState

    init(services: AppServices) {
        self.services = services
        let state = SavedPlaceBrowseState()

        _browse = StateObject(wrappedValue: state)
    }

    var body: some View {
        ZStack {
            FeastTheme.Colors.appBackground
                .ignoresSafeArea()

            if let startupError = services.startupError {
                ContentUnavailableView("Collection Unavailable", systemImage: "exclamationmark.triangle", description: Text(startupError))
            } else {
                TabView(selection: $browse.selectedTab) {
                    NavigationStack(path: $browse.citiesPath) {
                        ListsRootView()
                            .navigationDestination(for: SavedPlaceBrowseRoute.self) { route in
                                browseDestination(route)
                            }
                    }
                    .tint(FeastTheme.Colors.secondaryAction)
                    .tabItem {
                        Label { Text("Cities") } icon: {
                            Image(systemName: "building.2")
                                .environment(\.symbolVariants, .none)
                                .symbolRenderingMode(.monochrome)
                                .font(.system(size: 25, weight: .medium))
                                .accessibilityHidden(true)
                        }
                    }
                    .tag(0)

                    NavigationStack {
                        MapRootView()
                    }
                    .tint(FeastTheme.Colors.secondaryAction)
                    .tabItem {
                        Label { Text("Map") } icon: {
                            Image(systemName: "map")
                                .environment(\.symbolVariants, .none)
                                .symbolRenderingMode(.monochrome)
                                .font(.system(size: 25, weight: .medium))
                                .accessibilityHidden(true)
                        }
                    }
                    .tag(1)
                    AskFeastTab(state: ask, realContext: services.persistenceController.viewContext)
                        .tabItem {
                            Label { Text("Ask Feast") } icon: { Image("AskFeastTab").renderingMode(.template).accessibilityHidden(true) }
                        }
                        .tag(2)
                }
                .tint(FeastTheme.TabBar.selectedTint)
                .toolbarColorScheme(colorScheme, for: .tabBar)
            }
        }
        .onChange(of: scenePhase) { _, phase in if phase == .background { MapPlaceLookup.shared.clear() } }
        .onChange(of: browse.selectedTab) { _, tab in ask.selectionChanged(to: tab) }
        .environmentObject(browse)
        .onChange(of: browse.filters.selectedListURIString) { _, _ in browse.scopeDidChange() }
        .onChange(of: browse.citiesPath) { old, _ in browse.pathDidChange(from: old) }
        .environment(\.managedObjectContext, services.persistenceController.viewContext)
        .environment(\.persistenceController, services.persistenceController)
        .environment(\.applePlacesService, services.applePlacesService)
    }
    @ViewBuilder private func browseDestination(_ route: SavedPlaceBrowseRoute) -> some View {
        let uri: String = { switch route { case .city(let value), .place(let value): return value } }()
        let context = services.persistenceController.viewContext
        if let url = URL(string: uri),
           let id = context.persistentStoreCoordinator?.managedObjectID(forURIRepresentation: url),
           let object = try? context.existingObject(with: id), !object.isDeleted {
            switch route {
            case .city:
                if let city = object as? FeastList { FeastListDetailView(feastList: city) }
            case .place:
                if let place = object as? SavedPlace { SavedPlaceDetailView(savedPlace: place) }
            }
        } else {
            ContentUnavailableView("Unavailable", systemImage: "exclamationmark.triangle", description: Text("This saved item is no longer available."))
        }
    }

}

#Preview {
    FeastPreviewContainer {
        FeastRootView(services: .preview)
    }
}
