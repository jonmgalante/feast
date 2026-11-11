import Foundation
import CoreData

private actor NavigationHeldAnswer:AskFeastProvider {
    nonisolated let label="Offline held navigation answer"
    private var gate:CheckedContinuation<Void,Never>?,started=false
    func ready()->Bool {started}
    func release(){gate?.resume();gate=nil}
    func answer(_ request:AskRequest,tools:AskReadTools)async throws->AskResponse {
        started=true;await withCheckedContinuation {gate=$0}
        return .init(summary:"Accepted late response",candidates:[],listedCandidateIDs:[],usesLocalCatalog:true,agentTask:.init(action:"query",fields:[],orderedIDs:[],sourcePolicy:"stored_only"))
    }
}
@MainActor enum AskHistoryReviewRegressionTests {
    static func run(directory:URL)async throws {
        let root=directory.appendingPathComponent("navigation-review");try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
        let index=AskLocalIndex(records:[],visibleCityIDs:[],visibleNoteIDs:[],scope:.savedMetadata)
        var failures:[String]=[]
        func check(_ result:Bool,_ label:String){print("\(result ? "PASS" : "FAIL") history review: "+label);if !result {failures.append(label)}}
        for phase in ["activate-after-rename","canonical-after-rename","retire-after-rename","marker-after-remove","final-before-sync"] {
            let store=AskConversationStore(url:root.appendingPathComponent(phase+".json")),provider=NavigationHeldAnswer(),session=AskSession(index:index,provider:provider)
            session.restoreHistory(from:store);session.input="Original draft";session.flushHistory();let old=session.activeChatID
            session.input="Question accepted before uncertain Clear";session.run()
            for _ in 0..<2000 {if await provider.ready(){break};try await Task.sleep(nanoseconds:1_000_000)}
            var hit=false;store.historyFault={point in if point==phase {hit=true};if hit && point=="sync" {throw CocoaError(.fileWriteOutOfSpace)}}
            session.clearConversation()
            check(hit && session.activeChatID==old && session.isLoading,"unverified Clear retains live screen at "+phase)
            check(session.historyWarning?.contains("couldn’t be verified")==true,"unverified removal has specific warning at "+phase)
            let draft="Newer e\u{301} 🧭 draft after uncertain Clear  "
            session.input=draft;await provider.release()
            for _ in 0..<2000 {if !session.isLoading{break};try await Task.sleep(nanoseconds:1_000_000)}
            let turn=session.turns.last!;check(turn.status == .complete,"accepted late response retained at "+phase)
            session.flushHistory()
            let restartBefore=AskConversationStore(url:store.url),visible=try restartBefore.loadLibrary()
            check(!visible.chats.contains(where:{$0.id==old}),"restart before live resolution sees exact removal candidate at "+phase)
            store.historyFault=nil
            check(session.newChat() && session.openChat(old),"New/Open resolves same live uncertain operation at "+phase)
            check(Array(session.input.utf8)==Array(draft.utf8) && session.turns.last?.id==turn.id && session.turns.last?.response==turn.response,"newer UTF-8 draft and late answer survive resolution at "+phase)
            let reloaded=try AskConversationStore(url:store.url).loadLibrary(),chat=reloaded.chats.first {$0.id==old}
            check(chat.map {Array($0.conversation.draft.utf8)==Array(draft.utf8) && $0.conversation.turns.last?.id==turn.id}==true,"restart after resolution has newest old-ID state at "+phase)
            check((try? store.durableLibrary()) != nil,"resolved exact revision authorizes durability at "+phase)
        }
        for phase in ["activate-before-write","activate-after-rename","canonical-after-rename","retire-after-rename","marker-after-remove","final-before-sync"] {
            let store=AskConversationStore(url:root.appendingPathComponent("retry-"+phase+".json")),session=AskSession(index:index)
            session.restoreHistory(from:store);session.input="Original before explicit retry";session.flushHistory();let old=session.activeChatID
            var hit=false;store.historyFault={point in if point==phase {hit=true};if hit && (point=="sync" || point==phase) {throw CocoaError(.fileWriteOutOfSpace)}}
            session.clearConversation();check(hit && session.activeChatID==old,"failed/unverified retry setup at "+phase)
            if phase=="activate-before-write" {
                check(store.unresolvedRemovalWarning==nil,"pre-activation failure is unchanged, not an uncertain removal")
                check(try AskConversationStore(url:store.url).loadLibrary().activeID==old,"pre-activation restart keeps old authority")
            }
            session.input="Genuine newer draft before a NEW explicit Clear e\u{301}";store.historyFault=nil
            session.clearConversation()
            check(session.activeChatID != old && session.input.isEmpty && session.turns.isEmpty,"new explicit Clear acts on current screen at "+phase)
            let actual=try AskConversationStore(url:store.url).loadLibrary()
            check(actual.activeID==session.activeChatID && !actual.chats.contains(where:{$0.id==old}),"explicit retry has its own verified replacement at "+phase)
        }
        do {
            let store=AskConversationStore(url:root.appendingPathComponent("foreign.json")),session=AskSession(index:index)
            session.restoreHistory(from:store);session.input="Original foreign fence";session.flushHistory();let old=session.activeChatID
            var hit=false;store.historyFault={if $0=="activate-after-rename" {hit=true};if hit && $0=="sync" {throw CocoaError(.fileWriteOutOfSpace)}}
            session.clearConversation();store.historyFault=nil
            let foreign=AskConversationStore(url:store.url);var value=try foreign.loadLibrary();value.chats[0].conversation.draft="Foreign newer revision"
            check(foreign.preserveLibrary(value) == .canonical,"another instance writes a genuinely new revision")
            session.input="New live old-ID draft e\u{301}";session.flushHistory()
            check(session.activeChatID==old && session.historyWarning?.contains("not saved")==true,"owned removal cannot override foreign revision")
            check(try AskConversationStore(url:store.url).loadLibrary().chats[0].conversation.draft=="Foreign newer revision","foreign bytes remain authoritative")
        }
        do {
            let store=AskConversationStore(url:root.appendingPathComponent("takeover.json")),first=AskSession(index:index)
            first.restoreHistory(from:store);first.input="First owner";first.flushHistory()
            let second=AskSession(index:index);second.restoreHistory(from:store);second.input="Second Session owner";second.flushHistory()
            first.input="Old Session must retain only RAM";first.flushHistory()
            check(first.historyWarning?.contains("not saved")==true && (try? store.loadLibrary().chats[0].conversation.draft)=="Second Session owner","shared store capability belongs to exactly one live Session")
            check((try? store.durableLibrary()) != nil && store.unsavedNotice==nil,"rejected old owner cannot invalidate new owner durability or own its loss notice")
        }
        do {
            let store=AskConversationStore(url:root.appendingPathComponent("uncertain-notice.json")),session=AskSession(index:index)
            session.restoreHistory(from:store);session.input="Prior state";session.flushHistory()
            store.historyFault={if $0=="final-before-sync" {throw CocoaError(.fileWriteUnknown)}}
            session.clearConversation();store.historyFault=nil
            let restarted=AskConversationStore(url:store.url);_ = try restarted.loadLibrary()
            check(restarted.unsavedNotice?.contains("Clear or Delete couldn’t be verified")==true && restarted.unsavedNotice?.contains("earlier saved history")==false,"durable uncertain-removal notice never calls the visible candidate an unchanged old archive")
        }
        do {
            let url=root.appendingPathComponent("notice.json"),first=AskConversationStore(url:url);var value=try first.loadLibrary()
            value.chats[0].conversation.draft="Earlier saved draft";check(first.preserveLibrary(value) == .canonical,"seed historical notice")
            var huge=value;huge.chats[0].conversation.draft=String(repeating:"x",count:8*1024*1024+1)
            check(first.preserveLibrary(huge) == .unsaved,"record first session lost RAM")
            let second=AskConversationStore(url:url);_ = try second.loadLibrary();check(second.unsavedNotice != nil,"import earlier session loss notice")
            check(second.preserveLibrary(huge) == .unsaved,"new failure after historical notice")
            value.chats[0].conversation.draft="Small newly saved edit";check(second.preserveLibrary(value) == .canonical,"save later current edit")
            check(second.unsavedNotice != nil,"new failure and success cannot dismiss imported loss notice")
            let third=AskConversationStore(url:url);_ = try third.loadLibrary();check(third.unsavedNotice != nil,"historical notice remains after another restart")
        }
        do {
            let store=AskConversationStore(url:root.appendingPathComponent("cleanup.json"));var value=try store.loadLibrary()
            value.chats[0].conversation.draft=String(repeating:"old payload ",count:1000);check(store.preserveLibrary(value) == .pending,"seed obsolete cleanup references")
            var fired=false;store.historyFault={if $0=="retire-after-rename" && !fired {fired=true;throw CocoaError(.fileWriteUnknown)}}
            value.chats[0].conversation.draft="Small canonical replacement";check(store.preserveLibrary(value) == .canonical,"verify canonical despite receipt boundary failure")
            let blobs=store.pendingDirectory.appendingPathComponent("payloads")
            let count=try FileManager.default.contentsOfDirectory(at:blobs,includingPropertiesForKeys:nil).filter {$0.pathExtension=="blob"}.count
            check(count==0 || store.maintenanceWarning != nil,"retirement cannot silently lose obsolete cleanup obligation")
            store.historyFault=nil;check(store.preserveLibrary(value) == .canonical,"retry cleanup obligation")
            check(try FileManager.default.contentsOfDirectory(at:blobs,includingPropertiesForKeys:nil).filter {$0.pathExtension=="blob"}.isEmpty,"later success finishes exact obsolete payload cleanup")
        }
        do {
            let store=AskConversationStore(url:root.appendingPathComponent("nonactive.json")),provider=NavigationHeldAnswer(),session=AskSession(index:index,provider:provider)
            session.restoreHistory(from:store);let other=session.activeChatID
            check(session.newChat(),"create active A beside removable B")
            let active=session.activeChatID;session.input="Keep active request";session.run()
            for _ in 0..<2000 {if await provider.ready(){break};try await Task.sleep(nanoseconds:1_000_000)}
            let turn=session.turns.last!.id
            check(session.deleteChat(other),"delete nonactive B while A is running without recovery")
            check(session.activeChatID==active && session.isLoading && session.turns.contains(where:{$0.id==turn}),"nonactive Delete preserves active task and loading turn")
            await provider.release();for _ in 0..<2000 {if !session.isLoading{break};try await Task.sleep(nanoseconds:1_000_000)}
            check(!session.isLoading && session.turns.last?.id==turn && session.turns.last?.status == .complete,"active no-recovery response still lands after deleting other chat")
        }
        precondition(failures.isEmpty,"Navigation review regressions: "+failures.joined(separator:"; "))
    }
}
