import CoreData
import Foundation

/// A portable, versioned snapshot. Restoration is deliberately outside this format's UI.
struct PlaceExport: Codable, Equatable {
    var format = "com.jongalante.Feast.places"
    var version = 1
    let exportedAt: Date
    let cities: [City]
    let neighborhoods: [Neighborhood]
    let places: [Place]

    struct City: Codable, Equatable {
        let id: UUID
        let name: String?
        let createdAt: Date?
        let updatedAt: Date?
    }
    struct Neighborhood: Codable, Equatable {
        let id: UUID
        let cityID: UUID?
        let parentID: UUID?
        let name: String?
        let createdAt: Date?
        let updatedAt: Date?
    }
    struct Place: Codable, Equatable {
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
        case unsavedChanges, invalidContents
        var errorDescription: String? {
            switch self {
            case .unsavedChanges: return "Finish saving your changes before exporting."
            case .invalidContents: return "Feast couldn't validate this export. No file was shared."
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
        let cityIDs = Set(cities.map(\.id))
        let neighborhoodIDs = Set(neighborhoods.map(\.id))
        guard format == "com.jongalante.Feast.places", version == 1,
              cityIDs.count == cities.count, neighborhoodIDs.count == neighborhoods.count,
              Set(places.map(\.id)).count == places.count,
              neighborhoods.allSatisfy({ n in
                  (n.cityID.map { cityIDs.contains($0) } ?? true) &&
                  (n.parentID.map { id in neighborhoods.contains { $0.id == id && $0.cityID == n.cityID && id != n.id } } ?? true)
              }),
              places.allSatisfy({ p in
                  (p.cityID.map { cityIDs.contains($0) } ?? true) &&
                  (p.neighborhoodID.map { id in neighborhoods.contains { $0.id == id && $0.cityID == p.cityID } } ?? true)
              }) else { throw ExportError.invalidContents }
    }

    func validatedData() throws -> Data {
        try validate()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        // Preserve subsecond timestamps through the encoder/decoder round trip.
        let data = try encoder.encode(self)
        guard try JSONDecoder().decode(PlaceExport.self, from: data) == self else { throw ExportError.invalidContents }
        return data
    }
}
