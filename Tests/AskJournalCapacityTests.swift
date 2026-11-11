import Foundation
import CoreData

/// Expected-correct regressions, first executed against the immutable v1 engine.
@MainActor enum AskJournalCapacityTests {
    static func run(model:NSManagedObjectModel,directory:URL)throws {
        var failures:[String]=[]
        func check(_ value:Bool,_ label:String) { print("\(value ? "PASS" : "FAIL") journal capacity: \(label)");if !value {failures.append(label)} }
        for mode in ["count","bytes","failed-admission"] {
            let f=try AskJournalFixture(model:model,directory:directory,name:mode)
            let early=try f.place("Earliest"),filler=try f.place("Filler",note:String(repeating:"n",count:mode=="bytes" ? 100_000 : 4000))
            let earliest=try f.commit(f.proposal(early,"Earliest changed"))
            let turn=UUID(),chat=UUID()
            var committed=1
            if mode=="failed-admission" {
                let prior=try f.engine.actionStatus(earliest.id)
                let bad=f.proposal(filler,"Oversize",quote:String(repeating:"q",count:9*1024*1024))
                var rejected=false
                do {_ = try f.engine.prepare(bad,question:bad.instructionQuote,authorization:f.grant(bad),findings:[])}catch {rejected=true}
                check(rejected,"oversized single entry is rejected before publication")
                check((try? f.engine.actionStatus(earliest.id))==prior,"failed prepare keeps the previous receipt")
                do {_ = try f.commit(f.proposal(filler,"Valid after failure"));check(true,"failed prepare does not poison later admission")}catch {check(false,"failed prepare does not poison later admission")}
            } else {
                let total=mode=="count" ? 1000 : 110
                for i in 2...total {
                    do {
                        _ = try f.commit(f.proposal(filler,"Iteration \(i)"),turn:turn,chat:chat);committed=i
                        if [199,200,201,1000].contains(i) {check(true,"action \(i) is durable")}
                    }catch {check(false,"\(mode) action \(i) is admitted: \(error)");break}
                }
                if mode=="count" {check(committed==1000,"1,000 complete durable actions")}
                else {check(committed==total,"aggregate payload above 8 MiB is retained")}
            }
            let restart=AskCollectionChangeEngine(adapter:f.adapter,journalURL:f.url)
            let started=Date()
            check((try? restart.latestAction(for:early.id!.uuidString))?.id==earliest.id,"\(mode) earliest Undo is reachable across restart")
            check(restart.journal.decodedPayloads<=2,"\(mode) latest target lookup does not decode history")
            print("METRIC journal \(mode): restart plus indexed lookup \(Date().timeIntervalSince(started)) seconds; decoded \(restart.journal.decodedPayloads) payloads")
            if mode=="bytes",committed==110 {check((try AskJournalTestSupport.scalar(restart.journal.databaseURL,"SELECT sum(length(payload)) FROM snapshots"))>8*1024*1024,"payload evidence exceeds 8 MiB") }
            do {_ = try restart.performExplicitAction(earliest.id,undo:true);check(early.displayNameSnapshot=="Earliest","\(mode) earliest Undo restores original value")}catch {check(false,"\(mode) earliest Undo succeeds: \(error)")}
            if mode != "failed-admission" {check((try? restart.receipts(forTurn:turn))?.count==committed-1,"\(mode) turn receipt ordering/count survives restart")}
            check(restart.journal.largestIDPage<=64,"\(mode) bounded ID pages")
            check(restart.journal.maximumTargetFullScanSteps==0,"\(mode) target lookup uses the ordered index without a table scan")
            if mode=="count" {
                let started=Date()
                for i in 0..<10 {
                    let writer=i%2==0 ? f.engine : restart,p=f.proposal(filler,"Other instance \(i)"),g=f.grant(p)
                    let a=try writer.prepare(p,question:p.instructionQuote,authorization:g,findings:[])
                    _ = try writer.apply(a.id,authorization:g)
                    check((try (i%2==0 ? restart : f.engine).actionStatus(a.id)).state == .applied,"multiple engines observe committed revision \(i)")
                }
                print("METRIC journal: ten alternating engine commits after 1,000 records \(Date().timeIntervalSince(started)) seconds")
            }
        }
        try largeUndo(model:model,directory:directory,check:check)
        if !failures.isEmpty {throw NSError(domain:"AskJournalCapacity",code:1,userInfo:[NSLocalizedDescriptionKey:failures.joined(separator:"; ")])}
    }
    private static func largeUndo(model:NSManagedObjectModel,directory:URL,check:(Bool,String)->Void)throws {
        let f=try AskJournalFixture(model:model,directory:directory,name:"six-large-notes")
        let places=try (0..<6).map {try f.place("Original \($0)",note:String(repeating:"n",count:500_000))}
        let proposal=AskChangeProposal(entity:"place",operation:"update",targetIDs:places.map {$0.id!.uuidString},cityID:nil,sectionID:nil,mapMatchID:nil,changes:[.init(field:"name",value:"Renamed",values:nil,findingID:nil)],instructionQuote:"Rename these six places")
        let action=try f.commit(proposal)
        let restart=AskCollectionChangeEngine(adapter:f.adapter,journalURL:f.url)
        _ = try restart.performExplicitAction(action.id,undo:true)
        check(places.enumerated().allSatisfy {$0.element.displayName=="Original \($0.offset)" && $0.element.note==String(repeating:"n",count:500_000)},"six preserved 500 KB notes survive rename and Undo beyond 8 MiB cumulative evidence")
        check((try AskJournalTestSupport.scalar(restart.journal.databaseURL,"SELECT sum(length(payload)) FROM snapshots"))>8*1024*1024,"all large before/after/Undo payloads remain durable")
        let huge=try AskJournalFixture(model:model,directory:directory,name:"unrepresentable-after"),hp=try huge.place("x",note:String(repeating:"n",count:8*1024*1024-700))
        let site="https://example.org/"+String(repeating:"a",count:1800)
        let impossible=AskChangeProposal(entity:"place",operation:"update",targetIDs:[hp.id!.uuidString],cityID:nil,sectionID:nil,mapMatchID:nil,changes:[.init(field:"website",value:site,values:nil,findingID:nil,source:"user")],instructionQuote:"Save this website")
        let ready=try huge.engine.prepare(impossible,question:impossible.instructionQuote,authorization:huge.grant(impossible),findings:[])
        var refused=false;do {_ = try huge.engine.apply(ready.id,authorization:huge.grant(impossible))}catch {refused=true}
        check(refused && hp.websiteURL==nil,"unrepresentable after evidence fails before any collection save")
        check((try huge.engine.actionStatus(ready.id)).state == .ready,"failed phase admission retains the previous durable preview")
        // A valid v1 committed deletion can have almost 8 MiB of before data,
        // including hundreds of absent updatedAt timestamps. Restoration adds
        // those timestamps. Its inverse budget must derive from the exact image,
        // not assume undoAfter <= before or refuse an already promised Undo.
        let legacy=try AskJournalFixture(model:model,directory:directory,name:"near-limit-legacy-delete")
        var original:[SavedPlace]=[]
        for i in 0..<250 {
            let p=SavedPlace(context:legacy.context);p.id=UUID();p.applePlaceID="legacy-\(i)";p.displayNameSnapshot="Legacy \(i)";p.feastList=legacy.city;p.placeStatus = .love;p.placeTypeValue = .restaurant
            original.append(p)
        }
        legacy.city.createdAt=nil;legacy.city.updatedAt=nil;try legacy.context.save()
        let deletion=AskChangeProposal(entity:"city",operation:"delete",targetIDs:[legacy.city.id!.uuidString],cityID:nil,sectionID:nil,mapMatchID:nil,changes:[],instructionQuote:"Delete this legacy fixture")
        let preview=try legacy.engine.prepare(deletion,question:deletion.instructionQuote,authorization:legacy.grant(deletion),findings:[])
        var entry=try legacy.engine.journal.withLock {try legacy.engine.journal.load(id:preview.id)!}
        entry.phase="committed";entry.action.state = .applied;entry.action.undoable=true;entry.action.committedChange=true
        let key=original[0].id!.uuidString,index=entry.before.firstIndex {$0.id==key}!,image=entry.before[index]
        var strings=image.strings;strings["note"]=""
        entry.before[index] = .init(entity:image.entity,id:image.id,store:image.store,strings:strings,dates:image.dates,links:image.links)
        let encoder=JSONEncoder(),base=try encoder.encode(AskChangeArchive(entries:[entry])).count
        let note=String(repeating:"z",count:8*1024*1024-base-64);strings["note"]=note
        entry.before[index] = .init(entity:image.entity,id:image.id,store:image.store,strings:strings,dates:image.dates,links:image.links)
        original[0].note=note;try legacy.context.save()
        let ids=Set(original.compactMap(\.id))
        try legacy.repository.delete(legacy.city)
        let legacyURL=directory.appendingPathComponent("near-limit-committed-v1.json")
        let bytes=try encoder.encode(AskChangeArchive(entries:[entry]));try bytes.write(to:legacyURL)
        check(bytes.count<8*1024*1024,"near-limit deleted graph is a valid bounded v1 archive")
        let migrated=AskCollectionChangeEngine(adapter:legacy.adapter,journalURL:legacyURL)
        _ = try migrated.performExplicitAction(preview.id,undo:true)
        let restored=try legacy.repository.fetchSavedPlaces()
        check(Set(restored.compactMap(\.id))==ids && restored.first {$0.id?.uuidString==key}?.note==note && restored.allSatisfy {$0.updatedAt != nil},"migrated near-limit deletion restores exact graph plus new timestamps")
        let restoredEntry=try migrated.journal.withLock {try migrated.journal.load(id:preview.id)!}
        let inverseBytes=try restoredEntry.undoAfter!.reduce(0) {$0 + (try encoder.encode($1).count)}
        check(inverseBytes>8*1024*1024,"derived inverse budget accommodates timestamp growth beyond one phase's initial bound")
    }

}

@MainActor final class AskJournalFixture {
    let context:NSManagedObjectContext,repository:FeastRepository,adapter:AskSavedCollection,city:FeastList,url:URL
    var engine:AskCollectionChangeEngine
    init(model:NSManagedObjectModel,directory:URL,name:String)throws {
        let coordinator=NSPersistentStoreCoordinator(managedObjectModel:model)
        let store=try coordinator.addPersistentStore(ofType:NSSQLiteStoreType,configurationName:nil,at:directory.appendingPathComponent("journal-\(name)-collection.sqlite"))
        context=NSManagedObjectContext(concurrencyType:.mainQueueConcurrencyType);context.persistentStoreCoordinator=coordinator
        repository=FeastRepository(context:context);city=try repository.createFeastList(named:"Journal fixture")
        let repository=self.repository
        adapter=AskSavedCollection(context:context,canMutate:{_,_,_ in true},canRecoverStore:{$0==store.identifier},visibleCities:{Set(try repository.fetchFeastLists().compactMap(\.id))})
        url=directory.appendingPathComponent("journal-\(name).json");engine=AskCollectionChangeEngine(adapter:adapter,journalURL:url)
    }
    func place(_ name:String,note:String?=nil)throws->SavedPlace {try repository.createSavedPlace(from:.init(applePlaceID:UUID().uuidString,displayNameSnapshot:name,status:.love,placeType:.restaurant,cuisines:[],tags:[],note:note,websiteURL:nil,instagramURL:nil,feastList:city,listSection:nil))}
    func proposal(_ place:SavedPlace,_ name:String,quote:String="Rename this fixture")->AskChangeProposal {.init(entity:"place",operation:"update",targetIDs:[place.id!.uuidString],cityID:nil,sectionID:nil,mapMatchID:nil,changes:[.init(field:"name",value:name,values:nil,findingID:nil)],instructionQuote:quote)}
    func grant(_ p:AskChangeProposal)->AskChangeGrant {.init(question:p.instructionQuote,entity:p.entity,operations:[p.operation],fields:Set(p.changes.map(\.field)),targetIDs:Set(p.targetIDs),allowsCreation:p.operation=="create",cityIDs:Set(p.cityID.map {[$0]} ?? []),sectionIDs:Set(p.sectionID.map {[$0]} ?? []),mapMatchIDs:Set(p.mapMatchID.map {[$0]} ?? []),boundProposal:p)}
    func commit(_ p:AskChangeProposal,turn:UUID?=nil,chat:UUID?=nil,key:String?=nil)throws->AskCollectionAction {let g=grant(p),a=try engine.prepare(p,question:p.instructionQuote,authorization:g,findings:[],turnID:turn,chatID:chat,recoveryOperationID:key);return try engine.apply(a.id,authorization:g,confirmed:true)}
}
