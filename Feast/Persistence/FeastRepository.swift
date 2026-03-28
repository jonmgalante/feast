import CoreData
import Foundation
import os

@MainActor
final class FeastRepository {
    enum FeastListError: LocalizedError {
        case ownerRequiredToDeleteSharedList

        var errorDescription: String? {
            switch self {
            case .ownerRequiredToDeleteSharedList:
                return "Only the owner can delete a shared city."
            }
        }
    }

    enum SectionError: LocalizedError {
        case nestedNeighborhoodsUnavailable

        var errorDescription: String? {
            switch self {
            case .nestedNeighborhoodsUnavailable:
                return "Neighborhoods can only be created directly inside a city."
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
        let websiteURL: String?
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
        let websiteURL: String?
        let instagramURL: String?
        let listSection: ListSection?
    }

    struct ImportedSavedPlaceDraft {
        let applePlaceID: String
        let displayNameSnapshot: String
        let status: PlaceStatus
        let placeType: PlaceType
        let cuisines: [String]
        let tags: [String]
        let note: String?
        let websiteURL: String?
        let instagramURL: String?
        let neighborhoodName: String?
    }

    struct ImportSavedPlacesResult: Identifiable, Hashable {
        let id = UUID()
        let cityURIString: String
        let cityName: String
        let addedCount: Int
        let duplicateCount: Int
    }

    enum ImportError: LocalizedError {
        case cityUnavailable

        var errorDescription: String? {
            switch self {
            case .cityUnavailable:
                return "The selected city is no longer available for import."
            }
        }
    }

    enum SeedMode {
        case defaultListsOnly
        case previewDemoContent
    }

    private let context: NSManagedObjectContext
    private let persistenceController: PersistenceController?

    private static let logger = Logger(subsystem: "com.jongalante.Feast", category: "Repository")
    private static let legacySkipGuidancePrefix = "Skip guidance: "

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

    func migrateToCityNeighborhoodModelIfNeeded() throws {
        let feastLists = try fetchFeastLists()
        var didChange = false

        for feastList in feastLists {
            if migrateSections(in: feastList) {
                didChange = true
            }
        }

        if didChange {
            try saveIfNeeded()
        }
    }

    func migrateDeprecatedSkipNotesIfNeeded() throws {
        let request = SavedPlace.fetchRequest()
        request.predicate = NSPredicate(format: "skipNote != nil AND skipNote != ''")

        let savedPlaces = try context.fetch(request)
        var migratedCount = 0

        for savedPlace in savedPlaces {
            if migrateDeprecatedSkipNoteIfNeeded(for: savedPlace) {
                migratedCount += 1
            }
        }

        guard migratedCount > 0 else {
            return
        }

        do {
            try saveIfNeeded()
            Self.logger.notice(
                "Migrated legacy skip notes for \(migratedCount, privacy: .public) saved places."
            )
        } catch {
            context.rollback()
            throw error
        }
    }

    @discardableResult
    func createListSection(
        named name: String,
        in feastList: FeastList,
        parent: ListSection? = nil
    ) throws -> ListSection {
        if parent != nil {
            throw SectionError.nestedNeighborhoodsUnavailable
        }

        let section = makeListSection(
            name: normalizeSectionName(name),
            list: feastList
        )
        touch(feastList)
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
        let feastList = section.feastList

        context.delete(section)
        touch(feastList)
        try saveIfNeeded()
    }

    @discardableResult
    func createSavedPlace(from draft: SavedPlaceDraft) throws -> SavedPlace {
        if let listSection = draft.listSection, listSection.feastList != draft.feastList {
            assertionFailure("Attempted to save a place into a neighborhood that belongs to a different city.")
        }

        let savedPlace = makeSavedPlace(
            applePlaceID: draft.applePlaceID,
            displayName: draft.displayNameSnapshot,
            status: draft.status,
            placeType: draft.placeType,
            cuisines: draft.cuisines,
            tags: draft.tags,
            note: draft.note,
            websiteURL: draft.websiteURL,
            instagramURL: draft.instagramURL,
            list: draft.feastList,
            section: draft.listSection
        )
        touch(draft.feastList)
        touch(draft.listSection)
        try saveIfNeeded()
        return savedPlace
    }

    func importSavedPlaces(
        from drafts: [ImportedSavedPlaceDraft],
        into feastList: FeastList
    ) throws -> ImportSavedPlacesResult {
        guard
            !feastList.isDeleted,
            feastList.managedObjectContext === context
        else {
            throw ImportError.cityUnavailable
        }

        let existingPlaceIDs = Set(
            (feastList.savedPlaces as? Set<SavedPlace> ?? [])
                .compactMap(\.applePlaceIDValue)
        )
        var seenPlaceIDs = existingPlaceIDs
        var neighborhoodsByKey: [String: ListSection] = [:]
        for section in feastList.neighborhoodSections {
            guard
                let key = FeastTag.normalizedKey(for: section.displayName),
                neighborhoodsByKey[key] == nil
            else {
                continue
            }

            neighborhoodsByKey[key] = section
        }

        var addedCount = 0
        var duplicateCount = 0

        do {
            for draft in drafts {
                guard
                    let applePlaceID = normalizedOptional(draft.applePlaceID),
                    let displayNameSnapshot = normalizedOptional(draft.displayNameSnapshot)
                else {
                    continue
                }

                guard !seenPlaceIDs.contains(applePlaceID) else {
                    duplicateCount += 1
                    continue
                }

                let neighborhood = importedNeighborhood(
                    named: draft.neighborhoodName,
                    in: feastList,
                    cache: &neighborhoodsByKey
                )

                _ = makeSavedPlace(
                    applePlaceID: applePlaceID,
                    displayName: displayNameSnapshot,
                    status: draft.status,
                    placeType: draft.placeType,
                    cuisines: normalizedListValues(draft.cuisines),
                    tags: FeastTag.normalizedTags(draft.tags),
                    note: normalizedOptional(draft.note),
                    websiteURL: normalizedOptional(draft.websiteURL),
                    instagramURL: normalizedOptional(draft.instagramURL),
                    list: feastList,
                    section: neighborhood
                )
                seenPlaceIDs.insert(applePlaceID)
                addedCount += 1
            }

            if addedCount > 0 {
                touch(feastList)
                try saveIfNeeded()
            }
        } catch {
            context.rollback()
            throw error
        }

        return ImportSavedPlacesResult(
            cityURIString: feastList.objectURIString,
            cityName: feastList.displayName,
            addedCount: addedCount,
            duplicateCount: duplicateCount
        )
    }

    func update(_ savedPlace: SavedPlace, with metadata: SavedPlaceMetadata) throws {
        let previousSection = savedPlace.listSection

        if let listSection = metadata.listSection, listSection.feastList != savedPlace.feastList {
            assertionFailure("Attempted to save a place into a neighborhood that belongs to a different city.")
        }

        savedPlace.placeStatus = metadata.status
        savedPlace.placeTypeValue = metadata.placeType
        savedPlace.cuisines = metadata.cuisines
        savedPlace.tags = metadata.tags
        savedPlace.note = metadata.note
        savedPlace.websiteURL = metadata.websiteURL
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
        let names = ["NYC", "London", "Philadelphia"]
        return Dictionary(uniqueKeysWithValues: names.map { name in
            (name, makeFeastList(name: name))
        })
    }

    private func seedDemoContent(into lists: [String: FeastList]) {
        guard
            let nyc = lists["NYC"],
            let london = lists["London"],
            let philadelphia = lists["Philadelphia"]
        else {
            return
        }

        let ridgewood = makeListSection(name: "Ridgewood", list: nyc)
        let lowerEastSide = makeListSection(name: "Lower East Side", list: nyc)
        let soho = makeListSection(name: "Soho", list: london)
        let fishtown = makeListSection(name: "Fishtown", list: philadelphia)

        _ = makeSavedPlace(
            applePlaceID: "applemaps-rolo-s-ridgewood",
            displayName: "Rolo's",
            status: .love,
            placeType: .restaurant,
            cuisines: ["American", "Wood-fired"],
            tags: ["Dinner", "Group spot"],
            note: "Excellent for a big dinner and easy repeat visits.",
            websiteURL: nil,
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
            websiteURL: nil,
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
            note: "Good unsorted example for the city detail screen.",
            websiteURL: nil,
            instagramURL: nil,
            list: nyc,
            section: nil
        )

        _ = makeSavedPlace(
            applePlaceID: "applemaps-st-john-soho",
            displayName: "St. JOHN",
            status: .wantToTry,
            placeType: .restaurant,
            cuisines: ["British"],
            tags: ["Classic", "Reservation"],
            note: "A useful London anchor for preview data.",
            websiteURL: nil,
            instagramURL: nil,
            list: london,
            section: soho
        )

        _ = makeSavedPlace(
            applePlaceID: "applemaps-middle-child-clubhouse",
            displayName: "Middle Child Clubhouse",
            status: .been,
            placeType: .restaurant,
            cuisines: ["Sandwiches", "American"],
            tags: ["Lunch", "Casual"],
            note: "A good Philadelphia example with a neighborhood assignment.",
            websiteURL: nil,
            instagramURL: nil,
            list: philadelphia,
            section: fishtown
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
            return "Untitled City"
        }

        return normalized
    }

    private func normalizeSectionName(_ rawValue: String) -> String {
        let normalized = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else {
            return "Untitled Neighborhood"
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
        websiteURL: String?,
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
        savedPlace.websiteURL = websiteURL
        savedPlace.instagramURL = instagramURL
        savedPlace.feastList = list
        savedPlace.listSection = section
        savedPlace.createdAt = now
        savedPlace.updatedAt = now
        persistenceController?.assign(savedPlace, toSameStoreAs: list)

        return savedPlace
    }

    private func importedNeighborhood(
        named rawName: String?,
        in feastList: FeastList,
        cache: inout [String: ListSection]
    ) -> ListSection? {
        guard let normalizedName = FeastTag.collapsed(rawName ?? "") else {
            return nil
        }

        guard let key = FeastTag.normalizedKey(for: normalizedName) else {
            return nil
        }

        if let existingNeighborhood = cache[key] {
            return existingNeighborhood
        }

        let neighborhood = makeListSection(name: normalizedName, list: feastList)
        cache[key] = neighborhood
        touch(neighborhood)
        return neighborhood
    }

    private func normalizedOptional(_ rawValue: String?) -> String? {
        guard let rawValue else {
            return nil
        }

        let trimmed = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private func normalizedListValues(_ values: [String]) -> [String] {
        var normalizedValues: [String] = []
        var seenKeys: Set<String> = []

        for value in values {
            guard let normalizedValue = normalizedOptional(value) else {
                continue
            }

            let key = normalizedValue.folding(
                options: [.caseInsensitive, .diacriticInsensitive],
                locale: .current
            )

            guard !seenKeys.contains(key) else {
                continue
            }

            seenKeys.insert(key)
            normalizedValues.append(normalizedValue)
        }

        return normalizedValues
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

    private func migrateDeprecatedSkipNoteIfNeeded(for savedPlace: SavedPlace) -> Bool {
        guard let skipNote = normalizedOptional(savedPlace.skipNote) else {
            return false
        }

        let mergedNote = mergedNote(savedPlace.note, withDeprecatedSkipNote: skipNote)
        let didChangeNote = savedPlace.note != mergedNote
        let hadLegacySkipNote = savedPlace.skipNote != nil

        if didChangeNote {
            savedPlace.note = mergedNote
        }

        guard hadLegacySkipNote else {
            return didChangeNote
        }

        savedPlace.skipNote = nil
        return didChangeNote || hadLegacySkipNote
    }

    private func mergedNote(_ existingNote: String?, withDeprecatedSkipNote skipNote: String) -> String {
        let skipGuidanceBlock = Self.legacySkipGuidancePrefix + skipNote

        guard let existingNote, !existingNote.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return skipGuidanceBlock
        }

        if noteContainsDeprecatedSkipGuidance(existingNote, skipNote: skipNote) {
            return existingNote
        }

        return existingNote + "\n\n" + skipGuidanceBlock
    }

    private func noteContainsDeprecatedSkipGuidance(_ note: String, skipNote: String) -> Bool {
        let normalizedNote = normalizedMigrationText(note)
        let normalizedSkipNote = normalizedMigrationText(skipNote)
        let normalizedGuidanceBlock = normalizedMigrationText(Self.legacySkipGuidancePrefix + skipNote)

        return normalizedNote.contains(normalizedGuidanceBlock) || normalizedNote.contains(normalizedSkipNote)
    }

    private func normalizedMigrationText(_ rawValue: String) -> String {
        rawValue
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
    }

    private func migrateSections(in feastList: FeastList) -> Bool {
        let allSections = stableSections(from: feastList.sortedSections)
        guard !allSections.isEmpty else {
            return false
        }

        let retirementCandidates = Set(
            allSections
                .filter { !$0.sortedChildren.isEmpty && $0.sortedSavedPlaces.isEmpty }
                .map(\.objectID)
        )

        var didChange = false
        var neighborhoodsByKey: [String: ListSection] = [:]

        for section in stableSections(from: feastList.topLevelSections) {
            let key = normalizedSectionKey(for: section.displayName)

            if let existing = neighborhoodsByKey[key] {
                didChange = merge(section, into: existing) || didChange
            } else {
                neighborhoodsByKey[key] = section
            }
        }

        let nestedSections = allSections.sorted { lhs, rhs in
            if lhs.depth != rhs.depth {
                return lhs.depth > rhs.depth
            }

            return stableSectionLessThan(lhs, rhs)
        }

        for section in nestedSections where section.parent != nil && !section.isDeleted {
            let key = normalizedSectionKey(for: section.displayName)

            if let existing = neighborhoodsByKey[key], existing.objectID != section.objectID {
                didChange = merge(section, into: existing) || didChange
            } else {
                section.parent = nil
                touch(section)
                touch(feastList)
                neighborhoodsByKey[key] = section
                didChange = true
            }
        }

        neighborhoodsByKey.removeAll()

        for section in stableSections(from: feastList.topLevelSections) where !section.isDeleted {
            let key = normalizedSectionKey(for: section.displayName)

            if let existing = neighborhoodsByKey[key], existing.objectID != section.objectID {
                didChange = merge(section, into: existing) || didChange
            } else {
                neighborhoodsByKey[key] = section
            }
        }

        for section in allSections where retirementCandidates.contains(section.objectID) && !section.isDeleted {
            if section.parent == nil && section.sortedChildren.isEmpty && section.sortedSavedPlaces.isEmpty {
                context.delete(section)
                touch(feastList)
                didChange = true
            }
        }

        return didChange
    }

    @discardableResult
    private func merge(_ source: ListSection, into destination: ListSection) -> Bool {
        guard source.objectID != destination.objectID, !source.isDeleted else {
            return false
        }

        var didChange = false
        let now = Date()

        let savedPlaces = source.savedPlaces as? Set<SavedPlace> ?? []
        for savedPlace in savedPlaces where savedPlace.listSection != destination {
            savedPlace.listSection = destination
            savedPlace.updatedAt = now
            didChange = true
        }

        let children = source.children as? Set<ListSection> ?? []
        for child in children where child.parent == source {
            child.parent = nil
            touch(child)
            didChange = true
        }

        if didChange {
            touch(destination)
            touch(destination.feastList)
        }

        context.delete(source)
        touch(destination.feastList)
        return true
    }

    private func stableSections(from sections: [ListSection]) -> [ListSection] {
        sections.sorted(by: stableSectionLessThan)
    }

    private func stableSectionLessThan(_ lhs: ListSection, _ rhs: ListSection) -> Bool {
        let lhsCreatedAt = lhs.createdAt ?? .distantPast
        let rhsCreatedAt = rhs.createdAt ?? .distantPast

        if lhsCreatedAt != rhsCreatedAt {
            return lhsCreatedAt < rhsCreatedAt
        }

        let nameComparison = lhs.displayName.localizedCaseInsensitiveCompare(rhs.displayName)
        if nameComparison != .orderedSame {
            return nameComparison == .orderedAscending
        }

        return lhs.objectID.uriRepresentation().absoluteString < rhs.objectID.uriRepresentation().absoluteString
    }

    private func normalizedSectionKey(for rawValue: String) -> String {
        rawValue
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
    }
}
