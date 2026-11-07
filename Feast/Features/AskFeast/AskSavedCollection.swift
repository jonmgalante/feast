import CoreData
import Foundation

/// Reads only currently visible cities. Rich fields are fetched on demand after capability and consent gates.
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
    func personalPlaces() throws -> [AskPersonalPlace] { try librarySnapshot().places }
    func librarySnapshot() throws -> AskLibrarySnapshot { try readCollection(visible:visibleCities()).snapshot }
    /// One uncapped metadata fetch supplies both the local catalog and evidence index.
    /// Invalid rows stay in the stored total; neither duplicate identity is eligible.
    private func readCollection(visible:Set<UUID>,includeDetails:Bool=false) throws -> (snapshot:AskLibrarySnapshot,cityIDs:[String:String]) {
        let cities=NSFetchRequest<NSDictionary>(entityName:"FeastList")
        cities.resultType = .dictionaryResultType;cities.includesPendingChanges=false;cities.propertiesToFetch=["id","name"]
        cities.predicate=NSPredicate(format:"id IN %@",Array(visible) as NSArray)
        let cityRows=try context.fetch(cities),cityGroups=Dictionary(grouping:cityRows,by:{$0["id"] as? UUID})
        let safeCities=cityRows.filter {row in
            guard let id=row["id"] as? UUID,cityGroups[id]?.count==1,let name=row["name"] as? String,!name.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty,name.utf16.count<=200 else{return false}
            return true
        }
        let safeCityIDs=Set(safeCities.compactMap {$0["id"] as? UUID})
        let fetch=NSFetchRequest<NSDictionary>(entityName:"SavedPlace")
        fetch.resultType = .dictionaryResultType;fetch.includesPendingChanges=false
        fetch.propertiesToFetch=["id","displayNameSnapshot","cuisinesStorage","status","placeType","feastList.id","feastList.name","listSection.name","websiteURL","instagramURL","applePlaceID"]
        if includeDetails {fetch.propertiesToFetch! += ["note","tagsStorage"]}
        fetch.predicate=NSPredicate(format:"feastList.id IN %@",Array(visible) as NSArray)
        let rows=try context.fetch(fetch)
        var places:[AskPersonalPlace]=[],unavailable:[String?]=[],cityIDs:[String:String]=[:]
        for row in rows {
            let city=row["feastList.name"] as? String ?? ""
            guard let cityID=row["feastList.id"] as? UUID,safeCityIDs.contains(cityID) else{unavailable.append(nil);continue}
            guard let id=row["id"] as? UUID,let name=row["displayNameSnapshot"] as? String else {unavailable.append(city.utf16.count<=200 ? city : nil);continue}
            let cuisines=(row["cuisinesStorage"] as? String ?? "").split(separator:"\n").map {$0.trimmingCharacters(in:.whitespacesAndNewlines)}.filter {!$0.isEmpty}
            places.append(.init(id:id.uuidString,name:name,status:row["status"] as? String,type:row["placeType"] as? String,cuisines:cuisines,city:city,neighborhood:row["listSection.name"] as? String ?? "",websiteURL:row["websiteURL"] as? String,instagramURL:row["instagramURL"] as? String,applePlaceID:row["applePlaceID"] as? String,note:includeDetails ? row["note"] as? String : nil,tags:includeDetails ? (row["tagsStorage"] as? String ?? "").split(separator:"\n").map(String.init) : nil))
            cityIDs[id.uuidString]=cityID.uuidString
        }
        let names=safeCities.compactMap {$0["name"] as? String}
        return (.init(places:places,totalCount:rows.count,cityNames:names,unavailableCities:unavailable,cityCatalogComplete:safeCities.count==cityRows.count).sanitized(),cityIDs)
    }
    func index() throws -> AskLocalIndex { try readView().index }
    /// Fresh, operation-local reads only. Never retain this view across an await,
    /// an edit, or another request: permissions and stored values must be re-read.
    func readView(includeDetails:Bool=false) throws -> (snapshot: AskLibrarySnapshot, index: AskLocalIndex) {
        let visible=try visibleCities(),reading=try readCollection(visible:visible,includeDetails:includeDetails),snapshot=reading.snapshot
        let records=snapshot.places.compactMap {place->AskCollectionRecord? in
            guard let cityID=reading.cityIDs[place.id] else{return nil}
            return .init(id:place.id,cityID:cityID,city:"",name:place.name,neighborhood:"",cuisine:String(place.cuisines.joined(separator:", ").prefix(500)),status:"",notes:[])
        }
        let index=AskLocalIndex(records:records,visibleCityIDs:Set(visible.map(\.uuidString)),visibleNoteIDs:[],scope:.savedMetadata,personalPlaces:snapshot.places,catalogComplete:snapshot.complete)
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
