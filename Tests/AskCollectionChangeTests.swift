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
        print("PASS generalized isolated field change, durable restore, repeated apply/Undo, stale edit refusal, permission refusal and confirmed recoverable deletion preserve IDs and unrelated metadata")
    }
}
