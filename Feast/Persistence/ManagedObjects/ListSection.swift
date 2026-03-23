import CoreData
import Foundation

@objc(ListSection)
public final class ListSection: NSManagedObject {
    @nonobjc public class func fetchRequest() -> NSFetchRequest<ListSection> {
        NSFetchRequest<ListSection>(entityName: "ListSection")
    }

    @NSManaged public var createdAt: Date?
    @NSManaged public var id: UUID?
    @NSManaged public var name: String?
    @NSManaged public var updatedAt: Date?
    @NSManaged public var children: NSSet?
    @NSManaged public var feastList: FeastList?
    @NSManaged public var parent: ListSection?
    @NSManaged public var savedPlaces: NSSet?
}

extension ListSection: Identifiable {}

extension ListSection {
    var displayName: String {
        name ?? "Untitled Section"
    }

    var sortedChildren: [ListSection] {
        let values = children as? Set<ListSection> ?? []
        return values.sorted { lhs, rhs in
            lhs.displayName.localizedCaseInsensitiveCompare(rhs.displayName) == .orderedAscending
        }
    }

    var sortedSavedPlaces: [SavedPlace] {
        let values = savedPlaces as? Set<SavedPlace> ?? []
        return values.sorted { lhs, rhs in
            lhs.updatedAtValue > rhs.updatedAtValue
        }
    }

    var depth: Int {
        var currentParent = parent
        var depth = 0

        while let section = currentParent {
            depth += 1
            currentParent = section.parent
        }

        return depth
    }

    var pathComponents: [String] {
        if let parent {
            return parent.pathComponents + [displayName]
        }

        return [displayName]
    }

    var pathDisplay: String {
        pathComponents.joined(separator: " • ")
    }
}
