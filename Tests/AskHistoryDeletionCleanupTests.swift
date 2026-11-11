import Foundation
import CoreData

private actor DeletionCleanupWire {
    private var gates:[CheckedContinuation<Void,Never>]=[],submits=0
    func count()->Int {submits}
    func release(){let waiting=gates;gates=[];for gate in waiting {gate.resume()}}
    func send(_ request:URLRequest)async throws->(Data,HTTPURLResponse) {
        let object=try JSONSerialization.jsonObject(with:request.httpBody!) as! [String:Any],operation=object["op"] as! String
        let payload=object["request"] as? [String:Any] ?? object
        if operation=="submit" {submits+=1;await withCheckedContinuation {gates.append($0)}}
        let reply:[String:Any]=["version":10,"requestID":payload["requestID"]!,"step":payload["step"]!,"kind":"answer","text":"Completed the still-active chat.","continuation":"offline","model":"gpt-6-astra","call":NSNull(),"nativeEvidence":["version":1,"blocks":[],"sources":[],"actions":[]],"finalCitations":[]]
        let body:[String:Any]=["version":1,"requestID":payload["requestID"]!,"step":payload["step"]!,"state":operation=="cancel" ? "cancelled" : operation=="ack" ? "acknowledged" : "completed","result":["submit","status"].contains(operation) ? reply : NSNull(),"retryAfterMs":100]
        return (try JSONSerialization.data(withJSONObject:body),HTTPURLResponse(url:request.url!,statusCode:200,httpVersion:nil,headerFields:["Content-Type":"application/json"])!)
    }
}
@MainActor enum AskHistoryDeletionCleanupTests {
    static func run(model:NSManagedObjectModel,directory:URL)async throws {
        guard AskRecoveryFeature.enabled else{return}
        do {
            let root=directory.appendingPathComponent("background-history-failure"),fixture=try AskLargeHistoryFixture(model:model,directory:root),wire=DeletionCleanupWire()
            let recovery=AskTurnRecoveryStore(directory:root.appendingPathComponent("recovery"),requirePersistence:true)
            let hosted=AskHostedProvider(configuration:.init(environment:.development,endpoint:URL(string:"https://deletion-fixture.workers.dev/v1/answer")!,scope:.savedMetadata),token:{String(repeating:"x",count:43)},approve:{_,_ in true},send:{try await wire.send($0)},libraryToolsEnabled:{true},permission:{true},libraryPlanVersion:{7},nativeResearchEnabled:{true},recoveryEnabled:{true})
            let provider=AskAgentProvider(remote:hosted,fallback:fixture.provider,adapter:fixture.adapter,engine:fixture.provider.engine,searchMaps:{_ in []},recoveryStore:recovery)
            let store=AskConversationStore(url:root.appendingPathComponent("history.json")),session=AskSession(index:try fixture.adapter.index(),provider:provider)
            session.restoreHistory(from:store);let origin=session.activeChatID
            session.input="Finish this answer after switching chats";session.run()
            for _ in 0..<5000 {if await wire.count()==1 {break};try await Task.sleep(nanoseconds:1_000_000)}
            let ready=await wire.count();precondition(ready==1)
            let turn=session.turns.last!.id;precondition(session.newChat());let selected=session.activeChatID
            let prior=try Data(contentsOf:store.url)
            store.historyFault={if $0=="sync" {throw CocoaError(.fileWriteOutOfSpace)}}
            let selectedDraft="Keep A’s exact newer draft e\u{301} 🧭  ";session.input=selectedDraft
            await wire.release()
            for _ in 0..<5000 {if session.chats.first(where:{$0.id==origin})?.conversation.turns.last?.id==turn {break};try await Task.sleep(nanoseconds:1_000_000)}
            let retained=session.chats.first(where:{$0.id==origin})?.conversation.turns.last
            precondition(session.activeChatID==selected && session.turns.isEmpty && retained?.id==turn && retained?.response.summary=="Completed the still-active chat.","Background accepted answer stays in its origin RAM chat")
            precondition(Array(session.input.utf8)==Array(selectedDraft.utf8) && session.chats.first(where:{$0.id==selected}).map {Array($0.conversation.draft.utf8)==Array(selectedDraft.utf8)}==true,"Background archive preserves the selected chat's unflushed UTF-8 draft")
            precondition(session.unsavedHistoryChatIDs.contains(origin),"A background answer's actual origin chat must receive the Not saved History/VoiceOver status")
            let unchanged=try Data(contentsOf:store.url)
            precondition(unchanged==prior,"Failed background archive must leave prior durable bytes exact")
            print("PASS background accepted answer marks its actual origin chat as not saved without moving the selected screen")
            store.historyFault=nil;session.flushHistory()
            let durable=try store.durableLibrary()
            precondition(session.unsavedHistoryChatIDs.isEmpty && durable.chats.first(where:{$0.id==origin})?.conversation.turns.last?.id==turn)
            let encoder=JSONEncoder();encoder.outputFormatting = .sortedKeys
            let durableAnswer=try encoder.encode(durable.chats.first(where:{$0.id==origin})?.conversation.turns.last),retainedAnswer=try encoder.encode(retained)
            precondition(durableAnswer==retainedAnswer && durable.chats.first(where:{$0.id==selected}).map {Array($0.conversation.draft.utf8)==Array(selectedDraft.utf8)}==true,"Whole-library success preserves exact background result and selected draft")
            print("PASS successful whole-library save clears background unsaved status only after exact answer durability")
        }
        let root=directory.appendingPathComponent("unarchived-delete"),fixture=try AskLargeHistoryFixture(model:model,directory:root),wire=DeletionCleanupWire()
        let recovery=AskTurnRecoveryStore(directory:root.appendingPathComponent("recovery"),requirePersistence:true)
        let hosted=AskHostedProvider(configuration:.init(environment:.development,endpoint:URL(string:"https://deletion-fixture.workers.dev/v1/answer")!,scope:.savedMetadata),token:{String(repeating:"x",count:43)},approve:{_,_ in true},send:{try await wire.send($0)},libraryToolsEnabled:{true},permission:{true},libraryPlanVersion:{7},nativeResearchEnabled:{true},recoveryEnabled:{true})
        let writable=AskSavedCollection(context:fixture.adapter.context,canMutate:{_,_,_ in true},canRecoverStore:{identifier in fixture.adapter.context.persistentStoreCoordinator!.persistentStores.contains {$0.identifier==identifier}},visibleCities:fixture.adapter.visibleCities)
        let engine=AskCollectionChangeEngine(adapter:writable,journalURL:root.appendingPathComponent("actions.json"))
        let provider=AskAgentProvider(remote:hosted,fallback:fixture.provider,adapter:fixture.adapter,engine:engine,searchMaps:{_ in []},recoveryStore:recovery)
        let store=AskConversationStore(url:root.appendingPathComponent("history.json")),session=AskSession(index:try fixture.adapter.index(),provider:provider)
        session.collectionClear={try engine.dismissRecovery(in:$0)};session.restoreHistory(from:store)
        let chatB=session.activeChatID;session.input="Hold accepted recovery in B";session.run()
        for _ in 0..<5000 {if await wire.count()==1 {break};try await Task.sleep(nanoseconds:1_000_000)}
        let firstReady=await wire.count();precondition(firstReady==1);let turnB=session.turns.last!.id
        let place=try fixture.adapter.personalPlaces()[0],receiptTurn=UUID(),question="Set note for deletion fixture"
        let proposal=AskChangeProposal(entity:"place",operation:"update",targetIDs:[place.id],cityID:nil,sectionID:nil,mapMatchID:nil,changes:[.init(field:"note",value:"Preserved collection receipt",values:nil,findingID:nil)],instructionQuote:question)
        let grant=AskChangeGrant(question:question,entity:"place",operations:["update"],fields:["note"],targetIDs:[place.id],allowsCreation:false,boundProposal:proposal)
        let receipt=try engine.prepare(proposal,question:question,authorization:grant,findings:[],turnID:receiptTurn,chatID:chatB);_ = try engine.apply(receipt.id,authorization:grant)
        precondition(session.newChat());let chatA=session.activeChatID;session.input="Hold accepted recovery in A";session.run()
        for _ in 0..<5000 {if await wire.count()==2 {break};try await Task.sleep(nanoseconds:1_000_000)}
        let secondReady=await wire.count();precondition(secondReady==2);let turnA=session.turns.last!.id
        let attempts=AskProviderAttempts.shared
        func retain(_ turn:UUID)async throws->AskProviderAttemptLease {
            let entry=await attempts.entries[turn]!,lease=AskProviderAttemptLease(turn:turn,attempt:entry.attempt)
            try await attempts.register(UUID(),lease:lease)
            var response=AskResponse(summary:"Retained read context",candidates:[])
            response.mapChoices=[.init(id:UUID().uuidString,applePlaceID:"offline",name:"Private fixture context",address:"1 Example Street",city:"Example",query:"Example",website:nil,originatingTurn:turn)]
            try await attempts.keepReadContext(response,lease:lease);return lease
        }
        let leaseB=try await retain(turnB),leaseA=try await retain(turnA),beforeB=await attempts.entries[turnB]!,beforeA=await attempts.entries[turnA]!
        let pathB=recovery.directory!.appendingPathComponent(turnB.uuidString+".json"),pathA=recovery.directory!.appendingPathComponent(turnA.uuidString+".json"),checkpointB=try Data(contentsOf:pathB),checkpointA=try Data(contentsOf:pathA)
        var failures:[String]=[]
        func check(_ result:Bool,_ label:String){print("\(result ? "PASS" : "FAIL") deletion cleanup: "+label);if !result {failures.append(label)}}
        check(session.chats.first(where:{$0.id==chatB})?.conversation.turns.isEmpty==true,"running B turn is genuinely absent from archived IDs")
        store.historyFault={if $0=="sync" {throw CocoaError(.fileWriteOutOfSpace)}}
        check(!session.deleteChat(chatB),"failed explicit Delete keeps B and all unresolved work")
        let held=try await attempts.readContext(for:leaseB)
        check(try held?.mapChoices==beforeB.checkpoint?.mapChoices && Data(contentsOf:pathB)==checkpointB,"failed Delete does not clean or fence B retry/recovery context")
        store.historyFault=nil;check(session.deleteChat(chatB),"durable Delete removes only B membership")
        check(try session.activeChatID==chatA && session.isLoading && session.turns.last?.id==turnA && Data(contentsOf:pathA)==checkpointA,"active A screen/task/checkpoint remains exact")
        check(!FileManager.default.fileExists(atPath:pathB.path),"explicit B recovery checkpoint cleanup completed")
        for _ in 0..<1000 {if await attempts.entries[turnB]?.checkpoint==nil {break};try await Task.sleep(nanoseconds:1_000_000)}
        let afterB=await attempts.entries[turnB]!,afterA=try await attempts.readContext(for:leaseA)
        check(afterB.checkpoint==nil && afterB.frozen,"unarchived B retry payload is cleaned and frozen")
        var fenced=false;do {_ = try await attempts.readContext(for:leaseB)}catch AskRetryError.active {fenced=true}
        check(fenced,"unarchived B retry identity is explicitly fenced, not merely hidden")
        check(afterB.roots==beforeB.roots && afterB.attempt==beforeB.attempt,"B accounting root/attempt evidence is preserved")
        check(afterA?.mapChoices==beforeA.checkpoint?.mapChoices,"unrelated A retained retry context is not cleaned")
        check(try engine.actionStatus(receipt.id).state == .applied && engine.receipts(forTurn:receiptTurn).contains(where:{$0.id==receipt.id}),"saved collection receipt and Undo evidence remain available")
        await wire.release();for _ in 0..<5000 {if !session.isLoading {break};try await Task.sleep(nanoseconds:1_000_000)}
        check(session.activeChatID==chatA && session.turns.last?.id==turnA && session.turns.last?.status == .complete && !session.chats.contains(where:{$0.id==chatB}),"late B callback cannot restore B and active A still completes")
        let calls=await wire.count();check(calls==2,"no external replay was attempted or needed for this cleanup proof")
        precondition(failures.isEmpty,"Explicit deletion cleanup: "+failures.joined(separator:"; "))
    }
}
