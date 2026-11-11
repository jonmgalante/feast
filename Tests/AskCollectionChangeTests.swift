import CoreData
import Foundation
@MainActor enum AskCollectionChangeTests {
    static func run(model:NSManagedObjectModel,temporaryDirectory:URL)throws {
        try auditSafety(model:model,temporaryDirectory:temporaryDirectory)
        let coordinator=NSPersistentStoreCoordinator(managedObjectModel:model)
        let store=try coordinator.addPersistentStore(ofType:NSSQLiteStoreType,configurationName:nil,at:temporaryDirectory.appendingPathComponent("collection-changes.sqlite"))
        let context=NSManagedObjectContext(concurrencyType:.mainQueueConcurrencyType);context.persistentStoreCoordinator=coordinator
        let repository=FeastRepository(context:context),city=try repository.createFeastList(named:"Chicago")
        let place=try repository.createSavedPlace(from:.init(applePlaceID:"isolated-map-id",displayNameSnapshot:"Isolated place",status:.love,placeType:.restaurant,cuisines:["Italian"],tags:["Keep"],note:"Private preserved note",websiteURL:nil,instagramURL:nil,feastList:city,listSection:nil))
        let id=place.id!.uuidString,cityID=city.id!
        let adapter=AskSavedCollection(context:context,canMutate:{_,_,_ in true},canRecoverStore:{$0==store.identifier},visibleCities:{Set((try? repository.fetchFeastLists().compactMap(\.id)) ?? [])})
        let url=temporaryDirectory.appendingPathComponent("collection-changes.json")
        let engine=AskCollectionChangeEngine(adapter:adapter,journalURL:url)
        func grant(_ question:String,_ proposal:AskChangeProposal?=nil)->AskChangeGrant {.init(question:question,entity:"place",operations:["update","delete","undo"],fields:["name"],targetIDs:[id],allowsCreation:false,boundProposal:proposal)}
        func undoGrant()->AskChangeGrant {let p=AskChangeProposal(entity:"place",operation:"undo",targetIDs:[id],cityID:nil,sectionID:nil,mapMatchID:nil,changes:[],instructionQuote:"Undo");return grant("Undo",p)}
        func proposal(_ operation:String,_ field:String,_ value:String?)->AskChangeProposal {.init(entity:"place",operation:operation,targetIDs:[id],cityID:nil,sectionID:nil,mapMatchID:nil,changes:[.init(field:field,value:value,values:nil,findingID:nil)],instructionQuote:"Change this")}
        let prepared=try engine.prepare(proposal("update","name","Updated name"),question:"Change this",authorization:grant("Change this"),findings:[])
        precondition(place.displayNameSnapshot=="Isolated place")
        let applied=try engine.apply(prepared.id,authorization:grant("Change this",proposal("update","name","Updated name")))
        precondition(applied.state == .applied && place.displayNameSnapshot=="Updated name" && place.note=="Private preserved note" && place.placeStatus == .love && place.feastList?.id==cityID)
        let revision=place.updatedAt
        _ = try engine.apply(prepared.id,authorization:grant("Change this",proposal("update","name","Updated name")));precondition(place.updatedAt==revision)
        let restored=AskCollectionChangeEngine(adapter:adapter,journalURL:url)
        _ = try restored.undo(prepared.id,authorization:undoGrant())
        precondition(place.displayNameSnapshot=="Isolated place" && place.note=="Private preserved note" && place.tags==["Keep"])
        _ = try restored.undo(prepared.id,authorization:undoGrant())
        let stale=try engine.prepare(proposal("update","name","Stale overwrite"),question:"Change this",authorization:grant("Change this"),findings:[])
        place.note="Newer private edit";try context.save()
        do {_ = try engine.apply(stale.id,authorization:grant("Change this",proposal("update","name","Stale overwrite")));preconditionFailure("Stale edit applied")}catch {}
        precondition(place.note=="Newer private edit" && place.displayNameSnapshot=="Isolated place")
        let denied=AskSavedCollection(context:context,visibleCities:{[cityID]})
        do {_ = try AskCollectionChangeEngine(adapter:denied,journalURL:temporaryDirectory.appendingPathComponent("denied.json")).prepare(proposal("update","name","No"),question:"Change this",authorization:grant("Change this"),findings:[]);preconditionFailure("Permission ignored")}catch {}
        let deletion=AskChangeProposal(entity:"place",operation:"delete",targetIDs:[id],cityID:nil,sectionID:nil,mapMatchID:nil,changes:[],instructionQuote:"Delete this")
        let deleteAction=try engine.prepare(deletion,question:"Delete this",authorization:grant("Delete this"),findings:[])
        let unconfirmed=try engine.apply(deleteAction.id,authorization:grant("Delete this",deletion));precondition(unconfirmed.state == .needsConfirmation)
        _ = try engine.apply(deleteAction.id,authorization:grant("Delete this",deletion),confirmed:true)
        let fetch=SavedPlace.fetchRequest();fetch.predicate=NSPredicate(format:"id == %@",UUID(uuidString:id)! as NSUUID)
        let deleted=try context.fetch(fetch);precondition(deleted.isEmpty)
        _ = try engine.undo(deleteAction.id,authorization:undoGrant())
        let recovered=try context.fetch(fetch).first!
        precondition(recovered.id?.uuidString==id && recovered.note=="Newer private edit" && recovered.feastList?.id==cityID)
        // Exercise the same journal/repository path for every supported entity, not only links.
        func commit(_ p:AskChangeProposal,maps:[String:ApplePlaceMatch]=[:])throws->AskCollectionAction {
            let g=AskChangeGrant(question:p.instructionQuote,entity:p.entity,operations:[p.operation],fields:Set(p.changes.map(\.field)),targetIDs:Set(p.targetIDs),allowsCreation:p.operation=="create",cityIDs:Set(p.cityID.map {[$0]} ?? []),sectionIDs:Set(p.sectionID.map {[$0]} ?? []),mapMatchIDs:Set(p.mapMatchID.map {[$0]} ?? []),boundProposal:p)
            let ready=try engine.prepare(p,question:p.instructionQuote,authorization:g,findings:[])
            return try engine.apply(ready.id,authorization:g,maps:maps)
        }
        recovered.instagramURL="https://www.instagram.com/isolated_account/";try context.save()
        let clear=try commit(.init(entity:"place",operation:"update",targetIDs:[id],cityID:nil,sectionID:nil,mapMatchID:nil,changes:[.init(field:"instagram",value:nil,values:nil,findingID:nil)],instructionQuote:"Clear the saved Instagram"))
        precondition(recovered.instagramURL==nil)
        _ = try engine.performExplicitAction(clear.id,undo:true)
        precondition(recovered.instagramURL=="https://www.instagram.com/isolated_account/")
        let newCity=try commit(.init(entity:"city",operation:"create",targetIDs:[],cityID:nil,sectionID:nil,mapMatchID:nil,changes:[.init(field:"name",value:"Philadelphia",values:nil,findingID:nil)],instructionQuote:"Create Philadelphia"))
        let destination=newCity.targetIDs[0]
        let newSection=try commit(.init(entity:"neighborhood",operation:"create",targetIDs:[],cityID:destination,sectionID:nil,mapMatchID:nil,changes:[.init(field:"name",value:"Old City",values:nil,findingID:nil)],instructionQuote:"Add Old City in Philadelphia"))
        let sectionID=newSection.targetIDs[0]
        let match=ApplePlaceMatch(applePlaceID:"isolated-real-map-contract",displayName:"Maps selected business",secondaryText:"Philadelphia",coordinate:nil,suggestedSectionPath:.init(cityOrRegion:"Philadelphia",neighborhood:"Old City"),websiteURL:nil,instagramURL:nil)
        let created=try commit(.init(entity:"place",operation:"create",targetIDs:[],cityID:destination,sectionID:sectionID,mapMatchID:match.id,changes:[.init(field:"note",value:"Preserve on move",values:nil,findingID:nil),.init(field:"status",value:PlaceStatus.love.rawValue,values:nil,findingID:nil)],instructionQuote:"Save this Maps result in Old City as Love"),maps:[match.id:match])
        let createdID=created.targetIDs[0]
        let newFetch=SavedPlace.fetchRequest();newFetch.predicate=NSPredicate(format:"id == %@",UUID(uuidString:createdID)! as NSUUID)
        let saved=try context.fetch(newFetch).first!
        precondition(saved.listSection?.id?.uuidString==sectionID && saved.placeStatus == .love && saved.note=="Preserve on move")
        _ = try commit(.init(entity:"place",operation:"move",targetIDs:[createdID],cityID:cityID.uuidString,sectionID:nil,mapMatchID:nil,changes:[],instructionQuote:"Move it to Chicago, unsorted"))
        precondition(saved.feastList?.id==cityID && saved.listSection==nil && saved.note=="Preserve on move")
        do {_ = try engine.performExplicitAction(created.id,undo:true);preconditionFailure("Undo creation overwrote newer move")}catch {}
        do {_ = try engine.performExplicitAction(newCity.id,undo:true);preconditionFailure("Undo city creation removed a newer neighborhood")}catch {}
        let interrupted=try commit(.init(entity:"city",operation:"create",targetIDs:[],cityID:nil,sectionID:nil,mapMatchID:nil,changes:[.init(field:"name",value:"Recovery city",values:nil,findingID:nil)],instructionQuote:"Create Recovery city"))
        let crashURL=url.appendingPathExtension("intent-v1")
        try AskJournalTestSupport.legacyCopy(from:engine,to:crashURL) {entries in
            let crashIndex=entries.firstIndex {(($0["id"] as? String)?.lowercased())==interrupted.id.uuidString.lowercased()}!
            entries[crashIndex]["phase"]="intent"
            var action=entries[crashIndex]["action"] as! [String:Any];action["targetIDs"]=[];entries[crashIndex]["action"]=action
        }
        let crashEngine=AskCollectionChangeEngine(adapter:adapter,journalURL:crashURL)
        let recoveredCreation=try crashEngine.latestAction(for:interrupted.targetIDs[0])
        precondition(recoveredCreation?.targetIDs==interrupted.targetIDs)
        _ = try crashEngine.performExplicitAction(interrupted.id,undo:true)
        let survivingCities=try repository.fetchFeastLists();precondition(!survivingCities.contains {$0.id?.uuidString==interrupted.targetIDs[0]})
        // Stable recovery IDs are journaled before writes. Reconstructing the
        // engine must not append a note twice or allocate another created ID.
        let dedupURL=temporaryDirectory.appendingPathComponent("recovery-dedup-actions.json"),turn=UUID(),chat=UUID()
        func recoveryGrant(_ p:AskChangeProposal)->AskChangeGrant {.init(question:p.instructionQuote,entity:p.entity,operations:[p.operation],fields:Set(p.changes.map(\.field)),targetIDs:Set(p.targetIDs),allowsCreation:p.operation=="create",cityIDs:Set(p.cityID.map {[$0]} ?? []),sectionIDs:Set(p.sectionID.map {[$0]} ?? []),mapMatchIDs:Set(p.mapMatchID.map {[$0]} ?? []),boundProposal:p)}
        let note=AskChangeProposal(entity:"place",operation:"append",targetIDs:[id],cityID:nil,sectionID:nil,mapMatchID:nil,changes:[.init(field:"note",value:"Only append once",values:nil,findingID:nil)],instructionQuote:"Append this note")
        let appendKey=try AskRecoveryOperationIdentity(turnID:turn,step:1,callID:"fixture-append").key(entity:"place",target:id)
        let dedup=AskCollectionChangeEngine(adapter:adapter,journalURL:dedupURL)
        let readyNote=try dedup.prepare(note,question:note.instructionQuote,authorization:recoveryGrant(note),findings:[],turnID:turn,chatID:chat,recoveryOperationID:appendKey)
        let firstNote=try dedup.apply(readyNote.id,authorization:recoveryGrant(note))
        let onceNote=recovered.note,onceRevision=recovered.updatedAt
        let reloaded=AskCollectionChangeEngine(adapter:adapter,journalURL:dedupURL)
        let sameNote=try reloaded.prepare(note,question:note.instructionQuote,authorization:recoveryGrant(note),findings:[],turnID:turn,chatID:chat,recoveryOperationID:appendKey)
        let repeatedNote=try reloaded.apply(sameNote.id,authorization:recoveryGrant(note))
        precondition(firstNote.id==repeatedNote.id && recovered.note==onceNote && recovered.updatedAt==onceRevision)
        var differentNote=note;differentNote.changes=[.init(field:"note",value:"Different payload",values:nil,findingID:nil)]
        do {_ = try reloaded.prepare(differentNote,question:differentNote.instructionQuote,authorization:recoveryGrant(differentNote),findings:[],turnID:turn,chatID:chat,recoveryOperationID:appendKey);preconditionFailure("Recovery key accepted different mutation content")}catch {}
        var noGrant=recoveryGrant(note);noGrant.boundProposal=nil
        let noPermission=AskChangeGrant(question:note.instructionQuote,entity:"place",operations:[],fields:[],targetIDs:[],allowsCreation:false)
        do {_ = try reloaded.prepare(note,question:note.instructionQuote,authorization:noPermission,findings:[],turnID:turn,chatID:chat,recoveryOperationID:appendKey);preconditionFailure("Recovery key bypassed authorization")}catch {}
        do {_ = try reloaded.apply(sameNote.id,authorization:noGrant);preconditionFailure("Recovery receipt bypassed bound authorization")}catch {}
        let creation=AskChangeProposal(entity:"place",operation:"create",targetIDs:[],cityID:destination,sectionID:sectionID,mapMatchID:match.id,changes:[],instructionQuote:"Save this place once")
        let createKey=try AskRecoveryOperationIdentity(turnID:turn,step:2,callID:"fixture-create").key(entity:"place",target:nil)
        let readyCreation=try reloaded.prepare(creation,question:creation.instructionQuote,authorization:recoveryGrant(creation),findings:[],turnID:turn,chatID:chat,recoveryOperationID:createKey)
        let createdOnce=try reloaded.apply(readyCreation.id,authorization:recoveryGrant(creation),maps:[match.id:match])
        let dedupCrashURL=dedupURL.appendingPathExtension("intent-v1")
        try AskJournalTestSupport.legacyCopy(from:reloaded,to:dedupCrashURL) {entries in
            let i=entries.firstIndex {($0["id"] as? String)==createdOnce.id.uuidString}!
            entries[i]["phase"]="intent"
        }
        let afterCreationCrash=AskCollectionChangeEngine(adapter:adapter,journalURL:dedupCrashURL)
        let recoveredIntent=try afterCreationCrash.prepare(creation,question:creation.instructionQuote,authorization:recoveryGrant(creation),findings:[],turnID:turn,chatID:chat,recoveryOperationID:createKey)
        let createdAgain=try afterCreationCrash.apply(recoveredIntent.id,authorization:recoveryGrant(creation),maps:[match.id:match])
        precondition(createdAgain.id==createdOnce.id && createdAgain.targetIDs==createdOnce.targetIDs)
        _ = try afterCreationCrash.performExplicitAction(createdOnce.id,undo:true)
        let afterUndo=AskCollectionChangeEngine(adapter:adapter,journalURL:dedupCrashURL)
        let undoneIntent=try afterUndo.prepare(creation,question:creation.instructionQuote,authorization:recoveryGrant(creation),findings:[],turnID:turn,chatID:chat,recoveryOperationID:createKey)
        let noRecreation=try afterUndo.apply(undoneIntent.id,authorization:recoveryGrant(creation),maps:[match.id:match])
        precondition(noRecreation.state == .undone)
        let onceFetch=SavedPlace.fetchRequest();onceFetch.predicate=NSPredicate(format:"id == %@",UUID(uuidString:createdOnce.targetIDs[0])! as NSUUID)
        let onceSurvivors=try context.fetch(onceFetch);precondition(onceSurvivors.isEmpty)
        let ownDelete=AskChangeProposal(entity:"place",operation:"delete",targetIDs:[createdID],cityID:nil,sectionID:nil,mapMatchID:nil,changes:[],instructionQuote:"Delete this place")
        let ownDeleteKey=try AskRecoveryOperationIdentity(turnID:turn,step:3,callID:"fixture-delete").key(entity:"place",target:createdID)
        let readyDelete=try afterUndo.prepare(ownDelete,question:ownDelete.instructionQuote,authorization:recoveryGrant(ownDelete),findings:[],turnID:turn,chatID:chat,recoveryOperationID:ownDeleteKey)
        let beforeDeletion=try afterUndo.recoveryDeletedRecordIDs(forTurn:turn);precondition(!beforeDeletion.contains(createdID))
        _ = try afterUndo.apply(readyDelete.id,authorization:recoveryGrant(ownDelete),confirmed:true)
        let deletedProof=try afterUndo.recoveryDeletedRecordIDs(forTurn:turn),otherTurnProof=try afterUndo.recoveryDeletedRecordIDs(forTurn:UUID())
        precondition(deletedProof.contains(createdID) && otherTurnProof.isEmpty)
        let restoredDeletionEngine=AskCollectionChangeEngine(adapter:adapter,journalURL:dedupCrashURL)
        let restoredProof=try restoredDeletionEngine.recoveryDeletedRecordIDs(forTurn:turn);precondition(restoredProof.contains(createdID))
        let confirmationTurn=UUID()
        let confirmedDeletionProof=try restoredDeletionEngine.recoveryDeletedRecordIDs(forTurn:confirmationTurn,includingActionIDs:[readyDelete.id])
        precondition(confirmedDeletionProof==[createdID])
        let undoCreationProof=try restoredDeletionEngine.recoveryDeletedRecordIDs(forTurn:confirmationTurn,includingActionIDs:[createdOnce.id])
        precondition(undoCreationProof==Set(createdOnce.targetIDs))
        _ = try restoredDeletionEngine.performExplicitAction(readyDelete.id,undo:true)
        let undoneProof=try restoredDeletionEngine.recoveryDeletedRecordIDs(forTurn:turn);precondition(!undoneProof.contains(createdID))
        print("PASS retained-context deletion proof requires this turn's committed unchanged journal result; prepared/other-turn/undone records never qualify")
        print("PASS stable mutation identity survives restart, paid-tool scope mismatch is refused, note append occurs once, creation intent reconciles once, and Undo cannot recreate it")
        print("PASS generalized isolated field change, durable restore, repeated apply/Undo, stale edit refusal, permission refusal and confirmed recoverable deletion preserve IDs and unrelated metadata")
    }
}

@MainActor private final class AskMutationAuditFixture {
    let context:NSManagedObjectContext,repository:FeastRepository,store:NSPersistentStore,engine:AskCollectionChangeEngine
    init(model:NSManagedObjectModel,directory:URL,name:String)throws {
        let coordinator=NSPersistentStoreCoordinator(managedObjectModel:model)
        store=try coordinator.addPersistentStore(ofType:NSSQLiteStoreType,configurationName:nil,at:directory.appendingPathComponent("mutation-audit-\(name).sqlite"))
        context=NSManagedObjectContext(concurrencyType:.mainQueueConcurrencyType);context.persistentStoreCoordinator=coordinator
        repository=FeastRepository(context:context)
        // Install permission closures after initialization through a separate fixture policy.
        let policy=AskMutationAuditPolicy();self.policy=policy
        let repository=self.repository,store=self.store
        let adapter=AskSavedCollection(context:context,canMutate:{_,id,_ in id.map {!policy.denied.contains($0)} ?? true},canRecoverStore:{$0==store.identifier},visibleCities:{Set(try repository.fetchFeastLists().compactMap(\.id)).subtracting(policy.hidden)})
        self.adapter=adapter;engine=AskCollectionChangeEngine(adapter:adapter,journalURL:directory.appendingPathComponent("mutation-audit-\(name).json"))
    }
    let policy:AskMutationAuditPolicy,adapter:AskSavedCollection
    func place(_ city:FeastList,name:String="Fixture",apple:String=UUID().uuidString,note:String?=nil,tags:[String]=[],cuisines:[String]=[])throws->SavedPlace {
        try repository.createSavedPlace(from:.init(applePlaceID:apple,displayNameSnapshot:name,status:.love,placeType:.restaurant,cuisines:cuisines,tags:tags,note:note,websiteURL:nil,instagramURL:nil,feastList:city,listSection:nil))
    }
    func grant(_ p:AskChangeProposal)->AskChangeGrant {.init(question:p.instructionQuote,entity:p.entity,operations:[p.operation],fields:Set(p.changes.map(\.field)),targetIDs:Set(p.targetIDs),allowsCreation:p.operation=="create",cityIDs:Set(p.cityID.map {[$0]} ?? []),sectionIDs:Set(p.sectionID.map {[$0]} ?? []),mapMatchIDs:Set(p.mapMatchID.map {[$0]} ?? []),boundProposal:p)}
    func commit(_ p:AskChangeProposal,findings:[AskVerifiedFinding]=[])throws->AskCollectionAction {
        let g=grant(p),ready=try engine.prepare(p,question:p.instructionQuote,authorization:g,findings:findings)
        return try engine.apply(ready.id,authorization:g,confirmed:true)
    }
}
@MainActor private final class AskMutationAuditPolicy {var denied=Set<NSManagedObjectID>(),hidden=Set<UUID>()}
@MainActor private extension AskCollectionChangeTests {
    static func auditSafety(model:NSManagedObjectModel,temporaryDirectory:URL)throws {
        var failures:[String]=[]
        func check(_ value:Bool,_ label:String){if !value {failures.append(label);print("FAIL mutation audit: \(label)")}}
        func proposal(_ place:SavedPlace,_ field:String,_ value:String?=nil,_ values:[String]?=nil,operation:String="update")->AskChangeProposal {
            .init(entity:"place",operation:operation,targetIDs:[place.id!.uuidString],cityID:nil,sectionID:nil,mapMatchID:nil,changes:[.init(field:field,value:value,values:values,findingID:nil,source:"user")],instructionQuote:"Apply this fixture change")
        }
        let f=try AskMutationAuditFixture(model:model,directory:temporaryDirectory,name:"bounds"),city=try f.repository.createFeastList(named:"Bounds")
        let note=try f.place(city,note:String(repeating:"a",count:3950)),tags=try f.place(city,tags:(1...30).map {"Tag \($0)"}),cuisines=try f.place(city,cuisines:(1...20).map {"Cuisine \($0)"}),unicode=try f.place(city)
        let invalid=[proposal(note,"note",String(repeating:"b",count:100),operation:"append"),proposal(tags,"tags",nil,["Extra"],operation:"append"),proposal(cuisines,"cuisines",nil,["Extra"],operation:"append"),proposal(unicode,"name",String(repeating:"😀",count:101))]
        for (i,p) in invalid.enumerated() {var rejected=false;do {_ = try f.commit(p)}catch {rejected=true};check(rejected,"final read bounds \(i)")}
        check(note.note==String(repeating:"a",count:3950) && tags.tags.count==30 && cuisines.cuisines.count==20 && unicode.displayName=="Fixture","invalid writes are atomic")
        // The normalized stored value, not the raw append count, is authoritative.
        _ = try f.commit(proposal(tags,"tags",nil,[" Tag 1 "],operation:"append"))
        check(tags.tags.count==30,"normalized duplicate tag remains admissible")
        _ = try f.commit(proposal(unicode,"name",String(repeating:"😀",count:100)))
        check(unicode.displayName.utf16.count==200,"UTF-16 boundary remains admissible")
        let first=try f.place(city,note:"Short original"),last=try f.place(city,note:String(repeating:"a",count:3950))
        let batch=AskChangeProposal(entity:"place",operation:"append",targetIDs:[first.id!.uuidString,last.id!.uuidString],cityID:nil,sectionID:nil,mapMatchID:nil,changes:[.init(field:"note",value:String(repeating:"b",count:100),values:nil,findingID:nil,source:"user")],instructionQuote:"Append to these fixture notes")
        var batchRejected=false;do {_ = try f.commit(batch)}catch {batchRejected=true}
        check(batchRejected && first.note=="Short original" && last.note==String(repeating:"a",count:3950),"invalid final member rolls back the whole atomic action")
        for mode in ["hidden","denied","duplicate"] {
            let u=try AskMutationAuditFixture(model:model,directory:temporaryDirectory,name:"undo-\(mode)")
            let source=try u.repository.createFeastList(named:"Source"),destination=try u.repository.createFeastList(named:"Destination"),place=try u.place(source,apple:"same-apple")
            let move=AskChangeProposal(entity:"place",operation:"move",targetIDs:[place.id!.uuidString],cityID:destination.id!.uuidString,sectionID:nil,mapMatchID:nil,changes:[],instructionQuote:"Move fixture")
            let action=try u.commit(move)
            if mode=="hidden" {u.policy.hidden=[source.id!]}
            if mode=="denied" {u.policy.denied=[source.objectID]}
            if mode=="duplicate" {_ = try u.place(source,apple:"same-apple")}
            var rejected=false;do {_ = try u.engine.performExplicitAction(action.id,undo:true)}catch {rejected=true}
            check(rejected && place.feastList?.id==destination.id,"Undo rejects \(mode) restored parent atomically")
            if mode != "duplicate" {u.policy.hidden=[];u.policy.denied=[];_ = try u.engine.performExplicitAction(action.id,undo:true);check(place.feastList?.id==source.id,"Undo still works after restoring \(mode) access")}
        }
        for mode in ["sectionPermission","sectionRelationship","crossStore"] {
            let u=try AskMutationAuditFixture(model:model,directory:temporaryDirectory,name:mode)
            let source=try u.repository.createFeastList(named:"Source"),destination=try u.repository.createFeastList(named:"Destination"),section=try u.repository.createListSection(named:"Original Neighborhood",in:source),place=try u.place(source,apple:"store-fixture")
            place.listSection=mode=="crossStore" ? nil : section;try u.context.save()
            let move=AskChangeProposal(entity:"place",operation:"move",targetIDs:[place.id!.uuidString],cityID:destination.id!.uuidString,sectionID:nil,mapMatchID:nil,changes:[],instructionQuote:"Move fixture")
            let action=try u.commit(move)
            if mode=="sectionPermission" {u.policy.denied=[section.objectID]}
            if mode=="sectionRelationship" {section.feastList=destination;try u.context.save()}
            if mode=="crossStore" {
                let oldID=source.id!,coordinator=u.context.persistentStoreCoordinator!
                try u.repository.delete(source)
                let other=try coordinator.addPersistentStore(ofType:NSSQLiteStoreType,configurationName:nil,at:temporaryDirectory.appendingPathComponent("mutation-audit-other-store.sqlite"))
                let replacement=FeastList(context:u.context);u.context.assign(replacement,to:other);replacement.id=oldID;replacement.name="Source";try u.context.save()
            }
            var rejected=false;do {_ = try u.engine.performExplicitAction(action.id,undo:true)}catch {rejected=true}
            check(rejected && place.feastList?.id==destination.id && place.listSection==nil,"Undo rejects \(mode) atomically")
        }
        let s=try AskMutationAuditFixture(model:model,directory:temporaryDirectory,name:"stale"),sc=try s.repository.createFeastList(named:"Identity"),sp=try s.place(sc,apple:"old")
        let old=try s.adapter.personalPlaces().first!
        for field in ["website","instagram"] {
            let url=field=="website" ? "https://old.example.org/" : "https://www.instagram.com/old_fixture/"
            let finding=AskVerifiedFinding(id:UUID(),recordID:sp.id!.uuidString,identity:.init(old),field:field,value:url,evidenceURL:"https://old.example.org/",verification:"cited_search",originatingTurn:UUID())
            sp.applePlaceID="new";try s.context.save()
            let p=AskChangeProposal(entity:"place",operation:"update",targetIDs:[sp.id!.uuidString],cityID:nil,sectionID:nil,mapMatchID:nil,changes:[.init(field:field,value:url,values:nil,findingID:finding.id.uuidString)],instructionQuote:"Save the researched link")
            var rejected=false;do {_ = try s.commit(p,findings:[finding])}catch {rejected=true}
            check(rejected && (field=="website" ? sp.websiteURL : sp.instagramURL)==nil,"stale \(field) identity rejected")
            sp.applePlaceID="old";try s.context.save()
        }
        // A parent rename need not update the place snapshot. Identity binding
        // must survive restart and be rechecked independently at commit.
        let race=try AskMutationAuditFixture(model:model,directory:temporaryDirectory,name:"commit-identity"),rc=try race.repository.createFeastList(named:"Original City"),rp=try race.place(rc)
        let current=try race.adapter.personalPlaces().first!,site="https://fresh.example.org/"
        let finding=AskVerifiedFinding(id:UUID(),recordID:rp.id!.uuidString,identity:.init(current),field:"website",value:site,evidenceURL:site,verification:"cited_search",originatingTurn:UUID())
        let change=AskChangeProposal(entity:"place",operation:"update",targetIDs:[rp.id!.uuidString],cityID:nil,sectionID:nil,mapMatchID:nil,changes:[.init(field:"website",value:site,values:nil,findingID:finding.id.uuidString)],instructionQuote:"Save this researched website")
        let ready=try race.engine.prepare(change,question:change.instructionQuote,authorization:race.grant(change),findings:[finding])
        rc.name="Changed City";try race.context.save()
        let reloaded=AskCollectionChangeEngine(adapter:race.adapter,journalURL:race.engine.journalURL)
        var raceRejected=false;do {_ = try reloaded.apply(ready.id,authorization:race.grant(change))}catch {raceRejected=true}
        check(raceRejected && rp.websiteURL==nil,"parent identity change after preparation rejected across restart")
        rc.name="Original City";try race.context.save()
        let success=try reloaded.apply(ready.id,authorization:race.grant(change))
        let revision=rp.updatedAt
        _ = try reloaded.apply(ready.id,authorization:race.grant(change))
        check(success.state == .applied && rp.websiteURL==site && rp.updatedAt==revision,"fresh finding save and repeated receipt remain valid")
        _ = try reloaded.performExplicitAction(ready.id,undo:true)
        check(rp.websiteURL==nil,"fresh finding save remains undoable")
        // Lossless restores preserve legacy values outside current Ask write
        // limits. Editing an unrelated field must not rewrite or reject them.
        let legacy=try AskMutationAuditFixture(model:model,directory:temporaryDirectory,name:"legacy-preserved"),lc=try legacy.repository.createFeastList(named:"Legacy")
        let lp=try legacy.place(lc,note:String(repeating:"n",count:4100),tags:(1...31).map {"Legacy \($0)"},cuisines:(1...21).map {"Legacy cuisine \($0)"})
        let legacyNote=lp.note,legacyTags=lp.tagsStorage,legacyCuisines=lp.cuisinesStorage
        var legacyEdited=false
        do {let a=try legacy.commit(proposal(lp,"status",PlaceStatus.been.rawValue));legacyEdited=lp.placeStatus == .been;_ = try legacy.engine.performExplicitAction(a.id,undo:true)}catch {}
        check(legacyEdited && lp.placeStatus == .love && lp.note==legacyNote && lp.tagsStorage==legacyTags && lp.cuisinesStorage==legacyCuisines,"unrelated legacy oversize fields survive edit and Undo byte-for-byte")
        // Metadata-only Undo does not introduce an existing nested relationship
        // or duplicate Apple identity and must leave either legacy state intact.
        let parent=try legacy.repository.createListSection(named:"Parent",in:lc),child=ListSection(context:legacy.context)
        child.id=UUID();child.name="Preserved nested child";child.feastList=lc;child.parent=parent
        let original=try legacy.place(lc,apple:"legacy-duplicate"),duplicate=SavedPlace(context:legacy.context)
        duplicate.id=UUID();duplicate.applePlaceID=original.applePlaceID;duplicate.displayNameSnapshot="Preserved duplicate";duplicate.feastList=lc;duplicate.placeStatus = .love;duplicate.placeTypeValue = .restaurant
        original.listSection=child;try legacy.context.save()
        var legacyUndone=false
        do {let a=try legacy.commit(proposal(original,"note","A metadata change"));_ = try legacy.engine.performExplicitAction(a.id,undo:true);legacyUndone=true}catch {}
        check(legacyUndone && original.note==nil && original.listSection===child && child.parent===parent && duplicate.applePlaceID==original.applePlaceID,"metadata Undo preserves unchanged nested and duplicate legacy structure")
        for entity in ["city","neighborhood"] {
            let names=try AskMutationAuditFixture(model:model,directory:temporaryDirectory,name:"undo-name-\(entity)")
            let a=try names.repository.createFeastList(named:entity=="city" ? "Original" : "Container")
            let target:NSManagedObject
            if entity=="city" {target=a}else{target=try names.repository.createListSection(named:"Original",in:a)}
            let rename=AskChangeProposal(entity:entity,operation:"update",targetIDs:[(target.value(forKey:"id") as! UUID).uuidString],cityID:nil,sectionID:nil,mapMatchID:nil,changes:[.init(field:"name",value:"Renamed",values:nil,findingID:nil)],instructionQuote:"Rename fixture")
            let action=try names.commit(rename)
            if entity=="city" {_ = try names.repository.createFeastList(named:"Original")}
            else {_ = try names.repository.createListSection(named:"Original",in:a)}
            var rejected=false;do {_ = try names.engine.performExplicitAction(action.id,undo:true)}catch {rejected=true}
            check(rejected && target.value(forKey:"name") as? String == "Renamed","Undo cannot introduce duplicate \(entity) name")
        }
        let oldFormat=try AskMutationAuditFixture(model:model,directory:temporaryDirectory,name:"old-format"),oc=try oldFormat.repository.createFeastList(named:"Old Format"),op=try oldFormat.place(oc)
        let oldRecord=try oldFormat.adapter.personalPlaces().first!,oldSite="https://old-format.example.org/"
        let oldFinding=AskVerifiedFinding(id:UUID(),recordID:op.id!.uuidString,identity:.init(oldRecord),field:"website",value:oldSite,evidenceURL:oldSite,verification:"cited_search",originatingTurn:UUID())
        let oldProposal=AskChangeProposal(entity:"place",operation:"update",targetIDs:[op.id!.uuidString],cityID:nil,sectionID:nil,mapMatchID:nil,changes:[.init(field:"website",value:oldSite,values:nil,findingID:oldFinding.id.uuidString)],instructionQuote:"Save old-format website")
        let oldReady=try oldFormat.engine.prepare(oldProposal,question:oldProposal.instructionQuote,authorization:oldFormat.grant(oldProposal),findings:[oldFinding])
        func oldIdentityFixture(_ engine:AskCollectionChangeEngine)throws->URL {
            let url=temporaryDirectory.appendingPathComponent("old-identity-"+UUID().uuidString+".json")
            try AskJournalTestSupport.legacyCopy(from:engine,to:url) {entries in
                for i in entries.indices {entries[i].removeValue(forKey:"findingIdentities")}
            }
            return url
        }
        let oldPrepared=AskCollectionChangeEngine(adapter:oldFormat.adapter,journalURL:try oldIdentityFixture(oldFormat.engine))
        var unboundRejected=false;do {_ = try oldPrepared.apply(oldReady.id,authorization:oldFormat.grant(oldProposal))}catch {unboundRejected=true}
        check(unboundRejected && op.websiteURL==nil,"old unbound researched preview safely refuses")
        _ = try oldFormat.engine.apply(oldReady.id,authorization:oldFormat.grant(oldProposal))
        let oldCommitted=AskCollectionChangeEngine(adapter:oldFormat.adapter,journalURL:try oldIdentityFixture(oldFormat.engine))
        _ = try oldCommitted.apply(oldReady.id,authorization:oldFormat.grant(oldProposal))
        _ = try oldCommitted.performExplicitAction(oldReady.id,undo:true)
        check(op.websiteURL==nil,"old committed researched receipt and Undo remain compatible")
        let ordinary=proposal(op,"name","Ordinary restored preview"),ordinaryReady=try oldCommitted.prepare(ordinary,question:ordinary.instructionQuote,authorization:oldFormat.grant(ordinary),findings:[])
        let oldOrdinary=AskCollectionChangeEngine(adapter:oldFormat.adapter,journalURL:try oldIdentityFixture(oldCommitted))
        _ = try oldOrdinary.apply(ordinaryReady.id,authorization:oldFormat.grant(ordinary))
        check(op.displayName=="Ordinary restored preview","old ordinary prepared preview remains compatible")
        // A whole deleted flat graph can contain losslessly restored duplicate
        // names/Maps IDs. Only original peers recreated together are exempt.
        let cascade=try AskMutationAuditFixture(model:model,directory:temporaryDirectory,name:"duplicate-cascade"),cc=try cascade.repository.createFeastList(named:"Cascade")
        let cs=try cascade.repository.createListSection(named:"Same",in:cc),ct=ListSection(context:cascade.context)
        ct.id=UUID();ct.name="Same";ct.feastList=cc
        let cp=try cascade.place(cc,apple:"cascade-duplicate"),cq=SavedPlace(context:cascade.context)
        cq.id=UUID();cq.displayNameSnapshot="Original peer";cq.applePlaceID=cp.applePlaceID;cq.feastList=cc;cq.listSection=ct;cq.note="Keep peer note";cq.placeStatus = .love;cq.placeTypeValue = .restaurant
        cp.listSection=cs;try cascade.context.save()
        let cityUUID=cc.id!,sectionUUIDs=Set([cs.id!,ct.id!]),placeUUIDs=Set([cp.id!,cq.id!])
        let deleteCity=AskChangeProposal(entity:"city",operation:"delete",targetIDs:[cityUUID.uuidString],cityID:nil,sectionID:nil,mapMatchID:nil,changes:[],instructionQuote:"Delete fixture city")
        var cascadeRestored=false
        do {
            let action=try cascade.commit(deleteCity)
            // Simulate exit after the atomic store save but before the journal's
            // final receipt update. The pre-save graph must reconcile exactly.
            let crashURL=cascade.engine.journalURL.appendingPathExtension("cascade-intent-v1")
            try AskJournalTestSupport.legacyCopy(from:cascade.engine,to:crashURL) {entries in
                let i=entries.firstIndex {($0["id"] as? String)==action.id.uuidString}!
                check((entries[i]["after"] as? [Any])?.isEmpty==true,"cascade intent records no deleted children as survivors")
                entries[i]["phase"]="intent"
                var receipt=entries[i]["action"] as! [String:Any];receipt["state"]="needsConfirmation";receipt["undoable"]=false;entries[i]["action"]=receipt
            }
            let afterCrash=AskCollectionChangeEngine(adapter:cascade.adapter,journalURL:crashURL)
            _ = try afterCrash.performExplicitAction(action.id,undo:true);cascadeRestored=true
        }catch {}
        let restoredCities=try cascade.repository.fetchFeastLists(),restoredPlaces=try cascade.repository.fetchSavedPlaces()
        let restoredCity=restoredCities.first {$0.id==cityUUID}
        check(cascadeRestored && Set(restoredCity?.sortedSections.compactMap(\.id) ?? [])==sectionUUIDs && Set(restoredPlaces.compactMap(\.id))==placeUUIDs && restoredPlaces.allSatisfy {$0.applePlaceID=="cascade-duplicate"},"whole-city Undo restores exact original duplicate graph")
        for kind in ["survivingDuplicateSection","nestedPlace","nestedLeafSection"] {
            let f=try AskMutationAuditFixture(model:model,directory:temporaryDirectory,name:kind),city=try f.repository.createFeastList(named:"Restore fixture")
            let section=try f.repository.createListSection(named:"Original",in:city),other=ListSection(context:f.context)
            other.id=UUID();other.name=kind=="survivingDuplicateSection" ? "Original" : "Nested child";other.feastList=city
            if kind != "survivingDuplicateSection" {other.parent=section}
            let place=try f.place(city);place.listSection=other;try f.context.save()
            let sectionID=other.id!,placeID=place.id!,parentID=section.id!
            let entity=kind=="nestedPlace" ? "place" : "neighborhood",target=kind=="nestedPlace" ? placeID : sectionID
            let deletion=AskChangeProposal(entity:entity,operation:"delete",targetIDs:[target.uuidString],cityID:nil,sectionID:nil,mapMatchID:nil,changes:[],instructionQuote:"Delete fixture")
            var undone=false;do {let action=try f.commit(deletion);_ = try f.engine.performExplicitAction(action.id,undo:true);undone=true}catch {}
            let currentPlaces=try f.repository.fetchSavedPlaces(),query=ListSection.fetchRequest(),sections=try f.context.fetch(query)
            let restoredPlace=currentPlaces.first {$0.id==placeID},restoredSection=sections.first {$0.id==sectionID}
            check(undone && restoredPlace?.listSection?.id==sectionID && (kind=="survivingDuplicateSection" || restoredSection?.parent?.id==parentID),"Undo preserves original \(kind) relationships")
        }
        // A new external Maps collider is never covered by the original graph.
        let conflict=try AskMutationAuditFixture(model:model,directory:temporaryDirectory,name:"deleted-external-collider"),xc=try conflict.repository.createFeastList(named:"External"),xp=try conflict.place(xc,apple:"same-external")
        let originalID=xp.id!
        let deletePlace=AskChangeProposal(entity:"place",operation:"delete",targetIDs:[originalID.uuidString],cityID:nil,sectionID:nil,mapMatchID:nil,changes:[],instructionQuote:"Delete original")
        let deletedAction=try conflict.commit(deletePlace)
        let external=try conflict.place(xc,apple:"same-external")
        var externalRejected=false;do {_ = try conflict.engine.performExplicitAction(deletedAction.id,undo:true)}catch {externalRejected=true}
        let remaining=try conflict.repository.fetchSavedPlaces()
        check(externalRejected && remaining.count==1 && remaining.first?.id==external.id,"deleted-row Undo rejects new external Maps collider atomically")
        let ancestry=try AskMutationAuditFixture(model:model,directory:temporaryDirectory,name:"restored-ancestor-city"),ac=try ancestry.repository.createFeastList(named:"Original ancestor city"),otherCity=try ancestry.repository.createFeastList(named:"Changed ancestor city")
        let ancestor=try ancestry.repository.createListSection(named:"Original parent",in:ac),childSection=ListSection(context:ancestry.context)
        childSection.id=UUID();childSection.name="Original child";childSection.feastList=ac;childSection.parent=ancestor
        let nested=try ancestry.place(ac,apple:"ancestor-fixture");nested.listSection=childSection;try ancestry.context.save()
        let nestedID=nested.id!
        let removeNested=AskChangeProposal(entity:"place",operation:"delete",targetIDs:[nestedID.uuidString],cityID:nil,sectionID:nil,mapMatchID:nil,changes:[],instructionQuote:"Delete nested fixture")
        let removedNested=try ancestry.commit(removeNested)
        ancestor.feastList=otherCity;try ancestry.context.save()
        var ancestorRejected=false;do {_ = try ancestry.engine.performExplicitAction(removedNested.id,undo:true)}catch {ancestorRejected=true}
        let finalPlaces=try ancestry.repository.fetchSavedPlaces()
        check(ancestorRejected && !finalPlaces.contains {$0.id==nestedID} && childSection.feastList===ac && childSection.parent===ancestor && ancestor.feastList===otherCity,"Undo refuses changed cross-city ancestor without recreating place or changing parent graph")
        if !failures.isEmpty {throw NSError(domain:"AskMutationAudit",code:1,userInfo:[NSLocalizedDescriptionKey:failures.joined(separator:"; ")])}
        print("PASS mutation audit: final normalized UTF-16 bounds, stale website/Instagram identity, and Undo destination ACL/visibility/uniqueness")
    }
}
