import CoreData
import MapKit
import SwiftUI
import os

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
    @State private var viewport = SavedMapViewport.overview
    @State private var cameraRevision = UUID()
    @State private var viewportRevision = 0
    @State private var automaticNearby = false
    @State private var nearbyRevision = 0
    @StateObject private var markerLookup = MapPlaceLookup.shared
    @State private var markerGeneration = UUID()
    @State private var markerRetry = 0
    @State private var refreshAfterLoading = false
    @State private var failedIDs: Set<String> = []
    @State private var loadingCount = 0
    @State private var completedCount = 0
    @State private var clusterIDs: [String] = []
    @State private var selectedPlaceID: NSManagedObjectID?
    @State private var isResolvingMarkers = false

    @State private var markerFailure: MapPlaceLookupFailure?
    @State private var showingExploreSearch = false
    @State private var showingSavedPlaceFilters = false
    private var savedPlaceFilters: SavedPlaceSearchFilters { browse.filters }

    private static let loadLogger = Logger(subsystem: "com.jongalante.Feast", category: "SavedMapLoad")

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

    private var lifecycleContent: some View {
        content
            .toolbar {
                if (markerFailure != nil || !failedIDs.isEmpty || capacityDeferredCount > 0) && !isResolvingMarkers {
                    Button("Retry Missing Pins") { markerLookup.retryEvictedLocations(); markerRetry += 1 }
                }
            }
            .onDisappear { markerLookup.visibleViewport = nil; nearby.cancel(); markerGeneration = UUID(); isResolvingMarkers = false }
            .onChange(of: scenePhase) { _, phase in if phase == .background { nearby.cancel() } }
            .onChange(of: browse.selectedTab) { _, tab in if tab != 1 { nearby.cancel() } }
            .onChange(of: browse.scopeKey) { _, _ in nearby.cancel() }
            .onChange(of: nearby.resultID) { _, _ in
                guard let fix = nearby.location,
                      SavedMapPlan.acceptsCameraResult(requestedScope: nearbyScope ?? "", currentScope: browse.scopeKey,
                          requestedRevision: nearbyRevision, currentRevision: viewportRevision, active: mapIsActive) else { return }
                displayedScope = browse.scopeKey
                setCamera(.nearby(fix.coordinate))
            }
            .alert("Location Unavailable", isPresented: Binding(get: { !automaticNearby && nearby.errorMessage != nil }, set: { if !$0 { nearby.errorMessage = nil } })) {
                Button("OK") { nearby.errorMessage = nil }
            } message: { Text(nearby.errorMessage ?? "") }
            .onChange(of: markerLookup.expiration) { _, _ in
                guard mapIsActive else { return }
                if isResolvingMarkers { refreshAfterLoading = true } else { markerRetry += 1 }
            }
            .onChange(of: feastLists.map(\.objectURIString)) { _, values in browse.validateCities(Set(values)) }
    }

    var body: some View {
        lifecycleContent
            .navigationTitle("Map")
            .navigationBarTitleDisplayMode(.inline)
            .task(id: "camera|\(browse.scopeKey)|\(markerRetry)|\(mapIsActive)") {
                if mapIsActive { await prepareCamera() }
            }
            .task(id: markerResolutionKey + "|\(markerRetry)|\(mapIsActive)") {
                if mapIsActive { await resolveMarkers() }
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
            .sheet(isPresented: Binding(get: { !clusterIDs.isEmpty }, set: { if !$0 { clusterIDs = [] } })) {
                clusterSheet
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

    private var clusterSheet: some View {
        NavigationStack {
            List(savedPlaces.filter { clusterIDs.contains($0.objectID.uriRepresentation().absoluteString) }) { place in
                Button { clusterIDs = []; selectedPlaceID = place.objectID } label: {
                    VStack(alignment: .leading) {
                        Text(place.displayName)
                        Text(place.displayCityName + " · " + place.displayNeighborhoodName).font(.caption).foregroundStyle(.secondary)
                    }.frame(minHeight: 44)
                }
            }
            .navigationTitle("Saved Places")
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Done") { clusterIDs = [] } } }
        }
        .presentationDetents([.medium, .large])
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
                    automaticNearby = false
                    viewportRevision += 1
                    nearbyScope = browse.scopeKey; nearbyRevision = viewportRevision
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

    /// No second coordinate cache in the view. Expiry/background eviction in the
    /// shared service also removes annotations from the Apple map.
    private var markerItems: [SavedPlaceMapMarker] {
        filteredCitySavedPlaces.compactMap { place in
            guard let id = place.applePlaceIDValue, let match = markerLookup.cachedPlace(id), let coordinate = match.coordinate else { return nil }
            return SavedPlaceMapMarker(savedPlaceObjectID: place.objectID, applePlaceID: id,
                displayName: match.displayName, fallbackName: place.displayName, coordinate: coordinate)
        }
    }
    private var filteredMarkerItems: [SavedPlaceMapMarker] {
        markerItems.filter { viewport.contains($0.coordinate) }
    }
    private var unresolvedPlaceCount: Int { max(0, filteredCitySavedPlaces.count - markerItems.count) }
    private var capacityDeferredCount: Int {
        let cached = Set(markerItems.map(\.applePlaceID)), attempted = markerLookup.recentlyResolvedIDs
        return placePlan.filter { !cached.contains($0.appleID) && attempted.contains($0.appleID) }.count
    }
    private var placePlan: [SavedMapPlan.Place] {
        filteredCitySavedPlaces.map { .init(id: $0.objectID.uriRepresentation().absoluteString, appleID: $0.applePlaceIDValue ?? "", cityID: $0.feastList?.objectURIString ?? "") }
    }
    private var availableTags: [String] {
        FeastTag.catalog(from: selectedCitySavedPlaces.map(\.tags))
    }

    private var hasActiveSavedPlaceFilters: Bool {
        savedPlaceFilters.hasCriteria
    }

    private var mapIsActive: Bool { browse.selectedTab == 1 && scenePhase != .background }

    private var markerResolutionKey: String {
        let cities = feastLists.map { "\($0.objectURIString):\($0.displayName)" }.sorted().joined(separator: "|")
        return browse.scopeKey + "|" + SavedMapPlan.identity(placePlan) + "|" + cities + "|" + viewport.queryKey
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
        SavedPinsMap(viewport: viewport, cameraRevision: cameraRevision,
            pins: filteredMarkerItems.map { .init(id: $0.savedPlaceObjectID.uriRepresentation().absoluteString,
                title: $0.markerLabel, coordinate: $0.coordinate) },
            location: nearby.location.map { .init(latitude: $0.coordinate.latitude, longitude: $0.coordinate.longitude) },
            interactionBegan: {
                viewportRevision += 1; nearby.cancel(); displayedScope = browse.scopeKey
            }, moved: { next, userInitiated in
                guard viewport != next else { return }
                viewport = next; markerLookup.visibleViewport = next
                if userInitiated {
                    viewportRevision += 1; nearby.cancel(); displayedScope = browse.scopeKey
                    browse.viewports[browse.scopeKey] = next
                }
                // User panning takes precedence over a late automatic fix/city lookup.
            }, clusterSelected: { clusterIDs = $0 }, selected: { uri in
                if let place = savedPlaces.first(where: { $0.objectID.uriRepresentation().absoluteString == uri }) { selectedPlaceID = place.objectID }
            })
            .ignoresSafeArea(edges: .bottom)
            .overlay {
                if emptyReason != .hasMatches {
                    SavedPlaceEmptyState(reason: emptyReason, scopeName: selectedFeastList?.displayName ?? "All Cities", addPlace: presentDiscovery)
                        .padding(FeastTheme.Spacing.large)
                        .feastMapOverlayCard(cornerRadius: FeastTheme.CornerRadius.medium)
                        .padding(.horizontal, FeastTheme.Spacing.large)
                }
            }
            .overlay(alignment: .bottomLeading) {
                if isResolvingMarkers {
                    HStack(spacing: 6) {
                        ProgressView().controlSize(.small)
                        Text(loadingCount > 0 ? "Loading locations · \(completedCount)/\(loadingCount)" : "Finding nearby cities…")
                            .font(FeastTheme.Typography.caption)
                    }
                    .padding(10).feastMapOverlayCard(cornerRadius: FeastTheme.CornerRadius.medium)
                    .padding(.leading, 12).padding(.bottom, 70)
                    .accessibilityElement(children: .combine)
                }
            }
    }

    private var citySummaryColor: Color {
        filteredCitySavedPlaces.isEmpty ? FeastTheme.Colors.secondaryText : FeastTheme.Colors.tertiaryText
    }

    private var citySummaryText: String {
        if selectedCitySavedPlaces.isEmpty { return "Search Apple Maps and save places to start building the map." }
        if shouldShowNoMatchingResults { return emptyReason == .queryHasNoMatches ? "No saved places match this search." : "Filters are hiding matching places." }
        let base = "\(filteredMarkerItems.count) pins in view · \(filteredCitySavedPlaces.count) saved places"
        if capacityDeferredCount > 0 { return base + ". Some locations were released from temporary memory. Retry Missing Pins to reload them." }
        if browse.filters.selectedListURIString == nil && !viewport.loadsUnknownPlaces { return base + ". Zoom in or choose a city to load locations." }
        if unresolvedPlaceCount > 0 && !isResolvingMarkers && failedIDs.isEmpty { return base + ". Some locations aren't loaded yet; choose a city to include them." }
        return base
    }

    private var emptyReason: SavedPlaceEmptyReason {
        SavedPlaceEmptyReason.evaluate(places: Array(savedPlaces), filters: savedPlaceFilters)
    }

    private var shouldShowNoMatchingResults: Bool {
        emptyReason == .queryHasNoMatches || emptyReason == .filtersHideMatches
    }

    @MainActor private func setCamera(_ next: SavedMapViewport) {
        guard next.isValid else { return }
        viewport = next; markerLookup.visibleViewport = next; cameraRevision = UUID(); browse.viewports[browse.scopeKey] = next
    }
    @MainActor private func prepareCamera() async {
        let scope = browse.scopeKey
        guard displayedScope != scope else { return }
        viewportRevision += 1
        if let remembered = browse.viewports[scope] { displayedScope = scope; setCamera(remembered); return }
        let revision = viewportRevision
        if let city = selectedFeastList {
            do {
                let hint = try await markerLookup.city(name: city.displayName) { try await applePlacesService.cityViewport(name: $0) }
                guard !Task.isCancelled, let hint,
                      SavedMapPlan.acceptsCameraResult(requestedScope: scope, currentScope: browse.scopeKey,
                          requestedRevision: revision, currentRevision: viewportRevision, active: mapIsActive) else { return }
                displayedScope = scope; setCamera(hint)
            } catch {
                if !Task.isCancelled { markerFailure = MapPlaceLookupFailure.classify(error) }
            }
        } else {
            automaticNearby = true; nearbyScope = scope; nearbyRevision = revision
            nearby.requestIfAuthorized()
            if !nearby.isRequesting { displayedScope = scope }
        }
    }

    @MainActor private func resolveMarkers() async {
        guard !Task.isCancelled else { return }
        markerLookup.visibleViewport = viewport
        let start = ProcessInfo.processInfo.systemUptime
        let generation = UUID(); markerGeneration = generation
        let plan = placePlan, scope = browse.scopeKey, requestedViewport = viewport
        let selected = browse.filters.selectedListURIString
        let eligibleCities = Set(plan.map(\.cityID))
        let cities = feastLists.filter { eligibleCities.contains($0.objectURIString) }
            .map { ($0.objectURIString, $0.displayName) }
        isResolvingMarkers = true; loadingCount = 0; completedCount = 0; markerFailure = nil; failedIDs = []
        defer {
            if markerGeneration == generation {
                isResolvingMarkers = false
                let elapsed = Int((ProcessInfo.processInfo.systemUptime - start) * 1000)
                Self.loadLogger.info("elapsed_ms=\(elapsed, privacy: .public) attempted=\(completedCount, privacy: .public) planned=\(loadingCount, privacy: .public) visible=\(filteredMarkerItems.count, privacy: .public) cancelled=\(Task.isCancelled, privacy: .public)")
                if refreshAfterLoading { refreshAfterLoading = false; markerRetry += 1 }
            }
        }
        if let selected {
            await resolvePlaceIDs(SavedMapPlan.lookupIDs(places: plan, selectedCity: selected,
                viewport: requestedViewport, cityHints: [:], known: markerLookup.recentlyResolvedIDs), generation: generation)
            return
        }
        guard requestedViewport.loadsUnknownPlaces else { return }
        // Hints are city-level demand hints, not a spatial index for unknown records.
        // Nearby cached hints go first. As a nearby hint returns, load that city's
        // eligible places without waiting for every other city's hint.
        let orderedCities = cities.sorted {
            let a = markerLookup.cachedCity($0.1).map { requestedViewport.contains(.init(latitude:$0.latitude,longitude:$0.longitude),padding:3) } ?? false
            let b = markerLookup.cachedCity($1.1).map { requestedViewport.contains(.init(latitude:$0.latitude,longitude:$0.longitude),padding:3) } ?? false
            return a != b ? a : $0.0 < $1.0
        }
        var index = 0
        await withTaskGroup(of: (String, SavedMapViewport?, MapPlaceLookupFailure?).self) { group in
            func add() {
                guard index < orderedCities.count, !Task.isCancelled else { return }
                let city = orderedCities[index]; index += 1
                group.addTask { @MainActor in
                    do { return (city.0, try await markerLookup.city(name: city.1) { try await applePlacesService.cityViewport(name: $0) }, nil) }
                    catch { return (city.0, nil, error is CancellationError ? nil : MapPlaceLookupFailure.classify(error)) }
                }
            }
            for _ in 0..<min(3, orderedCities.count) { add() }
            while let (id, hint, failure) = await group.next() {
                guard !Task.isCancelled, markerGeneration == generation, scope == browse.scopeKey else { group.cancelAll(); break }
                if let failure { markerFailure = failure }
                if let failure, failure.pausesBatch { group.cancelAll(); break }
                if let hint {
                    let ids = SavedMapPlan.lookupIDs(places:plan.filter {$0.cityID == id},selectedCity:nil,
                        viewport:requestedViewport,cityHints:[id:hint],known:markerLookup.recentlyResolvedIDs)
                    await resolvePlaceIDs(ids,generation:generation)
                    if markerFailure?.pausesBatch == true { group.cancelAll(); break }
                }
                add()
            }
        }
    }

    @MainActor private func resolvePlaceIDs(_ ids: [String], generation: UUID) async {
        let needed = ids.filter { markerLookup.cachedPlace($0) == nil }
        loadingCount += needed.count
        var index = 0, stopped = false
        await withTaskGroup(of: (String, Bool, MapPlaceLookupFailure?).self) { group in
            func add() {
                guard !stopped, index < needed.count, !Task.isCancelled else { return }; let id = needed[index]; index += 1
                group.addTask { @MainActor in
                    do { return (id, try await markerLookup.resolve(placeID: id) { try await applePlacesService.resolve(placeID: $0) } != nil, nil) }
                    catch { return (id, false, error is CancellationError ? nil : MapPlaceLookupFailure.classify(error)) }
                }
            }
            for _ in 0..<min(3, needed.count) { add() }
            while let (id, success, failure) = await group.next() {
                guard !Task.isCancelled, markerGeneration == generation else { group.cancelAll(); break }
                completedCount += 1
                if !success { failedIDs.insert(id); markerFailure = failure ?? .unavailable }
                if let failure, failure.pausesBatch { stopped = true }
                add()
            }
        }
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
