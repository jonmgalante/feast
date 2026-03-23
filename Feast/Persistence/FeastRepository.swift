import CoreData
import Foundation

@MainActor
final class FeastRepository {
    enum FeastListError: LocalizedError {
        case ownerRequiredToDeleteSharedList

        var errorDescription: String? {
            switch self {
            case .ownerRequiredToDeleteSharedList:
                return "Only the owner can delete an entire shared list."
            }
        }
    }

    enum SectionError: LocalizedError {
        case invalidParentDepth

        var errorDescription: String? {
            switch self {
            case .invalidParentDepth:
                return "Feast v1 supports at most two section levels under a list."
            }
        }
    }

    struct SavedPlaceDraft {
        let applePlaceID: String
        let displayNameSnapshot: String
        let status: PlaceStatus
        let placeType: PlaceType
        let cuisines: [String]
        let tags: [String]
        let note: String?
        let skipNote: String?
        let instagramURL: String?
        let feastList: FeastList
        let listSection: ListSection?
    }

    struct SavedPlaceMetadata {
        let status: PlaceStatus
        let placeType: PlaceType
        let cuisines: [String]
        let tags: [String]
        let note: String?
        let skipNote: String?
        let instagramURL: String?
        let listSection: ListSection?
    }

    enum SeedMode {
        case defaultListsOnly
        case previewDemoContent
    }

    private let context: NSManagedObjectContext
    private let persistenceController: PersistenceController?

    init(
        context: NSManagedObjectContext,
        persistenceController: PersistenceController? = nil
    ) {
        self.context = context
        self.persistenceController = persistenceController
    }

    func fetchFeastLists() throws -> [FeastList] {
        let request = FeastList.fetchRequest()
        request.sortDescriptors = [
            NSSortDescriptor(key: "name", ascending: true)
        ]
        return try context.fetch(request)
    }

    func fetchSavedPlaces() throws -> [SavedPlace] {
        let request = SavedPlace.fetchRequest()
        request.sortDescriptors = [
            NSSortDescriptor(key: "updatedAt", ascending: false),
            NSSortDescriptor(key: "displayNameSnapshot", ascending: true)
        ]
        return try context.fetch(request)
    }

    func fetchPreviewFeastList(named name: String) -> FeastList {
        let request = FeastList.fetchRequest()
        request.fetchLimit = 1
        request.predicate = NSPredicate(format: "name == %@", name)
        return (try? context.fetch(request).first) ?? makeFeastList(name: name)
    }

    @discardableResult
    func createFeastList(named name: String) throws -> FeastList {
        let normalizedName = normalizeListName(name)
        let feastList = makeFeastList(name: normalizedName)
        try saveIfNeeded()
        return feastList
    }

    func rename(_ feastList: FeastList, to name: String) throws {
        feastList.name = normalizeListName(name)
        feastList.updatedAt = Date()
        try saveIfNeeded()
    }

    func delete(_ feastList: FeastList) throws {
        if let persistenceController, !persistenceController.canDeleteFeastList(feastList) {
            throw FeastListError.ownerRequiredToDeleteSharedList
        }

        context.delete(feastList)
        try saveIfNeeded()
    }

    @discardableResult
    func createListSection(
        named name: String,
        in feastList: FeastList,
        parent: ListSection? = nil
    ) throws -> ListSection {
        if let parent, parent.depth >= 1 {
            throw SectionError.invalidParentDepth
        }

        let section = makeListSection(
            name: normalizeSectionName(name),
            list: feastList,
            parent: parent
        )
        touch(feastList)
        touch(parent)
        try saveIfNeeded()
        return section
    }

    func rename(_ section: ListSection, to name: String) throws {
        section.name = normalizeSectionName(name)
        touch(section)
        touch(section.feastList)
        try saveIfNeeded()
    }

    func delete(_ section: ListSection) throws {
        let parent = section.parent
        let feastList = section.feastList

        context.delete(section)
        touch(parent)
        touch(feastList)
        try saveIfNeeded()
    }

    @discardableResult
    func createSavedPlace(from draft: SavedPlaceDraft) throws -> SavedPlace {
        if let listSection = draft.listSection, listSection.feastList != draft.feastList {
            assertionFailure("Attempted to save a place into a section that belongs to a different list.")
        }

        let savedPlace = makeSavedPlace(
            applePlaceID: draft.applePlaceID,
            displayName: draft.displayNameSnapshot,
            status: draft.status,
            placeType: draft.placeType,
            cuisines: draft.cuisines,
            tags: draft.tags,
            note: draft.note,
            skipNote: draft.skipNote,
            instagramURL: draft.instagramURL,
            list: draft.feastList,
            section: draft.listSection
        )
        touch(draft.feastList)
        touch(draft.listSection)
        try saveIfNeeded()
        return savedPlace
    }

    func update(_ savedPlace: SavedPlace, with metadata: SavedPlaceMetadata) throws {
        let previousSection = savedPlace.listSection

        if let listSection = metadata.listSection, listSection.feastList != savedPlace.feastList {
            assertionFailure("Attempted to save a place into a section that belongs to a different list.")
        }

        savedPlace.placeStatus = metadata.status
        savedPlace.placeTypeValue = metadata.placeType
        savedPlace.cuisines = metadata.cuisines
        savedPlace.tags = metadata.tags
        savedPlace.note = metadata.note
        savedPlace.skipNote = metadata.skipNote
        savedPlace.instagramURL = metadata.instagramURL
        savedPlace.listSection = metadata.listSection
        savedPlace.updatedAt = Date()

        touch(savedPlace.feastList)
        touch(previousSection)
        if previousSection != metadata.listSection {
            touch(metadata.listSection)
        }

        try saveIfNeeded()
    }

    func delete(_ savedPlace: SavedPlace) throws {
        let feastList = savedPlace.feastList
        let section = savedPlace.listSection

        context.delete(savedPlace)
        touch(feastList)
        touch(section)
        try saveIfNeeded()
    }

    func seedIfNeeded(mode: SeedMode) throws {
        let countRequest = FeastList.fetchRequest()
        countRequest.includesSubentities = false

        guard try context.count(for: countRequest) == 0 else {
            return
        }

        let lists = seedDefaultLists()

        if mode == .previewDemoContent {
            seedDemoContent(into: lists)
        }

        try saveIfNeeded()
    }

    private func seedDefaultLists() -> [String: FeastList] {
        let names = ["NYC", "USA", "International"]
        return Dictionary(uniqueKeysWithValues: names.map { name in
            (name, makeFeastList(name: name))
        })
    }

    private func seedDemoContent(into lists: [String: FeastList]) {
        guard
            let nyc = lists["NYC"],
            let usa = lists["USA"],
            let international = lists["International"]
        else {
            return
        }

        let brooklyn = makeListSection(name: "Brooklyn", list: nyc)
        let ridgewood = makeListSection(name: "Ridgewood", list: nyc, parent: brooklyn)
        let manhattan = makeListSection(name: "Manhattan", list: nyc)
        let lowerEastSide = makeListSection(name: "Lower East Side", list: nyc, parent: manhattan)

        let california = makeListSection(name: "California", list: usa)
        let losAngeles = makeListSection(name: "Los Angeles", list: usa, parent: california)

        let tokyo = makeListSection(name: "Tokyo", list: international)
        let shibuya = makeListSection(name: "Shibuya", list: international, parent: tokyo)

        _ = makeSavedPlace(
            applePlaceID: "applemaps-rolo-s-ridgewood",
            displayName: "Rolo's",
            status: .love,
            placeType: .restaurant,
            cuisines: ["American", "Wood-fired"],
            tags: ["Dinner", "Group spot"],
            note: "Excellent for a big dinner and easy repeat visits.",
            skipNote: nil,
            instagramURL: "https://www.instagram.com/rolosnyc",
            list: nyc,
            section: ridgewood
        )

        _ = makeSavedPlace(
            applePlaceID: "applemaps-dhamaka-les",
            displayName: "Dhamaka",
            status: .been,
            placeType: .restaurant,
            cuisines: ["Indian"],
            tags: ["Spicy", "Special occasion"],
            note: "Still worth revisiting for the larger-format dishes.",
            skipNote: nil,
            instagramURL: nil,
            list: nyc,
            section: lowerEastSide
        )

        _ = makeSavedPlace(
            applePlaceID: "applemaps-librae-bakery",
            displayName: "Librae Bakery",
            status: .wantToTry,
            placeType: .bakery,
            cuisines: ["Bakery", "Middle Eastern"],
            tags: ["Breakfast"],
            note: "Good unsorted example for the list detail screen.",
            skipNote: nil,
            instagramURL: nil,
            list: nyc,
            section: nil
        )

        _ = makeSavedPlace(
            applePlaceID: "applemaps-bar-etoile-la",
            displayName: "Bar Etoile",
            status: .wantToTry,
            placeType: .bar,
            cuisines: ["Wine bar"],
            tags: ["Date night"],
            note: nil,
            skipNote: "Need a trip to LA first.",
            instagramURL: "https://www.instagram.com/baretoile",
            list: usa,
            section: losAngeles
        )

        _ = makeSavedPlace(
            applePlaceID: "applemaps-koffee-mameya-kakeru",
            displayName: "Koffee Mameya Kakeru",
            status: .justOpened,
            placeType: .cafe,
            cuisines: ["Coffee", "Dessert"],
            tags: ["Reservation", "Coffee"],
            note: "Good anchor for a Tokyo coffee list.",
            skipNote: nil,
            instagramURL: nil,
            list: international,
            section: shibuya
        )
    }

    private func makeFeastList(name: String) -> FeastList {
        let feastList = FeastList(context: context)
        let now = Date()

        feastList.id = UUID()
        feastList.name = name
        feastList.createdAt = now
        feastList.updatedAt = now
        persistenceController?.assignToDefaultStore(feastList)

        return feastList
    }

    private func normalizeListName(_ rawValue: String) -> String {
        let normalized = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else {
            return "Untitled List"
        }

        return normalized
    }

    private func normalizeSectionName(_ rawValue: String) -> String {
        let normalized = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else {
            return "Untitled Section"
        }

        return normalized
    }

    private func makeListSection(name: String, list: FeastList, parent: ListSection? = nil) -> ListSection {
        let section = ListSection(context: context)
        let now = Date()

        section.id = UUID()
        section.name = name
        section.feastList = list
        section.parent = parent
        section.createdAt = now
        section.updatedAt = now
        persistenceController?.assign(section, toSameStoreAs: list)

        return section
    }

    @discardableResult
    private func makeSavedPlace(
        applePlaceID: String,
        displayName: String,
        status: PlaceStatus,
        placeType: PlaceType,
        cuisines: [String],
        tags: [String],
        note: String?,
        skipNote: String?,
        instagramURL: String?,
        list: FeastList,
        section: ListSection?
    ) -> SavedPlace {
        let savedPlace = SavedPlace(context: context)
        let now = Date()

        savedPlace.id = UUID()
        savedPlace.applePlaceID = applePlaceID
        savedPlace.displayNameSnapshot = displayName
        savedPlace.placeStatus = status
        savedPlace.placeTypeValue = placeType
        savedPlace.cuisines = cuisines
        savedPlace.tags = tags
        savedPlace.note = note
        savedPlace.skipNote = skipNote
        savedPlace.instagramURL = instagramURL
        savedPlace.feastList = list
        savedPlace.listSection = section
        savedPlace.createdAt = now
        savedPlace.updatedAt = now
        persistenceController?.assign(savedPlace, toSameStoreAs: list)

        return savedPlace
    }

    private func saveIfNeeded() throws {
        guard context.hasChanges else {
            return
        }

        try context.save()
    }

    private func touch(_ feastList: FeastList?) {
        feastList?.updatedAt = Date()
    }

    private func touch(_ section: ListSection?) {
        section?.updatedAt = Date()
    }
}
