import Foundation
import CoreData
private struct FieldFixtureProvider:AskFeastProvider {
    let label="Offline action contract fixture"
    let finding:AskVerifiedFinding
    func answer(_ request:AskRequest,tools:AskReadTools) async throws -> AskResponse {
        let candidate=tools.localCandidate(finding.recordID)!
        let saving=request.text == "Add that to Public Cafe"
        return .init(summary:saving ? "Save Instagram" : "Public business details",candidates:[candidate],listedCandidateIDs:[],usesLocalCatalog:true,libraryContext:.init(ids:[finding.recordID],filters:.init(operation:saving ? .updateField : .lookup,scope:.library,city:nil,cuisine:nil,status:nil,placeType:nil,name:"Public Cafe",positions:[],fields:["instagram"])),fieldActions:[.init(finding:finding)],requestsFieldSave:saving)
    }
}
private struct FieldPlanner:AskLibraryIntentPlanning {
    let plan:AskLibraryPlan
    func libraryPlan(_ question:String) async throws -> AskLibraryPlan? {plan}
}
@MainActor enum AskFieldActionTests {
    static func run(model:NSManagedObjectModel,temporaryDirectory:URL) async throws {
        let coordinator=NSPersistentStoreCoordinator(managedObjectModel:model)
        let url=temporaryDirectory.appendingPathComponent("field-actions.sqlite")
        let store=try coordinator.addPersistentStore(ofType:NSSQLiteStoreType,configurationName:nil,at:url)
        let context=NSManagedObjectContext(concurrencyType:.mainQueueConcurrencyType);context.persistentStoreCoordinator=coordinator
        let repository=FeastRepository(context:context),city=try repository.createFeastList(named:"Fixture city")
        let place=try repository.createSavedPlace(from:.init(applePlaceID:"field-fixture",displayNameSnapshot:"Public Cafe",status:.love,placeType:.cafe,cuisines:["Italian"],tags:["Kept"],note:"Private fixture note",websiteURL:"https://public-cafe.org/",instagramURL:nil,feastList:city,listSection:nil))
        let id=place.id!,cityID=city.id!,profile="https://www.instagram.com/public_cafe/"
        let adapter=AskSavedCollection(context:context,canUpdate:{_ in true},visibleCities:{[cityID]})
        let finding=AskVerifiedFinding(id:UUID(),recordID:id.uuidString,identity:.init(name:"Public Cafe",city:"Fixture city",website:"https://public-cafe.org/",applePlaceID:"field-fixture"),field:"instagram",value:profile,evidenceURL:"https://public-cafe.org/",verification:"official_website",originatingTurn:UUID())
        let ready=AskFieldActionState(finding:finding)
        let saved=try adapter.apply(ready,mode:.save)
        precondition(saved.outcome == .saved && place.instagramURL==profile && place.note=="Private fixture note" && place.placeStatus == .love && place.tags==["Kept"] && place.feastList?.id==cityID)
        let revision=place.updatedAt
        let repeated=try adapter.apply(ready,mode:.save);precondition(repeated.outcome == .alreadySaved)
        precondition(place.updatedAt==revision)
        let undone=try adapter.apply(saved,mode:.undo);precondition(undone.outcome == .undone && place.instagramURL==nil)
        let savedAgain=try adapter.apply(ready,mode:.save)
        place.note="Newer editor change";place.updatedAt=Date();try context.save()
        let blockedUndo=try adapter.apply(savedAgain,mode:.undo);precondition(blockedUndo.outcome == .unavailable)
        precondition(place.instagramURL==profile && place.note=="Newer editor change")
        print("PASS field save is narrow, durable and repeat-safe; conditional Undo preserves newer edits and all unrelated metadata")
        place.instagramURL="https://www.instagram.com/old_profile/";try context.save()
        let conflict=try adapter.apply(ready,mode:.save);precondition(conflict.outcome == .conflict && place.instagramURL != profile)
        place.instagramURL="https://www.instagram.com/newer_profile/";try context.save()
        let stale=try adapter.apply(conflict,mode:.replace);precondition(stale.outcome == .conflict && place.instagramURL!.contains("newer_profile"))
        let replaced=try adapter.apply(stale,mode:.replace);precondition(replaced.outcome == .saved && place.instagramURL==profile)
        place.note="Unsent draft"
        do {_ = try adapter.apply(replaced,mode:.undo);preconditionFailure("Pending editor was overwritten")} catch {}
        precondition(place.note=="Unsent draft" && context.hasChanges);context.rollback()
        let failing=AskSavedCollection(context:context,canUpdate:{_ in true},saveFieldContext:{_ in throw NSError(domain:"Offline save failure",code:1)},visibleCities:{[cityID]})
        let persistedBefore=place.instagramURL
        do {_ = try failing.apply(replaced,mode:.undo);preconditionFailure("Failed save reported success")} catch {}
        precondition(place.instagramURL==persistedBefore && !context.hasChanges)
        city.name="Unsent city rename"
        do {_ = try adapter.apply(replaced,mode:.undo);preconditionFailure("Pending city draft accepted")} catch {}
        precondition(city.name=="Unsent city rename" && context.hasChanges && place.instagramURL==persistedBefore)
        context.rollback()
        let denied=AskSavedCollection(context:context,visibleCities:{[cityID]})
        do {_ = try denied.apply(ready,mode:.save);preconditionFailure("Missing edit permission accepted")} catch {}
        print("PASS replacement is explicit compare-and-set; concurrent edits, pending drafts and revoked edit permissions cannot be overwritten")
        let identityBefore=place.displayNameSnapshot
        place.displayNameSnapshot="Another business";try context.save()
        let staleIdentity=try adapter.apply(ready,mode:.save);precondition(staleIdentity.outcome == .unavailable)
        place.displayNameSnapshot=identityBefore;try context.save()
        var forged=ready
        let wrong=AskVerifiedFinding(id:UUID(),recordID:id.uuidString,identity:finding.identity,field:"instagram",value:"https://instagram.com.evil.org/fake",evidenceURL:"https://public-cafe.org/",verification:"official_website",originatingTurn:UUID())
        forged=AskFieldActionState(finding:wrong)
        do {_ = try adapter.apply(forged,mode:.save);preconditionFailure("Unsafe profile accepted")} catch {}
        print("PASS stale business identities and spoofed Instagram profiles cannot produce writes")
        let plan=AskLibraryPlan(operation:.updateField,scope:.library,city:"Fixture city",cuisine:nil,status:nil,placeType:nil,name:"Public Cafe",positions:[],fields:["instagram"])
        let planner=FieldPlanner(plan:plan)
        let pipeline=AskLibraryProvider(remote:FieldFixtureProvider(finding:finding),places:{try await adapter.personalPlaces()},intentPlanner:planner,snapshot:{try await adapter.librarySnapshot()})
        var actionRequest=AskRequest(mode:.collection,text:"Add that to Public Cafe",fromOCR:false);actionRequest.verifiedFindings=[finding]
        precondition(actionRequest.collectionReadVersion().verifiedFindings == [finding])
        let planned=try await pipeline.answer(actionRequest,tools:AskReadTools(request:actionRequest,index:adapter.index()))
        precondition(planned.requestsFieldSave==true && planned.fieldActions?.first?.finding==finding)
        var withoutEvidence=actionRequest;withoutEvidence.verifiedFindings=[]
        let clarify=try await pipeline.answer(withoutEvidence,tools:AskReadTools(request:withoutEvidence,index:adapter.index()))
        precondition(clarify.requestsFieldSave != true && clarify.summary=="Which Instagram should I save?")
        let twin=try repository.createSavedPlace(from:.init(applePlaceID:"other-branch",displayNameSnapshot:"Public Cafe",status:.wantToTry,placeType:.cafe,cuisines:[],tags:[],note:nil,websiteURL:nil,instagramURL:nil,feastList:city,listSection:nil))
        let ambiguous=try await pipeline.answer(actionRequest,tools:AskReadTools(request:actionRequest,index:adapter.index()))
        precondition(ambiguous.requestsFieldSave != true && ambiguous.fieldActions==nil)
        try repository.delete(twin)
        print("PASS full mocked action planning resolves exact typed evidence; missing findings and ambiguous branches clarify without writes")
        let legacy=AskResponse(summary:"Old response",candidates:[])
        let encoded=try JSONEncoder().encode(legacy),decoded=try JSONDecoder().decode(AskResponse.self,from:encoded);precondition(decoded.fieldActions==nil)
        let session=AskSession(index:try adapter.index(),provider:FieldFixtureProvider(finding:finding));var executions=0
        let history=AskConversationStore(url:temporaryDirectory.appendingPathComponent("field-action-chats.json"));session.restoreHistory(from:history)
        session.fieldExecutor={action,mode in executions+=1;return try adapter.apply(action,mode:mode)}
        place.instagramURL=nil;try context.save();session.updateIndex(try adapter.index())
        session.input="Find Public Cafe Instagram";session.run();while session.isLoading {await Task.yield()}
        precondition(executions==0 && session.response?.fieldActions?.first?.finding==finding)
        let first=session.turns.last!.id
        session.applyFieldAction(turn:first,findingID:finding.id,mode:.save);precondition(place.instagramURL==profile)
        session.applyFieldAction(turn:first,findingID:finding.id,mode:.undo);precondition(place.instagramURL==nil)
        session.input="Add that to Public Cafe";session.run();while session.isLoading {await Task.yield()}
        precondition(place.instagramURL==profile && session.response?.fieldActions?.first?.outcome == .saved && session.response?.requestsFieldSave==false)
        session.flushHistory();let before=executions
        let restored=AskSession(index:try adapter.index(),provider:FieldFixtureProvider(finding:finding));restored.fieldExecutor={action,mode in executions+=1;return try adapter.apply(action,mode:mode)};restored.restoreHistory(from:history)
        precondition(executions==before && restored.response?.fieldActions?.first?.outcome == .saved)
        let restoredTurn=restored.turns.last!.id
        restored.applyFieldAction(turn:restoredTurn,findingID:finding.id,mode:.undo);precondition(place.instagramURL==nil)
        restored.applyFieldAction(turn:restoredTurn,findingID:finding.id,mode:.save);precondition(place.instagramURL==profile)
        let beforeNewChat=executions
        let newChat=restored.newChat();_ = newChat;precondition(restored.turns.isEmpty && executions==beforeNewChat)
        print("PASS button and explicit chat save share the same executor; typed findings/outcomes survive history with no automatic write replay")
        context.reset();try coordinator.remove(store)
        let reopened=try coordinator.addPersistentStore(ofType:NSSQLiteStoreType,configurationName:nil,at:url)
        let fresh=NSManagedObjectContext(concurrencyType:.mainQueueConcurrencyType);fresh.persistentStoreCoordinator=coordinator
        let persisted=try fresh.fetch(SavedPlace.fetchRequest()).first;precondition(persisted?.instagramURL==profile)
        try coordinator.remove(reopened)
        print("PASS Instagram field persists after SQLite close/reopen without changing saved-place schema")
    }
}
