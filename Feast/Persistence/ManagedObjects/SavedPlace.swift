import CoreData
import Foundation

@objc(SavedPlace)
public final class SavedPlace: NSManagedObject {
    @nonobjc public class func fetchRequest() -> NSFetchRequest<SavedPlace> {
        NSFetchRequest<SavedPlace>(entityName: "SavedPlace")
    }

    @NSManaged public var applePlaceID: String?
    @NSManaged public var createdAt: Date?
    @NSManaged public var cuisinesStorage: String?
    @NSManaged public var displayNameSnapshot: String?
    @NSManaged public var id: UUID?
    @NSManaged public var instagramURL: String?
    @NSManaged public var note: String?
    @NSManaged public var placeType: String?
    @NSManaged public var skipNote: String?
    @NSManaged public var status: String?
    @NSManaged public var tagsStorage: String?
    @NSManaged public var updatedAt: Date?
    @NSManaged public var feastList: FeastList?
    @NSManaged public var listSection: ListSection?
}

extension SavedPlace: Identifiable {}

extension SavedPlace {
    var applePlaceIDValue: String? {
        guard let applePlaceID, !applePlaceID.isEmpty else {
            return nil
        }

        return applePlaceID
    }

    var displayName: String {
        displayNameSnapshot ?? "Unnamed Place"
    }

    var updatedAtValue: Date {
        updatedAt ?? .distantPast
    }

    var placeStatus: PlaceStatus {
        get { PlaceStatus(rawValue: status ?? "") ?? .wantToTry }
        set { status = newValue.rawValue }
    }

    var placeTypeValue: PlaceType {
        get { PlaceType(rawValue: placeType ?? "") ?? .other }
        set { placeType = newValue.rawValue }
    }

    var cuisines: [String] {
        get { decodeList(from: cuisinesStorage) }
        set { cuisinesStorage = encodeList(newValue) }
    }

    var tags: [String] {
        get { decodeList(from: tagsStorage) }
        set { tagsStorage = encodeList(newValue) }
    }

    var instagramURLValue: URL? {
        guard let instagramURL, !instagramURL.isEmpty else {
            return nil
        }

        return URL(string: instagramURL)
    }

    var displayListName: String {
        feastList?.displayName ?? "No List"
    }

    var displaySectionPath: String {
        listSection?.pathDisplay ?? "No section yet"
    }

    var statusAndTypeSummary: String {
        "\(placeStatus.rawValue) • \(placeTypeValue.rawValue)"
    }

    var cuisineTagPreview: String? {
        let previewValues = Array((cuisines + tags).prefix(4))
        guard !previewValues.isEmpty else {
            return nil
        }

        return previewValues.joined(separator: " • ")
    }

    private func decodeList(from storedValue: String?) -> [String] {
        guard let storedValue, !storedValue.isEmpty else {
            return []
        }

        return storedValue
            .split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    private func encodeList(_ values: [String]) -> String? {
        let normalized = values
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        guard !normalized.isEmpty else {
            return nil
        }

        return normalized.joined(separator: "\n")
    }
}
