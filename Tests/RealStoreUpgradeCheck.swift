import Foundation
import CoreData
import CryptoKit

/// Runs only on a private SQLite backup under /tmp. Never attaches to CloudKit or an original simulator store.
@MainActor enum RealStoreUpgradeCheck {
    static func run(model:NSManagedObjectModel,directory:URL) throws {
        let path = directory.resolvingSymlinksInPath().path
        guard path.hasPrefix("/private/tmp/feast-original-production-") || path.hasPrefix("/tmp/feast-original-production-"),
              FileManager.default.fileExists(atPath:directory.appendingPathComponent("COPY_ONLY").path) else { throw CocoaError(.fileReadNoPermission) }
        let coordinator = NSPersistentStoreCoordinator(managedObjectModel:model)
        for name in ["Feast.sqlite","Feast-Shared.sqlite"] {
            try coordinator.addPersistentStore(ofType:NSSQLiteStoreType,configurationName:nil,at:directory.appendingPathComponent(name),options:[NSPersistentHistoryTrackingKey:true])
        }
        let context=NSManagedObjectContext(concurrencyType:.mainQueueConcurrencyType);context.persistentStoreCoordinator=coordinator
        func snapshot() throws -> [String:[String:Any]] {
            var result:[String:[String:Any]]=[:]
            for entity in ["SavedPlace","FeastList","ListSection"] {
                let objects=try context.fetch(NSFetchRequest<NSManagedObject>(entityName:entity))
                let rows=objects.map { object -> String in
                    var fields:[String]=[]
                    for key in object.entity.attributesByName.keys.sorted() {
                        let value=object.value(forKey:key),text:String
                        if let date=value as? Date {text=String(date.timeIntervalSinceReferenceDate.bitPattern)}
                        else if let id=value as? UUID {text=id.uuidString}
                        else if let string=value as? String {text=string}
                        else if let data=value as? Data {text=data.base64EncodedString()}
                        else {text=value.map{String(describing:$0)} ?? "<nil>"}
                        fields.append(key+":"+text)
                    }
                    for key in object.entity.relationshipsByName.keys.sorted() {
                        let value=object.value(forKey:key)
                        func identity(_ value:NSManagedObject)->String { (value.value(forKey:"id") as? UUID)?.uuidString ?? value.objectID.uriRepresentation().absoluteString }
                        let ids:String
                        if let value=value as? NSManagedObject {ids=identity(value)}
                        else if let values=value as? NSSet {ids=values.compactMap{$0 as? NSManagedObject}.map(identity).sorted().joined(separator:",")}
                        else {ids="<nil>"}
                        fields.append(key+":"+ids)
                    }
                    return fields.joined(separator:"|")
                }.sorted().joined(separator:"\n")
                result[entity]=["count":objects.count,"sha256":SHA256.hash(data:Data(rows.utf8)).map{String(format:"%02x",$0)}.joined()]
            }
            return result
        }
        let before=try snapshot()
        try FeastRepository(context:context).runStartupMigrations()
        let after=try snapshot()
        try FeastRepository(context:context).runStartupMigrations()
        let repeated=try snapshot()
        let intact=NSDictionary(dictionary:before).isEqual(to:after) && NSDictionary(dictionary:after).isEqual(to:repeated)
        let report:[String:Any]=["copyOnly":true,"cloudKitDisabled":true,"allUserFieldsAndRelationshipsPreserved":intact,"before":before,"after":after,"repeat":repeated]
        try JSONSerialization.data(withJSONObject:report,options:[.sortedKeys,.prettyPrinted]).write(to:directory.appendingPathComponent("upgrade-verification.json"),options:.atomic)
        context.reset();for store in coordinator.persistentStores {try coordinator.remove(store)}
        guard intact else {throw NSError(domain:"CopiedStoreUserFieldsChanged",code:1)}
        print("PASS private copied real-store upgrade preserves every user attribute/relationship and repeat startup; CloudKit disabled, originals untouched")
    }
}
