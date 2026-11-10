import CoreData
import Foundation
import Darwin

final class FailingContext: NSManagedObjectContext, @unchecked Sendable {
    override func save() throws { throw NSError(domain: "SyntheticSaveFailure", code: 1) }
}

@main struct PersistenceSafetyTests {
    @MainActor static func main() async throws {
        setbuf(stdout, nil)
        try await MapPlaceLookupTests.run()
        let model = NSManagedObjectModel(contentsOf: URL(fileURLWithPath: CommandLine.arguments[1]))!
        if CommandLine.arguments.count == 4 && CommandLine.arguments[3] == "--verify-real-copy" {
            try RealStoreUpgradeCheck.run(model:model,directory:URL(fileURLWithPath:CommandLine.arguments[2]));return
        }
        let url = URL(fileURLWithPath: CommandLine.arguments[2]).appendingPathComponent("synthetic.sqlite")
        func coordinator() throws -> NSPersistentStoreCoordinator {
            let coordinator = NSPersistentStoreCoordinator(managedObjectModel: model)
            try coordinator.addPersistentStore(ofType: NSSQLiteStoreType, configurationName: nil, at: url)
            return coordinator
        }
        func context(_ coordinator: NSPersistentStoreCoordinator) -> NSManagedObjectContext {
            let context = NSManagedObjectContext(concurrencyType: .mainQueueConcurrencyType)
            context.persistentStoreCoordinator = coordinator
            return context
        }
        let unavailable = NSManagedObjectContext(concurrencyType: .mainQueueConcurrencyType)
        do { try FeastRepository(context: unavailable).runStartupMigrations(); fatalError("Expected missing coordinator rejection") }
        catch FeastRepository.StartupMigrationError.storesUnavailable {}
        let unloadedCoordinator = NSPersistentStoreCoordinator(managedObjectModel: model)
        let unloaded = context(unloadedCoordinator)
        do { try FeastRepository(context: unloaded).runStartupMigrations(); fatalError("Expected missing store rejection") }
        catch FeastRepository.StartupMigrationError.storesUnavailable {}
        precondition(!unavailable.hasChanges && !unloaded.hasChanges && unloadedCoordinator.persistentStores.isEmpty)
        print("PASS startup rejects missing coordinator or stores without exposing an empty collection")
        let ids = (0..<5).map { _ in UUID() }
        var coordinator1: NSPersistentStoreCoordinator? = try coordinator()
        var original: NSManagedObjectContext? = context(coordinator1!)
        do {
            let city = FeastList(context: original!); city.id = ids[0]; city.name = "Synthetic City"
            let parent = ListSection(context: original!); parent.id = ids[1]; parent.name = "Duplicate"; parent.feastList = city
            let child = ListSection(context: original!); child.id = ids[2]; child.name = "Duplicate"; child.parent = parent; child.feastList = city
            let empty = ListSection(context: original!); empty.id = ids[3]; empty.name = "Empty"; empty.feastList = city
            let place = SavedPlace(context: original!); place.id = ids[4]; place.feastList = city; place.listSection = child
            place.createdAt = Date(timeIntervalSince1970: 123456.125)
            place.updatedAt = Date(timeIntervalSince1970: 234567.875)
            place.websiteURL = "https://example.invalid/place"; place.instagramURL = "https://example.invalid/social"
            place.placeStatus = .love; place.placeTypeValue = .cafe; place.cuisines = ["Synthetic cuisine"]
            place.applePlaceID = "synthetic-only"; place.note = "Original note"; place.skipNote = "Legacy guidance"; place.tags = ["One", "Two"]
            try original!.save()
        }
        original = nil
        for store in coordinator1!.persistentStores { try coordinator1!.remove(store) }
        coordinator1 = nil
        let reopened = try coordinator()
        let migration = context(reopened)
        try FeastRepository(context: migration).runStartupMigrations()
        migration.reset()
        let sections = try migration.fetch(ListSection.fetchRequest())
        precondition(Set(sections.compactMap(\.id)) == Set(ids[1...3]))
        precondition(sections.allSatisfy { $0.parent == nil })
        let place = try migration.fetch(SavedPlace.fetchRequest()).first!
        precondition(place.id == ids[4] && place.feastList?.id == ids[0] && place.listSection?.id == ids[2])
        precondition(place.note?.contains("Original note") == true && place.note?.contains("Legacy guidance") == true)
        precondition(place.tags == ["One", "Two"] && place.applePlaceID == "synthetic-only")
        let note = place.note
        let metadataBeforePendingEdit = reopened.metadata(for: reopened.persistentStores[0]) as NSDictionary
        place.note = "Pending user draft"
        do { try FeastRepository(context: migration).runStartupMigrations(); fatalError("Expected pending edit rejection") }
        catch FeastRepository.StartupMigrationError.pendingEdits {}
        precondition(place.note == "Pending user draft" && migration.hasChanges)
        precondition(metadataBeforePendingEdit.isEqual(to: reopened.metadata(for: reopened.persistentStores[0])))
        let persistedCheck = context(reopened)
        let persistedPlace = try persistedCheck.fetch(SavedPlace.fetchRequest()).first!
        precondition(persistedPlace.note == note)
        migration.rollback()
        precondition(place.note == note && !migration.hasChanges)
        print("PASS startup refuses a dirty context without committing, discarding, or changing its draft or migration metadata")
        try FeastRepository(context: migration).runStartupMigrations()
        precondition(place.note == note && !migration.hasChanges)
        print("PASS populated disk-store upgrade preserves UUIDs, duplicate/empty sections, assignments, tags, notes; repeat launch is stable")
        // Force replay as if interrupted between the data save and metadata marker.
        let store = reopened.persistentStores[0]
        var metadata = reopened.metadata(for: store); metadata.removeValue(forKey: "FeastSafeStartupMigrationVersion"); reopened.setMetadata(metadata, for: store)
        try FeastRepository(context: migration).runStartupMigrations()
        let sectionCount = try migration.count(for: ListSection.fetchRequest())
        precondition(place.note == note && sectionCount == 3)
        place.note = "bread"; place.skipNote = "red"; try migration.save()
        reopened.setMetadata(metadata, for: store)
        try FeastRepository(context: migration).runStartupMigrations()
        precondition(place.note == "bread\n\nSkip guidance: red" && place.skipNote == nil)
        reopened.setMetadata(metadata, for: store)
        try FeastRepository(context: migration).runStartupMigrations()
        precondition(place.note == "bread\n\nSkip guidance: red")
        place.note = note; try migration.save()
        print("PASS interrupted marker replay is idempotent")
        // Save failure must leave neither durable edits nor pending mutations.
        metadata.removeValue(forKey: "FeastSafeStartupMigrationVersion"); reopened.setMetadata(metadata, for: store)
        place.skipNote = "Second legacy note"
        let retainedParent = sections.first { $0.id == ids[1] }!
        place.listSection!.parent = retainedParent
        try migration.save()
        let failing = FailingContext(concurrencyType: .mainQueueConcurrencyType); failing.persistentStoreCoordinator = reopened
        do { try FeastRepository(context: failing).runStartupMigrations(); fatalError("Expected failure") } catch {}
        precondition(!failing.hasChanges)
        migration.refreshAllObjects()
        precondition(place.skipNote == "Second legacy note" && place.note == note && place.listSection?.parent?.id == ids[1])
        precondition(reopened.metadata(for: store)["FeastSafeStartupMigrationVersion"] == nil)
        print("PASS failed startup rolls back all pending edits and leaves migration retryable")
        let failingPlace = try failing.fetch(SavedPlace.fetchRequest()).first!
        do { try FeastRepository(context: failing).delete(failingPlace); fatalError("Expected failure") } catch {}
        precondition(!failing.hasChanges && !failingPlace.isDeleted)
        let failingRepository = FeastRepository(context: failing)
        let draftSection = try failingRepository.createListSection(named: "Unsaved synthetic section", in: failingPlace.feastList!, saveImmediately: false)
        do {
            try failingRepository.update(failingPlace, with: FeastRepository.SavedPlaceMetadata(
                status: .been, placeType: .bar, cuisines: [], tags: [], note: "Failed edit",
                websiteURL: nil, instagramURL: nil, listSection: draftSection, location: nil))
            fatalError("Expected edit failure")
        } catch {}
        precondition(!failing.hasChanges && failingPlace.note == note)
        let sectionCountAfterFailure = try failing.count(for: ListSection.fetchRequest())
        precondition(sectionCountAfterFailure == 3)
        print("PASS failed delete rolls back pending deletion")
        let snapshot = try PlaceExport.capture(context: migration)
        let data = try snapshot.validatedData()
        let decoded = try JSONDecoder().decode(PlaceExport.self, from: data)
        precondition(decoded == snapshot && decoded.places[0].note == note && decoded.places[0].skipNote == "Second legacy note")
        precondition(decoded.neighborhoods.count == 3 && decoded.places[0].neighborhoodID == ids[2])
        precondition(decoded.places[0].createdAt == Date(timeIntervalSince1970: 123456.125))
        precondition(decoded.places[0].updatedAt == Date(timeIntervalSince1970: 234567.875))
        precondition(decoded.places[0].websiteURL == "https://example.invalid/place" && decoded.places[0].instagramURL == "https://example.invalid/social")
        precondition(decoded.places[0].status == PlaceStatus.love.rawValue && decoded.places[0].placeType == PlaceType.cafe.rawValue)
        precondition(decoded.places[0].cuisinesStorage == place.cuisinesStorage && decoded.places[0].tagsStorage == place.tagsStorage)
        // Shared-store semantics: enumerate all loaded stores, without any CloudKit adapter.
        let dual = NSPersistentStoreCoordinator(managedObjectModel: model)
        let dualContext = context(dual)
        for name in ["synthetic-private.sqlite", "synthetic-shared.sqlite"] {
            let dualStore = try dual.addPersistentStore(ofType: NSSQLiteStoreType, configurationName: nil,
                at: URL(fileURLWithPath: CommandLine.arguments[2]).appendingPathComponent(name))
            let city = FeastList(context: dualContext); city.id = UUID(); city.name = name
            dualContext.assign(city, to: dualStore)
            let saved = SavedPlace(context: dualContext); saved.id = UUID(); saved.note = name; saved.feastList = city
            dualContext.assign(saved, to: dualStore)
        }
        try dualContext.save()
        let dualExport = try PlaceExport.capture(context: dualContext)
        precondition(dualExport.cities.count == 2 && dualExport.places.count == 2)
        _ = try dualExport.validatedData()
        print("PASS versioned export round-trip preserves notes, legacy guidance and organization")
        place.note = "Unsaved synthetic draft"
        do { _ = try PlaceExport.capture(context: migration); fatalError("Expected unsaved rejection") } catch {}
        migration.rollback()
        var corrupt = snapshot; corrupt.version = 99
        do { _ = try corrupt.validatedData(); fatalError("Expected invalid version rejection") } catch {}
        let orphan = PlaceExport(exportedAt: snapshot.exportedAt, cities: snapshot.cities, neighborhoods: [], places: snapshot.places)
        do { _ = try orphan.validatedData(); fatalError("Expected orphan rejection") } catch {}
        let crossCity = PlaceExport(exportedAt: Date(), cities: dualExport.cities, neighborhoods: [
            PlaceExport.Neighborhood(id: ids[1], cityID: dualExport.cities[0].id, parentID: ids[2], name: nil, createdAt: nil, updatedAt: nil),
            PlaceExport.Neighborhood(id: ids[2], cityID: dualExport.cities[1].id, parentID: nil, name: nil, createdAt: nil, updatedAt: nil)
        ], places: [])
        do { _ = try crossCity.validatedData(); fatalError("Expected cross-city parent rejection") } catch {}
        print("PASS export rejects pending edits and unsupported versions")
        precondition(PlaceSearchContext.query("Cafe", cityName: "Paris") == "Cafe, Paris")
        precondition(PlaceSearchContext.query("Cafe, Paris", cityName: "Paris") == "Cafe, Paris")
        precondition(PlaceSearchContext.query("10 Main St", cityName: nil) == "10 Main St")
        var queries: [String] = []
        let fallbackResults = try await PlaceSearchContext.search("Cafe", cityName: "Paris") { query in
            queries.append(query); return []
        }
        precondition(fallbackResults.isEmpty && queries == ["Cafe, Paris", "Cafe"])
        queries = []
        _ = try await PlaceSearchContext.search("Cafe, Paris", cityName: "Paris") { query in queries.append(query); return [] }
        precondition(queries == ["Cafe, Paris"])
        print("PASS selected-city search context and explicit address preservation")
        let item = NotesImportReviewItem(id: UUID(), sourceLineNumber: 1, parsedPlaceName: "Cafe",
            status: .wantToTry, placeType: nil, cuisines: [], tags: [], note: "Keep note", websiteURL: nil,
            instagramURL: nil, parsedNeighborhoodName: nil, selectedNeighborhoodName: nil,
            matchedPlace: nil, suggestedMatches: [], isSkipped: false, matchingErrorMessage: nil)
        func match(_ id: String, address: String) -> ApplePlaceMatch {
            ApplePlaceMatch(applePlaceID: id, displayName: "Cafe", secondaryText: address,
                coordinate: nil, suggestedSectionPath: ApplePlaceSectionPathSuggestion(cityOrRegion: "Paris", neighborhood: nil), websiteURL: nil, instagramURL: nil)
        }
        let branchA = match("synthetic-A", address: "1 Street, Paris")
        let branchB = match("synthetic-B", address: "2 Street, Paris")
        var contextualCalls = 0
        let successfulContext = try await PlaceSearchContext.search("Cafe", cityName: "Paris") { _ in contextualCalls += 1; return [branchA] }
        precondition(successfulContext == [branchA] && contextualCalls == 1)
        let ambiguous = await NotesImportMatcher.match(item, cityName: "Paris", neighborhoodNames: [], using: ApplePlacesService(matches: [branchA, branchB]))
        precondition(ambiguous.matchedPlace == nil && ambiguous.suggestedMatches.count == 2 && ambiguous.bucket == .needsReview)
        let unique = await NotesImportMatcher.match(item, cityName: "Paris", neighborhoodNames: [], using: ApplePlacesService(matches: [branchA]))
        precondition(unique.matchedPlace?.applePlaceID == branchA.applePlaceID)
        var edited = item; edited.isSkipped = true
        precondition(edited.applyingBackgroundMatch(unique, original: item, wasEdited: false, preserveNeighborhood: false) == edited)
        precondition(item.applyingBackgroundMatch(unique, original: item, wasEdited: true, preserveNeighborhood: false) == item)
        precondition(item.applyingBackgroundMatch(unique, original: item, wasEdited: false, preserveNeighborhood: false) == unique)
        var correctedNeighborhood = item; correctedNeighborhood.selectedNeighborhoodName = "User neighborhood"
        let merged = correctedNeighborhood.applyingBackgroundMatch(unique, original: item, wasEdited: false, preserveNeighborhood: true)
        precondition(merged.matchedPlace == branchA && merged.selectedNeighborhoodName == "User neighborhood")
        print("PASS ambiguous branches require review; unique contextual match accepted; user corrections reject stale matcher results")
        let lookup = MapPlaceLookup()
        var calls = 0
        let pin = ApplePlaceMatch(applePlaceID: "pin", displayName: "Synthetic Pin", secondaryText: "Fixture address",
            coordinate: ApplePlaceCoordinate(latitude: 1, longitude: 1),
            suggestedSectionPath: ApplePlaceSectionPathSuggestion(cityOrRegion: nil, neighborhood: nil), websiteURL: nil, instagramURL: nil)
        _ = try await lookup.resolve(placeID: "pin") { _ in calls += 1; return pin }
        _ = try await lookup.resolve(placeID: "pin") { _ in calls += 1; return pin }
        precondition(calls == 1)
        _ = try await lookup.resolve(placeID: "missing") { _ in calls += 1; return nil }
        _ = try await lookup.resolve(placeID: "missing") { _ in calls += 1; return pin }
        precondition(calls == 3)
        // Simulate a provider completing after SwiftUI cancels an obsolete city task.
        var continuation: CheckedContinuation<ApplePlaceMatch?, Never>?
        let stale = Task { @MainActor in
            try await lookup.resolve(placeID: "stale") { _ in
                await withCheckedContinuation { continuation = $0 }
            }
        }
        while continuation == nil { await Task.yield() }
        stale.cancel()
        continuation!.resume(returning: pin)
        do { _ = try await stale.value; fatalError("Cancelled lookup published result") } catch is CancellationError {} catch { throw error }
        var staleCalls = 0
        _ = try await lookup.resolve(placeID: "stale") { _ in staleCalls += 1; return pin }
        precondition(staleCalls == 1)
        print("PASS map success cache, retry after missing result, and cancellation after provider completion")
        let retry = context(reopened); try FeastRepository(context: retry).runStartupMigrations()
        print("PASS startup succeeds after failed attempt")
        retry.reset(); failing.reset(); migration.reset()
        for store in reopened.persistentStores { try reopened.remove(store) }
        let finalCoordinator = try coordinator()
        let finalContext = context(finalCoordinator)
        let finalPlace = try finalContext.fetch(SavedPlace.fetchRequest()).first!
        precondition(finalPlace.id == ids[4] && finalPlace.listSection?.parent == nil)
        precondition((finalCoordinator.metadata(for: finalCoordinator.persistentStores[0])["FeastSafeStartupMigrationVersion"] as? Int) == 1)
        let emptyURL = URL(fileURLWithPath: CommandLine.arguments[2]).appendingPathComponent("empty.sqlite")
        let emptyCoordinator = NSPersistentStoreCoordinator(managedObjectModel: model)
        let emptyStore = try emptyCoordinator.addPersistentStore(ofType: NSSQLiteStoreType, configurationName: nil, at: emptyURL)
        let emptyContext = context(emptyCoordinator)
        try FeastRepository(context: emptyContext).runStartupMigrations()
        emptyContext.reset(); try emptyCoordinator.remove(emptyStore)
        let reopenedEmpty = try emptyCoordinator.addPersistentStore(ofType: NSSQLiteStoreType, configurationName: nil, at: emptyURL)
        precondition((emptyCoordinator.metadata(for: reopenedEmpty)["FeastSafeStartupMigrationVersion"] as? Int) == 1)
        print("PASS durable migration data and completion marker survive store close/reopen")
        try await LibraryArchiveTests.run(model: model, directory: URL(fileURLWithPath: CommandLine.arguments[2]))
        try await BrowsingConsistencyTests.run(model: model)
        await InstagramAutofillTests.run()
        await NearbyLocationTests.run()
        StatusBadgeTests.run()
        try EmptyStateTests.run(model: model)
        try await AskRecoveryMutationTests.run(model:model,directory:URL(fileURLWithPath:CommandLine.arguments[2]))
        try await AskTurnRecoveryTests.run(model:model,directory:URL(fileURLWithPath:CommandLine.arguments[2]))
        try AskNativeResearchTests.run()
        try await AskNativeResearchTests.runLoop()
        try await AskResearchPilotTests.run()
        try await AskPhoneActivationTests.run()
        try await AskAccessManagementTests.run()
        try await AskPerformanceTests.run(model:model,temporaryDirectory:URL(fileURLWithPath:CommandLine.arguments[2]))
        try await AskAgentExecutorTests.run(model:model,temporaryDirectory:URL(fileURLWithPath:CommandLine.arguments[2]))
        try await AskCollectionContextTests.run(model:model,temporaryDirectory:URL(fileURLWithPath:CommandLine.arguments[2]))
        try await AskPlaceReferenceTests.run(model:model,temporaryDirectory:URL(fileURLWithPath:CommandLine.arguments[2]))
        try await AskAnswerAcceptanceTests.run(model:model,temporaryDirectory:URL(fileURLWithPath:CommandLine.arguments[2]))
        try await AskAgentLoopTests.run()
        try await AskConversationLoopTests.run()
        try await AskRetryStorageTests.run(directory:URL(fileURLWithPath:CommandLine.arguments[2]))
        try await AskLifecycleAdmissionTests.run(model:model,directory:URL(fileURLWithPath:CommandLine.arguments[2]))
        try await AskConversationPersistenceTests.run(model:model,directory:URL(fileURLWithPath:CommandLine.arguments[2]))
        try AskCollectionChangeTests.run(model:model,temporaryDirectory:URL(fileURLWithPath:CommandLine.arguments[2]))
        try await AskFieldActionTests.run(model:model,temporaryDirectory:URL(fileURLWithPath:CommandLine.arguments[2]))
        try await AskBusinessLookupTests.run()
        try await AskUXSafetyTests.run(model: model, temporaryDirectory: URL(fileURLWithPath: CommandLine.arguments[2]))
        try await AskFeastPrototypeTests.run(model: model, temporaryDirectory: URL(fileURLWithPath: CommandLine.arguments[2]))
    }
}
