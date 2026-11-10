import CoreData
import CryptoKit
import Foundation

/// Additive restore only. No normalizing creation helpers, share APIs, deletion, or merging.
nonisolated enum PlaceImport {
    enum Result: Equatable, Sendable { case restored, alreadyImported }
    enum ImportError: LocalizedError {
        case pendingEdits, unavailableStore, identityConflict, preparationRequired, inProgress
        var errorDescription: String? {
            switch self {
            case .inProgress: return "Another library import is still running. Wait for it to finish before trying again."
            case .pendingEdits: return "Finish saving your current changes before importing. Your edits were left untouched."
            case .unavailableStore: return "The private library store is unavailable. Nothing was imported."
            case .identityConflict: return "Some records from this snapshot already exist, or their identifiers conflict. Nothing was changed. Keep your original export; restore into a separate empty library if you need a complete copy."
            case .preparationRequired: return "Feast must finish preparing the library before importing. Close and reopen Feast, then try again."
            }
        }
    }

    /// Read at most limit + 1 bytes, even if a file changes after its size was checked.
    static func readFile(at url: URL) throws -> PlaceExport {
        try Task.checkCancellation()
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var data = Data()
        while data.count <= PlaceExport.maximumFileBytes {
            try Task.checkCancellation()
            let chunk = try handle.read(upToCount: min(65_536, PlaceExport.maximumFileBytes + 1 - data.count)) ?? Data()
            if chunk.isEmpty { break }
            data.append(chunk)
        }
        try Task.checkCancellation()
        return try PlaceExport.decode(data)
    }

    @MainActor private static var importInProgress = false

    /// Production path: the private context owns every mutation and rollback. The UI
    /// context is never saved or reset, including if another window creates a draft.
    @MainActor static func restoreInBackground(_ archive: PlaceExport, into viewContext: NSManagedObjectContext,
                                               privateStore: NSPersistentStore) async throws -> Result {
        try Task.checkCancellation()
        guard !importInProgress else { throw ImportError.inProgress }
        guard !viewContext.hasChanges else { throw ImportError.pendingEdits }
        guard viewContext.parent == nil, let coordinator = viewContext.persistentStoreCoordinator else {
            throw ImportError.unavailableStore
        }
        importInProgress = true
        defer { importInProgress = false }
        let worker = NSManagedObjectContext(concurrencyType: .privateQueueConcurrencyType)
        worker.persistentStoreCoordinator = coordinator
        worker.mergePolicy = NSErrorMergePolicy
        worker.undoManager = nil
        let storeIdentity = ObjectIdentifier(privateStore)
        let (result, insertedIDs) = try await worker.perform {
            guard let workerStore = worker.persistentStoreCoordinator?.persistentStores.first(where: { ObjectIdentifier($0) == storeIdentity }) else {
                throw ImportError.unavailableStore
            }
            var insertedIDs: [NSManagedObjectID] = []
            let result = try execute(archive, into: worker, privateStore: workerStore) { insertedIDs = $0 }
            return (result, insertedIDs)
        }
        if !insertedIDs.isEmpty {
            NSManagedObjectContext.mergeChanges(fromRemoteContextSave: [NSInsertedObjectIDsKey: insertedIDs], into: [viewContext])
        }
        return result
    }

    /// Main-actor synchronous transaction: preview never reserves identity or writes a receipt.
    /// A repeat is recognized from durable mapped IDs, including after a crash following save.
    /// Partial prior copies are rejected rather than duplicated, resurrected, or overwritten.
    @MainActor static func restore(_ archive: PlaceExport, into context: NSManagedObjectContext,
                                   privateStore: NSPersistentStore) throws -> Result {
        guard !importInProgress else { throw ImportError.inProgress }
        return try execute(archive, into: context, privateStore: privateStore)
    }

    /// Caller must own the context's queue. Uses no main-actor application helpers.
    private static func execute(_ archive: PlaceExport, into context: NSManagedObjectContext,
                                privateStore: NSPersistentStore,
                                onSave: ([NSManagedObjectID]) -> Void = { _ in }) throws -> Result {
        try Task.checkCancellation()
        guard !context.hasChanges else { throw ImportError.pendingEdits }
        guard context.parent == nil,
              let coordinator = context.persistentStoreCoordinator,
              coordinator.persistentStores.contains(where: { $0 === privateStore }),
              !privateStore.isReadOnly else { throw ImportError.unavailableStore }
        // The application runs these migrations before presenting the library. Do not run
        // migrations here: doing so could change unrelated existing records during import.
        guard coordinator.persistentStores.allSatisfy({
            (coordinator.metadata(for: $0)["FeastSafeStartupMigrationVersion"] as? Int ?? 0) >= 1
        }) else { throw ImportError.preparationRequired }
        let mapped = try remappedArchive(archive)
        let expected = Dictionary(uniqueKeysWithValues:
            mapped.cities.map { ($0.id, "FeastList") } +
            mapped.neighborhoods.map { ($0.id, "ListSection") } +
            mapped.places.map { ($0.id, "SavedPlace") })
        var found = Set<UUID>()
        // Read every loaded store. This prevents collision with shared records as well as
        // unrelated private records, without consulting or granting sharing authority.
        for entity in ["FeastList", "ListSection", "SavedPlace"] {
            let request = NSFetchRequest<NSManagedObject>(entityName: entity)
            request.includesPendingChanges = false
            for object in try context.fetch(request) {
                guard let id = object.value(forKey: "id") as? UUID, let expectedEntity = expected[id] else { continue }
                guard expectedEntity == entity, object.objectID.persistentStore === privateStore,
                      found.insert(id).inserted else { throw ImportError.identityConflict }
            }
        }
        if !expected.isEmpty && found.count == expected.count { return .alreadyImported }
        guard found.isEmpty else { throw ImportError.identityConflict }
        try Task.checkCancellation()
        do {
            var cities: [UUID: FeastList] = [:]
            var sections: [UUID: ListSection] = [:]
            for source in mapped.cities {
                let city = FeastList(context: context)
                context.assign(city, to: privateStore)
                city.id = source.id; city.name = source.name
                city.createdAt = source.createdAt; city.updatedAt = source.updatedAt
                cities[source.id] = city
            }
            for source in mapped.neighborhoods {
                let section = ListSection(context: context)
                context.assign(section, to: privateStore)
                section.id = source.id; section.name = source.name
                section.createdAt = source.createdAt; section.updatedAt = source.updatedAt
                section.feastList = source.cityID.flatMap { cities[$0] }
                sections[source.id] = section
            }
            for source in mapped.neighborhoods {
                sections[source.id]?.parent = source.parentID.flatMap { sections[$0] }
            }
            for source in mapped.places {
                let place = SavedPlace(context: context)
                context.assign(place, to: privateStore)
                place.id = source.id; place.applePlaceID = source.applePlaceID
                place.displayNameSnapshot = source.name; place.status = source.status
                place.placeType = source.placeType; place.cuisinesStorage = source.cuisinesStorage
                place.tagsStorage = source.tagsStorage; place.note = source.note; place.skipNote = source.skipNote
                place.websiteURL = source.websiteURL; place.instagramURL = source.instagramURL
                place.createdAt = source.createdAt; place.updatedAt = source.updatedAt
                place.feastList = source.cityID.flatMap { cities[$0] }
                place.listSection = source.neighborhoodID.flatMap { sections[$0] }
            }
            try Task.checkCancellation()
            // All inserted objects target exactly one store; one SQLite/Core Data save is
            // the commit point. No sidecar or separately-written import receipt is needed.
            if context.hasChanges {
                let inserted = Array(context.insertedObjects)
                try context.save()
                onSave(inserted.map(\.objectID))
            }
            return .restored
        } catch {
            context.rollback()
            throw error
        }
    }

    /// Stable identity depends on the raw graph, not serialization order, export time,
    /// format version, sharing metadata, or normalized names/Apple Place IDs.
    static func remappedArchive(_ archive: PlaceExport) throws -> PlaceExport {
        try archive.validate()
        let canonical = PlaceExport(exportedAt: Date(timeIntervalSinceReferenceDate: 0),
            cities: archive.cities.sorted { $0.id.uuidString < $1.id.uuidString },
            neighborhoods: archive.neighborhoods.sorted { $0.id.uuidString < $1.id.uuidString },
            places: archive.places.sorted { $0.id.uuidString < $1.id.uuidString })
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        let bytes = try encoder.encode(canonical)
        guard bytes.count <= PlaceExport.maximumFileBytes else { throw PlaceExport.ExportError.tooLarge }
        let fingerprint = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
        func id(_ entity: String, _ original: UUID) -> UUID {
            let input = Data("Feast.private-library-restore.v1|\(fingerprint)|\(entity)|\(original.uuidString)".utf8)
            var bytes = Array(SHA256.hash(data: input).prefix(16))
            // Reserved application UUID v8 namespace allows legacy migrations to recognize
            // restored raw records without changing the Core Data schema or storing receipts.
            bytes[0] = 0xfe; bytes[1] = 0xa5; bytes[2] = 0x7b; bytes[3] = 0x01
            bytes[6] = (bytes[6] & 0x0f) | 0x80; bytes[8] = (bytes[8] & 0x3f) | 0x80
            return UUID(uuid: (bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5], bytes[6], bytes[7],
                bytes[8], bytes[9], bytes[10], bytes[11], bytes[12], bytes[13], bytes[14], bytes[15]))
        }
        let mapped = PlaceExport(exportedAt: archive.exportedAt, cities: canonical.cities.map {
            .init(id: id("FeastList", $0.id), name: $0.name, createdAt: $0.createdAt, updatedAt: $0.updatedAt)
        }, neighborhoods: canonical.neighborhoods.map {
            .init(id: id("ListSection", $0.id), cityID: $0.cityID.map { id("FeastList", $0) },
                  parentID: $0.parentID.map { id("ListSection", $0) }, name: $0.name,
                  createdAt: $0.createdAt, updatedAt: $0.updatedAt)
        }, places: canonical.places.map {
            .init(id: id("SavedPlace", $0.id), cityID: $0.cityID.map { id("FeastList", $0) },
                  neighborhoodID: $0.neighborhoodID.map { id("ListSection", $0) },
                  applePlaceID: $0.applePlaceID, name: $0.name, status: $0.status, placeType: $0.placeType,
                  cuisinesStorage: $0.cuisinesStorage, tagsStorage: $0.tagsStorage, note: $0.note, skipNote: $0.skipNote,
                  websiteURL: $0.websiteURL, instagramURL: $0.instagramURL, createdAt: $0.createdAt, updatedAt: $0.updatedAt)
        })
        // Defensive against even a cryptographic collision, including across entity kinds.
        let allIDs = mapped.cities.map(\.id) + mapped.neighborhoods.map(\.id) + mapped.places.map(\.id)
        guard Set(allIDs).count == allIDs.count else { throw ImportError.identityConflict }
        return mapped
    }

    static func preservesRawLegacyValues(_ id: UUID?) -> Bool {
        guard let bytes = id?.uuid else { return false }
        return bytes.0 == 0xfe && bytes.1 == 0xa5 && bytes.2 == 0x7b && bytes.3 == 0x01
            && bytes.6 & 0xf0 == 0x80 && bytes.8 & 0xc0 == 0x80
    }
}
