import Foundation
import CoreData

private actor NavigationHeldRecoveryWire {
    var started=false,submits=0
    var gate:CheckedContinuation<Void,Never>?
    func ready()->Bool {started}
    func count()->Int {submits}
    func release(){gate?.resume();gate=nil}
    func send(_ request:URLRequest)async throws->(Data,HTTPURLResponse) {
        let body=try JSONSerialization.jsonObject(with:request.httpBody!) as! [String:Any]
        let op=body["op"] as? String ?? "direct",payload=body["request"] as? [String:Any] ?? body
        if op=="submit" {submits+=1;started=true;await withCheckedContinuation {gate=$0}}
        let requestID=payload["requestID"] as! String,step=payload["step"] as! Int
        let reply:[String:Any] = ["version":10,"requestID":requestID,"step":step,"kind":"answer","text":"The originally accepted answer.","continuation":"offline","model":"gpt-6-astra","call":NSNull(),"nativeEvidence":["version":1,"blocks":[],"sources":[],"actions":[]],"finalCitations":[]]
        let result:[String:Any] = op=="direct" ? reply : ["version":1,"requestID":requestID,"step":step,"state":op=="ack" ? "acknowledged" : op=="cancel" ? "cancelled" : "completed","result":["submit","status"].contains(op) ? reply : NSNull(),"retryAfterMs":100]
        return (try JSONSerialization.data(withJSONObject:result),HTTPURLResponse(url:request.url!,statusCode:200,httpVersion:nil,headerFields:["Content-Type":"application/json"])!)
    }
}
@MainActor enum AskHistoryDestructiveTests {
    static func run(model:NSManagedObjectModel,directory:URL)async throws {
        let root=directory.appendingPathComponent("navigation-destructive"),fixture=try AskLargeHistoryFixture(model:model,directory:root)
        let writable=AskSavedCollection(context:fixture.adapter.context,canMutate:{_,_,_ in true},canRecoverStore:{identifier in fixture.adapter.context.persistentStoreCoordinator!.persistentStores.contains {$0.identifier==identifier}},visibleCities:fixture.adapter.visibleCities)
        let engine=AskCollectionChangeEngine(adapter:writable,journalURL:root.appendingPathComponent("writable-actions.json"))
        func check(_ value:Bool,_ name:String) {precondition(value,name);print("PASS history destruction: "+name)}
        func action(chat:UUID,question:String)throws->(UUID,UUID) {
            let place=try fixture.adapter.personalPlaces()[0],turn=UUID()
            let proposal=AskChangeProposal(entity:"place",operation:"update",targetIDs:[place.id],cityID:nil,sectionID:nil,mapMatchID:nil,changes:[.init(field:"note",value:"Changed by fixture "+UUID().uuidString,values:nil,findingID:nil)],instructionQuote:question)
            let grant=AskChangeGrant(question:question,entity:"place",operations:["update"],fields:["note"],targetIDs:[place.id],allowsCreation:false,boundProposal:proposal)
            let prepared=try engine.prepare(proposal,question:question,authorization:grant,findings:[],turnID:turn,chatID:chat)
            _ = try engine.apply(prepared.id,authorization:grant);return (turn,prepared.id)
        }
        for synthesized in [false,true] {
            let store=AskConversationStore(url:root.appendingPathComponent("draft-\(synthesized).json"));var library=AskChatLibrary.empty()
            let question="Set this note é 🧭",receipt=try action(chat:library.activeID,question:question)
            library.chats[0].conversation.draft=question
            library.chats[0].conversation.fallbackDraftTurnID=synthesized ? receipt.0 : nil
            check(store.saveLibrary(library),"seed draft provenance fixture")
            let session=try fixture.session();session.collectionRecovery={try engine.recoverableTurns(in:$0)};session.restoreHistory(from:store)
            check(synthesized ? session.input.isEmpty : Array(session.input.utf8)==Array(question.utf8),synthesized ? "only original synthesized fallback clears" : "genuinely retyped equal question is byte-exact, not erased by receipt recovery")
        }
        for point in ["clear-committed","before-recovery-cleanup","before-journal-cleanup","before-retry-cleanup"] {
            let store=AskConversationStore(url:root.appendingPathComponent(point+".json")),session=try fixture.session(store:store),old=session.activeChatID
            let receipt=try action(chat:old,question:"Set note before Clear")
            session.collectionRecovery={try engine.recoverableTurns(in:$0)};session.collectionClear={try engine.dismissRecovery(in:$0)}
            session.input="Keep title";session.flushHistory();check(session.renameChat(old,to:"Same visible title"),"seed visible title before clear")
            session.historyDestructiveInterruption={$0==point};session.clearConversation()
            let restarted=try fixture.session();restarted.collectionRecovery={try engine.recoverableTurns(in:$0)};restarted.restoreHistory(from:AskConversationStore(url:store.url))
            check(restarted.activeChatID != old && restarted.turns.isEmpty && restarted.input.isEmpty && restarted.chats[0].title=="Same visible title" && restarted.chats[0].hasCustomTitle==true,"clear barrier survives interruption at "+point)
            check(try engine.actionStatus(receipt.1).state == .applied,"clear never deletes action receipt/Undo evidence")
        }
        do {
            let legacy=root.appendingPathComponent("legacy.json"),store=AskConversationStore(url:root.appendingPathComponent("migrated.json"),legacyURL:legacy)
            check(AskConversationStore(url:legacy).save(.init(draft:"Legacy text")),"seed verified migration copy")
            let session=try fixture.session(store:store),old=session.activeChatID;session.clearConversation()
            check(try session.activeChatID != old && !FileManager.default.fileExists(atPath:legacy.path) && store.loadLibrary().migration==nil,"explicit Clear removes only verified old-ID legacy copy and does not bind it to new chat")
        }
        for changed in [false,true] {
            let legacy=root.appendingPathComponent("legacy-interrupted-\(changed).json"),store=AskConversationStore(url:root.appendingPathComponent("migrated-interrupted-\(changed).json"),legacyURL:legacy)
            check(AskConversationStore(url:legacy).save(.init(draft:"Exact original legacy")),"seed interrupted legacy cleanup")
            let session=try fixture.session(store:store),old=session.activeChatID
            session.historyDestructiveInterruption={$0=="clear-committed"};session.clearConversation()
            if changed {check(AskConversationStore(url:legacy).save(.init(draft:"Different unowned legacy bytes")),"replace legacy backup after interrupted Clear")}
            let restarted=try fixture.session(store:AskConversationStore(url:store.url,legacyURL:legacy))
            check(restarted.activeChatID != old && restarted.turns.isEmpty,"migration pointer never rebinds cleared old ID")
            check(changed ? FileManager.default.fileExists(atPath:legacy.path) && restarted.historyWarning?.contains("backup was kept")==true : !FileManager.default.fileExists(atPath:legacy.path),"restart only finishes exact explicitly removed migration copy")
            if changed {restarted.input="Newer legitimate draft";restarted.flushHistory();check(restarted.historyWarning?.contains("backup was kept")==true,"changed migration-backup warning survives later successful saves")}
        }
        guard AskRecoveryFeature.enabled else{return}
        for point in ["clear-committed","before-recovery-cleanup","before-journal-cleanup","before-retry-cleanup"] {
            let wire=NavigationHeldRecoveryWire(),recovery=AskTurnRecoveryStore(directory:root.appendingPathComponent("recovery-"+point),requirePersistence:true)
            let hosted=AskHostedProvider(configuration:.init(environment:.development,endpoint:URL(string:"https://navigation-fixture.workers.dev/v1/answer")!,scope:.savedMetadata),token:{String(repeating:"x",count:43)},approve:{_,_ in true},send:{try await wire.send($0)},libraryToolsEnabled:{true},permission:{true},libraryPlanVersion:{7},nativeResearchEnabled:{true},recoveryEnabled:{true})
            try hosted.configuration.validate()
            let provider=AskAgentProvider(remote:hosted,fallback:fixture.provider,adapter:fixture.adapter,engine:engine,searchMaps:{_ in []},recoveryStore:recovery)
            let store=AskConversationStore(url:root.appendingPathComponent("accepted-"+point+".json")),session=AskSession(index:try fixture.adapter.index(),provider:provider)
            session.restoreHistory(from:store);session.input="Keep this accepted recovery exact";session.run()
            for _ in 0..<5000 {if await wire.ready() {break};try await Task.sleep(nanoseconds:1_000_000)}
            let ready=await wire.ready();if !ready {print("DIAGNOSTIC hosted mock did not enter: \(session.error ?? "no error"), \(String(describing:session.turns.last?.status))")};check(ready,"actual hosted-mock recovery accepted before "+point)
            let old=session.activeChatID,turn=session.turns.last!.id,path=recovery.directory!.appendingPathComponent(turn.uuidString+".json"),before=try Data(contentsOf:path)
            store.historyFault={if $0=="sync" {throw CocoaError(.fileWriteOutOfSpace)}}
            session.clearConversation();check(try session.activeChatID==old && session.isLoading && Data(contentsOf:path)==before,"failed Clear preserves exact accepted checkpoint and running task")
            check(try !session.deleteChat(old) && session.activeChatID==old && Data(contentsOf:path)==before,"failed Delete preserves exact checkpoint and original chat")
            store.historyFault=nil;session.historyDestructiveInterruption={$0==point};session.clearConversation()
            let newID=session.activeChatID;check(newID != old,"successful Clear commits new identity before cleanup")
            let reloadedRecovery=AskTurnRecoveryStore(directory:recovery.directory,requirePersistence:true)
            let reloadedProvider=AskAgentProvider(remote:hosted,fallback:fixture.provider,adapter:fixture.adapter,engine:engine,searchMaps:{_ in []},recoveryStore:reloadedRecovery)
            let restarted=AskSession(index:try fixture.adapter.index(),provider:reloadedProvider);restarted.restoreHistory(from:AskConversationStore(url:store.url))
            check(restarted.activeChatID==newID && restarted.turns.isEmpty && !restarted.isLoading,"restart cannot resume or append cleared checkpoint")
            await wire.release();for _ in 0..<100 {await Task.yield()}
            let count=await wire.count();check(count==1 && restarted.turns.isEmpty,"late old reply cannot resurrect or dispatch a second accepted request")
        }
        for phase in ["activate-after-rename","canonical-after-rename","retire-after-rename","marker-after-remove","final-before-sync"] {
            let wire=NavigationHeldRecoveryWire(),recovery=AskTurnRecoveryStore(directory:root.appendingPathComponent("uncertain-recovery-"+phase),requirePersistence:true)
            let hosted=AskHostedProvider(configuration:.init(environment:.development,endpoint:URL(string:"https://navigation-fixture.workers.dev/v1/answer")!,scope:.savedMetadata),token:{String(repeating:"x",count:43)},approve:{_,_ in true},send:{try await wire.send($0)},libraryToolsEnabled:{true},permission:{true},libraryPlanVersion:{7},nativeResearchEnabled:{true},recoveryEnabled:{true})
            try hosted.configuration.validate()
            let provider=AskAgentProvider(remote:hosted,fallback:fixture.provider,adapter:fixture.adapter,engine:engine,searchMaps:{_ in []},recoveryStore:recovery)
            let store=AskConversationStore(url:root.appendingPathComponent("uncertain-"+phase+".json")),session=AskSession(index:try fixture.adapter.index(),provider:provider)
            session.restoreHistory(from:store);session.input="Accepted request before uncertain Clear";session.run()
            for _ in 0..<5000 {if await wire.ready(){break};try await Task.sleep(nanoseconds:1_000_000)}
            let ready=await wire.ready();if !ready {print("DIAGNOSTIC hosted mock did not enter: \(session.error ?? "no error"), \(String(describing:session.turns.last?.status))")};check(ready,"actual accepted recovery before uncertain "+phase)
            let old=session.activeChatID,turn=session.turns.last!.id,path=recovery.directory!.appendingPathComponent(turn.uuidString+".json"),before=try Data(contentsOf:path)
            var armed=false;store.historyFault={point in if point==phase {armed=true};if armed && point=="sync" {throw CocoaError(.fileWriteOutOfSpace)}}
            session.clearConversation()
            check(try armed && session.activeChatID==old && session.isLoading && Data(contentsOf:path)==before,"unverified Clear never scrubs accepted checkpoint at "+phase)
            let draft="Newer recovery draft e\u{301} 🧭 after uncertain removal";session.input=draft
            await wire.release();for _ in 0..<5000 {if !session.isLoading{break};try await Task.sleep(nanoseconds:1_000_000)}
            check(session.turns.last?.id==turn && session.turns.last?.status == .complete,"late accepted response remains in old live chat at "+phase)
            session.flushHistory();check(FileManager.default.fileExists(atPath:path.path),"unverified save retains completed recovery proof at "+phase)
            store.historyFault=nil
            check(session.newChat() && session.openChat(old),"same live recovery Session resolves owned operation at "+phase)
            let actual=try AskConversationStore(url:store.url).loadLibrary().chats.first {$0.id==old}
            check(actual?.conversation.turns.last?.id==turn && actual.map {Array($0.conversation.draft.utf8)==Array(draft.utf8)}==true,"newest accepted result and genuine draft durable after "+phase)
            let count=await wire.count();check(count==1,"resolution never resubmits accepted provider request")
        }
    }
}
