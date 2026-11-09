import Foundation
import CoreData

/// Synthetic-only transport. Never calls a provider or touches a real collection.
private actor PlaceReferencePlanner: AskFeastProvider, AskAgentPlanning, AskBusinessResearching, AskConversationPlanning {
    nonisolated let label="Reference regression fixture"
    let text:String
    var seen:[AskConversationStep]=[]
    let calls:[AskAgentReply.Call]
    let selector:AskAgentSelector?
    let allowUnnamedAuthorization:Bool
    var authorizations=0
    init(text:String,calls:[AskAgentReply.Call]=[],selector:AskAgentSelector?=nil,allowUnnamedAuthorization:Bool=false) {self.text=text;self.calls=calls;self.selector=selector;self.allowUnnamedAuthorization=allowUnnamedAuthorization}
    func agentAvailable()async->Bool {true}
    func publicLookupAvailable()async->Bool {false}
    func conversationAvailable()async->Bool {true}
    func answer(_ request:AskRequest,tools:AskReadTools)async throws->AskResponse {preconditionFailure("Unexpected fallback")}
    func agentStep(_ step:AskAgentStep)async throws->AskAgentReply {preconditionFailure("Unexpected legacy loop")}
    func businessResearch(_ request:AskBusinessRequest)async throws->AskBusinessResult {preconditionFailure("No external research")}
    func searchConversationWeb(_ query:String)async throws->AskWebResearchResult {preconditionFailure("No external search")}
    func conversationStep(_ step:AskConversationStep)async throws->AskConversationReply {
        seen.append(step)
        let call=step.step<calls.count ? calls[step.step] : nil
        return .init(version:9,requestID:step.requestID,step:step.step,kind:call==nil ? "answer" : "tool",text:call==nil ? text : "",continuation:"synthetic",model:"gpt-6-astra",call:call)
    }
    func authorizePendingConfirmation(_ actions:[AskCollectionAction],question:String,history:[String])async throws->AskHumanAuthorization {preconditionFailure("Unexpected pending confirmation")}
    func authorizeConversationChange(_ proposal:AskChangeProposal,question:String,history:[String],targets:[AskAgentRecord])async throws->AskHumanAuthorization {
        precondition(selector != nil || allowUnnamedAuthorization,"Unexpected mutation")
        authorizations += 1
        return .init(approved:true,replaceExisting:false,deleteContents:false,reason:"explicit_instruction",targetSelector:selector)
    }
    func steps()->[AskConversationStep] {seen}
}
@MainActor enum AskPlaceReferenceTests {
    static func run(model:NSManagedObjectModel,temporaryDirectory:URL)async throws {
        let coordinator=NSPersistentStoreCoordinator(managedObjectModel:model)
        let store=try coordinator.addPersistentStore(ofType:NSSQLiteStoreType,configurationName:nil,at:temporaryDirectory.appendingPathComponent("place-references.sqlite"))
        let context=NSManagedObjectContext(concurrencyType:.mainQueueConcurrencyType);context.persistentStoreCoordinator=coordinator
        let repository=FeastRepository(context:context),city=try repository.createFeastList(named:"Synthetic City")
        var places:[SavedPlace]=[]
        for i in 0..<260 {
            places.append(try repository.createSavedPlace(from:.init(applePlaceID:"reference-fixture-\(i)",displayNameSnapshot:"Synthetic Cafe \(i)",status:.wantToTry,placeType:.restaurant,cuisines:[],tags:["Keep"],note:"Unchanged synthetic note",websiteURL:nil,instagramURL:nil,feastList:city,listSection:nil)))
        }
        var visible:Set<UUID>=[city.id!]
        let adapter=AskSavedCollection(context:context,canMutate:{_,_,_ in true},canRecoverStore:{$0==store.identifier},visibleCities:{visible})
        let engine=AskCollectionChangeEngine(adapter:adapter,journalURL:temporaryDirectory.appendingPathComponent("place-reference-actions.json"))
        let base=AskRequest(mode:.collection,text:"Find Instagram URLs for the first 3 on that list",fromOCR:false)
        let snapshot=try adapter.librarySnapshot(),catalog=try AskSemanticContext.make(base,catalog:snapshot)
        let sampled=Set(catalog.index.map(\.id)),outside=places.first {!sampled.contains($0.id!.uuidString)}!.id!.uuidString
        let ids=[catalog.index[0].id,catalog.index[1].id,outside]
        let text=ids.enumerated().map {"\($0.offset+1). [[place:\($0.element)]]: https://www.instagram.com/synthetic\($0.offset)/"}.joined(separator:"\n")
        var request=base;request.agentTask = .init(action:"query",fields:[],orderedIDs:ids,sourcePolicy:"public_if_missing")
        let tools=try AskReadTools(request:request,index:adapter.readView().index)
        let remote=PlaceReferencePlanner(text:text)
        let provider=AskAgentProvider(remote:remote,fallback:remote,adapter:adapter,engine:engine,searchMaps:{_ in []})
        var response=try await provider.answer(request,tools:tools)
        let displayed=response.paragraphs.flatMap(\.spans).compactMap {span->String? in if case .place(let id)=span{return id};return nil}
        precondition(displayed==ids && response.agentTask?.orderedIDs==ids && response.agentTask?.referencesIncomplete != true)
        _ = try tools.checked(response)
        let steps=await remote.steps();precondition(steps.count==1 && steps[0].context.index==catalog.index)
        precondition(!steps[0].context.index.contains {$0.id==outside},"Hydration must not expand prompt catalog")
        print("PASS previous three exact IDs render and retain order even when the third is outside the prompt catalog; no extra model/search call")

        // Exercise the real session archive -> follow-up -> provider -> independent
        // authorization -> per-record changes/receipts. Three different URLs, no name matching.
        let byID=Dictionary(uniqueKeysWithValues:snapshot.places.map {($0.id,$0)})
        let findings=ids.enumerated().map {index,id in AskVerifiedFinding(id:UUID(),recordID:id,identity:.init(byID[id]!),field:"instagram",value:"https://www.instagram.com/synthetic\(index)/",evidenceURL:"https://example.org/synthetic\(index)",verification:"cited_search",originatingTurn:UUID(),externallyReusable:true)}
        response.verifiedPublicFindings=findings
        let question="Add those 3 URLs to their respective saved locations"
        func proposal(_ index:Int)->AskAgentReply.Call {
            let value=AskChangeProposal(entity:"place",operation:"update",targetIDs:[ids[index]],cityID:nil,sectionID:nil,mapMatchID:nil,changes:[.init(field:"instagram",value:nil,values:nil,findingID:findings[index].id.uuidString,source:"verified_finding")],instructionQuote:question)
            return .init(name:"propose_changes",callID:"save-\(index)",arguments:String(data:try! JSONEncoder().encode(value),encoding:.utf8)!)
        }
        let previous=AskAgentSelector(city:nil,name:nil,neighborhood:nil,cuisine:nil,status:nil,placeType:nil,scope:"previous",positions:[1,2,3])
        let writer=PlaceReferencePlanner(text:"Saved the three Instagram profiles.",calls:(0..<3).map(proposal),selector:previous)
        let writeProvider=AskAgentProvider(remote:writer,fallback:writer,adapter:adapter,engine:engine,searchMaps:{_ in []})
        let archive=AskConversationStore(url:temporaryDirectory.appendingPathComponent("reference-history.json"))
        precondition(archive.save(.init(turns:[AskArchivedTurn(.init(id:UUID(),request:request,response:response,status:.complete))])))
        let session=AskSession(index:try adapter.readView().index,provider:writeProvider)
        session.restoreHistory(from:archive);session.mode = .collection;session.input=question;session.run()
        while session.isLoading {try await Task.sleep(nanoseconds:1_000_000)}
        precondition(session.turns.last?.status == .complete,"Follow-up must complete")
        let saved=session.response!,savedActions=saved.collectionActions ?? []
        precondition(savedActions.count==3 && savedActions.allSatisfy {$0.state == .applied && $0.undoable})
        precondition(session.turns.last?.request.agentTask?.orderedIDs==ids)
        let writes=await writer.steps();precondition(writes.count==4)
        for (index,id) in ids.enumerated() {precondition(places.first {$0.id!.uuidString==id}!.instagramURL==findings[index].value)}
        precondition(places.allSatisfy {$0.note=="Unchanged synthetic note" && $0.tags==["Keep"]})
        for action in savedActions {
            let p=AskChangeProposal(entity:"place",operation:"undo",targetIDs:action.targetIDs,cityID:nil,sectionID:nil,mapMatchID:nil,changes:[],instructionQuote:"Undo")
            let grant=AskChangeGrant(question:"Undo",entity:"place",operations:["undo"],fields:[],targetIDs:Set(action.targetIDs),allowsCreation:false,boundProposal:p)
            _ = try engine.undo(action.id,authorization:grant)
        }
        precondition(places.allSatisfy {$0.instagramURL==nil})
        print("PASS archived session follow-up saves the three distinct URLs to exact records with individual receipts and Undo; no unrelated field changes")

        // Existing saved values still need review; partial completion stays truthful.
        let first=places.first {$0.id!.uuidString==ids[0]}!
        first.instagramURL="https://www.instagram.com/existing/";try context.save()
        var followup=AskRequest(mode:.collection,text:question,fromOCR:false,verifiedFindings:findings,agentTask:response.agentTask)
        let existingExecutor=AskAgentExecutor(adapter:adapter,engine:engine,request:followup,researcher:remote,searchMaps:{_ in []})
        let needsReview=try await existingExecutor.executeConversation(proposal(0),planner:writer)
        precondition(needsReview.output.status=="needs_confirmation" && first.instagramURL=="https://www.instagram.com/existing/")
        first.instagramURL=nil;try context.save()
        let blocked=places.first {$0.id!.uuidString==ids[1]}!.objectID
        let partialAdapter=AskSavedCollection(context:context,canMutate:{_,id,_ in id != blocked},canRecoverStore:{$0==store.identifier},visibleCities:{[city.id!]})
        let partialEngine=AskCollectionChangeEngine(adapter:partialAdapter,journalURL:temporaryDirectory.appendingPathComponent("reference-partial-actions.json"))
        let partialRemote=PlaceReferencePlanner(text:"Saved all three.",calls:(0..<3).map(proposal),selector:previous)
        let partialProvider=AskAgentProvider(remote:partialRemote,fallback:partialRemote,adapter:partialAdapter,engine:partialEngine,searchMaps:{_ in []})
        let partial=try await partialProvider.answer(followup,tools:tools)
        let partialActions=partial.collectionActions ?? []
        precondition(partialActions.count==1 && partialActions[0].targetIDs==[ids[0]] && partialActions[0].state == .applied)
        precondition(first.instagramURL==findings[0].value && places.first {$0.id!.uuidString==ids[1]}!.instagramURL==nil && places.first {$0.id!.uuidString==ids[2]}!.instagramURL==nil)
        precondition(!partial.paragraphs.flatMap(\.spans).contains(.text("Saved all three.")))
        let undoPartial=AskChangeProposal(entity:"place",operation:"undo",targetIDs:[ids[0]],cityID:nil,sectionID:nil,mapMatchID:nil,changes:[],instructionQuote:"Undo")
        _ = try partialEngine.undo(partialActions[0].id,authorization:.init(question:"Undo",entity:"place",operations:["undo"],fields:[],targetIDs:[ids[0]],allowsCreation:false,boundProposal:undoPartial))
        // A retained value for a different saved identity cannot become a write.
        var wrong=findings;wrong[0] = .init(id:findings[0].id,recordID:ids[0],identity:.init(byID[ids[2]]!),field:"instagram",value:findings[0].value,evidenceURL:findings[0].evidenceURL,verification:"cited_search",originatingTurn:UUID(),externallyReusable:true)
        followup.verifiedFindings=wrong
        let staleSource=AskAgentExecutor(adapter:adapter,engine:engine,request:followup,researcher:remote,searchMaps:{_ in []})
        do {_ = try await staleSource.executeConversation(proposal(0),planner:writer);preconditionFailure("Mismatched finding identity saved")}catch {}
        precondition(places.allSatisfy {$0.instagramURL==nil})
        print("PASS existing-value review, permission-denied partial save, truthful receipt/Undo and mismatched-source rejection are unchanged")

        // A stale identity stays in its ordinal slot; no reduced two-item fallback.
        let missing=UUID().uuidString
        let incompleteText="1. [[place:\(ids[0])]]\n2. [[place:\(missing)]]\n3. [[place:\(ids[2])]]"
        let absentPlanner=PlaceReferencePlanner(text:incompleteText)
        let absent=try await AskConversationLoop(planner:absentPlanner,availableCandidates:tools.localCandidates(Set(ids)),execute:{_ in preconditionFailure()}).answer(request,context:catalog,cities:[],findings:[])
        precondition(absent.agentTask?.orderedIDs==[ids[0],missing,ids[2]] && absent.agentTask?.referencesIncomplete==true)
        precondition(!absent.paragraphs.flatMap(\.spans).contains(.text("a place that is no longer available")))
        var unsafe=AskRequest(mode:.collection,text:question,fromOCR:false,verifiedFindings:findings,agentTask:absent.agentTask)
        let stopped=AskAgentExecutor(adapter:adapter,engine:engine,request:unsafe,researcher:remote,searchMaps:{_ in []})
        let rejected=try await stopped.executeConversation(proposal(0),planner:writer)
        precondition(rejected.output.status=="needs_confirmation" && rejected.output.complete==false && places.allSatisfy {$0.instagramURL==nil})
        let nilSelector=PlaceReferencePlanner(text:"",allowUnnamedAuthorization:true)
        let rejectedNil=try await stopped.executeConversation(proposal(0),planner:nilSelector)
        precondition(rejectedNil.output.status=="needs_confirmation" && places.allSatisfy {$0.instagramURL==nil})
        let named=AskAgentSelector(city:"Synthetic City",name:byID[ids[0]]!.name,neighborhood:nil,cuisine:nil,status:nil,placeType:nil,scope:"library",positions:[])
        let namedPlanner=PlaceReferencePlanner(text:"",selector:named)
        let namedQuestion="Save the Instagram URL to "+byID[ids[0]]!.name+" in Synthetic City"
        let namedRequest=AskRequest(mode:.collection,text:namedQuestion,fromOCR:false,verifiedFindings:findings,agentTask:absent.agentTask)
        let namedExecutor=AskAgentExecutor(adapter:adapter,engine:engine,request:namedRequest,researcher:remote,searchMaps:{_ in []})
        let namedProposal=AskChangeProposal(entity:"place",operation:"update",targetIDs:[ids[0]],cityID:nil,sectionID:nil,mapMatchID:nil,changes:[.init(field:"instagram",value:nil,values:nil,findingID:findings[0].id.uuidString,source:"verified_finding")],instructionQuote:namedQuestion)
        let namedCall=AskAgentReply.Call(name:"propose_changes",callID:"explicit-name",arguments:String(data:try JSONEncoder().encode(namedProposal),encoding:.utf8)!)
        let explicitlyNamed=try await namedExecutor.executeConversation(namedCall,planner:namedPlanner)
        precondition(explicitlyNamed.output.status=="applied" && first.instagramURL==findings[0].value)
        let namedAction=explicitlyNamed.response!.collectionActions![0]
        _ = try engine.undo(namedAction.id,authorization:.init(question:"Undo",entity:"place",operations:["undo"],fields:[],targetIDs:[ids[0]],allowsCreation:false,boundProposal:undoPartial))
        let legacy=AskAgentExecutor(adapter:adapter,engine:engine,request:namedRequest,researcher:remote,searchMaps:{_ in []})
        var legacyPermission=AskAgentPermission(entity:"place",operations:["update"],fields:["instagram"],targetIDs:[ids[0]],instructionQuote:namedQuestion,changes:[.init(field:"instagram",source:"verified_finding",value:nil,values:nil)])
        func legacyIntent(_ permission:AskAgentPermission)->AskAgentInterpretation {.init(goal:"change",sourcePolicy:"public_if_missing",fields:["instagram"],selectionIDs:[ids[0]],permissions:[permission])}
        do {try legacy.prepare(legacyIntent(legacyPermission));preconditionFailure("Legacy nil-selector accepted incomplete references")}catch AskChangeError.invalid {}
        legacyPermission.selector=previous
        do {try legacy.prepare(legacyIntent(legacyPermission));preconditionFailure("Legacy ordinal accepted incomplete references")}catch AskChangeError.invalid {}
        legacyPermission.selector=named
        try legacy.prepare(legacyIntent(legacyPermission))
        precondition(places.allSatisfy {$0.instagramURL==nil})
        let encoded=try JSONEncoder().encode(absent.agentTask!),roundtrip=try JSONDecoder().decode(AskAgentTask.self,from:encoded)
        precondition(roundtrip.referencesIncomplete==true && roundtrip.orderedIDs==absent.agentTask?.orderedIDs)
        let projected=try JSONEncoder().encode(roundtrip.projection(fullCollection:true))
        precondition(!String(data:projected,encoding:.utf8)!.contains("referencesIncomplete"))
        let old=try JSONDecoder().decode(AskAgentTask.self,from:JSONEncoder().encode(request.agentTask!));precondition(old.referencesIncomplete==nil)
        var recovery=AskRecoveryLoopState();recovery.referencesIncomplete=true
        let decodedRecovery=try JSONDecoder().decode(AskRecoveryLoopState.self,from:JSONEncoder().encode(recovery));precondition(decodedRecovery.referencesIncomplete==true)

        // Explicit display order wins over alphabetic order and repeated prose.
        let reordered="1. [[place:\(ids[2])]]\n2. [[place:\(ids[0])]]\n3. [[place:\(ids[1])]]\n\nMy favorite is [[place:\(ids[2])]]."
        let ordered=AskPlaceReferenceSequence.read(reordered)
        precondition(ordered.ids==[ids[2],ids[0],ids[1]] && !ordered.incomplete)
        let duplicate=AskPlaceReferenceSequence.read("1. [[place:\(ids[0])]]\n2. [[place:\(ids[0])]]\n3. [[place:\(ids[2])]]")
        precondition(duplicate.incomplete)
        for malformed in ["1. [[place:bad]]", "1. [[place:\(ids[0])]]\n3. [[place:\(ids[2])]]", "[[place:"] {precondition(AskPlaceReferenceSequence.read(malformed).incomplete)}
        // Complete explicit native replacement owns the visible order. A mere
        // mention does not overwrite list order or turn aggregate membership into ordinals.
        func query(_ operation:String)->AskAgentReply.Call {
            .init(name:"query_collection",callID:"native-"+operation,arguments:"{\"entity\":\"place\",\"query\":{\"operation\":\""+operation+"\",\"scope\":\"previous\",\"positions\":[],\"fields\":[]}}")
        }
        func nativeAnswer(_ operation:String,_ text:String)async throws->AskResponse {
            let planner=PlaceReferencePlanner(text:text,calls:[query(operation)])
            let executor=AskAgentExecutor(adapter:adapter,engine:engine,request:request,researcher:remote,searchMaps:{_ in []},fullCollectionContext:true)
            let rich=try AskSemanticContext.make(request,catalog:snapshot,fullCollection:true)
            return try await AskConversationLoop(planner:planner,availableCandidates:tools.localCandidates(Set(ids)),execute:{call in try await executor.executeConversation(call,planner:planner)}).answer(request,context:rich,cities:[],findings:[])
        }
        let replacement=try await nativeAnswer("list",reordered)
        precondition(replacement.agentTask?.orderedIDs==[ids[2],ids[0],ids[1]] && replacement.candidates.map(\.id)==[ids[2],ids[0],ids[1]] && replacement.paragraphs.count==1)
        let bulletOrder="- [[place:\(ids[2])]]\n- [[place:\(ids[0])]]\n- [[place:\(ids[1])]]"
        let bullets=try await nativeAnswer("list",bulletOrder)
        precondition(bullets.agentTask?.orderedIDs==[ids[2],ids[0],ids[1]] && bullets.paragraphs.count==1)
        let partialBullets=try await nativeAnswer("list","- [[place:\(ids[2])]]\n- [[place:\(ids[0])]]")
        precondition(partialBullets.agentTask?.referencesIncomplete==true && partialBullets.agentTask?.orderedIDs.count==3 && partialBullets.agentTask?.orderedIDs==partialBullets.libraryContext?.ids)
        let extra=catalog.index.first {!ids.contains($0.id)}!.id
        let extraPlanner=PlaceReferencePlanner(text:reordered+"\n4. [[place:\(extra)]]",calls:[query("list")])
        let extraExecutor=AskAgentExecutor(adapter:adapter,engine:engine,request:request,researcher:remote,searchMaps:{_ in []},fullCollectionContext:true)
        let extraAnswer=try await AskConversationLoop(planner:extraPlanner,availableCandidates:tools.localCandidates(Set(ids+[extra])),execute:{call in try await extraExecutor.executeConversation(call,planner:extraPlanner)}).answer(request,context:AskSemanticContext.make(request,catalog:snapshot,fullCollection:true),cities:[],findings:[])
        precondition(extraAnswer.agentTask?.orderedIDs.count==3 && !extraAnswer.agentTask!.orderedIDs.contains(extra) && extraAnswer.agentTask?.referencesIncomplete==true && extraAnswer.collectionPage?.totalCount==3)
        let mention=try await nativeAnswer("list","Consider [[place:\(ids[2])]].")
        precondition(mention.agentTask?.orderedIDs==mention.libraryContext?.ids && mention.agentTask?.orderedIDs.count==3)
        let aggregate=try await nativeAnswer("count","There are three, including [[place:\(ids[2])]].")
        precondition(aggregate.agentTask?.orderedIDs==[] && Set(aggregate.agentTask?.selectionIDs ?? [])==Set(ids))
        let sameName=places.first {$0.id!.uuidString==ids[1]}!
        sameName.displayNameSnapshot=places.first {$0.id!.uuidString==ids[0]}!.displayNameSnapshot;try context.save()
        let fresh=try AskReadTools(request:request,index:adapter.readView().index).localCandidates(Set(ids))
        precondition(fresh.count==3 && fresh[ids[0]]!.name==fresh[ids[1]]!.name && fresh[ids[0]]!.id != fresh[ids[1]]!.id)
        let renamed=try await provider.answer(request,tools:tools)
        precondition(renamed.candidates.first {$0.id==ids[1]}?.name==sameName.displayNameSnapshot,"Fresh local labels must win over stale input tools without matching by name")
        visible=[]
        let revokedProvider=AskAgentProvider(remote:remote,fallback:remote,adapter:adapter,engine:engine,searchMaps:{_ in []})
        let revoked=try await revokedProvider.answer(request,tools:tools)
        precondition(revoked.candidates.isEmpty && revoked.agentTask?.referencesIncomplete==true)
        visible=[city.id!]
        unsafe.agentTask=request.agentTask
        print("PASS missing/revoked/ambiguous references block previous-position saves; distinct same-name records retain exact identities; old history and recovery checkpoints remain compatible")
        let start=DispatchTime.now().uptimeNanoseconds
        for _ in 0..<100 {precondition(tools.localCandidates(Set(ids)).count==3);precondition(AskPlaceReferenceSequence.read(text).ids==ids)}
        let elapsed=Double(DispatchTime.now().uptimeNanoseconds-start)/1_000_000/100
        print("REFERENCE BENCH: three-ID hydration + order scan in 260-place collection: \(String(format:"%.3f",elapsed)) ms mean, 100 iterations; zero network calls added")
    }
}
