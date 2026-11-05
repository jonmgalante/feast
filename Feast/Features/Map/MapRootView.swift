import CoreData
import MapKit
import SwiftUI

struct MapRootView: View {
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.scenePhase) private var scenePhase
    @EnvironmentObject private var browse: SavedPlaceBrowseState
    @Environment(\.managedObjectContext) private var viewContext
    @Environment(\.persistenceController) private var persistenceController
    @Environment(\.applePlacesService) private var applePlacesService

    @FetchRequest(fetchRequest: Self.feastListsFetchRequest, animation: .default)
    private var feastLists: FetchedResults<FeastList>

    @FetchRequest(fetchRequest: Self.savedPlacesFetchRequest, animation: .default)
    private var savedPlaces: FetchedResults<SavedPlace>

    @State private var discoveryCityURI: String?
    @State private var presentedPlaceID: NSManagedObjectID?
    @State private var displayedScope: String?
    @StateObject private var nearby = NearbyLocationService()
    @State private var nearbyScope: String?
    @State private var cameraPosition: MapCameraPosition = .automatic
    @State private var markerLookup = MapPlaceLookup()
    @State private var markerGeneration = UUID()
    @State private var markerRetry = 0
    @State private var markerItems: [SavedPlaceMapMarker] = []
    @State private var selectedPlaceID: NSManagedObjectID?
    @State private var isResolvingMarkers = false
    @State private var unresolvedPlaceCount = 0
    @State private var markerFailure: MapPlaceLookupFailure?
    @State private var showingExploreSearch = false
    @State private var showingSavedPlaceFilters = false
    private var savedPlaceFilters: SavedPlaceSearchFilters { browse.filters }

    private static let feastListsFetchRequest: NSFetchRequest<FeastList> = {
        let request = FeastList.fetchRequest()
        request.sortDescriptors = [
            NSSortDescriptor(key: "createdAt", ascending: true),
            NSSortDescriptor(key: "name", ascending: true)
        ]
        return request
    }()

    private static let savedPlacesFetchRequest: NSFetchRequest<SavedPlace> = {
        let request = SavedPlace.fetchRequest()
        request.sortDescriptors = [
            NSSortDescriptor(key: "updatedAt", ascending: false),
            NSSortDescriptor(key: "displayNameSnapshot", ascending: true)
        ]
        return request
    }()

    var body: some View {
        content
            .toolbar {
                if unresolvedPlaceCount > 0 && !isResolvingMarkers && !filteredMarkerItems.isEmpty {
                    Button("Retry Missing Pins") { markerRetry += 1 }
                }
            }
            .onDisappear { nearby.cancel(); endMapSession() }
            .onChange(of: browse.selectedTab) { _, tab in if tab != 1 { nearby.cancel() } }
            .onChange(of: browse.scopeKey) { _, _ in nearby.cancel() }
            .onChange(of: nearby.resultID) { _, _ in
                guard let fix = nearby.location, nearbyScope == browse.scopeKey, browse.selectedTab == 1 else { return }
                let region = MKCoordinateRegion(center: fix.coordinate, latitudinalMeters: 2_000, longitudinalMeters: 2_000)
                guard browse.rememberNearbyViewport(SavedMapViewport(latitude: region.center.latitude, longitude: region.center.longitude,
                    latitudeDelta: region.span.latitudeDelta, longitudeDelta: region.span.longitudeDelta), requestedScope: nearbyScope ?? "") else { return }
                cameraPosition = .region(region)
            }
            .alert("Location Unavailable", isPresented: Binding(get: { nearby.errorMessage != nil }, set: { if !$0 { nearby.errorMessage = nil } })) {
                Button("OK") { nearby.errorMessage = nil }
            } message: { Text(nearby.errorMessage ?? "") }
            .onChange(of: feastLists.map(\.objectURIString)) { _, values in browse.validateCities(Set(values)) }
            .navigationTitle("Map")
            .navigationBarTitleDisplayMode(.inline)
            .task(id: markerResolutionKey + "|\(markerRetry)|\(mapIsActive)") {
                if mapIsActive { await resolveMarkers() } else { endMapSession() }
            }
            .navigationDestination(item: $presentedPlaceID) { placeID in
                if let savedPlace = savedPlace(for: placeID) {
                    SavedPlaceDetailView(savedPlace: savedPlace)
                } else {
                    ContentUnavailableView(
                        "Place Unavailable",
                        systemImage: "mappin.slash",
                        description: Text("This saved place could not be loaded.")
                    )
                }
            }
            .onChange(of: selectedPlaceID) { _, placeID in
                if let placeID { presentedPlaceID = placeID }
            }
            .onChange(of: presentedPlaceID) { _, placeID in
                if placeID == nil { selectedPlaceID = nil }
            }
            .sheet(isPresented: $showingExploreSearch) {
                NavigationStack {
                    AddPlaceView(feastList: feastLists.first(where: { $0.objectURIString == discoveryCityURI }))
                }
            }
            .sheet(isPresented: $showingSavedPlaceFilters) {
                NavigationStack {
                    SavedPlaceFilterSheet(
                        filters: $browse.filters,
                        availableLists: Array(feastLists),
                        availableCuisines: SavedPlaceSearchEngine.availableCuisines(from: Array(savedPlaces), filters: .init()),
                        fixedFeastList: nil,
                        availableTags: availableTags,
                        showsQuery: true
                    )
                }
                .presentationDetents([.medium, .large])
            }
    }

    private var content: some View {
        Group {
            if feastLists.isEmpty {
                ContentUnavailableView {
                    Label("No Cities Yet", systemImage: "map")
                } description: {
                    Text("Add your first city in Cities, then save places to see them here.")
                } actions: {
                    Button("Go to Cities") { browse.selectedTab = 0 }
                        .buttonStyle(FeastQuietChipButtonStyle())
                }
            } else {
                mapScreen
                .background(FeastTheme.Colors.appBackground)
            }
        }
    }

    private var mapScreen: some View {
        ZStack(alignment: .top) {
            mapContent

            VStack(spacing: 0) {
                if dynamicTypeSize.isAccessibilitySize {
                    ScrollView { mapHeaderOverlay }
                        .frame(maxHeight: 260)
                } else {
                    mapHeaderOverlay
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, FeastTheme.Spacing.large)
            .padding(.top, FeastTheme.Spacing.small)
        }
            .overlay(alignment: .bottomTrailing) {
                Button {
                    nearbyScope = browse.scopeKey
                    nearby.request()
                } label: {
                    HStack {
                        if nearby.isRequesting { ProgressView() }
                        if dynamicTypeSize.isAccessibilitySize {
                            Image(systemName: "location")
                        } else {
                            Label(nearby.isRequesting ? "Locating…" : "Nearby", systemImage: "location")
                        }
                    }
                }
                .buttonStyle(FeastQuietChipButtonStyle())
                .disabled(nearby.isRequesting)
                .accessibilityLabel(nearby.isRequesting ? "Finding your location" : "Nearby saved places")
                .accessibilityHint("Centers the map on your location, keeping the selected city and filters")
                .padding(16)
            }
    }

    private var selectedFeastList: FeastList? {
        feastLists.first { $0.objectURIString == browse.filters.selectedListURIString }
    }

    private var selectedCitySavedPlaces: [SavedPlace] {
        guard let selectedFeastList else { return Array(savedPlaces) }
        return savedPlaces.filter { $0.feastList == selectedFeastList }
    }

    private var filteredCitySavedPlaces: [SavedPlace] {
        SavedPlaceSearchEngine.filteredPlaces(from: Array(savedPlaces), query: browse.filters.queryText, filters: browse.filters)
    }

    private var filteredMarkerItems: [SavedPlaceMapMarker] {
        let filteredPlaceIDs = SavedPlaceSearchEngine.mappedPlaceIDs(from: Array(savedPlaces), filters: browse.filters, resolvedIDs: Set(markerItems.map(\.savedPlaceObjectID)))
        return markerItems.filter { filteredPlaceIDs.contains($0.savedPlaceObjectID) }
    }

    private var availableTags: [String] {
        FeastTag.catalog(from: selectedCitySavedPlaces.map(\.tags))
    }

    private var hasActiveSavedPlaceFilters: Bool {
        savedPlaceFilters.hasCriteria
    }

    private var mapIsActive: Bool { browse.selectedTab == 1 && scenePhase != .background }

    private var markerResolutionKey: String {
        let listKey = browse.scopeKey
        let placeKeys = selectedCitySavedPlaces.map { place in
            let objectKey = place.objectID.uriRepresentation().absoluteString
            let updateKey = place.updatedAtValue.timeIntervalSinceReferenceDate
            return "\(objectKey)-\(updateKey)"
        }

        return ([listKey] + placeKeys).joined(separator: "|")
    }

    private var headerLayout: AnyLayout {
        dynamicTypeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: 8))
            : AnyLayout(HStackLayout(alignment: .top, spacing: 12))
    }

    private var mapHeaderOverlay: some View {
        VStack(alignment: .leading, spacing: FeastTheme.Spacing.small) {
            headerLayout {
                VStack(alignment: .leading, spacing: FeastTheme.Spacing.small) {
                    Text("City")
                        .font(FeastTheme.Typography.sectionLabel)
                        .tracking(0.8)
                        .foregroundStyle(FeastTheme.Colors.secondaryText)

                    Menu {
                        Button("All Cities") { browse.filters.selectedListURIString = nil }
                        ForEach(feastLists) { feastList in
                            Button(feastList.displayName) {
                                browse.filters.selectedListURIString = uriString(for: feastList)
                            }
                        }
                    } label: {
                        HStack(spacing: FeastTheme.Spacing.small) {
                            Image(systemName: "mappin.circle.fill")
                                .font(.system(size: 14, weight: .semibold))
                                .foregroundStyle(FeastTheme.Colors.accentSelection)

                            Text(selectedFeastList?.displayName ?? "All Cities")
                                .font(FeastTheme.Typography.listTitle)
                                .foregroundStyle(FeastTheme.Colors.primaryText)
                                .fixedSize(horizontal: false, vertical: true)

                            Image(systemName: "chevron.down")
                                .font(FeastTheme.Typography.caption.weight(.semibold))
                                .foregroundStyle(FeastTheme.Colors.secondaryText)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .buttonStyle(.plain)
                    .frame(minHeight: 44)

                    if let markerFailure, unresolvedPlaceCount > 0, !isResolvingMarkers {
                        Text(markerFailure.message).font(FeastTheme.Typography.caption)
                            .foregroundStyle(FeastTheme.Colors.secondaryText)
                    }
                    Text(citySummaryText)
                        .font(FeastTheme.Typography.rowMetadata)
                        .foregroundStyle(citySummaryColor)
                        .fixedSize(horizontal: false, vertical: true)
                        .multilineTextAlignment(.leading)
                }

                if !dynamicTypeSize.isAccessibilitySize { Spacer(minLength: 0) }

                VStack(alignment: .trailing, spacing: FeastTheme.Spacing.small) {
                    Button {
                        presentDiscovery()
                    } label: {
                        Label("Search", systemImage: "magnifyingglass")
                    }
                    .buttonStyle(FeastQuietChipButtonStyle())
                    .accessibilityLabel("Search Apple Maps")

                    Button {
                        presentSavedPlaceFilters()
                    } label: {
                        HStack(spacing: FeastTheme.Spacing.xSmall) {
                            Image(
                                systemName: hasActiveSavedPlaceFilters
                                    ? "line.3.horizontal.decrease.circle.fill"
                                    : "line.3.horizontal.decrease.circle"
                            )

                            Text("Filters")

                        }
                    }
                    .buttonStyle(FeastQuietChipButtonStyle())
                    .accessibilityLabel("Filters")
                    .accessibilityValue(
                        hasActiveSavedPlaceFilters
                            ? "Active filters"
                            : "No active filters"
                    )
                }
            }

        }
        .padding(.horizontal, FeastTheme.Spacing.large)
        .padding(.vertical, FeastTheme.Spacing.medium)
        .feastMapOverlayCard(cornerRadius: FeastTheme.CornerRadius.medium)
    }

    private var mapContent: some View {
        ZStack {
            Map(position: $cameraPosition, selection: $selectedPlaceID) {
                if let fix = nearby.location {
                    Annotation("Your location", coordinate: fix.coordinate) {
                        Image(systemName: "location.circle.fill")
                            .font(.title).foregroundStyle(.white, .blue)
                            .accessibilityLabel("Your last requested location")
                    }
                }
                ForEach(filteredMarkerItems) { marker in
                    Marker(marker.markerLabel, coordinate: marker.coordinate.clLocationCoordinate2D)
                        .tint(FeastTheme.Colors.mapPinTint)
                        .tag(marker.savedPlaceObjectID)
                }
            }
            .onMapCameraChange(frequency: .onEnd) { camera in
                guard cameraPosition.positionedByUser else { return }
                let region = camera.region
                browse.viewports[browse.scopeKey] = SavedMapViewport(latitude: region.center.latitude, longitude: region.center.longitude,
                    latitudeDelta: region.span.latitudeDelta, longitudeDelta: region.span.longitudeDelta)
            }
            .mapStyle(.standard(elevation: .flat))
            .ignoresSafeArea(edges: .bottom)
            .overlay {
                VStack(spacing: 0) {
                    LinearGradient(
                        colors: [
                            FeastTheme.Colors.groupedBackground.opacity(0.26),
                            .clear
                        ],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                    .frame(height: 120)

                    Spacer(minLength: 0)

                    LinearGradient(
                        colors: [
                            .clear,
                            FeastTheme.Colors.appBackground.opacity(0.2)
                        ],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                    .frame(height: 140)
                }
                .allowsHitTesting(false)
            }

            if case let .savedContent(reason) = emptyPresentation {
                SavedPlaceEmptyState(reason: reason, scopeName: selectedFeastList?.displayName ?? "All Cities", addPlace: presentDiscovery)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(FeastTheme.Spacing.large)
                    .feastMapOverlayCard(cornerRadius: FeastTheme.CornerRadius.medium)
                    .padding(.horizontal, FeastTheme.Spacing.large)
            } else if emptyPresentation == .locationsUnavailable {
                ContentUnavailableView {
                    Label("Locations Couldn't Be Loaded", systemImage: "mappin.slash")
                } description: {
                    Text(markerFailure?.message ?? "Your places are still saved. Try loading their map locations again.")
                } actions: {
                    Button("Retry") { markerRetry += 1 }.buttonStyle(FeastQuietChipButtonStyle())
                }
                .padding(FeastTheme.Spacing.large)
                .feastMapOverlayCard(cornerRadius: FeastTheme.CornerRadius.medium)
                .padding(.horizontal, FeastTheme.Spacing.large)
            }

            if isResolvingMarkers && emptyReason == .hasMatches {
                HStack(spacing: FeastTheme.Spacing.small) {
                    ProgressView()
                    Text("Loading pins · \(markerItems.count) of \(selectedCitySavedPlaces.count)")
                        .font(FeastTheme.Typography.rowMetadata)
                        .foregroundStyle(FeastTheme.Colors.primaryText)
                }
                .padding(.horizontal, FeastTheme.Spacing.large)
                .padding(.vertical, FeastTheme.Spacing.medium)
                .feastMapOverlayCard(cornerRadius: FeastTheme.CornerRadius.medium)
            }
        }
    }

    private var citySummaryColor: Color {
        filteredCitySavedPlaces.isEmpty ? FeastTheme.Colors.secondaryText : FeastTheme.Colors.tertiaryText
    }

    private var citySummaryText: String {
        let savedCount = selectedCitySavedPlaces.count
        let filteredSavedCount = filteredCitySavedPlaces.count
        let mappedCount = filteredMarkerItems.count

        if savedCount == 0 {
            return "Search Apple Maps and save places to start building the map."
        }

        if shouldShowNoMatchingResults {
            return emptyReason == .queryHasNoMatches ? "No saved places match this search." : "Filters are hiding matching places."
        }

        if hasActiveSavedPlaceFilters {
            let unresolvedFilteredCount = max(filteredSavedCount - mappedCount, 0)

            if unresolvedFilteredCount > 0 {
                return "\(mappedCount) of \(filteredSavedCount) matching saved places mapped"
            }

            if mappedCount == 0 {
                return "Matching saved places will appear here once Apple Maps can resolve them."
            }

            return "\(mappedCount) matching saved \(mappedCount == 1 ? "place" : "places") in \(selectedFeastList?.displayName ?? "All Cities")"
        }

        if unresolvedPlaceCount > 0 {
            return "\(mappedCount) of \(savedCount) saved places mapped"
        }

        if mappedCount == 0 {
            return "Saved places in this city will appear here once Apple Maps can resolve them."
        }

        return "\(mappedCount) saved \(mappedCount == 1 ? "place" : "places") in \(selectedFeastList?.displayName ?? "All Cities")"
    }

    private var emptyPresentation: SavedMapEmptyPresentation {
        .evaluate(reason: emptyReason, resolving: isResolvingMarkers, pinCount: filteredMarkerItems.count)
    }

    private var emptyReason: SavedPlaceEmptyReason {
        SavedPlaceEmptyReason.evaluate(places: Array(savedPlaces), filters: savedPlaceFilters)
    }

    private var shouldShowNoMatchingResults: Bool {
        emptyReason == .queryHasNoMatches || emptyReason == .filtersHideMatches
    }

    private var trimmedSavedPlaceQueryText: String? {
        let trimmed = savedPlaceFilters.queryText.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private func compactFilterChipText(_ text: String, limit: Int = 24) -> String {
        guard text.count > limit else {
            return text
        }

        let endIndex = text.index(text.startIndex, offsetBy: max(limit - 3, 0))
        return "\(text[..<endIndex])..."
    }

    @MainActor
    private func endMapSession() {
        markerGeneration = UUID()
        markerLookup.clear()
        markerItems = []
        unresolvedPlaceCount = 0
        markerFailure = nil
        isResolvingMarkers = false
    }

    @MainActor
    private func resolveMarkers() async {
        guard !Task.isCancelled else { return }
        let scope = browse.scopeKey
        if displayedScope != scope {
            displayedScope = scope
            if let viewport = browse.viewports[scope] {
                cameraPosition = .region(MKCoordinateRegion(center: CLLocationCoordinate2D(latitude: viewport.latitude, longitude: viewport.longitude),
                    span: MKCoordinateSpan(latitudeDelta: viewport.latitudeDelta, longitudeDelta: viewport.longitudeDelta)))
            } else { cameraPosition = .automatic }
        }

        let generation = UUID()
        markerGeneration = generation
        let places = selectedCitySavedPlaces
        let currentIDs = Dictionary(uniqueKeysWithValues: places.map { ($0.objectID, $0.applePlaceIDValue ?? "") })
        markerLookup.retainOnly(Set(currentIDs.values.filter { !$0.isEmpty }))
        markerItems = markerItems.filter { currentIDs[$0.savedPlaceObjectID] == $0.applePlaceID }
        unresolvedPlaceCount = places.count - markerItems.count
        markerFailure = nil
        isResolvingMarkers = true
        defer {
            if markerGeneration == generation { isResolvingMarkers = false }
        }
        var resolvedMarkers = markerItems
        for savedPlace in places {
            guard !Task.isCancelled, markerGeneration == generation else { return }
            guard let applePlaceID = savedPlace.applePlaceIDValue else {
                markerFailure = markerFailure ?? .unavailable
                continue
            }
            do {
                let resolvedPlace = try await markerLookup.resolve(placeID: applePlaceID) { id in
                    try await applePlacesService.resolve(placeID: id)
                }
                guard !Task.isCancelled, markerGeneration == generation else { return }
                if let resolvedPlace, let coordinate = resolvedPlace.coordinate {
                    resolvedMarkers.removeAll { $0.savedPlaceObjectID == savedPlace.objectID }
                    resolvedMarkers.append(SavedPlaceMapMarker(
                        savedPlaceObjectID: savedPlace.objectID,
                        applePlaceID: applePlaceID,
                        displayName: resolvedPlace.displayName,
                        fallbackName: savedPlace.displayName,
                        coordinate: coordinate
                    ))
                    markerItems = resolvedMarkers
                    unresolvedPlaceCount = places.count - resolvedMarkers.count
                } else {
                    markerFailure = markerFailure ?? .unavailable
                }
            } catch {
                guard !Task.isCancelled, markerGeneration == generation else { return }
                if error is CancellationError { return }
                let failure = MapPlaceLookupFailure.classify(error)
                markerFailure = failure
                if failure.pausesBatch { break }
            }
        }
        guard !Task.isCancelled, markerGeneration == generation else { return }
        if browse.viewports[scope] == nil, !cameraPosition.positionedByUser, !resolvedMarkers.isEmpty {
            updateCameraPosition(using: resolvedMarkers)
        }
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

    private func presentDiscovery() {
        discoveryCityURI = selectedFeastList?.objectURIString
        showingExploreSearch = true
    }

    private func presentSavedPlaceFilters() { showingSavedPlaceFilters = true }

    private func uriString(for feastList: FeastList) -> String {
        feastList.objectID.uriRepresentation().absoluteString
    }
}

private struct SavedPlaceMapMarker: Identifiable, Hashable {
    let savedPlaceObjectID: NSManagedObjectID
    let applePlaceID: String
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
