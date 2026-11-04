import CoreData
import Foundation

@MainActor enum BrowsingConsistencyTests {
    static func run(model: NSManagedObjectModel) async throws {
        let coordinator = NSPersistentStoreCoordinator(managedObjectModel: model)
        try coordinator.addPersistentStore(ofType: NSInMemoryStoreType, configurationName: nil, at: nil)
        let context = NSManagedObjectContext(concurrencyType: .mainQueueConcurrencyType)
        context.persistentStoreCoordinator = coordinator
        let london = FeastList(context: context); london.id = UUID(); london.name = "London"
        let nyc = FeastList(context: context); nyc.id = UUID(); nyc.name = "NYC"
        let section = ListSection(context: context); section.id = UUID(); section.name = "Soho"; section.feastList = london
        func place(_ city: FeastList, name: String, status: PlaceStatus, type: PlaceType, tags: [String], cuisine: String) -> SavedPlace {
            let value = SavedPlace(context: context); value.id = UUID(); value.displayNameSnapshot = name
            value.feastList = city; value.placeStatus = status; value.placeTypeValue = type
            value.tags = tags; value.cuisines = [cuisine]; value.note = "Synthetic coffee note"
            value.websiteURL = "https://example.invalid/unique-link"; value.applePlaceID = UUID().uuidString
            value.updatedAt = Date(); return value
        }
        let cafe = place(london, name: "Café One", status: .love, type: .cafe, tags: ["Quiet"], cuisine: "French")
        cafe.listSection = section
        let restaurant = place(london, name: "Dinner", status: .been, type: .restaurant, tags: ["Group"], cuisine: "Italian")
        let otherCity = place(nyc, name: "Café NYC", status: .love, type: .cafe, tags: ["Quiet"], cuisine: "French")
        try context.save()
        let places = [cafe, restaurant, otherCity]
        var criteria = SavedPlaceSearchFilters()
        criteria.selectedListURIString = london.objectURIString
        criteria.queryText = "CAFE soho unique-link"
        criteria.selectedStatuses = [.love, .regulars]
        criteria.selectedTags = ["quiet", "Unmatched"]
        criteria.selectedPlaceType = .cafe
        criteria.selectedCuisine = "french"
        let listIDs = Set(SavedPlaceSearchEngine.filteredPlaces(from: places, query: criteria.queryText, filters: criteria, fixedFeastList: london).map(\.objectID))
        let mapIDs = SavedPlaceSearchEngine.matchingPlaceIDs(from: places, filters: criteria)
        precondition(listIDs == [cafe.objectID] && mapIDs == listIDs)
        for statuses: Set<PlaceStatus> in [[], [.love], [.love, .been], [.regulars]] {
            for type: PlaceType? in [nil, .cafe, .restaurant] {
                for tags: Set<String> in [[], ["quiet"], ["Quiet", "Group"], ["Absent"]] {
                    var combination = SavedPlaceSearchFilters()
                    combination.selectedStatuses = statuses; combination.selectedPlaceType = type; combination.selectedTags = tags
                    let expected = Set(places.filter { p in
                        (statuses.isEmpty || statuses.contains(p.placeStatus)) && (type == nil || p.placeTypeValue == type) &&
                        (tags.isEmpty || p.tags.contains { actual in tags.contains { $0.lowercased() == actual.lowercased() } })
                    }.map(\.objectID))
                    precondition(SavedPlaceSearchEngine.matchingPlaceIDs(from: places, filters: combination) == expected)
                }
            }
        }
        print("PASS list/map matching-ID parity across city, neighborhood/query, multiple statuses/tags, type and cuisine")

        let browse = SavedPlaceBrowseState()
        browse.filters = criteria
        browse.scopeDidChange()
        precondition(browse.citiesPath == [.city(london.objectURIString)])
        browse.filters.selectedListURIString = nyc.objectURIString; browse.scopeDidChange()
        precondition(browse.citiesPath == [.city(nyc.objectURIString)] && browse.filters.queryText == criteria.queryText)
        let previous = browse.citiesPath
        browse.citiesPath = [.city(london.objectURIString)]; browse.pathDidChange(from: previous)
        precondition(browse.filters.selectedListURIString == london.objectURIString)
        let editorPath: [SavedPlaceBrowseRoute] = [.city(london.objectURIString), .place(cafe.objectID.uriRepresentation().absoluteString)]
        browse.citiesPath = editorPath
        browse.filters.selectedListURIString = nyc.objectURIString; browse.scopeDidChange()
        precondition(browse.citiesPath == editorPath) // Do not pop/recreate the live editor or its @State draft.
        browse.citiesPath = [.city(london.objectURIString)]; browse.pathDidChange(from: editorPath)
        precondition(browse.citiesPath == [.city(nyc.objectURIString)])
        browse.citiesPath = []; browse.pathDidChange(from: [.city(nyc.objectURIString)])
        precondition(browse.filters.selectedListURIString == nil)
        browse.filters.selectedListURIString = "deleted-city"
        browse.validateCities([nyc.objectURIString, london.objectURIString])
        precondition(browse.filters.selectedListURIString == nil && browse.filters.queryText == criteria.queryText)
        let global = SavedPlaceSearchEngine.matchingPlaceIDs(from: places, filters: .init())
        precondition(global.count == 3)
        print("PASS two-way city transitions, All Cities, deleted-city fallback and deferred navigation while an editor is open")

        let committed = browse.filters
        var draft = committed
        draft.queryText = "Different"; draft.selectedStatuses = [.been]
        precondition(browse.filters == committed) // Cancel/dismiss discards this uncommitted value.
        browse.filters = draft // Done commits the complete value once.
        browse.filters.selectedListURIString = london.objectURIString
        browse.filters.reset()
        precondition(!browse.filters.hasCriteria && browse.filters.selectedListURIString == london.objectURIString)
        print("PASS staged filter cancellation, atomic Done and Reset preserving city scope")

        let viewport = SavedMapViewport(latitude: 1, longitude: 2, latitudeDelta: 3, longitudeDelta: 4)
        browse.viewports[london.objectURIString] = viewport
        browse.scrollAnchors[london.objectURIString] = cafe.objectID.uriRepresentation().absoluteString
        browse.filters.selectedListURIString = nyc.objectURIString; browse.scopeDidChange()
        browse.filters.selectedListURIString = london.objectURIString; browse.scopeDidChange()
        precondition(browse.viewports[browse.scopeKey] == viewport)
        precondition(browse.scrollAnchors[browse.scopeKey] == cafe.objectID.uriRepresentation().absoluteString)
        let savedBeforeDiscovery = browse.filters
        var discoveryQueries: [String] = []
        // Discovery accepts its own destination/query, not the saved-place criteria.
        let discovered = try await PlaceSearchContext.search("Il Buco", cityName: "NYC") { query in
            discoveryQueries.append(query)
            return []
        }
        precondition(discovered.isEmpty && discoveryQueries == ["Il Buco, NYC", "Il Buco"] && browse.filters == savedBeforeDiscovery)
        // A matching place without a resolved coordinate stays in list results.
        precondition(SavedPlaceSearchEngine.matchingPlaceIDs(from: places, filters: .init()).contains(restaurant.objectID))
        let resolvedIDs: Set<NSManagedObjectID> = [cafe.objectID, otherCity.objectID]
        precondition(SavedPlaceSearchEngine.mappedPlaceIDs(from: places, filters: .init(), resolvedIDs: resolvedIDs) == resolvedIDs)
        print("PASS session scroll/viewport retention, discovery criteria separation and missing-coordinate list retention")
    }

}
