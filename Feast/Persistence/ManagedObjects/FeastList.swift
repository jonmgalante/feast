import CoreData
import Foundation

@objc(FeastList)
public final class FeastList: NSManagedObject {
    @nonobjc public class func fetchRequest() -> NSFetchRequest<FeastList> {
        NSFetchRequest<FeastList>(entityName: "FeastList")
    }

    @NSManaged public var createdAt: Date?
    @NSManaged public var id: UUID?
    @NSManaged public var name: String?
    @NSManaged public var updatedAt: Date?
    @NSManaged public var savedPlaces: NSSet?
    @NSManaged public var sections: NSSet?
}

extension FeastList: Identifiable {}

extension FeastList {
    var objectURIString: String {
        objectID.uriRepresentation().absoluteString
    }

    var displayName: String {
        name ?? "Untitled City"
    }

    var sortedSections: [ListSection] {
        let values = sections as? Set<ListSection> ?? []
        return values.sorted { lhs, rhs in
            lhs.pathDisplay.localizedCaseInsensitiveCompare(rhs.pathDisplay) == .orderedAscending
        }
    }

    var topLevelSections: [ListSection] {
        sortedSections.filter { $0.parent == nil }
    }

    var neighborhoodSections: [ListSection] {
        topLevelSections
    }

    var sortedSavedPlaces: [SavedPlace] {
        let values = savedPlaces as? Set<SavedPlace> ?? []
        return values.sorted { lhs, rhs in
            lhs.updatedAtValue > rhs.updatedAtValue
        }
    }

    var unsortedSavedPlaces: [SavedPlace] {
        sortedSavedPlaces.filter { $0.listSection == nil }
    }

    var savedPlaceCount: Int {
        (savedPlaces as? Set<SavedPlace>)?.count ?? 0
    }

    var neighborhoodSummary: String {
        let names = neighborhoodSections.map(\.displayName)
        guard !names.isEmpty else {
            return "Add neighborhoods to organize places"
        }

        return names.joined(separator: ", ")
    }
}
