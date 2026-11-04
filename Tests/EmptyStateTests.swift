import CoreData
import Foundation

@MainActor enum EmptyStateTests {
    static func run(model: NSManagedObjectModel) throws {
        let coordinator = NSPersistentStoreCoordinator(managedObjectModel: model)
        try coordinator.addPersistentStore(ofType: NSInMemoryStoreType, configurationName: nil, at: nil)
        let context = NSManagedObjectContext(concurrencyType: .mainQueueConcurrencyType)
        context.persistentStoreCoordinator = coordinator
        let city = FeastList(context: context); city.id = UUID(); city.name = "Synthetic City"
        let emptyCity = FeastList(context: context); emptyCity.id = UUID(); emptyCity.name = "Empty City"
        let otherCity = FeastList(context: context); otherCity.id = UUID(); otherCity.name = "Another City"
        let cafe = SavedPlace(context: context); cafe.id = UUID(); cafe.feastList = city
        cafe.displayNameSnapshot = "Cafe"; cafe.placeStatus = .been; cafe.placeTypeValue = .cafe; cafe.tags = ["Quiet"]; cafe.cuisines = ["French"]
        let dinner = SavedPlace(context: context); dinner.id = UUID(); dinner.feastList = city
        dinner.displayNameSnapshot = "Dinner"; dinner.placeStatus = .love
        let outside = SavedPlace(context: context); outside.id = UUID(); outside.feastList = otherCity
        outside.displayNameSnapshot = "Cafe"; outside.placeStatus = .love
        try context.save()
        let all = [cafe, dinner, outside]
        var filters = SavedPlaceSearchFilters()
        filters.selectedListURIString = city.objectURIString
        precondition(SavedPlaceEmptyReason.evaluate(places: [], filters: filters) == .emptyScope)
        var emptyFilters = filters; emptyFilters.selectedListURIString = emptyCity.objectURIString
        emptyFilters.queryText = "Cafe"; emptyFilters.selectedStatuses = [.love]
        precondition(SavedPlaceEmptyReason.evaluate(places: all, filters: emptyFilters) == .emptyScope)
        filters.queryText = "Cafe"; filters.selectedStatuses = [.love]
        precondition(SavedPlaceEmptyReason.evaluate(places: all, filters: filters) == .filtersHideMatches)
        precondition(SavedPlaceEmptyReason.evaluate(places: all, filters: filters, fixedCity: city) == .filtersHideMatches)
        filters.queryText = "No such place"
        precondition(SavedPlaceEmptyReason.evaluate(places: all, filters: filters) == .queryHasNoMatches)
        filters.clearFiltersKeepingScopeAndQuery()
        precondition(SavedPlaceEmptyReason.evaluate(places: all, filters: filters) == .queryHasNoMatches)
        filters.queryText = ""
        precondition(SavedPlaceEmptyReason.evaluate(places: all, filters: filters) == .hasMatches)
        print("PASS empty-state reasons distinguish genuinely empty scope, query misses and filters hiding query matches")

        let browse = SavedPlaceBrowseState()
        browse.filters.selectedListURIString = city.objectURIString
        browse.filters.queryText = " Cafe "
        browse.filters.selectedStatuses = [.love]
        browse.filters.selectedTags = ["Absent"]
        browse.filters.selectedPlaceType = .bar
        browse.filters.selectedCuisine = "Italian"
        browse.scopeDidChange()
        let previousPath = browse.citiesPath
        browse.selectedTab = 1
        browse.filters.clearFiltersKeepingScopeAndQuery()
        precondition(browse.filters.selectedListURIString == city.objectURIString && browse.filters.queryText == " Cafe ")
        precondition(!browse.filters.hasContentFilters && browse.citiesPath == previousPath)
        let IDs = SavedPlaceSearchEngine.matchingPlaceIDs(from: all, filters: browse.filters)
        precondition(IDs == [cafe.objectID] && !IDs.contains(outside.objectID))
        browse.selectedTab = 0
        precondition(SavedPlaceEmptyReason.evaluate(places: all, filters: browse.filters) == .hasMatches)
        browse.filters.queryText = "No such place"; browse.filters.selectedStatuses = [.love]
        browse.filters.clearFiltersKeepingScopeAndQuery()
        precondition(SavedPlaceEmptyReason.evaluate(places: all, filters: browse.filters) == .queryHasNoMatches)
        browse.filters.selectedStatuses = [.love]
        browse.filters.queryText = "" // Separate Clear Search action leaves content filters alone.
        precondition(browse.filters.selectedStatuses == [.love] && browse.filters.selectedListURIString == city.objectURIString)
        precondition(SavedPlaceSearchEngine.matchingPlaceIDs(from: all, filters: browse.filters) == [dinner.objectID])
        precondition(!context.hasChanges)
        print("PASS Clear Filters retains exact query/city across list-map transitions; Clear Search is separate; no data mutations")

        precondition(SavedMapEmptyPresentation.evaluate(reason: .hasMatches, resolving: true, pinCount: 0) == .loading)
        precondition(SavedMapEmptyPresentation.evaluate(reason: .hasMatches, resolving: false, pinCount: 0) == .locationsUnavailable)
        precondition(SavedMapEmptyPresentation.evaluate(reason: .hasMatches, resolving: true, pinCount: 1) == .hasPins)
        precondition(SavedMapEmptyPresentation.evaluate(reason: .filtersHideMatches, resolving: true, pinCount: 0) == .savedContent(.filtersHideMatches))
        precondition(SavedMapEmptyPresentation.evaluate(reason: .emptyScope, resolving: false, pinCount: 0) == .savedContent(.emptyScope))
        print("PASS map distinguishes loading, unavailable locations, partial pins and saved-content empty states")
    }
}
