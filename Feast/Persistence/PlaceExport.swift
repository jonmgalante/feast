import CoreData
import Foundation

/// Raw saved-library graph. Sharing provenance is informational, never restore authority.
nonisolated struct PlaceExport: Codable, Equatable, Sendable {
    var format = "com.jongalante.Feast.places"
    var version = 2
    let exportedAt: Date
    let cities: [City]
    let neighborhoods: [Neighborhood]
    let places: [Place]
    var provenance: Provenance? = nil

    static let maximumFileBytes = 32 * 1024 * 1024
    static let maximumRecords = 100_000
    static let maximumStringBytes = 1_048_576
    static let maximumParentDepth = 128

    enum StoreScope: String, Codable, Sendable { case privateLibrary, sharedLibrary, unknown }
    enum SharingStatus: String, Codable, Sendable { case notShared, shared, unavailable }
    struct Provenance: Codable, Equatable, Sendable {
        let capturedAt: Date
        let records: [RecordSource]
        let cities: [CitySharing]
    }
    struct RecordSource: Codable, Equatable, Sendable {
        let entity: String
        let id: UUID
        let store: StoreScope
    }
    struct CitySharing: Codable, Equatable, Sendable {
        let cityID: UUID
        let status: SharingStatus
        let ownerRecordName: String?
        let currentUserRole: String?
        let currentUserPermission: String?
        let publicPermission: String?
        let participants: [Participant]
        var shareRecordName: String? = nil
        var zoneName: String? = nil
        var zoneOwnerName: String? = nil
    }
    struct Participant: Codable, Equatable, Sendable {
        let userRecordName: String?
        let role: String
        let permission: String
        let acceptanceStatus: String
    }

    struct City: Codable, Equatable, Sendable {
        let id: UUID
        let name: String?
        let createdAt: Date?
        let updatedAt: Date?
    }
    struct Neighborhood: Codable, Equatable, Sendable {
        let id: UUID
        let cityID: UUID?
        let parentID: UUID?
        let name: String?
        let createdAt: Date?
        let updatedAt: Date?
    }
    struct Place: Codable, Equatable, Sendable {
        let id: UUID
        let cityID: UUID?
        let neighborhoodID: UUID?
        let applePlaceID: String?
        let name: String?
        let status: String?
        let placeType: String?
        let cuisinesStorage: String?
        let tagsStorage: String?
        let note: String?
        let skipNote: String?
        let websiteURL: String?
        let instagramURL: String?
        let createdAt: Date?
        let updatedAt: Date?
    }
    enum ExportError: LocalizedError {
        case unsavedChanges, invalidContents, unsupportedVersion, tooLarge
        var errorDescription: String? {
            switch self {
            case .unsavedChanges: return "Finish saving your changes before exporting."
            case .invalidContents: return "This is not a valid Feast library file. Nothing was imported or shared."
            case .unsupportedVersion: return "This Feast export version is not supported. Update Feast and try again."
            case .tooLarge: return "This library exceeds the supported limits (32 MB, 100,000 records, or 1 MB per field)."
            }
        }
    }

    @MainActor static func capture(context: NSManagedObjectContext) throws -> PlaceExport {
        guard !context.hasChanges else { throw ExportError.unsavedChanges }
        let cities = try context.fetch(FeastList.fetchRequest())
        let neighborhoods = try context.fetch(ListSection.fetchRequest())
        let places = try context.fetch(SavedPlace.fetchRequest())
        guard cities.allSatisfy({ $0.id != nil }), neighborhoods.allSatisfy({ $0.id != nil }), places.allSatisfy({ $0.id != nil }) else {
            throw ExportError.invalidContents
        }
        let snapshot = PlaceExport(exportedAt: Date(), cities: cities.map {
            City(id: $0.id!, name: $0.name, createdAt: $0.createdAt, updatedAt: $0.updatedAt)
        }, neighborhoods: neighborhoods.map {
            Neighborhood(id: $0.id!, cityID: $0.feastList?.id, parentID: $0.parent?.id, name: $0.name, createdAt: $0.createdAt, updatedAt: $0.updatedAt)
        }, places: places.map {
            Place(id: $0.id!, cityID: $0.feastList?.id, neighborhoodID: $0.listSection?.id,
                  applePlaceID: $0.applePlaceID, name: $0.displayNameSnapshot,
                  status: $0.status, placeType: $0.placeType, cuisinesStorage: $0.cuisinesStorage,
                  tagsStorage: $0.tagsStorage, note: $0.note, skipNote: $0.skipNote,
                  websiteURL: $0.websiteURL, instagramURL: $0.instagramURL,
                  createdAt: $0.createdAt, updatedAt: $0.updatedAt)
        })
        try snapshot.validate()
        return snapshot
    }

    func validate() throws {
        guard format == "com.jongalante.Feast.places" else { throw ExportError.invalidContents }
        guard version == 1 || version == 2 else { throw ExportError.unsupportedVersion }
        guard cities.count + neighborhoods.count + places.count <= Self.maximumRecords else { throw ExportError.tooLarge }
        let cityIDs = Set(cities.map(\.id))
        let neighborhoodIDs = Set(neighborhoods.map(\.id))
        let placeIDs = Set(places.map(\.id))
        guard cityIDs.count == cities.count, neighborhoodIDs.count == neighborhoods.count,
              placeIDs.count == places.count else { throw ExportError.invalidContents }
        let sections = Dictionary(uniqueKeysWithValues: neighborhoods.map { ($0.id, $0) })
        guard exportedAt.timeIntervalSinceReferenceDate.isFinite,
              cities.allSatisfy({ Self.validDates($0.createdAt, $0.updatedAt) }),
              neighborhoods.allSatisfy({ n in
                  Self.validDates(n.createdAt, n.updatedAt) &&
                  (n.cityID.map { cityIDs.contains($0) } ?? true) &&
                  (n.parentID.map { sections[$0]?.cityID == n.cityID && sections[$0] != nil && $0 != n.id } ?? true)
              }),
              places.allSatisfy({ p in
                  Self.validDates(p.createdAt, p.updatedAt) &&
                  (p.cityID.map { cityIDs.contains($0) } ?? true) &&
                  (p.neighborhoodID.map { sections[$0]?.cityID == p.cityID && sections[$0] != nil } ?? true)
              }) else { throw ExportError.invalidContents }
        // Iterative, memoized walk rejects cycles and avoids recursive UI stack exhaustion.
        var depths: [UUID: Int] = [:]
        for section in neighborhoods where depths[section.id] == nil {
            var path: [UUID] = []
            var seen = Set<UUID>()
            var next: UUID? = section.id
            while let id = next, depths[id] == nil {
                guard seen.insert(id).inserted, path.count < Self.maximumParentDepth else { throw ExportError.invalidContents }
                path.append(id)
                next = sections[id]?.parentID
            }
            var depth = next.flatMap { depths[$0] } ?? 0
            for id in path.reversed() {
                depth += 1
                guard depth <= Self.maximumParentDepth else { throw ExportError.invalidContents }
                depths[id] = depth
            }
        }
        for city in cities { try Self.validateStrings([city.name]) }
        for section in neighborhoods { try Self.validateStrings([section.name]) }
        for place in places {
            try Self.validateStrings([place.applePlaceID, place.name, place.status, place.placeType,
                place.cuisinesStorage, place.tagsStorage, place.note, place.skipNote, place.websiteURL, place.instagramURL])
        }
        if let provenance {
            guard provenance.capturedAt.timeIntervalSinceReferenceDate.isFinite,
                  provenance.records.count <= Self.maximumRecords,
                  provenance.cities.count <= cities.count else { throw ExportError.invalidContents }
            let idsByEntity = ["FeastList": cityIDs, "ListSection": neighborhoodIDs, "SavedPlace": placeIDs]
            var sourceKeys = Set<String>()
            for source in provenance.records {
                guard idsByEntity[source.entity]?.contains(source.id) == true,
                      sourceKeys.insert(source.entity + source.id.uuidString).inserted else { throw ExportError.invalidContents }
            }
            var sharedCities = Set<UUID>()
            for sharing in provenance.cities {
                guard cityIDs.contains(sharing.cityID), sharedCities.insert(sharing.cityID).inserted,
                      sharing.participants.count <= 1_000 else { throw ExportError.invalidContents }
                try Self.validateStrings([sharing.ownerRecordName, sharing.currentUserRole, sharing.currentUserPermission, sharing.publicPermission, sharing.shareRecordName, sharing.zoneName, sharing.zoneOwnerName])
                for participant in sharing.participants {
                    try Self.validateStrings([participant.userRecordName, participant.role, participant.permission, participant.acceptanceStatus])
                }
            }
        }
    }

    private static func validDates(_ dates: Date?...) -> Bool {
        dates.allSatisfy { $0?.timeIntervalSinceReferenceDate.isFinite ?? true }
    }

    private static func validateStrings(_ values: [String?]) throws {
        guard values.allSatisfy({ ($0?.utf8.count ?? 0) <= maximumStringBytes }) else { throw ExportError.tooLarge }
    }

    static func decode(_ data: Data) throws -> PlaceExport {
        guard data.count <= maximumFileBytes else { throw ExportError.tooLarge }
        struct Envelope: Decodable { let format: String; let version: Int }
        let archive: PlaceExport
        do {
            let envelope = try JSONDecoder().decode(Envelope.self, from: data)
            guard envelope.format == "com.jongalante.Feast.places" else { throw ExportError.invalidContents }
            guard envelope.version == 1 || envelope.version == 2 else { throw ExportError.unsupportedVersion }
            archive = try JSONDecoder().decode(PlaceExport.self, from: data)
        } catch let error as ExportError { throw error }
        catch { throw ExportError.invalidContents }
        try archive.validate()
        return archive
    }

    func validatedData() throws -> Data {
        try validate()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        // Foundation's numeric Date encoding preserves subsecond timestamps.
        let data = try encoder.encode(self)
        guard data.count <= Self.maximumFileBytes else { throw ExportError.tooLarge }
        guard try Self.decode(data) == self else { throw ExportError.invalidContents }
        return data
    }
}
