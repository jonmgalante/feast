import Foundation
import CoreData
private actor AgentBusinessFixture:AskBusinessResearching {
    var calls:[String]=[];let failAt:Int?,failure:AskHostedError;let empty:Bool
    init(failAt:Int?=nil,failure:AskHostedError = .service(503),empty:Bool=false){self.failAt=failAt;self.failure=failure;self.empty=empty}
    func publicLookupAvailable()async->Bool {true}
    func businessResearch(_ request:AskBusinessRequest)async throws->AskBusinessResult {
        calls.append(request.business.name)
        if calls.count==failAt {throw failure}
        if empty {return .init(version:1,state:"unverified",business:request.business,findings:[])}
        let handle=request.business.name.lowercased().filter {$0.isLetter||$0.isNumber}
        return .init(version:1,state:"found",business:request.business,findings:request.fields.map {field in .init(field:field,value:field=="instagram" ? "https://www.instagram.com/"+handle+"/" : "Public phone 123",sourceURL:"https://example.org/business/"+handle,quote:"The official business website supplies this public business detail.",title:"Fixture official page",verification:"cited_search")})
    }
    func count()->Int {calls.count}
}
private actor AgentExecutorPlanFixture:AskAgentPlanning {
    var calls:[AskAgentReply.Call]
    init(_ calls:[AskAgentReply.Call]) {self.calls=calls}
    func agentStep(_ step:AskAgentStep) async throws->AskAgentReply {
        guard !calls.isEmpty else {throw AskError.invalidEvidence}
        return .init(version:8,requestID:step.requestID,step:step.step,call:calls.removeFirst(),continuation:"fixture",model:"gpt-6-astra")
    }
}
private actor AgentMutationGate {
    var applied=false;var continuation:CheckedContinuation<Void,Never>?
    func pause()async {applied=true;await withCheckedContinuation {continuation=$0}}
    func ready()->Bool {applied}
    func release(){continuation?.resume();continuation=nil}
}
private struct AgentMutationPauseProvider:AskFeastProvider {
    let label="Isolated mutation cancellation fixture"
    let gate:AgentMutationGate
    let apply:@MainActor @Sendable (AskRequest)throws->AskResponse
    func answer(_ request:AskRequest,tools:AskReadTools)async throws->AskResponse {
        let response=try await apply(request);await gate.pause();return response
    }
}
@MainActor enum AskAgentExecutorTests {
    static func run(model:NSManagedObjectModel,temporaryDirectory:URL)async throws {
        let coordinator=NSPersistentStoreCoordinator(managedObjectModel:model)
        let store=try coordinator.addPersistentStore(ofType:NSSQLiteStoreType,configurationName:nil,at:temporaryDirectory.appendingPathComponent("agent-executor.sqlite"))
        let context=NSManagedObjectContext(concurrencyType:.mainQueueConcurrencyType);context.persistentStoreCoordinator=coordinator
        let repo=FeastRepository(context:context),chicago=try repo.createFeastList(named:"Chicago"),london=try repo.createFeastList(named:"London")
        let names=["Alinea","Giordano’s","Soho House Chicago"]
        var places:[SavedPlace]=[]
        for (i,name) in names.enumerated() {places.append(try repo.createSavedPlace(from:.init(applePlaceID:"isolated-chicago-\(i)",displayNameSnapshot:name,status:.wantToTry,placeType:.restaurant,cuisines:[],tags:["Preserved"],note:"Private fixture note",websiteURL:nil,instagramURL:nil,feastList:chicago,listSection:nil)))}
        let londonNames=["Dishoom","Dishoom","Notting Hill Farmers’ Market","Portobello Market","Qima Cafe","The Ladbroke Arms"]
        for i in 0..<6 {_ = try repo.createSavedPlace(from:.init(applePlaceID:"isolated-london-\(i)",displayNameSnapshot:londonNames[i],status:.love,placeType:i==0 ? .restaurant : i==4 ? .cafe : .other,cuisines:[],tags:[],note:nil,websiteURL:nil,instagramURL:nil,feastList:london,listSection:nil))}
        let section=try repo.createListSection(named:"Shoreditch",in:london)
        let adapter=AskSavedCollection(context:context,canMutate:{_,_,_ in true},canRecoverStore:{$0==store.identifier},visibleCities:{[chicago.id!,london.id!]})
        let engine=AskCollectionChangeEngine(adapter:adapter,journalURL:temporaryDirectory.appendingPathComponent("agent-executor-actions.json"))
        let ids=places.map {$0.id!.uuidString}
        func call(_ name:String,_ values:[String:Any])->AskAgentReply.Call {.init(name:name,callID:UUID().uuidString,arguments:String(data:try! JSONSerialization.data(withJSONObject:values),encoding:.utf8)!)}
        func intent(_ goal:String,_ permissions:[[String:Any]]=[],_ fields:[String]=["instagram"] )throws->AskAgentInterpretation {try JSONDecoder().decode(AskAgentInterpretation.self,from:JSONSerialization.data(withJSONObject:["goal":goal,"sourcePolicy":"public_if_missing","fields":fields,"selectionIDs":ids,"permissions":permissions]))}
        let researcher=AgentBusinessFixture(),request=AskRequest(mode:.collection,text:"Find their Instagrams",fromOCR:false,performanceID:UUID(),agentTask:.init(action:"research",fields:["instagram"],orderedIDs:ids,sourcePolicy:"public_if_missing"))
        let executor=AskAgentExecutor(adapter:adapter,engine:engine,request:request,researcher:researcher,searchMaps:{_ in []})
        let lookup=call("research_businesses",["targetIDs":ids,"fields":["instagram"],"sourcePolicy":"public_if_missing"])
        try executor.prepare(intent("research"))
        let emptyResearcher=AgentBusinessFixture(empty:true)
        let emptyExecutor=AskAgentExecutor(adapter:adapter,engine:engine,request:request,researcher:emptyResearcher,searchMaps:{_ in []})
        try emptyExecutor.prepare(intent("research"))
        let emptyLookup=try await emptyExecutor.execute(lookup,intent:intent("research"))
        precondition(emptyLookup.response?.paragraphs.filter {$0.transientToolStatus==true}.count==3)
        let found=try await executor.execute(lookup,intent:intent("research"))
        precondition(found.response?.fieldActions?.count==3 && found.response?.verifiedPublicFindings?.count==3 && found.orderedIDs==ids)
        _ = try await executor.execute(lookup,intent:intent("research"));let repeatedCount=await researcher.count();precondition(repeatedCount==3)
        // A restored executor reuses successful public lookups and the same
        // reference order, without making another provider call.
        let executorSnapshot=try executor.recoverySnapshot()
        let restoredExecutor=AskAgentExecutor(adapter:adapter,engine:engine,request:request,researcher:researcher,searchMaps:{_ in []})
        try restoredExecutor.restoreRecoverySnapshot(executorSnapshot)
        let restoredLookup=try await restoredExecutor.execute(lookup,intent:intent("research"))
        let restoredCount=await researcher.count()
        precondition(restoredCount==3 && restoredLookup.orderedIDs==found.orderedIDs && restoredLookup.response?.verifiedPublicFindings==found.response?.verifiedPublicFindings)
        var wrongRequest=request;wrongRequest.performanceID=UUID()
        let wrongExecutor=AskAgentExecutor(adapter:adapter,engine:engine,request:wrongRequest,researcher:researcher,searchMaps:{_ in []})
        do {try wrongExecutor.restoreRecoverySnapshot(executorSnapshot);preconditionFailure("A checkpoint from another turn was restored")}catch {}
        do {try restoredExecutor.restoreRecoverySnapshot(Data("{}".utf8));preconditionFailure("Corrupt executor checkpoint was accepted")}catch {}
        print("PASS executor restart preserves research cache and reference order without paid replay; mismatched/corrupt checkpoint rejected")
        var saveRequest=request;saveRequest=AskRequest(mode:.collection,text:"Save all three",fromOCR:false,verifiedFindings:found.response!.verifiedPublicFindings!,performanceID:UUID(),agentTask:request.agentTask)
        let saver=AskAgentExecutor(adapter:adapter,engine:engine,request:saveRequest,researcher:researcher,searchMaps:{_ in []})
        let permission:[String:Any]=["entity":"place","operations":["update"],"fields":["instagram"],"targetIDs":ids,"instructionQuote":"Save all three","selector":NSNull(),"changes":[["field":"instagram","source":"verified_finding","value":NSNull(),"values":NSNull()]]]
        let saving=try intent("change",[permission]);try saver.prepare(saving)
        let proposal:[String:Any]=["entity":"place","operation":"update","targetIDs":ids,"cityID":NSNull(),"sectionID":NSNull(),"mapMatchID":NSNull(),"changes":[["field":"instagram","value":NSNull(),"values":NSNull(),"findingID":NSNull()]],"instructionQuote":"Save all three"]
        var savedActions:[AskCollectionAction]=[]
        for id in ids {
            var single=proposal;single["targetIDs"]=[id]
            let tool=call("propose_changes",single)
            let saved=try await saver.execute(tool,intent:saving)
            precondition(!saved.output.localOnly && saved.output.status=="applied" && saved.output.records.isEmpty && saved.output.findings.isEmpty && saved.output.totalCount==0 && saved.orderedIDs==ids)
            savedActions += saved.response?.collectionActions ?? []
            _ = try await saver.execute(tool,intent:saving) // same call cannot repeat its journal/write
        }
        precondition(savedActions.count==3 && places.allSatisfy {$0.instagramURL != nil && $0.note=="Private fixture note" && $0.tags==["Preserved"]})
        var replayGroup=proposal;replayGroup["instructionQuote"]="all three"
        let replayed=try await saver.execute(call("propose_changes",replayGroup),intent:saving)
        precondition(replayed.outcomes?.count==3 && replayed.outcomes?.allSatisfy {$0.state=="applied"}==true)
        let savedReceipts=try engine.receipts(forTurn:saveRequest.performanceID!);precondition(savedReceipts.count==3)
        let saverSnapshot=try saver.recoverySnapshot()
        let restoredSaver=AskAgentExecutor(adapter:adapter,engine:engine,request:saveRequest,researcher:researcher,searchMaps:{_ in []})
        try restoredSaver.restoreRecoverySnapshot(saverSnapshot)
        do {_ = try await restoredSaver.execute(call("propose_changes",proposal),intent:saving);preconditionFailure("A prepared authorization grant was restored")}catch {}
        try restoredSaver.prepare(saving)
        _ = try await restoredSaver.execute(call("propose_changes",proposal),intent:saving)
        let replayReceipts=try engine.receipts(forTurn:saveRequest.performanceID!)
        precondition(replayReceipts==savedReceipts)
        print("PASS restored executor does not restore mutation authorization; fresh preparation reuses durable receipts without duplicate edits")
        let undoRequest=AskRequest(mode:.collection,text:"Undo the second one",fromOCR:false,agentTask:.init(action:"change",fields:["instagram"],orderedIDs:ids,sourcePolicy:"local_only"))
        let undoer=AskAgentExecutor(adapter:adapter,engine:engine,request:undoRequest,researcher:researcher,searchMaps:{_ in []})
        let undoPermission:[String:Any]=["entity":"place","operations":["undo"],"fields":[],"targetIDs":[ids[1]],"instructionQuote":"Undo the second one","changes":[],"selector":["city":NSNull(),"name":NSNull(),"neighborhood":NSNull(),"cuisine":NSNull(),"status":NSNull(),"placeType":NSNull(),"scope":"previous","positions":[2]]]
        var conflictingUndo=undoPermission;conflictingUndo["targetIDs"]=[ids[0]]
        do {try undoer.prepare(intent("change",[conflictingUndo],[]));preconditionFailure("Contradictory ordinal and explicit ID accepted")}catch {}
        let undoIntent=try intent("change",[undoPermission],[]);try undoer.prepare(undoIntent)
        var undo=proposal;undo["operation"]="undo";undo["targetIDs"]=[ids[1]];undo["changes"]=[];undo["instructionQuote"]="Undo the second one"
        _ = try await undoer.execute(call("propose_changes",undo),intent:undoIntent)
        undo["instructionQuote"]="second one"
        _ = try await undoer.execute(call("propose_changes",undo),intent:undoIntent)
        precondition(places[0].instagramURL != nil && places[1].instagramURL==nil && places[2].instagramURL != nil)
        let afterExternalUndo=try await restoredSaver.execute(call("propose_changes",proposal),intent:saving)
        precondition(afterExternalUndo.response?.collectionActions?.first(where:{$0.targetIDs==[ids[1]]})?.state == .undone && places[1].instagramURL==nil)
        print("PASS recovered receipt cache refreshes an externally undone action and never silently reapplies it")
        // Stop before an executor reaches persistence must leave both the field
        // and durable action journal unchanged. The gate makes the race ordered,
        // rather than relying on a timing-sensitive sleep.
        let beforeWriteGate=AgentMutationGate()
        let receiptsBeforeCancellation=try engine.receipts(forTurn:saveRequest.performanceID!)
        let cancelledWrite=Task { @MainActor in
            await beforeWriteGate.pause()
            return try await saver.execute(call("propose_changes",proposal),intent:saving)
        }
        while !(await beforeWriteGate.ready()) {await Task.yield()}
        cancelledWrite.cancel();await beforeWriteGate.release()
        do {_ = try await cancelledWrite.value;preconditionFailure("Stopped mutation reached persistence")}
        catch is CancellationError {}
        precondition(places[1].instagramURL==nil)
        let receiptsAfterCancellation=try engine.receipts(forTurn:saveRequest.performanceID!)
        precondition(receiptsAfterCancellation==receiptsBeforeCancellation)
        print("PASS Stop before mutation leaves SQLite and journal unchanged; mocked execution with ordered gate")
        let query:[String:Any]=["entity":"place","selectionIDs":NSNull(),"query":["operation":"list","scope":"library","city":"London","cuisine":NSNull(),"status":NSNull(),"placeType":NSNull(),"name":NSNull(),"positions":[],"fields":[],"neighborhood":NSNull(),"groupBy":NSNull(),"names":NSNull()]]
        let listed=try await executor.execute(call("query_collection",query),intent:intent("query",[],[]));precondition(listed.response?.candidates.count==6)
        let neighborhoodRequest=AskRequest(mode:.collection,text:"Rename Shoreditch to Shoreditch East",fromOCR:false)
        let neighborhoodExecutor=AskAgentExecutor(adapter:adapter,engine:engine,request:neighborhoodRequest,researcher:researcher,searchMaps:{_ in []})
        let npermission:[String:Any]=["entity":"neighborhood","operations":["update"],"fields":["name"],"targetIDs":[],"instructionQuote":neighborhoodRequest.text,"selector":["city":"London","name":"Shoreditch","neighborhood":NSNull(),"cuisine":NSNull(),"status":NSNull(),"placeType":NSNull()],"changes":[["field":"name","source":"user","value":"Shoreditch East","values":NSNull()]]]
        let ni=try intent("change",[npermission],["name"]);try neighborhoodExecutor.prepare(ni)
        var np=proposal;np["entity"]="neighborhood";np["targetIDs"]=[];np["changes"]=[["field":"name","value":"Shoreditch East","values":NSNull(),"findingID":NSNull()]];np["instructionQuote"]=neighborhoodRequest.text
        _ = try await neighborhoodExecutor.execute(call("propose_changes",np),intent:ni)
        precondition(section.name=="Shoreditch East")
        let londonRecords=try adapter.personalPlaces().filter {$0.city=="London"}
        let qima=londonRecords.first {$0.name=="Qima Cafe"}!
        let qimaRequest=AskRequest(mode:.collection,text:"What about Qima Cafe?",fromOCR:false,verifiedFindings:found.response!.verifiedPublicFindings!,performanceID:UUID(),agentTask:request.agentTask)
        let qimaResearcher=AgentBusinessFixture(),qimaExecutor=AskAgentExecutor(adapter:adapter,engine:engine,request:qimaRequest,researcher:qimaResearcher,searchMaps:{_ in []})
        let qimaResult=try await qimaExecutor.execute(call("research_businesses",["targetIDs":[qima.id],"fields":["instagram"],"sourcePolicy":"public_if_missing"]),intent:intent("research"))
        precondition(qimaResult.response?.candidates.map(\.id)==[qima.id] && qimaResult.response?.verifiedPublicFindings?.first?.recordID==qima.id)
        let duplicateResearcher=AgentBusinessFixture(),duplicateExecutor=AskAgentExecutor(adapter:adapter,engine:engine,request:qimaRequest,researcher:duplicateResearcher,searchMaps:{_ in []})
        let dish=Array(londonRecords.filter {$0.name=="Dishoom"}.map(\.id))
        let branchResult=try await duplicateExecutor.execute(call("research_businesses",["targetIDs":dish,"fields":["instagram"],"sourcePolicy":"public_if_missing"]),intent:intent("research"))
        let branchCalls=await duplicateResearcher.count();precondition(branchCalls==0 && branchResult.response?.verifiedPublicFindings?.isEmpty==true && branchResult.response?.candidates.count==2)
        // A later item refusing permission must not hide an earlier committed item.
        let partialAdapter=AskSavedCollection(context:context,canMutate:{_,objectID,_ in objectID != places[1].objectID},canRecoverStore:{$0==store.identifier},visibleCities:{[chicago.id!,london.id!]})
        let partialEngine=AskCollectionChangeEngine(adapter:partialAdapter,journalURL:temporaryDirectory.appendingPathComponent("partial-actions.json"))
        let partialRequest=AskRequest(mode:.collection,text:"Add this tag",fromOCR:false,performanceID:UUID(),agentTask:request.agentTask)
        let partialExecutor=AskAgentExecutor(adapter:partialAdapter,engine:partialEngine,request:partialRequest,researcher:researcher,searchMaps:{_ in []})
        let tagPermission:[String:Any]=["entity":"place","operations":["append"],"fields":["tags"],"targetIDs":ids,"instructionQuote":"Add this tag","changes":[["field":"tags","source":"user","value":NSNull(),"values":["New tag"]]]]
        let tagIntent=try intent("change",[tagPermission],["tags"]);try partialExecutor.prepare(tagIntent)
        var tag=proposal;tag["operation"]="append";tag["changes"]=[["field":"tags","value":NSNull(),"values":["New tag"],"findingID":NSNull()]];tag["instructionQuote"]="Add this tag"
        let partial=try await partialExecutor.execute(call("propose_changes",tag),intent:tagIntent)
        precondition(partial.response?.collectionActions?.count==1 && places[0].tags.contains("New Tag") && !places[1].tags.contains("New Tag") && !places[2].tags.contains("New Tag"))
        precondition(partial.outcomes?.map(\.state)==["applied","failed","pending"])
        // Private selection membership must never become an uploaded ordinary result on a follow-up.
        let appendRequest=AskRequest(mode:.collection,text:"Append Keep to Alinea tags",fromOCR:false,performanceID:UUID())
        let appender=AskAgentExecutor(adapter:adapter,engine:engine,request:appendRequest,researcher:researcher,searchMaps:{_ in []})
        let ap:[String:Any]=["entity":"place","operations":["append"],"fields":["tags"],"targetIDs":[ids[0]],"instructionQuote":appendRequest.text,"changes":[["field":"tags","source":"user","value":NSNull(),"values":["Keep"]]]]
        let ai=try intent("change",[ap],["tags"]);try appender.prepare(ai)
        var av:[String:Any]=["entity":"place","operation":"append","targetIDs":[ids[0]],"cityID":NSNull(),"sectionID":NSNull(),"mapMatchID":NSNull(),"changes":[["field":"tags","value":NSNull(),"values":["Keep"],"findingID":NSNull()]],"instructionQuote":appendRequest.text]
        _ = try await appender.execute(call("propose_changes",av),intent:ai)
        av["instructionQuote"]="Keep"
        _ = try await appender.execute(call("propose_changes",av),intent:ai)
        precondition(places[0].tags.filter {$0=="Keep"}.count==1)
        let appendReceipts=try engine.receipts(forTurn:appendRequest.performanceID!);precondition(appendReceipts.count==1)

        let privateRequest=AskRequest(mode:.collection,text:"Show those again",fromOCR:false,agentTask:.init(action:"query",fields:["status"],orderedIDs:[ids[0]],sourcePolicy:"stored_only",privateSelection:true))
        let privateExecutor=AskAgentExecutor(adapter:adapter,engine:engine,request:privateRequest,researcher:researcher,searchMaps:{_ in []})
        var previous=query;var previousPlan=previous["query"] as! [String:Any];previousPlan["city"]=NSNull();previousPlan["scope"]="previous";previous["query"]=previousPlan
        let privateResult=try await privateExecutor.execute(call("query_collection",previous),intent:intent("query",[],[]))
        precondition(privateResult.output.localOnly && privateResult.output.records.isEmpty && privateResult.selectionIsPrivate)
        precondition(privateRequest.agentTask!.externalProjection.orderedIDs.isEmpty)
        previousPlan["fields"]=["instagram"];previous["query"]=previousPlan
        let privateLinks=try await privateExecutor.execute(call("query_collection",previous),intent:intent("query",[],["instagram"]))
        precondition(privateLinks.response?.verifiedPublicFindings==nil && privateLinks.output.findings.isEmpty)
        let privateCallsBefore=await researcher.count()
        let blockedResearch=try await privateExecutor.execute(call("research_businesses",["targetIDs":[ids[0]],"fields":["instagram"],"sourcePolicy":"public_if_missing"]),intent:intent("research"))
        let privateCallsAfter=await researcher.count();precondition(blockedResearch.output.localOnly && privateCallsBefore==privateCallsAfter)

        precondition(!AskAgentExecutor.explicitlyNames("Bar",in:"Find Barbara's Instagram"))
        precondition(!AskAgentExecutor.explicitlyNames("Love",in:"I'd love their Instagram"))
        precondition(!AskAgentExecutor.explicitlyNames("Qima Cafe",in:"Find Qima Cafeteria online"))
        precondition(AskAgentExecutor.explicitlyNames("Qima Cafe",in:"Find Qima Café’s Instagram"))
        precondition(AskAgentExecutor.explicitlyNames("The Ladbroke Arms",in:"Ladbroke Arms Instagram"))

        // A committed action is visible even if Stop wins before the provider response arrives.
        let gate=AgentMutationGate()
        let provider=AgentMutationPauseProvider(gate:gate,apply:{request in
            let p=AskChangeProposal(entity:"place",operation:"update",targetIDs:[ids[0]],cityID:nil,sectionID:nil,mapMatchID:nil,changes:[.init(field:"note",value:"Private fixture note; secret fixture",values:nil,findingID:nil)],instructionQuote:request.text)
            let grant=AskChangeGrant(question:request.text,entity:"place",operations:["update"],fields:["note"],targetIDs:[ids[0]],allowsCreation:false,boundProposal:p)
            let ready=try engine.prepare(p,question:request.text,authorization:grant,findings:[],turnID:request.performanceID,chatID:request.conversationID)
            let saved=try engine.apply(ready.id,authorization:grant)
            return .init(summary:"Late response must not overwrite recovery",candidates:[],listedCandidateIDs:[],usesLocalCatalog:true,collectionActions:[saved])
        })
        let history=AskConversationStore(url:temporaryDirectory.appendingPathComponent("agent-cancel-chats.json"))
        let session=AskSession(index:try adapter.index(),provider:provider)
        session.collectionReceipts={try engine.receipts(forTurn:$0)};session.collectionRecovery={try engine.recoverableTurns(in:$0)}
        session.restoreHistory(from:history);session.input="Add this private note: secret fixture";session.run()
        for _ in 0..<100 {if await gate.ready() {break};try await Task.sleep(nanoseconds:10_000_000)}
        let mutationReady=await gate.ready();precondition(mutationReady)
        session.flushHistory()
        let interruptedData=try Data(contentsOf:history.url)
        session.cancel();precondition(session.turns.last?.status == .complete && session.turns.last?.response?.collectionActions?.count==1)
        await gate.release();try await Task.sleep(nanoseconds:30_000_000)
        precondition(session.turns.last?.response?.summary=="Changes recorded before this request stopped.")
        // Simulate the saved interrupted chat file preceding presentation, not a new write.
        let crashURL=temporaryDirectory.appendingPathComponent("agent-crash-chats.json");try interruptedData.write(to:crashURL)
        let recoveredSession=AskSession(index:try adapter.index(),provider:provider);recoveredSession.collectionRecovery={try engine.recoverableTurns(in:$0)}
        recoveredSession.restoreHistory(from:.init(url:crashURL))
        precondition(recoveredSession.turns.last?.response?.collectionActions?.count==1 && recoveredSession.input.isEmpty)
        precondition(places[0].note=="Private fixture note; secret fixture" && places[0].displayNameSnapshot=="Alinea")
        precondition(!AskSemanticContext.recentQuestions(session.turns).contains(where:{$0.question.contains("secret fixture")}))
        precondition(!AskSemanticContext.recentQuestions(recoveredSession.turns).contains(where:{$0.question.contains("secret fixture")}))
        if let receipt=recoveredSession.turns.last?.response?.collectionActions?.first {_ = try engine.performExplicitAction(receipt.id,undo:true)}
        precondition(places[0].note=="Private fixture note")
        // Any selected set uses the same leaf executor; six is a research batch size,
        // never a mutation-selector limit. No real collection is touched.
        let broadRequest=AskRequest(mode:.collection,text:"Tag all London places and Chicago places",fromOCR:false,performanceID:UUID())
        let broad=AskAgentExecutor(adapter:adapter,engine:engine,request:broadRequest,researcher:researcher,searchMaps:{_ in []})
        let broadPermission:[String:Any]=["entity":"place","operations":["append"],"fields":["tags"],"targetIDs":[],"instructionQuote":broadRequest.text,"selector":["city":NSNull(),"name":NSNull(),"neighborhood":NSNull(),"cuisine":NSNull(),"status":NSNull(),"placeType":NSNull(),"scope":"library","positions":[]],"changes":[["field":"tags","source":"user","value":NSNull(),"values":["Batch test"]]]]
        let broadIntent=try intent("change",[broadPermission]);try broad.prepare(broadIntent)
        var broadProposal=proposal;broadProposal["operation"]="append";broadProposal["targetIDs"]=[];broadProposal["instructionQuote"]=broadRequest.text;broadProposal["changes"]=[["field":"tags","value":NSNull(),"values":["Batch test"],"findingID":NSNull()]]
        let broadResult=try await broad.execute(call("propose_changes",broadProposal),intent:broadIntent)
        precondition(broadResult.response?.collectionActions?.count==9 && broadResult.outcomes?.count==9)
        let aggregate=AskAgentExecutor(adapter:adapter,engine:engine,request:request,researcher:researcher,searchMaps:{_ in []})
        let researchIDs=try adapter.personalPlaces().filter {!($0.name=="Dishoom")}.map(\.id)
        precondition(researchIDs.count==7)
        let firstBatch=try await aggregate.execute(call("research_businesses",["targetIDs":Array(researchIDs.prefix(6)),"fields":["instagram"],"sourcePolicy":"public_if_missing"]),intent:intent("research"))
        let secondBatch=try await aggregate.execute(call("research_businesses",["targetIDs":Array(researchIDs.suffix(1)),"fields":["instagram"],"sourcePolicy":"public_if_missing"]),intent:intent("research"))
        precondition(firstBatch.response?.candidates.count==6 && secondBatch.response?.candidates.count==7 && secondBatch.orderedIDs==researchIDs)
        let repeatedBatch=try await aggregate.execute(call("research_businesses",["targetIDs":Array(researchIDs.prefix(6)),"fields":["instagram"],"sourcePolicy":"public_if_missing"]),intent:intent("research"))
        precondition(repeatedBatch.response?.candidates.count==7 && repeatedBatch.response?.paragraphs.count==secondBatch.response?.paragraphs.count)
        let phoneBatch=try await aggregate.execute(call("research_businesses",["targetIDs":[researchIDs[0]],"fields":["phone"],"sourcePolicy":"public_if_missing"]),intent:intent("research"))
        precondition(phoneBatch.response?.verifiedPublicFindings?.count==8 && phoneBatch.response?.fieldActions?.count==7 && phoneBatch.response?.paragraphs.contains(where:{$0.representedField=="phone"})==true)
        let afterPhoneReplay=try await aggregate.execute(call("research_businesses",["targetIDs":[researchIDs[0]],"fields":["instagram"],"sourcePolicy":"public_if_missing"]),intent:intent("research"))
        precondition(afterPhoneReplay.response?.verifiedPublicFindings?.count==8 && afterPhoneReplay.response?.fieldActions?.count==7 && afterPhoneReplay.response?.paragraphs.count==phoneBatch.response?.paragraphs.count)
        var checkedAggregate=afterPhoneReplay.response!
        checkedAggregate.agentTask = .init(action:"research",fields:["instagram","phone"],orderedIDs:afterPhoneReplay.orderedIDs,sourcePolicy:"public_if_missing")
        _ = try AskReadTools(request:request.collectionReadVersion(),index:adapter.index()).checked(checkedAggregate)
        let beforeCapacity=await researcher.count()
        let capacity=try await aggregate.execute(call("research_businesses",["targetIDs":Array(researchIDs.prefix(6)),"fields":["phone","address","hours","menu"],"sourcePolicy":"public_if_missing"]),intent:intent("research"))
        let afterCapacity=await researcher.count()
        precondition(capacity.output.status=="unavailable" && !capacity.output.complete && beforeCapacity==afterCapacity && capacity.response?.fieldActions?.count==7)
        var capacityChecked=capacity.response!;capacityChecked.agentTask=checkedAggregate.agentTask
        _ = try AskReadTools(request:request.collectionReadVersion(),index:adapter.index()).checked(capacityChecked)
        var retainedRequest=request;retainedRequest.verifiedFindings=Array(found.response!.verifiedPublicFindings!.prefix(1))
        let retainedCapacity=AskAgentExecutor(adapter:adapter,engine:engine,request:retainedRequest,researcher:researcher,searchMaps:{_ in []})
        let retainedStop=try await retainedCapacity.execute(call("research_businesses",["targetIDs":researchIDs.prefix(6).contains(retainedRequest.verifiedFindings[0].recordID) ? Array(researchIDs.prefix(6)) : [retainedRequest.verifiedFindings[0].recordID]+Array(researchIDs.filter {$0 != retainedRequest.verifiedFindings[0].recordID}.prefix(5)),"fields":["phone","address","hours","menu"],"sourcePolicy":"public_if_missing"]),intent:intent("research"))
        precondition(retainedStop.output.status=="unavailable" && !retainedStop.output.complete)
        let afterRetainedCapacity=await researcher.count();precondition(afterRetainedCapacity==beforeCapacity)
        let retainedTargets=[retainedRequest.verifiedFindings[0].recordID]+Array(researchIDs.filter {$0 != retainedRequest.verifiedFindings[0].recordID}.prefix(5))
        let capacityPlanner=AgentExecutorPlanFixture([call("interpret_request",["goal":"research","sourcePolicy":"public_if_missing","fields":["phone","address","hours","menu"],"selectionIDs":retainedTargets,"permissions":[]]),call("research_businesses",["targetIDs":retainedTargets,"fields":["phone","address","hours","menu"],"sourcePolicy":"public_if_missing"])])
        let capacityContext=try AskSemanticContext.make(retainedRequest,catalog:adapter.librarySnapshot())
        let stoppedLoop=try await AskAgentLoop(planner:capacityPlanner,execute:{call,intent in try await retainedCapacity.execute(call,intent:intent)},prepareIntent:{intent in try await retainedCapacity.prepare(intent)}).answer(retainedRequest,context:capacityContext,cities:retainedCapacity.cities(),findings:[])
        _ = try AskReadTools(request:retainedRequest.collectionReadVersion(),index:adapter.index()).checked(stoppedLoop)
        let finalCapacityCount=await researcher.count();precondition(finalCapacityCount==beforeCapacity)
        // Dependent destinations are bound only to the city actually created by this turn.
        let destinationAdapter=AskSavedCollection(context:context,canMutate:{_,_,_ in true},canRecoverStore:{$0==store.identifier},visibleCities:{Set(try context.fetch(FeastList.fetchRequest()).compactMap(\.id))})
        let destinationEngine=AskCollectionChangeEngine(adapter:destinationAdapter,journalURL:temporaryDirectory.appendingPathComponent("dependent-actions.json"))
        let destinationRequest=AskRequest(mode:.collection,text:"Create Paris and move these places there",fromOCR:false,performanceID:UUID())
        let dependent=AskAgentExecutor(adapter:destinationAdapter,engine:destinationEngine,request:destinationRequest,researcher:researcher,searchMaps:{_ in []})
        let cityPermission:[String:Any]=["entity":"city","operations":["create"],"fields":["name"],"targetIDs":[],"instructionQuote":destinationRequest.text,"changes":[["field":"name","source":"user","value":"Paris","values":NSNull()]]]
        let movePermission:[String:Any]=["entity":"place","operations":["move"],"fields":[],"targetIDs":ids,"instructionQuote":destinationRequest.text,"destinationCityID":"created:Paris","changes":[]]
        var romePermission=cityPermission;romePermission["changes"]=[["field":"name","source":"user","value":"Rome","values":NSNull()]]
        var romeMovePermission=movePermission;romeMovePermission["destinationCityID"]="created:Rome"
        let dependentIntent=try intent("change",[cityPermission,romePermission,romeMovePermission]);try dependent.prepare(dependentIntent)
        var moveProposal=proposal;moveProposal["operation"]="move";moveProposal["changes"]=[];moveProposal["instructionQuote"]=destinationRequest.text
        do {_ = try await dependent.execute(call("propose_changes",moveProposal),intent:dependentIntent);preconditionFailure("uncreated destination accepted")}catch AskChangeError.missing {}
        var createProposal=proposal;createProposal["entity"]="city";createProposal["operation"]="create";createProposal["targetIDs"]=[];createProposal["changes"]=[["field":"name","value":"Paris","values":NSNull(),"findingID":NSNull()]];createProposal["instructionQuote"]=destinationRequest.text
        let createdCity=try await dependent.execute(call("propose_changes",createProposal),intent:dependentIntent)
        precondition(createdCity.output.records.count==1 && createdCity.output.records[0].kind=="city")
        var romeProposal=createProposal;romeProposal["changes"]=[["field":"name","value":"Rome","values":NSNull(),"findingID":NSNull()]]
        let createdRome=try await dependent.execute(call("propose_changes",romeProposal),intent:dependentIntent)
        precondition(createdRome.output.records.count==1 && createdRome.output.records[0].id != createdCity.output.records[0].id)
        let repeatedRome=try await dependent.execute(call("propose_changes",romeProposal),intent:dependentIntent)
        precondition(repeatedRome.output.records[0].id==createdRome.output.records[0].id)
        moveProposal["cityID"]=createdRome.output.records[0].id
        _ = try await dependent.execute(call("propose_changes",moveProposal),intent:dependentIntent)
        context.refreshAllObjects();precondition(places.allSatisfy {$0.feastList?.id?.uuidString==createdRome.output.records[0].id})
        var wrongMove=moveProposal;wrongMove["cityID"]=london.id!.uuidString
        do {_ = try await dependent.execute(call("propose_changes",wrongMove),intent:dependentIntent);preconditionFailure("wrong destination accepted")}catch AskChangeError.permission {}
        let noCreate=try intent("change",[movePermission])
        do {try dependent.prepare(noCreate);preconditionFailure("unbound future destination accepted")}catch AskChangeError.permission {}
        let capacityRecords=Array(try adapter.librarySnapshot().places.prefix(5))
        precondition(capacityRecords.count==5)
        let evidenceCapacity=AskAgentExecutor(adapter:adapter,engine:engine,request:.init(mode:.collection,text:"Research these places",fromOCR:false),researcher:AgentBusinessFixture(),searchMaps:{_ in []})
        var capacityEvidence:[AskRetainedResearch]=[],capacityItems:[[String:String]]=[]
        for (i,r) in capacityRecords.enumerated() {
            let site="https://public-"+String(i)+".example.org/",quote=r.name+" Instagram @publicprofile Website "+site+" Menu "+site+"menu Phone 123456 Address Public Street Hours 9-5"
            capacityEvidence.append(.init(id:UUID(),originatingTurn:UUID(),query:r.name+" public details",result:.init(text:quote,citations:[.init(title:"Public",url:site)])))
            for (field,value) in [("instagram","https://www.instagram.com/publicprofile/"),("website",site),("menu",site+"menu"),("phone","123456"),("address","Public Street"),("hours","9-5")] {capacityItems.append(["recordID":r.id,"field":field,"value":value,"sourceURL":site,"quote":quote])}
        }
        func capacityCall(_ values:[[String:String]])->AskAgentReply.Call {.init(name:"retain_findings",callID:UUID().uuidString,arguments:String(data:try! JSONSerialization.data(withJSONObject:["findings":values]),encoding:.utf8)!)}
        let firstCapacity=try evidenceCapacity.retainPublicFindings(capacityCall(Array(capacityItems.prefix(24))),evidence:capacityEvidence)
        precondition(firstCapacity.response?.verifiedPublicFindings?.count==24 && firstCapacity.orderedIDs.count==4)
        do {_ = try evidenceCapacity.retainPublicFindings(capacityCall([capacityItems[24]]),evidence:capacityEvidence);preconditionFailure("Cumulative public evidence cap bypassed")}catch AskError.inputLimit {}
        let replayCapacity=try evidenceCapacity.retainPublicFindings(capacityCall(Array(capacityItems.prefix(24))),evidence:capacityEvidence)
        precondition(replayCapacity.response?.verifiedPublicFindings?.map(\.id)==firstCapacity.response?.verifiedPublicFindings?.map(\.id))
        print("PASS cumulative retained evidence cap is enforced before mutation and repeated retention reuses identities")
        print("PASS >6 selection mutation, multi-batch research aggregation/replay and create-city→move with frozen destination and no pre-creation/foreign-city authority")
        print("PASS integrated isolated Chicago three research→save→Undo second, no repeated research spend, complete London six and on-device neighborhood selector/update; mocked public provider, real Core Data repository")
    }
}
