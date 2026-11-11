import Foundation
import CoreData
import Darwin

@MainActor enum AskJournalFailureTests {
    private static func injected()->NSError {NSError(domain:"JournalInjectedFault",code:1)}
    static func run(model:NSManagedObjectModel,directory:URL)throws {
        var failures:[String]=[]
        func check(_ value:Bool,_ label:String) {print("\(value ? "PASS" : "FAIL") journal safety: \(label)");if !value {failures.append(label)}}
        func rejected(_ label:String,_ body:()throws->Void) {do {try body();check(false,label)}catch {check(true,label)}}
        for point in ["apply-before-intent","apply-after-intent","apply-after-collection","undo-before-intent","undo-after-intent","undo-after-collection"] {
            let f=try AskJournalFixture(model:model,directory:directory,name:point),p=try f.place("Original")
            let proposal=f.proposal(p,"Changed"),g=f.grant(proposal)
            let ready=try f.engine.prepare(proposal,question:proposal.instructionQuote,authorization:g,findings:[])
            let isUndo=point.hasPrefix("undo")
            if isUndo {_ = try f.engine.apply(ready.id,authorization:g)}
            f.engine.journal.fault={if $0==point {throw injected()}}
            rejected("fault at \(point)") {if isUndo {_ = try f.engine.performExplicitAction(ready.id,undo:true)}else{_ = try f.engine.apply(ready.id,authorization:g)}}
            f.context.refreshAllObjects()
            let restart=AskCollectionChangeEngine(adapter:f.adapter,journalURL:f.url)
            let status=try restart.actionStatus(ready.id)
            let committed=point.hasSuffix("after-collection")
            check(status.state==(isUndo ? (committed ? .undone : .applied) : (committed ? .applied : .ready)),"\(point) restart reconciles actual collection outcome")
            if isUndo {_ = try restart.performExplicitAction(ready.id,undo:true);check(p.displayName=="Original","\(point) Undo completes exactly once")}
            else {_ = try restart.apply(ready.id,authorization:g);check(p.displayName=="Changed","\(point) apply completes exactly once")}
        }
        for undo in [false,true] {
            let f=try AskJournalFixture(model:model,directory:directory,name:"receipt-\(undo)"),p=try f.place("Original")
            let proposal=f.proposal(p,"Changed"),g=f.grant(proposal)
            let ready=try f.engine.prepare(proposal,question:proposal.instructionQuote,authorization:g,findings:[])
            if undo {_ = try f.engine.apply(ready.id,authorization:g)}
            var saved=false
            f.engine.journal.fault={point in
                if point==(undo ? "undo-after-collection" : "apply-after-collection") {saved=true}
                if saved && point=="write" {throw injected()}
            }
            let action=try undo ? f.engine.performExplicitAction(ready.id,undo:true) : f.engine.apply(ready.id,authorization:g)
            let revision=p.updatedAt
            check(action.state==(undo ? .undone : .applied),"final receipt failure truthfully returns \(undo ? "Undo" : "commit")")
            let restart=AskCollectionChangeEngine(adapter:f.adapter,journalURL:f.url)
            restart.journal.fault={if $0=="write" {throw injected()}}
            check((try restart.actionStatus(ready.id)).state==action.state,"restart with unwritable receipt reports the verified outcome")
            _ = try undo ? restart.performExplicitAction(ready.id,undo:true) : restart.apply(ready.id,authorization:g)
            check(p.updatedAt==revision && p.displayName==(undo ? "Original" : "Changed"),"unwritable receipt replay never repeats the collection write")
            restart.journal.fault=nil
            if !undo {_ = try restart.performExplicitAction(ready.id,undo:true);check(p.displayName=="Original","pending receipt remains undoable when storage recovers")}
        }
        let noop=try AskJournalFixture(model:model,directory:directory,name:"noop"),same=try noop.place("Unchanged")
        let noProposal=noop.proposal(same,"Unchanged"),noGrant=noop.grant(noProposal)
        let noReady=try noop.engine.prepare(noProposal,question:noProposal.instructionQuote,authorization:noGrant,findings:[])
        noop.engine.journal.fault={if $0=="apply-after-collection" {throw injected()}}
        rejected("interrupted no-op leaves a durable intent") {_ = try noop.engine.apply(noReady.id,authorization:noGrant)}
        let noRestart=AskCollectionChangeEngine(adapter:noop.adapter,journalURL:noop.url),noStatus=try noRestart.actionStatus(noReady.id)
        check(noStatus.state == .applied && !noStatus.undoable && !noStatus.wasChanged,"reconciled no-op never advertises a change or Undo")
        let failuresFixture=try AskJournalFixture(model:model,directory:directory,name:"write-failures"),old=try failuresFixture.place("Old"),new=try failuresFixture.place("New")
        let prior=try failuresFixture.commit(failuresFixture.proposal(old,"Old changed"))
        for point in ["write","before-commit","after-commit"] {
            let proposal=failuresFixture.proposal(new,"Fault \(point)")
            var fired=false
            failuresFixture.engine.journal.fault={if $0==point && !fired {fired=true;throw injected()}}
            var ready:AskCollectionAction?
            do {ready=try failuresFixture.engine.prepare(proposal,question:proposal.instructionQuote,authorization:failuresFixture.grant(proposal),findings:[])}catch {}
            failuresFixture.engine.journal.fault=nil
            check((ready != nil)==(point=="after-commit"),"\(point) admission reflects the reconciled SQL commit, never an optimistic cache")
            check((try failuresFixture.engine.actionStatus(prior.id)).state == .applied,"\(point) retains previous receipt")
        }
        let nearProposal=failuresFixture.proposal(new,"Near metadata limit")
        let nearAction=AskCollectionAction(id:UUID(),title:"Metadata fixture",targetIDs:nearProposal.targetIDs,entity:"place",operation:"update",state:.ready,undoable:false)
        var nearEntry=AskChangeEntry(id:nearAction.id,proposal:nearProposal,action:nearAction,before:[],after:[],phase:"prepared",question:"")
        let base=try JSONEncoder().encode(nearEntry).count
        nearEntry.question=String(repeating:"m",count:8*1024*1024-base-20)
        rejected("admission reserves future dismissal/receipt metadata, not only prepared bytes") {try failuresFixture.engine.journal.withLock {try failuresFixture.engine.journal.insert(nearEntry)}}
        try failuresFixture.engine.journal.withLock {try failuresFixture.engine.journal.testMaximumPages()}
        let full=failuresFixture.proposal(new,"Disk full",quote:String(repeating:"q",count:1_000_000))
        rejected("real SQLite SQLITE_FULL rejects only new admission") {_ = try failuresFixture.engine.prepare(full,question:full.instructionQuote,authorization:failuresFixture.grant(full),findings:[])}
        check((try failuresFixture.engine.actionStatus(prior.id)).state == .applied,"SQLITE_FULL preserves earlier receipt reads")
        try failuresFixture.engine.journal.withLock {try failuresFixture.engine.journal.testMaximumPages(1_000_000)}
        _ = try failuresFixture.engine.performExplicitAction(prior.id,undo:true)
        check(old.displayName=="Old","SQLITE_FULL does not poison later Undo")
        try migration(model:model,directory:directory,check:check,rejected:rejected)
        try corruption(model:model,directory:directory,check:check,rejected:rejected)
        try lifecycle(model:model,directory:directory,check:check,rejected:rejected)
        try metadataLifecycle(model:model,directory:directory,check:check,rejected:rejected)
        if !failures.isEmpty {throw NSError(domain:"AskJournalFailureTests",code:1,userInfo:[NSLocalizedDescriptionKey:failures.joined(separator:"; ")])}
    }
    private static func migration(model:NSManagedObjectModel,directory:URL,check:(Bool,String)->Void,rejected:(String,()throws->Void)->Void)throws {
        let source=try AskJournalFixture(model:model,directory:directory,name:"migration-source"),p=try source.place("Migration")
        let turn=UUID(),chat=UUID(),key=String(repeating:"a",count:64)
        let committed=try source.commit(source.proposal(p,"Migrated"),turn:turn,chat:chat,key:key)
        let draft=source.proposal(p,"Prepared")
        _ = try source.engine.prepare(draft,question:draft.instructionQuote,authorization:source.grant(draft),findings:[],turnID:turn,chatID:chat)
        try source.engine.dismissRecovery(in:chat)
        for empty in [false,true] {
            for point in ["file-write","file-sync","directory-sync","migration-backup","migration-before-commit","migration-database","migration-activated","activation-directory-sync"] {
                let url=directory.appendingPathComponent("migration-\(empty)-\(point).json")
                if empty {try JSONEncoder().encode(AskChangeArchive()).write(to:url)}else{try AskJournalTestSupport.legacyCopy(from:source.engine,to:url)}
                let bytes=try Data(contentsOf:url),engine=AskCollectionChangeEngine(adapter:source.adapter,journalURL:url)
                var fired=false
                engine.journal.fault={boundary in
                    let activationSync=point=="activation-directory-sync" && boundary=="directory-sync" && ((try? JSONDecoder().decode(AskChangeArchive.self,from:Data(contentsOf:url)).version)==2)
                    if !fired && (boundary==point || activationSync) {fired=true;throw injected()}
                }
                rejected("\(empty ? "empty" : "populated") migration interruption at \(point)") {_ = try engine.receipts(forTurn:turn)}
                let restart=AskCollectionChangeEngine(adapter:source.adapter,journalURL:url)
                if point=="activation-directory-sync" {
                    restart.journal.fault={if $0=="directory-sync" {throw injected()}}
                    rejected("visible activation must resynchronize before use") {_ = try restart.receipts(forTurn:turn)}
                    restart.journal.fault=nil
                }
                let receipts=try restart.receipts(forTurn:turn)
                check(receipts.map(\.id)==(empty ? [] : [committed.id]),"\(point) migration resumes with exact IDs and order")
                check(try Data(contentsOf:restart.journal.backupURL)==bytes,"\(point) immutable v1 backup matches exact source")
                check((try JSONDecoder().decode(AskChangeArchive.self,from:Data(contentsOf:url))).version != 1,"\(point) old-reader marker fails closed")
                let again=AskCollectionChangeEngine(adapter:source.adapter,journalURL:url)
                check((try again.receipts(forTurn:turn)).map(\.id)==receipts.map(\.id),"\(point) repeated migration does not duplicate records")
                check((try again.recoverableTurns(in:chat)).isEmpty,"\(point) dismissed recovery presentation stays dismissed")
            }
        }
        let staleURL=directory.appendingPathComponent("migration-stale.json")
        try AskJournalTestSupport.legacyCopy(from:source.engine,to:staleURL)
        let original=try Data(contentsOf:staleURL),migrated=AskCollectionChangeEngine(adapter:source.adapter,journalURL:staleURL)
        _ = try migrated.receipts(forTurn:turn)
        let extra=source.proposal(p,"Stale-launch sentinel")
        _ = try migrated.prepare(extra,question:extra.instructionQuote,authorization:source.grant(extra),findings:[])
        try original.write(to:staleURL,options:.atomic)
        rejected("existing engine detects a stale v1 marker overwrite") {_ = try migrated.receipts(forTurn:turn)}
        rejected("restart never reimports stale v1 after v2 writes") {_ = try AskCollectionChangeEngine(adapter:source.adapter,journalURL:staleURL).receipts(forTurn:turn)}
        check((try AskJournalTestSupport.scalar(migrated.journal.databaseURL,"SELECT count(*) FROM actions"))==3,"stale launch never replaces durable v2 history")
    }
    private static func corruption(model:NSManagedObjectModel,directory:URL,check:(Bool,String)->Void,rejected:(String,()throws->Void)->Void)throws {
        let cases:[(String,String)]=[
            ("payload","UPDATE actions SET payload=x'00'"),
            ("snapshot","UPDATE snapshots SET payload=x'00'"),
            ("snapshot-same-length","UPDATE snapshots SET payload=zeroblob(length(payload))"),
            ("missing-snapshot","DELETE FROM snapshots"),
            ("image-reference","DELETE FROM action_images WHERE phase='before'"),
            ("missing-row","DELETE FROM targets; DELETE FROM actions"),
            ("missing-index","DROP INDEX actions_turn"),
            ("recovery-key","UPDATE actions SET recovery_key=NULL"),
            ("turn","UPDATE actions SET turn_id=NULL"),
            ("chat","UPDATE actions SET chat_id=NULL"),
            ("target","UPDATE targets SET target='00000000-0000-0000-0000-000000000000'"),
            ("revision","UPDATE actions SET revision=revision+1"),
            ("database-id","UPDATE journal_meta SET database_id='00000000-0000-0000-0000-000000000000'"),
            ("generation","UPDATE journal_meta SET generation=generation+1")]
        for (name,sql) in cases {
            let f=try AskJournalFixture(model:model,directory:directory,name:"corrupt-"+name),p=try f.place("Original"),turn=UUID(),chat=UUID(),key=String(repeating:"b",count:64)
            let proposal=f.proposal(p,"Changed"),action=try f.commit(proposal,turn:turn,chat:chat,key:key)
            let oldValue=p.displayName,revision=p.updatedAt
            try AskJournalTestSupport.sql(f.engine.journal.databaseURL,sql)
            for engine in [f.engine,AskCollectionChangeEngine(adapter:f.adapter,journalURL:f.url)] {
                rejected("\(name) corruption cannot hide/replay recovery authority") {_ = try engine.prepare(proposal,question:proposal.instructionQuote,authorization:f.grant(proposal),findings:[],turnID:turn,chatID:chat,recoveryOperationID:key)}
                rejected("\(name) corruption does not produce an empty turn") {_ = try engine.receipts(forTurn:turn)}
                rejected("\(name) corruption does not hide indexed Undo") {_ = try engine.latestAction(for:p.id!.uuidString)}
            }
            check(p.displayName==oldValue && p.updatedAt==revision,"\(name) corruption does not modify Core Data")
            _ = action
        }
        for component in ["database","marker","manifest"] {
            let f=try AskJournalFixture(model:model,directory:directory,name:"missing-"+component),p=try f.place("Original")
            let action=try f.commit(f.proposal(p,"Changed"))
            let path=component=="database" ? f.engine.journal.databaseURL : component=="marker" ? f.url : f.engine.journal.directory.appendingPathComponent("migration.json")
            try FileManager.default.moveItem(at:path,to:path.appendingPathExtension("retained-missing-fixture"))
            let restart=AskCollectionChangeEngine(adapter:f.adapter,journalURL:f.url)
            rejected("missing \(component) never becomes an empty journal") {_ = try restart.actionStatus(action.id)}
            check(p.displayName=="Changed","missing \(component) leaves collection intact")
        }
    }
    private static func lifecycle(model:NSManagedObjectModel,directory:URL,check:(Bool,String)->Void,rejected:(String,()throws->Void)->Void)throws {
        let f=try AskJournalFixture(model:model,directory:directory,name:"lifecycle"),p=try f.place("Original"),turn=UUID(),chat=UUID(),key=String(repeating:"c",count:64)
        let proposal=f.proposal(p,"Changed"),action=try f.commit(proposal,turn:turn,chat:chat,key:key)
        try f.engine.dismissRecovery(in:chat)
        check((try f.engine.recoverableTurns(in:chat)).isEmpty,"chat deletion suppresses presentation, not history")
        check((try f.engine.latestAction(for:p.id!.uuidString))?.id==action.id,"deleted chat keeps globally reachable Undo")
        let replay=try f.engine.prepare(proposal,question:proposal.instructionQuote,authorization:f.grant(proposal),findings:[],turnID:turn,chatID:chat,recoveryOperationID:key)
        check(replay.id==action.id,"deleted chat keeps running-recovery replay fence")
        for (otherTurn,otherChat) in [(UUID(),chat),(turn,UUID())] {rejected("recovery key rejects changed owner turn/chat") {_ = try f.engine.prepare(proposal,question:proposal.instructionQuote,authorization:f.grant(proposal),findings:[],turnID:otherTurn,chatID:otherChat,recoveryOperationID:key)}}
        let old=try f.engine.journal.withLock {try f.engine.journal.load(id:action.id)!}
        try f.engine.dismissRecovery(in:chat)
        rejected("stale revision cannot overwrite later dismissal") {try f.engine.journal.withLock {_ = try f.engine.journal.replace(old,expectedPhase:old.phase)}}
        check((try f.engine.recoverableTurns(in:chat)).isEmpty,"failed CAS leaves dismissal and receipt intact")
        // Separate executable processes exercise actual advisory locking and
        // abrupt death with a durable intent on either side of the Core Data save.
        for point in ["apply-after-intent","apply-after-collection"] {
            let childPlace=try f.place("Child original"),cp=f.proposal(childPlace,"Child changed")
            let ready=try f.engine.prepare(cp,question:cp.instructionQuote,authorization:f.grant(cp),findings:[])
            let process=Process(),pipe=Pipe()
            process.executableURL=URL(fileURLWithPath:CommandLine.arguments[0])
            process.arguments=["--journal-crash-child",CommandLine.arguments[1],f.context.persistentStoreCoordinator!.persistentStores[0].url!.path,f.url.path,ready.id.uuidString,point]
            process.standardOutput=pipe;process.standardError=FileHandle.nullDevice
            try process.run()
            let signal=pipe.fileHandleForReading.readData(ofLength:7)
            guard String(data:signal,encoding:.utf8)=="LOCKED\n" else {process.terminate();process.waitUntilExit();throw injected()}
            let started=Date()
            rejected("second process cannot reconcile an in-flight \(point)") {_ = try f.engine.actionStatus(ready.id)}
            check(Date().timeIntervalSince(started)<1,"contended process lock fails promptly without hanging UI")
            process.terminate();process.waitUntilExit();f.context.refreshAllObjects()
            let restart=AskCollectionChangeEngine(adapter:f.adapter,journalURL:f.url),status=try restart.actionStatus(ready.id)
            check(status.state==(point=="apply-after-intent" ? .ready : .applied),"killed process releases lock and reconciles \(point)")
            _ = try restart.apply(ready.id,authorization:f.grant(cp))
            check(childPlace.displayName=="Child changed","process-death recovery applies once")
        }
    }
    private static func metadataLifecycle(model:NSManagedObjectModel,directory:URL,check:(Bool,String)->Void,rejected:(String,()throws->Void)->Void)throws {
        let f=try AskJournalFixture(model:model,directory:directory,name:"metadata-lifecycle"),place=try f.place("Original"),chat=UUID()
        let proposal=f.proposal(place,"Changed"),template=try f.engine.prepare(proposal,question:proposal.instructionQuote,authorization:f.grant(proposal),findings:[],chatID:chat)
        var entry=try f.engine.journal.withLock {try f.engine.journal.load(id:template.id)!}
        entry.before=[];entry.after=[];entry.undoAfter=[];entry.phase="undo-intent"
        entry.action.state = .needsConfirmation;entry.action.undoable=false;entry.action.committedChange=false
        let encoder=JSONEncoder();encoder.outputFormatting = .sortedKeys
        @MainActor func question(reservingDismissal:Bool)throws->String {
            var sized=entry;sized.recoveryDismissed=reservingDismissal ? false : nil
            let remaining=8*1024*1024-(try encoder.encode(sized).count)
            return String(repeating:"m",count:remaining)+proposal.instructionQuote
        }
        func grant(_ question:String)->AskChangeGrant {.init(question:question,entity:proposal.entity,operations:[proposal.operation],fields:["name"],targetIDs:Set(proposal.targetIDs),allowsCreation:false,boundProposal:proposal)}
        let rejectedQuestion=try question(reservingDismissal:false)
        let tooTight=AskCollectionChangeEngine(adapter:f.adapter,journalURL:directory.appendingPathComponent("metadata-too-tight.json"))
        rejected("formerly exact-bound metadata is refused before committing an Undo promise") {_ = try tooTight.prepare(proposal,question:rejectedQuestion,authorization:grant(rejectedQuestion),findings:[],chatID:chat)}
        let safeQuestion=try question(reservingDismissal:true),safe=AskCollectionChangeEngine(adapter:f.adapter,journalURL:directory.appendingPathComponent("metadata-safe.json"))
        let ready=try safe.prepare(proposal,question:safeQuestion,authorization:grant(safeQuestion),findings:[],chatID:chat)
        _ = try safe.apply(ready.id,authorization:grant(safeQuestion))
        try safe.dismissRecovery(in:chat)
        _ = try safe.performExplicitAction(ready.id,undo:true)
        let stored=try safe.journal.withLock {try safe.journal.load(id:ready.id)!}
        check(place.displayName=="Original" && stored.question==safeQuestion && stored.phase=="undone" && stored.recoveryDismissed==true,"exact-bound admitted metadata survives commit, chat dismissal and Undo losslessly")
    }
    static func child()throws {
        let model=NSManagedObjectModel(contentsOf:URL(fileURLWithPath:CommandLine.arguments[2]))!,coordinator=NSPersistentStoreCoordinator(managedObjectModel:model)
        let store=try coordinator.addPersistentStore(ofType:NSSQLiteStoreType,configurationName:nil,at:URL(fileURLWithPath:CommandLine.arguments[3]))
        let context=NSManagedObjectContext(concurrencyType:.mainQueueConcurrencyType);context.persistentStoreCoordinator=coordinator
        let repo=FeastRepository(context:context),adapter=AskSavedCollection(context:context,canMutate:{_,_,_ in true},canRecoverStore:{$0==store.identifier},visibleCities:{Set(try repo.fetchFeastLists().compactMap(\.id))})
        let engine=AskCollectionChangeEngine(adapter:adapter,journalURL:URL(fileURLWithPath:CommandLine.arguments[4]))
        engine.journal.fault={if $0==CommandLine.arguments[6] {print("LOCKED");fflush(stdout);sleep(30)}}
        _ = try engine.performExplicitAction(UUID(uuidString:CommandLine.arguments[5])!,undo:false)
    }
}
