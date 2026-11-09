import Foundation
import CoreData
private func assertRecovery(_ value:Bool,_ message:String=""){precondition(value,message)}

private actor RecoveryHTTPFixture {
    var submits=0,statuses=0,acks=0,cancels=0,direct=0
    var accepted:[String:AskConversationStep]=[:]
    var released=true
    var loseSubmit=false
    var uncertain=false
    var allow=true
    var holdAck=false
    var ackWaiters:[CheckedContinuation<Void,Never>]=[]
    func holdAcknowledgements(){holdAck=true}
    func releaseAcknowledgements(){holdAck=false;for waiter in ackWaiters {waiter.resume()};ackWaiters=[]}
    var beforeAck:(@Sendable ()async throws->Void)?
    func hold(){released=false}
    func release(){released=true}
    func loseNextSubmit(){loseSubmit=true}
    func markUncertain(){uncertain=true}
    func revoke(){allow=false}
    func allowed()->Bool {allow}
    func counts()->[Int] {[submits,statuses,acks,cancels,direct]}
    func checkAck(_ body:@escaping @Sendable ()async throws->Void){beforeAck=body}
    func send(_ request:URLRequest)async throws->(Data,HTTPURLResponse) {
        let object=try JSONSerialization.jsonObject(with:request.httpBody!) as! [String:Any]
        let op=object["op"] as? String ?? "direct"
        let step:AskConversationStep
        if op=="submit" || op=="direct" {
            let payload=op=="submit" ? object["request"] as! [String:Any] : object
            step=try JSONDecoder().decode(AskConversationStep.self,from:JSONSerialization.data(withJSONObject:payload))
            accepted[step.requestID+":"+String(step.step)]=step
            if op=="submit" {submits+=1}else{direct+=1}
            if loseSubmit {loseSubmit=false;throw URLError(.networkConnectionLost)}
        }else {
            let key=(object["requestID"] as! String)+":"+String(object["step"] as! Int)
            guard let value=accepted[key] else {return (Data("{}".utf8),HTTPURLResponse(url:request.url!,statusCode:404,httpVersion:nil,headerFields:["Content-Type":"application/json"])!)}
            step=value
            if op=="status" {statuses+=1}
            if op=="ack" {try await beforeAck?();acks+=1;if holdAck {await withCheckedContinuation {ackWaiters.append($0)}}}
            if op=="cancel" {cancels+=1}
        }
        let reply=AskConversationReply(version:10,requestID:step.requestID,step:step.step,kind:"answer",text:"A retained answer.",continuation:"opaque-exact-continuation",model:"gpt-6-astra",call:nil,nativeEvidence:.init(version:1,blocks:[],sources:[],actions:[]),finalCitations:[])
        let result=try JSONSerialization.jsonObject(with:JSONEncoder().encode(reply))
        let state=op=="cancel" ? "cancelled" : op=="ack" ? "acknowledged" : uncertain ? "uncertain" : released ? "completed" : "running"
        let payload:[String:Any]=op=="direct" ? result as! [String:Any] : ["version":1,"requestID":step.requestID,"step":step.step,"state":state,"retryAfterMs":100,"result":state=="completed" ? result : NSNull()]
        return (try JSONSerialization.data(withJSONObject:payload),HTTPURLResponse(url:request.url!,statusCode:200,httpVersion:nil,headerFields:["Content-Type":"application/json"])!)
    }
}
private actor RecoveryCapabilityFixture {
    var ready=false,refreshes=0
    var succeeds=true
    func refresh(){refreshes+=1;if succeeds {ready=true}}
    func available()->Bool {ready}
    func version()->Int {ready ? 7 : 1}
    func fail(){succeeds=false}
    func count()->Int {refreshes}
}
private actor RecoveryLoopFixture:AskConversationPlanning {
    var steps:[AskConversationStep]=[]
    var failAt:Int?
    init(failAt:Int?=nil){self.failAt=failAt}
    func payloads()->[AskConversationStep] {steps}
    func conversationAvailable()async->Bool {true}
    func nativeResearchAvailable()async->Bool {true}
    func conversationStep(_ step:AskConversationStep)async throws->AskConversationReply {
        if failAt==step.step {throw URLError(.networkConnectionLost)}
        steps.append(step)
        return .init(version:10,requestID:step.requestID,step:step.step,kind:step.step==0 ? "tool" : "answer",text:step.step==0 ? "" : "The saved result is unchanged.",continuation:"opaque-\(step.step)",model:"gpt-6-astra",call:step.step==0 ? .init(name:"query_collection",callID:"stable-call",arguments:"{}") : nil,nativeEvidence:.init(version:1,blocks:[],sources:[],actions:[]),finalCitations:[])
    }
    func searchConversationWeb(_ query:String)async throws->AskWebResearchResult {preconditionFailure("Extra research call")}
    func authorizePendingConfirmation(_ actions:[AskCollectionAction],question:String,history:[String])async throws->AskHumanAuthorization {preconditionFailure("Extra authorization call")}
    func authorizeConversationChange(_ proposal:AskChangeProposal,question:String,history:[String],targets:[AskAgentRecord])async throws->AskHumanAuthorization {preconditionFailure("Extra authorization call")}
}
private actor RecoveryToolCounter {
    var count=0
    func execute(_ call:AskAgentReply.Call)->AskAgentExecution {
        count+=1
        return .init(output:.init(status:"success",complete:true,totalCount:0,records:[],findings:[],message:"exact-result",localOnly:false),response:.init(summary:"A saved result.",candidates:[],listedCandidateIDs:[],usesLocalCatalog:true),orderedIDs:[])
    }
    func calls()->Int {count}
}
@MainActor enum AskTurnRecoveryTests {
    static let endpoint=URL(string:"https://recovery-fixture.workers.dev/v1/answer")!
    private static func hosted(_ fixture:RecoveryHTTPFixture)->AskHostedProvider {
        .init(configuration:.init(environment:.development,endpoint:endpoint,scope:.savedMetadata),token:{String(repeating:"x",count:43)},approve:{_,_ in true},send:{try await fixture.send($0)},libraryToolsEnabled:{true},permission:{await fixture.allowed()},libraryPlanVersion:{7},nativeResearchEnabled:{true},recoveryEnabled:{true})
    }
    static func checkpoint(turn:UUID=UUID(),chat:UUID=UUID())->AskTurnCheckpoint {
        let request=AskRequest(mode:.collection,text:"Keep this exact request",fromOCR:false,performanceID:turn,conversationID:chat)
        var value=AskTurnCheckpoint(turnID:turn,chatID:chat,attemptID:turn,endpoint:endpoint.absoluteString,request:request,createdAt:Date())
        value.context = .init(index:[],recent:[])
        return value
    }
    static func step(_ value:AskTurnCheckpoint)->AskConversationStep {
        var step=AskConversationStep(requestID:value.attemptID.uuidString,step:0,text:value.request.text,context:value.context!,cities:[],task:nil,findings:[],history:[],continuation:nil,result:nil)
        step.version=10;step.webAllowed=true;step.turnID=value.turnID.uuidString;return step
    }
    static func waitUntil(_ body:@escaping @MainActor ()->Bool)async throws {
        for _ in 0..<500 {if body(){return};try await Task.sleep(nanoseconds:10_000_000)}
        preconditionFailure("Recovery fixture did not settle")
    }
    static func run(model:NSManagedObjectModel,directory:URL)async throws {
#if !FEAST_DURABLE_RECOVERY
        assertRecovery(!AskRecoveryFeature.enabled)
#endif
        let folder=directory.appendingPathComponent("recovery-checkpoints")
        let store=AskTurnRecoveryStore(directory:folder),value=checkpoint()
        try store.save(value)
        let fixture=RecoveryHTTPFixture(),provider=hosted(fixture),request=step(value)
        await fixture.loseNextSubmit()
        do {_ = try await provider.recoveredConversationStep(request,handle:.init(store:store,turn:value.turnID));preconditionFailure()}catch is URLError {}
        assertRecovery(try store.checkpoint(value.turnID)?.phase == .awaitingReply)
        let restored=AskTurnRecoveryStore(directory:folder)
        await fixture.checkAck {
            let reread=await AskTurnRecoveryStore(directory:folder)
            let saved=try await reread.checkpoint(value.turnID)
            assertRecovery(saved?.phase == .receivedReply && saved?.reply?.continuation=="opaque-exact-continuation")
        }
        let answer=try await provider.recoveredConversationStep(request,handle:.init(store:restored,turn:value.turnID))
        assertRecovery(answer.text=="A retained answer.")
        for _ in 0..<500 {if await fixture.counts()[2]==1 {break};try await Task.sleep(nanoseconds:1_000_000)}
        let counts=await fixture.counts();assertRecovery(counts==[1,1,1,0,0],"Uncertain submit must reconcile, not pay again")
        _ = try await provider.recoveredConversationStep(request,handle:.init(store:restored,turn:value.turnID))
        let afterCached=await fixture.counts();assertRecovery(afterCached==counts)
        var changed=request;changed.webAllowed=false
        do {_ = try await provider.recoveredConversationStep(changed,handle:.init(store:restored,turn:value.turnID));preconditionFailure()}catch AskRecoveryError.unavailable {}
        let noCredential=try String(contentsOf:folder.appendingPathComponent(value.turnID.uuidString+".json"),encoding:.utf8)
        assertRecovery(!noCredential.contains(String(repeating:"x",count:43)))
        try restored.stop(value.turnID)
        do {try restored.save(value);preconditionFailure()}catch AskRecoveryError.stopped {}
        try restored.deleteChat(value.chatID)
        assertRecovery(try restored.checkpoint(value.turnID)==nil)
        do {try restored.save(value);preconditionFailure()}catch AskRecoveryError.stopped {}
        let beforeRegistration=checkpoint(),preflight=AskTurnRecoveryStore()
        try preflight.stop(beforeRegistration.turnID)
        do {try preflight.save(beforeRegistration);preconditionFailure("Stop before registration was revived")}catch AskRecoveryError.stopped {}
        var stale=checkpoint();stale.executor=Data("temporary Maps coordinates".utf8);stale.state.continuation="private continuation"
        let expiry=AskTurnRecoveryStore(directory:directory.appendingPathComponent("recovery-expiry"));try expiry.save(stale)
        expiry.now={stale.createdAt.addingTimeInterval(AskTurnRecoveryStore.lifetime+1)}
        let expired=try expiry.checkpoint(stale.turnID)
        assertRecovery(expired?.phase == .blocked && expired?.executor==nil && expired?.context==nil && expired?.state.continuation==nil)
        let cleanupValue=checkpoint(),cleanupStore=AskTurnRecoveryStore();try cleanupStore.save(cleanupValue)
        let cleanupFixture=RecoveryHTTPFixture();await cleanupFixture.hold()
        var cleanupProvider=hosted(cleanupFixture)
        cleanupProvider.recoveryCleanupToken={String(repeating:"c",count:43)}
        let cleanupStep=step(cleanupValue)
        _ = try await cleanupProvider.recoveryJob("submit",step:cleanupStep)
        await cleanupFixture.revoke()
        cleanupProvider=AskHostedProvider(configuration:cleanupProvider.configuration,token:{throw AskHostedError.consentRequired},approve:{_,_ in false},send:{try await cleanupFixture.send($0)},libraryToolsEnabled:{false},permission:{false},recoveryCleanupToken:{String(repeating:"c",count:43)})
        _ = try await cleanupProvider.recoveryJob("cancel",step:cleanupStep)
        do {_ = try await cleanupProvider.recoveryJob("status",step:cleanupStep);preconditionFailure("Revoked research consent permitted status")}catch AskHostedError.consentRequired {}
        let cleanupCounts=await cleanupFixture.counts();assertRecovery(cleanupCounts[0]==1 && cleanupCounts[3]==1)
        print("PASS recovery expiry scrubs temporary state, preflight Stop fence, and consent-revoked identity-only cancellation")
        print("PASS recovery accepted-submit disconnect, status reconciliation, durable reply-before-ack, exact payload and Stop/delete fences")

        // Safe local-tool boundary restart: no repeated query, same next model input.
        let loopValue=checkpoint(),loopStore=AskTurnRecoveryStore(directory:directory.appendingPathComponent("recovery-loop"))
        try loopStore.save(loopValue)
        let uninterrupted=RecoveryLoopFixture(),interrupted=RecoveryLoopFixture(failAt:1),counter=RecoveryToolCounter()
        let normal=try await AskConversationLoop(planner:uninterrupted,availableCandidates:[:],execute:{await counter.execute($0)}).answer(loopValue.request,context:loopValue.context!,cities:[],findings:[])
        do {
            _ = try await AskRecoveryScope.$handle.withValue(.init(store:loopStore,turn:loopValue.turnID)) {
                try await AskConversationLoop(planner:interrupted,availableCandidates:[:],execute:{await counter.execute($0)},recoverySnapshot:{Data("exact-executor-state".utf8)}).answer(loopValue.request,context:loopValue.context!,cities:[],findings:[])
            }
            preconditionFailure()
        }catch is URLError {}
        let kept=try loopStore.checkpoint(loopValue.turnID)!
        assertRecovery(kept.phase == .ready && kept.state.nextStep==1 && kept.state.result?.output.message=="exact-result" && kept.executor==Data("exact-executor-state".utf8))
        let restarted=AskTurnRecoveryStore(directory:directory.appendingPathComponent("recovery-loop")),continuing=RecoveryLoopFixture()
        let recovered=try await AskRecoveryScope.$handle.withValue(.init(store:restarted,turn:loopValue.turnID)) {
            try await AskConversationLoop(planner:continuing,availableCandidates:[:],execute:{_ in preconditionFailure("Completed local tool replayed")}).answer(loopValue.request,context:loopValue.context!,cities:[],findings:[])
        }
        assertRecovery(recovered==normal)
        let originals=await uninterrupted.payloads(),resumed=await continuing.payloads(),encoder=JSONEncoder();encoder.outputFormatting=[.sortedKeys]
        let normalPayload=try encoder.encode(originals[1]),resumedPayload=try encoder.encode(resumed[0])
        assertRecovery(originals.count==2 && resumed.count==1 && normalPayload==resumedPayload)
        let executed=await counter.calls();assertRecovery(executed==2)
        var unknown=kept;unknown.phase = .executingTool;try restarted.save(unknown)
        do {
            _ = try await AskRecoveryScope.$handle.withValue(.init(store:restarted,turn:loopValue.turnID)) {
                try await AskConversationLoop(planner:continuing,availableCandidates:[:],execute:{_ in preconditionFailure("Unknown local step replayed")}).answer(loopValue.request,context:loopValue.context!,cities:[],findings:[])
            };preconditionFailure()
        }catch AskRecoveryError.localStepUncertain {}
        print("PASS recovery foreground parity, exact continuation/result, no repeated local query or added model pass; unknown local step fails closed")
        let ackValue=checkpoint(),ackStore=AskTurnRecoveryStore(),heldAck=RecoveryHTTPFixture();try ackStore.save(ackValue)
        await heldAck.holdAcknowledgements();let ackProvider=hosted(heldAck)
        var returnedBeforeAck=false
        let ackWork=Task {let answer=try await ackProvider.recoveredConversationStep(step(ackValue),handle:.init(store:ackStore,turn:ackValue.turnID));returnedBeforeAck=true;return answer}
        try await waitUntil {returnedBeforeAck}
        let durableReply=try ackStore.checkpoint(ackValue.turnID)?.reply
        assertRecovery(durableReply != nil)
        await heldAck.releaseAcknowledgements();_ = try await ackWork.value
        print("PASS delayed acknowledgement never delays the answer; response is durable before asynchronous cleanup")


        let coordinator=NSPersistentStoreCoordinator(managedObjectModel:model)
        _ = try coordinator.addPersistentStore(ofType:NSInMemoryStoreType,configurationName:nil,at:nil)
        let context=NSManagedObjectContext(concurrencyType:.mainQueueConcurrencyType);context.persistentStoreCoordinator=coordinator
        let adapter=AskSavedCollection(context:context,visibleCities:{[]})
        let engine=AskCollectionChangeEngine(adapter:adapter,journalURL:directory.appendingPathComponent("recovery-empty-actions.json"))
        let cold=RecoveryCapabilityFixture(),coldHTTP=RecoveryHTTPFixture(),coldStore=AskTurnRecoveryStore()
        var coldHosted=hosted(coldHTTP);coldHosted.libraryToolsEnabled={await cold.available()};coldHosted.libraryPlanVersion={await cold.version()};coldHosted.prepareCapabilities={await cold.refresh()}
        let coldAgent=AskAgentProvider(remote:coldHosted,fallback:coldHosted,adapter:adapter,engine:engine,searchMaps:{_ in []},recoveryStore:coldStore)
        let coldSaved=checkpoint();try coldStore.save(coldSaved)
        _ = try await coldAgent.answer(coldSaved.request,tools:AskReadTools(request:coldSaved.request,index:adapter.index()))
        let coldRefreshes=await cold.count(),coldCalls=await coldHTTP.counts();assertRecovery(coldRefreshes==1 && coldCalls[0]==1 && coldCalls[4]==0)
        let unavailable=RecoveryCapabilityFixture();await unavailable.fail()
        var notReady=hosted(coldHTTP);notReady.libraryToolsEnabled={await unavailable.available()};notReady.libraryPlanVersion={await unavailable.version()};notReady.prepareCapabilities={await unavailable.refresh()}
        let unavailableAgent=AskAgentProvider(remote:notReady,fallback:notReady,adapter:adapter,engine:engine,searchMaps:{_ in []},recoveryStore:coldStore)
        let paused=checkpoint();try coldStore.save(paused)
        do {_ = try await unavailableAgent.answer(paused.request,tools:AskReadTools(request:paused.request,index:adapter.index()));preconditionFailure()}catch AskRecoveryError.paused {}
        let pausedState=try coldStore.checkpoint(paused.turnID),afterHealthFailure=await coldHTTP.counts()
        assertRecovery(pausedState?.resumable==true && afterHealthFailure==coldCalls)
        print("PASS cold-launch capability preparation and transient health failure preserve the accepted turn without fallback")
        let sessionFixture=RecoveryHTTPFixture(),sessionHosted=hosted(sessionFixture),sessionStore=AskTurnRecoveryStore(directory:directory.appendingPathComponent("recovery-session"))
        let agent=AskAgentProvider(remote:sessionHosted,fallback:sessionHosted,adapter:adapter,engine:engine,searchMaps:{_ in []},recoveryStore:sessionStore)
        let session=AskSession(index:try adapter.index(),provider:agent)
        session.restoreHistory(from:.init(url:directory.appendingPathComponent("recovery-chats.json")))
        await sessionFixture.hold()
        let chat=session.activeChatID
        session.input="A simple public question";session.run()
        let turn=session.turns.last!.id
        try await waitUntil {(try? sessionStore.checkpoint(turn)?.phase) == .awaitingReply}
        assertRecovery(session.newChat());let second=session.activeChatID;session.input="Unsent draft in another chat";session.flushHistory()
        session.setAppActive(false);await sessionFixture.release()
        try await Task.sleep(nanoseconds:150_000_000)
        assertRecovery(session.activeChatID==second && session.input=="Unsent draft in another chat")
        session.setAppActive(true)
        try await waitUntil {session.chats.first(where:{$0.id==chat})?.conversation.turns.contains(where:{$0.id==turn})==true}
        assertRecovery(session.activeChatID==second && session.input=="Unsent draft in another chat")
        assertRecovery(session.openChat(chat));assertRecovery(session.turns.count==1 && session.turns[0].id==turn && session.turns[0].status == .complete && session.input.isEmpty)
        let sessionCounts=await sessionFixture.counts();assertRecovery(sessionCounts[0]==1 && sessionCounts[4]==0)
        await sessionFixture.hold();session.input="Second question";session.run();let stopped=session.turns.last!.id
        try await waitUntil {(try? sessionStore.checkpoint(stopped)?.phase) == .awaitingReply}
        session.cancel();await sessionFixture.release();try await Task.sleep(nanoseconds:150_000_000)
        let stoppedCheckpoint=try sessionStore.checkpoint(stopped)
        assertRecovery(session.turns.last?.status == .stopped && !session.isLoading && stoppedCheckpoint?.phase == .stopped)
        assertRecovery(stoppedCheckpoint?.executor==nil && stoppedCheckpoint?.pendingRequest==nil && stoppedCheckpoint?.context==nil)
        session.setAppActive(true);try await Task.sleep(nanoseconds:120_000_000)
        let stopCounts=await sessionFixture.counts();assertRecovery(stopCounts[0]==2)
        assertRecovery(session.deleteChat(chat));assertRecovery(try sessionStore.checkpoint(stopped)==nil)
        print("PASS recovery navigation, scene wait/return, original-chat completion, preserved drafts, explicit Stop and deletion")

        // Representative local persistence cost, isolated synthetic metadata only.
        var large=checkpoint()
        large.context = .init(index:(0..<284).map {_ in .init(id:UUID().uuidString,name:"Synthetic restaurant",city:"Synthetic city",cuisines:["Italian"])},recent:[])
        large.state.continuation=String(repeating:"opaque ",count:10000)
        let began=DispatchTime.now().uptimeNanoseconds
        for _ in 0..<10 {try store.save(large)}
        let elapsed=Double(DispatchTime.now().uptimeNanoseconds-began)/1_000_000
        print(String(format:"INFO recovery atomic/fsync checkpoint (284 synthetic records, 70 KB continuation): %.2f ms mean over 10 writes",elapsed/10))
    }
}
