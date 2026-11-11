import Foundation
import CoreData

private actor RetainedHistoryRecoveryWire {
    let offset:Int
    var accepted:[String:AskConversationStep]=[:]
    var submits=0,foundTail=false,loseFirst=true
    init(offset:Int) {self.offset=offset}
    func state()->(Int,Bool) {(submits,foundTail)}
    func send(_ request:URLRequest)throws->(Data,HTTPURLResponse) {
        let body=try JSONSerialization.jsonObject(with:request.httpBody!) as! [String:Any]
        let op=body["op"] as! String
        let step:AskConversationStep
        if op=="submit" {
            step=try JSONDecoder().decode(AskConversationStep.self,from:JSONSerialization.data(withJSONObject:body["request"]!))
            precondition(step.retainedHistoryVersion==1)
            accepted[step.requestID+":"+String(step.step)]=step;submits+=1
            if loseFirst {loseFirst=false;throw URLError(.networkConnectionLost)}
        }else {step=accepted[(body["requestID"] as! String)+":"+String(body["step"] as! Int)]!}
        let call:AskAgentReply.Call?=step.step==0 ? .init(name:"read_conversation",callID:"retained-tail",arguments:"{\"offset\":1,\"limit\":1,\"textOffset\":\(offset)}") : nil
        if step.step==1 {foundTail=step.result?.output.history?.contains {$0.text.contains("CAPACITY_HISTORY_TAIL")}==true}
        let reply=AskConversationReply(version:10,requestID:step.requestID,step:step.step,kind:call==nil ? "answer" : "tool",text:call==nil ? "I recovered the retained tail." : "",continuation:"offline-history-continuation",model:"gpt-6.1-sol",call:call,nativeEvidence:.init(version:1,blocks:[],sources:[],actions:[]),finalCitations:[])
        let result=try JSONSerialization.jsonObject(with:JSONEncoder().encode(reply))
        let data=try JSONSerialization.data(withJSONObject:["version":1,"requestID":step.requestID,"step":step.step,"state":op=="ack" ? "acknowledged" : "completed","retryAfterMs":100,"result":op=="ack" ? NSNull() : result])
        return (data,HTTPURLResponse(url:request.url!,statusCode:200,httpVersion:nil,headerFields:["Content-Type":"application/json"])!)
    }
}
@MainActor enum AskRetainedHistoryRecoveryTests {
    static func run(model:NSManagedObjectModel,directory:URL)async throws {
        let folder=directory.appendingPathComponent("retained-recovery-capacity")
        let fixture=try AskLargeHistoryFixture(model:model,directory:folder)
        let fetch=NSFetchRequest<SavedPlace>(entityName:"SavedPlace")
        for place in try fixture.adapter.context.fetch(fetch) {place.note=String(repeating:"n",count:3450)+" CAPACITY_HISTORY_TAIL"}
        try fixture.adapter.context.save()
        let original=try fixture.session();try await fixture.answer(original)
        let library=try fixture.nearLimitLibrary(turn:original.turns[0])
        let bytes=try JSONEncoder().encode(library);precondition(bytes.count>7*1024*1024 && bytes.count<=8*1024*1024)
        let history=AskConversationStore(url:folder.appendingPathComponent("history.json"));precondition(history.saveLibrary(library))
        let retained=AskConversationProjection.retainedMessages(library.chats[0].conversation.turns.map(\.turn))
        let offset=retained[1].message.text.utf16.count-1500
        let wire=RetainedHistoryRecoveryWire(offset:offset)
        let checkpoints=AskTurnRecoveryStore(directory:folder.appendingPathComponent("checkpoints"),requirePersistence:true)
        var hosted=AskHostedProvider(configuration:.init(environment:.development,endpoint:URL(string:"https://history-recovery-fixture.workers.dev/v1/answer")!,scope:.savedMetadata),token:{String(repeating:"R",count:43)},approve:{_,_ in true},send:{try await wire.send($0)},libraryToolsEnabled:{true},permission:{true},libraryPlanVersion:{7},nativeResearchEnabled:{true},retainedHistoryEnabled:{true},recoveryEnabled:{true},recoveryRetainedHistoryEnabled:{true})
        let provider=AskAgentProvider(remote:hosted,fallback:hosted,adapter:fixture.adapter,engine:fixture.provider.engine,searchMaps:{_ in []},recoveryStore:checkpoints)
        let session=AskSession(index:try fixture.adapter.index(),provider:provider);session.restoreHistory(from:history);session.refreshIndex={try fixture.adapter.index()}
        session.input="Retrieve the end of the first retained answer";session.run();while session.isLoading {await Task.yield()}
        let turn=session.turns.last!.id
        guard let pending=try checkpoints.checkpoint(turn) else{preconditionFailure("Near-limit history follow-up never reached a durable checkpoint")}
        precondition(pending.phase == .awaitingReply && pending.retainedHistoryVersion==1)
        precondition(pending.request.collectionHistory != nil && pending.userRequest?.collectionHistory==nil && pending.executorRequest?.collectionHistory==nil,"Full history must not be stored three times in a checkpoint")
        let checkpointBytes=try JSONEncoder().encode(pending);precondition(checkpointBytes.count<=16*1024*1024)
        session.setAppActive(false)
        hosted.recoveryRetainedHistoryEnabled={false} // New capability availability cannot rewrite an accepted request.
        let restored=AskTurnRecoveryStore(directory:folder.appendingPathComponent("checkpoints"),requirePersistence:true)
        let continuing=AskAgentProvider(remote:hosted,fallback:hosted,adapter:fixture.adapter,engine:fixture.provider.engine,searchMaps:{_ in []},recoveryStore:restored)
        let reopened=AskSession(index:try fixture.adapter.index(),provider:continuing);reopened.refreshIndex={try fixture.adapter.index()};reopened.restoreHistory(from:history)
        reopened.restorePendingRecovery()
        for _ in 0..<100_000 {if !reopened.isLoading && reopened.turns.last?.status == .complete {break};try await Task.sleep(nanoseconds:1_000_000)}
        let state=await wire.state();precondition(reopened.turns.last?.status == .complete && state.0==2 && state.1,"Recovery must retrieve retained tail with pinned capability, without replaying accepted submit")
        print("PASS >7MiB legitimate archived history starts recovery with one full provenance copy; restart pins paging capability and retrieves the tail without paid-submit replay")
    }
}
