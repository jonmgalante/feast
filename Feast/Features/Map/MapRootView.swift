import CoreData
import MapKit
import SwiftUI

struct MapRootView: View {
    @Environment(\.managedObjectContext) private var viewContext
    @Environment(\.applePlacesService) private var applePlacesService

    @FetchRequest(
        sortDescriptors: [
            NSSortDescriptor(key: "createdAt", ascending: true),
            NSSortDescriptor(key: "name", ascending: true)
        ],
        animation: .default
    )
    private var feastLists: FetchedResults<FeastList>

    @FetchRequest(
        sortDescriptors: [
            NSSortDescriptor(key: "updatedAt", ascending: false),
            NSSortDescriptor(key: "displayNameSnapshot", ascending: true)
        ],
        animation: .default
    )
    private var savedPlaces: FetchedResults<SavedPlace>

    @SceneStorage("map.selectedFeastListURI") private var selectedFeastListURI = ""
    @State private var cameraPosition: MapCameraPosition = .automatic
    @State private var markerItems: [SavedPlaceMapMarker] = []
    @State private var selectedMarker: SavedPlaceMapMarker?
    @State private var isResolvingMarkers = false
    @State private var unresolvedPlaceCount = 0
    @State private var showingExploreSearch = false

    var body: some View {
        content
            .navigationTitle("Map")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        showingExploreSearch = true
                    } label: {
                        Label("Search Apple Maps", systemImage: "magnifyingglass")
                    }
                    .disabled(selectedFeastList == nil)
                }
            }
            .task(id: markerResolutionKey) {
                await resolveMarkers()
            }
            .navigationDestination(item: $selectedMarker) { marker in
                if let savedPlace = savedPlace(for: marker.savedPlaceObjectID) {
                    SavedPlaceDetailView(savedPlace: savedPlace)
                } else {
                    ContentUnavailableView(
                        "Place Unavailable",
                        systemImage: "mappin.slash",
                        description: Text("This saved place could not be loaded.")
                    )
                }
            }
            .sheet(isPresented: $showingExploreSearch) {
                NavigationStack {
                    if let selectedFeastList {
                        AddPlaceView(feastList: selectedFeastList)
                    } else {
                        ContentUnavailableView(
                            "No List Selected",
                            systemImage: "magnifyingglass",
                            description: Text("Choose a Feast list before searching Apple Maps.")
                        )
                        .navigationTitle("Search")
                        .navigationBarTitleDisplayMode(.inline)
                    }
                }
            }
    }

    private var content: some View {
        Group {
            if feastLists.isEmpty {
                ContentUnavailableView(
                    "No Lists Yet",
                    systemImage: "map",
                    description: Text("Create a Feast list to start mapping saved places.")
                )
            } else {
                VStack(spacing: 0) {
                    listSelectorHeader
                    mapContent
                }
                .background(FeastTheme.Colors.appBackground)
            }
        }
    }

    private var selectedFeastList: FeastList? {
        if let matchedList = feastLists.first(where: { uriString(for: $0) == selectedFeastListURI }) {
            return matchedList
        }

        return feastLists.first
    }

    private var selectedListSavedPlaces: [SavedPlace] {
        guard let selectedFeastList else {
            return []
        }

        return savedPlaces.filter { $0.feastList == selectedFeastList }
    }

    private var markerResolutionKey: String {
        let listKey = selectedFeastList.map(uriString(for:)) ?? "none"
        let placeKeys = selectedListSavedPlaces.map { place in
            let objectKey = place.objectID.uriRepresentation().absoluteString
            let updateKey = place.updatedAtValue.timeIntervalSinceReferenceDate
            return "\(objectKey)-\(updateKey)"
        }

        return ([listKey] + placeKeys).joined(separator: "|")
    }

    private var listSelectorHeader: some View {
        VStack(alignment: .leading, spacing: FeastTheme.Spacing.small) {
            Text("Viewing")
                .font(FeastTheme.Typography.caption.weight(.semibold))
                .foregroundStyle(FeastTheme.Colors.secondaryNeutral)

            Menu {
                ForEach(feastLists) { feastList in
                    Button(feastList.displayName) {
                        selectedFeastListURI = uriString(for: feastList)
                    }
                }
            } label: {
                HStack(spacing: FeastTheme.Spacing.small) {
                    Text(selectedFeastList?.displayName ?? "Select List")
                        .font(FeastTheme.Typography.body.weight(.semibold))
                        .foregroundStyle(FeastTheme.Colors.primaryText)

                    Spacer()

                    Image(systemName: "chevron.up.chevron.down")
                        .font(FeastTheme.Typography.caption.weight(.semibold))
                        .foregroundStyle(FeastTheme.Colors.secondaryNeutral)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, FeastTheme.Spacing.xSmall)
            }

            Text(listSummaryText)
                .font(FeastTheme.Typography.supporting)
                .foregroundStyle(FeastTheme.Colors.secondaryNeutral)
        }
        .padding(FeastTheme.Spacing.large)
        .background(FeastTheme.Colors.groupedSurface)
    }

    private var mapContent: some View {
        ZStack {
            Map(position: $cameraPosition, selection: $selectedMarker) {
                ForEach(markerItems) { marker in
                    Marker(marker.markerLabel, coordinate: marker.coordinate.clLocationCoordinate2D)
                        .tint(FeastTheme.Colors.primaryAccent)
                        .tag(marker)
                }
            }
            .mapStyle(.standard(elevation: .flat))

            if markerItems.isEmpty && !isResolvingMarkers {
                ContentUnavailableView {
                    Label("No Saved Places On This Map", systemImage: "mappin.and.ellipse")
                } description: {
                    Text(emptyStateText)
                } actions: {
                    if selectedFeastList != nil {
                        Button("Search Apple Maps") {
                            showingExploreSearch = true
                        }
                        .buttonStyle(.borderedProminent)
                    }
                }
                .padding(FeastTheme.Spacing.large)
            }

            if isResolvingMarkers {
                ProgressView()
                    .padding(FeastTheme.Spacing.large)
                    .background(.ultraThinMaterial)
                    .clipShape(RoundedRectangle(cornerRadius: FeastTheme.CornerRadius.medium, style: .continuous))
            }
        }
    }

    private var listSummaryText: String {
        let mappedCount = markerItems.count
        let savedCount = selectedListSavedPlaces.count

        if savedCount == 0 {
            return "Search Apple Maps and save places into this list to start building the map."
        }

        if unresolvedPlaceCount > 0 {
            return "\(mappedCount) of \(savedCount) saved places mapped"
        }

        if mappedCount == 0 {
            return "Saved places in this list will appear here once Apple Maps can resolve them."
        }

        return "\(mappedCount) saved places on the map"
    }

    private var emptyStateText: String {
        if selectedListSavedPlaces.isEmpty {
            return "Search Apple Maps and save places into \(selectedFeastList?.displayName ?? "this list") to see them on the map."
        }

        return "Feast could not resolve any saved places for this list in Apple Maps right now."
    }

    @MainActor
    private func resolveMarkers() async {
        if selectedFeastList == nil, let firstList = feastLists.first {
            selectedFeastListURI = uriString(for: firstList)
        }

        let places = selectedListSavedPlaces

        isResolvingMarkers = true
        defer {
            isResolvingMarkers = false
        }

        var resolvedMarkers: [SavedPlaceMapMarker] = []
        var unresolvedCount = 0

        for savedPlace in places {
            guard let applePlaceID = savedPlace.applePlaceIDValue else {
                unresolvedCount += 1
                continue
            }

            do {
                if let resolvedPlace = try await applePlacesService.resolvePlace(applePlaceID: applePlaceID),
                   let coordinate = resolvedPlace.coordinate {
                    resolvedMarkers.append(
                        SavedPlaceMapMarker(
                            savedPlaceObjectID: savedPlace.objectID,
                            displayName: resolvedPlace.displayName,
                            fallbackName: savedPlace.displayName,
                            coordinate: coordinate
                        )
                    )
                } else {
                    unresolvedCount += 1
                }
            } catch {
                unresolvedCount += 1
            }
        }

        markerItems = resolvedMarkers
        unresolvedPlaceCount = unresolvedCount
        updateCameraPosition(using: resolvedMarkers)
    }

    private func updateCameraPosition(using markers: [SavedPlaceMapMarker]) {
        guard !markers.isEmpty else {
            cameraPosition = .automatic
            return
        }

        let coordinates = markers.map(\.coordinate.clLocationCoordinate2D)
        cameraPosition = .region(regionFitting(coordinates: coordinates))
    }

    private func regionFitting(coordinates: [CLLocationCoordinate2D]) -> MKCoordinateRegion {
        guard let firstCoordinate = coordinates.first else {
            return MKCoordinateRegion()
        }

        guard coordinates.count > 1 else {
            return MKCoordinateRegion(
                center: firstCoordinate,
                span: MKCoordinateSpan(latitudeDelta: 0.08, longitudeDelta: 0.08)
            )
        }

        let latitudes = coordinates.map(\.latitude)
        let longitudes = coordinates.map(\.longitude)

        let minLatitude = latitudes.min() ?? firstCoordinate.latitude
        let maxLatitude = latitudes.max() ?? firstCoordinate.latitude
        let minLongitude = longitudes.min() ?? firstCoordinate.longitude
        let maxLongitude = longitudes.max() ?? firstCoordinate.longitude

        let latitudeDelta = max((maxLatitude - minLatitude) * 1.6, 0.08)
        let longitudeDelta = max((maxLongitude - minLongitude) * 1.6, 0.08)

        return MKCoordinateRegion(
            center: CLLocationCoordinate2D(
                latitude: (minLatitude + maxLatitude) / 2,
                longitude: (minLongitude + maxLongitude) / 2
            ),
            span: MKCoordinateSpan(
                latitudeDelta: latitudeDelta,
                longitudeDelta: longitudeDelta
            )
        )
    }

    private func savedPlace(for objectID: NSManagedObjectID) -> SavedPlace? {
        try? viewContext.existingObject(with: objectID) as? SavedPlace
    }

    private func uriString(for feastList: FeastList) -> String {
        feastList.objectID.uriRepresentation().absoluteString
    }
}

private struct SavedPlaceMapMarker: Identifiable, Hashable {
    let savedPlaceObjectID: NSManagedObjectID
    let displayName: String
    let fallbackName: String
    let coordinate: ApplePlaceCoordinate

    var id: NSManagedObjectID { savedPlaceObjectID }

    var markerLabel: String {
        displayName.isEmpty ? fallbackName : displayName
    }

    static func == (lhs: SavedPlaceMapMarker, rhs: SavedPlaceMapMarker) -> Bool {
        lhs.savedPlaceObjectID == rhs.savedPlaceObjectID
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(savedPlaceObjectID)
    }
}

#Preview {
    FeastPreviewContainer {
        NavigationStack {
            MapRootView()
        }
    }
}
