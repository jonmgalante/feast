import CoreData
import MapKit
import SwiftUI

struct MapRootView: View {
    @Environment(\.managedObjectContext) private var viewContext
    @Environment(\.applePlacesService) private var applePlacesService

    @FetchRequest(fetchRequest: Self.feastListsFetchRequest, animation: .default)
    private var feastLists: FetchedResults<FeastList>

    @FetchRequest(fetchRequest: Self.savedPlacesFetchRequest, animation: .default)
    private var savedPlaces: FetchedResults<SavedPlace>

    @SceneStorage("map.selectedFeastListURI") private var selectedFeastListURI = ""
    @State private var cameraPosition: MapCameraPosition = .automatic
    @State private var markerItems: [SavedPlaceMapMarker] = []
    @State private var selectedMarker: SavedPlaceMapMarker?
    @State private var isResolvingMarkers = false
    @State private var unresolvedPlaceCount = 0
    @State private var showingExploreSearch = false
    @State private var showingSavedPlaceFilters = false
    @State private var savedPlaceFilters = MapSavedPlaceFilters()
    @State private var draftSavedPlaceFilters = MapSavedPlaceFilters()

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
            .navigationTitle("Map")
            .navigationBarTitleDisplayMode(.inline)
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
                            "No City Selected",
                            systemImage: "magnifyingglass",
                            description: Text("Choose a city before searching Apple Maps.")
                        )
                        .navigationTitle("Search")
                        .navigationBarTitleDisplayMode(.inline)
                    }
                }
            }
            .sheet(isPresented: $showingSavedPlaceFilters) {
                NavigationStack {
                    MapSavedPlaceFilterSheet(
                        filters: $draftSavedPlaceFilters,
                        availableTags: availableTags,
                        cityName: selectedFeastList?.displayName ?? "This city",
                        onApply: applyDraftSavedPlaceFilters
                    )
                }
                .presentationDetents([.medium, .large])
            }
    }

    private var content: some View {
        Group {
            if feastLists.isEmpty {
                ContentUnavailableView(
                    "No Cities Yet",
                    systemImage: "map",
                    description: Text("Create a city to start mapping saved places.")
                )
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
                mapHeaderOverlay
                Spacer(minLength: 0)
            }
            .padding(.horizontal, FeastTheme.Spacing.large)
            .padding(.top, FeastTheme.Spacing.small)
        }
    }

    private var selectedFeastList: FeastList? {
        if let matchedList = feastLists.first(where: { uriString(for: $0) == selectedFeastListURI }) {
            return matchedList
        }

        return feastLists.first
    }

    private var selectedCitySavedPlaces: [SavedPlace] {
        guard let selectedFeastList else {
            return []
        }

        return savedPlaces.filter { $0.feastList == selectedFeastList }
    }

    private var filteredCitySavedPlaces: [SavedPlace] {
        MapSavedPlaceFilterEngine.filteredPlaces(
            from: selectedCitySavedPlaces,
            filters: savedPlaceFilters
        )
    }

    private var filteredMarkerItems: [SavedPlaceMapMarker] {
        let filteredPlaceIDs = Set(filteredCitySavedPlaces.map(\.objectID))
        return markerItems.filter { filteredPlaceIDs.contains($0.savedPlaceObjectID) }
    }

    private var availableTags: [String] {
        FeastTag.catalog(from: selectedCitySavedPlaces.map(\.tags))
    }

    private var hasActiveSavedPlaceFilters: Bool {
        savedPlaceFilters.hasActiveFilters
    }

    private var markerResolutionKey: String {
        let listKey = selectedFeastList.map(uriString(for:)) ?? "none"
        let placeKeys = selectedCitySavedPlaces.map { place in
            let objectKey = place.objectID.uriRepresentation().absoluteString
            let updateKey = place.updatedAtValue.timeIntervalSinceReferenceDate
            return "\(objectKey)-\(updateKey)"
        }

        return ([listKey] + placeKeys).joined(separator: "|")
    }

    private var mapHeaderOverlay: some View {
        HStack(alignment: .top, spacing: FeastTheme.Spacing.medium) {
            VStack(alignment: .leading, spacing: FeastTheme.Spacing.small) {
                Text("City")
                    .font(FeastTheme.Typography.sectionLabel)
                    .tracking(0.8)
                    .foregroundStyle(FeastTheme.Colors.secondaryText)

                Menu {
                    ForEach(feastLists) { feastList in
                        Button(feastList.displayName) {
                            selectedFeastListURI = uriString(for: feastList)
                        }
                    }
                } label: {
                    HStack(spacing: FeastTheme.Spacing.small) {
                        Image(systemName: "mappin.circle.fill")
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(FeastTheme.Colors.accentSelection)

                        Text(selectedFeastList?.displayName ?? "Select City")
                            .font(FeastTheme.Typography.listTitle)
                            .foregroundStyle(FeastTheme.Colors.primaryText)
                            .lineLimit(1)
                            .minimumScaleFactor(0.82)

                        Image(systemName: "chevron.down")
                            .font(FeastTheme.Typography.caption.weight(.semibold))
                            .foregroundStyle(FeastTheme.Colors.secondaryText)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .buttonStyle(.plain)

                Text(citySummaryText)
                    .font(FeastTheme.Typography.rowMetadata)
                    .foregroundStyle(citySummaryColor)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
            }

            Spacer(minLength: 0)

            VStack(alignment: .trailing, spacing: FeastTheme.Spacing.small) {
                Button {
                    showingExploreSearch = true
                } label: {
                    Label("Search", systemImage: "magnifyingglass")
                }
                .buttonStyle(FeastQuietChipButtonStyle())
                .disabled(selectedFeastList == nil)
                .accessibilityLabel("Search Apple Maps")

                Button {
                    presentSavedPlaceFilters()
                } label: {
                    Label(
                        "Filters",
                        systemImage: hasActiveSavedPlaceFilters
                            ? "line.3.horizontal.decrease.circle.fill"
                            : "line.3.horizontal.decrease.circle"
                    )
                }
                .buttonStyle(FeastQuietChipButtonStyle())
                .disabled(selectedFeastList == nil)
            }
        }
        .padding(.horizontal, FeastTheme.Spacing.large)
        .padding(.vertical, FeastTheme.Spacing.medium)
        .feastMapOverlayCard(cornerRadius: FeastTheme.CornerRadius.medium)
    }

    private var mapContent: some View {
        ZStack {
            Map(position: $cameraPosition, selection: $selectedMarker) {
                ForEach(filteredMarkerItems) { marker in
                    Marker(marker.markerLabel, coordinate: marker.coordinate.clLocationCoordinate2D)
                        .tint(FeastTheme.Colors.mapPinTint)
                        .tag(marker)
                }
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

            if filteredMarkerItems.isEmpty && !isResolvingMarkers {
                if shouldShowNoMatchingResults {
                    ContentUnavailableView {
                        Label("No Matching Places", systemImage: "line.3.horizontal.decrease.circle")
                    } description: {
                        Text(noMatchingResultsText)
                    } actions: {
                        Button("Clear All") {
                            clearSavedPlaceFilters()
                        }
                        .buttonStyle(FeastQuietChipButtonStyle())
                    }
                    .padding(FeastTheme.Spacing.large)
                    .feastMapOverlayCard(cornerRadius: FeastTheme.CornerRadius.medium)
                    .padding(.horizontal, FeastTheme.Spacing.large)
                } else {
                    ContentUnavailableView {
                        Label("No Places in This City Yet", systemImage: "mappin.and.ellipse")
                    } description: {
                        Text(emptyStateText)
                    } actions: {
                        if selectedFeastList != nil {
                            Button("Search Apple Maps") {
                                showingExploreSearch = true
                            }
                            .buttonStyle(FeastProminentButtonStyle())
                        }
                    }
                    .padding(FeastTheme.Spacing.large)
                    .feastMapOverlayCard(cornerRadius: FeastTheme.CornerRadius.medium)
                    .padding(.horizontal, FeastTheme.Spacing.large)
                }
            }

            if isResolvingMarkers {
                HStack(spacing: FeastTheme.Spacing.small) {
                    ProgressView()
                    Text("Loading places")
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
            return "Search Apple Maps and save places into this city to start building the map."
        }

        if shouldShowNoMatchingResults {
            return "No saved places match these filters."
        }

        if hasActiveSavedPlaceFilters {
            let unresolvedFilteredCount = max(filteredSavedCount - mappedCount, 0)

            if unresolvedFilteredCount > 0 {
                return "\(mappedCount) of \(filteredSavedCount) matching saved places mapped"
            }

            if mappedCount == 0 {
                return "Matching saved places will appear here once Apple Maps can resolve them."
            }

            return "\(mappedCount) matching saved places on the map"
        }

        if unresolvedPlaceCount > 0 {
            return "\(mappedCount) of \(savedCount) saved places mapped"
        }

        if mappedCount == 0 {
            return "Saved places in this city will appear here once Apple Maps can resolve them."
        }

        return "\(mappedCount) saved places on the map"
    }

    private var emptyStateText: String {
        if selectedCitySavedPlaces.isEmpty {
            return "Search Apple Maps and save places into \(selectedFeastList?.displayName ?? "this city") to see them on the map."
        }

        if hasActiveSavedPlaceFilters {
            return "Feast could not resolve any matching saved places for this city in Apple Maps right now."
        }

        return "Feast could not resolve any saved places for this city in Apple Maps right now."
    }

    private var shouldShowNoMatchingResults: Bool {
        hasActiveSavedPlaceFilters
            && !selectedCitySavedPlaces.isEmpty
            && filteredCitySavedPlaces.isEmpty
    }

    private var noMatchingResultsText: String {
        "Try a different search, status, or tag for \(selectedFeastList?.displayName ?? "this city")."
    }

    @MainActor
    private func resolveMarkers() async {
        if selectedFeastList == nil, let firstList = feastLists.first {
            selectedFeastListURI = uriString(for: firstList)
        }

        let places = selectedCitySavedPlaces

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
                if let resolvedPlace = try await applePlacesService.resolve(placeID: applePlaceID),
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

    private func presentSavedPlaceFilters() {
        draftSavedPlaceFilters = savedPlaceFilters
        showingSavedPlaceFilters = true
    }

    private func applyDraftSavedPlaceFilters() {
        savedPlaceFilters = draftSavedPlaceFilters
    }

    private func clearSavedPlaceFilters() {
        savedPlaceFilters.reset()
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

private struct MapSavedPlaceFilters: Equatable {
    var queryText = ""
    var selectedStatuses: Set<PlaceStatus> = []
    var selectedTags: Set<String> = []

    var hasActiveFilters: Bool {
        !queryText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || !selectedStatuses.isEmpty
            || !selectedTags.isEmpty
    }

    mutating func reset() {
        self = .init()
    }

    mutating func toggle(_ status: PlaceStatus) {
        if selectedStatuses.contains(status) {
            selectedStatuses.remove(status)
        } else {
            selectedStatuses.insert(status)
        }
    }

    mutating func toggleTag(_ tag: String) {
        guard let normalizedKey = FeastTag.normalizedKey(for: tag) else {
            return
        }

        if let existingTag = selectedTags.first(where: { FeastTag.normalizedKey(for: $0) == normalizedKey }) {
            selectedTags.remove(existingTag)
        } else if let displayTag = FeastTag.normalizedDisplay(tag) {
            selectedTags.insert(displayTag)
        }
    }

    func includesTag(_ tag: String) -> Bool {
        guard let normalizedKey = FeastTag.normalizedKey(for: tag) else {
            return false
        }

        return selectedTags.contains { FeastTag.normalizedKey(for: $0) == normalizedKey }
    }

    static func sheetTags(availableTags: [String], selectedTags: Set<String>) -> [String] {
        var visibleTags: [String] = []
        var seenKeys: Set<String> = []

        for tag in selectedTags.sorted(by: localizedAscending) + availableTags {
            guard
                let displayTag = FeastTag.normalizedDisplay(tag),
                let normalizedKey = FeastTag.normalizedKey(for: displayTag),
                !seenKeys.contains(normalizedKey)
            else {
                continue
            }

            seenKeys.insert(normalizedKey)
            visibleTags.append(displayTag)
        }

        return visibleTags
    }

    nonisolated private static func localizedAscending(_ lhs: String, _ rhs: String) -> Bool {
        lhs.localizedCaseInsensitiveCompare(rhs) == .orderedAscending
    }
}

private enum MapSavedPlaceFilterEngine {
    static func filteredPlaces(
        from places: [SavedPlace],
        filters: MapSavedPlaceFilters
    ) -> [SavedPlace] {
        let queryTokens = normalizedTokens(in: filters.queryText)
        let selectedTagKeys = Set(filters.selectedTags.compactMap { FeastTag.normalizedKey(for: $0) })

        return places.filter { place in
            matchesStatus(place, selectedStatuses: filters.selectedStatuses)
                && matchesTags(place, selectedTagKeys: selectedTagKeys)
                && matchesQuery(place, queryTokens: queryTokens)
        }
    }

    private static func matchesStatus(
        _ place: SavedPlace,
        selectedStatuses: Set<PlaceStatus>
    ) -> Bool {
        selectedStatuses.isEmpty || selectedStatuses.contains(place.placeStatus)
    }

    private static func matchesTags(
        _ place: SavedPlace,
        selectedTagKeys: Set<String>
    ) -> Bool {
        guard !selectedTagKeys.isEmpty else {
            return true
        }

        return place.tags.contains { tag in
            guard let normalizedKey = FeastTag.normalizedKey(for: tag) else {
                return false
            }

            return selectedTagKeys.contains(normalizedKey)
        }
    }

    private static func matchesQuery(
        _ place: SavedPlace,
        queryTokens: [String]
    ) -> Bool {
        guard !queryTokens.isEmpty else {
            return true
        }

        let searchableText = searchableFields(for: place)
            .joined(separator: " ")
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)

        return queryTokens.allSatisfy { searchableText.contains($0) }
    }

    private static func searchableFields(for place: SavedPlace) -> [String] {
        [
            place.displayName,
            place.displayNeighborhoodName,
            place.note,
            place.placeStatus.rawValue,
            place.placeTypeValue.rawValue
        ]
        .compactMap { normalized($0) }
        + place.tags
        + place.cuisines
    }

    private static func normalizedTokens(in query: String) -> [String] {
        query
            .split(whereSeparator: \.isWhitespace)
            .map(String.init)
            .compactMap(normalized)
    }

    nonisolated private static func normalized(_ value: String?) -> String? {
        guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else {
            return nil
        }

        return trimmed.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
    }
}

private struct MapSavedPlaceFilterSheet: View {
    @Environment(\.dismiss) private var dismiss

    @Binding var filters: MapSavedPlaceFilters

    let availableTags: [String]
    let cityName: String
    let onApply: () -> Void

    private let statuses = Array(PlaceStatus.allCases.enumerated())

    var body: some View {
        List {
            searchSection
            statusSection
            tagsSection
        }
        .feastScrollableChrome()
        .listStyle(.insetGrouped)
        .navigationTitle("Filters")
        .navigationBarTitleDisplayMode(.inline)
        .safeAreaInset(edge: .bottom) {
            footerActions
        }
    }

    private var visibleTags: [String] {
        MapSavedPlaceFilters.sheetTags(
            availableTags: availableTags,
            selectedTags: filters.selectedTags
        )
    }

    private var searchSection: some View {
        Section {
            FeastFormGroup {
                FeastFormField(
                    title: "Search saved places",
                    helper: "Search only within \(cityName)'s saved places."
                ) {
                    FeastSingleLineTextField(
                        placeholder: "Name, neighborhood, note, tag, cuisine, or type",
                        text: $filters.queryText,
                        textInputAutocapitalization: .never,
                        autocorrectionDisabled: true
                    )
                }
            }
        }
    }

    private var statusSection: some View {
        Section {
            FeastFormGroup {
                ForEach(statuses, id: \.element.id) { index, status in
                    MapSavedPlaceFilterRow(
                        title: status.rawValue,
                        isSelected: filters.selectedStatuses.contains(status)
                    ) {
                        filters.toggle(status)
                    }

                    if index < statuses.count - 1 {
                        FeastFormDivider()
                    }
                }
            }
        } header: {
            FeastFormSectionHeader(
                title: "Status",
                subtitle: "Choose one or more saved-place statuses."
            )
        }
    }

    private var tagsSection: some View {
        Section {
            FeastFormGroup {
                if visibleTags.isEmpty {
                    Text("No tags available yet")
                        .font(FeastTheme.Typography.supporting.weight(.semibold))
                        .foregroundStyle(FeastTheme.Colors.secondaryText)
                        .frame(maxWidth: .infinity, alignment: .leading)
                } else {
                    ForEach(Array(visibleTags.enumerated()), id: \.element) { index, tag in
                        MapSavedPlaceFilterRow(
                            title: tag,
                            isSelected: filters.includesTag(tag)
                        ) {
                            filters.toggleTag(tag)
                        }

                        if index < visibleTags.count - 1 {
                            FeastFormDivider()
                        }
                    }
                }
            }
        } header: {
            FeastFormSectionHeader(
                title: "Tags",
                subtitle: "Choose reusable tags already attached to saved places in this city."
            )
        }
    }

    private var footerActions: some View {
        HStack(spacing: FeastTheme.Spacing.medium) {
            Button("Clear All") {
                filters.reset()
            }
            .buttonStyle(FeastQuietChipButtonStyle())
            .disabled(!filters.hasActiveFilters)

            Spacer(minLength: 0)

            Button {
                onApply()
                dismiss()
            } label: {
                Text("Done")
                    .frame(minWidth: 96)
            }
            .buttonStyle(FeastProminentButtonStyle())
        }
        .feastBottomBarChrome()
    }
}

private struct MapSavedPlaceFilterRow: View {
    let title: String
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: FeastTheme.Spacing.small) {
                Text(title)
                    .font(FeastTheme.Typography.supporting)
                    .foregroundStyle(FeastTheme.Colors.primaryText)

                Spacer(minLength: 0)

                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(
                        isSelected
                            ? FeastTheme.Colors.accentSelection
                            : FeastTheme.Colors.tertiaryText
                    )
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

#Preview {
    FeastPreviewContainer {
        NavigationStack {
            MapRootView()
        }
    }
}
