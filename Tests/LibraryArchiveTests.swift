import CoreData
import Foundation

/// Host-only tests. Every coordinator uses disposable SQLite files, never CloudKit.
@MainActor enum LibraryArchiveTests {
    static func run(model: NSManagedObjectModel, directory: URL) async throws {
        func open(_ name: String) throws -> (NSPersistentStoreCoordinator, NSManagedObjectContext, NSPersistentStore) {
            let coordinator = NSPersistentStoreCoordinator(managedObjectModel: model)
            let store = try coordinator.addPersistentStore(ofType: NSSQLiteStoreType, configurationName: nil,
                at: directory.appendingPathComponent("library-\(name).sqlite"))
            let context = NSManagedObjectContext(concurrencyType: .mainQueueConcurrencyType)
            context.persistentStoreCoordinator = coordinator
            try FeastRepository(context: context).runStartupMigrations()
            return (coordinator, context, store)
        }
        let (sourceCoordinator, source, sourceStore) = try open("source")
        let date = Date(timeIntervalSinceReferenceDate: 432_123_456.123456)
        let cities = (0..<4).map { index -> FeastList in
            let city = FeastList(context: source)
            city.id = UUID(); city.name = index < 2 ? "Identical city 🌮" : (index == 2 ? "" : nil)
            city.createdAt = index == 3 ? nil : date; city.updatedAt = date.addingTimeInterval(Double(index) / 8)
            return city
        }
        let sections = (0..<5).map { index -> ListSection in
            let section = ListSection(context: source)
            section.id = UUID(); section.name = index < 2 ? "Same neighborhood" : (index == 2 ? "" : nil)
            section.feastList = index == 4 ? nil : cities[index == 3 ? 1 : 0]
            section.createdAt = date.addingTimeInterval(-0.25); section.updatedAt = index == 4 ? nil : date
            return section
        }
        sections[1].parent = sections[0]
        for index in 0..<5 {
            let place = SavedPlace(context: source)
            place.id = UUID(); place.feastList = index == 4 ? nil : cities[index == 2 ? 1 : 0]
            place.listSection = index == 0 ? sections[1] : (index == 2 ? sections[3] : nil)
            place.applePlaceID = index < 3 ? "same-apple-id" : (index == 3 ? "" : nil)
            place.displayNameSnapshot = index == 4 ? nil : (index == 3 ? "" : "Name \(index) 東京 🥟")
            place.status = index == 4 ? nil : (index == 3 ? "" : "Unknown future status")
            place.placeType = index == 4 ? nil : (index == 3 ? "" : "Unknown future type")
            place.cuisinesStorage = index == 4 ? nil : (index == 3 ? "" : "  raw\n\nCafé\r\n ")
            place.tagsStorage = index == 4 ? nil : (index == 3 ? "" : "Raw\nRaw\n unnormalized ")
            place.note = index == 4 ? nil : (index == 3 ? "" : String(repeating: "長い 🌮\n", count: 4_000))
            place.skipNote = index == 4 ? nil : (index == 3 ? "" : "Legacy guidance \(index)")
            place.websiteURL = index == 4 ? nil : (index == 3 ? "" : "not normalized: https://example.invalid/é?q=x ")
            place.instagramURL = index == 4 ? nil : (index == 3 ? "" : "@raw name")
            place.createdAt = index == 4 ? nil : date.addingTimeInterval(-Double(index) / 16)
            place.updatedAt = index == 3 ? nil : date.addingTimeInterval(Double(index) / 32)
        }
        try source.save()
        let archive = try PlaceExport.capture(context: source)
        let bytes = try archive.validatedData()
        let file = directory.appendingPathComponent("synthetic-library.json")
        try bytes.write(to: file)
        let read = try PlaceImport.readFile(at: file)
        precondition(read == archive)
        var withProvenance = archive
        let sourceRecords = archive.cities.map { PlaceExport.RecordSource(entity: "FeastList", id: $0.id, store: .sharedLibrary) }
            + archive.neighborhoods.map { PlaceExport.RecordSource(entity: "ListSection", id: $0.id, store: .privateLibrary) }
            + archive.places.map { PlaceExport.RecordSource(entity: "SavedPlace", id: $0.id, store: .unknown) }
        let sharing = PlaceExport.CitySharing(cityID: archive.cities[0].id, status: .shared,
            ownerRecordName: "synthetic-owner-record", currentUserRole: "privateUser", currentUserPermission: "readWrite",
            publicPermission: "none", participants: [
                .init(userRecordName: "synthetic-owner-record", role: "owner", permission: "readWrite", acceptanceStatus: "accepted"),
                .init(userRecordName: nil, role: "privateUser", permission: "readOnly", acceptanceStatus: "pending")
            ], shareRecordName: "synthetic-share-record", zoneName: "synthetic-zone", zoneOwnerName: "synthetic-zone-owner")
        withProvenance.provenance = .init(capturedAt: date, records: sourceRecords, cities: [sharing])
        try require(PlaceExport.decode(withProvenance.validatedData()) == withProvenance, "V2 sharing provenance failed lossless encoding")
        let expected = try PlaceImport.remappedArchive(archive)
        try assertRawAttributesEqual(archive, expected)
        let sourceIDs = Set(archive.cities.map(\.id) + archive.neighborhoods.map(\.id) + archive.places.map(\.id))
        let destinationIDs = Set(expected.cities.map(\.id) + expected.neighborhoods.map(\.id) + expected.places.map(\.id))
        precondition(sourceIDs.isDisjoint(with: destinationIDs) && destinationIDs.count == sourceIDs.count)
        let (destinationCoordinator, destination, destinationStore) = try open("destination")
        let untouched = FeastList(context: destination); untouched.id = UUID(); untouched.name = "Preexisting unrelated city"
        untouched.createdAt = date; untouched.updatedAt = date
        let untouchedPlace = SavedPlace(context: destination); untouchedPlace.id = UUID(); untouchedPlace.feastList = untouched
        untouchedPlace.note = "Existing private note"; untouchedPlace.applePlaceID = "same-apple-id"
        try destination.save()
        let before = try PlaceExport.capture(context: destination)
        let metadata = destinationCoordinator.metadata(for: destinationStore) as NSDictionary
        let result = try PlaceImport.restore(read, into: destination, privateStore: destinationStore)
        guard case .restored = result else { fatalError("First import must restore") }
        let combined = try PlaceExport.capture(context: destination)
        assertGraph(combined, equals: expected, plus: before)
        precondition(metadata.isEqual(to: destinationCoordinator.metadata(for: destinationStore)))
        precondition(!destination.hasChanges)
        let allObjects = try destination.fetch(FeastList.fetchRequest()) as [NSManagedObject]
            + destination.fetch(ListSection.fetchRequest()) + destination.fetch(SavedPlace.fetchRequest())
        precondition(allObjects.allSatisfy { $0.objectID.persistentStore === destinationStore })
        // Display adapters reveal restored legacy data without rewriting its raw graph.
        let restoredSections = try destination.fetch(ListSection.fetchRequest())
        let restoredChild = restoredSections.first { $0.parent != nil }!
        precondition(restoredChild.isVisibleNeighborhood)
        precondition(restoredChild.feastList!.visibleNeighborhoodSections.contains { $0 === restoredChild })
        precondition(!restoredChild.feastList!.neighborhoodSections.contains { $0 === restoredChild })
        precondition(restoredChild.neighborhoodDisplayName == "Same neighborhood • Same neighborhood")
        precondition(restoredChild.neighborhoodDisplayName == restoredChild.pathDisplay)
        precondition(!sections[1].isVisibleNeighborhood)
        precondition(!cities[0].neighborhoodSections.contains { $0 === sections[1] })
        precondition(!cities[0].visibleNeighborhoodSections.contains { $0 === sections[1] })
        precondition(sections[1].neighborhoodDisplayName == sections[1].displayName)
        let restoredPlaces = try destination.fetch(SavedPlace.fetchRequest()).filter { destinationIDs.contains($0.id!) }
        precondition(restoredPlaces.contains { $0.skipNote == nil })
        precondition(restoredPlaces.contains { $0.skipNote == "" })
        precondition(restoredPlaces.contains { !($0.skipNote ?? "").isEmpty })
        for restoredPlace in restoredPlaces {
            let expectedGuidance = restoredPlace.skipNote.flatMap { $0.isEmpty ? nil : $0 }
            precondition(restoredPlace.restoredLegacyGuidance == expectedGuidance)
        }
        let originalPlaces = try source.fetch(SavedPlace.fetchRequest())
        precondition(originalPlaces.allSatisfy { $0.restoredLegacyGuidance == nil })
        precondition(!source.hasChanges && !destination.hasChanges)
        assertGraph(try PlaceExport.capture(context: source), equals: archive)
        assertGraph(try PlaceExport.capture(context: destination), equals: combined)
        print("PASS library restored nested neighborhoods and legacy guidance are visible without normalizing fields or relationships")
        destination.reset(); try destinationCoordinator.remove(destinationStore)
        let reopenedStore = try destinationCoordinator.addPersistentStore(ofType: NSSQLiteStoreType, configurationName: nil,
            at: directory.appendingPathComponent("library-destination.sqlite"))
        try FeastRepository(context: destination).runStartupMigrations()
        assertGraph(try PlaceExport.capture(context: destination), equals: expected, plus: before)
        guard case .alreadyImported = try PlaceImport.restore(archive, into: destination, privateStore: reopenedStore) else {
            fatalError("Repeated import after reopen must not duplicate")
        }
        // File order, legacy encoding, timestamp, and informational sharing do not mint fresh copies.
        var equivalent = PlaceExport(exportedAt: date, cities: archive.cities.reversed(),
            neighborhoods: archive.neighborhoods.reversed(), places: archive.places.reversed())
        equivalent.version = 1
        equivalent.provenance = PlaceExport.Provenance(capturedAt: date,
            records: archive.cities.map { .init(entity: "FeastList", id: $0.id, store: .sharedLibrary) },
            cities: archive.cities.map { .init(cityID: $0.id, status: .shared, ownerRecordName: "synthetic-owner",
                currentUserRole: "owner", currentUserPermission: "readWrite", publicPermission: "readOnly",
                participants: [.init(userRecordName: "synthetic-participant", role: "privateUser", permission: "readOnly", acceptanceStatus: "accepted")]) })
        guard case .alreadyImported = try PlaceImport.restore(equivalent, into: destination, privateStore: reopenedStore) else {
            fatalError("Equivalent payload must reuse identity")
        }
        let importedPlace = try destination.fetch(SavedPlace.fetchRequest()).first { destinationIDs.contains($0.id!) }!
        importedPlace.note = "User edited after restore"; try destination.save()
        guard case .alreadyImported = try PlaceImport.restore(archive, into: destination, privateStore: reopenedStore) else {
            fatalError("Retry must not overwrite subsequent edits")
        }
        precondition(importedPlace.note == "User edited after restore")
        let afterEdit = try PlaceExport.capture(context: destination)
        importedPlace.note = "Unsaved user draft"
        expectRejected { _ = try PlaceImport.restore(archive, into: destination, privateStore: reopenedStore) }
        precondition(importedPlace.note == "Unsaved user draft" && destination.hasChanges)
        destination.rollback()
        assertGraph(try PlaceExport.capture(context: destination), equals: afterEdit)
        destination.delete(importedPlace); try destination.save()
        let afterDeletion = try PlaceExport.capture(context: destination)
        expectRejected { _ = try PlaceImport.restore(archive, into: destination, privateStore: reopenedStore) }
        assertGraph(try PlaceExport.capture(context: destination), equals: afterDeletion)
        // Attaching a newly downloaded store used to replay migrations over every loaded store.
        let newStore = try destinationCoordinator.addPersistentStore(ofType: NSSQLiteStoreType, configurationName: nil,
            at: directory.appendingPathComponent("library-new-unprepared.sqlite"))
        expectRejected { _ = try PlaceImport.restore(archive, into: destination, privateStore: reopenedStore) }
        let ordinaryCity = FeastList(context: destination); ordinaryCity.id = UUID(); ordinaryCity.name = "Ordinary legacy city"
        destination.assign(ordinaryCity, to: newStore)
        let ordinaryParent = ListSection(context: destination); ordinaryParent.id = UUID(); ordinaryParent.feastList = ordinaryCity
        destination.assign(ordinaryParent, to: newStore)
        let ordinaryChild = ListSection(context: destination); ordinaryChild.id = UUID(); ordinaryChild.feastList = ordinaryCity
        destination.assign(ordinaryChild, to: newStore); ordinaryChild.parent = ordinaryParent
        let ordinaryPlace = SavedPlace(context: destination); ordinaryPlace.id = UUID(); ordinaryPlace.feastList = ordinaryCity
        destination.assign(ordinaryPlace, to: newStore); ordinaryPlace.listSection = ordinaryChild
        ordinaryPlace.note = "Normal note"; ordinaryPlace.skipNote = "Normal legacy guidance"
        try destination.save()
        try FeastRepository(context: destination).runStartupMigrations()
        precondition(ordinaryChild.parent == nil && ordinaryPlace.skipNote == nil)
        precondition(ordinaryPlace.note == "Normal note\n\nSkip guidance: Normal legacy guidance")
        let replayed = try PlaceExport.capture(context: destination)
        let retainedIDs = Set(afterDeletion.cities.map(\.id) + afterDeletion.neighborhoods.map(\.id) + afterDeletion.places.map(\.id))
        let retained = PlaceExport(exportedAt: replayed.exportedAt,
            cities: replayed.cities.filter { retainedIDs.contains($0.id) },
            neighborhoods: replayed.neighborhoods.filter { retainedIDs.contains($0.id) },
            places: replayed.places.filter { retainedIDs.contains($0.id) })
        assertGraph(retained, equals: afterDeletion)
        print("PASS library restored raw legacy values survive new-store migration replay; normal legacy records still migrate")
        print("PASS library disk round-trip preserves every raw field, relationships, empty groups and unrelated records; retry, edits and partial conflicts are safe")

        let (failureCoordinator, failureContext, failureStore) = try open("failure")
        let failing = FailingContext(concurrencyType: .mainQueueConcurrencyType)
        failing.persistentStoreCoordinator = failureCoordinator
        let failureMetadata = failureCoordinator.metadata(for: failureStore) as NSDictionary
        expectRejected { _ = try PlaceImport.restore(archive, into: failing, privateStore: failureStore) }
        precondition(!failing.hasChanges)
        precondition(failureMetadata.isEqual(to: failureCoordinator.metadata(for: failureStore)))
        try require(PlaceExport.capture(context: failureContext).places.isEmpty)
        guard case .restored = try PlaceImport.restore(archive, into: failureContext, privateStore: failureStore) else {
            fatalError("Retry following a failed save must work")
        }
        assertGraph(try PlaceExport.capture(context: failureContext), equals: expected)
        let (_, cancelContext, cancelStore) = try open("cancel")
        let cancelled = Task { @MainActor in
            try Task.checkCancellation()
            return try PlaceImport.restore(archive, into: cancelContext, privateStore: cancelStore)
        }
        cancelled.cancel()
        do { _ = try await cancelled.value; fatalError("Cancelled work restored data") }
        catch is CancellationError {} catch { throw error }
        try require(PlaceExport.capture(context: cancelContext).cities.isEmpty)
        let directCancellation = Task { @MainActor in
            // Yield once so cancellation lands before the synchronous commit starts.
            await Task.yield()
            return try PlaceImport.restore(archive, into: cancelContext, privateStore: cancelStore)
        }
        directCancellation.cancel()
        do { _ = try await directCancellation.value; fatalError("Restore ignored cancellation") }
        catch is CancellationError {} catch { throw error }
        precondition(!cancelContext.hasChanges)
        try require(PlaceExport.capture(context: cancelContext).cities.isEmpty)
        print("PASS library failed-save rollback and cancellation leave no records; fresh retry succeeds")

        let (_, validationContext, validationStore) = try open("validation")
        func reject(_ invalid: PlaceExport) throws {
            expectRejected { _ = try PlaceImport.restore(invalid, into: validationContext, privateStore: validationStore) }
            precondition(!validationContext.hasChanges)
            try require(PlaceExport.capture(context: validationContext).cities.isEmpty)
        }
        var invalidProvenance = archive
        invalidProvenance.provenance = .init(capturedAt: date,
            records: [.init(entity: "FeastList", id: UUID(), store: .sharedLibrary)], cities: [])
        try reject(invalidProvenance)
        invalidProvenance.provenance = .init(capturedAt: date, records: [sourceRecords[0], sourceRecords[0]], cities: [])
        try reject(invalidProvenance)
        invalidProvenance.provenance = .init(capturedAt: date, records: [], cities: [sharing, sharing])
        try reject(invalidProvenance)
        invalidProvenance.provenance = .init(capturedAt: date, records: [], cities: [
            .init(cityID: UUID(), status: .unavailable, ownerRecordName: nil, currentUserRole: nil,
                currentUserPermission: nil, publicPermission: nil, participants: [])])
        try reject(invalidProvenance)
        invalidProvenance.provenance = .init(capturedAt: date,
            records: [.init(entity: "UnknownEntity", id: archive.cities[0].id, store: .unknown)], cities: [])
        try reject(invalidProvenance)
        print("PASS library v2 sharing provenance round-trip and dangling/duplicate/unknown source rejection")
        var future = archive; future.version = 99; try reject(future)
        var negative = archive; negative.version = -1; try reject(negative)
        var wrongFormat = archive; wrongFormat.format = "not.feast"; try reject(wrongFormat)
        try reject(PlaceExport(exportedAt: date, cities: archive.cities + [archive.cities[0]], neighborhoods: archive.neighborhoods, places: archive.places))
        try reject(PlaceExport(exportedAt: date, cities: archive.cities, neighborhoods: archive.neighborhoods + [archive.neighborhoods[0]], places: archive.places))
        try reject(PlaceExport(exportedAt: date, cities: archive.cities, neighborhoods: archive.neighborhoods, places: archive.places + [archive.places[0]]))
        try reject(PlaceExport(exportedAt: date, cities: [], neighborhoods: archive.neighborhoods, places: archive.places))
        try reject(PlaceExport(exportedAt: date, cities: archive.cities, neighborhoods: [], places: archive.places))
        var crossCityJSON = try JSONSerialization.jsonObject(with: bytes) as! [String: Any]
        var crossCityPlaces = crossCityJSON["places"] as! [[String: Any]]
        let categorizedIndex = crossCityPlaces.firstIndex { $0["neighborhoodID"] != nil }!
        let categorizedID = UUID(uuidString: crossCityPlaces[categorizedIndex]["cityID"] as! String)!
        crossCityPlaces[categorizedIndex]["cityID"] = archive.cities.first { $0.id != categorizedID }!.id.uuidString
        crossCityJSON["places"] = crossCityPlaces
        try reject(JSONDecoder().decode(PlaceExport.self, from: JSONSerialization.data(withJSONObject: crossCityJSON)))
        let first = UUID(), second = UUID()
        func section(_ id: UUID, city: UUID?, parent: UUID?) -> PlaceExport.Neighborhood {
            .init(id: id, cityID: city, parentID: parent, name: nil, createdAt: nil, updatedAt: nil)
        }
        try reject(PlaceExport(exportedAt: date, cities: archive.cities, neighborhoods: [section(first, city: cities[0].id, parent: first)], places: []))
        try reject(PlaceExport(exportedAt: date, cities: archive.cities, neighborhoods: [
            section(first, city: cities[0].id, parent: second), section(second, city: cities[0].id, parent: first)], places: []))
        try reject(PlaceExport(exportedAt: date, cities: archive.cities, neighborhoods: [
            section(first, city: cities[0].id, parent: second), section(second, city: cities[1].id, parent: nil)], places: []))
        try reject(PlaceExport(exportedAt: date, cities: archive.cities, neighborhoods: [section(first, city: nil, parent: second)], places: []))
        let deepIDs = (0...PlaceExport.maximumParentDepth).map { _ in UUID() }
        let deep = deepIDs.enumerated().map { index, id in
            section(id, city: cities[0].id, parent: index == 0 ? nil : deepIDs[index - 1])
        }
        try reject(PlaceExport(exportedAt: date, cities: archive.cities, neighborhoods: deep, places: []))
        try reject(PlaceExport(exportedAt: date, cities: [.init(id: UUID(), name: String(repeating: "x", count: PlaceExport.maximumStringBytes + 1), createdAt: nil, updatedAt: nil)], neighborhoods: [], places: []))
        try reject(PlaceExport(exportedAt: Date(timeIntervalSinceReferenceDate: .infinity), cities: [], neighborhoods: [], places: []))
        try reject(PlaceExport(exportedAt: date, cities: [.init(id: UUID(), name: nil, createdAt: Date(timeIntervalSinceReferenceDate: .nan), updatedAt: nil)], neighborhoods: [], places: []))
        let tooMany = (0...PlaceExport.maximumRecords).map { _ in PlaceExport.City(id: UUID(), name: nil, createdAt: nil, updatedAt: nil) }
        try reject(PlaceExport(exportedAt: date, cities: tooMany, neighborhoods: [], places: []))
        for invalid in [Data(), Data("not JSON".utf8), Data("{}".utf8), Data(bytes.dropLast()), Data("{\"version\":2}".utf8)] {
            expectRejected { _ = try PlaceExport.decode(invalid) }
        }
        let futureEnvelope = Data("{\"format\":\"com.jongalante.Feast.places\",\"version\":99}".utf8)
        do { _ = try PlaceExport.decode(futureEnvelope); fatalError("Expected unsupported future envelope") }
        catch PlaceExport.ExportError.unsupportedVersion {} catch { throw error }
        let oversized = Data(repeating: 32, count: PlaceExport.maximumFileBytes + 1)
        expectRejected { _ = try PlaceExport.decode(oversized) }
        let largeFile = directory.appendingPathComponent("oversized-library.json")
        try oversized.write(to: largeFile)
        expectRejected { _ = try PlaceImport.readFile(at: largeFile) }
        expectRejected { _ = try PlaceImport.readFile(at: directory) }
        var legacy = archive; legacy.version = 1; legacy.provenance = nil
        let legacyBytes = try legacy.validatedData()
        precondition(!String(decoding: legacyBytes, as: UTF8.self).contains("provenance"))
        guard case .restored = try PlaceImport.restore(PlaceExport.decode(legacyBytes), into: validationContext, privateStore: validationStore) else {
            fatalError("Legacy v1 file not restored")
        }
        assertGraph(try PlaceExport.capture(context: validationContext), equals: expected)
        print("PASS library legacy v1, malformed/future/version/size/string/count/date/reference/cycle/depth validation")

        let (_, collision, collisionStore) = try open("collision")
        let conflicting = SavedPlace(context: collision); conflicting.id = expected.cities[0].id
        conflicting.note = "Unrelated record with colliding UUID"; try collision.save()
        let collisionBefore = try PlaceExport.capture(context: collision)
        expectRejected { _ = try PlaceImport.restore(archive, into: collision, privateStore: collisionStore) }
        assertGraph(try PlaceExport.capture(context: collision), equals: collisionBefore)
        let child = NSManagedObjectContext(concurrencyType: .mainQueueConcurrencyType); child.parent = collision
        expectRejected { _ = try PlaceImport.restore(archive, into: child, privateStore: collisionStore) }
        let unavailable = NSManagedObjectContext(concurrencyType: .mainQueueConcurrencyType)
        expectRejected { _ = try PlaceImport.restore(archive, into: unavailable, privateStore: collisionStore) }
        expectRejected { _ = try PlaceImport.restore(archive, into: collision, privateStore: sourceStore) }
        print("PASS library UUID collision, child context, unloaded context and foreign destination rejection")
        // Nested restored leaf names must not redirect existing name-based Notes imports.
        let (_, matchingContext, matchingStore) = try open("matching")
        let matchingCityID = UUID(), matchingParentID = UUID()
        let matchingArchive = PlaceExport(exportedAt: date,
            cities: [.init(id: matchingCityID, name: "Matching city", createdAt: date, updatedAt: date)],
            neighborhoods: [
                .init(id: matchingParentID, cityID: matchingCityID, parentID: nil, name: "A parent", createdAt: date, updatedAt: date),
                .init(id: UUID(), cityID: matchingCityID, parentID: matchingParentID, name: "Same", createdAt: date, updatedAt: date),
                .init(id: UUID(), cityID: matchingCityID, parentID: nil, name: "Same", createdAt: date, updatedAt: date),
                .init(id: UUID(), cityID: matchingCityID, parentID: matchingParentID, name: "Child only", createdAt: date, updatedAt: date)
            ], places: [])
        _ = try PlaceImport.restore(matchingArchive, into: matchingContext, privateStore: matchingStore)
        let matchingCity = try matchingContext.fetch(FeastList.fetchRequest()).first!
        let matchingRoot = matchingCity.neighborhoodSections.first { $0.name == "Same" }!
        let matchingChild = matchingCity.visibleNeighborhoodSections.first { $0.name == "Same" && $0.parent != nil }!
        precondition(matchingCity.visibleNeighborhoodSections.first { $0.name == "Same" } === matchingChild)
        precondition(matchingCity.neighborhoodSections.allSatisfy { $0.parent == nil })
        let matchingDrafts = ["Same", "Child only"].map { name in
            FeastRepository.ImportedSavedPlaceDraft(applePlaceID: "synthetic-name-match-\(name)", displayNameSnapshot: name,
                status: .wantToTry, placeType: .restaurant, cuisines: [], tags: [], note: nil,
                websiteURL: nil, instagramURL: nil, neighborhoodName: name)
        }
        let matchingResult = try FeastRepository(context: matchingContext).importSavedPlaces(from: matchingDrafts, into: matchingCity)
        precondition(matchingResult.addedCount == 2)
        let matchingPlaces = try matchingContext.fetch(SavedPlace.fetchRequest())
        precondition(matchingPlaces.first { $0.displayNameSnapshot == "Same" }!.listSection === matchingRoot)
        let newRoot = matchingPlaces.first { $0.displayNameSnapshot == "Child only" }!.listSection!
        precondition(newRoot.parent == nil && newRoot.name == "Child only")
        precondition(matchingCity.visibleNeighborhoodSections.contains { $0.name == "Child only" && $0.parent != nil })
        precondition(!matchingContext.hasChanges)
        print("PASS restored nested duplicate names never redirect top-level Notes matching or prevent new top-level creation")

        let (_, asyncContext, asyncStore) = try open("async")
        let draft = FeastList(context: asyncContext); draft.id = UUID(); draft.name = "Unsaved draft"
        do {
            _ = try await PlaceImport.restoreInBackground(archive, into: asyncContext, privateStore: asyncStore)
            fatalError("Async restore saved a dirty view context")
        } catch {}
        precondition(asyncContext.hasChanges && draft.name == "Unsaved draft")
        asyncContext.rollback()
        guard case .restored = try await PlaceImport.restoreInBackground(archive, into: asyncContext, privateStore: asyncStore) else {
            fatalError("Background restore did not import")
        }
        assertGraph(try PlaceExport.capture(context: asyncContext), equals: expected)
        guard case .alreadyImported = try await PlaceImport.restoreInBackground(archive, into: asyncContext, privateStore: asyncStore) else {
            fatalError("Background retry duplicated records")
        }
        let (_, largeContext, largeStore) = try open("large")
        let largeCity = PlaceExport.City(id: UUID(), name: "10,000 synthetic places", createdAt: date, updatedAt: date)
        let largePlaces = (0..<10_000).map { index in
            PlaceExport.Place(id: UUID(), cityID: largeCity.id, neighborhoodID: nil,
                applePlaceID: "synthetic-\(index)", name: "Place \(index)", status: "Raw status", placeType: "Raw type",
                cuisinesStorage: nil, tagsStorage: "one\ntwo", note: "Synthetic note \(index)", skipNote: nil,
                websiteURL: nil, instagramURL: nil, createdAt: date, updatedAt: date)
        }
        let largeArchive = PlaceExport(exportedAt: date, cities: [largeCity], neighborhoods: [], places: largePlaces)
        let largeStart = Date()
        guard case .restored = try await PlaceImport.restoreInBackground(largeArchive, into: largeContext, privateStore: largeStore) else {
            fatalError("Large library did not restore")
        }
        let duration = Date().timeIntervalSince(largeStart)
        assertGraph(try PlaceExport.capture(context: largeContext), equals: try PlaceImport.remappedArchive(largeArchive))
        guard case .alreadyImported = try await PlaceImport.restoreInBackground(largeArchive, into: largeContext, privateStore: largeStore) else {
            fatalError("Large library retry duplicated records")
        }
        precondition(!largeContext.hasChanges)
        print("PASS library async worker restore/merge/retry and dirty-context protection; 10,000-place restore took \(String(format: "%.3f", duration)) seconds")
        source.reset(); try sourceCoordinator.remove(sourceStore)
    }

    private static func require(_ condition: Bool, _ message: String = "Library check failed") {
        precondition(condition, message)
    }

    private static func expectRejected(_ work: () throws -> Void) {
        do { try work(); fatalError("Expected library validation/import rejection") } catch {}
    }

    private static func normalized(_ archive: PlaceExport) -> PlaceExport {
        PlaceExport(exportedAt: Date(timeIntervalSinceReferenceDate: 0),
            cities: archive.cities.sorted { $0.id.uuidString < $1.id.uuidString },
            neighborhoods: archive.neighborhoods.sorted { $0.id.uuidString < $1.id.uuidString },
            places: archive.places.sorted { $0.id.uuidString < $1.id.uuidString })
    }

    private static func assertGraph(_ actual: PlaceExport, equals expected: PlaceExport, plus other: PlaceExport? = nil) {
        let combined = PlaceExport(exportedAt: expected.exportedAt, cities: expected.cities + (other?.cities ?? []),
            neighborhoods: expected.neighborhoods + (other?.neighborhoods ?? []), places: expected.places + (other?.places ?? []))
        precondition(normalized(actual) == normalized(combined), "Raw archive graph differs")
    }

    /// Independent oracle: mapped arrays retain canonical source-UUID order. Only new
    /// identities come from the mapper; every attribute association and edge is checked
    /// against the original graph rather than another production remapping call.
    private static func assertRawAttributesEqual(_ original: PlaceExport, _ remapped: PlaceExport) throws {
        let canonical = normalized(original)
        precondition(canonical.cities.count == remapped.cities.count)
        precondition(canonical.neighborhoods.count == remapped.neighborhoods.count)
        precondition(canonical.places.count == remapped.places.count)
        let cityIDs = Dictionary(uniqueKeysWithValues: zip(canonical.cities, remapped.cities).map { ($0.id, $1.id) })
        let sectionIDs = Dictionary(uniqueKeysWithValues: zip(canonical.neighborhoods, remapped.neighborhoods).map { ($0.id, $1.id) })
        for (source, mapped) in zip(canonical.neighborhoods, remapped.neighborhoods) {
            precondition(mapped.cityID == source.cityID.map { cityIDs[$0]! }, "Mapper changed a neighborhood's city edge")
            precondition(mapped.parentID == source.parentID.map { sectionIDs[$0]! }, "Mapper changed a neighborhood's parent edge")
        }
        for (source, mapped) in zip(canonical.places, remapped.places) {
            precondition(mapped.cityID == source.cityID.map { cityIDs[$0]! }, "Mapper changed a place's city edge")
            precondition(mapped.neighborhoodID == source.neighborhoodID.map { sectionIDs[$0]! }, "Mapper changed a place's neighborhood edge")
        }
        func attributes(_ archive: PlaceExport, key: String) throws -> [String] {
            let object = try JSONSerialization.jsonObject(with: JSONEncoder().encode(archive)) as! [String: Any]
            return try (object[key] as! [[String: Any]]).map { record in
                var fields = record
                for reference in ["id", "cityID", "neighborhoodID", "parentID"] { fields.removeValue(forKey: reference) }
                return String(decoding: try JSONSerialization.data(withJSONObject: fields, options: [.sortedKeys]), as: UTF8.self)
            }
        }
        for key in ["cities", "neighborhoods", "places"] {
            // No multiset sorting: a value moved to a different record must fail too.
            try require(attributes(canonical, key: key) == attributes(remapped, key: key), "Mapper changed per-record raw attributes")
        }
    }
}
