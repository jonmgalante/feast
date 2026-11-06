import CoreData
import Foundation

@MainActor enum CityFilteredPlaceGroupsTests {
    static func run(model: NSManagedObjectModel) throws {
        let coordinator = NSPersistentStoreCoordinator(managedObjectModel: model)
        let privateStore = try coordinator.addPersistentStore(ofType: NSInMemoryStoreType, configurationName: nil, at: nil)
        let sharedStore = try coordinator.addPersistentStore(ofType: NSInMemoryStoreType, configurationName: nil, at: nil)
        let context = NSManagedObjectContext(concurrencyType: .mainQueueConcurrencyType)
        context.persistentStoreCoordinator = coordinator

        func city(_ name: String, store: NSPersistentStore) -> FeastList {
            let value = FeastList(context: context); value.id = UUID(); value.name = name
            context.assign(value, to: store)
            return value
        }
        func section(_ name: String?, city: FeastList, store: NSPersistentStore) -> ListSection {
            let value = ListSection(context: context); value.name = name; value.feastList = city
            context.assign(value, to: store)
            return value
        }
        let london = city("London", store: privateStore)
        let sharedLondon = city("London", store: sharedStore)
        sharedLondon.id = london.id // IDs/names are not safe grouping or scope keys.
        let nyc = city("NYC", store: privateStore)
        let first = section("Soho", city: london, store: privateStore)
        let second = section("Soho", city: london, store: privateStore)
        first.id = UUID(); second.id = first.id
        let empty = section(nil, city: london, store: privateStore)
        let nested = section("Legacy child", city: london, store: privateStore); nested.parent = first
        let unavailable = section("Not in visible fetch", city: london, store: privateStore)
        let foreign = section("Foreign", city: nyc, store: privateStore)
        let sharedSection = section("Soho", city: sharedLondon, store: sharedStore)
        sharedSection.id = first.id

        func place(_ name: String, city: FeastList, section: ListSection?, status: PlaceStatus,
                   type: PlaceType, tags: [String], cuisine: String, updated: Double,
                   store: NSPersistentStore = privateStore) -> SavedPlace {
            let value = SavedPlace(context: context)
            value.displayNameSnapshot = name; value.applePlaceID = UUID().uuidString
            value.feastList = city; value.listSection = section; value.placeStatus = status
            value.placeTypeValue = type; value.tags = tags; value.cuisines = [cuisine]
            value.updatedAt = Date(timeIntervalSince1970: updated)
            value.note = "Synthetic café note"; value.websiteURL = "https://example.invalid/unique-link"
            context.assign(value, to: store)
            return value
        }
        let a = place("A newer", city: london, section: first, status: .love, type: .cafe, tags: ["Quiet"], cuisine: "Italian", updated: 90)
        let b = place("B older", city: london, section: first, status: .been, type: .restaurant, tags: ["Group"], cuisine: "French", updated: 20)
        let c = place("C same time", city: london, section: second, status: .love, type: .cafe, tags: ["Quiet"], cuisine: "Italian", updated: 90)
        let unassigned = place("Unsorted", city: london, section: nil, status: .regulars, type: .cafe, tags: ["Quiet"], cuisine: "Coffee", updated: 80)
        let legacy = place("Legacy", city: london, section: nested, status: .love, type: .restaurant, tags: ["Group"], cuisine: "Italian", updated: 70)
        let pending = place("Pending section", city: london, section: unavailable, status: .been, type: .cafe, tags: ["Quiet"], cuisine: "French", updated: 60)
        let mismatched = place("Foreign assignment", city: london, section: foreign, status: .wantToTry, type: .restaurant, tags: [], cuisine: "Italian", updated: 50)
        let otherCity = place("NYC match", city: nyc, section: foreign, status: .love, type: .cafe, tags: ["Quiet"], cuisine: "Italian", updated: 100)
        let sharedPlace = place("Shared match", city: sharedLondon, section: sharedSection, status: .love, type: .cafe, tags: ["Quiet"], cuisine: "Italian", updated: 110, store: sharedStore)
        try context.save()
        let all = [a, b, c, unassigned, legacy, pending, mismatched, otherCity, sharedPlace]
        let visible = [second, empty, first] // Preserve the supplied fetch order, even with duplicate labels/UUIDs.

        func snapshot() -> NSDictionary {
            var values: [String: NSDictionary] = [:]
            for object in context.registeredObjects {
                var fields = object.dictionaryWithValues(forKeys: Array(object.entity.attributesByName.keys))
                for (key, relationship) in object.entity.relationshipsByName {
                    if relationship.isToMany {
                        fields[key] = ((object.value(forKey: key) as? Set<NSManagedObject>) ?? [])
                            .map { $0.objectID.uriRepresentation().absoluteString }.sorted()
                    } else {
                        fields[key] = (object.value(forKey: key) as? NSManagedObject)?.objectID.uriRepresentation().absoluteString ?? "nil"
                    }
                }
                values[object.objectID.uriRepresentation().absoluteString] = fields as NSDictionary
            }
            return values as NSDictionary
        }
        let before = snapshot()
        func verify(_ matches: [SavedPlace], sections: [ListSection]) -> CityFilteredPlaceGroups {
            let groups = CityFilteredPlaceGroups(matchingPlaces: matches, neighborhoods: sections)
            let rendered = groups.neighborhoods.flatMap(\.places) + groups.unsorted + groups.otherMatches
            precondition(rendered.count == matches.count)
            precondition(Set(rendered.map(\.objectID)) == Set(matches.map(\.objectID)))
            precondition(Set(rendered.map(\.objectID)).count == rendered.count)
            precondition(groups.neighborhoods.map(\.id) == sections.filter { s in matches.contains { $0.listSection?.objectID == s.objectID } }.map(\.objectID))
            for group in groups.neighborhoods {
                precondition(!group.places.isEmpty)
                precondition(group.places.map(\.objectID) == matches.filter { $0.listSection?.objectID == group.id }.map(\.objectID))
            }
            precondition(groups.unsorted.map(\.objectID) == matches.filter { $0.listSection == nil }.map(\.objectID))
            return groups
        }

        var combinations = 0
        for statuses: Set<PlaceStatus> in [[], Set(PlaceStatus.allCases), [.love], [.love, .been], [.justOpened]] {
            for type: PlaceType? in [nil, .cafe, .restaurant] {
                for tags: Set<String> in [[], ["quiet"], ["Quiet", "Group"], ["Absent"]] {
                    for cuisine: String? in [nil, "french", "Italian", "Absent"] {
                        for query in ["", "CAFÉ", "soho", "unique-link", "absent", "café quiet", "  "] {
                            var filters = SavedPlaceSearchFilters()
                            filters.selectedStatuses = statuses; filters.selectedPlaceType = type
                            filters.selectedTags = tags; filters.selectedCuisine = cuisine; filters.queryText = query
                            filters.selectedListURIString = nyc.objectURIString // Fixed city wins, as before.
                            let matches = SavedPlaceSearchEngine.filteredPlaces(from: all, query: query, filters: filters, fixedFeastList: london)
                            let groups = verify(matches, sections: visible)
                            precondition(!groups.neighborhoods.flatMap(\.places).contains(otherCity))
                            precondition(matches.allSatisfy { $0.feastList?.objectID == london.objectID })
                            combinations += 1
                        }
                    }
                }
            }
        }
        print("PASS city filtered groups preserve every match, counts and order across \(combinations) status/type/tag/cuisine/query combinations")

        let cityMatches = SavedPlaceSearchEngine.filteredPlaces(from: all, query: "", filters: .init(), fixedFeastList: london)
        let groups = verify(cityMatches, sections: visible)
        precondition(groups.neighborhoods.map(\.id) == [second.objectID, first.objectID])
        precondition(groups.neighborhoods[1].places.map(\.objectID) == [a.objectID, b.objectID])
        precondition(groups.unsorted.map(\.objectID) == [unassigned.objectID])
        precondition(groups.otherMatches.map(\.objectID) == [legacy.objectID, pending.objectID, mismatched.objectID])
        precondition(verify([], sections: visible).neighborhoods.isEmpty)
        precondition(verify(cityMatches, sections: []).otherMatches.count == 6)
        print("PASS duplicate and missing neighborhood IDs/names, empty groups, Unsorted and legacy/unavailable/foreign assignment fallback")

        let sharedMatches = SavedPlaceSearchEngine.filteredPlaces(from: all, query: "", filters: .init(), fixedFeastList: sharedLondon)
        let sharedGroups = verify(sharedMatches, sections: [sharedSection])
        precondition(sharedGroups.neighborhoods.count == 1 && sharedGroups.neighborhoods[0].places.map(\.objectID) == [sharedPlace.objectID])
        var searchOnly = SavedPlaceSearchFilters(); searchOnly.queryText = "café"
        precondition(searchOnly.hasCriteria && !searchOnly.hasContentFilters)
        searchOnly.selectedListURIString = london.objectURIString
        precondition(!searchOnly.hasContentFilters)
        let global = SavedPlaceSearchEngine.filteredPlaces(from: all, query: "", filters: .init())
        precondition(global.count == all.count && global.first == sharedPlace)
        precondition(!context.hasChanges && snapshot().isEqual(before))
        print("PASS distinct private/shared-store object identity, fixed-city scope, search-only gate, cross-city matches and unchanged attributes/relationships")
    }
}
