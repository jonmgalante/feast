import Foundation
import CryptoKit

private struct HistoryActivityProvider:AskFeastProvider {
    let label="Offline navigation activity fixture"
    func answer(_ request:AskRequest,tools:AskReadTools)async throws->AskResponse {
        .init(summary:"Accepted ordinary response",candidates:[],listedCandidateIDs:[],usesLocalCatalog:true,agentTask:.init(action:"query",fields:[],orderedIDs:[],sourcePolicy:"stored_only"))
    }
}
private struct HistoryFailureProvider:AskFeastProvider {
    let label="Offline history error fixture"
    func answer(_ request:AskRequest,tools:AskReadTools)async throws->AskResponse {throw CocoaError(.fileReadUnknown)}
}
@MainActor enum AskHistoryFollowupTests {
    private static func digest(_ data:Data)->String {SHA256.hash(data:data).map {String(format:"%02x",$0)}.joined()}
    private static func root(_ store:AskConversationStore)throws->[String:Any] {
        let envelope=try JSONSerialization.jsonObject(with:Data(contentsOf:store.pendingDirectory.appendingPathComponent("current.json"))) as! [String:Any]
        return try JSONSerialization.jsonObject(with:Data(base64Encoded:envelope["payload"] as! String)!) as! [String:Any]
    }
    private static func write(_ root:[String:Any],store:AskConversationStore)throws {
        let payload=try JSONSerialization.data(withJSONObject:root,options:.sortedKeys)
        try JSONSerialization.data(withJSONObject:["payload":payload.base64EncodedString(),"digest":digest(payload)],options:.sortedKeys).write(to:store.pendingDirectory.appendingPathComponent("current.json"),options:.atomic)
    }
    static func run(directory:URL)async throws {
        let folder=directory.appendingPathComponent("navigation-followup");try FileManager.default.createDirectory(at:folder,withIntermediateDirectories:true)
        let index=AskLocalIndex(records:[],visibleCityIDs:[],visibleNoteIDs:[],scope:.savedMetadata)
        var failures:[String]=[]
        func check(_ value:Bool,_ label:String){print("\(value ? "PASS" : "FAIL") history follow-up: "+label);if !value {failures.append(label)}}
        do {
            let session=AskSession(index:index,provider:HistoryFailureProvider())
            session.input="Keep the existing failed-turn error in History";session.run();while session.isLoading {await Task.yield()}
            check(session.error != nil && session.turns.last?.status == .failed(session.error!),"seed an inline failed-turn error")
            check(session.composerError==nil && session.historyError==session.error,"History retains request error hidden only by the composer's inline-turn deduplication")
        }
        do {
            let store=AskConversationStore(url:folder.appendingPathComponent("sticky-removal-cleanup.json")),session=AskSession(index:index)
            session.restoreHistory(from:store);session.input="Explicitly clear this draft";session.flushHistory()
            let removed=session.activeChatID
            session.collectionClear={_ in throw CocoaError(.fileWriteUnknown)}
            session.clearConversation()
            check(session.activeChatID != removed && session.historyWarning?.contains("older local recovery data couldn’t be cleared")==true,"verified Clear surfaces failed post-commit cleanup")
            try await Task.sleep(nanoseconds:450_000_000);session.flushHistory()
            check(session.historyWarning?.contains("older local recovery data couldn’t be cleared")==true && session.composerError?.contains("older local recovery data couldn’t be cleared")==true && session.historyError?.contains("older local recovery data couldn’t be cleared")==true,"ordinary successful autosave cannot erase unresolved removal-cleanup warning")
            let other=session.activeChatID
            check(session.newChat() && session.openChat(other) && session.historyWarning?.contains("older local recovery data couldn’t be cleared")==true && session.composerError?.contains("older local recovery data couldn’t be cleared")==true && session.historyError?.contains("older local recovery data couldn’t be cleared")==true,"unresolved removal-cleanup warning survives New/Open")
        }
        do {
            let seed=AskConversationStore(url:folder.appendingPathComponent("combined-warning.json"));var value=try seed.loadLibrary()
            value.chats[0].conversation.draft=String(repeating:"old ",count:1500);precondition(seed.preserveLibrary(value) == .pending)
            seed.historyFault={if $0=="cleanup" {throw CocoaError(.fileWriteUnknown)}}
            value.chats[0].conversation.draft=String(repeating:"new ",count:1500);precondition(seed.preserveLibrary(value) == .pending)
            var huge=value;huge.chats[0].conversation.draft=String(repeating:"x",count:8*1024*1024+1);precondition(seed.preserveLibrary(huge) == .unsaved)
            let store=AskConversationStore(url:seed.url),session=AskSession(index:index)
            store.historyFault={if $0=="cleanup" {throw CocoaError(.fileWriteUnknown)}};session.restoreHistory(from:store)
            func visibleLoss()->Bool {session.historyWarning?.contains("not saved")==true && (session.historyWarning?.contains("earlier")==true || session.historyWarning?.contains("earlier".capitalized)==true)}
            check(visibleLoss() && session.historyWarning?.contains("cleanup")==true && session.canDismissHistoryNotice,"imported lost-RAM explanation is visible beside cleanup debt before dismissal")
            session.input += " newer durable edit";session.flushHistory()
            check(visibleLoss() && session.historyWarning?.contains("cleanup")==true,"successful pending autosave cannot hide imported loss behind cleanup debt")
            session.input=huge.chats[0].conversation.draft;session.flushHistory()
            check(visibleLoss() && session.historyWarning?.contains("Keep the app open")==true && !session.canDismissHistoryNotice,"new RAM failure preserves historical-loss explanation and current unsaved warning")
            session.input=value.chats[0].conversation.draft;session.flushHistory();session.dismissHistoryNotice()
            check(store.unsavedNotice==nil && session.historyWarning?.contains("cleanup")==true && !visibleLoss(),"explicit dismissal acknowledges only loss notice, not cleanup obligation")
        }
        do {
            let store=AskConversationStore(url:folder.appendingPathComponent("activity.json")),session=AskSession(index:index,provider:HistoryActivityProvider())
            session.restoreHistory(from:store);let first=session.activeChatID,t1=Date(timeIntervalSinceReferenceDate:1000),t2=Date(timeIntervalSinceReferenceDate:2000)
            session.activityNow={t1};session.input="First genuine activity";session.run();while session.isLoading {await Task.yield()}
            let firstTurn=session.turns.last!.id,firstDraft="First unflushed draft e\u{301} 🧭  "
            session.input=firstDraft;check(session.newChat(),"New immediately captures unflushed first activity")
            let second=session.activeChatID;session.input="Draft only in new chat";session.flushHistory()
            check(session.chats.first(where:{$0.id==second})?.lastActivityAt==nil && session.chats.first(where:{$0.id==first})?.lastActivityAt==t1,"previous pending activity is never attributed to a draft-only new chat")
            session.activityNow={t2};session.input="Second genuine activity";session.run();while session.isLoading {await Task.yield()}
            let secondTurn=session.turns.last!.id,secondDraft="Second exact unflushed draft e\u{301}  "
            session.input=secondDraft;check(session.openChat(first),"Open immediately captures unflushed second activity");session.flushHistory()
            let saved=try AskConversationStore(url:store.url).loadLibrary(),a=saved.chats.first {$0.id==first}!,b=saved.chats.first {$0.id==second}!
            check(a.lastActivityAt==t1 && b.lastActivityAt==t2,"passive Open/flush never moves another chat's activity timestamp")
            check(a.conversation.turns.last?.id==firstTurn && b.conversation.turns.last?.id==secondTurn && Array(a.conversation.draft.utf8)==Array(firstDraft.utf8) && Array(b.conversation.draft.utf8)==Array(secondDraft.utf8),"single-commit navigation preserves both exact turns and UTF-8 drafts")
        }
        do {
            let seed=AskConversationStore(url:folder.appendingPathComponent("fair-cleanup.json"));var value=try seed.loadLibrary();value.chats[0].conversation.draft=String(repeating:"active ",count:700);precondition(seed.preserveLibrary(value) == .pending)
            let blobs=seed.pendingDirectory.appendingPathComponent("payloads")
            let ordered=(0..<40).map {Data("Obsolete fixture \($0)".utf8)}.sorted {digest($0)<digest($1)}
            var manifest=try root(seed);manifest["retired"]=ordered.map {["digest":digest($0),"bytes":$0.count] as [String:Any]}
            for (i,original) in ordered.enumerated() {var bytes=original;if i<32 {bytes[0] ^= 1};try bytes.write(to:blobs.appendingPathComponent(digest(original)+".blob"))}
            try write(manifest,store:seed)
            for attempt in 0..<3 {
                let reopened=AskConversationStore(url:seed.url);value=try reopened.loadLibrary()
                check(reopened.preserveLibrary(value) == .pending && reopened.historyCleanupFilesInspected<=32,"bounded cleanup pass across restart \(attempt)")
            }
            check(ordered.suffix(8).allSatisfy {!FileManager.default.fileExists(atPath:blobs.appendingPathComponent(digest($0)+".blob").path)},"32 permanently divergent refs cannot starve eligible later cleanup")
            check(try ordered.prefix(32).allSatisfy {original in var damaged=original;damaged[0] ^= 1;return try Data(contentsOf:blobs.appendingPathComponent(digest(original)+".blob"))==damaged},"fair cleanup preserves every divergent payload unchanged")
            let reopened=AskConversationStore(url:seed.url);_ = try reopened.loadLibrary()
            check(try reopened.maintenanceWarning != nil && (root(reopened)["retired"] as! [Any]).count==32,"only unresolved divergent obligations remain durable and visible")
        }
        do {
            let seed=AskConversationStore(url:folder.appendingPathComponent("grown-obsolete.json"));var value=try seed.loadLibrary();value.chats[0].conversation.draft=String(repeating:"active ",count:700);precondition(seed.preserveLibrary(value) == .pending)
            let blobs=seed.pendingDirectory.appendingPathComponent("payloads"),grown=Data(repeating:0x5a,count:512*1024)
            let original=(0..<32).map {Data([UInt8($0)])};var manifest=try root(seed)
            manifest["retired"]=original.map {["digest":digest($0),"bytes":$0.count] as [String:Any]}
            for data in original {try grown.write(to:blobs.appendingPathComponent(digest(data)+".blob"))};try write(manifest,store:seed)
            let store=AskConversationStore(url:seed.url);value=try store.loadLibrary();check(store.preserveLibrary(value) == .pending,"grown obsolete files cannot block current exact authority")
            print("DIAGNOSTIC cleanup actual payload bytes read \(store.historyCleanupBytesRead), declared debt bytes 32")
            check(store.historyCleanupBytesRead<=32 && store.historyCleanupFilesInspected<=32,"fresh size mismatch rejects grown obsolete files before payload reads")
            check(try original.allSatisfy {try Data(contentsOf:blobs.appendingPathComponent(digest($0)+".blob"))==grown},"size-mismatched foreign bytes remain untouched with visible debt")
            check(try store.maintenanceWarning != nil && (root(store)["retired"] as! [Any]).count==32,"size mismatch never silently retires a cleanup obligation")
        }
        precondition(failures.isEmpty,"History follow-up: "+failures.joined(separator:"; "))
    }
}
