import Foundation
import CoreData

/// Every reply is scripted. The real local loop, executor and session acceptance
/// run, but no provider, network, live store or production credentials are used.
private actor AcceptancePlanner:AskConversationPlanning,AskBusinessResearching {
    let calls:[AskAgentReply.Call],text:String,selector:AskAgentSelector?
    init(_ calls:[AskAgentReply.Call],text:String,selector:AskAgentSelector?=nil) {self.calls=calls;self.text=text;self.selector=selector}
    func conversationAvailable()async->Bool {true}
    func publicLookupAvailable()async->Bool {false}
    func businessResearch(_ request:AskBusinessRequest)async throws->AskBusinessResult {preconditionFailure("No external research")}
    func searchConversationWeb(_ query:String)async throws->AskWebResearchResult {preconditionFailure("No external search")}
    func conversationStep(_ step:AskConversationStep)async throws->AskConversationReply {
        let call=step.step<calls.count ? calls[step.step] : nil
        return .init(version:9,requestID:step.requestID,step:step.step,kind:call==nil ? "answer" : "tool",text:call==nil ? text : "",continuation:"synthetic",model:"gpt-6-astra",call:call)
    }
    func authorizePendingConfirmation(_ actions:[AskCollectionAction],question:String,history:[String])async throws->AskHumanAuthorization {preconditionFailure("No pending approvals")}
    func authorizeConversationChange(_ proposal:AskChangeProposal,question:String,history:[String],targets:[AskAgentRecord])async throws->AskHumanAuthorization {
        precondition(selector != nil,"Unexpected write")
        return .init(approved:true,replaceExisting:false,deleteContents:false,reason:"explicit_instruction",targetSelector:selector)
    }
}
private struct AcceptanceProvider:AskFeastProvider {
    let label="Offline acceptance fixture"
    let adapter:AskSavedCollection,engine:AskCollectionChangeEngine,planner:AcceptancePlanner
    var damage:String?=nil
    func answer(_ request:AskRequest,tools:AskReadTools)async throws->AskResponse {
        let view=try await adapter.readView()
        let context=try AskSemanticContext.make(request,catalog:view.snapshot,fullCollection:true)
        let executor=await AskAgentExecutor(adapter:adapter,engine:engine,request:request,researcher:planner,searchMaps:{_ in []},fullCollectionContext:true)
        let available=AskReadTools.localCandidates(Set(view.snapshot.places.map(\.id)),in:view.index)
        var answer=try await AskConversationLoop(planner:planner,availableCandidates:available,execute:{call in try await executor.executeConversation(call,planner:planner)}).answer(request,context:context,cities:[],findings:[])
        if damage=="citation" {answer.paragraphs[0].citations=[.init(title:"Rejected",url:"javascript:invalid")]}
        if damage=="candidate",let original=answer.candidates.first {
            answer.candidates[0] = .init(id:original.id,name:"Forged private payload",city:original.city,facts:original.facts,sourceIDs:original.sourceIDs,uncertainty:original.uncertainty,mapOptions:original.mapOptions,existingRecordID:original.existingRecordID)
        }
        return answer
    }
}
@MainActor enum AskAnswerAcceptanceTests {
    private static func settle(_ session:AskSession)async throws {
        for _ in 0..<10000 {if !session.isLoading {return};try await Task.sleep(nanoseconds:1_000_000)}
        preconditionFailure("Offline acceptance session did not settle")
    }
    private static func diagnostic(_ turn:UUID)async throws->AskPipelineSnapshot {
        for _ in 0..<1000 {
            if let value=await AskPerformanceRecorder.shared.pipelineSnapshot().first(where:{$0.turnID==turn && $0.outcome != .running}) {return value}
            try await Task.sleep(nanoseconds:1_000_000)
        }
        preconditionFailure("Final diagnostic was not recorded")
    }
    static func run(model:NSManagedObjectModel,temporaryDirectory:URL)async throws {
        let coordinator=NSPersistentStoreCoordinator(managedObjectModel:model)
        let store=try coordinator.addPersistentStore(ofType:NSSQLiteStoreType,configurationName:nil,at:temporaryDirectory.appendingPathComponent("answer-acceptance.sqlite"))
        let context=NSManagedObjectContext(concurrencyType:.mainQueueConcurrencyType);context.persistentStoreCoordinator=coordinator
        let repo=FeastRepository(context:context),city=try repo.createFeastList(named:"Acceptance City"),other=try repo.createFeastList(named:"Other City")
        var places:[SavedPlace]=[]
        for i in 0..<205 {
            places.append(try repo.createSavedPlace(from:.init(applePlaceID:"acceptance-\(i)",displayNameSnapshot:String(format:"Cafe %03d",i),status:.wantToTry,placeType:.cafe,cuisines:["Coffee"],tags:["Keep"],note:"Unchanged",websiteURL:nil,instagramURL:nil,feastList:city,listSection:nil)))
        }
        let extra=try repo.createSavedPlace(from:.init(applePlaceID:"acceptance-extra",displayNameSnapshot:"Extra Cafe",status:.wantToTry,placeType:.cafe,cuisines:["Coffee"],tags:["Keep"],note:"Unchanged",websiteURL:nil,instagramURL:nil,feastList:other,listSection:nil))
        let adapter=AskSavedCollection(context:context,canMutate:{_,_,_ in true},canRecoverStore:{$0==store.identifier},visibleCities:{[city.id!,other.id!]})
        let engine=AskCollectionChangeEngine(adapter:adapter,journalURL:temporaryDirectory.appendingPathComponent("acceptance-actions.json"))
        let ids=places.prefix(3).map {$0.id!.uuidString},extraID=extra.id!.uuidString
        let shown=[ids[2],ids[0],ids[1]]
        let prose=shown.enumerated().map {"\($0.offset+1). [[place:\($0.element)]]"}.joined(separator:"\n")+"\n\nSeparately, [[place:\(extraID)]] is worth considering."
        func query(_ operation:String="list",ids:[String],offset:Int?=nil,snapshot:String?=nil)->AskAgentReply.Call {
            var q:[String:Any] = ["operation":operation,"scope":"library","positions":[],"fields":[]]
            if operation=="group" {q["groupBy"]="cuisine"}
            if let offset {q["offset"]=offset};if let snapshot {q["snapshot"]=snapshot}
            let body:[String:Any] = ["entity":"place","selectionIDs":ids,"query":q]
            return .init(name:"query_collection",callID:UUID().uuidString,arguments:String(data:try! JSONSerialization.data(withJSONObject:body),encoding:.utf8)!)
        }
        func session(_ calls:[AskAgentReply.Call],text:String,selector:AskAgentSelector?=nil,damage:String?=nil)throws->AskSession {
            let provider=AcceptanceProvider(adapter:adapter,engine:engine,planner:AcceptancePlanner(calls,text:text,selector:selector),damage:damage)
            let value=AskSession(index:try adapter.readView().index,provider:provider)
            value.refreshIndex={try adapter.readView().index};return value
        }
        let initial=try session([query(ids:ids)],text:prose)
        initial.input="Show my three cafes and suggest an alternative";initial.run();try await settle(initial)
        precondition(initial.turns.last?.status == .complete && initial.error==nil)
        let accepted=initial.response!,turn=initial.turns.last!
        precondition(accepted.libraryContext?.ids==shown && accepted.agentTask?.orderedIDs==shown && accepted.agentTask?.referencesIncomplete != true)
        precondition(accepted.answerMentionIDs==[extraID] && accepted.candidates.count==4 && accepted.paragraphs.count==1)
        let copy=AskAnswerCopy.text(accepted)
        precondition(copy.contains("Cafe 002") && copy.contains("Extra Cafe") && !copy.contains("[[place:"))
        let rendered=AskMarkdownPresentation.inline(accepted.paragraphs[0],candidates:accepted.candidates)
        let linked=Array(rendered.runs).compactMap {run in run.link.flatMap {AskPlaceReference.candidate(for:$0,in:accepted.candidates)?.id}}
        precondition(linked==shown+[extraID])
        initial.markRendered(turn.id)
        let trace=try await diagnostic(turn.id)
        precondition(trace.validationFailure==nil && trace.samples.contains {$0.stage == .assembly} && trace.samples.contains {$0.stage == .validation} && trace.samples.contains {$0.stage == .answerAvailable})
        let archive=AskConversationStore(url:temporaryDirectory.appendingPathComponent("acceptance-history.json"))
        precondition(archive.save(.init(turns:[AskArchivedTurn(turn)])))
        let decoded=archive.load().turns[0].turn.response!
        precondition(decoded.answerMentionIDs==[extraID] && decoded.libraryContext?.ids==shown)
        let checkpointDirectory=temporaryDirectory.appendingPathComponent("acceptance-checkpoints")
        let checkpoints=AskTurnRecoveryStore(directory:checkpointDirectory,requirePersistence:true)
        var checkpoint=AskTurnCheckpoint(turnID:turn.id,chatID:turn.request.conversationID!,attemptID:UUID(),endpoint:"https://offline.invalid/answer",request:turn.request,createdAt:Date())
        checkpoint.phase = .completed;checkpoint.loopInitialized=true;checkpoint.finalResponse=accepted
        checkpoint.state.latest=accepted;checkpoint.state.ordered=shown
        checkpoint.state.available=Dictionary(uniqueKeysWithValues:accepted.candidates.map {($0.id,$0)})
        try checkpoints.save(checkpoint)
        let reopened=AskTurnRecoveryStore(directory:checkpointDirectory,requirePersistence:true)
        let restoredCheckpoint=try reopened.checkpoint(turn.id)!
        precondition(restoredCheckpoint.finalResponse==accepted && restoredCheckpoint.state.latest==accepted && restoredCheckpoint.state.ordered==shown)
        precondition(restoredCheckpoint.state.latest?.answerMentionIDs==[extraID])
        print("PASS actual session assembles, accepts, renders and archives native results plus a verified extra mention without changing query or visible selection")

        // Exact displayed positions and 'those' are resolved independently from
        // the extra recommendation, through real authorization and writes.
        for positions in [[2],[1],[1,2,3]] {
            let targets=positions.map {shown[$0-1]},url="https://www.instagram.com/acceptancefixture/"
            let question="Save \(url) to "+(positions.count==3 ? "those three places" : "the place at position \(positions[0])")
            let proposal=AskChangeProposal(entity:"place",operation:"update",targetIDs:targets,cityID:nil,sectionID:nil,mapMatchID:nil,changes:[.init(field:"instagram",value:url,values:nil,findingID:nil,source:"user")],instructionQuote:question)
            let call=AskAgentReply.Call(name:"propose_changes",callID:UUID().uuidString,arguments:String(data:try JSONEncoder().encode(proposal),encoding:.utf8)!)
            let selector=AskAgentSelector(city:nil,name:nil,neighborhood:nil,cuisine:nil,status:nil,placeType:nil,scope:"previous",positions:positions)
            let writer=try session([call],text:"Saved.",selector:selector)
            writer.restoreHistory(from:archive);writer.input=question;writer.run();try await settle(writer)
            precondition(writer.turns.last?.status == .complete,"Archived follow-up failed")
            precondition(writer.turns.last?.request.agentTask?.orderedIDs==shown && !writer.turns.last!.request.referencedIDs.contains(extraID))
            let actions=writer.response?.collectionActions ?? []
            precondition(!actions.isEmpty && actions.allSatisfy {$0.state == .applied && $0.undoable})
            precondition(Set(actions.flatMap(\.targetIDs))==Set(targets))
            for place in places {precondition(place.instagramURL == (targets.contains(place.id!.uuidString) ? url : nil))}
            precondition(extra.instagramURL==nil && places.allSatisfy {$0.note=="Unchanged" && $0.tags==["Keep"]})
            if positions==[2] {
                // A legitimate mutation receipt activates the production rebase
                // path; neither refreshed evidence nor mentions redefine rows.
                var withReceipt=accepted;withReceipt.collectionActions=actions
                let freshTools=try AskReadTools(request:turn.request,index:adapter.readView().index)
                let rebased=try freshTools.checked(freshTools.rebasedCatalogResponse(withReceipt))
                precondition(rebased.answerMentionIDs==[extraID] && rebased.libraryContext?.ids==shown && rebased.agentTask?.orderedIDs==shown)
                precondition(rebased.candidates.count==4 && Set(rebased.collectionActions!.flatMap(\.targetIDs))==Set(targets))
            }
            for action in actions {
                let undo=AskChangeProposal(entity:"place",operation:"undo",targetIDs:action.targetIDs,cityID:nil,sectionID:nil,mapMatchID:nil,changes:[],instructionQuote:"Undo")
                let result=try engine.undo(action.id,authorization:.init(question:"Undo",entity:"place",operations:["undo"],fields:[],targetIDs:Set(action.targetIDs),allowsCreation:false,boundProposal:undo))
                precondition(result.state == .undone)
            }
            precondition(places.allSatisfy {$0.instagramURL==nil} && extra.instagramURL==nil)
        }
        print("PASS archived displayed first/second/those selection saves only native targets, retains per-record receipts and supports Undo without touching the extra mention")

        for operation in ["count","group"] {
            let aggregate=try session([query(operation,ids:ids)],text:"The answer includes [[place:\(extraID)]].")
            aggregate.input="Summarize my cafes";aggregate.run();try await settle(aggregate)
            precondition(aggregate.turns.last?.status == .complete)
            precondition(aggregate.response?.libraryContext?.ids==[] && Set(aggregate.response?.libraryContext?.selectionIDs ?? [])==Set(ids))
            precondition(aggregate.response?.agentTask?.orderedIDs==[] && Set(aggregate.response?.agentTask?.selectionIDs ?? [])==Set(ids))
            precondition(aggregate.response?.answerMentionIDs==[extraID])
        }
        let partial=try session([query(ids:ids)],text:"1. [[place:\(ids[0])]]\n2. [[place:\(extraID)]]")
        partial.input="Show my three cafes";partial.run();try await settle(partial)
        precondition(partial.turns.last?.status == .complete && partial.response?.agentTask?.referencesIncomplete==true)
        precondition(Set(partial.response?.agentTask?.orderedIDs ?? [])==Set(ids) && !partial.response!.agentTask!.orderedIDs.contains(extraID))
        print("PASS aggregate mentions preserve aggregate membership and a competing partial list is displayed without granting expanded positional scope")

        // Answer-mode native rows are query inputs, not a displayed list. Only
        // explicit in-query visible selections can become follow-up positions.
        var subsetTurn:AskTurn?
        for (text,expected,incomplete) in [
            ("1. [[place:\(ids[2])]]\n2. [[place:\(ids[0])]]",[ids[2],ids[0]],false),
            ("Consider [[place:\(ids[2])]].",ids,true),
            ("1. [[place:\(ids[0])]]\n2. [[place:\(extraID)]]",ids,true)
        ] {
            let answerOnly=try session([query("answer",ids:ids)],text:text)
            answerOnly.input="Recommend cafes from my selection";answerOnly.run();try await settle(answerOnly)
            precondition(answerOnly.turns.last?.status == .complete)
            precondition(answerOnly.response?.libraryContext?.ids==ids)
            precondition(answerOnly.response?.agentTask?.orderedIDs==expected && (answerOnly.response?.agentTask?.referencesIncomplete==true)==incomplete)
            if !incomplete {subsetTurn=answerOnly.turns.last!}
        }
        let subsetArchive=AskConversationStore(url:temporaryDirectory.appendingPathComponent("acceptance-answer-subset.json"))
        precondition(subsetArchive.save(.init(turns:[AskArchivedTurn(subsetTurn!)])))
        let subsetURL="https://www.instagram.com/subsetfixture/",subsetQuestion="Save https://www.instagram.com/subsetfixture/ to the second place"
        let subsetProposal=AskChangeProposal(entity:"place",operation:"update",targetIDs:[ids[0]],cityID:nil,sectionID:nil,mapMatchID:nil,changes:[.init(field:"instagram",value:subsetURL,values:nil,findingID:nil,source:"user")],instructionQuote:subsetQuestion)
        let subsetCall=AskAgentReply.Call(name:"propose_changes",callID:"subset-follow-up",arguments:String(data:try JSONEncoder().encode(subsetProposal),encoding:.utf8)!)
        let subsetWriter=try session([subsetCall],text:"Saved.",selector:.init(city:nil,name:nil,neighborhood:nil,cuisine:nil,status:nil,placeType:nil,scope:"previous",positions:[2]))
        subsetWriter.restoreHistory(from:subsetArchive);subsetWriter.input=subsetQuestion;subsetWriter.run();try await settle(subsetWriter)
        precondition(subsetWriter.turns.last?.status == .complete)
        precondition(subsetWriter.turns.last?.request.libraryContext?.ids==ids && subsetWriter.turns.last?.request.agentTask?.orderedIDs==[ids[2],ids[0]])
        let subsetActions=subsetWriter.response?.collectionActions ?? []
        precondition(!subsetActions.isEmpty && subsetActions.allSatisfy {$0.state == .applied && $0.undoable && $0.targetIDs==[ids[0]]})
        precondition(places[0].instagramURL==subsetURL && places.dropFirst().allSatisfy {$0.instagramURL==nil} && extra.instagramURL==nil)
        for action in subsetActions {
            let undo=AskChangeProposal(entity:"place",operation:"undo",targetIDs:action.targetIDs,cityID:nil,sectionID:nil,mapMatchID:nil,changes:[],instructionQuote:"Undo")
            let result=try engine.undo(action.id,authorization:.init(question:"Undo",entity:"place",operations:["undo"],fields:[],targetIDs:Set(action.targetIDs),allowsCreation:false,boundProposal:undo))
            precondition(result.state == .undone)
        }
        precondition(places.allSatisfy {$0.instagramURL==nil && $0.note=="Unchanged" && $0.tags==["Keep"]})
        print("PASS archived answer-mode subset preserves full query membership but saves and undoes only the explicitly displayed second place")
        for operation in ["count","group"] {
            for (text,incomplete) in [
                ("1. [[place:\(ids[0])]]",true),
                ("1. [[place:\(extraID)]]",true),
                (ids.enumerated().map {"\($0.offset+1). [[place:\($0.element)]]"}.joined(separator:"\n"),false)
            ] {
                let aggregate=try session([query(operation,ids:ids)],text:text)
                aggregate.input="Summarize my cafes";aggregate.run();try await settle(aggregate)
                precondition(aggregate.turns.last?.status == .complete)
                precondition(aggregate.response?.agentTask?.orderedIDs==[] && Set(aggregate.response?.agentTask?.selectionIDs ?? [])==Set(ids))
                precondition((aggregate.response?.agentTask?.referencesIncomplete==true)==incomplete)
            }
        }
        let empty=try session([query(ids:[])],text:"Separately, consider [[place:\(extraID)]].")
        empty.input="Show matches for this empty selection";empty.run();try await settle(empty)
        precondition(empty.turns.last?.status == .complete)
        precondition(empty.response?.agentTask?.orderedIDs==[] && empty.response?.agentTask?.selectionIDs?.isEmpty != false)
        precondition(empty.response?.collectionPage?.totalCount==0 && empty.response?.candidates.map(\.id)==[extraID])
        let unknown=UUID().uuidString
        for text in ["1. [[place:\(ids[0])]]\n2. [[place:\(unknown)]]", "1. [[place:bad]]", "1. [[place:\(ids[0])]]\n2. [[place:\(ids[0])]]"] {
            let incomplete=try session([query(ids:ids)],text:text)
            incomplete.input="Show my cafes";incomplete.run();try await settle(incomplete)
            precondition(incomplete.turns.last?.status == .complete && incomplete.response?.agentTask?.referencesIncomplete==true)
            precondition(Set(incomplete.response?.candidates.map(\.id) ?? [])==Set(ids) && incomplete.response?.agentTask?.orderedIDs==ids)
            precondition(!incomplete.response!.paragraphs.flatMap(\.spans).contains(.place(unknown)))
        }
        print("PASS aggregate subset/extra lists, unknown and malformed references retain safe scope; a zero-match query does not invent targets")
        let unsafeArchive=AskConversationStore(url:temporaryDirectory.appendingPathComponent("acceptance-ambiguous.json"))
        precondition(unsafeArchive.save(.init(turns:[AskArchivedTurn(partial.turns.last!)])))
        let blockedQuestion="Save https://www.instagram.com/blockedfixture/ to the second place"
        let blockedProposal=AskChangeProposal(entity:"place",operation:"update",targetIDs:[extraID],cityID:nil,sectionID:nil,mapMatchID:nil,changes:[.init(field:"instagram",value:"https://www.instagram.com/blockedfixture/",values:nil,findingID:nil,source:"user")],instructionQuote:blockedQuestion)
        let blockedCall=AskAgentReply.Call(name:"propose_changes",callID:"ambiguous-follow-up",arguments:String(data:try JSONEncoder().encode(blockedProposal),encoding:.utf8)!)
        let blockedWriter=try session([blockedCall],text:"Saved.",selector:.init(city:nil,name:nil,neighborhood:nil,cuisine:nil,status:nil,placeType:nil,scope:"previous",positions:[2]))
        blockedWriter.restoreHistory(from:unsafeArchive);blockedWriter.input=blockedQuestion;blockedWriter.run();try await settle(blockedWriter)
        precondition(blockedWriter.turns.last?.status == .complete && blockedWriter.response?.executionStatus=="needs_confirmation")
        precondition(extra.instagramURL==nil && places.allSatisfy {$0.instagramURL==nil})
        print("PASS answer-only visible subsets stay separate from full query membership; ambiguous archived positional saves remain blocked")

        let all=places.map {$0.id!.uuidString}
        let firstPage=try session([query(ids:all)],text:"For another option, see [[place:\(extraID)]].")
        firstPage.input="Show all my cafes";firstPage.run();try await settle(firstPage)
        precondition(firstPage.turns.last?.status == .complete && firstPage.response?.libraryContext?.ids.count==200 && firstPage.response?.candidates.count==201)
        let page=firstPage.response!.collectionPage!
        let pagingArchive=AskConversationStore(url:temporaryDirectory.appendingPathComponent("acceptance-pages.json"))
        precondition(pagingArchive.save(.init(turns:[AskArchivedTurn(firstPage.turns.last!)])))
        let continued=try session([query(ids:all,offset:page.nextOffset,snapshot:page.snapshot)],text:"Here are the remaining cafes.")
        continued.restoreHistory(from:pagingArchive);continued.input="Continue the list";continued.run();try await settle(continued)
        precondition(continued.turns.last?.status == .complete)
        let complete=continued.response!
        precondition(complete.collectionPage?.returnedCount==205 && complete.collectionPage?.nextOffset==nil && complete.libraryContext?.ids==all)
        precondition(complete.answerMentionIDs==[extraID] && complete.candidates.count==206 && complete.agentTask?.orderedIDs==all)
        print("PASS 200-row page accepts an extra mention and archived continuation preserves all 205 native rows without promoting the mention")

        // A reference can be outside the current rendered page yet belong to
        // a later native page. Continuing must classify it once as a native row.
        let laterID=all[204]
        let upcoming=try session([query(ids:all)],text:"A later result is [[place:\(laterID)]].")
        upcoming.input="Show all my cafes";upcoming.run();try await settle(upcoming)
        precondition(upcoming.turns.last?.status == .complete && upcoming.response?.answerMentionIDs==[laterID])
        let upcomingPage=upcoming.response!.collectionPage!
        let upcomingArchive=AskConversationStore(url:temporaryDirectory.appendingPathComponent("acceptance-upcoming-page.json"))
        precondition(upcomingArchive.save(.init(turns:[AskArchivedTurn(upcoming.turns.last!)])))
        let nativeContinuation=try session([query(ids:all,offset:upcomingPage.nextOffset,snapshot:upcomingPage.snapshot)],text:"The remaining cafes are shown below.")
        nativeContinuation.restoreHistory(from:upcomingArchive);nativeContinuation.input="Continue the list";nativeContinuation.run();try await settle(nativeContinuation)
        precondition(nativeContinuation.turns.last?.status == .complete)
        let nativeComplete=nativeContinuation.response!
        precondition(nativeComplete.libraryContext?.ids==all && nativeComplete.agentTask?.orderedIDs==all && nativeComplete.candidates.count==205)
        precondition(nativeComplete.answerMentionIDs?.isEmpty != false && nativeComplete.candidates.filter {$0.id==laterID}.count==1)
        print("PASS page continuation promotes a prior mention only when its authoritative native row arrives, without duplicating identity or changing membership")

        for (damage,reason) in [("citation",AskAnswerValidationReason.citations),("candidate",.candidateEvidence),("revoked",.candidateEvidence)] {
            let rejected=try session([query(ids:ids)],text:prose,damage:damage)
            if damage=="revoked" {rejected.refreshIndex={AskLocalIndex(records:[],visibleCityIDs:[],visibleNoteIDs:[],scope:.savedMetadata,personalPlaces:[])}}
            rejected.input="Show my cafes";rejected.run();try await settle(rejected)
            precondition(rejected.turns.last?.status == .failed(AskError.invalidEvidence.localizedDescription) && rejected.response==nil)
            let failure=try await diagnostic(rejected.turns.last!.id)
            precondition(failure.validationFailure==reason && failure.samples.contains {$0.stage == .validation} && !failure.samples.contains {$0.stage == .answerAvailable})
            let data=String(data:try JSONEncoder().encode(failure),encoding:.utf8)!
            precondition(!data.contains("Forged private payload") && !data.contains("Cafe") && !data.contains(extraID) && !data.contains("javascript"))
        }
        print("PASS final validation still rejects forged identities, unsafe citations and revoked visibility; failure diagnostics contain closed reasons, not content")
        try boundary()
    }
    private static func boundary()throws {
        let records=(0...2400).map {i in AskCollectionRecord(id:UUID().uuidString,cityID:"fixture-city",city:"Fixture",name:"Bounded \(i)",neighborhood:"",cuisine:"",status:"",notes:[])}
        let personal=records.map {AskPersonalPlace(id:$0.id,name:$0.name,status:nil,type:nil,cuisines:[],city:"Fixture",neighborhood:"")}
        let index=AskLocalIndex(records:records,visibleCityIDs:["fixture-city"],visibleNoteIDs:[],scope:.savedMetadata,personalPlaces:personal)
        let request=AskRequest(mode:.collection,text:"List places",fromOCR:false),tools=try AskReadTools(request:request,index:index)
        let byID=tools.localCandidates(Set(records.map(\.id)))
        let candidates=records.map {byID[$0.id]!},ids=Array(records.prefix(2400)).map(\.id),extra=records.last!.id
        let plan=AskLibraryPlan(operation:.list,scope:.library,city:nil,cuisine:nil,status:nil,placeType:nil,name:nil,positions:[],fields:[])
        let paragraphs=candidates.enumerated().map {i,c in AskAnswerParagraph(id:"boundary-\(i)",spans:[.place(c.id)],sourceIDs:c.sourceIDs)}
        var response=AskResponse(summary:"Results",candidates:candidates,paragraphs:paragraphs,listedCandidateIDs:[],usesLocalCatalog:true,libraryContext:.init(ids:ids,filters:plan),answerMentionIDs:[extra],collectionPage:.init(snapshot:String(repeating:"a",count:64),totalCount:2400,offset:0,returnedCount:2400,nextOffset:nil))
        _ = try tools.checked(response)
        response.answerMentionIDs=nil
        do {_ = try tools.checked(response);preconditionFailure("Unmarked extra candidate bypassed query validation")}catch AskError.invalidEvidence {}
        response.answerMentionIDs=[extra];response.paragraphs.removeLast()
        do {_ = try tools.checked(response);preconditionFailure("Undisplayed extra candidate accepted")}catch AskError.invalidEvidence {}
        print("PASS maximum 2400 native rows plus a bounded verified mention remain valid; unmarked and undisplayed extras still fail")
    }
}
