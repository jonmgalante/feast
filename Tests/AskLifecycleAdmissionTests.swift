import Foundation
import CoreData

private actor LifecycleCountingProvider: AskFeastProvider {
    nonisolated let label = "Offline lifecycle regression"
    private var calls = 0
    func answer(_ request: AskRequest, tools: AskReadTools) async throws -> AskResponse {
        calls += 1
        return .init(summary:"Synthetic answer",candidates:[],listedCandidateIDs:[],usesLocalCatalog:true,agentTask:.init(action:"query",fields:[],orderedIDs:[],sourcePolicy:"stored_only"))
    }
    func count() -> Int { calls }
}
private actor LifecycleHeldWire {
    private var started = false
    private var gate: CheckedContinuation<Void,Never>?
    func isStarted() -> Bool { started }
    func release() { gate?.resume(); gate = nil }
    func send(_ request:URLRequest) async throws -> (Data,HTTPURLResponse) {
        let body = try JSONSerialization.jsonObject(with:request.httpBody!) as! [String:Any]
        precondition(body["mode"] as? String == "conversationStep")
        started = true
        await withCheckedContinuation { gate = $0 }
        let response:[String:Any] = ["version":10,"requestID":body["requestID"]!,"step":body["step"]!,"kind":"answer","text":"Completed original direct answer.","continuation":"synthetic","model":"gpt-6.1-sol","call":NSNull(),"nativeEvidence":["version":1,"blocks":[],"sources":[],"actions":[]],"finalCitations":[]]
        return (try JSONSerialization.data(withJSONObject:response),HTTPURLResponse(url:request.url!,statusCode:200,httpVersion:nil,headerFields:["Content-Type":"application/json"])!)
    }
}
@MainActor enum AskLifecycleAdmissionTests {
    private static func settle(_ session:AskSession) async throws {
        for _ in 0..<10000 { if !session.isLoading { return }; try await Task.sleep(nanoseconds:1_000_000) }
        preconditionFailure("Synthetic lifecycle request did not settle")
    }
    static func run(model:NSManagedObjectModel,directory:URL) async throws {
        let only=ProcessInfo.processInfo.environment["FEAST_LIFECYCLE_CASE"]
        if only == nil || only == "admission" { try await admission(directory:directory) }
        if only == nil || only == "archive" { try archive(directory:directory) }
        if AskRecoveryFeature.enabled && (only == nil || only == "draft") { try await drafts(model:model,directory:directory) }
    }
    private static func admission(directory:URL) async throws {
        let index=AskLocalIndex(records:[],visibleCityIDs:[],visibleNoteIDs:[],scope:.savedMetadata)
        let plain=AskResponse(summary:"Saved answer",candidates:[])
        for terminal in [AskTurnStatus.failed("Old offline error"),.stopped,.complete] {
            let store=AskConversationStore(url:directory.appendingPathComponent("lifecycle-limit-\(UUID()).json"))
            let archived=(0..<100).map {i in AskArchivedTurn(.init(id:UUID(),request:.init(mode:.collection,text:"Question \(i)",fromOCR:false),response:plain,status:i==99 ? terminal : .complete))}
            precondition(store.save(.init(turns:archived)))
            let provider=LifecycleCountingProvider(),session=AskSession(index:index,provider:provider)
            session.restoreHistory(from:store); session.input="Keep this unsent draft"; session.run(); try await settle(session)
            let calls=await provider.count()
            precondition(calls==0 && session.turns.count==100 && session.input=="Keep this unsent draft","Full mixed-status history must reject before dispatch and retain draft")
            precondition(session.error?.contains("This chat is full") == true && session.composerError==session.error)
            session.answerAgain(archived[0].id,using:.collection);try await settle(session)
            let correctionCalls=await provider.count();precondition(correctionCalls==0 && session.turns.count==100,"Answer-again must share admission limit")
            session.flushHistory();precondition(store.load().turns.count==100)
            precondition(session.newChat(),"A valid full chat must not prevent starting a new one")
        }
        let lastSlot=AskConversationStore(url:directory.appendingPathComponent("lifecycle-last-slot.json"))
        let mixed=(0..<99).map {i in AskArchivedTurn(.init(id:UUID(),request:.init(mode:.collection,text:"Earlier \(i)",fromOCR:false),response:plain,status:i%3==0 ? .failed("Old failure") : i%3==1 ? .stopped : .complete))}
        precondition(lastSlot.save(.init(turns:mixed)))
        let lastProvider=LifecycleCountingProvider(),last=AskSession(index:index,provider:lastProvider)
        last.restoreHistory(from:lastSlot);last.input="Use the final available turn";last.run();try await settle(last);last.flushHistory()
        let lastCalls=await lastProvider.count();precondition(lastCalls==1 && last.turns.count==100 && lastSlot.load().turns.count==100)
        let textRequest=AskRequest(mode:.collection,text:"Text",fromOCR:false)
        precondition(!AskTurn(id:UUID(),request:textRequest,status:.loading).isArchiveEligible)
        for status in [AskTurnStatus.complete,.failed("failure"),.stopped] {
            precondition(AskTurn(id:UUID(),request:textRequest,status:status).isArchiveEligible)
            var imageRequest=textRequest;imageRequest.attachment = .init(jpeg:Data([0xff,0xd8,0xff,0xd9]))
            precondition(!AskTurn(id:UUID(),request:imageRequest,status:status).isArchiveEligible)
        }
        let provider=LifecycleCountingProvider(),session=AskSession(index:index,provider:provider)
        for prompt in ["Hello","Find a coffee shop in London","Create a city called Paris","Save Buvette to Paris"] {
            session.input=prompt;session.runAutomatically();try await settle(session)
            precondition(session.turns.last?.status == .complete)
        }
        let calls=await provider.count();precondition(calls==4)
        print("PASS mixed completed/failed/stopped history rejects extra dispatch and correction, keeps draft, permits new chat; empty-library session accepts model-led prompts")
    }
    private static func archive(directory:URL) throws {
        for size in [2400,2399,200,199] {
            let ids=(0...size).map {_ in UUID().uuidString},city=UUID().uuidString
            let index=AskLocalIndex(records:ids.enumerated().map {i,id in .init(id:id,cityID:city,city:"Fixture",name:"Fixture \(i)",neighborhood:"",cuisine:"",status:"",notes:[])},visibleCityIDs:[city],visibleNoteIDs:[],scope:.savedMetadata)
            let request=AskRequest(mode:.collection,text:"List my places",fromOCR:false),tools=try AskReadTools(request:request,index:index)
            let map=AskReadTools.localCandidates(Set(ids),in:index),candidates=ids.map {map[$0]!}
            let response=AskResponse(summary:"Results",candidates:candidates,paragraphs:candidates.enumerated().map {i,c in .init(id:"row-\(i)",spans:[.place(c.id)],sourceIDs:c.sourceIDs)},listedCandidateIDs:[],usesLocalCatalog:true,libraryContext:.init(ids:Array(ids.dropLast()),filters:.init(operation:.list,scope:.library,positions:[],fields:[])),answerMentionIDs:[ids.last!],collectionPage:.init(snapshot:String(repeating:"a",count:64),totalCount:size,offset:0,returnedCount:size,nextOffset:nil))
            let checked=try tools.checked(response),sources=ids.compactMap {tools.source("metadata-"+$0)}
            let turn=AskTurn(id:UUID(),request:request,response:checked,sources:sources,status:.complete)
            let store=AskConversationStore(url:directory.appendingPathComponent("lifecycle-boundary-\(size).json"))
            precondition(store.save(.init(turns:[.init(turn)])),"Accepted native rows plus extra mention must archive")
            let loaded=store.load();precondition(loaded.turns.first?.response==checked && loaded.turns.first?.sources==sources)
            var invalid=response;invalid.answerMentionIDs=nil
            precondition(!store.save(.init(turns:[.init(.init(id:UUID(),request:request,response:invalid,sources:sources,status:.complete))])),"Unmarked extra must not inflate archive limit")
        }
        print("PASS 199/200/2399/2400 native rows plus extra mention archive and reload losslessly; malformed extras remain rejected")
    }
    private static func drafts(model:NSManagedObjectModel,directory:URL) async throws {
        let coordinator=NSPersistentStoreCoordinator(managedObjectModel:model)
        try coordinator.addPersistentStore(ofType:NSSQLiteStoreType,configurationName:nil,at:directory.appendingPathComponent("lifecycle-mixed.sqlite"))
        let context=NSManagedObjectContext(concurrencyType:.mainQueueConcurrencyType);context.persistentStoreCoordinator=coordinator
        let adapter=AskSavedCollection(context:context,visibleCities:{[]})
        let engine=AskCollectionChangeEngine(adapter:adapter,journalURL:directory.appendingPathComponent("lifecycle-actions.json"))
        for scenario in ["away","edited-away","foreground","edited-foreground"] {
            let edit=scenario.hasPrefix("edited"),foreground=scenario.hasSuffix("foreground")
            let wire=LifecycleHeldWire(),recovery=AskTurnRecoveryStore(directory:directory.appendingPathComponent("lifecycle-recovery-\(scenario)"))
            let hosted=AskHostedProvider(configuration:.init(environment:.development,endpoint:URL(string:"https://synthetic.workers.dev/v1/answer")!,scope:.savedMetadata),token:{String(repeating:"A",count:43)},approve:{_,_ in true},send:{try await wire.send($0)},libraryToolsEnabled:{true},permission:{true},libraryPlanVersion:{7},nativeResearchEnabled:{true},recoveryEnabled:{false})
            let provider=AskAgentProvider(remote:hosted,fallback:LifecycleCountingProvider(),adapter:adapter,engine:engine,searchMaps:{_ in []},recoveryStore:recovery)
            let session=AskSession(index:try adapter.index(),provider:provider),store=AskConversationStore(url:directory.appendingPathComponent("lifecycle-mixed-\(scenario).json"))
            session.restoreHistory(from:store);session.input="Original answered question";session.run()
            for _ in 0..<10000 { if await wire.isStarted() {break};try await Task.sleep(nanoseconds:1_000_000) }
            let started=await wire.isStarted();precondition(started)
            let origin=session.activeChatID,turn=session.turns.last!.id
            let checkpoint=try recovery.checkpoint(turn);precondition(checkpoint==nil)
            precondition(session.newChat());let other=session.activeChatID
            session.input="Unrelated new-chat draft";session.flushHistory()
            if edit || foreground {
                precondition(session.openChat(origin))
                if edit {session.input="Newer genuine user draft";session.flushHistory()}
                if !foreground {precondition(session.openChat(other))}
            }
            await wire.release()
            for _ in 0..<10000 {if session.chats.first(where:{$0.id==origin})?.conversation.turns.count==1 {break};try await Task.sleep(nanoseconds:1_000_000)}
            if !foreground {
                precondition(session.activeChatID==other && session.input=="Unrelated new-chat draft")
                precondition(session.openChat(origin))
            } else {precondition(session.activeChatID==origin)}
            precondition(session.turns.last?.status == .complete)
            precondition(session.input == (edit ? "Newer genuine user draft" : ""),"Only the originating fallback draft must clear after successful direct completion")
            session.flushHistory();let reloaded=AskSession(index:try adapter.index(),provider:provider);reloaded.restoreHistory(from:store)
            precondition(reloaded.input==session.input && reloaded.turns.last?.status == .complete)
        }
        print("PASS compiled recovery/server OFF routes late answer to original chat, clears only its fallback draft, preserves edited/new-chat drafts and survives reload")
    }
}
