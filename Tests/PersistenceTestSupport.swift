// Deliberately excludes the app's CloudKit controller from this host-only harness.
import CoreData
final class PersistenceController {
    func canDeleteFeastList(_ list: FeastList) -> Bool { true }
    func assignToDefaultStore(_ object: NSManagedObject) {}
    func assign(_ object: NSManagedObject, toSameStoreAs other: NSManagedObject) {}
}

struct ApplePlaceCoordinate: Hashable { let latitude: Double; let longitude: Double }
struct ApplePlacesService {
    let matches: [ApplePlaceMatch]
    init(matches:[ApplePlaceMatch]=[]){self.matches=matches}
    @MainActor func search(query: String) async throws -> [ApplePlaceMatch] { matches }
    @MainActor func resolve(placeID: String) async throws -> ApplePlaceMatch? { matches.first {$0.applePlaceID==placeID} }
}
