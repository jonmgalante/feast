import Foundation
import CoreData

@MainActor enum AskDeletedRecordProofTests {
    static func run(model:NSManagedObjectModel,directory:URL)throws {
        var failures:[String]=[]
        func check(_ value:Bool,_ label:String) {print("\(value ? "PASS" : "FAIL") deleted read proof: \(label)");if !value {failures.append(label)}}
        let f=try Fixture(model:model,directory:directory,name:"place"),city=try f.repository.createFeastList(named:"Accessible"),section=try f.repository.createListSection(named:"Original parent",in:city),place=try f.place(city,section:section)
        let placeID=place.id!,cityID=city.id!,action=try f.remove("place",placeID)
        check(try f.proof()==[placeID.uuidString],"own deleted place under visible same-store city has detail proof")
        check(try f.engine.recoveryDeletedRecordIDs(forTurn:UUID(),includingActionIDs:[action.id])==[placeID.uuidString],"explicit local receipt IDs use the same current proof")
        for mode in ["hidden-city","city-acl","section-acl","store"] {
            switch mode {case "hidden-city":f.hidden=[cityID];case "city-acl":f.denied=[city.objectID];case "section-acl":f.denied=[section.objectID];default:f.unrecoverable=true}
            check(try f.proof().isEmpty,"\(mode) revocation denies deleted detail proof")
            check(try AskCollectionChangeEngine(adapter:f.adapter,journalURL:f.url).recoveryDeletedRecordIDs(forTurn:f.turn).isEmpty,"\(mode) revocation remains denied after restart")
            let status=try f.engine.actionStatus(action.id)
            check(status.state == .applied && status.undoable,"\(mode) does not reinterpret generic receipt or Undo affordance")
            f.hidden=[];f.denied=[];f.unrecoverable=false
            check(try f.proof()==[placeID.uuidString],"\(mode) renewed authority restores proof without rewriting history")
        }
        let duplicate=FeastList(context:f.context);duplicate.id=cityID;duplicate.name="Duplicate UUID";try f.context.save()
        check(try f.proof().isEmpty,"duplicate original-city UUID is not positive authority")
        f.context.delete(duplicate);try f.context.save()
        check(try f.proof()==[placeID.uuidString],"removing ambiguity restores only the original parent proof")
        let other=try f.repository.createFeastList(named:"Another city")
        section.feastList=other;try f.context.save()
        check(try f.proof().isEmpty,"moved original neighborhood cannot borrow old city's authority")
        section.feastList=city;try f.context.save()
        f.visibilityFails=true
        var readFailed=false;do {_ = try f.proof()}catch {readFailed=true}
        check(readFailed,"failed current visibility read propagates, never grants absence authority")
        f.visibilityFails=false
        try f.repository.delete(section)
        check(try f.proof().isEmpty,"missing original neighborhood is not inferred readable")
        // Separate flat deletion retains no neighborhood dependency. Its missing
        // city still cannot be inferred from record absence or an applied state.
        let missing=try Fixture(model:model,directory:directory,name:"missing-city"),mc=try missing.repository.createFeastList(named:"Original"),mp=try missing.place(mc)
        let originalCityID=mc.id!,ma=try missing.remove("place",mp.id!)
        try missing.repository.delete(mc)
        check(try missing.proof().isEmpty,"externally removed city absent from receipt denies detail proof")
        let second=try missing.context.persistentStoreCoordinator!.addPersistentStore(ofType:NSSQLiteStoreType,configurationName:nil,at:directory.appendingPathComponent("proof-other-store.sqlite"))
        let replacement=FeastList(context:missing.context);missing.context.assign(replacement,to:second);replacement.id=originalCityID;replacement.name="Replacement";try missing.context.save()
        check(try missing.proof().isEmpty,"same UUID in a different store does not replace original parent authority")
        check((try missing.engine.actionStatus(ma.id)).state == .applied,"failed read proof preserves receipt authority")
        for mode in ["missing","read-only"] {
            let stores=try Fixture(model:model,directory:directory,name:"store-"+mode),sc=try stores.repository.createFeastList(named:"Store"),sp=try stores.place(sc)
            _ = try stores.remove("place",sp.id!)
            let coordinator=stores.context.persistentStoreCoordinator!,url=stores.store.url!
            stores.context.reset();try coordinator.remove(stores.store)
            if mode=="read-only" {
                let readOnly=try coordinator.addPersistentStore(ofType:NSSQLiteStoreType,configurationName:nil,at:url,options:[NSReadOnlyPersistentStoreOption:true])
                check(readOnly.isReadOnly,"read-only fixture uses a real read-only SQLite store")
            }
            check((try? stores.proof())?.isEmpty != false,"\(mode) original store cannot grant deleted detail access")
        }
        // The mutation outcome remains an exact whole-graph proof; current
        // read permission is per fragment, not a reason to erase unrelated data.
        let batch=try Fixture(model:model,directory:directory,name:"atomic-batch"),bc=try batch.repository.createFeastList(named:"Visible"),bd=try batch.repository.createFeastList(named:"Revoked")
        let bp=try batch.place(bc),bq=try batch.place(bd),ids=[bp.id!.uuidString,bq.id!.uuidString]
        _ = try batch.remove("place",ids:ids)
        batch.hidden=[bd.id!]
        check(try batch.proof()==[ids[0]],"revoked parent is excluded without hiding another permitted city")
        batch.hidden=[]
        check(try batch.proof()==Set(ids),"all original parents restore complete batch proof")
        // Whole owned-city deletion, including its complete original graph,
        // remains usable without an impossible surviving-city requirement.
        let whole=try Fixture(model:model,directory:directory,name:"whole-city"),wc=try whole.repository.createFeastList(named:"Owned"),ws=try whole.repository.createListSection(named:"Owned section",in:wc),wp=try whole.place(wc,section:ws)
        let wholePlaceID=wp.id!,wholeIDs=Set([wc.id!,ws.id!,wp.id!].map(\.uuidString)),wa=try whole.remove("city",wc.id!)
        check(try whole.proof()==wholeIDs,"verified whole owned-city deletion proves its complete same-store graph")
        whole.deniedCreates=["place"]
        check(try whole.proof()==wholeIDs.subtracting([wholePlaceID.uuidString]),"whole-city fragments require their own current entity-create authority")
        whole.deniedCreates=["city"]
        check(try whole.proof().isEmpty,"whole-city graph requires current city-create authority")
        whole.deniedCreates=[];whole.unrecoverable=true
        check(try whole.proof().isEmpty,"whole-city proof fails when its original store is no longer recoverable")
        whole.unrecoverable=false
        for malformed in ["store","parent","incomplete-section"] {
            let url=directory.appendingPathComponent("proof-legacy-\(malformed).json")
            try AskJournalTestSupport.legacyCopy(from:whole.engine,to:url) {entries in
                let index=entries.firstIndex {($0["id"] as? String)==wa.id.uuidString}!
                var before=entries[index]["before"] as! [[String:Any]]
                let placeIndex=before.firstIndex {$0["entity"] as? String == "SavedPlace"}!
                if malformed=="store" {before[placeIndex].removeValue(forKey:"store")}
                else if malformed=="parent" {var links=before[placeIndex]["links"] as! [String:String];links["feastList"]=UUID().uuidString;before[placeIndex]["links"]=links}
                else {before.removeAll {$0["entity"] as? String == "ListSection"}}
                entries[index]["before"]=before
            }
            let legacy=AskCollectionChangeEngine(adapter:whole.adapter,journalURL:url)
            check(try !legacy.recoveryDeletedRecordIDs(forTurn:whole.turn).contains(wholePlaceID.uuidString),"unknown legacy \(malformed) cannot authorize dependent place detail")
            check((try legacy.actionStatus(wa.id)).state == .applied,"unknown legacy \(malformed) does not rewrite the receipt")
        }
        _ = try whole.engine.performExplicitAction(wa.id,undo:true)
        check(try whole.proof().isEmpty,"restored whole-city data no longer uses deleted-record authority")
        let restored=try whole.repository.fetchSavedPlaces()
        check(Set(restored.compactMap(\.id))==[wholePlaceID],"owned whole-city Undo still restores its saved place")
        let nullified=try Fixture(model:model,directory:directory,name:"section-nullify"),nc=try nullified.repository.createFeastList(named:"City"),ns=try nullified.repository.createListSection(named:"Removed section",in:nc),np=try nullified.place(nc,section:ns)
        let sectionID=ns.id!,survivorID=np.id!
        _ = try nullified.remove("neighborhood",sectionID)
        check(try nullified.proof()==[sectionID.uuidString] && np.id==survivorID && np.listSection==nil,"section deletion proves only its removed ID, never nullified surviving places")
        for entity in ["place","neighborhood"] {
            let creator=try Fixture(model:model,directory:directory,name:"undo-create-"+entity),parent=try creator.repository.createFeastList(named:"Parent")
            let match=ApplePlaceMatch(applePlaceID:"proof-created-place",displayName:"Created place",secondaryText:"Parent",coordinate:nil,suggestedSectionPath:.init(cityOrRegion:"Parent",neighborhood:nil),websiteURL:nil,instagramURL:nil)
            let p=AskChangeProposal(entity:entity,operation:"create",targetIDs:[],cityID:parent.id!.uuidString,sectionID:nil,mapMatchID:entity=="place" ? match.id : nil,changes:entity=="place" ? [] : [.init(field:"name",value:"Created section",values:nil,findingID:nil)],instructionQuote:"Create this fixture")
            let g=creator.grant(p),ready=try creator.engine.prepare(p,question:p.instructionQuote,authorization:g,findings:[],turnID:creator.turn)
            let a=try creator.engine.apply(ready.id,authorization:g,maps:[match.id:match])
            _ = try creator.engine.performExplicitAction(a.id,undo:true)
            check(try creator.proof()==Set(a.targetIDs),"undone \(entity) creation has fresh surviving-parent proof")
            creator.hidden=[parent.id!]
            check(try creator.proof().isEmpty,"undone \(entity) creation loses detail proof after parent revocation")
        }
        let created=try Fixture(model:model,directory:directory,name:"undo-city-create")
        let cp=AskChangeProposal(entity:"city",operation:"create",targetIDs:[],cityID:nil,sectionID:nil,mapMatchID:nil,changes:[.init(field:"name",value:"Created",values:nil,findingID:nil)],instructionQuote:"Create this city")
        let cg=created.grant(cp),ready=try created.engine.prepare(cp,question:cp.instructionQuote,authorization:cg,findings:[],turnID:created.turn)
        let applied=try created.engine.apply(ready.id,authorization:cg)
        _ = try created.engine.performExplicitAction(applied.id,undo:true)
        check(try created.proof()==Set(applied.targetIDs),"undone owned-city creation retains legitimate deletion proof")
        created.deniedCreates=["city"]
        check(try created.proof().isEmpty,"undone creation cannot lend stale create authority")
        if !failures.isEmpty {throw NSError(domain:"AskDeletedRecordProof",code:1,userInfo:[NSLocalizedDescriptionKey:failures.joined(separator:"; ")])}
    }
    @MainActor private final class Fixture {
        let context:NSManagedObjectContext,repository:FeastRepository,store:NSPersistentStore,turn=UUID()
        var hidden=Set<UUID>(),denied=Set<NSManagedObjectID>(),deniedCreates=Set<String>()
        var unrecoverable=false,visibilityFails=false
        lazy var adapter=AskSavedCollection(context:context,canMutate:{[unowned self] entity,id,operation in
            if let id {return !self.denied.contains(id)}
            return operation=="create" && !self.deniedCreates.contains(entity)
        },canRecoverStore:{[unowned self] in !self.unrecoverable && $0==self.store.identifier},visibleCities:{[unowned self] in
            if self.visibilityFails {throw NSError(domain:"ProofVisibility",code:1)}
            return Set(try self.repository.fetchFeastLists().compactMap(\.id)).subtracting(self.hidden)
        })
        lazy var engine=AskCollectionChangeEngine(adapter:adapter,journalURL:url)
        let url:URL
        init(model:NSManagedObjectModel,directory:URL,name:String)throws {
            let coordinator=NSPersistentStoreCoordinator(managedObjectModel:model)
            store=try coordinator.addPersistentStore(ofType:NSSQLiteStoreType,configurationName:nil,at:directory.appendingPathComponent("deleted-proof-\(name).sqlite"))
            context=NSManagedObjectContext(concurrencyType:.mainQueueConcurrencyType);context.persistentStoreCoordinator=coordinator
            repository=FeastRepository(context:context);url=directory.appendingPathComponent("deleted-proof-\(name).json")
        }
        func place(_ city:FeastList,section:ListSection?=nil)throws->SavedPlace {try repository.createSavedPlace(from:.init(applePlaceID:UUID().uuidString,displayNameSnapshot:"Private fixture",status:.love,placeType:.restaurant,cuisines:[],tags:[],note:"Retained private fixture note",websiteURL:nil,instagramURL:nil,feastList:city,listSection:section))}
        func grant(_ p:AskChangeProposal)->AskChangeGrant {.init(question:p.instructionQuote,entity:p.entity,operations:[p.operation],fields:Set(p.changes.map(\.field)),targetIDs:Set(p.targetIDs),allowsCreation:p.operation=="create",cityIDs:Set(p.cityID.map {[$0]} ?? []),sectionIDs:Set(p.sectionID.map {[$0]} ?? []),mapMatchIDs:Set(p.mapMatchID.map {[$0]} ?? []),boundProposal:p)}
        func remove(_ entity:String,_ id:UUID)throws->AskCollectionAction {try remove(entity,ids:[id.uuidString])}
        func remove(_ entity:String,ids:[String])throws->AskCollectionAction {
            let p=AskChangeProposal(entity:entity,operation:"delete",targetIDs:ids,cityID:nil,sectionID:nil,mapMatchID:nil,changes:[],instructionQuote:"Delete this fixture"),g=grant(p)
            let a=try engine.prepare(p,question:p.instructionQuote,authorization:g,findings:[],turnID:turn)
            return try engine.apply(a.id,authorization:g,confirmed:true)
        }
        func proof()throws->Set<String> {try engine.recoveryDeletedRecordIDs(forTurn:turn)}
    }
}
