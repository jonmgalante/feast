import CoreData
import Foundation

/// Reads approved persisted metadata only. Never faults SavedPlace objects/notes into the AI path.
@MainActor final class AskSavedCollection {
    let context: NSManagedObjectContext
    let canMutate:(String,NSManagedObjectID?,String) -> Bool
    let repository:(NSManagedObjectContext) -> FeastRepository
    let canRecoverStore:(String) -> Bool
    let saveFieldContext:(NSManagedObjectContext) throws -> Void
    let canUpdate: (NSManagedObjectID) -> Bool
    let visibleCities: () throws -> Set<UUID>
    init(context: NSManagedObjectContext, canUpdate: @escaping (NSManagedObjectID) -> Bool = {_ in false}, canMutate: @escaping (String,NSManagedObjectID?,String) -> Bool = {_,_,_ in false}, repository: ((NSManagedObjectContext)->FeastRepository)? = nil, canRecoverStore: @escaping (String)->Bool = {_ in false}, saveFieldContext: @escaping (NSManagedObjectContext) throws -> Void = {try $0.save()}, visibleCities: @escaping () throws -> Set<UUID>) {
        self.context = context; self.visibleCities = visibleCities;self.canUpdate=canUpdate;self.saveFieldContext=saveFieldContext;self.canMutate=canMutate;self.repository=repository ?? { FeastRepository(context:$0) };self.canRecoverStore=canRecoverStore
    }
    /// A save form owns its context, so Cancel/failure cannot roll back another editor's draft.
    func makeSaveContext() throws -> NSManagedObjectContext {
        guard let coordinator = context.persistentStoreCoordinator else { throw AskError.invalidEvidence }
        let isolated = NSManagedObjectContext(concurrencyType: .mainQueueConcurrencyType)
        isolated.persistentStoreCoordinator = coordinator
        isolated.mergePolicy = NSErrorMergePolicy
        return isolated
    }
    func personalPlaces() throws -> [AskPersonalPlace] {
        try personalPlaces(visible: visibleCities())
    }
    private func personalPlaces(visible: Set<UUID>) throws -> [AskPersonalPlace] {
        let fetch = NSFetchRequest<NSDictionary>(entityName: "SavedPlace")
        fetch.resultType = .dictionaryResultType; fetch.includesPendingChanges = false
        fetch.propertiesToFetch = ["id", "displayNameSnapshot", "cuisinesStorage", "status", "placeType", "feastList.name", "listSection.name", "websiteURL", "instagramURL", "applePlaceID"]
        fetch.predicate = NSPredicate(format: "feastList.id IN %@", Array(visible) as NSArray)
        fetch.fetchLimit = 200
        return try context.fetch(fetch).compactMap { row in
            guard let id = row["id"] as? UUID, let name = row["displayNameSnapshot"] as? String else { return nil }
            return .init(id: id.uuidString, name: name, status: row["status"] as? String, type: row["placeType"] as? String,
                cuisines: (row["cuisinesStorage"] as? String ?? "").split(separator: "\n").map(String.init),
                city: row["feastList.name"] as? String ?? "", neighborhood: row["listSection.name"] as? String ?? "",websiteURL:row["websiteURL"] as? String,instagramURL:row["instagramURL"] as? String,applePlaceID:row["applePlaceID"] as? String)
        }
    }
    func librarySnapshot() throws -> AskLibrarySnapshot {
        let visible = try visibleCities()
        return try librarySnapshot(visible: visible)
    }
    private func librarySnapshot(visible: Set<UUID>) throws -> AskLibrarySnapshot {
        let request = NSFetchRequest<NSFetchRequestResult>(entityName: "SavedPlace")
        request.includesPendingChanges = false
        request.predicate = NSPredicate(format: "feastList.id IN %@", Array(visible) as NSArray)
        let cities = NSFetchRequest<NSDictionary>(entityName: "FeastList")
        cities.resultType = .dictionaryResultType; cities.includesPendingChanges = false
        cities.propertiesToFetch = ["name"]
        cities.predicate = NSPredicate(format: "id IN %@", Array(visible) as NSArray)
        return .init(places: try personalPlaces(visible: visible), totalCount: try context.count(for: request), cityNames: try context.fetch(cities).compactMap { $0["name"] as? String })
    }
    func index() throws -> AskLocalIndex {
        try readView().index
    }
    /// Fresh, operation-local reads only. Never retain this view across an await,
    /// an edit, or another request: permissions and stored values must be re-read.
    func readView() throws -> (snapshot: AskLibrarySnapshot, index: AskLocalIndex) {
        let visible = try visibleCities()
        var records: [AskCollectionRecord] = []
        for city in visible.sorted(by: { $0.uuidString < $1.uuidString }) {
            guard records.count < 200 else { break }
            let fetch = NSFetchRequest<NSDictionary>(entityName: "SavedPlace")
            fetch.resultType = .dictionaryResultType
            fetch.includesPendingChanges = false
            fetch.propertiesToFetch = ["id", "displayNameSnapshot", "cuisinesStorage"]
            fetch.predicate = NSPredicate(format: "feastList.id == %@", city as NSUUID)
            fetch.sortDescriptors = [NSSortDescriptor(key: "id", ascending: true)]
            fetch.fetchLimit = 200 - records.count
            for row in try context.fetch(fetch) {
                guard let id = row["id"] as? UUID, let name = row["displayNameSnapshot"] as? String,
                      !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, name.count <= 200 else { continue }
                // Match SavedPlace.cuisines' persisted newline encoding; never migrate/write it.
                let values = (row["cuisinesStorage"] as? String ?? "").split(separator: "\n")
                    .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
                let cuisine = String(values.joined(separator: ", ").prefix(500))
                records.append(.init(id: id.uuidString, cityID: city.uuidString, city: "", name: name,
                    neighborhood: "", cuisine: cuisine, status: "", notes: []))
            }
        }
        // Addresses/ratings are not persisted by this model: deliberately absent.
        let snapshot = try librarySnapshot(visible: visible)
        let index = AskLocalIndex(records: records, visibleCityIDs: Set(visible.map(\.uuidString)), visibleNoteIDs: [], scope: .savedMetadata, personalPlaces: snapshot.places, catalogComplete: snapshot.complete)
        return (snapshot,index)
    }
}

enum AskSavedMetadataEvidence {
    static func build(_ records: [AskCollectionRecord]) -> AskEvidence {
        var sources: [AskSource] = []
        let candidates = records.prefix(6).map { record -> AskCandidate in
            let sourceID = "metadata-" + record.id
            var fields: [String: Any] = ["name": record.name]
            var facts: [AskFact] = []
            if !record.cuisine.isEmpty { fields["cuisines"] = record.cuisine; facts.append(.init(kind: .cuisine, value: record.cuisine, sourceID: sourceID)) }
            if let address = record.address, !address.isEmpty, address.count <= 400 {
                fields["address"] = address; facts.append(.init(kind: .address, value: address, sourceID: sourceID))
            }
            if let rating = record.rating, rating.isFinite, (0...5).contains(rating) {
                fields["rating"] = rating; facts.append(.init(kind: .rating, value: String(rating), sourceID: sourceID))
            }
            let data = (try? JSONSerialization.data(withJSONObject: fields, options: [.sortedKeys])) ?? Data()
            sources.append(.init(id: sourceID, title: "Saved place details", kind: .savedMetadata,
                author: "Saved place metadata", published: nil, checked: "", url: nil,
                excerpt: String(data: data, encoding: .utf8) ?? ""))
            return .init(id: record.id, name: record.name, city: "", facts: facts, sourceIDs: [sourceID],
                uncertainty: "", mapOptions: [], existingRecordID: record.id)
        }
        return .init(candidates: candidates, sources: sources)
    }
}
