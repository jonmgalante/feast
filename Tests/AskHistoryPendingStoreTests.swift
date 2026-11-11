import Foundation
import CoreData
import CryptoKit

@MainActor enum AskHistoryPendingStoreTests {
    private static func bytes<T:Encodable>(_ value:T)throws->Data {let e=JSONEncoder();e.outputFormatting = .sortedKeys;return try e.encode(value)}
    private static func pending(_ store:AskConversationStore)throws->URL {store.pendingDirectory.appendingPathComponent("current.json")}
    private static func payloads(_ store:AskConversationStore)throws->[URL] {try FileManager.default.contentsOfDirectory(at:store.pendingDirectory.appendingPathComponent("payloads"),includingPropertiesForKeys:nil).filter {$0.pathExtension=="blob"}}
    static func run(model:NSManagedObjectModel,directory:URL)async throws {
        let root=directory.appendingPathComponent("pending-protocol");try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
        var checks=0
        func check(_ value:Bool,_ name:String) {precondition(value,name);checks+=1;print("PASS pending history: "+name)}
        func fixture(_ name:String)throws->(AskConversationStore,AskChatLibrary) {
            let store=AskConversationStore(url:root.appendingPathComponent(name+".json"));var value=try store.loadLibrary();value.chats[0].conversation.draft=String(repeating:"preserved é 🧭\n",count:500)
            return (store,value)
        }
        // Faults are real file-operation boundaries, not a store that lies about success.
        for phase in ["payload-before-write","payload-before-rename","payload-after-rename","payload-after-sync","activate-before-write","activate-before-rename","activate-after-rename","activate-after-sync"] {
            let (store,value)=try fixture("fault-"+phase);var injected=false
            store.historyFault={point in if point==phase && !injected {injected=true;throw CocoaError(.fileWriteOutOfSpace)}}
            _ = store.preserveLibrary(value);check(injected,"hit "+phase)
            store.historyFault=nil
            check(store.preserveLibrary(value) == .pending,"same-instance retry reconciles "+phase)
            let reopened=AskConversationStore(url:store.url),actual=try reopened.loadLibrary()
            check(try bytes(actual)==bytes(value),"exact restart after "+phase)
        }
        for phase in ["canonical-before-write","canonical-before-rename","canonical-after-rename","canonical-after-sync","retire-before-write","retire-before-rename","retire-after-rename","retire-after-sync"] {
            let (store,large)=try fixture("return-"+phase);check(store.preserveLibrary(large) == .pending,"seed pending for "+phase)
            var next=large;next.chats[0].conversation.draft="Newest canonical draft "+phase
            var injected=false;store.historyFault={point in if point==phase && !injected {injected=true;throw CocoaError(.fileWriteUnknown)}}
            _ = store.preserveLibrary(next);check(injected,"hit "+phase)
            store.historyFault=nil
            check(store.preserveLibrary(next) == .canonical,"finish canonical after "+phase)
            check(try bytes(AskConversationStore(url:store.url).loadLibrary())==bytes(next),"no older draft after "+phase)
        }
        do {
            let (store,value)=try fixture("retire-exact");check(store.preserveLibrary(value) == .pending,"pending is durable before canonical handoff")
            let stale=try Data(contentsOf:pending(store));var next=value;next.chats[0].conversation.draft="Newest exact canonical"
            check(store.preserveLibrary(next) == .canonical,"equivalent canonical retires matching pending")
            check(try payloads(store).isEmpty,"only verified matching pending payloads retired")
            try stale.write(to:pending(store),options:.atomic)
            do {_ = try AskConversationStore(url:store.url).loadLibrary();preconditionFailure("Old pending overwrote newer canonical")}catch {}
            check(try Data(contentsOf:store.url)==bytes(next),"stale sidecar never overwrites newer canonical bytes")
        }
        do {
            let (store,value)=try fixture("stale-writer"),stale=AskConversationStore(url:store.url);_ = try stale.loadLibrary()
            check(store.preserveLibrary(value) == .pending,"first writer preserves overflow")
            let rootBytes=try Data(contentsOf:pending(store));var other=value;other.chats[0].conversation.draft="stale writer"
            check(stale.preserveLibrary(other) == .unsaved,"stale writer cannot overwrite active pending revision")
            check(try Data(contentsOf:pending(store))==rootBytes,"stale writer leaves authoritative pending unchanged")
        }
        for damage in ["missing","corrupt","manifest"] {
            let (store,value)=try fixture("damage-"+damage);check(store.preserveLibrary(value) == .pending,"seed "+damage)
            if damage=="manifest" {try Data("bad".utf8).write(to:pending(store))}
            else {let file=try payloads(store)[0];if damage=="missing" {try FileManager.default.removeItem(at:file)}else {var data=try Data(contentsOf:file);data[0] ^= 1;try data.write(to:file)}}
            do {_ = try AskConversationStore(url:store.url).loadLibrary();preconditionFailure("Damaged pending silently fell back to canonical")}catch {}
            check(true,"\(damage) active pending fails closed, never empty fallback")
        }
        do {
            let (store,value)=try fixture("permanent-sync")
            store.historyFault={if $0=="sync" {throw CocoaError(.fileWriteOutOfSpace)}}
            check(store.preserveLibrary(value) == .unsaved,"persistent sync failure never claims durability")
            do {_ = try store.durableLibrary();preconditionFailure("Unsynced payload compacted checkpoint")}catch {}
            store.historyFault=nil;check(store.preserveLibrary(value) == .pending,"known old/new outcome can retry after sync recovers")
        }
        do {
            let (store,value)=try fixture("bounds");var huge=value;huge.chats[0].conversation.draft=String(repeating:"x",count:8*1024*1024+1)
            check(store.preserveLibrary(huge) == .unsaved,"unrepresentable individual draft stays RAM, not a larger cap")
            check(store.preserveLibrary(value) == .pending,"failed oversized admission does not poison later pending save")
            for path in [store.pendingDirectory,try pending(store),store.url.appendingPathExtension("history-lock")]+(try payloads(store)) {
                check(try path.resourceValues(forKeys:[.isExcludedFromBackupKey]).isExcludedFromBackup==true,"history component remains excluded from backup")
            }
            check(try store.url.deletingLastPathComponent().resourceValues(forKeys:[.isExcludedFromBackupKey]).isExcludedFromBackup != true,"shared parent is not excluded with the action journal")
        }
        for phase in ["activate-after-rename","canonical-before-write","canonical-after-rename","cleanup"] {
            let store=AskConversationStore(url:root.appendingPathComponent("redact-"+phase+".json"));var base=AskChatLibrary.empty()
            let removed=base.activeID;base.chats[0].conversation.draft="Explicitly deleted private draft"
            let remaining=AskChatArchive(id:UUID(),title:"Remaining",updatedAt:Date(),conversation:.init(draft:"Older remaining draft"))
            base.chats.append(remaining);check(store.saveLibrary(base),"seed known canonical redaction baseline")
            var next=try store.loadLibrary();next.activeID=remaining.id;next.chats[1].conversation.draft=String(repeating:"newest ",count:1000)
            check(store.preserveLibrary(next) == .pending,"overflow retains both latest chats before deletion")
            next.chats.removeAll {$0.id==removed}
            var hit=false;store.historyFault={if $0==phase && !hit {hit=true;throw CocoaError(.fileWriteOutOfSpace)}}
            _ = store.preserveLibrary(next,removingChatIDs:[removed]);check(hit,"hit explicit-redaction "+phase)
            store.historyFault=nil
            check(store.preserveLibrary(next,removingChatIDs:[removed]) == .pending,"resume bound redaction without discarding remaining overflow")
            let canonical=try JSONDecoder().decode(AskChatLibrary.self,from:Data(contentsOf:store.url))
            check(!canonical.chats.contains(where:{$0.id==removed}) && canonical.chats.first?.conversation.draft=="Older remaining draft","only explicitly removed canonical chat is redacted")
            check(try bytes(AskConversationStore(url:store.url).loadLibrary())==bytes(next),"restart keeps newest remaining pending draft after canonical redaction")
        }
        do {
            let (store,value)=try fixture("total-bound");check(store.preserveLibrary(value) == .pending,"seed before total pending resource boundary")
            let original=try Data(contentsOf:pending(store));var next=value
            next.chats[0].conversation.draft=String(repeating:"x",count:6*1024*1024)
            for n in 0..<2 {next.chats.append(.init(id:UUID(),title:"Large \(n)",updatedAt:Date(),conversation:.init(draft:String(repeating:"y",count:6*1024*1024))))}
            check(store.preserveLibrary(next) == .unsaved,"16-MiB materialized pending bound fails before writing payloads")
            check(try Data(contentsOf:pending(store))==original,"resource failure keeps prior durable pending revision")
        }
        do {
            let store=AskConversationStore(url:root.appendingPathComponent("fifty.json"));var library=AskChatLibrary.empty()
            for i in 1..<50 {library.chats.append(.init(id:UUID(),title:"Chat \(i)",updatedAt:Date(),conversation:.init()))}
            check(store.saveLibrary(library),"canonical 50-chat fixture admitted")
            let session=AskSession(index:.init(records:[],visibleCityIDs:[],visibleNoteIDs:[],scope:.savedMetadata));session.restoreHistory(from:store)
            let original=session.activeChatID;session.input=String(repeating:"draft ",count:1000);session.flushHistory()
            check(!session.newChat() && session.chats.count==50 && session.activeChatID==original,"pending does not bypass 50-chat new admission")
            check(session.openChat(library.chats[1].id),"full library still allows safe existing-chat selection")
            check(session.openChat(original) && session.input.utf8.count==6000,"full library returns exact oversized draft")
        }
        do {
            let store=AskConversationStore(url:root.appendingPathComponent("process-lock.json"));var value=try store.loadLibrary();value.chats[0].conversation.draft="Prior durable process-lock state"
            check(store.preserveLibrary(value) == .canonical,"seed interprocess writer lock")
            let prior=try Data(contentsOf:store.url),lock=store.url.appendingPathExtension("history-lock"),pipe=Pipe(),child=Process()
            child.executableURL=URL(fileURLWithPath:"/usr/bin/env");child.arguments=["python3","-c","import fcntl,sys,time; f=open(sys.argv[1],'a+'); fcntl.flock(f,fcntl.LOCK_EX); print('ready',flush=True); time.sleep(60)",lock.path];child.standardOutput=pipe
            try child.run();defer{if child.isRunning {child.terminate();child.waitUntilExit()}}
            let ready=try pipe.fileHandleForReading.read(upToCount:6);check(ready==Data("ready\n".utf8),"real second process holds journal-independent history lock")
            value.chats[0].conversation.draft="Newer local RAM waiting for lock";let started=DispatchTime.now().uptimeNanoseconds
            check(store.preserveLibrary(value) == .unsaved,"concurrent process refuses before history write")
            check(Double(DispatchTime.now().uptimeNanoseconds-started)/1_000_000<1000 && (try? Data(contentsOf:store.url))==prior,"lock contention is bounded and leaves prior bytes exact")
            child.terminate();child.waitUntilExit()
            check(store.preserveLibrary(value) == .canonical,"process death releases lock without deleting evidence")
        }
        print("DIAGNOSTIC pending protocol checkpoints \(checks)")
    }
}
