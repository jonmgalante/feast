import CoreData
import Foundation
import Combine

/// A separate collection for the optional mock sheet. Never inherits the app's context.
@MainActor final class AskPrototypeSandbox: ObservableObject {
    let container: NSPersistentContainer
    let repository: FeastRepository
    private let visibleCities: Set<UUID>
    private var originals: [UUID: (String, [AskAuthoredNote])] = [:]
    private var localAuthoredTexts: [UUID: String] = [:]

    init(model: NSManagedObjectModel? = nil) throws {
        guard let model = model ?? NSManagedObjectModel.mergedModel(from: [Bundle.main]) else { throw AskError.invalidEvidence }
        container = NSPersistentContainer(name: "FeastDataModel", managedObjectModel: model)
        let store = NSPersistentStoreDescription()
        store.type = NSInMemoryStoreType
        store.shouldAddStoreAsynchronously = false
        container.persistentStoreDescriptions = [store]
        var loadError: Error?
        container.loadPersistentStores { _, error in loadError = error }
        if let loadError { throw loadError }
        repository = FeastRepository(context: container.viewContext)
        let city = try repository.createFeastList(named: "NYC · synthetic shared city")
        let london = try repository.createFeastList(named: "London · synthetic")
        let hidden = try repository.createFeastList(named: "Private City · inaccessible fixture")
        visibleCities = [city.id!, london.id!]
        let section = try repository.createListSection(named: "Upper East Side", in: city)
        for record in AskFixtures.records {
            let note = record.notes.map { "\($0.author): \($0.text)" }.joined(separator: "\n\n")
            let place = try repository.createSavedPlace(from: .init(
                applePlaceID: record.id == "kiku" ? "mock-kiku-ues" : "mock-" + record.id,
                displayNameSnapshot: record.name, status: .wantToTry, placeType: .restaurant,
                cuisines: [record.cuisine], tags: [], note: note, websiteURL: nil, instagramURL: nil,
                feastList: record.cityID == "shared-nyc" ? city : hidden, listSection: record.cityID == "shared-nyc" ? section : nil))
            originals[place.id!] = (note, record.notes)
        }
    }
    var context: NSManagedObjectContext { container.viewContext }
    func cities() throws -> [FeastList] { try repository.fetchFeastLists().filter { $0.id.map(visibleCities.contains) ?? false } }
    func localIndex() throws -> AskLocalIndex {
        // Predicate the read itself by current access; do not send all fetched records to a provider.
        let request = SavedPlace.fetchRequest()
        request.predicate = NSPredicate(format: "feastList.id IN %@", Array(visibleCities) as NSArray)
        request.fetchLimit = 200
        request.sortDescriptors = [NSSortDescriptor(key: "displayNameSnapshot", ascending: true)]
        let places = try context.fetch(request)
        var allowedNotes: Set<String> = []
        let records = places.compactMap { place -> AskCollectionRecord? in
            guard let id = place.id, let cityID = place.feastList?.id, visibleCities.contains(cityID) else { return nil }
            let notes: [AskAuthoredNote]
            if let original = originals[id], place.note == original.0 {
                notes = original.1
            } else {
                notes = [.init(id: "note-" + id.uuidString, author: localAuthoredTexts[id] != nil && localAuthoredTexts[id] == place.note ? "You · synthetic reviewed save" : "Author unknown", text: place.note ?? "")]
            }
            allowedNotes.formUnion(notes.map(\.id))
            var record = AskCollectionRecord(id: id.uuidString, cityID: cityID.uuidString, city: place.displayCityName,
                name: place.displayName, neighborhood: place.listSection?.displayName ?? "See attributed notes; neighborhood unverified",
                cuisine: place.cuisines.joined(separator: ", "), status: place.placeStatus.rawValue, notes: notes)
            record.address = AskFixtures.mapOptions.first { $0.id == place.applePlaceIDValue }?.address
            return record
        }
        return .init(records: records, visibleCityIDs: Set(visibleCities.map(\.uuidString)), visibleNoteIDs: allowedNotes)
    }
    /// Resolve only a currently visible, unique model UUID from this isolated store.
    func savedRecord(id rawID: String) throws -> AskCollectionRecord {
        guard let id = UUID(uuidString: rawID) else { throw AskError.invalidEvidence }
        let request = SavedPlace.fetchRequest()
        request.predicate = NSPredicate(format: "id == %@ AND feastList.id IN %@", id as NSUUID, Array(visibleCities) as NSArray)
        request.fetchLimit = 2
        guard try context.fetch(request).count == 1,
              let record = try localIndex().records.first(where: { $0.id == id.uuidString }) else { throw AskError.invalidEvidence }
        return record
    }
    func save(_ review: AskSaveReview) throws -> SavedPlace {
        guard review.canSave, !context.hasChanges,
              let city = try cities().first(where: { $0.objectURIString == review.cityID }) else { throw AskError.invalidEvidence }
        // Recheck immediately before a write. Never update/merge an existing restaurant.
        let existing = try repository.fetchSavedPlaces().filter { $0.feastList == city }
        let key = Self.nameKey(review.name)
        if existing.contains(where: { Self.nameKey($0.displayName) == key && ($0.applePlaceIDValue == nil || review.selectedMapOption == nil) }) {
            throw FeastRepository.SavedPlaceError.duplicatePrototypeName
        }
        let place: SavedPlace
        let cuisines = review.cuisines.split(separator: ",").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        let reviewedNote = review.note + (review.personalNote.isEmpty ? "" : "\n\nYour note:\n" + review.personalNote)
        if let option = review.selectedMapOption {
            let note = reviewedNote + "\n\nReviewed mock Maps branch (fixture only): \(option.name)\nAddress: \(option.address)"
            place = try repository.createSavedPlace(from: .init(applePlaceID: option.id,
                displayNameSnapshot: review.name, status: review.status, placeType: review.placeType,
                cuisines: cuisines, tags: [], note: note, websiteURL: nil, instagramURL: nil,
                feastList: city, listSection: nil))
        } else {
            place = try repository.createUnmappedPrototypePlace(name: review.name, status: review.status,
                placeType: review.placeType, cuisines: cuisines, note: reviewedNote + "\n\nNo Maps listing selected. Unpinned manual prototype entry.", in: city)
        }
        if let id = place.id { localAuthoredTexts[id] = place.note }
        return place
    }
    private static func nameKey(_ name: String) -> String {
        name.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "en_US_POSIX"))
            .split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }
}
