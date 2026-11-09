import CoreData
import Foundation
@MainActor enum AskCollectionChangeTests {
    static func run(model:NSManagedObjectModel,temporaryDirectory:URL)throws {
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
        var archive=try JSONSerialization.jsonObject(with:Data(contentsOf:url)) as! [String:Any]
        var entries=archive["entries"] as! [[String:Any]]
        let crashIndex=entries.firstIndex {(($0["id"] as? String)?.lowercased())==interrupted.id.uuidString.lowercased()}!
        entries[crashIndex]["phase"]="intent"
        var crashAction=entries[crashIndex]["action"] as! [String:Any];crashAction["targetIDs"]=[];entries[crashIndex]["action"]=crashAction
        archive["entries"]=entries;try JSONSerialization.data(withJSONObject:archive).write(to:url,options:.atomic)
        let crashEngine=AskCollectionChangeEngine(adapter:adapter,journalURL:url)
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
        var interruptedArchive=try JSONSerialization.jsonObject(with:Data(contentsOf:dedupURL)) as! [String:Any]
        var interruptedEntries=interruptedArchive["entries"] as! [[String:Any]]
        let intentIndex=interruptedEntries.firstIndex {($0["id"] as? String)==createdOnce.id.uuidString}!
        interruptedEntries[intentIndex]["phase"]="intent"
        interruptedArchive["entries"]=interruptedEntries;try JSONSerialization.data(withJSONObject:interruptedArchive).write(to:dedupURL,options:.atomic)
        let afterCreationCrash=AskCollectionChangeEngine(adapter:adapter,journalURL:dedupURL)
        let recoveredIntent=try afterCreationCrash.prepare(creation,question:creation.instructionQuote,authorization:recoveryGrant(creation),findings:[],turnID:turn,chatID:chat,recoveryOperationID:createKey)
        let createdAgain=try afterCreationCrash.apply(recoveredIntent.id,authorization:recoveryGrant(creation),maps:[match.id:match])
        precondition(createdAgain.id==createdOnce.id && createdAgain.targetIDs==createdOnce.targetIDs)
        _ = try afterCreationCrash.performExplicitAction(createdOnce.id,undo:true)
        let afterUndo=AskCollectionChangeEngine(adapter:adapter,journalURL:dedupURL)
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
        let restoredDeletionEngine=AskCollectionChangeEngine(adapter:adapter,journalURL:dedupURL)
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
