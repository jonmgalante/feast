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
        try await staleFindingProviderPaths(model:model,directory:temporaryDirectory)
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

private actor AskIdentityAuditTransport {
    let recordID:String,field:String,repeats:Bool,combined:Bool
    let beforeApproval:@MainActor @Sendable ()throws->Void
    var initialFindings = -1,authorizationFindings = -1
    var resultStatuses:[String]=[]
    init(id:String,field:String,repeats:Bool=false,combined:Bool=false,beforeApproval:@escaping @MainActor @Sendable ()throws->Void){recordID=id;self.field=field;self.repeats=repeats;self.combined=combined;self.beforeApproval=beforeApproval}
    func send(_ request:URLRequest)async throws->(Data,HTTPURLResponse) {
        let body=try JSONSerialization.jsonObject(with:request.httpBody!) as! [String:Any],mode=body["mode"] as! String
        var reply:[String:Any]=["version":9,"requestID":body["requestID"]!]
        if mode=="conversationStep" {
            let step=body["step"] as! Int
            if step==0 {initialFindings=(body["findings"] as? [Any])?.count ?? -1}
            if let result=body["result"] as? [String:Any],let output=result["output"] as? [String:Any],let status=output["status"] as? String {resultStatuses.append(status)}
            let proposing=step==0 || (repeats && step==1)
            let fields=combined ? ["website","instagram"] : [field]
            let changes=fields.map {field->[String:Any] in ["field":field,"value":NSNull(),"values":NSNull(),"findingID":NSNull(),"source":"verified_finding"]}
            let proposal:[String:Any]=["entity":"place","operation":"update","targetIDs":[recordID],"cityID":NSNull(),"sectionID":NSNull(),"mapMatchID":NSNull(),"changes":changes,"instructionQuote":"Save the researched link"]
            reply["step"]=step;reply["kind"]=proposing ? "tool" : "answer";reply["text"]=proposing ? "" : "Finished reviewing the link.";reply["continuation"]="synthetic";reply["model"]="gpt-6.1-sol"
            reply["call"]=proposing ? ["name":"propose_changes","callID":"save-found-link","arguments":String(data:try JSONSerialization.data(withJSONObject:proposal),encoding:.utf8)!] as Any : NSNull()
        } else if mode=="authorizeChange" {
            let proposal=body["proposal"] as! [String:Any]
            authorizationFindings=(proposal["findingContext"] as? [Any])?.count ?? 0
            try await beforeApproval()
            reply["decision"]=["approved":true,"replaceExisting":false,"deleteContents":false,"reason":"explicit_instruction","targetSelector":["scope":"previous","positions":[1]]]
        } else {throw NSError(domain:"UnexpectedSyntheticMode",code:1)}
        return (try JSONSerialization.data(withJSONObject:reply),HTTPURLResponse(url:request.url!,statusCode:200,httpVersion:nil,headerFields:["Content-Type":"application/json"])!)
    }
    func counts()->(Int,Int){(initialFindings,authorizationFindings)}
    func statuses()->[String]{resultStatuses}
}
@MainActor private extension AskFieldActionTests {
    static func staleFindingProviderPaths(model:NSManagedObjectModel,directory:URL)async throws {
        for field in ["website","instagram"] {for phase in ["before","duringApproval","parentDuringApproval","freshReplay"] {
            let coordinator=NSPersistentStoreCoordinator(managedObjectModel:model)
            let store=try coordinator.addPersistentStore(ofType:NSSQLiteStoreType,configurationName:nil,at:directory.appendingPathComponent("identity-provider-\(field)-\(phase).sqlite"))
            let context=NSManagedObjectContext(concurrencyType:.mainQueueConcurrencyType);context.persistentStoreCoordinator=coordinator
            let repository=FeastRepository(context:context),city=try repository.createFeastList(named:"Fixture City")
            let place=try repository.createSavedPlace(from:.init(applePlaceID:"old-business",displayNameSnapshot:"Same Name",status:.love,placeType:.cafe,cuisines:[],tags:[],note:"Preserved",websiteURL:nil,instagramURL:nil,feastList:city,listSection:nil))
            let adapter=AskSavedCollection(context:context,canMutate:{_,_,_ in true},canRecoverStore:{$0==store.identifier},visibleCities:{[city.id!]})
            let record=try adapter.personalPlaces().first!,value=field=="website" ? "https://old.example.org/" : "https://www.instagram.com/old_fixture/"
            let finding=AskVerifiedFinding(id:UUID(),recordID:record.id,identity:.init(record),field:field,value:value,evidenceURL:"https://old.example.org/",verification:"cited_search",originatingTurn:UUID(),externallyReusable:true)
            if phase=="before" {place.applePlaceID="new-business";try context.save()}
            let transport=AskIdentityAuditTransport(id:record.id,field:field,repeats:phase=="freshReplay",beforeApproval:{
                if phase=="duringApproval" {place.applePlaceID="new-business";try context.save()}
                if phase=="parentDuringApproval" {city.name="Changed City";try context.save()}
            })
            let hosted=AskHostedProvider(configuration:.init(environment:.production,endpoint:URL(string:"https://feast-owner-validation.jonmgalante.workers.dev/v1/answer")!,scope:.savedMetadata,productionHost:"feast-owner-validation.jonmgalante.workers.dev",ownerValidation:true),token:{String(repeating:"x",count:43)},approve:{_,_ in true},send:{try await transport.send($0)},libraryToolsEnabled:{true},permission:{true},libraryPlanVersion:{7})
            let engine=AskCollectionChangeEngine(adapter:adapter,journalURL:directory.appendingPathComponent("identity-provider-\(field)-\(phase).json"))
            let provider=AskAgentProvider(remote:hosted,fallback:hosted,adapter:adapter,engine:engine,searchMaps:{_ in preconditionFailure("No real Maps requests")})
            let request=AskRequest(mode:.collection,text:"Save the researched link",fromOCR:false,verifiedFindings:[finding],performanceID:UUID(),agentTask:.init(action:"research",fields:[field],orderedIDs:[record.id],sourcePolicy:"public_if_missing"))
            _ = try? await provider.answer(request,tools:AskReadTools(request:request,index:adapter.index()))
            let counts=await transport.counts()
            precondition(counts.0==(phase=="before" ? 0 : 1),"model evidence must be freshly filtered")
            if phase=="before" {precondition(counts.1<=0,"stale evidence reached authorization")}
            else {precondition(counts.1==1,"race fixture did not reach authorization")}
            if phase=="freshReplay" {
                let statuses=await transport.statuses(),receipts=try engine.receipts(forTurn:request.performanceID!)
                precondition(statuses==["applied","applied"] && receipts.count==1,"Same-executor repeated researched link must return its one original receipt")
                precondition((field=="website" ? place.websiteURL : place.instagramURL)==value && place.note=="Preserved")
                _ = try engine.performExplicitAction(receipts[0].id,undo:true)
                precondition(place.websiteURL==nil && place.instagramURL==nil)
            } else {
            precondition(place.websiteURL==nil && place.instagramURL==nil && place.note=="Preserved","stale identity persisted a researched \(field) at \(phase)")
            }
        }}
        let coordinator=NSPersistentStoreCoordinator(managedObjectModel:model)
        let store=try coordinator.addPersistentStore(ofType:NSSQLiteStoreType,configurationName:nil,at:directory.appendingPathComponent("identity-provider-combined.sqlite"))
        let context=NSManagedObjectContext(concurrencyType:.mainQueueConcurrencyType);context.persistentStoreCoordinator=coordinator
        let repository=FeastRepository(context:context),city=try repository.createFeastList(named:"Combined City")
        let place=try repository.createSavedPlace(from:.init(applePlaceID:"combined-business",displayNameSnapshot:"Combined",status:.love,placeType:.cafe,cuisines:[],tags:[],note:"Preserved",websiteURL:nil,instagramURL:nil,feastList:city,listSection:nil))
        let adapter=AskSavedCollection(context:context,canMutate:{_,_,_ in true},canRecoverStore:{$0==store.identifier},visibleCities:{[city.id!]})
        let record=try adapter.personalPlaces().first!,site="https://combined.example.org/",profile="https://www.instagram.com/combined_fixture/"
        let findings=[("website",site),("instagram",profile)].map {field,value in AskVerifiedFinding(id:UUID(),recordID:record.id,identity:.init(record),field:field,value:value,evidenceURL:site,verification:"cited_search",originatingTurn:UUID(),externallyReusable:true)}
        let transport=AskIdentityAuditTransport(id:record.id,field:"website",repeats:true,combined:true,beforeApproval:{})
        let hosted=AskHostedProvider(configuration:.init(environment:.production,endpoint:URL(string:"https://feast-owner-validation.jonmgalante.workers.dev/v1/answer")!,scope:.savedMetadata,productionHost:"feast-owner-validation.jonmgalante.workers.dev",ownerValidation:true),token:{String(repeating:"x",count:43)},approve:{_,_ in true},send:{try await transport.send($0)},libraryToolsEnabled:{true},permission:{true},libraryPlanVersion:{7})
        let engine=AskCollectionChangeEngine(adapter:adapter,journalURL:directory.appendingPathComponent("identity-provider-combined.json"))
        let provider=AskAgentProvider(remote:hosted,fallback:hosted,adapter:adapter,engine:engine,searchMaps:{_ in preconditionFailure("No real Maps requests")})
        let request=AskRequest(mode:.collection,text:"Save the researched link",fromOCR:false,verifiedFindings:findings,performanceID:UUID(),agentTask:.init(action:"research",fields:["website","instagram"],orderedIDs:[record.id],sourcePolicy:"public_if_missing"))
        _ = try await provider.answer(request,tools:AskReadTools(request:request,index:adapter.index()))
        let statuses=await transport.statuses(),receipts=try engine.receipts(forTurn:request.performanceID!)
        precondition(statuses==["applied","applied"] && receipts.count==1 && place.websiteURL==site && place.instagramURL==profile,"Combined researched link replay must reuse one receipt")
        _ = try engine.performExplicitAction(receipts[0].id,undo:true)
        precondition(place.websiteURL==nil && place.instagramURL==nil && place.note=="Preserved")
        let restoredRequest=AskRequest(mode:.collection,text:"Save the researched link",fromOCR:false,verifiedFindings:findings,performanceID:UUID(),agentTask:.init(action:"research",fields:["website","instagram"],orderedIDs:[record.id],sourcePolicy:"public_if_missing"))
        let direct=AskAgentExecutor(adapter:adapter,engine:engine,request:restoredRequest,researcher:hosted,searchMaps:{_ in []},fullCollectionContext:true)
        let combinedProposal=AskChangeProposal(entity:"place",operation:"update",targetIDs:[record.id],cityID:nil,sectionID:nil,mapMatchID:nil,changes:["website","instagram"].map {.init(field:$0,value:nil,values:nil,findingID:nil,source:"verified_finding")},instructionQuote:"Save the researched link")
        let call=AskAgentReply.Call(name:"propose_changes",callID:"combined-restored",arguments:String(data:try JSONEncoder().encode(combinedProposal),encoding:.utf8)!)
        let first=try await direct.executeConversation(call,planner:hosted)
        let checkpoint=try direct.recoverySnapshot()
        let resumed=AskAgentExecutor(adapter:adapter,engine:engine,request:restoredRequest,researcher:hosted,searchMaps:{_ in []},fullCollectionContext:true)
        try resumed.restoreRecoverySnapshot(checkpoint)
        let repeated=try await resumed.executeConversation(call,planner:hosted)
        let restoredReceipts=try engine.receipts(forTurn:restoredRequest.performanceID!)
        precondition(first.output.status=="applied" && repeated.output.status=="applied" && restoredReceipts.count==1 && place.websiteURL==site && place.instagramURL==profile,"Restored executor combined-link replay must reuse one receipt")
        _ = try engine.performExplicitAction(restoredReceipts[0].id,undo:true)
        precondition(place.websiteURL==nil && place.instagramURL==nil && place.note=="Preserved")
        print("PASS full hosted-provider path rejects stale website/Instagram before authorization and identity changes during authorization, including parent rename; same-executor repeated researched writes reuse one undoable receipt")
    }
}
