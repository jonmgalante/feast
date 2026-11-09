import Foundation
import CoreData

private struct RecoveryConfirmationPlanner:AskConversationPlanning {
    func conversationAvailable()async->Bool {true}
    func nativeResearchAvailable()async->Bool {true}
    func conversationStep(_ step:AskConversationStep)async throws->AskConversationReply {throw AskError.invalidEvidence}
    func searchConversationWeb(_ query:String)async throws->AskWebResearchResult {throw AskError.invalidEvidence}
    func authorizePendingConfirmation(_ actions:[AskCollectionAction],question:String,history:[String])async throws->AskHumanAuthorization {
        precondition(question=="Yes, delete it" && actions.count==1 && actions[0].state == .needsConfirmation)
        return .init(approved:true,replaceExisting:false,deleteContents:true,reason:"accepted_pending")
    }
    func authorizeConversationChange(_ proposal:AskChangeProposal,question:String,history:[String],targets:[AskAgentRecord])async throws->AskHumanAuthorization {throw AskError.invalidEvidence}
}
private actor RecoveryMutationHTTP {
    var calls=0
    var held=false
    var waiters:[CheckedContinuation<Void,Never>]=[]
    func hold(){held=true}
    func release(){held=false;for waiter in waiters {waiter.resume()};waiters=[]}
    func count()->Int {calls}
    func send(_ request:URLRequest)async throws->(Data,HTTPURLResponse) {
        calls+=1
        let p=try JSONSerialization.jsonObject(with:request.httpBody!) as! [String:Any]
        precondition(request.url!.lastPathComponent=="answer-jobs","Unexpected model/authorization call")
        let submitted=p["request"] as? [String:Any]
        let id=submitted?["requestID"] as? String ?? p["requestID"] as! String
        let step=submitted?["step"] as? Int ?? p["step"] as! Int
        if held {await withCheckedContinuation {waiters.append($0)}}
        let state=(p["op"] as? String)=="cancel" ? "cancelled" : "uncertain"
        let bytes=try JSONSerialization.data(withJSONObject:["version":1,"requestID":id,"step":step,"state":state])
        return (bytes,HTTPURLResponse(url:request.url!,statusCode:200,httpVersion:nil,headerFields:["Content-Type":"application/json"])!)
    }
}
private actor RecoveryTwoTurnHTTP {
    let answerText:String
    init(_ answerText:String="Completed this fixture question."){self.answerText=answerText}
    var accepted=Set<String>(),released=Set<String>(),cancelled=Set<String>()
    var waiting:[String:[CheckedContinuation<Void,Never>]]=[:]
    func contains(_ root:String)->Bool {accepted.contains(root)}
    func release(_ root:String){released.insert(root);for waiter in waiting.removeValue(forKey:root) ?? [] {waiter.resume()}}
    func send(_ request:URLRequest)async throws->(Data,HTTPURLResponse) {
        let p=try JSONSerialization.jsonObject(with:request.httpBody!) as! [String:Any]
        let payload=p["request"] as? [String:Any]
        let root=payload?["requestID"] as? String ?? p["requestID"] as! String
        let step=payload?["step"] as? Int ?? p["step"] as! Int
        let op=p["op"] as! String
        if op=="cancel" {cancelled.insert(root);release(root)}
        if op=="submit" || op=="status" {
            accepted.insert(root)
            if !released.contains(root) {await withCheckedContinuation {waiting[root,default:[]].append($0)}}
        }
        let reply=AskConversationReply(version:10,requestID:root,step:step,kind:"answer",text:answerText,continuation:"opaque-two-turn",model:"gpt-6-astra",call:nil,nativeEvidence:.init(version:1,blocks:[],sources:[],actions:[]),finalCitations:[])
        let state=cancelled.contains(root) ? "cancelled" : op=="ack" ? "acknowledged" : "completed"
        let result=try JSONSerialization.jsonObject(with:JSONEncoder().encode(reply))
        let bytes=try JSONSerialization.data(withJSONObject:["version":1,"requestID":root,"step":step,"state":state,"result":state=="completed" ? result : NSNull()])
        return (bytes,HTTPURLResponse(url:request.url!,statusCode:200,httpVersion:nil,headerFields:["Content-Type":"application/json"])!)
    }
}
private actor RecoveryLateFailureHTTP {
    let failStatus:Bool
    var submits=0,statuses=0
    var accepted:AskConversationStep?
    var held:CheckedContinuation<Void,Never>?
    init(failStatus:Bool){self.failStatus=failStatus}
    func counts()->(Int,Int){(submits,statuses)}
    func release(){held?.resume();held=nil}
    func send(_ request:URLRequest)async throws->(Data,HTTPURLResponse) {
        let p=try JSONSerialization.jsonObject(with:request.httpBody!) as! [String:Any],op=p["op"] as! String
        if op=="submit" {
            submits+=1
            accepted=try JSONDecoder().decode(AskConversationStep.self,from:JSONSerialization.data(withJSONObject:p["request"]!))
            await withCheckedContinuation {held=$0}
            throw URLError(.networkConnectionLost)
        }
        guard let step=accepted else{throw AskError.invalidEvidence}
        if op=="status" {statuses+=1;if failStatus {throw URLError(.notConnectedToInternet)}}
        let reply=AskConversationReply(version:10,requestID:step.requestID,step:step.step,kind:"answer",text:"Reconciled the existing accepted job.",continuation:"opaque-late-error",model:"gpt-6-astra",call:nil,nativeEvidence:.init(version:1,blocks:[],sources:[],actions:[]),finalCitations:[])
        let state=op=="ack" ? "acknowledged" : "completed"
        let result=try JSONSerialization.jsonObject(with:JSONEncoder().encode(reply))
        let bytes=try JSONSerialization.data(withJSONObject:["version":1,"requestID":step.requestID,"step":step.step,"state":state,"result":state=="completed" ? result : NSNull()])
        return (bytes,HTTPURLResponse(url:request.url!,statusCode:200,httpVersion:nil,headerFields:["Content-Type":"application/json"])!)
    }
}
@MainActor enum AskRecoveryMutationTests {
    static func waitUntil(_ condition:@escaping @MainActor ()->Bool)async throws {
        for _ in 0..<500 {if condition(){return};try await Task.sleep(nanoseconds:10_000_000)}
        preconditionFailure("Recovery mutation fixture did not settle")
    }
    static func run(model:NSManagedObjectModel,directory:URL)async throws {
        let coordinator=NSPersistentStoreCoordinator(managedObjectModel:model)
        let store=try coordinator.addPersistentStore(ofType:NSSQLiteStoreType,configurationName:nil,at:directory.appendingPathComponent("recovery-mutations.sqlite"))
        let context=NSManagedObjectContext(concurrencyType:.mainQueueConcurrencyType);context.persistentStoreCoordinator=coordinator
        let repo=FeastRepository(context:context),city=try repo.createFeastList(named:"Recovery fixture city")
        let original=try repo.createSavedPlace(from:.init(applePlaceID:"recovery-mutation-fixture",displayNameSnapshot:"Recovery fixture place",status:.love,placeType:.restaurant,cuisines:[],tags:[],note:"Original fixture note",websiteURL:nil,instagramURL:nil,feastList:city,listSection:nil))
        let id=original.id!.uuidString,cityID=city.id!
        var visible=true
        let adapter=AskSavedCollection(context:context,canMutate:{_,_,_ in true},canRecoverStore:{$0==store.identifier},visibleCities:{visible ? [cityID] : []})
        let engine=AskCollectionChangeEngine(adapter:adapter,journalURL:directory.appendingPathComponent("recovery-mutation-actions.json"))
        let endpoint=URL(string:"https://recovery-mutation-fixture.workers.dev/v1/answer")!
        let http=RecoveryMutationHTTP()
        let hosted=AskHostedProvider(configuration:.init(environment:.development,endpoint:endpoint,scope:.savedMetadata),token:{String(repeating:"x",count:43)},approve:{_,_ in true},send:{try await http.send($0)},libraryToolsEnabled:{true},permission:{true},libraryPlanVersion:{7},nativeResearchEnabled:{true},recoveryEnabled:{true})
        func grant(_ p:AskChangeProposal)->AskChangeGrant {.init(question:p.instructionQuote,entity:p.entity,operations:[p.operation],fields:Set(p.changes.map(\.field)),targetIDs:Set(p.targetIDs),allowsCreation:false,boundProposal:p)}
        func savedPlace()throws->SavedPlace {
            let request=SavedPlace.fetchRequest();request.predicate=NSPredicate(format:"id == %@",UUID(uuidString:id)! as NSUUID)
            return try context.fetch(request).first!
        }
        func checkpoint(_ request:AskRequest)->AskTurnCheckpoint {
            var c=AskTurnCheckpoint(turnID:request.performanceID!,chatID:request.conversationID!,attemptID:UUID(),endpoint:endpoint.absoluteString,request:request,createdAt:Date())
            c.context = .init(index:[.init(id:id,name:"Recovery fixture place",city:"Recovery fixture city",cuisines:[])],recent:[])
            c.loopInitialized=true;c.state.nextStep=1;c.state.continuation="fixture-native-continuation"
            return c
        }
        // A separate preview turn owns the journal. Confirmation must retain
        // its actual removal receipt without treating the deleted ID as revoked.
        let previewTurn=UUID(),confirmationTurn=UUID(),confirmationChat=UUID()
        let proposal=AskChangeProposal(entity:"place",operation:"delete",targetIDs:[id],cityID:nil,sectionID:nil,mapMatchID:nil,changes:[],instructionQuote:"Delete this fixture place")
        let preview=try engine.prepare(proposal,question:proposal.instructionQuote,authorization:grant(proposal),findings:[],turnID:previewTurn,chatID:confirmationChat)
        precondition(preview.state == .needsConfirmation)
        let confirmation=AskRequest(mode:.collection,text:"Yes, delete it",fromOCR:false,performanceID:confirmationTurn,conversationID:confirmationChat,pendingActions:[preview])
        let executor=AskAgentExecutor(adapter:adapter,engine:engine,request:confirmation,researcher:hosted,searchMaps:{_ in []})
        let args=String(data:try JSONSerialization.data(withJSONObject:["actionIDs":[preview.id.uuidString]]),encoding:.utf8)!
        let effect=try await executor.executeConversation(.init(name:"confirm_changes",callID:"confirmed-delete",arguments:args),planner:RecoveryConfirmationPlanner())
        let deletedAction=effect.response!.collectionActions![0]
        precondition(deletedAction.state == .applied && deletedAction.originatingTurn==previewTurn)
        let proof=try engine.recoveryDeletedRecordIDs(forTurn:confirmationTurn,includingActionIDs:[deletedAction.id]);precondition(proof==[id])
        let completionDirectory=directory.appendingPathComponent("recovery-completed-delete"),completion=AskTurnRecoveryStore(directory:completionDirectory)
        var pending=checkpoint(confirmation);pending.state.durableActions=[deletedAction];pending.state.latest=effect.response
        try completion.save(pending);try completion.complete(confirmationTurn,response:effect.response!)
        let rebuilt=AskTurnRecoveryStore(directory:completionDirectory)
        let restoredAgent=AskAgentProvider(remote:hosted,fallback:hosted,adapter:adapter,engine:engine,searchMaps:{_ in []},recoveryStore:rebuilt)
        let result=try await restoredAgent.answer(confirmation,tools:AskReadTools(request:confirmation,index:adapter.index()))
        precondition(result.collectionActions?.first?.id==deletedAction.id && result.collectionActions?.first?.state == .applied)
        let completedCalls=await http.count();precondition(completedCalls==0)
        _ = try engine.performExplicitAction(deletedAction.id,undo:true)
        precondition(try! savedPlace().note=="Original fixture note")
        print("PASS two-turn delete preview/confirmation and completed-before-archive restart retain receipt and make no provider call")

        // A later online step fails while another chat is visible. The prior
        // save must remain visible, undoable, and archived to its original chat.
        let recovery=AskTurnRecoveryStore(directory:directory.appendingPathComponent("recovery-failed-save"))
        let agent=AskAgentProvider(remote:hosted,fallback:hosted,adapter:adapter,engine:engine,searchMaps:{_ in []},recoveryStore:recovery)
        let session=AskSession(index:try adapter.index(),provider:agent)
        func wire(_ s:AskSession) {
            s.refreshIndex={try adapter.index()};s.collectionStatus={try engine.actionStatus($0)}
            s.collectionReceipts={try engine.receipts(forTurn:$0)};s.collectionExecutor={try engine.performExplicitAction($0,undo:$1)}
            s.collectionRecovery={try engine.recoverableTurns(in:$0)}
        }
        wire(session)
        let historyURL=directory.appendingPathComponent("recovery-mutation-history.json")
        session.restoreHistory(from:.init(url:historyURL))
        let origin=session.activeChatID,turn=UUID()
        let request=AskRequest(mode:.collection,text:"Update the fixture note and continue",fromOCR:false,performanceID:turn,conversationID:origin)
        let update=AskChangeProposal(entity:"place",operation:"update",targetIDs:[id],cityID:nil,sectionID:nil,mapMatchID:nil,changes:[.init(field:"note",value:"Saved before interruption",values:nil,findingID:nil)],instructionQuote:request.text)
        let ready=try engine.prepare(update,question:request.text,authorization:grant(update),findings:[],turnID:turn,chatID:origin)
        let applied=try engine.apply(ready.id,authorization:grant(update))
        var interrupted=checkpoint(request)
        interrupted.state.durableActions=[applied]
        interrupted.state.latest = .init(summary:"Saved.",candidates:[],listedCandidateIDs:[],usesLocalCatalog:true,collectionActions:[applied])
        try recovery.save(interrupted)
        await http.hold();session.restorePendingRecovery()
        for _ in 0..<500 {if await http.count()>0 {break};try await Task.sleep(nanoseconds:10_000_000)}
        let activeCalls=await http.count();precondition(activeCalls>0)
        precondition(session.newChat());let other=session.activeChatID;session.input="Preserved other-chat draft";session.flushHistory()
        await http.release()
        try await waitUntil {session.chats.first(where:{$0.id==origin})?.conversation.turns.contains(where:{$0.id==turn && $0.failure != nil})==true}
        precondition(session.activeChatID==other && session.input=="Preserved other-chat draft")
        let archived=session.chats.first(where:{$0.id==origin})!.conversation.turns.first(where:{$0.id==turn})!
        precondition(archived.response.collectionActions?.first?.id==applied.id && archived.response.collectionActions?.first?.undoable==true)
        precondition(session.openChat(origin));session.applyCollectionAction(turn:turn,actionID:applied.id,undo:true)
        precondition(try! savedPlace().note=="Original fixture note")
        session.flushHistory()
        let reopened=AskSession(index:try adapter.index(),provider:agent);wire(reopened);reopened.restoreHistory(from:.init(url:historyURL))
        precondition(reopened.turns.first(where:{$0.id==turn})?.response?.collectionActions?.first?.state == .undone)
        print("PASS saved edit followed by uncertain online step keeps original-chat failure, receipt, Undo and unrelated draft across reopening")

        // A retained private answer is not re-exposed through the error path
        // when its shared city is no longer permitted on return.
        let lostStore=AskTurnRecoveryStore(directory:directory.appendingPathComponent("recovery-lost-sharing"))
        let lostAgent=AskAgentProvider(remote:hosted,fallback:hosted,adapter:adapter,engine:engine,searchMaps:{_ in []},recoveryStore:lostStore)
        let lost=AskSession(index:try adapter.index(),provider:lostAgent);wire(lost)
        lost.restoreHistory(from:.init(url:directory.appendingPathComponent("recovery-lost-sharing-history.json")))
        let lostTurn=UUID(),lostRequest=AskRequest(mode:.collection,text:"Continue that answer",fromOCR:false,performanceID:lostTurn,conversationID:lost.activeChatID)
        var privateCheckpoint=checkpoint(lostRequest)
        let privateTools=try AskReadTools(request:lostRequest,index:adapter.index())
        privateCheckpoint.state.latest = .init(summary:"PRIVATE_RETAINED_FIXTURE_NOTE",candidates:[privateTools.localCandidate(id)!],listedCandidateIDs:[id],usesLocalCatalog:true)
        privateCheckpoint.state.ordered=[id]
        try lostStore.save(privateCheckpoint)
        let beforeLossCalls=await http.count();visible=false;lost.restorePendingRecovery()
        try await waitUntil {lost.turns.first(where:{$0.id==lostTurn}).map {if case .failed = $0.status{return true};return false}==true}
        let hidden=lost.turns.first(where:{$0.id==lostTurn})!
        precondition(hidden.response==nil || (hidden.response!.candidates.isEmpty && !hidden.response!.summary.contains("PRIVATE_RETAINED")))
        let afterLossCalls=await http.count();precondition(afterLossCalls==beforeLossCalls)
        visible=true
        print("PASS sharing loss stops recovery before transport and does not reveal retained private data in its failure response")

        // Two previously accepted resumable questions in one chat must not let
        // the first completion hide loading or disable Stop for the second.
        let twoHTTP=RecoveryTwoTurnHTTP(),twoStore=AskTurnRecoveryStore(directory:directory.appendingPathComponent("recovery-two-turns"))
        let twoHosted=AskHostedProvider(configuration:hosted.configuration,token:{String(repeating:"x",count:43)},approve:{_,_ in true},send:{try await twoHTTP.send($0)},libraryToolsEnabled:{true},permission:{true},libraryPlanVersion:{7},nativeResearchEnabled:{true},recoveryEnabled:{true})
        let twoAgent=AskAgentProvider(remote:twoHosted,fallback:twoHosted,adapter:adapter,engine:engine,searchMaps:{_ in []},recoveryStore:twoStore)
        let two=AskSession(index:try adapter.index(),provider:twoAgent);wire(two)
        two.restoreHistory(from:.init(url:directory.appendingPathComponent("recovery-two-turn-history.json")))
        let turnA=UUID(),turnB=UUID(),sameChat=two.activeChatID
        let requestA=AskRequest(mode:.collection,text:"First resumable question",fromOCR:false,performanceID:turnA,conversationID:sameChat)
        let requestB=AskRequest(mode:.collection,text:"Second resumable question",fromOCR:false,performanceID:turnB,conversationID:sameChat)
        let savedA=checkpoint(requestA),savedB=checkpoint(requestB)
        try twoStore.save(savedA);try twoStore.save(savedB);two.restorePendingRecovery()
        for _ in 0..<500 {if await twoHTTP.contains(savedA.attemptID.uuidString){break};try await Task.sleep(nanoseconds:10_000_000)}
        let beganA=await twoHTTP.contains(savedA.attemptID.uuidString);precondition(beganA)
        await twoHTTP.release(savedA.attemptID.uuidString)
        for _ in 0..<500 {
            let beganB=await twoHTTP.contains(savedB.attemptID.uuidString)
            if beganB && two.turns.first(where:{$0.id==turnA})?.status == .complete {break}
            try await Task.sleep(nanoseconds:10_000_000)
        }
        let beganB=await twoHTTP.contains(savedB.attemptID.uuidString)
        precondition(beganB && two.turns.first(where:{$0.id==turnA})?.status == .complete && two.isLoading)
        two.cancel();await twoHTTP.release(savedB.attemptID.uuidString)
        try await Task.sleep(nanoseconds:150_000_000)
        let fencedB=try twoStore.checkpoint(turnB)
        precondition(fencedB?.phase == .stopped && two.turns.first(where:{$0.id==turnB})?.status == .stopped && !two.isLoading)
        two.setAppActive(true);try await Task.sleep(nanoseconds:100_000_000)
        precondition(two.turns.first(where:{$0.id==turnB})?.status == .stopped)
        print("PASS first same-chat recovered completion keeps the second question loading and stoppable; Stop fences its late reply")
        let turnC=UUID(),turnD=UUID()
        let requestC=AskRequest(mode:.collection,text:"Third held question",fromOCR:false,performanceID:turnC,conversationID:sameChat)
        let requestD=AskRequest(mode:.collection,text:"Fourth held question",fromOCR:false,performanceID:turnD,conversationID:sameChat)
        let savedC=checkpoint(requestC),savedD=checkpoint(requestD)
        try twoStore.save(savedC);try twoStore.save(savedD);two.restorePendingRecovery()
        for _ in 0..<500 {
            let c=await twoHTTP.contains(savedC.attemptID.uuidString),d=await twoHTTP.contains(savedD.attemptID.uuidString)
            if c && d {break};try await Task.sleep(nanoseconds:10_000_000)
        }
        let heldC=await twoHTTP.contains(savedC.attemptID.uuidString),heldD=await twoHTTP.contains(savedD.attemptID.uuidString)
        precondition(heldC && heldD && two.isLoading)
        two.cancel()
        let firstC=try twoStore.checkpoint(turnC),firstD=try twoStore.checkpoint(turnD)
        precondition((firstC?.phase == .stopped) != (firstD?.phase == .stopped))
        precondition(two.isLoading,"Stopping one question hid the other still-running question")
        two.cancel();await twoHTTP.release(savedC.attemptID.uuidString);await twoHTTP.release(savedD.attemptID.uuidString)
        try await Task.sleep(nanoseconds:150_000_000)
        let finalC=try twoStore.checkpoint(turnC),finalD=try twoStore.checkpoint(turnD)
        precondition(finalC?.phase == .stopped && finalD?.phase == .stopped && !two.isLoading)
        print("PASS Stop while two same-chat replies are held retains controls for the other turn and independently fences both")

        for failStatus in [false,true] {
            let label=failStatus ? "failed-status" : "successful-status"
            let lateHTTP=RecoveryLateFailureHTTP(failStatus:failStatus),lateStore=AskTurnRecoveryStore(directory:directory.appendingPathComponent("recovery-late-"+label))
            let lateHosted=AskHostedProvider(configuration:hosted.configuration,token:{String(repeating:"x",count:43)},approve:{_,_ in true},send:{try await lateHTTP.send($0)},libraryToolsEnabled:{true},permission:{true},libraryPlanVersion:{7},nativeResearchEnabled:{true},recoveryEnabled:{true})
            let lateAgent=AskAgentProvider(remote:lateHosted,fallback:lateHosted,adapter:adapter,engine:engine,searchMaps:{_ in []},recoveryStore:lateStore)
            let late=AskSession(index:try adapter.index(),provider:lateAgent);wire(late)
            late.restoreHistory(from:.init(url:directory.appendingPathComponent("recovery-late-history-"+label+".json")))
            let lateID=UUID(),lateRequest=AskRequest(mode:.collection,text:"Recover the accepted step",fromOCR:false,performanceID:lateID,conversationID:late.activeChatID)
            let lateCheckpoint=checkpoint(lateRequest);try lateStore.save(lateCheckpoint);late.restorePendingRecovery()
            for _ in 0..<500 {if await lateHTTP.counts().0==1 {break};try await Task.sleep(nanoseconds:10_000_000)}
            let accepted=await lateHTTP.counts();precondition(accepted.0==1)
            late.setAppActive(false);late.setAppActive(true)
            await lateHTTP.release()
            for _ in 0..<500 {
                let calls=await lateHTTP.counts()
                if calls.1==1 && !late.isLoading {break};try await Task.sleep(nanoseconds:10_000_000)
            }
            let recoveredCalls=await lateHTTP.counts();precondition(recoveredCalls.0==1 && recoveredCalls.1==1)
            let recoveredTurn=late.turns.first(where:{$0.id==lateID})!
            if failStatus {if case .failed = recoveredTurn.status {}else{preconditionFailure("Failed reconciliation did not stop retrying")}}
            else {precondition(recoveredTurn.status == .complete)}
            try await Task.sleep(nanoseconds:200_000_000)
            let stableCalls=await lateHTTP.counts();precondition(stableCalls.0==1 && stableCalls.1==1)
        }
        print("PASS return-before-transport-failure reconciles accepted job once with status, no resubmit, and no retry spin when status also fails")

        let privacyHTTP=RecoveryTwoTurnHTTP("PRIVATE_READY_WHILE_INACTIVE"),privacyStore=AskTurnRecoveryStore(directory:directory.appendingPathComponent("recovery-private-ready"))
        let privacyHosted=AskHostedProvider(configuration:hosted.configuration,token:{String(repeating:"x",count:43)},approve:{_,_ in true},send:{try await privacyHTTP.send($0)},libraryToolsEnabled:{true},permission:{true},libraryPlanVersion:{7},nativeResearchEnabled:{true},recoveryEnabled:{true})
        let privacyAgent=AskAgentProvider(remote:privacyHosted,fallback:privacyHosted,adapter:adapter,engine:engine,searchMaps:{_ in []},recoveryStore:privacyStore)
        let privacySession=AskSession(index:try adapter.index(),provider:privacyAgent);wire(privacySession)
        privacySession.restoreHistory(from:.init(url:directory.appendingPathComponent("recovery-private-ready-history.json")))
        let privacyID=UUID(),privacyRequest=AskRequest(mode:.collection,text:"Read the fixture private details",fromOCR:false,performanceID:privacyID,conversationID:privacySession.activeChatID)
        let privacyCheckpoint=checkpoint(privacyRequest);try privacyStore.save(privacyCheckpoint);privacySession.restorePendingRecovery()
        for _ in 0..<500 {if await privacyHTTP.contains(privacyCheckpoint.attemptID.uuidString){break};try await Task.sleep(nanoseconds:10_000_000)}
        let beganPrivate=await privacyHTTP.contains(privacyCheckpoint.attemptID.uuidString);precondition(beganPrivate)
        privacySession.setAppActive(false);await privacyHTTP.release(privacyCheckpoint.attemptID.uuidString)
        try await waitUntil {(try? privacyStore.checkpoint(privacyID)?.phase) == .completed}
        visible=false;privacySession.setAppActive(true)
        try await waitUntil {!privacySession.isLoading}
        let privateTurn=privacySession.turns.first(where:{$0.id==privacyID})!
        precondition(privateTurn.response==nil || (!privateTurn.response!.summary.contains("PRIVATE_READY") && !privateTurn.response!.paragraphs.flatMap(\.spans).contains(where:{if case .text(let text)=$0{return text.contains("PRIVATE_READY")};return false})))
        visible=true
        print("PASS completed private reply waits for active and rechecks sharing before display or archival")
    }
}
