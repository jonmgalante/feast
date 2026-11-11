import Foundation
import CoreData

private struct RetentionResearcher:AskBusinessResearching {
    func publicLookupAvailable()async->Bool {false}
    func businessResearch(_ request:AskBusinessRequest)async throws->AskBusinessResult {preconditionFailure("No provider calls in retention regressions")}
}
private actor RetentionPlanner:AskConversationPlanning {
    let calls:[AskAgentReply.Call],text:String
    private var seen:[AskConversationStep]=[]
    init(calls:[AskAgentReply.Call]=[],text:String="") {self.calls=calls;self.text=text}
    func steps()->[AskConversationStep] {seen}
    func conversationAvailable()async->Bool {true}
    func conversationStep(_ step:AskConversationStep)async throws->AskConversationReply {
        seen.append(step)
        let call=step.step<calls.count ? calls[step.step] : nil
        return .init(version:9,requestID:step.requestID,step:step.step,kind:call==nil ? "answer" : "tool",text:call==nil ? text : "",continuation:"offline",model:"fixture",call:call)
    }
    func searchConversationWeb(_ query:String)async throws->AskWebResearchResult {preconditionFailure("No web calls")}
    func authorizePendingConfirmation(_ actions:[AskCollectionAction],question:String,history:[String])async throws->AskHumanAuthorization {preconditionFailure("No mutations")}
    func authorizeConversationChange(_ proposal:AskChangeProposal,question:String,history:[String],targets:[AskAgentRecord])async throws->AskHumanAuthorization {preconditionFailure("No mutations")}
}
private struct RetentionProvider:AskFeastProvider {
    let label="Offline answer retention regression"
    let adapter:AskSavedCollection,engine:AskCollectionChangeEngine,planner:RetentionPlanner
    var maps:[ApplePlaceMatch]=[]
    func answer(_ request:AskRequest,tools:AskReadTools)async throws->AskResponse {
        let view=try await adapter.readView(),semantic=try AskSemanticContext.make(request,catalog:view.snapshot,fullCollection:true)
        let executor=await AskAgentExecutor(adapter:adapter,engine:engine,request:request,researcher:RetentionResearcher(),searchMaps:{_ in maps},fullCollectionContext:true,supportsCollectionQueryV2:true)
        let available=AskReadTools.localCandidates(Set(view.snapshot.places.map(\.id)),in:view.index)
        return try await AskConversationLoop(planner:planner,availableCandidates:available,execute:{call in try await executor.executeConversation(call,planner:planner)}).answer(request,context:semantic,cities:[],findings:[])
    }
}
@MainActor enum AskAnswerRetentionTests {
    static func query(_ operation:String="list",name:String?=nil,scope:String="library",positions:[Int]=[])->AskAgentReply.Call {
        var query:[String:Any] = ["operation":operation,"scope":scope,"positions":positions,"fields":[]]
        if let name {query["name"]=name}
        return .init(name:"query_collection",callID:UUID().uuidString,arguments:String(data:try! JSONSerialization.data(withJSONObject:["entity":"place","query":query]),encoding:.utf8)!)
    }
    static func run(model:NSManagedObjectModel,directory:URL,selection:String?=nil)async throws {
        let coordinator=NSPersistentStoreCoordinator(managedObjectModel:model)
        _ = try coordinator.addPersistentStore(ofType:NSSQLiteStoreType,configurationName:nil,at:directory.appendingPathComponent("answer-retention.sqlite"))
        let context=NSManagedObjectContext(concurrencyType:.mainQueueConcurrencyType);context.persistentStoreCoordinator=coordinator
        let repo=FeastRepository(context:context),city=try repo.createFeastList(named:"Retention City")
        _ = try repo.createSavedPlace(from:.init(applePlaceID:"retention-cafe",displayNameSnapshot:"Retention Cafe",status:.wantToTry,placeType:.cafe,cuisines:[],tags:[],note:"Saved private detail",websiteURL:"https://example.org/book",instagramURL:nil,feastList:city,listSection:nil))
        let adapter=AskSavedCollection(context:context,visibleCities:{[city.id!]})
        let engine=AskCollectionChangeEngine(adapter:adapter,journalURL:directory.appendingPathComponent("answer-retention-journal.json"))
        if selection==nil || selection=="blank" {
            for (calls,text) in [([]," \n "),([query("answer")]," \n "),([],"\u{E200}cite\u{E202}turn0search0\u{E201}"),([query("answer")],"\u{E200}cite\u{E202}turn0search0\u{E201}")] {
                let planner=RetentionPlanner(calls:calls,text:text)
                let session=AskSession(index:try adapter.index(),provider:RetentionProvider(adapter:adapter,engine:engine,planner:planner))
                session.refreshIndex={try adapter.index()}
                let store=AskConversationStore(url:directory.appendingPathComponent(UUID().uuidString+".json"));session.restoreHistory(from:store)
                session.input="Explain why this cafe fits a quiet lunch";session.run()
                while session.isLoading {await Task.yield()}
                guard case .failed = session.turns.last?.status else {preconditionFailure("Blank synthesis was accepted as a completed answer")}
                precondition(session.response==nil && session.error != nil)
                session.flushHistory()
                let restored=AskSession(index:try adapter.index(),provider:RetentionProvider(adapter:adapter,engine:engine,planner:planner));restored.restoreHistory(from:store)
                guard case .failed = restored.turns.last?.status else {preconditionFailure("Blank failure did not survive archive reload")}
                let steps=await planner.steps();precondition(steps.count==(calls.count+1))
            }
            for call in [query(),query("count"),query(name:"Missing Cafe")] {
                let planner=RetentionPlanner(calls:[call])
                let session=AskSession(index:try adapter.index(),provider:RetentionProvider(adapter:adapter,engine:engine,planner:planner))
                session.input="Show the requested saved result";session.run();while session.isLoading {await Task.yield()}
                precondition(session.turns.last?.status == .complete && !AskAnswerCopy.text(session.response!).trimmingCharacters(in:.whitespacesAndNewlines).isEmpty)
            }
            let request=AskRequest(mode:.collection,text:"Save this change",fromOCR:false,performanceID:UUID())
            let receipt=AskCollectionAction(id:UUID(),title:"Saved change",targetIDs:[],entity:"place",operation:"update",state:.applied,undoable:false)
            let actionPlanner=RetentionPlanner(calls:[.init(name:"propose_changes",callID:"action",arguments:"{}")])
            let actionOnly=try await AskConversationLoop(planner:actionPlanner,availableCandidates:[:],execute:{_ in .init(output:.init(status:"applied",complete:true,totalCount:0,records:[],findings:[],message:"changed",localOnly:false),response:.init(summary:"Saved.",candidates:[],listedCandidateIDs:[],usesLocalCatalog:true,collectionActions:[receipt]),orderedIDs:[])}).answer(request,context:.init(index:[],recent:[]),cities:[],findings:[])
            precondition(actionOnly.collectionActions==[receipt] && !actionOnly.summary.contains("unfinished"))
            let findingPlanner=RetentionPlanner(calls:[.init(name:"retain_findings",callID:"finding",arguments:"{}")])
            let item=try adapter.personalPlaces()[0]
            let finding=AskVerifiedFinding(id:UUID(),recordID:item.id,identity:.init(item),field:"website",value:"https://example.org/book",evidenceURL:"https://example.org/source",verification:"cited_search",originatingTurn:UUID(),externallyReusable:true)
            let retained=try await AskConversationLoop(planner:findingPlanner,availableCandidates:[:],execute:{_ in preconditionFailure()},retainFindings:{_,_ in .init(output:.init(status:"success",complete:true,totalCount:1,records:[],findings:[],message:"ok",localOnly:false),response:.init(summary:"Public findings",candidates:[],listedCandidateIDs:[],usesLocalCatalog:true,verifiedPublicFindings:[finding]),orderedIDs:[item.id])}).answer(request,context:.init(index:[],recent:[]),cities:[],findings:[])
            precondition(retained.summary.contains("unfinished") && retained.verifiedPublicFindings==[finding])
            print("PASS whitespace/control-token direct and answer-read finals fail honestly across reload without retry; list/count/negative/action-only outputs remain valid and unsynthesized findings are retained as unfinished")
        }
        if selection==nil || selection=="native-visibility" {
            let maps=ApplePlacesService.previewMatches.prefix(1).map {$0}
            let planner=RetentionPlanner(calls:[.init(name:"search_maps",callID:"maps",arguments:"{\"query\":\"Harbor Bakery\",\"cityID\":null}")])
            let provider=RetentionProvider(adapter:adapter,engine:engine,planner:planner,maps:maps)
            let store=AskConversationStore(url:directory.appendingPathComponent("maps-visibility.json"))
            let session=AskSession(index:try adapter.index(),provider:provider);session.restoreHistory(from:store)
            session.input="Find Harbor Bakery in Maps";session.run();while session.isLoading {await Task.yield()}
            precondition(session.turns.last?.status == .complete && session.response?.mapChoices?.count==1,"A native Maps-choice-only answer was rejected")
            let choices=session.response!.mapChoices!
            precondition(choices[0].match.applePlaceID==maps[0].applePlaceID && session.response?.collectionActions?.isEmpty != false)
            session.flushHistory()
            let reopened=AskSession(index:try adapter.index(),provider:provider);reopened.restoreHistory(from:store)
            let places=try adapter.personalPlaces();precondition(reopened.response?.mapChoices==choices && places.count==1)
            let status="No current hours could be verified. No saved fields changed."
            let lookup=RetentionPlanner(calls:[.init(name:"research_businesses",callID:"lookup",arguments:"{}")],text:"\u{E200}cite\u{E202}turn0search0\u{E201}")
            let response=try await AskConversationLoop(planner:lookup,availableCandidates:[:],execute:{_ in
                .init(output:.init(status:"empty",complete:true,totalCount:0,records:[],findings:[],message:"not_found",localOnly:false),response:.init(summary:"Lookup result",candidates:[],paragraphs:[.init(id:"business-unverified",spans:[.text(status)],sourceIDs:[],transientToolStatus:true)],listedCandidateIDs:[],usesLocalCatalog:true),orderedIDs:[])
            }).answer(.init(mode:.collection,text:"Find current hours",fromOCR:false),context:.init(index:[],recent:[]),cities:[],findings:[])
            precondition(AskAnswerCopy.text(response).contains(status),"Invisible synthesis erased the native negative lookup result")
            let turn=AskTurn(id:UUID(),request:.init(mode:.collection,text:"Find current hours",fromOCR:false),response:response,status:.complete)
            let archive=try JSONDecoder().decode(AskArchivedTurn.self,from:JSONEncoder().encode(AskArchivedTurn(turn)))
            let projected=AskConversationProjection.messages([archive.turn],fullCollection:true).map(\.text).joined(separator:"\n")
            precondition(projected.contains(status) && !projected.contains("\u{E200}"),"History must retain the truthful native fallback, not invisible control tokens")
            print("PASS native Maps choices survive Session/archive without saving; invisible final synthesis retains negative lookup presentation and truthful history")
        }
        if selection==nil || selection=="aggregate" {
            for i in 1...2400 {
                let place=SavedPlace(context:context);place.id=UUID();place.displayNameSnapshot="Aggregate \(i)";place.applePlaceID="aggregate-\(i)";place.feastList=city;place.placeStatus = .wantToTry;place.placeTypeValue = .restaurant;place.cuisines=[];place.tags=[];place.createdAt=Date();place.updatedAt=Date()
            }
            try context.save()
            let planner=RetentionPlanner(calls:[query("count")]),provider=RetentionProvider(adapter:adapter,engine:engine,planner:planner)
            let store=AskConversationStore(url:directory.appendingPathComponent("aggregate-history.json")),session=AskSession(index:try adapter.index(),provider:provider)
            session.restoreHistory(from:store);session.refreshIndex={try adapter.index()};session.input="Count my complete collection";session.run();while session.isLoading {await Task.yield()}
            precondition(session.turns.last?.status == .complete && session.response?.agentTask?.selectionIDs?.count==2401 && session.response?.agentTask?.orderedIDs==[])
            session.flushHistory()
            let nextPlanner=RetentionPlanner(calls:[query("count",scope:"previous")]),nextProvider=RetentionProvider(adapter:adapter,engine:engine,planner:nextPlanner)
            let reopened=AskSession(index:try adapter.index(),provider:nextProvider);reopened.restoreHistory(from:store);reopened.input="How many of those?";reopened.run();while reopened.isLoading {await Task.yield()}
            precondition(reopened.turns.last?.status == .complete && reopened.response?.agentTask?.selectionIDs?.count==2401)
            let request=reopened.turns.last!.request
            let executor=AskAgentExecutor(adapter:adapter,engine:engine,request:request,researcher:RetentionResearcher(),searchMaps:{_ in []},fullCollectionContext:true,supportsCollectionQueryV2:true)
            let result=try await executor.executeConversation(query("count",scope:"previous"),planner:nextPlanner)
            precondition(result.orderedIDs.count==2401 && !result.selectionIsOrdered)
            let bytes=try executor.recoverySnapshot()
            let checkpoints=AskTurnRecoveryStore(directory:directory.appendingPathComponent("aggregate-checkpoints"),requirePersistence:true)
            var checkpoint=AskTurnCheckpoint(turnID:request.performanceID!,chatID:request.conversationID!,attemptID:UUID(),endpoint:"https://fixture.invalid/answer",request:request,createdAt:Date())
            checkpoint.executor=bytes;checkpoint.state.ordered=result.orderedIDs;checkpoint.state.selectionIsOrdered=false
            try checkpoints.save(checkpoint)
            let reloaded=try AskTurnRecoveryStore(directory:checkpoints.directory,requirePersistence:true).checkpoint(request.performanceID!)!
            let recovered=AskAgentExecutor(adapter:adapter,engine:engine,request:reloaded.request,researcher:RetentionResearcher(),searchMaps:{_ in []},fullCollectionContext:true,supportsCollectionQueryV2:true)
            try recovered.restoreRecoverySnapshot(reloaded.executor!)
            let all=try await recovered.executeConversation(query("count",scope:"previous"),planner:nextPlanner)
            precondition(all.orderedIDs.count==2401 && !all.selectionIsOrdered && all.output.totalCount==2401)
            do {
                let positional=try await recovered.executeConversation(query("details",scope:"previous",positions:[1]),planner:nextPlanner)
                precondition(["stale","ambiguous","needs_confirmation","conflict"].contains(positional.output.status) && positional.output.records.isEmpty,"Aggregate recovery granted ordinal authority")
            }catch AskError.invalidEvidence {}catch AskChangeError.invalid {}
            let receipts=try engine.receipts(forTurn:request.performanceID!);precondition(receipts.isEmpty)
            print("PASS 2401-member aggregates retain full nonordinal membership through Session, archive/follow-up and disk checkpoint restart without mutation")
        }
        if selection==nil || selection=="links" {
            let candidate=AskReadTools.localCandidates(Set(try adapter.personalPlaces().map(\.id)),in:try adapter.index()).values.first!
            let citation=AskWebCitation(title:"Verified source",url:"https://example.org/source?view=full")
            let paragraph=AskAnswerParagraph(id:"links",spans:[.place(candidate.id),.text(" [Stored business](https://example.org/book) [Verified](https://example.org/source?view=full&utm_source=test) [Unsafe](javascript:alert) ")],sourceIDs:candidate.sourceIDs,citations:[citation])
            let shown=AskMarkdownPresentation.inline(paragraph,candidates:[candidate])
            let links=shown.runs.compactMap(\.link)
            precondition(!links.contains { $0.absoluteString=="https://example.org/book" },"An unsupported stored link must not look tappable")
            precondition(links.contains {AskCitationLink.acceptedURL(for:$0,citations:[citation]) != nil})
            precondition(links.contains {AskPlaceReference.candidate(for:$0,in:[candidate]) != nil})
            precondition(!links.contains {$0.scheme=="javascript"})
            precondition(AskCitationLink.acceptedURL(for:URL(string:"https://example.org/source?view=other")!,citations:[citation])==nil)
            precondition(String(shown.characters).contains("Stored business") && String(shown.characters).contains(candidate.name))
            let response=AskResponse(summary:"Links",candidates:[candidate],paragraphs:[paragraph],listedCandidateIDs:[],usesLocalCatalog:true)
            let restored=try JSONDecoder().decode(AskResponse.self,from:JSONEncoder().encode(response))
            precondition(AskMarkdownPresentation.inline(restored.paragraphs[0],candidates:restored.candidates).runs.compactMap(\.link)==links)
            precondition(AskAnswerCopy.text(restored).contains("Stored business"))
            print("PASS paragraph links match approved tap destinations; saved uncited and unsafe links are plain text, citations/internal links and copy survive reload")
        }
    }
}
