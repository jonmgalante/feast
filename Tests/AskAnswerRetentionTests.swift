import Foundation
import CoreData

private struct RetentionResearcher:AskBusinessResearching {
    func publicLookupAvailable()async->Bool {false}
    func businessResearch(_ request:AskBusinessRequest)async throws->AskBusinessResult {preconditionFailure("No provider calls in retention regressions")}
}
private actor RetentionPlanner:AskConversationPlanning {
    let calls:[AskAgentReply.Call],text:String
    let selector:AskAgentSelector?
    let replaceExisting:Bool
    let confirmPending:Bool
    private var seen:[AskConversationStep]=[]
    init(calls:[AskAgentReply.Call]=[],text:String="",selector:AskAgentSelector?=nil,replaceExisting:Bool=false,confirmPending:Bool=false) {self.calls=calls;self.text=text;self.selector=selector;self.replaceExisting=replaceExisting;self.confirmPending=confirmPending}
    func steps()->[AskConversationStep] {seen}
    func conversationAvailable()async->Bool {true}
    func conversationStep(_ step:AskConversationStep)async throws->AskConversationReply {
        seen.append(step)
        let call=step.step<calls.count ? calls[step.step] : nil
        return .init(version:9,requestID:step.requestID,step:step.step,kind:call==nil ? "answer" : "tool",text:call==nil ? text : "",continuation:"offline",model:"fixture",call:call)
    }
    func searchConversationWeb(_ query:String)async throws->AskWebResearchResult {preconditionFailure("No web calls")}
    func authorizePendingConfirmation(_ actions:[AskCollectionAction],question:String,history:[String])async throws->AskHumanAuthorization {precondition(confirmPending,"No pending confirmation expected");return .init(approved:true,replaceExisting:false,deleteContents:false,reason:"accepted_pending")}
    func authorizeConversationChange(_ proposal:AskChangeProposal,question:String,history:[String],targets:[AskAgentRecord])async throws->AskHumanAuthorization {guard let selector else{preconditionFailure("No mutations")};return .init(approved:true,replaceExisting:replaceExisting,deleteContents:false,reason:"offline fixture",targetSelector:selector)}
}
private actor SectionPagePlanner:AskConversationPlanning {
    let calls:[AskAgentReply.Call],interrupt:Bool
    init(_ calls:[AskAgentReply.Call],interrupt:Bool=false) {self.calls=calls;self.interrupt=interrupt}
    func conversationAvailable()async->Bool {true}
    func conversationStep(_ step:AskConversationStep)async throws->AskConversationReply {
        if step.step>=calls.count,interrupt {throw AskHostedError.service(503)}
        let call=step.step<calls.count ? calls[step.step] : nil
        return .init(version:9,requestID:step.requestID,step:step.step,kind:call==nil ? "answer" : "tool",text:call==nil ? "Both separate lists are complete." : "",continuation:"offline-sections",model:"fixture",call:call)
    }
    func searchConversationWeb(_ query:String)async throws->AskWebResearchResult {preconditionFailure("No web calls")}
    func authorizePendingConfirmation(_ actions:[AskCollectionAction],question:String,history:[String])async throws->AskHumanAuthorization {preconditionFailure("No mutations")}
    func authorizeConversationChange(_ proposal:AskChangeProposal,question:String,history:[String],targets:[AskAgentRecord])async throws->AskHumanAuthorization {preconditionFailure("No mutations")}
}
private actor SectionRecoveryWire {
    let calls:[AskAgentReply.Call]
    var accepted:[Int:AskConversationStep]=[:],submits=0,lost=false
    init(calls:[AskAgentReply.Call]) {self.calls=calls}
    func send(_ request:URLRequest)throws->(Data,HTTPURLResponse) {
        let body=try JSONSerialization.jsonObject(with:request.httpBody!) as! [String:Any],op=body["op"] as! String
        let step:AskConversationStep
        if op=="submit" {
            step=try JSONDecoder().decode(AskConversationStep.self,from:JSONSerialization.data(withJSONObject:body["request"]!));accepted[step.step]=step;submits+=1
            if step.step==calls.count,!lost {lost=true;throw URLError(.networkConnectionLost)}
        }else {step=accepted[body["step"] as! Int]!}
        let call=step.step<calls.count ? calls[step.step] : nil
        let reply=AskConversationReply(version:10,requestID:step.requestID,step:step.step,kind:call==nil ? "answer" : "tool",text:call==nil ? "Both independent lists are retained." : "",continuation:"offline-sections",model:"gpt-6.1-sol",call:call,nativeEvidence:.init(version:1,blocks:[],sources:[],actions:[]),finalCitations:[])
        let data=try JSONSerialization.data(withJSONObject:["version":1,"requestID":step.requestID,"step":step.step,"state":op=="ack" ? "acknowledged" : "completed","retryAfterMs":100,"result":op=="ack" ? NSNull() : JSONSerialization.jsonObject(with:JSONEncoder().encode(reply))])
        return (data,HTTPURLResponse(url:request.url!,statusCode:200,httpVersion:nil,headerFields:["Content-Type":"application/json"])!)
    }
}
private struct RetentionProvider:AskFeastProvider {
    let label="Offline answer retention regression"
    let adapter:AskSavedCollection,engine:AskCollectionChangeEngine
    let planner:any AskConversationPlanning
    var maps:[ApplePlaceMatch]=[]
    var fullCollection=true
    func answer(_ request:AskRequest,tools:AskReadTools)async throws->AskResponse {
        let view=try await adapter.readView(),semantic=try AskSemanticContext.make(request,catalog:view.snapshot,fullCollection:fullCollection)
        let executor=await AskAgentExecutor(adapter:adapter,engine:engine,request:request,researcher:RetentionResearcher(),searchMaps:{_ in maps},fullCollectionContext:fullCollection,supportsCollectionQueryV2:fullCollection)
        let available=AskReadTools.localCandidates(Set(view.snapshot.places.map(\.id)),in:view.index)
        return try await AskConversationLoop(planner:planner,availableCandidates:available,execute:{call in try await executor.executeConversation(call,planner:planner)}).answer(request,context:semantic,cities:[],findings:[])
    }
}
@MainActor enum AskAnswerRetentionTests {
    static func query(_ operation:String="list",name:String?=nil,scope:String="library",positions:[Int]=[],fields:[String]=[],groupBy:String?=nil)->AskAgentReply.Call {
        var query:[String:Any] = ["operation":operation,"scope":scope,"positions":positions,"fields":fields]
        if let name {query["name"]=name}
        if let groupBy {query["groupBy"]=groupBy}
        return .init(name:"query_collection",callID:UUID().uuidString,arguments:String(data:try! JSONSerialization.data(withJSONObject:["entity":"place","query":query]),encoding:.utf8)!)
    }
    static func run(model:NSManagedObjectModel,directory:URL,selection:String?=nil)async throws {
        for kind in ["retry","retry-legacy","live","live-maps","live-authorization","live-authorization-token","contract-v9","contract-v9-long","contract-v9-capacity","contract-native","contract-native-long","contract-durable","contract-durable-restart","contract-many"] where selection==nil || selection=="channels-"+kind {try await AskRetainedChannelTests.run(model:model,directory:directory,kind:kind)}
        if selection==nil || selection=="recovery-history" {try await AskRetainedHistoryRecoveryTests.run(model:model,directory:directory)}
        if selection==nil || selection=="history" {try await AskHistoryProjectionTests.run(model:model,directory:directory,tail:false)}
        if selection==nil || selection=="history-v6" {try await AskHistoryProjectionTests.legacyPublicPrivacy(model:model,directory:directory)}
        if selection==nil || selection=="tail" {try await AskHistoryProjectionTests.run(model:model,directory:directory,tail:true)}
        let coordinator=NSPersistentStoreCoordinator(managedObjectModel:model)
        _ = try coordinator.addPersistentStore(ofType:NSSQLiteStoreType,configurationName:nil,at:directory.appendingPathComponent("answer-retention.sqlite"))
        let context=NSManagedObjectContext(concurrencyType:.mainQueueConcurrencyType);context.persistentStoreCoordinator=coordinator
        let repo=FeastRepository(context:context),city=try repo.createFeastList(named:"Retention City")
        _ = try repo.createSavedPlace(from:.init(applePlaceID:"retention-cafe",displayNameSnapshot:"Retention Cafe",status:.wantToTry,placeType:.cafe,cuisines:[],tags:[],note:"Saved private detail",websiteURL:"https://example.org/book",instagramURL:nil,feastList:city,listSection:nil))
        var visible:Set<UUID>=[city.id!]
        let adapter=AskSavedCollection(context:context,canMutate:{_,_,_ in true},canRecoverStore:{id in coordinator.persistentStores.contains {$0.identifier==id}},visibleCities:{visible})
        let engine=AskCollectionChangeEngine(adapter:adapter,journalURL:directory.appendingPathComponent("answer-retention-journal.json"))
        if selection==nil || selection=="history-rows" {
            let id=try adapter.personalPlaces().first!.id
            let planner=RetentionPlanner(calls:[query(name:"Retention Cafe")],text:"Choose [[place:"+id+"]] for coffee.")
            let provider=RetentionProvider(adapter:adapter,engine:engine,planner:planner,fullCollection:false)
            let store=AskConversationStore(url:directory.appendingPathComponent("row-privacy.json"))
            let session=AskSession(index:try adapter.index(),provider:provider);session.restoreHistory(from:store);session.refreshIndex={try adapter.index()}
            session.input="Find a coffee shop";session.run();while session.isLoading {await Task.yield()};session.flushHistory()
            precondition(session.turns.last?.status == .complete && session.response?.publicConversationText != nil)
            var library=try store.loadLibrary();let original=library.chats[0]
            var privateResponse=original.conversation.turns[0].response
            privateResponse.publicConversationText=nil;privateResponse.collectionConversationText=nil
            privateResponse.agentTask = .init(action:"query",fields:["note"],orderedIDs:[id],sourcePolicy:"local_only",privateSelection:true)
            let privateTurn=AskArchivedTurn(.init(id:UUID(),request:.init(mode:.collection,text:"Show my PRIVATE_RENAME_NOTE",fromOCR:false),response:privateResponse,status:.complete))
            let hidden=AskChatArchive(id:UUID(),title:privateTurn.question,updatedAt:Date(),conversation:.init(turns:[privateTurn]))
            var manual=original;manual = .init(id:UUID(),title:"My deliberate PRIVATE_MANUAL title",updatedAt:original.updatedAt,conversation:original.conversation,lastActivityAt:original.lastActivityAt)
            var legacy=original.conversation.turns[0].response
            legacy.historyRecordIDs=nil;legacy.retainsIndependentQuestion=nil;legacy.paragraphs=[]
            legacy.agentTask = .init(action:"query",fields:[],orderedIDs:[id],sourcePolicy:"stored_only",privateSelection:false)
            let legacyTurn=AskArchivedTurn(.init(id:UUID(),request:.init(mode:.collection,text:"Explain LEGACY_UNKNOWN_PRIVATE_CONTEXT now",fromOCR:false),response:legacy,status:.complete))
            let legacyChat=AskChatArchive(id:UUID(),title:legacyTurn.question,updatedAt:Date(),conversation:.init(turns:[legacyTurn]))
            library.chats += [hidden,manual,legacyChat]
            precondition(store.saveLibrary(library));let bytes=try Data(contentsOf:store.url)
            let reopened=AskSession(index:try adapter.index(),provider:provider);reopened.restoreHistory(from:store)
            var reads=0;reopened.refreshIndex={reads+=1;return try adapter.index()}
            let permitted=reopened.historyRows()
            precondition(permitted.first {$0.id==original.id}!.preview.contains("Retention Cafe"),"Permitted public native previews must remain readable with one fresh access snapshot")
            visible=[]
            let denied=reopened.historyRows(),publicRow=denied.first {$0.id==original.id}!,privateRow=denied.first {$0.id==hidden.id}!,manualRow=denied.first {$0.id==manual.id}!
            precondition(!publicRow.accessibilityLabel.contains("Retention Cafe"),"History title/preview/accessibility leaked a revoked native candidate")
            precondition(!privateRow.title.contains("PRIVATE_RENAME_NOTE"),"The safe History title must also be the Rename prefill, not the raw automatic question")
            precondition(manualRow.title==manual.title,"An intentional manual name must not be redacted as generated context")
            let legacyRow=denied.first {$0.id==legacyChat.id}!
            precondition(!legacyRow.accessibilityLabel.contains("LEGACY_UNKNOWN_PRIVATE_CONTEXT") && !legacyRow.title.contains("LEGACY_UNKNOWN_PRIVATE_CONTEXT"),"Legacy unknown-origin questions must not escape through automatic titles, Rename, or preview fallback")
            let unchanged=try Data(contentsOf:store.url)
            precondition(reads==2 && denied.map(\.id)==AskHistoryPresentation.ordered(library.chats).map(\.id) && unchanged==bytes,"Permission projection must fetch access once, not reorder or rewrite stored chats")
            visible=[city.id!]
            print("PASS whole-library History rows redact revoked native previews/AX, share a safe Rename title, preserve manual names/order/archive bytes, and fetch access once")
        }
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
        if selection==nil || selection=="deleted-history" {
            let cafe=try adapter.personalPlaces()[0]
            let question="Show Retention Cafe details, then delete Retention Cafe"
            let proposal=AskChangeProposal(entity:"place",operation:"delete",targetIDs:[cafe.id],cityID:nil,sectionID:nil,mapMatchID:nil,changes:[],instructionQuote:question)
            let call=AskAgentReply.Call(name:"propose_changes",callID:"delete-history",arguments:String(data:try JSONEncoder().encode(proposal),encoding:.utf8)!)
            let planner=RetentionPlanner(calls:[query("details",name:"Retention Cafe",fields:["note"]),call],selector:.init(city:nil,name:"Retention Cafe",neighborhood:nil,cuisine:nil,status:nil,placeType:nil,scope:"library"))
            let store=AskConversationStore(url:directory.appendingPathComponent("deleted-history.json"))
            let provider=RetentionProvider(adapter:adapter,engine:engine,planner:planner)
            let session=AskSession(index:try adapter.index(),provider:provider);session.restoreHistory(from:store)
            func wire(_ session:AskSession) {
                session.refreshIndex={try adapter.index()}
                session.collectionStatus={try engine.actionStatus($0)}
                session.collectionExecutor={try engine.performExplicitAction($0,undo:$1)}
                session.historyDeletedRecordIDs={turn,ids in try engine.recoveryDeletedRecordIDs(forTurn:turn,includingActionIDs:Set(ids))}
            }
            wire(session);session.input=question;session.run();while session.isLoading {await Task.yield()}
            precondition(session.turns.last?.status == .complete)
            let turn=session.turns.last!.id,receipt=session.response!.collectionActions!.first!
            precondition(receipt.state == .needsConfirmation && AskAnswerCopy.text(session.response!).contains("Saved private detail"))
            session.applyCollectionAction(turn:turn,actionID:receipt.id,undo:false)
            let deleted=try adapter.personalPlaces();precondition(deleted.isEmpty)
            let own=session.presentedTurn(session.turns.last!)
            precondition(AskAnswerCopy.text(own.response!).contains("Saved private detail") && own.response?.collectionActions?.first?.undoable==true,"Verified own deletion should retain its accessible native result and Undo")
            session.flushHistory();visible=[]
            let reopened=AskSession(index:try adapter.index(),provider:provider);wire(reopened);reopened.restoreHistory(from:store)
            let hidden=reopened.presentedTurns()[0]
            let shown=AskAnswerCopy.text(hidden.response!)+hidden.sources.map(\.excerpt).joined()
            precondition(!shown.contains("Saved private detail") && hidden.response?.collectionActions?.first?.title=="Saved change" && hidden.response?.collectionActions?.first?.detail==nil)
            precondition(hidden.response?.collectionActions?.first?.id==receipt.id && hidden.response?.collectionActions?.first?.undoable==true,"Redacting details must not erase the generic receipt/Undo affordance")
            for source in session.turns.last!.sources {precondition(reopened.source(source.id)==nil)}
            try await AskHistoryProjectionTests.verifyRevokedArchive(store:store,adapter:adapter,engine:engine,forbidden:"Saved private detail")
            visible=[city.id!];reopened.applyCollectionAction(turn:turn,actionID:receipt.id,undo:true)
            let restored=try adapter.personalPlaces();precondition(restored.count==1 && restored[0].id==cafe.id)
            print("PASS actual native read/delete/explicit Apply/archive revoke preserves generic receipt and Undo, redacts before-image UI/sources/provider, and restores accessible own deletion")
        }
        if selection==nil || selection=="mixed-hidden" {
            let bar=try repo.createSavedPlace(from:.init(applePlaceID:"hidden-bar",displayNameSnapshot:"Internal Bar",status:.wantToTry,placeType:.bar,cuisines:[],tags:[],note:"Hidden query support",websiteURL:nil,instagramURL:nil,feastList:city,listSection:nil))
            let cafe=try adapter.personalPlaces().first {$0.name=="Retention Cafe"}!
            let planner=RetentionPlanner(calls:[query(name:"Retention Cafe"),query("answer",name:"Internal Bar")],text:"1. [[place:"+cafe.id+"]]")
            let store=AskConversationStore(url:directory.appendingPathComponent("mixed-hidden.json"))
            let session=AskSession(index:try adapter.index(),provider:RetentionProvider(adapter:adapter,engine:engine,planner:planner));session.restoreHistory(from:store)
            session.input="Show Retention Cafe, using Internal Bar only for supporting context";session.run();while session.isLoading {await Task.yield()}
            precondition(session.turns.last?.status == .complete,"An exact displayed-list synthesis must remain acceptable beside an internal answer query")
            precondition(session.response?.querySections?.count==2 && session.response?.querySections?.filter(\.displayed).count==1)
            precondition(session.response?.nativeMembership==Set([cafe.id,bar.id!.uuidString]) && session.response?.hasArchiveCompatibleBounds==true)
            precondition(session.response?.agentTask?.orderedIDs==[cafe.id] && session.response?.agentTask?.referencesIncomplete != true)
            let copied=AskAnswerCopy.text(session.response!);precondition(copied.contains("Retention Cafe") && !copied.contains("Internal Bar"))
            session.flushHistory();let restored=AskSession(index:try adapter.index(),provider:RetentionProvider(adapter:adapter,engine:engine,planner:planner));restored.restoreHistory(from:store)
            precondition(restored.response?.querySections==session.response?.querySections && AskAnswerCopy.text(restored.response!)==copied)
            try repo.delete(bar)
            print("PASS exact native-list replacement retains hidden-query membership without displaying it or granting its ordinal authority across archive reload")
        }
        if selection==nil || selection=="section-invalidation" || selection=="section-noop" {
            let bar=try repo.createSavedPlace(from:.init(applePlaceID:"invalidation-bar",displayNameSnapshot:"Invalidation Bar",status:.wantToTry,placeType:.bar,cuisines:[],tags:[],note:"",websiteURL:nil,instagramURL:nil,feastList:city,listSection:nil))
            let cafe=try context.fetch(NSFetchRequest<SavedPlace>(entityName:"SavedPlace")).first {$0.displayNameSnapshot=="Retention Cafe"}!,oldStatus=cafe.placeStatus
            for changed in [true,false] where selection != "section-noop" || !changed {
                cafe.placeStatus = .wantToTry;try context.save()
                let status=changed ? "Love" : "Want to try"
                let question="Show Retention Cafe and Invalidation Bar separately, mark Retention Cafe "+status+", then reread Invalidation Bar details"
                let proposal=AskChangeProposal(entity:"place",operation:"update",targetIDs:[cafe.id!.uuidString],cityID:nil,sectionID:nil,mapMatchID:nil,changes:[.init(field:"status",value:status,values:nil,findingID:nil,source:"user")],instructionQuote:question)
                let change=AskAgentReply.Call(name:"propose_changes",callID:"native-invalidation-"+String(changed),arguments:String(data:try JSONEncoder().encode(proposal),encoding:.utf8)!)
                let calls=[query(name:"Retention Cafe"),query(name:"Invalidation Bar"),change]+(changed ? [query(name:"Invalidation Bar"),query("details",scope:"previous",positions:[1])] : [])
                let planner=RetentionPlanner(calls:calls,text:"The current results are retained.",selector:.init(city:nil,name:"Retention Cafe",neighborhood:nil,cuisine:nil,status:nil,placeType:nil,scope:"library"))
                let session=AskSession(index:try adapter.index(),provider:RetentionProvider(adapter:adapter,engine:engine,planner:planner))
                session.input=question;session.run();while session.isLoading {await Task.yield()}
                let steps=await planner.steps()
                precondition(session.turns.last?.status == .complete)
                if changed {
                    precondition(cafe.placeStatus == .love && session.response?.collectionActions?.contains {$0.wasChanged && $0.targetIDs==[cafe.id!.uuidString]}==true,"The invalidation regression must execute the requested named write")
                    precondition(steps.last?.result?.output.status=="success" && steps.last?.result?.output.records.map(\.id)==[bar.id!.uuidString],"A successful conversational write must clear obsolete query ambiguity before a fresh single list is read")
                    precondition(session.response?.querySections?.allSatisfy {!$0.selectionIDs.contains(cafe.id!.uuidString)}==true)
                }else {
                    precondition(cafe.placeStatus == .wantToTry && steps.contains {$0.result?.output.status=="unchanged"} && session.response?.collectionActions?.allSatisfy {!$0.wasChanged}==true,"The preservation regression must execute a genuine no-op")
                    precondition(session.response?.querySections?.count==2 && session.response?.agentTask?.referencesIncomplete==true,"A no-op must not destroy still-valid independent native read snapshots")
                }
            }
            cafe.placeStatus=oldStatus;try context.save();try repo.delete(bar)
            print("PASS successful conversational writes clear obsolete section/page state before fresh reads, while no-op writes retain valid independent sections")
        }
        if selection==nil || selection=="section-confirm-invalidation" {
            let target=try repo.createSavedPlace(from:.init(applePlaceID:"confirm-invalidation",displayNameSnapshot:"Confirm Target",status:.wantToTry,placeType:.bar,cuisines:[],tags:[],note:"",websiteURL:nil,instagramURL:nil,feastList:city,listSection:nil))
            let targetID=target.id!.uuidString,cafeID=try adapter.personalPlaces().first {$0.name=="Retention Cafe"}!.id
            let proposal=AskChangeProposal(entity:"place",operation:"delete",targetIDs:[targetID],cityID:nil,sectionID:nil,mapMatchID:nil,changes:[],instructionQuote:"Delete Confirm Target")
            let grant=AskChangeGrant(question:proposal.instructionQuote,entity:"place",operations:["delete"],fields:[],targetIDs:[targetID],allowsCreation:false,boundProposal:proposal)
            let preview=try engine.prepare(proposal,question:proposal.instructionQuote,authorization:grant,findings:[])
            precondition(preview.state == .needsConfirmation)
            let request=AskRequest(mode:.collection,text:"Yes, delete Confirm Target, then reread Retention Cafe",fromOCR:false,pendingActions:[preview])
            let executor=AskAgentExecutor(adapter:adapter,engine:engine,request:request,researcher:RetentionResearcher(),searchMaps:{_ in []},fullCollectionContext:true,supportsCollectionQueryV2:true)
            let planner=RetentionPlanner(confirmPending:true)
            _ = try await executor.executeConversation(query(name:"Confirm Target"),planner:planner)
            _ = try await executor.executeConversation(query(name:"Retention Cafe"),planner:planner)
            let arguments=String(data:try JSONSerialization.data(withJSONObject:["actionIDs":[preview.id.uuidString]]),encoding:.utf8)!
            let effect=try await executor.executeConversation(.init(name:"confirm_changes",callID:"confirm-invalidation",arguments:arguments),planner:planner)
            precondition(effect.response?.collectionActions?.contains {$0.wasChanged && $0.targetIDs==[targetID]}==true)
            _ = try await executor.executeConversation(query(name:"Retention Cafe"),planner:planner)
            let read=try await executor.executeConversation(query("details",scope:"previous",positions:[1]),planner:planner)
            precondition(read.output.status=="success" && read.output.records.map(\.id)==[cafeID],"A confirmed write must clear obsolete section state before a fresh single-list reference")
            // Exercise the real Session/Loop merge path too: a confirmed write
            // cannot reattach a single list's old context to its action receipt.
            let pendingTarget=try repo.createSavedPlace(from:.init(applePlaceID:"confirm-session",displayNameSnapshot:"Confirm Session Target",status:.wantToTry,placeType:.bar,cuisines:[],tags:[],note:"",websiteURL:nil,instagramURL:nil,feastList:city,listSection:nil))
            let pendingID=pendingTarget.id!.uuidString,question="Show Confirm Session Target, then delete Confirm Session Target"
            let deletion=AskChangeProposal(entity:"place",operation:"delete",targetIDs:[pendingID],cityID:nil,sectionID:nil,mapMatchID:nil,changes:[],instructionQuote:question)
            let deleteCall=AskAgentReply.Call(name:"propose_changes",callID:"session-delete-preview",arguments:String(data:try JSONEncoder().encode(deletion),encoding:.utf8)!)
            let previewPlanner=RetentionPlanner(calls:[query(name:"Confirm Session Target"),deleteCall],selector:.init(city:nil,name:"Confirm Session Target",neighborhood:nil,cuisine:nil,status:nil,placeType:nil,scope:"library"))
            let store=AskConversationStore(url:directory.appendingPathComponent("confirm-invalidation-session.json"))
            let previewSession=AskSession(index:try adapter.index(),provider:RetentionProvider(adapter:adapter,engine:engine,planner:previewPlanner));previewSession.restoreHistory(from:store)
            previewSession.input=question;previewSession.run();while previewSession.isLoading {await Task.yield()};previewSession.flushHistory()
            let pending=previewSession.response!.collectionActions!.first!
            precondition(previewSession.turns.last?.status == .complete && pending.state == .needsConfirmation)
            let confirmArguments=String(data:try JSONSerialization.data(withJSONObject:["actionIDs":[pending.id.uuidString]]),encoding:.utf8)!
            let confirmingPlanner=RetentionPlanner(calls:[query(name:"Retention Cafe"),.init(name:"confirm_changes",callID:"session-confirm",arguments:confirmArguments)],text:"Saved.",confirmPending:true)
            let confirming=AskSession(index:try adapter.index(),provider:RetentionProvider(adapter:adapter,engine:engine,planner:confirmingPlanner));confirming.restoreHistory(from:store)
            confirming.input="Yes, delete Confirm Session Target";confirming.run();while confirming.isLoading {await Task.yield()}
            precondition(confirming.turns.last?.status == .complete && confirming.response?.collectionActions?.contains {$0.wasChanged && $0.targetIDs==[pendingID]}==true)
            precondition(confirming.response?.querySections==nil && confirming.response?.libraryContext==nil && confirming.response?.collectionPage==nil,"A confirmed mutation must not reattach a pre-write single-list context to the final action response")
            print("PASS confirmed pending changes invalidate executor section/page snapshots before fresh single-list references")
        }
        if selection==nil || selection=="sections" {
            let bar = try repo.createSavedPlace(from:.init(applePlaceID:"retention-bar",displayNameSnapshot:"Retention Bar",status:.wantToTry,placeType:.bar,cuisines:[],tags:[],note:"Independent bar detail",websiteURL:nil,instagramURL:nil,feastList:city,listSection:nil))
            let planner=RetentionPlanner(calls:[query(name:"Retention Cafe"),query(name:"Retention Bar")],text:"Here are both requested lists.")
            let store=AskConversationStore(url:directory.appendingPathComponent("independent-sections.json"))
            let session=AskSession(index:try adapter.index(),provider:RetentionProvider(adapter:adapter,engine:engine,planner:planner));session.restoreHistory(from:store);session.refreshIndex={try adapter.index()}
            session.input="Show Retention Cafe and Retention Bar in separate lists";session.run();while session.isLoading {await Task.yield()}
            precondition(session.turns.last?.status == .complete)
            let text=AskAnswerCopy.text(session.response!)
            precondition(text.contains("Retention Cafe") && text.contains("Retention Bar"),"The last native list replaced an independent earlier displayed list")
            precondition(session.response?.libraryContext==nil && session.response?.agentTask?.referencesIncomplete==true,"Independent sections must not silently grant the last list's ordinal authority")
            session.flushHistory()
            let originalSectionLibrary=try store.loadLibrary()
            func isolatedSections()throws->AskConversationStore {
                let copy=AskConversationStore(url:directory.appendingPathComponent(UUID().uuidString+"-sections.json"))
                precondition(copy.saveLibrary(originalSectionLibrary));return copy
            }
            let reopened=AskSession(index:try adapter.index(),provider:RetentionProvider(adapter:adapter,engine:engine,planner:planner));reopened.restoreHistory(from:try isolatedSections())
            precondition(AskAnswerCopy.text(reopened.response!)==text && reopened.response?.agentTask?.referencesIncomplete==true)
            precondition(session.response?.querySections?.count==2)
            let followup=RetentionPlanner(calls:[query("details",scope:"previous",positions:[1])],text:"Which result section did you mean?")
            let after=AskSession(index:try adapter.index(),provider:RetentionProvider(adapter:adapter,engine:engine,planner:followup));after.restoreHistory(from:try isolatedSections())
            after.input="Show the first of those";after.run();while after.isLoading {await Task.yield()}
            let followupSteps=await followup.steps()
            precondition(followupSteps.last?.result?.output.status=="ambiguous" && followupSteps.last?.result?.output.records.isEmpty==true)
            for calls in [[query(name:"Retention Cafe"),query("count",name:"Retention Bar")],[query(name:"Retention Cafe"),query("details",name:"Retention Bar")],[query(name:"Retention Cafe"),.init(name:"search_maps",callID:"supporting-map",arguments:"{\"query\":\"Harbor Bakery\",\"cityID\":null}")]] {
                let mixedPlanner=RetentionPlanner(calls:calls,text:"Here are the requested results.")
                let mixed=AskSession(index:try adapter.index(),provider:RetentionProvider(adapter:adapter,engine:engine,planner:mixedPlanner,maps:Array(ApplePlacesService.previewMatches.prefix(1))))
                mixed.input="Show the saved cafe and the additional result";mixed.run();while mixed.isLoading {await Task.yield()}
                precondition(mixed.turns.last?.status == .complete && AskAnswerCopy.text(mixed.response!).contains("Retention Cafe"),"A supporting count/detail/Maps result erased an independent native list")
            }
            let extra=try repo.createSavedPlace(from:.init(applePlaceID:"section-extra",displayNameSnapshot:"Supplemental Restaurant",status:.wantToTry,placeType:.restaurant,cuisines:[],tags:[],note:"",websiteURL:nil,instagramURL:nil,feastList:city,listSection:nil))
            let extraID=extra.id!.uuidString
            let mentioningPlanner=RetentionPlanner(calls:[query(name:"Retention Cafe"),query(name:"Retention Bar")],text:"Both lists are above. [[place:"+extraID+"]] is an additional mention, not either list.")
            let mentioningStore=AskConversationStore(url:directory.appendingPathComponent("section-extra-history.json"))
            let mentioning=AskSession(index:try adapter.index(),provider:RetentionProvider(adapter:adapter,engine:engine,planner:mentioningPlanner));mentioning.restoreHistory(from:mentioningStore)
            mentioning.input="Show two separate saved lists and mention Supplemental Restaurant";mentioning.run();while mentioning.isLoading {await Task.yield()}
            precondition(mentioning.turns.last?.status == .complete && mentioning.response?.answerMentionIDs==[extraID] && mentioning.response?.querySections?.allSatisfy {!$0.selectionIDs.contains(extraID)}==true,"An extra answer mention must never enter native section membership")
            mentioning.flushHistory()
            let mentionReload=AskSession(index:try adapter.index(),provider:RetentionProvider(adapter:adapter,engine:engine,planner:mentioningPlanner));mentionReload.restoreHistory(from:mentioningStore)
            precondition(mentionReload.response?.answerMentionIDs==[extraID] && mentionReload.response?.querySections==mentioning.response?.querySections)
            for (answer,expected) in [("1. [[place:"+bar.id!.uuidString+"]]\n2. [[place:"+session.response!.querySections![0].selectionIDs[0]+"]]",true),("1. [[place:"+extraID+"]]",false)] {
                let synthesis=RetentionPlanner(calls:[query("answer",name:"Retention Cafe"),query("answer",name:"Retention Bar")],text:answer)
                let synthesized=AskSession(index:try adapter.index(),provider:RetentionProvider(adapter:adapter,engine:engine,planner:synthesis))
                synthesized.input="Recommend from these two saved query inputs";synthesized.run();while synthesized.isLoading {await Task.yield()}
                precondition(synthesized.turns.last?.status == .complete && synthesized.response?.querySections?.allSatisfy {!$0.displayed}==true)
                precondition((synthesized.response?.agentTask?.referencesIncomplete != true)==expected,"Only an explicit in-query synthesized subset may own answer-mode follow-up order")
                if !expected {precondition(synthesized.response?.agentTask?.orderedIDs.isEmpty==true)}
            }
            try repo.delete(extra)
            let cafe=try adapter.personalPlaces().first {$0.name=="Retention Cafe"}!
            let change=AskChangeProposal(entity:"place",operation:"update",targetIDs:[cafe.id],cityID:nil,sectionID:nil,mapMatchID:nil,changes:[.init(field:"status",value:"Love",values:nil,findingID:nil,source:"user")],instructionQuote:"Mark Retention Cafe Love")
            let write=AskAgentReply.Call(name:"propose_changes",callID:"named-write",arguments:String(data:try JSONEncoder().encode(change),encoding:.utf8)!)
            let named=RetentionPlanner(calls:[write],text:"Saved.",selector:.init(city:nil,name:"Retention Cafe",neighborhood:nil,cuisine:nil,status:nil,placeType:nil,scope:"library"))
            let writable=AskSession(index:try adapter.index(),provider:RetentionProvider(adapter:adapter,engine:engine,planner:named));writable.restoreHistory(from:try isolatedSections())
            writable.input="Mark Retention Cafe Love";writable.run();while writable.isLoading {await Task.yield()}
            precondition(writable.turns.last?.status == .complete && writable.response?.collectionActions?.contains(where:{$0.state == .applied})==true,"Named targets must remain independently writable after ambiguous sections")
            let savedCafe=try adapter.personalPlaces().first {$0.id==cafe.id};precondition(savedCafe?.status==PlaceStatus.love.rawValue)
            let ambiguousProposal=AskChangeProposal(entity:change.entity,operation:change.operation,targetIDs:change.targetIDs,cityID:nil,sectionID:nil,mapMatchID:nil,changes:change.changes,instructionQuote:"Mark the first of those Love")
            let ambiguousCall=AskAgentReply.Call(name:"propose_changes",callID:"ambiguous-exact-quote",arguments:String(data:try JSONEncoder().encode(ambiguousProposal),encoding:.utf8)!)
            let ambiguous=RetentionPlanner(calls:[ambiguousCall],text:"Which list did you mean?",selector:.init(city:nil,name:nil,neighborhood:nil,cuisine:nil,status:nil,placeType:nil,scope:"previous",positions:[1]))
            let blocked=AskSession(index:try adapter.index(),provider:RetentionProvider(adapter:adapter,engine:engine,planner:ambiguous));blocked.restoreHistory(from:try isolatedSections())
            blocked.input="Mark the first of those Love";blocked.run();while blocked.isLoading {await Task.yield()}
            precondition(blocked.response?.collectionActions?.contains(where:{$0.state == .applied}) != true && blocked.response?.executionStatus=="needs_confirmation")
            let sectionChange=AskChangeProposal(entity:"place",operation:"update",targetIDs:[cafe.id],cityID:nil,sectionID:nil,mapMatchID:nil,changes:[.init(field:"status",value:"Been",values:nil,findingID:nil,source:"user")],instructionQuote:"Mark the first place in Section 1 Been")
            let sectionWrite=AskAgentReply.Call(name:"propose_changes",callID:"section-write",arguments:String(data:try JSONEncoder().encode(sectionChange),encoding:.utf8)!)
            let scoped=RetentionPlanner(calls:[sectionWrite],text:"Saved.",selector:.init(city:nil,name:nil,neighborhood:nil,cuisine:nil,status:nil,placeType:nil,scope:"previous",positions:[1]))
            let explicit=AskSession(index:try adapter.index(),provider:RetentionProvider(adapter:adapter,engine:engine,planner:scoped));explicit.restoreHistory(from:try isolatedSections())
            explicit.input="Mark the first place in Section 1 Been";explicit.run();while explicit.isLoading {await Task.yield()}
            precondition(explicit.response?.collectionActions?.contains(where:{$0.state == .applied && $0.targetIDs==[cafe.id]})==true,"A user-selected section must retain its own exact ordinal authority")
            let wrong=AskChangeProposal(entity:change.entity,operation:change.operation,targetIDs:[bar.id!.uuidString],cityID:nil,sectionID:nil,mapMatchID:nil,changes:change.changes,instructionQuote:"Mark the first place in Section 1 Love")
            let wrongCall=AskAgentReply.Call(name:"propose_changes",callID:"wrong-section-target",arguments:String(data:try JSONEncoder().encode(wrong),encoding:.utf8)!)
            let wrongPlanner=RetentionPlanner(calls:[wrongCall],text:"Saved.",selector:.init(city:nil,name:nil,neighborhood:nil,cuisine:nil,status:nil,placeType:nil,scope:"previous",positions:[1]))
            let wrongSession=AskSession(index:try adapter.index(),provider:RetentionProvider(adapter:adapter,engine:engine,planner:wrongPlanner));wrongSession.restoreHistory(from:try isolatedSections())
            wrongSession.input="Mark the first place in Section 1 Love";wrongSession.run();while wrongSession.isLoading {await Task.yield()}
            precondition(wrongSession.response?.collectionActions?.contains(where:{$0.state == .applied}) != true,"An explicit model target must not escape the human-selected section")
            for question in ["Mark the first in Section 1 and Section 2 Love","Mark the first in Section 1 or 2 Love","Do not change Section 1","Change Section 2 instead of Section 1","Mark the first in Section 1 from the earlier answer Love","Mark the first place in Section 1 from two answers ago Love","Mark the first place in Section 1 in the answer before the last one Love","Mark the first place in Section 1 from the fourth answer Love","Mark the first place in Section 1 from the latest and an older answer Love","From two answers ago, mark the first place in Section 1 Love","In the answer before the last one, mark the first place in Section 1 Love","Last week, mark the first place in Section 1 Love","Mark the first in Section 99 Love"] {
                let unsafeProposal=AskChangeProposal(entity:change.entity,operation:change.operation,targetIDs:change.targetIDs,cityID:nil,sectionID:nil,mapMatchID:nil,changes:change.changes,instructionQuote:question)
                let unsafeCall=AskAgentReply.Call(name:"propose_changes",callID:UUID().uuidString,arguments:String(data:try JSONEncoder().encode(unsafeProposal),encoding:.utf8)!)
                let unsafe=RetentionPlanner(calls:[unsafeCall],text:"Saved.",selector:.init(city:nil,name:nil,neighborhood:nil,cuisine:nil,status:nil,placeType:nil,scope:"previous",positions:[1]))
                let check=AskSession(index:try adapter.index(),provider:RetentionProvider(adapter:adapter,engine:engine,planner:unsafe));check.restoreHistory(from:try isolatedSections())
                check.input=question;check.run();while check.isLoading {await Task.yield()}
                precondition(check.response?.collectionActions?.contains(where:{$0.state == .applied}) != true,"Conflicting, negated or older section references must not choose the latest section: "+question)
            }
            for (open,close) in [("'","'"),("\"","\""),("‘","’"),("“","”")] {
                let quoted1=open+"Section 1"+close,quoted2=open+"Section 2"+close
                for (first,second,target) in [(quoted1,"Section 2",bar.id!.uuidString),("Section 2",quoted1,bar.id!.uuidString),("Section 1",quoted2,cafe.id),(quoted2,"Section 1",cafe.id),(quoted1,quoted2,bar.id!.uuidString),(quoted2,quoted1,cafe.id),(open+"the first place in Section 1"+close,"Section 2",bar.id!.uuidString)] {
                    let quotedQuestion="Mark the first place in "+first+" and the first place in "+second+" Love"
                    let quotedProposal=AskChangeProposal(entity:change.entity,operation:change.operation,targetIDs:[target],cityID:nil,sectionID:nil,mapMatchID:nil,changes:change.changes,instructionQuote:quotedQuestion)
                    let quotedCall=AskAgentReply.Call(name:"propose_changes",callID:UUID().uuidString,arguments:String(data:try JSONEncoder().encode(quotedProposal),encoding:.utf8)!)
                    let quotedPlanner=RetentionPlanner(calls:[quotedCall],text:"",selector:.init(city:nil,name:nil,neighborhood:nil,cuisine:nil,status:nil,placeType:nil,scope:"previous",positions:[1]))
                    let quoted=AskSession(index:try adapter.index(),provider:RetentionProvider(adapter:adapter,engine:engine,planner:quotedPlanner));quoted.restoreHistory(from:try isolatedSections())
                    quoted.input=quotedQuestion;quoted.run();while quoted.isLoading {await Task.yield()}
                    precondition(quoted.response?.collectionActions?.contains {$0.state == .applied} != true && bar.placeStatus == .wantToTry,"A quoted section target must not disappear and silently authorize only another section: "+quotedQuestion)
                }
            }
            let latestQuestion="Mark the first place in Section 1 of the latest answer Love"
            let latestProposal=AskChangeProposal(entity:change.entity,operation:change.operation,targetIDs:change.targetIDs,cityID:change.cityID,sectionID:change.sectionID,mapMatchID:change.mapMatchID,changes:change.changes,instructionQuote:latestQuestion)
            let latestCall=AskAgentReply.Call(name:"propose_changes",callID:UUID().uuidString,arguments:String(data:try JSONEncoder().encode(latestProposal),encoding:.utf8)!)
            let latestPlanner=RetentionPlanner(calls:[latestCall],text:"",selector:.init(city:nil,name:nil,neighborhood:nil,cuisine:nil,status:nil,placeType:nil,scope:"previous",positions:[1]))
            let latest=AskSession(index:try adapter.index(),provider:RetentionProvider(adapter:adapter,engine:engine,planner:latestPlanner));latest.restoreHistory(from:try isolatedSections())
            latest.input=latestQuestion;latest.run();while latest.isLoading {await Task.yield()}
            precondition(latest.response?.collectionActions?.contains {$0.state == .applied && $0.targetIDs==[cafe.id]}==true,"An explicit latest-answer section reference must remain supported")
            let currentQuestion="In the current answer, mark the first place in Section 1 Been"
            let currentProposal=AskChangeProposal(entity:change.entity,operation:change.operation,targetIDs:[cafe.id],cityID:nil,sectionID:nil,mapMatchID:nil,changes:[.init(field:"status",value:"Been",values:nil,findingID:nil,source:"user")],instructionQuote:currentQuestion)
            let currentCall=AskAgentReply.Call(name:"propose_changes",callID:"current-section",arguments:String(data:try JSONEncoder().encode(currentProposal),encoding:.utf8)!)
            let currentPlanner=RetentionPlanner(calls:[currentCall],text:"",selector:.init(city:nil,name:nil,neighborhood:nil,cuisine:nil,status:nil,placeType:nil,scope:"previous",positions:[1]))
            let current=AskSession(index:try adapter.index(),provider:RetentionProvider(adapter:adapter,engine:engine,planner:currentPlanner));current.restoreHistory(from:try isolatedSections())
            current.input=currentQuestion;current.run();while current.isLoading {await Task.yield()}
            precondition(current.response?.collectionActions?.contains {$0.state == .applied && $0.targetIDs==[cafe.id]}==true,"A supported current-answer prefix must remain scoped to the exact latest section")
            let oldNote=try adapter.personalPlaces().first {$0.id==cafe.id}!.note
            let noteQuestion="Add 'try after lunch' to the note of the first place in Section 1"
            let noteProposal=AskChangeProposal(entity:"place",operation:"append",targetIDs:[cafe.id],cityID:nil,sectionID:nil,mapMatchID:nil,changes:[.init(field:"note",value:"try after lunch",values:nil,findingID:nil,source:"user")],instructionQuote:noteQuestion)
            let noteCall=AskAgentReply.Call(name:"propose_changes",callID:"quoted-note-value",arguments:String(data:try JSONEncoder().encode(noteProposal),encoding:.utf8)!)
            let notePlanner=RetentionPlanner(calls:[noteCall],text:"",selector:.init(city:nil,name:nil,neighborhood:nil,cuisine:nil,status:nil,placeType:nil,scope:"previous",positions:[1]))
            let note=AskSession(index:try adapter.index(),provider:RetentionProvider(adapter:adapter,engine:engine,planner:notePlanner));note.restoreHistory(from:try isolatedSections())
            note.input=noteQuestion;note.run();while note.isLoading {await Task.yield()}
            precondition(note.response?.collectionActions?.contains {$0.state == .applied}==true,"A quoted note value must remain compatible with an unambiguous current section target")
            let notePlace=try context.fetch(NSFetchRequest<SavedPlace>(entityName:"SavedPlace")).first {$0.id?.uuidString==cafe.id}!
            precondition(notePlace.note?.contains("try after lunch")==true);notePlace.note=oldNote;try context.save()
            let spoofed=RetentionPlanner(calls:[ambiguousCall],text:"Saved.",selector:.init(city:nil,name:"Retention Cafe",neighborhood:nil,cuisine:nil,status:nil,placeType:nil,scope:"library"))
            let guessed=AskSession(index:try adapter.index(),provider:RetentionProvider(adapter:adapter,engine:engine,planner:spoofed));guessed.restoreHistory(from:try isolatedSections())
            guessed.input="Mark the first of those Love";guessed.run();while guessed.isLoading {await Task.yield()}
            precondition(guessed.response?.collectionActions?.contains(where:{$0.state == .applied}) != true && guessed.response?.executionStatus=="needs_confirmation","Model-supplied names/UUIDs must not resolve an ambiguous human ordinal")
            // Repeated labels are bound to the newest response, not an older Section 1.
            let reversedPlanner=RetentionPlanner(calls:[query(name:"Retention Bar"),query(name:"Retention Cafe")],text:"Here are the newer lists.")
            let repeatedStore=try isolatedSections()
            let repeated=AskSession(index:try adapter.index(),provider:RetentionProvider(adapter:adapter,engine:engine,planner:reversedPlanner));repeated.restoreHistory(from:repeatedStore)
            repeated.input="Show Retention Bar first and Retention Cafe second in separate lists";repeated.run();while repeated.isLoading {await Task.yield()}
            precondition(repeated.turns.last?.status == .complete);repeated.flushHistory()
            let newestTurn=repeated.turns.last!.id
            let newestChange=AskChangeProposal(entity:"place",operation:"update",targetIDs:[bar.id!.uuidString],cityID:nil,sectionID:nil,mapMatchID:nil,changes:change.changes,instructionQuote:"Mark the first place in Section 1 Love")
            let newestCall=AskAgentReply.Call(name:"propose_changes",callID:"newest-section",arguments:String(data:try JSONEncoder().encode(newestChange),encoding:.utf8)!)
            let newestPlanner=RetentionPlanner(calls:[newestCall],text:"Saved.",selector:.init(city:nil,name:nil,neighborhood:nil,cuisine:nil,status:nil,placeType:nil,scope:"previous",positions:[1]))
            let newest=AskSession(index:try adapter.index(),provider:RetentionProvider(adapter:adapter,engine:engine,planner:newestPlanner));newest.restoreHistory(from:repeatedStore)
            newest.input=newestChange.instructionQuote;newest.run();while newest.isLoading {await Task.yield()}
            precondition(newest.turns.last?.request.referenceSectionsTurnID==newestTurn && newest.response?.collectionActions?.contains(where:{$0.state == .applied && $0.targetIDs==[bar.id!.uuidString]})==true,"Repeated section labels must select only the exact newest answer")
            visible=[]
            let revokedPlanner=RetentionPlanner(calls:[sectionWrite],text:"Unavailable.",selector:.init(city:nil,name:nil,neighborhood:nil,cuisine:nil,status:nil,placeType:nil,scope:"previous",positions:[1]))
            let revoked=AskSession(index:try adapter.index(),provider:RetentionProvider(adapter:adapter,engine:engine,planner:revokedPlanner));revoked.restoreHistory(from:try isolatedSections())
            revoked.input="Mark the first place in Section 1 Been";revoked.run();while revoked.isLoading {await Task.yield()}
            precondition(revoked.response?.collectionActions?.contains(where:{$0.state == .applied}) != true,"A section reference must not reauthorize revoked records")
            visible=[city.id!]
            let mutationQuestion="Show Retention Cafe and Retention Bar, then mark Retention Cafe Regulars"
            let realChange=AskChangeProposal(entity:"place",operation:"update",targetIDs:[cafe.id],cityID:nil,sectionID:nil,mapMatchID:nil,changes:[.init(field:"status",value:"Regulars",values:nil,findingID:nil,source:"user")],instructionQuote:mutationQuestion)
            let mutation=AskAgentReply.Call(name:"propose_changes",callID:"real-native-invalidation",arguments:String(data:try JSONEncoder().encode(realChange),encoding:.utf8)!)
            let invalidated=RetentionPlanner(calls:[query(name:"Retention Cafe"),query(name:"Retention Bar"),mutation],text:"Saved.",selector:.init(city:nil,name:"Retention Cafe",neighborhood:nil,cuisine:nil,status:nil,placeType:nil,scope:"library"))
            let changing=AskSession(index:try adapter.index(),provider:RetentionProvider(adapter:adapter,engine:engine,planner:invalidated))
            changing.input=mutationQuestion;changing.run();while changing.isLoading {await Task.yield()}
            precondition(changing.response?.querySections==nil,"A successful write must invalidate earlier native section snapshots")
            try repo.delete(bar)
            let missingPlanner=RetentionPlanner(calls:[query("details",scope:"previous",positions:[1])],text:"That saved result is no longer available.")
            let missing=AskSession(index:try adapter.index(),provider:RetentionProvider(adapter:adapter,engine:engine,planner:missingPlanner));missing.restoreHistory(from:try isolatedSections())
            missing.input="Show the first place in Section 2";missing.run();while missing.isLoading {await Task.yield()}
            let missingSteps=await missingPlanner.steps()
            precondition(missingSteps.last?.result?.output.status=="stale" && missingSteps.last?.result?.output.records.isEmpty==true,"A missing section member must not shift an ordinal to a surviving different list")
            print("PASS independent native sections retain both lists through actual Session/archive reload; ambiguous follow-up positions never pick the last list or union membership")
        }
        if selection==nil || selection=="note-value-compatibility" {
            let bar=try repo.createSavedPlace(from:.init(applePlaceID:"section-note-bar",displayNameSnapshot:"Note Value Bar",status:.wantToTry,placeType:.bar,cuisines:[],tags:[],note:"Original bar note",websiteURL:nil,instagramURL:nil,feastList:city,listSection:nil))
            let cafe=try context.fetch(NSFetchRequest<SavedPlace>(entityName:"SavedPlace")).first {$0.displayNameSnapshot=="Retention Cafe"}!,oldCafeNote=cafe.note
            let initialPlanner=RetentionPlanner(calls:[query(name:"Retention Cafe"),query(name:"Note Value Bar")],text:"Both lists are shown.")
            let store=AskConversationStore(url:directory.appendingPathComponent("section-note-values.json"))
            let initial=AskSession(index:try adapter.index(),provider:RetentionProvider(adapter:adapter,engine:engine,planner:initialPlanner));initial.restoreHistory(from:store)
            initial.input="Show two independent lists";initial.run();while initial.isLoading {await Task.yield()};precondition(initial.turns.last?.status == .complete);initial.flushHistory()
            let library=try store.loadLibrary()
            for kind in ["named","filter","section"] {
                for operation in ["append","update"] {
                    precondition(store.saveLibrary(library));bar.note="Original bar note";cafe.note="Original cafe note";try context.save()
                    let target=kind=="filter" ? cafe : bar
                    let phrase=kind=="named" ? "Note Value Bar" : kind=="filter" ? "all cafes" : "the first place in Section 2"
                    let value=kind=="section" ? "Section 1" : operation=="append" ? "Section 1" : "Do not choose the first place in Section 2"
                    let question=operation=="append" ? "Add '"+value+"' to the note of "+phrase : "Set the note on "+phrase+" to \""+value+"\""
                    let selector=AskAgentSelector(city:nil,name:kind=="named" ? "Note Value Bar" : nil,neighborhood:nil,cuisine:nil,status:nil,placeType:kind=="filter" ? "Cafe" : nil,scope:kind=="section" ? "previous" : "library",positions:kind=="section" ? [1] : nil)
                    let proposal=AskChangeProposal(entity:"place",operation:operation,targetIDs:[target.id!.uuidString],cityID:nil,sectionID:nil,mapMatchID:nil,changes:[.init(field:"note",value:value,values:nil,findingID:nil,source:"user")],instructionQuote:question)
                    let call=AskAgentReply.Call(name:"propose_changes",callID:UUID().uuidString,arguments:String(data:try JSONEncoder().encode(proposal),encoding:.utf8)!)
                    let planner=RetentionPlanner(calls:[call],text:"",selector:selector,replaceExisting:operation=="update")
                    let session=AskSession(index:try adapter.index(),provider:RetentionProvider(adapter:adapter,engine:engine,planner:planner));session.restoreHistory(from:store)
                    session.input=question;session.run();while session.isLoading {await Task.yield()}
                    let applied=session.response?.collectionActions?.contains {$0.state == .applied && $0.targetIDs==[target.id!.uuidString]}==true
                    if kind=="section" {
                        precondition(!applied && target.note=="Original bar note","The new bounded Section N shortcut must clarify a quoted section-label value rather than guess")
                    }else {
                        precondition(applied,"Existing explicit named/filter note edits must retain arbitrary quoted values: "+question)
                        let original=kind=="filter" ? "Original cafe note" : "Original bar note"
                        precondition(target.note==(operation=="append" ? original+"\n"+value : value))
                    }
                }
            }
            cafe.note=oldCafeNote;try context.save();try repo.delete(bar)
            print("PASS existing named/filter note append/set retain arbitrary quoted Section N values; only the new bounded literal-section shortcut clarifies without writing")
        }
        if selection==nil || selection=="section-redaction" {
            let hiddenCity=try repo.createFeastList(named:"Hidden Section City")
            let hiddenCafe = try repo.createSavedPlace(from:.init(applePlaceID:"hidden-section",displayNameSnapshot:"HIDDEN_SECTION_CAFE",status:.wantToTry,placeType:.cafe,cuisines:[],tags:[],note:"HIDDEN_SECTION_NOTE",websiteURL:nil,instagramURL:nil,feastList:hiddenCity,listSection:nil))
            let extra=try repo.createSavedPlace(from:.init(applePlaceID:"section-privacy-mention",displayNameSnapshot:"Supplemental Restaurant",status:.wantToTry,placeType:.restaurant,cuisines:[],tags:[],note:"",websiteURL:nil,instagramURL:nil,feastList:city,listSection:nil))
            let cafe=try context.fetch(NSFetchRequest<SavedPlace>(entityName:"SavedPlace")).first {$0.displayNameSnapshot=="Retention Cafe"}!
            let before=cafe.placeStatus;cafe.placeStatus = .wantToTry;try context.save()
            visible=[city.id!,hiddenCity.id!]
            let planner=RetentionPlanner(calls:[query(name:"HIDDEN_SECTION_CAFE"),query(name:"Retention Cafe")],text:"Both lists. [[place:"+extra.id!.uuidString+"]] is only a supplementary mention.")
            let provider=RetentionProvider(adapter:adapter,engine:engine,planner:planner)
            let store=AskConversationStore(url:directory.appendingPathComponent("section-redaction.json"))
            let session=AskSession(index:try adapter.index(),provider:provider);session.restoreHistory(from:store);session.refreshIndex={try adapter.index()}
            session.input="Show the two separate saved lists";session.run();while session.isLoading {await Task.yield()};session.flushHistory()
            precondition(session.response?.querySections?.count==2 && session.response!.querySections!.allSatisfy {!$0.selectionIDs.contains(extra.id!.uuidString)})
            let library=try store.loadLibrary()
            for revoked in [true,false] {
                cafe.placeStatus = .wantToTry;try context.save()
                visible=revoked ? [city.id!] : [city.id!,hiddenCity.id!]
                if !revoked {try repo.delete(hiddenCafe)}
                let shown=session.presentedTurns()[0].response!,copy=AskAnswerCopy.text(shown)
                precondition(!copy.contains("HIDDEN_SECTION_") && copy.contains("Section 1") && copy.contains("Section 2") && copy.contains("Retention Cafe"),"A fully revoked first section must keep stable non-sensitive numbering, not hide or renumber the remaining section")
                precondition(session.historyRows().allSatisfy {!$0.accessibilityLabel.contains("HIDDEN_SECTION_")})
                let providerStore=AskConversationStore(url:directory.appendingPathComponent(UUID().uuidString+"-section-provider.json"));precondition(providerStore.saveLibrary(library))
                try await AskHistoryProjectionTests.verifyRevokedArchive(store:providerStore,adapter:adapter,engine:engine,forbidden:"HIDDEN_SECTION_",requiredHistory:"Retention Cafe")
                for number in [1,2] {
                    let read=RetentionPlanner(calls:[query("details",scope:"previous",positions:[1])],text:"I checked that section.")
                    let readStore=AskConversationStore(url:directory.appendingPathComponent(UUID().uuidString+"-section-read.json"));precondition(readStore.saveLibrary(library))
                    let reading=AskSession(index:try adapter.index(),provider:RetentionProvider(adapter:adapter,engine:engine,planner:read));reading.restoreHistory(from:readStore)
                    reading.input="Show the first place in Section \(number)";reading.run();while reading.isLoading {await Task.yield()}
                    let readSteps=await read.steps(),records=readSteps.compactMap(\.result).flatMap { $0.output.records }
                    precondition(number==1 ? records.isEmpty : records.map(\.id)==[cafe.id!.uuidString],"Revoked Section 1 cannot become surviving Section 2 during a real follow-up read")
                    let question="Mark the first place in Section \(number) Love"
                    let proposal=AskChangeProposal(entity:"place",operation:"update",targetIDs:[cafe.id!.uuidString],cityID:nil,sectionID:nil,mapMatchID:nil,changes:[.init(field:"status",value:"Love",values:nil,findingID:nil,source:"user")],instructionQuote:question)
                    let call=AskAgentReply.Call(name:"propose_changes",callID:UUID().uuidString,arguments:String(data:try JSONEncoder().encode(proposal),encoding:.utf8)!)
                    let change=RetentionPlanner(calls:[call],text:"",selector:.init(city:nil,name:nil,neighborhood:nil,cuisine:nil,status:nil,placeType:nil,scope:"previous",positions:[1]))
                    let writeStore=AskConversationStore(url:directory.appendingPathComponent(UUID().uuidString+"-section-write.json"));precondition(writeStore.saveLibrary(library))
                    let writing=AskSession(index:try adapter.index(),provider:RetentionProvider(adapter:adapter,engine:engine,planner:change));writing.restoreHistory(from:writeStore)
                    writing.input=question;writing.run();while writing.isLoading {await Task.yield()}
                    precondition((writing.response?.collectionActions?.contains {$0.state == .applied}==true)==(number==2))
                    precondition(cafe.placeStatus==(number==2 ? .love : .wantToTry),"A Section 1 write must not target formerly Section 2")
                }
            }
            cafe.placeStatus=before;try context.save();try repo.delete(hiddenCity);try repo.delete(extra)
            print("PASS full Section 1 revocation/deletion preserves Section 2 numbering in UI/Copy/History and actual scoped reads/writes, without granting supplementary mentions")
        }
        if selection==nil || selection=="section-common-name" {
            let bar=try repo.createSavedPlace(from:.init(applePlaceID:"common-name-bar",displayNameSnapshot:"Named Bar",status:.wantToTry,placeType:.bar,cuisines:[],tags:[],note:"",websiteURL:nil,instagramURL:nil,feastList:city,listSection:nil))
            for name in ["First","Those","The First Place","All","Section 1","Those Cafes","All Cafes","Both Bars","First Two Cafes","First Watch"] {
                let collision=try repo.createSavedPlace(from:.init(applePlaceID:"collision-"+name,displayNameSnapshot:name,status:.wantToTry,placeType:.restaurant,cuisines:[],tags:[],note:"",websiteURL:nil,instagramURL:nil,feastList:city,listSection:nil))
                let firstPlanner=RetentionPlanner(calls:[query(name:"Retention Cafe"),query(name:"Named Bar")],text:"Here are both lists.")
                let store=AskConversationStore(url:directory.appendingPathComponent(UUID().uuidString+"-word-collision.json"))
                let initial=AskSession(index:try adapter.index(),provider:RetentionProvider(adapter:adapter,engine:engine,planner:firstPlanner));initial.restoreHistory(from:store)
                initial.input="Show Retention Cafe and Named Bar in separate lists";initial.run();while initial.isLoading {await Task.yield()};precondition(initial.turns.last?.status == .complete);initial.flushHistory()
                let original=try store.loadLibrary()
                let reference=["Those Cafes","All Cafes","Both Bars","First Two Cafes"].contains(name) ? "Mark "+name.lowercased()+" Love" : name=="Section 1" ? "Mark the first place in Section 1 Love" : name=="All" ? "Mark all of those Love" : "Mark the first place of those Love"
                let explicit=name=="All" || name=="Section 1" ? "Mark \""+name+"\" Love" : name=="First Watch" ? "Mark First Watch Love" : "Mark the saved place named "+name+" Love"
                for (question,allowed) in [(reference,false),(explicit,true)] {
                    precondition(store.saveLibrary(original))
                    let proposal=AskChangeProposal(entity:"place",operation:"update",targetIDs:[collision.id!.uuidString],cityID:nil,sectionID:nil,mapMatchID:nil,changes:[.init(field:"status",value:"Love",values:nil,findingID:nil,source:"user")],instructionQuote:question)
                    let call=AskAgentReply.Call(name:"propose_changes",callID:UUID().uuidString,arguments:String(data:try JSONEncoder().encode(proposal),encoding:.utf8)!)
                    let planner=RetentionPlanner(calls:[call],text:"Saved.",selector:.init(city:nil,name:name,neighborhood:nil,cuisine:nil,status:nil,placeType:nil,scope:"library"))
                    let session=AskSession(index:try adapter.index(),provider:RetentionProvider(adapter:adapter,engine:engine,planner:planner));session.restoreHistory(from:store)
                    session.input=question;session.run();while session.isLoading {await Task.yield()}
                    let applied=session.response?.collectionActions?.contains {$0.state == .applied}==true
                    precondition(applied==allowed,"A positional word colliding with a saved name must not resolve ambiguous sections; an explicit named target must still work")
                    precondition(collision.placeStatus==(allowed ? .love : .wantToTry))
                }
                try repo.delete(collision)
            }
            // Reference-grammar precedence must not turn ordinary explicit
            // plural filters into a blanket named-target-only restriction.
            let cafe=try context.fetch(NSFetchRequest<SavedPlace>(entityName:"SavedPlace")).first {$0.displayNameSnapshot=="Retention Cafe"}!
            cafe.placeStatus = .wantToTry;try context.save()
            let allStore=AskConversationStore(url:directory.appendingPathComponent("explicit-all-cafes.json"))
            let allInitial=AskSession(index:try adapter.index(),provider:RetentionProvider(adapter:adapter,engine:engine,planner:RetentionPlanner(calls:[query(name:"Retention Cafe"),query(name:"Named Bar")],text:"Both lists.")))
            allInitial.restoreHistory(from:allStore);allInitial.input="Show separate lists";allInitial.run();while allInitial.isLoading {await Task.yield()};allInitial.flushHistory()
            let allLibrary=try allStore.loadLibrary()
            let allProposal=AskChangeProposal(entity:"place",operation:"update",targetIDs:[cafe.id!.uuidString],cityID:nil,sectionID:nil,mapMatchID:nil,changes:[.init(field:"status",value:"Love",values:nil,findingID:nil,source:"user")],instructionQuote:"Mark all cafes Love")
            let allCall=AskAgentReply.Call(name:"propose_changes",callID:UUID().uuidString,arguments:String(data:try JSONEncoder().encode(allProposal),encoding:.utf8)!)
            let allPlanner=RetentionPlanner(calls:[allCall],text:"",selector:.init(city:nil,name:nil,neighborhood:nil,cuisine:nil,status:nil,placeType:"Cafe",scope:"library"))
            let allSession=AskSession(index:try adapter.index(),provider:RetentionProvider(adapter:adapter,engine:engine,planner:allPlanner));allSession.restoreHistory(from:allStore)
            allSession.input="Mark all cafes Love";allSession.run();while allSession.isLoading {await Task.yield()}
            precondition(allSession.response?.collectionActions?.contains {$0.state == .applied}==true && cafe.placeStatus == .love,"An explicit plural category scope must remain writable across independent lists")
            city.name="First City";cafe.placeStatus = .wantToTry;try context.save();precondition(allStore.saveLibrary(allLibrary))
            let cityQuestion="Mark all cafes in First City Love"
            let cityProposal=AskChangeProposal(entity:"place",operation:"update",targetIDs:[cafe.id!.uuidString],cityID:nil,sectionID:nil,mapMatchID:nil,changes:[.init(field:"status",value:"Love",values:nil,findingID:nil,source:"user")],instructionQuote:cityQuestion)
            let cityCall=AskAgentReply.Call(name:"propose_changes",callID:UUID().uuidString,arguments:String(data:try JSONEncoder().encode(cityProposal),encoding:.utf8)!)
            let cityPlanner=RetentionPlanner(calls:[cityCall],text:"",selector:.init(city:"First City",name:nil,neighborhood:nil,cuisine:nil,status:nil,placeType:"Cafe",scope:"library"))
            let citySession=AskSession(index:try adapter.index(),provider:RetentionProvider(adapter:adapter,engine:engine,planner:cityPlanner));citySession.restoreHistory(from:allStore)
            citySession.input=cityQuestion;citySession.run();while citySession.isLoading {await Task.yield()}
            precondition(citySession.response?.collectionActions?.contains {$0.state == .applied}==true && cafe.placeStatus == .love,"A normal explicit city name containing an ordinal word must not be rejected as a positional reference")
            city.name="Retention City";try context.save()

            try repo.delete(bar)
            print("PASS common-word business names cannot turn ambiguous section ordinals into named writes; explicit named, quoted, and plural-category targets still apply")
        }
        if selection==nil || selection=="section-pages" {
            var temporary:[SavedPlace]=[]
            for type in [PlaceType.cafe,.bar] {
                let count=type == .cafe ? 204 : 205
                for i in 0..<count {
                    let place=SavedPlace(context:context);place.id=UUID();place.displayNameSnapshot="Section "+type.rawValue+String(format:" %03d",i);place.applePlaceID="section-"+type.rawValue+String(i);place.feastList=city;place.placeStatus = .wantToTry;place.placeTypeValue=type;place.cuisines=[];place.tags=[];place.createdAt=Date();place.updatedAt=Date();temporary.append(place)
                }
            }
            try context.save()
            func page(_ type:PlaceType,offset:Int=0,snapshot:String?=nil)->AskAgentReply.Call {
                var q:[String:Any] = ["operation":"list","scope":"library","positions":[],"fields":[],"placeType":type.rawValue,"offset":offset,"limit":200]
                if let snapshot {q["snapshot"]=snapshot}
                return .init(name:"query_collection",callID:UUID().uuidString,arguments:String(data:try! JSONSerialization.data(withJSONObject:["entity":"place","query":q]),encoding:.utf8)!)
            }
            let paused=SectionPagePlanner([page(.cafe),page(.bar)],interrupt:true)
            let store=AskConversationStore(url:directory.appendingPathComponent("section-pages.json"))
            let session=AskSession(index:try adapter.index(),provider:RetentionProvider(adapter:adapter,engine:engine,planner:paused));session.restoreHistory(from:store)
            session.input="Show my cafe and bar lists separately";session.run();while session.isLoading {await Task.yield()}
            precondition(session.turns.last?.status == .complete && session.response?.candidates.count==400 && session.response?.querySections?.count==2)
            let sections=session.response!.querySections!
            precondition(sections.allSatisfy {$0.page?.nextOffset==200 && $0.selectionIDs.count==205} && session.response?.agentTask?.referencesIncomplete==true)
            session.flushHistory()
            let finishing=SectionPagePlanner([page(.cafe,offset:200,snapshot:sections[0].page!.snapshot),page(.bar,offset:200,snapshot:sections[1].page!.snapshot)])
            let reopened=AskSession(index:try adapter.index(),provider:RetentionProvider(adapter:adapter,engine:engine,planner:finishing));reopened.restoreHistory(from:store)
            reopened.input="Continue both separate lists";reopened.run();while reopened.isLoading {await Task.yield()}
            precondition(reopened.turns.last?.status == .complete && reopened.response?.candidates.count==410 && reopened.response?.querySections?.count==2,"Independent section pagination lost earlier native rows after archive restart")
            func assertSectionLayout(_ response:AskResponse) {
                let sections=response.querySections!.filter(\.displayed)
                let expected=sections.flatMap(\.paragraphIDs),native=Set(expected)
                let actual=response.paragraphs.filter {native.contains($0.id)}.map(\.id)
                precondition(actual==expected,"Each independently paged section must keep all its native paragraphs together in its own order")
                for section in sections {
                    let heading=response.paragraphs.firstIndex {$0.id=="section-heading-"+String(section.id.prefix(24))}!
                    let start=response.paragraphs.firstIndex {$0.id==section.paragraphIDs.first}!
                    precondition(start==heading+1,"A section heading must stay immediately above its own native rows")
                }
            }
            let final=reopened.response!.querySections!
            precondition(final.allSatisfy {$0.page?.returnedCount==205 && $0.page?.nextOffset==nil && $0.context?.ids.count==205})
            precondition(reopened.response?.libraryContext==nil && reopened.response?.agentTask?.referencesIncomplete==true)
            assertSectionLayout(reopened.response!)
            let text=AskAnswerCopy.text(reopened.response!);precondition(text.contains("Section 1") && text.contains("Section 2") && text.contains("Section Bar 204"))
            precondition(text.range(of:"Section Cafe 203")!.lowerBound<text.range(of:"Section 2:")!.lowerBound,"Copied cafe tail rows must not appear under the bar section heading")
            reopened.flushHistory()
            let restored=AskSession(index:try adapter.index(),provider:RetentionProvider(adapter:adapter,engine:engine,planner:finishing));restored.restoreHistory(from:store)
            assertSectionLayout(restored.response!)
            precondition(AskAnswerCopy.text(restored.response!)==text,"Archive reload must preserve the contiguous section presentation")
            // Re-querying the first page replaces only that section, without
            // moving it below a later section or dropping the later section's tail.
            let refreshPlanner=SectionPagePlanner([page(.cafe),page(.bar),page(.cafe,offset:200,snapshot:sections[0].page!.snapshot),page(.bar,offset:200,snapshot:sections[1].page!.snapshot),page(.cafe)])
            let refresh=AskSession(index:try adapter.index(),provider:RetentionProvider(adapter:adapter,engine:engine,planner:refreshPlanner))
            refresh.input="Show separate cafe and bar lists, then refresh the cafe page";refresh.run();while refresh.isLoading {await Task.yield()}
            precondition(refresh.turns.last?.status == .complete && refresh.response?.querySections?.map {$0.page?.returnedCount}==[200,205])
            assertSectionLayout(refresh.response!)
            let refreshedText=AskAnswerCopy.text(refresh.response!)
            precondition(!refreshedText.contains("Section Cafe 203") && refreshedText.contains("Section Bar 204"))
            for place in temporary {context.delete(place)};try context.save()
            print("PASS independent 205-row lists retain400 interrupted rows and resume each exact query to410 contiguous section rows across Session/archive reload and page replacement without merged ordinal authority")
        }
        if selection==nil || selection=="section-recovery" {
            let bar=try repo.createSavedPlace(from:.init(applePlaceID:"recovery-bar",displayNameSnapshot:"Recovery Bar",status:.wantToTry,placeType:.bar,cuisines:[],tags:[],note:"",websiteURL:nil,instagramURL:nil,feastList:city,listSection:nil))
            let fetch=SavedPlace.fetchRequest();fetch.predicate=NSPredicate(format:"displayNameSnapshot == %@","Retention Cafe")
            let grouped=try context.fetch(fetch).first!;grouped.cuisines=["Thai","Vietnamese"];try context.save()
            let wire=SectionRecoveryWire(calls:[query(name:"Retention Cafe",groupBy:"cuisine"),query(name:"Recovery Bar")])
            let history=AskConversationStore(url:directory.appendingPathComponent("section-recovery-history.json"))
            let checkpoints=AskTurnRecoveryStore(directory:directory.appendingPathComponent("section-recovery-checkpoints"),requirePersistence:true)
            let hosted=AskHostedProvider(configuration:.init(environment:.development,endpoint:URL(string:"https://section-fixture.workers.dev/v1/answer")!,scope:.savedMetadata),token:{String(repeating:"S",count:43)},approve:{_,_ in true},send:{try await wire.send($0)},libraryToolsEnabled:{true},permission:{true},libraryPlanVersion:{7},nativeResearchEnabled:{true},recoveryEnabled:{true})
            let provider=AskAgentProvider(remote:hosted,fallback:hosted,adapter:adapter,engine:engine,searchMaps:{_ in []},recoveryStore:checkpoints)
            let session=AskSession(index:try adapter.index(),provider:provider);session.restoreHistory(from:history);session.refreshIndex={try adapter.index()}
            session.input="Show Retention Cafe and Recovery Bar in separate lists";session.run();while session.isLoading {await Task.yield()}
            let turn=session.turns.last!.id,saved=try checkpoints.checkpoint(turn)!
            precondition(saved.phase == .awaitingReply && saved.state.latest?.querySections?.count==2)
            let original=saved.state.latest!.querySections!
            precondition(original[0].displayOrder?.count==2 && original[0].selectionIDs.count==1,"Grouped native occurrences must be independently retained")
            precondition(saved.state.selectionIsOrdered==false && saved.state.referencesIncomplete==true)
            session.setAppActive(false)
            let fresh=AskTurnRecoveryStore(directory:checkpoints.directory,requirePersistence:true)
            let resumedProvider=AskAgentProvider(remote:hosted,fallback:hosted,adapter:adapter,engine:engine,searchMaps:{_ in []},recoveryStore:fresh)
            let resumed=AskSession(index:try adapter.index(),provider:resumedProvider);resumed.refreshIndex={try adapter.index()};resumed.restoreHistory(from:history);resumed.restorePendingRecovery()
            for _ in 0..<20_000 {if !resumed.isLoading && resumed.turns.last?.status == .complete {break};try await Task.sleep(nanoseconds:1_000_000)}
            let sends=await wire.submits
            precondition(resumed.turns.last?.status == .complete && resumed.response?.querySections==original && sends==3,"Recovery must retain exact independent section metadata without replaying accepted calls")
            resumed.flushHistory()
            let readPlanner=RetentionPlanner(calls:[query("details",scope:"previous",positions:[1])],text:"Here is the chosen section's first place.")
            let read=AskSession(index:try adapter.index(),provider:RetentionProvider(adapter:adapter,engine:engine,planner:readPlanner));read.restoreHistory(from:history)
            read.input="Show the first place in Section 2";read.run();while read.isLoading {await Task.yield()}
            let steps=await readPlanner.steps()
            precondition(read.turns.last?.status == .complete && steps.last?.result?.output.records.map(\.id)==[bar.id!.uuidString],"A user-selected recovered section must preserve exact read order")
            try repo.delete(bar);grouped.cuisines=[];try context.save()
            print("PASS actual lost-ack Session recovery preserves independent query sections and exact selected-section follow-up without any accepted-call replay")
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
