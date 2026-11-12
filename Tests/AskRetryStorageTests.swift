import Foundation

private actor RetryStorageGate {
    private var continuation:CheckedContinuation<Void,Never>?
    private(set) var entered=false
    func wait()async {entered=true;await withCheckedContinuation {continuation=$0}}
    func open() {continuation?.resume();continuation=nil}
}
private actor RetryStorageProvider:AskFeastProvider {
    nonisolated let label="Offline retry storage fixture"
    let attempts:AskProviderAttempts
    let checkpoint:AskResponse
    let finalResponse:AskResponse
    let preflight:RetryStorageGate?
    let fails:Bool
    let revalidateRetry:Bool
    private(set) var requests:[AskRequest]=[]
    private(set) var resumedContexts:[AskResponse?]=[]
    init(attempts:AskProviderAttempts,checkpoint:AskResponse,finalResponse:AskResponse?=nil,preflight:RetryStorageGate?=nil,fails:Bool=false,revalidateRetry:Bool=false) {
        self.attempts=attempts;self.checkpoint=checkpoint;self.finalResponse=finalResponse ?? checkpoint;self.preflight=preflight;self.fails=fails;self.revalidateRetry=revalidateRetry
    }
    func answer(_ request:AskRequest,tools:AskReadTools)async throws->AskResponse {
        requests.append(request)
        if let preflight {await preflight.wait()}
        if request.providerRetry,revalidateRetry {try await AskProviderAttemptScope.validateExplicitRetry?()}
        let lease=try await attempts.begin(turn:request.performanceID!,retrying:request.providerRetry,legacySettled:false){_ in}
        do {
            resumedContexts.append(try await attempts.readContext(for:lease))
            try await attempts.register(lease.attempt,lease:lease)
            try await attempts.keepReadContext(checkpoint,lease:lease)
            if fails {throw AskHostedError.invalidResponse}
            await attempts.finish(lease);return finalResponse
        }catch {await attempts.finish(lease);throw error}
    }
}
@MainActor enum AskRetryStorageTests {
    nonisolated private static func check(_ value:Bool) {precondition(value)}
    private static func fixture(_ text:String,turn:UUID=UUID(),researchID:UUID=UUID())->AskResponse {
        .init(summary:"Retained public results.",candidates:[],listedCandidateIDs:[],usesLocalCatalog:true,
              publicResearch:[.init(id:researchID,originatingTurn:turn,query:"Public fixture",result:.init(text:text,citations:[]))])
    }
    nonisolated private static func path(_ base:URL,_ turn:UUID)->URL {base.appendingPathComponent(turn.uuidString+".json")}
    nonisolated private static func read(_ base:URL,_ turn:UUID)throws->AskProviderAttempts.Entry {
        try JSONDecoder().decode(AskProviderAttempts.Entry.self,from:Data(contentsOf:path(base,turn)))
    }
    private static func rejects(_ expected:AskRetryError,_ work:()async throws->Void)async throws {
        do {try await work();preconditionFailure("Retry safety failure: expected \(expected)")}
        catch let error as AskRetryError {check(error==expected)}
    }
    private static func waitForSession(_ session:AskSession)async throws {
        for _ in 0..<4000 {if !session.isLoading {return};try await Task.sleep(nanoseconds:1_000_000)}
        preconditionFailure("Offline fixture did not complete")
    }
    private static func waitForDeletion(_ base:URL,_ turn:UUID)async throws {
        for _ in 0..<4000 {
            if FileManager.default.fileExists(atPath:base.appendingPathComponent(turn.uuidString+".deleted").path),
               let entry=try? read(base,turn),entry.checkpoint==nil {return}
            try await Task.sleep(nanoseconds:1_000_000)
        }
        preconditionFailure("Deletion did not finish")
    }
    static func run(directory:URL)async throws {
        let base=directory.appendingPathComponent("retry-storage-"+UUID().uuidString)
        try FileManager.default.createDirectory(at:base,withIntermediateDirectories:true)
        defer {try? FileManager.default.removeItem(at:base)}
        // Explicit retry persists its proposed successor before network I/O. A
        // lost acknowledgement cannot authorize a second replacement generation.
        let retryFiles=base.appendingPathComponent("explicit-retry"),retryTurn=UUID()
        let firstStore=AskProviderAttempts(url:retryFiles,requirePersistence:true)
        let original=try await firstStore.begin(turn:retryTurn,retrying:false,legacySettled:false){_ in preconditionFailure()}
        try await firstStore.register(original.attempt,lease:original)
        try await firstStore.keepReadContext(fixture("Retained read"),lease:original)
        await firstStore.finish(original)
        do {
            _ = try await firstStore.begin(turn:retryTurn,retrying:true,legacySettled:false,restart:{roots,successor in
                check(roots==[original.attempt] && successor != original.attempt)
                check(try read(retryFiles,retryTurn).pendingSuccessor==successor)
                throw URLError(.networkConnectionLost)
            }){_ in preconditionFailure("Explicit retry must use restart")}
            preconditionFailure()
        }catch is URLError {}
        let pending=try read(retryFiles,retryTurn).pendingSuccessor!
        let afterLoss=AskProviderAttempts(url:retryFiles,requirePersistence:true)
        let successor=try await afterLoss.begin(turn:retryTurn,retrying:true,legacySettled:false,restart:{roots,id in
            check(roots==[original.attempt] && id==pending)
        }){_ in preconditionFailure()}
        check(successor.turn==retryTurn && successor.attempt==pending && successor.accountingTurn==pending)
        check(try await afterLoss.readContext(for:successor)?.publicResearch?.first?.result.text=="Retained read")
        let beforeDispatch=AskProviderAttempts(url:retryFiles,requirePersistence:true)
        let reused=try await beforeDispatch.begin(turn:retryTurn,retrying:true,legacySettled:false,restart:{_,_ in preconditionFailure()}){_ in preconditionFailure()}
        check(reused.attempt==pending && reused.accountingTurn==pending)
        try await beforeDispatch.register(pending,lease:reused)
        let next=try await beforeDispatch.begin(turn:retryTurn,retrying:true,legacySettled:false,restart:{roots,id in
            check(roots==[pending] && id != pending)
        }){_ in preconditionFailure()}
        check(next.attempt != pending && next.accountingTurn==next.attempt && next.turn==retryTurn)
        print("PASS explicit Retry preserves visual identity/read context; lost acknowledgement and pre-dispatch restart reuse one durable successor")

        for corruptMode in 0..<3 {
            let corruptFiles=base.appendingPathComponent("retry-corrupt-"+String(corruptMode))
            try FileManager.default.createDirectory(at:corruptFiles,withIntermediateDirectories:true)
            var corrupt=try read(retryFiles,retryTurn)
            if corruptMode==0 {corrupt.accountingTurn=UUID()}
            if corruptMode==1 {corrupt.pendingSuccessor=corrupt.attempt}
            if corruptMode==2 {corrupt.pendingSuccessor=UUID();corrupt.frozen=false}
            try JSONEncoder().encode(corrupt).write(to:path(corruptFiles,retryTurn))
            try await rejects(.storage) {_ = try await AskProviderAttempts(url:corruptFiles,requirePersistence:true).begin(turn:retryTurn,retrying:true,legacySettled:false,restart:{_,_ in preconditionFailure()}){_ in preconditionFailure()}}
        }
        print("PASS corrupt retry successor/accounting identities fail closed before any server call")

        let cancelStore=AskProviderAttempts(url:base.appendingPathComponent("cancel-retry"),requirePersistence:true),cancelTurn=UUID(),gate=RetryStorageGate()
        let cancelOriginal=try await cancelStore.begin(turn:cancelTurn,retrying:false,legacySettled:false){_ in}
        try await cancelStore.register(cancelOriginal.attempt,lease:cancelOriginal)
        let preparing=Task {try await cancelStore.begin(turn:cancelTurn,retrying:true,legacySettled:false,restart:{_,_ in await gate.wait()}){_ in}}
        while !(await gate.entered) {await Task.yield()}
        preparing.cancel();await gate.open()
        do {_ = try await preparing.value;preconditionFailure()}catch is CancellationError {}
        check(try read(base.appendingPathComponent("cancel-retry"),cancelTurn).attempt==cancelOriginal.attempt)
        print("PASS cancelled explicit retry never dispatches or replaces the original entry after fence acknowledgement")

        let files=base.appendingPathComponent("attempts"),attempts=AskProviderAttempts(url:files,requirePersistence:true)
        let turn=UUID(),researchID=UUID()
        let lease=try await attempts.begin(turn:turn,retrying:false,legacySettled:false){_ in preconditionFailure("Fresh turn")}
        try await attempts.register(lease.attempt,lease:lease)
        let large=fixture(String(repeating:"a",count:2*1024*1024),turn:turn,researchID:researchID)
        try await attempts.keepReadContext(large,lease:lease)
        check(try Data(contentsOf:path(files,turn)).count>1024*1024)
        let cached=await attempts.entries
        check(cached[turn]?.checkpoint==nil && cached[turn]?.roots==[lease.attempt])
        let loaded=try await attempts.readContext(for:lease)
        check(loaded?.publicResearch==large.publicResearch)
        let restarted=AskProviderAttempts(url:files,requirePersistence:true)
        let resumed=try await restarted.begin(turn:turn,retrying:true,legacySettled:false){roots in check(roots==[lease.attempt])}
        let roundTrip=try await restarted.readContext(for:resumed)
        check(roundTrip?.publicResearch==large.publicResearch)
        try await restarted.register(resumed.attempt,lease:resumed)

        // Precisely bound the serialized per-turn file, not Swift characters or aggregate files.
        var empty=try read(files,turn)
        let noText=fixture("",turn:turn,researchID:researchID)
        empty.checkpoint?.publicResearch=noText.publicResearch
        let overhead=try JSONEncoder().encode(empty).count
        let exact=fixture(String(repeating:"x",count:AskProviderAttempts.maximumBytes-overhead),turn:turn,researchID:researchID)
        try await restarted.keepReadContext(exact,lease:resumed)
        let exactBytes=try Data(contentsOf:path(files,turn))
        check(exactBytes.count==8*1024*1024)
        let boundaryReader=AskProviderAttempts(url:files)
        let boundaryLease=try await boundaryReader.begin(turn:turn,retrying:true,legacySettled:false){roots in check(roots==[resumed.attempt])}
        try await boundaryReader.register(boundaryLease.attempt,lease:boundaryLease)
        let boundaryContext=try await boundaryReader.readContext(for:boundaryLease)
        check(boundaryContext?.publicResearch==exact.publicResearch)
        let beforeOverflow=try Data(contentsOf:path(files,turn))
        let tooLarge=fixture(String(repeating:"x",count:AskProviderAttempts.maximumBytes-overhead+1),turn:turn,researchID:researchID)
        try await rejects(.capacity) {try await boundaryReader.keepReadContext(tooLarge,lease:boundaryLease)}
        check(try Data(contentsOf:path(files,turn))==beforeOverflow)
        try await rejects(.active) {try await boundaryReader.register(UUID(),lease:boundaryLease)}
        let overflowCache=await boundaryReader.entries
        check(overflowCache[turn]?.frozen==true && overflowCache[turn]?.checkpoint==nil)
        await boundaryReader.finish(boundaryLease)
        check(try read(files,turn).checkpoint?.publicResearch==exact.publicResearch)
        check(!AskRetryError.capacity.retryable && AskRetryError.capacity.localizedDescription.contains("No further step"))
        print("PASS retry checkpoints round-trip above 1MiB; exact 8MiB accepted, +1 fails closed without overwriting retained data; memory keeps metadata only")

        let legacyTurn=UUID(),legacyAttempt=UUID(),legacyRoot=UUID()
        let legacy:[String:Any] = ["attempt":legacyAttempt.uuidString,"roots":[legacyRoot.uuidString],"frozen":false,
                                  "checkpoint":try JSONSerialization.jsonObject(with:JSONEncoder().encode(noText))]
        try JSONSerialization.data(withJSONObject:legacy).write(to:path(files,legacyTurn))
        let legacyReader=AskProviderAttempts(url:files)
        let legacyLease=try await legacyReader.begin(turn:legacyTurn,retrying:true,legacySettled:false){roots in check(roots==[legacyRoot])}
        let legacyContext=try await legacyReader.readContext(for:legacyLease)
        check(legacyContext==noText)
        let oversizedTurn=UUID(),corruptTurn=UUID(),invalidRootsTurn=UUID()
        var oversized=exactBytes;oversized.append(0x20)
        try oversized.write(to:path(files,oversizedTurn))
        try Data("{".utf8).write(to:path(files,corruptTurn))
        var invalid=legacy;invalid["roots"]=[legacyRoot.uuidString,legacyRoot.uuidString]
        try JSONSerialization.data(withJSONObject:invalid).write(to:path(files,invalidRootsTurn))
        for (id,error) in [(oversizedTurn,AskRetryError.capacity),(corruptTurn,.storage),(invalidRootsTurn,.storage)] {
            let before=try Data(contentsOf:path(files,id))
            try await rejects(error) {_ = try await AskProviderAttempts(url:files).begin(turn:id,retrying:true,legacySettled:true){_ in preconditionFailure("Invalid journal must not reach a fence")}}
            check(try Data(contentsOf:path(files,id))==before)
        }
        // Once a live lease has encountered an unreadable checkpoint, restoring the
        // file does not make that old callback eligible to dispatch again.
        let unreadableCases:[(Data?,AskRetryError)]=[(nil,.storage),(Data("{".utf8),.storage),(oversized,.capacity)]
        for (replacement,error) in unreadableCases {
            let id=UUID(),reader=AskProviderAttempts(url:files)
            let active=try await reader.begin(turn:id,retrying:false,legacySettled:false){_ in}
            try await reader.register(active.attempt,lease:active)
            try await reader.keepReadContext(noText,lease:active)
            let valid=try Data(contentsOf:path(files,id))
            if let replacement {try replacement.write(to:path(files,id))}else{try FileManager.default.removeItem(at:path(files,id))}
            try await rejects(error) {_ = try await reader.readContext(for:active)}
            try valid.write(to:path(files,id))
            try await rejects(.active) {try await reader.register(UUID(),lease:active)}
            try await rejects(.active) {try await reader.keepReadContext(noText,lease:active)}
            await reader.finish(active)
            check(try read(files,id).frozen)
        }
        let blockedFolder=base.appendingPathComponent("not-a-directory")
        try Data([1]).write(to:blockedFolder)
        try await rejects(.storage) {_ = try await AskProviderAttempts(url:blockedFolder).begin(turn:UUID(),retrying:false,legacySettled:false){_ in}}
        let fileAttributes=try path(files,turn).resourceValues(forKeys:[.isExcludedFromBackupKey])
        let folderAttributes=try files.resourceValues(forKeys:[.isExcludedFromBackupKey])
        check(fileAttributes.isExcludedFromBackup==true && folderAttributes.isExcludedFromBackup==true)
#if os(iOS)
        let protection=try FileManager.default.attributesOfItem(atPath:path(files,turn).path)[.protectionKey] as? FileProtectionType
        check(protection == .completeUntilFirstUserAuthentication)
#endif
        print("PASS legacy small journals stay readable; corrupt/oversized/root-invalid files and I/O failures do not dispatch or overwrite; checkpoints excluded from backup and protected where available")

        try await lifecycle(directory:base)
        try await sessionLifecycle(directory:base)
    }
    private static func lifecycle(directory:URL)async throws {
        let files=directory.appendingPathComponent("lifecycle"),attempts=AskProviderAttempts(url:files)
        let turn=UUID(),response=fixture("Completed public evidence")
        let lease=try await attempts.begin(turn:turn,retrying:false,legacySettled:false){_ in}
        try await attempts.register(lease.attempt,lease:lease)
        try await attempts.keepReadContext(response,lease:lease)
        let runningTicket=try await attempts.archiveTicket(turn:turn);check(runningTicket==nil)
        await attempts.finish(lease)
        let ticket=try await attempts.archiveTicket(turn:turn)!
        let notCovered=try await attempts.archiveCommitted(ticket,response:.init(summary:"No evidence",candidates:[]))
        check(try !notCovered && read(files,turn).checkpoint != nil)
        let newLease=try await attempts.begin(turn:turn,retrying:true,legacySettled:false){roots in check(roots==[lease.attempt])}
        try await attempts.register(newLease.attempt,lease:newLease)
        let newer=fixture("New evidence must not be erased by an earlier archive callback")
        try await attempts.keepReadContext(newer,lease:newLease)
        let staleWhileRunning=try await attempts.archiveCommitted(ticket,response:response);check(!staleWhileRunning)
        try await rejects(.active) {try await attempts.keepReadContext(response,lease:lease)}
        await attempts.finish(lease) // A delayed old completion cannot freeze the new attempt.
        try await attempts.keepReadContext(newer,lease:newLease)
        await attempts.finish(newLease)
        let staleAfterFinish=try await attempts.archiveCommitted(ticket,response:response);check(!staleAfterFinish)
        check(try read(files,turn).checkpoint?.publicResearch==newer.publicResearch)
        let currentTicket=try await attempts.archiveTicket(turn:turn)!
        let cleaned=try await attempts.archiveCommitted(currentTicket,response:newer);check(cleaned)
        let compact=try read(files,turn)
        check(compact.checkpoint==nil && compact.frozen && compact.attempt==newLease.attempt && compact.roots==[newLease.attempt])
        let restored=AskProviderAttempts(url:files)
        let third=try await restored.begin(turn:turn,retrying:true,legacySettled:false){roots in check(roots==[newLease.attempt])}
        let empty=try await restored.readContext(for:third);check(empty==nil)
        print("PASS cleanup requires quiescence, full evidence coverage and exact attempt/revision; old callbacks cannot erase or freeze a newer retry; compact journals retain roots")

        let deletionTurn=UUID(),deletionLease=try await attempts.begin(turn:deletionTurn,retrying:false,legacySettled:false){_ in}
        let extraRoot=UUID()
        try await attempts.register(deletionLease.attempt,lease:deletionLease)
        try await attempts.register(extraRoot,lease:deletionLease)
        try await attempts.keepReadContext(response,lease:deletionLease)
        let gate=RetryStorageGate()
        let inFlight=Task {try await attempts.begin(turn:deletionTurn,retrying:true,legacySettled:false){_ in await gate.wait()}}
        while !(await gate.entered) {await Task.yield()}
        attempts.markDeleted([deletionTurn])
        try await rejects(.active) {try await attempts.keepReadContext(newer,lease:deletionLease)}
        try await attempts.delete([deletionTurn])
        await gate.open()
        try await rejects(.active) {_ = try await inFlight.value}
        let deleted=try read(files,deletionTurn)
        check(deleted.checkpoint==nil && deleted.frozen && deleted.attempt==deletionLease.attempt && deleted.roots==[deletionLease.attempt,extraRoot])
        try await rejects(.active) {try await attempts.register(UUID(),lease:deletionLease)}
        try await rejects(.active) {_ = try await AskProviderAttempts(url:files).begin(turn:deletionTurn,retrying:true,legacySettled:true){_ in preconditionFailure("Deleted turn")}}
        // Even a corrupt unresolved file is preserved behind a durable deletion marker.
        let corrupt=UUID(),corruptData=Data("unreadable accounting journal".utf8)
        try corruptData.write(to:path(files,corrupt))
        try await rejects(.storage) {try await attempts.delete([corrupt])}
        check(try Data(contentsOf:path(files,corrupt))==corruptData)
        try await rejects(.active) {_ = try await AskProviderAttempts(url:files).begin(turn:corrupt,retrying:true,legacySettled:true){_ in}}
        print("PASS explicit deletion retains unresolved accounting IDs and permanent tombstones; late callbacks and reentrant retry fences cannot resurrect deleted turns")
    }
    private static func sessionLifecycle(directory:URL)async throws {
        let files=directory.appendingPathComponent("session-attempts"),attempts=AskProviderAttempts(url:files)
        let ids=[UUID().uuidString,UUID().uuidString]
        var checkpoint=fixture("Public result safely retained")
        checkpoint.agentTask = .init(action:"query",fields:["name"],orderedIDs:ids,sourcePolicy:"local_only")
        checkpoint.mapChoices = [.init(id:UUID().uuidString,applePlaceID:"offline-fixture",name:"Public fixture",address:"1 Example Street",city:"Example City",query:"Public fixture",website:nil,originatingTurn:UUID())]
        var final=checkpoint
        final.agentTask = .init(action:"query",fields:["name"],orderedIDs:Array(ids.reversed()),sourcePolicy:"local_only")
        let provider=RetryStorageProvider(attempts:attempts,checkpoint:checkpoint,finalResponse:final)
        let index=AskLocalIndex(records:[],visibleCityIDs:[],visibleNoteIDs:[],scope:.savedMetadata)
        let archiveURL=directory.appendingPathComponent("blocked-archive.json"),store=AskConversationStore(url:archiveURL)
        let session=AskSession(index:index,provider:provider,providerAttempts:attempts)
        session.restoreHistory(from:store)
        try FileManager.default.createDirectory(at:archiveURL,withIntermediateDirectories:true)
        session.input="Research public fixtures";session.run();try await waitForSession(session)
        check(session.turns.last?.status == .complete)
        let turn=session.turns.last!.id
        session.flushHistory();await Task.yield()
        check(try session.error != nil && read(files,turn).checkpoint != nil)
        // Clearing also must not discard checkpoints when its archive replacement fails.
        session.clearConversation();await Task.yield()
        check(try session.turns.contains(where:{$0.id==turn}) && read(files,turn).checkpoint != nil)
        check(!FileManager.default.fileExists(atPath:files.appendingPathComponent(turn.uuidString+".deleted").path))
        try FileManager.default.removeItem(at:archiveURL)
        session.flushHistory()
        for _ in 0..<4000 {
            if try read(files,turn).checkpoint==nil {break}
            try await Task.sleep(nanoseconds:1_000_000)
        }
        let compact=try read(files,turn)
        check(compact.checkpoint==nil && compact.frozen && compact.roots==[compact.attempt])
        let archived=try store.loadLibrary().chats.flatMap {$0.conversation.turns}.first {$0.id==turn}
        check(archived?.response==final)
        // A failed archived turn rehydrates from its response after checkpoint compaction.
        let failed=AskTurn(id:turn,request:.init(mode:.collection,text:"Research public fixtures",fromOCR:false),response:final,status:.failed("Interrupted after retaining results"))
        let retryURL=directory.appendingPathComponent("archived-retry.json"),retryStore=AskConversationStore(url:retryURL)
        check(retryStore.save(.init(turns:[AskArchivedTurn(failed)])))
        let retrySession=AskSession(index:index,provider:provider,providerAttempts:attempts)
        retrySession.restoreHistory(from:retryStore);retrySession.retry(turn);try await waitForSession(retrySession)
        let requests=await provider.requests,contexts=await provider.resumedContexts
        check(requests.last?.providerRetry==true && requests.last?.publicResearch==final.publicResearch && requests.last?.mapChoices==final.mapChoices && requests.last?.agentTask==final.agentTask && contexts.last! == nil)
        check(retrySession.turns.last?.status == .complete)
        check(retrySession.deleteChat(retrySession.activeChatID))
        try await waitForDeletion(files,turn)
        check(try read(files,turn).roots.count==1)
        print("PASS real session archive failure/failed clear preserve retry context; verified save compacts even updated final task; archived retry reuses request evidence; chat deletion fences IDs")

        let receiptGate=RetryStorageGate(),receiptTurn=UUID()
        let guardedProvider=RetryStorageProvider(attempts:attempts,checkpoint:checkpoint,preflight:receiptGate,revalidateRetry:true)
        let guarded=AskSession(index:index,provider:guardedProvider,providerAttempts:attempts)
        let guardedHistory=AskConversationStore(url:directory.appendingPathComponent("receipt-after-fence.json"))
        check(guardedHistory.save(.init(turns:[AskArchivedTurn(.init(id:receiptTurn,request:.init(mode:.collection,text:"Retry safely",fromOCR:false),status:.stopped))])))
        guarded.restoreHistory(from:guardedHistory)
        var journalUnavailable=false
        guarded.collectionReceipts={_ in if journalUnavailable {throw AskRetryError.unverified};return []}
        guarded.retry(receiptTurn)
        while !(await receiptGate.entered) {await Task.yield()}
        journalUnavailable=true
        await receiptGate.open();try await waitForSession(guarded)
        check(guarded.error==AskRetryError.unverified.localizedDescription)
        check(!FileManager.default.fileExists(atPath:files.appendingPathComponent(receiptTurn.uuidString+".json").path))
        print("PASS retry rechecks action-journal safety after its awaited fence before starting new work")

        let failedProvider=RetryStorageProvider(attempts:attempts,checkpoint:checkpoint,fails:true)
        let failedSession=AskSession(index:index,provider:failedProvider,providerAttempts:attempts)
        let failedStore=AskConversationStore(url:directory.appendingPathComponent("failed-response.json"))
        failedSession.restoreHistory(from:failedStore);failedSession.input="Fail after a read";failedSession.run();try await waitForSession(failedSession)
        let failedID=failedSession.turns.last!.id
        failedSession.flushHistory();await Task.yield()
        check(try read(files,failedID).checkpoint != nil) // The archived error lacks the read evidence.
        failedSession.clearConversation();try await waitForDeletion(files,failedID)
        check(try failedSession.turns.isEmpty && read(files,failedID).roots.count==1)

        let oversized=fixture(String(repeating:"x",count:8*1024*1024))
        let capacityProvider=RetryStorageProvider(attempts:attempts,checkpoint:oversized)
        let capacitySession=AskSession(index:index,provider:capacityProvider,providerAttempts:attempts)
        capacitySession.input="Exceed retry capacity";capacitySession.run();try await waitForSession(capacitySession)
        check(capacitySession.canRetry[capacitySession.turns.last!.id]==false && capacitySession.error==AskRetryError.capacity.localizedDescription)

        let preflight=RetryStorageGate(),lateProvider=RetryStorageProvider(attempts:attempts,checkpoint:checkpoint,preflight:preflight)
        let lateSession=AskSession(index:index,provider:lateProvider,providerAttempts:attempts)
        lateSession.restoreHistory(from:AskConversationStore(url:directory.appendingPathComponent("late-preflight.json")))
        lateSession.input="Delete before preflight finishes";lateSession.run()
        while !(await preflight.entered) {await Task.yield()}
        let lateID=lateSession.turns.last!.id
        check(lateSession.deleteChat(lateSession.activeChatID))
        await preflight.open();try await waitForDeletion(files,lateID)
        let preflightEntry=try read(files,lateID)
        check(preflightEntry.checkpoint==nil && preflightEntry.roots.isEmpty && lateSession.turns.isEmpty)
        print("PASS failures keep unarchived evidence, capacity overflow is nonretryable, and chat deletion fences a not-yet-started provider preflight; no live transport or stores")
    }
}
