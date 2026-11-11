import Foundation
import CoreData

@MainActor enum AskHistoryNavigationTests {
    static func run(model:NSManagedObjectModel,directory:URL)async throws {
        let root=directory.appendingPathComponent("navigation-tests");try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
        let fixture=try AskLargeHistoryFixture(model:model,directory:root.appendingPathComponent("fixture"))
        let seed=try fixture.session();try await fixture.answer(seed)
        let turn=seed.turns.last!,turnBytes=try JSONEncoder().encode(AskArchivedTurn(turn)).count
        precondition(turnBytes>400_000,"Must exercise a genuinely large accepted native result")
        print("DIAGNOSTIC native archived turn bytes \(turnBytes), rendered records \(turn.response!.candidates.count)")
        var failures:[String]=[]
        func check(_ value:Bool,_ label:String) {print("\(value ? "PASS" : "FAIL") history navigation: \(label)");if !value {failures.append(label)}}
        let selected=ProcessInfo.processInfo.environment["FEAST_NAVIGATION_CASE"]
        if selected==nil || selected=="capacity" {
            let url=root.appendingPathComponent("capacity.json"),store=AskConversationStore(url:url)
            let baseline=try fixture.nearLimitLibrary(turn:turn);precondition(store.saveLibrary(baseline))
            let session=try fixture.session(store:store),original=session.activeChatID
            try await fixture.answer(session);let oldBytes=try Data(contentsOf:url);session.input="Exact unsent draft 🧭\n trailing  ";session.flushHistory()
            let ids=session.turns.map(\.id),response=session.response
            let moved=session.newChat();check(moved,"over-8-MiB current chat can leave without deleting history")
            if moved {
                let other=session.activeChatID
                let started=DispatchTime.now().uptimeNanoseconds,written=store.historyBytesWritten
                for i in 0..<5 {session.input="Draft edit \(i)";session.flushHistory()}
                let elapsed=Double(DispatchTime.now().uptimeNanoseconds-started)/1_000_000
                print("DIAGNOSTIC five just-over-8-MiB pending draft edits ms \(elapsed), new bytes \(store.historyBytesWritten-written)")
                check(store.historyBytesWritten-written<500_000,"pending draft edits reuse immutable turn payloads")
                session.input="Second draft";session.flushHistory()
                check(session.openChat(original) && session.input=="Exact unsent draft 🧭\n trailing  " && session.turns.map(\.id)==ids && session.response==response,"New/Open returns exact over-capacity chat and draft")
                session.suspend()
                let restarted=try fixture.session(store:AskConversationStore(url:url))
                check(restarted.activeChatID==original && restarted.input==session.input && restarted.turns.map(\.id)==ids && restarted.response==response && !restarted.isLoading,"pending overflow restarts without replay or truncation")
                check(restarted.openChat(other) && restarted.input=="Second draft","pending second chat remains discoverable")
            }
            check(try Data(contentsOf:url)==oldBytes,"canonical capacity rejection never replaces known saved bytes")
        }
        if selected==nil || selected=="budget" {
            let url=root.appendingPathComponent("budget.json"),store=AskConversationStore(url:url)
            let baseline=try fixture.nearLimitLibrary(turn:turn);precondition(store.saveLibrary(baseline))
            let session=try fixture.session(store:store),original=session.activeChatID
            try await fixture.answer(session);session.input="Last durable pending draft";session.flushHistory()
            let durableIDs=session.turns.map(\.id),large=String(repeating:"x",count:8*1024*1024-100_000)
            session.input=large;session.flushHistory()
            do {_ = try store.durableLibrary();preconditionFailure("Budget failure must not authorize checkpoint compaction")}catch {}
            check(session.newChat(),"crossing total pending budget still permits RAM escape")
            check(session.openChat(original) && Array(session.input.utf8)==Array(large.utf8) && session.turns.map(\.id)==durableIDs,"above-budget RAM chat remains exact and returnable")
            check(session.unsavedHistoryChatIDs.contains(original) && session.composerError?.contains("not saved")==true,"sticky above-budget warning associates affected chat by ID without private titles")
            session.suspend()
            let restarted=try fixture.session(store:AskConversationStore(url:url))
            check(restarted.turns.map(\.id)==durableIDs && restarted.input=="Last durable pending draft" && !restarted.isLoading,"restart loads only the prior durable pending revision, with no replay")
            check(restarted.composerError?.contains("earlier saved history")==true && restarted.composerError?.contains("not saved")==true,"small revision-bound notice never labels older history as newest RAM state")
            try await Task.sleep(nanoseconds:450_000_000);restarted.flushHistory()
            check(restarted.composerError?.contains("not saved")==true,"automatic save of older history does not dismiss the lost-RAM notice")
            check(restarted.newChat() && restarted.openChat(original) && restarted.composerError?.contains("not saved")==true,"imported notice survives New/Open and warning reset")
            restarted.dismissHistoryNotice();check(!restarted.canDismissHistoryNotice && restarted.composerError?.contains("earlier session") != true,"explicit notice dismissal acknowledges only status, not hidden data loss")
            check(Array(session.input.utf8)==Array(large.utf8),"older reload does not destroy still-open exact RAM draft")
        }
        if selected==nil || selected=="latency" {
            let store=AskConversationStore(url:root.appendingPathComponent("normal-latency.json"));var value=AskChatLibrary.empty();value.chats[0].conversation.turns=[.init(turn)]
            check(store.saveLibrary(value),"normal-size accepted native fixture admitted")
            let session=try fixture.session(store:store),original=session.activeChatID;var times:[String:Double]=[:]
            for i in 0..<3 {session.input="Normal draft \(i) e\u{301}";let start=DispatchTime.now().uptimeNanoseconds;session.flushHistory();times["draft-\(i)"]=Double(DispatchTime.now().uptimeNanoseconds-start)/1_000_000}
            let newStart=DispatchTime.now().uptimeNanoseconds;let moved=session.newChat();times["new"]=Double(DispatchTime.now().uptimeNanoseconds-newStart)/1_000_000
            let openStart=DispatchTime.now().uptimeNanoseconds;let opened=session.openChat(original);times["open"]=Double(DispatchTime.now().uptimeNanoseconds-openStart)/1_000_000
            check(moved && opened && Array(session.input.utf8)==Array("Normal draft 2 e\u{301}".utf8) && session.turns.first?.id==turn.id,"single-commit normal New/Open preserves exact draft and accepted result")
            print("DIAGNOSTIC normal one-turn bytes \(turnBytes), individual MainActor operation ms \(times), worst \(times.values.max()!)")
        }
        if selected==nil || selected=="latency" {
            let store=AskConversationStore(url:root.appendingPathComponent("near-pending-budget.json"));var library=try store.loadLibrary(),total=0
            let encoder=JSONEncoder();encoder.outputFormatting = .sortedKeys
            while true {
                let archived=AskArchivedTurn(.init(id:UUID(),request:turn.request,response:turn.response,sources:turn.sources,status:turn.status)),size=try encoder.encode(archived).count
                if total+size>AskConversationStore.maximumPendingBytes-4096 {break}
                library.chats[0].conversation.turns.append(archived);total+=size
            }
            check(total>15*1024*1024 && store.preserveLibrary(library) == .pending,"near-16-MiB actual accepted native history is durable")
            let session=try fixture.session(store:store),original=session.activeChatID
            var samples:[String:Double]=[:]
            for i in 0..<3 {
                session.input="Near budget draft \(i) e\u{301}";let start=DispatchTime.now().uptimeNanoseconds;session.flushHistory()
                samples["draft-\(i)"]=Double(DispatchTime.now().uptimeNanoseconds-start)/1_000_000
            }
            let start=DispatchTime.now().uptimeNanoseconds;let moved=session.newChat();samples["new"]=Double(DispatchTime.now().uptimeNanoseconds-start)/1_000_000
            let openStart=DispatchTime.now().uptimeNanoseconds;let opened=session.openChat(original);samples["open"]=Double(DispatchTime.now().uptimeNanoseconds-openStart)/1_000_000
            check(moved && opened && session.turns.count==library.chats[0].conversation.turns.count,"near-budget navigation preserves every accepted turn")
            print("DIAGNOSTIC active pending payload bytes \(total), individual MainActor operation ms \(samples), worst \(samples.values.max()!)")
            var armed=false;store.historyFault={point in if point=="cleanup-plan-after-rename" {armed=true};if armed && point=="sync" {throw CocoaError(.fileWriteOutOfSpace)}}
            session.clearConversation()
            check(armed && session.activeChatID==original,"partial bounded cleanup plan has exact unverified Clear identity")
            let newer="New draft after some history payload cleanup e\u{301}";session.input=newer;store.historyFault=nil
            check(session.newChat() && session.openChat(original),"unverified post-cleanup Clear can save exact whole live RAM")
            let actual=try AskConversationStore(url:store.url).loadLibrary().chats.first {$0.id==original}
            check(actual?.conversation.turns.count==library.chats[0].conversation.turns.count && actual.map {Array($0.conversation.draft.utf8)==Array(newer.utf8)}==true,"supersession restages removed old blobs without stale-baseline restoration")
        }
        if selected==nil || selected=="disk" {
            let folder=root.appendingPathComponent("disk-parent"),url=folder.appendingPathComponent("chats.json")
            let session=try fixture.session(store:AskConversationStore(url:url));try await fixture.answer(session);session.flushHistory()
            let original=session.activeChatID,ids=session.turns.map(\.id),response=session.response
            // Preserve the disposable canonical bytes elsewhere, then make the actual
            // storage parent a regular file. No injected false-success store.
            try FileManager.default.moveItem(at:folder,to:root.appendingPathComponent("disk-prior-copy"))
            try Data("not a directory".utf8).write(to:folder)
            session.input="New unsaved draft after storage failed";session.flushHistory()
            let moved=session.newChat();check(moved,"real filesystem failure still allows safe RAM navigation")
            if moved {
                check(session.composerError?.localizedCaseInsensitiveContains("keep") == true,"unsaved warning survives screen reset")
                check(session.openChat(original) && session.input=="New unsaved draft after storage failed" && session.turns.map(\.id)==ids && session.response==response,"RAM fallback retains exact prior turn and new draft")
                check(session.composerError?.localizedCaseInsensitiveContains("not saved") == true,"RAM fallback never claims durable persistence")
            }
        }
        if selected==nil || selected=="draft" {
            let url=root.appendingPathComponent("draft.json"),store=AskConversationStore(url:url),session=try fixture.session(store:store)
            let draft=String(repeating:"oversized 🧭 é\n",count:600)+"END ";session.input=draft;session.flushHistory()
            let original=session.activeChatID,moved=session.newChat();check(moved,"oversized existing draft does not strand navigation")
            if moved {
                check(session.openChat(original) && Array(session.input.utf8)==Array(draft.utf8),"oversized draft is not prefixed or normalized")
                session.suspend();let restarted=try fixture.session(store:AskConversationStore(url:url))
                check(Array(restarted.input.utf8)==Array(draft.utf8) && restarted.turns.isEmpty,"preservation-only draft survives restart")
                restarted.run();check(!restarted.isLoading && restarted.turns.isEmpty && Array(restarted.input.utf8)==Array(draft.utf8),"preserved oversized draft does not relax request admission")
            }
        }
        precondition(failures.isEmpty,"History navigation regressions: \(failures.joined(separator:"; "))")
    }
}
