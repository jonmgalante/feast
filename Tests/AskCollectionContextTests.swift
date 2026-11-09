import Foundation
import CoreData

private struct CollectionContextResearch:AskBusinessResearching {
    func publicLookupAvailable()async->Bool {false}
    func businessResearch(_ request:AskBusinessRequest)async throws->AskBusinessResult {preconditionFailure("No external calls in collection tests")}
}
private actor CollectionContextConversation:AskConversationPlanning {
    let calls:[AskAgentReply.Call]
    var seen:[AskConversationStep]=[]
    let stopAfterFirst:Bool,onePage:Bool,native:Bool,replacementText:String?
    init(_ calls:[AskAgentReply.Call],stopAfterFirst:Bool=false,onePage:Bool=false,replacementText:String?=nil,native:Bool=false) {self.calls=calls;self.stopAfterFirst=stopAfterFirst;self.onePage=onePage;self.replacementText=replacementText;self.native=native}
    func conversationAvailable()async->Bool {true}
    func nativeResearchAvailable()async->Bool {native}
    func conversationStep(_ step:AskConversationStep)async throws->AskConversationReply {
        seen.append(step)
        let call:AskAgentReply.Call?
        if step.step==0 {call=calls[0]}
        else if step.step==1 && stopAfterFirst {throw AskHostedError.service(503)}
        else if step.step==1 && !onePage {
            let output=step.result!.output
            let data=Data(calls[1].arguments.utf8)
            var object=try JSONSerialization.jsonObject(with:data) as! [String:Any]
            var query=object["query"] as! [String:Any]
            query["offset"]=output.nextOffset!;query["snapshot"]=output.snapshot!
            object["query"]=query
            call = .init(name:"query_collection",callID:"page2",arguments:String(data:try JSONSerialization.data(withJSONObject:object),encoding:.utf8)!)
        }else {call=nil}
        return .init(version:9,requestID:step.requestID,step:step.step,kind:call==nil ? "answer" : "tool",text:call==nil ? replacementText ?? "These are your saved matches." : "",continuation:"synthetic",model:"gpt-6.1-sol",call:call)
    }
    func searchConversationWeb(_ query:String)async throws->AskWebResearchResult {preconditionFailure("No external calls")}
    func authorizePendingConfirmation(_ actions:[AskCollectionAction],question:String,history:[String])async throws->AskHumanAuthorization {preconditionFailure("No writes")}
    func authorizeConversationChange(_ proposal:AskChangeProposal,question:String,history:[String],targets:[AskAgentRecord])async throws->AskHumanAuthorization {preconditionFailure("No writes")}
    func steps()->[AskConversationStep] {seen}
}
@MainActor enum AskCollectionContextTests {
    static func run(model:NSManagedObjectModel,temporaryDirectory:URL)async throws {
        let olderKeys=["AskFeast.onlinePermission.cloudflare-openai.catalog-public-dialogue-selected-images.v4",
                       "AskFeast.onlinePermission.cloudflare-openai.permitted-collection-dialogue-selected-images.v5"]
        let defaults=UserDefaults.standard,keys=olderKeys+[AskPrivacy.onlineKey]
        let previous=keys.reduce(into:[String:Any]()) {saved,key in if let value=defaults.object(forKey:key) {saved[key]=value}}
        defer {for key in keys {if let value=previous[key] {defaults.set(value,forKey:key)}else{defaults.removeObject(forKey:key)}}}
        for key in olderKeys {defaults.set(true,forKey:key)}
        defaults.removeObject(forKey:AskPrivacy.onlineKey)
        precondition(AskPrivacy.onlineKey.hasSuffix("selected-images-recovery.v6"))
        precondition(!AskPrivacy.onlineAllowed && !olderKeys.contains(AskPrivacy.onlineKey))
        AskPrivacy.accept();precondition(AskPrivacy.onlineAllowed)
        AskPrivacy.withdraw();precondition(!AskPrivacy.onlineAllowed)
        // Older grants remain untouched and never restore a withdrawn or
        // absent recovery-inclusive grant.
        precondition(olderKeys.allSatisfy {defaults.bool(forKey:$0)})
        defaults.removeObject(forKey:AskPrivacy.onlineKey);precondition(!AskPrivacy.onlineAllowed)
        for term in ["Cloudflare","OpenAI","notes","tags","statuses","shared","temporarily stores request data and answers","24-hour recovery window"] {precondition(AskPrivacy.disclosure.contains(term))}
        print("PASS recovery-inclusive v6 consent defaults off, does not migrate v4/v5 grants, and preserves explicit accept/withdraw behavior")
        let coordinator=NSPersistentStoreCoordinator(managedObjectModel:model)
        _ = try coordinator.addPersistentStore(ofType:NSSQLiteStoreType,configurationName:nil,at:temporaryDirectory.appendingPathComponent("rich-collection.sqlite"))
        let context=NSManagedObjectContext(concurrencyType:.mainQueueConcurrencyType);context.persistentStoreCoordinator=coordinator
        let repo=FeastRepository(context:context),city=try repo.createFeastList(named:"Synthetic City"),hidden=try repo.createFeastList(named:"Hidden City")
        let neighborhood=try repo.createListSection(named:"North Quarter",in:city)
        var places:[SavedPlace]=[]
        for i in 0..<260 {places.append(try repo.createSavedPlace(from:.init(applePlaceID:"synthetic-context-\(i)",displayNameSnapshot:String(format:"Cafe %03d",i),status:.love,placeType:.cafe,cuisines:["Coffee"],tags:["Quiet"],note:i==259 ? "Collaborator note: jazz piano on Tuesdays" : "Synthetic shared preference",websiteURL:nil,instagramURL:nil,feastList:city,listSection:neighborhood)))}
        _ = try repo.createSavedPlace(from:.init(applePlaceID:"hidden-context",displayNameSnapshot:"Hidden Cafe",status:.love,placeType:.cafe,cuisines:[],tags:["Secret"],note:"Never accessible",websiteURL:nil,instagramURL:nil,feastList:hidden,listSection:nil))
        let secondCity=try repo.createFeastList(named:"Synthetic Second City")
        var visible=Set([city.id!,secondCity.id!])
        let adapter=AskSavedCollection(context:context,visibleCities:{visible})
        let engine=AskCollectionChangeEngine(adapter:adapter,journalURL:temporaryDirectory.appendingPathComponent("rich-actions.json"))
        let request=AskRequest(mode:.collection,text:"List all my cafes",fromOCR:false,performanceID:UUID())
        let snapshot=try adapter.librarySnapshot()
        precondition(snapshot.totalCount==260 && snapshot.places.allSatisfy {$0.note==nil && $0.tags==nil})
        let rich=try AskSemanticContext.make(request,catalog:snapshot,fullCollection:true)
        precondition(rich.totalCount==260 && rich.collectionAccess=="permitted_details_v1")
        let richData=try JSONEncoder().encode(rich);precondition(richData.count<=24000)
        let tiny=(0..<400).map {_ in AskPersonalPlace(id:UUID().uuidString,name:"A",status:nil,type:nil,cuisines:[],city:"B",neighborhood:"")}
        let budgeted=try AskSemanticContext.make(request,catalog:.init(places:tiny,totalCount:tiny.count),fullCollection:true)
        let budgetedData=try JSONEncoder().encode(budgeted);precondition(budgeted.index.count>200 && budgeted.indexComplete==false && budgetedData.count<=24000)
        func query(_ operation:String="list",offset:Int?=nil,snapshot:String?=nil,search:String?=nil,fields:[String]=[],positions:[Int]=[],scope:String="library",entity:String="place")->AskAgentReply.Call {
            var q:[String:Any] = ["operation":operation,"scope":scope,"positions":positions,"fields":fields]
            if let offset {q["offset"]=offset};if let snapshot {q["snapshot"]=snapshot};if let search {q["searchText"]=search}
            return .init(name:"query_collection",callID:UUID().uuidString,arguments:String(data:try! JSONSerialization.data(withJSONObject:["entity":entity,"query":q]),encoding:.utf8)!)
        }
        let interpretation=AskAgentInterpretation(goal:"query",sourcePolicy:"public_if_missing",fields:[],selectionIDs:[],permissions:[])
        let executor=AskAgentExecutor(adapter:adapter,engine:engine,request:request,researcher:CollectionContextResearch(),searchMaps:{_ in []},fullCollectionContext:true)
        let found=try await executor.execute(query("details",search:"jazz",fields:["note","tags","status","neighborhood","type"]),intent:interpretation)
        precondition(found.output.records.count==1 && found.output.records[0].id==places[259].id!.uuidString)
        precondition(found.output.records[0].note!.contains("Collaborator") && found.output.records[0].tags==["Quiet"] && found.output.records[0].status=="Love" && !found.output.localOnly)
        let foundData=try JSONEncoder().encode(found.output);precondition(!String(data:foundData,encoding:.utf8)!.contains("Never accessible"))
        let first=try await executor.execute(query(),intent:interpretation)
        precondition(first.output.records.count==200 && first.output.totalCount==260 && !first.output.complete && first.output.nextOffset==200)
        let second=try await executor.execute(query(offset:200,snapshot:first.output.snapshot),intent:interpretation)
        precondition(second.output.records.count==60 && second.output.nextOffset==nil && !second.output.complete && second.selectionIsOrdered)
        precondition(Set(first.output.records.map(\.id)+second.output.records.map(\.id)).count==260)
        let ordinal=try await executor.execute(query("details",positions:[250],scope:"previous"),intent:interpretation)
        precondition(ordinal.output.records.map(\.name)==["Cafe 249"])
        places[0].displayNameSnapshot="Cafe changed";try context.save()
        let stale=try await executor.execute(query(offset:200,snapshot:first.output.snapshot),intent:interpretation)
        precondition(stale.output.status=="stale" && stale.output.records.isEmpty)
        places[0].note=String(repeating:"x",count:5000);try context.save()
        let count=try await executor.execute(query("count"),intent:interpretation)
        precondition(count.output.totalCount==260 && count.output.complete && count.output.summary!.contains("260"))
        let legacy=AskAgentExecutor(adapter:adapter,engine:engine,request:request,researcher:CollectionContextResearch(),searchMaps:{_ in []})
        do {_ = try await legacy.execute(query(search:"jazz"),intent:interpretation);preconditionFailure("Rich selector accepted by legacy path")}catch {}
        let pageExecutor=AskAgentExecutor(adapter:adapter,engine:engine,request:request,researcher:CollectionContextResearch(),searchMaps:{_ in []},fullCollectionContext:true)
        let planner=CollectionContextConversation([query(),query()])
        let localView=try adapter.readView(),tools=try AskReadTools(request:request,index:localView.index)
        let answer=try await AskConversationLoop(planner:planner,availableCandidates:[:],execute:{call in try await pageExecutor.execute(call,intent:interpretation)}).answer(request,context:rich,cities:[],findings:[])
        precondition(answer.candidates.count==260 && answer.collectionPage?.returnedCount==260 && answer.collectionPage?.nextOffset==nil)
        _ = try tools.checked(answer)
        precondition(answer.agentTask?.orderedIDs.count==260)
        precondition(answer.collectionConversationText != nil && answer.publicConversationText==nil)
        let steps=await planner.steps()
        try JSONEncoder().encode(steps[1]).write(to:URL(fileURLWithPath:"/tmp/feast-collection-synthetic-wire.json"))
        let interruptedPlanner=CollectionContextConversation([query()],stopAfterFirst:true)
        let interruptedExecutor=AskAgentExecutor(adapter:adapter,engine:engine,request:request,researcher:CollectionContextResearch(),searchMaps:{_ in []},fullCollectionContext:true)
        let interrupted=try await AskConversationLoop(planner:interruptedPlanner,availableCandidates:[:],execute:{call in try await interruptedExecutor.execute(call,intent:interpretation)}).answer(request,context:rich,cities:[],findings:[])
        precondition(interrupted.collectionPage?.nextOffset==200 && interrupted.agentTask?.selectionIDs?.count==260 && interrupted.collectionConversationText!.contains("nextOffset 200"))
        let interruptedStore=AskConversationStore(url:temporaryDirectory.appendingPathComponent("interrupted-rich.json"))
        precondition(interruptedStore.save(.init(turns:[AskArchivedTurn(.init(id:UUID(),request:request,response:interrupted,status:.complete))])))
        let restored=interruptedStore.load().turns[0].turn
        var resumed=request;resumed.collectionContinuation=restored.response;resumed.agentTask=restored.response!.agentTask;resumed.collectionDialogue=AskConversationProjection.messages([restored],fullCollection:true);resumed.dialogue=resumed.collectionDialogue
        let resumedExecutor=AskAgentExecutor(adapter:adapter,engine:engine,request:resumed,researcher:CollectionContextResearch(),searchMaps:{_ in []},fullCollectionContext:true)
        let resumedPlanner=CollectionContextConversation([query(offset:200,snapshot:interrupted.collectionPage!.snapshot)],onePage:true)
        let resumedAnswer=try await AskConversationLoop(planner:resumedPlanner,availableCandidates:[:],execute:{call in try await resumedExecutor.execute(call,intent:interpretation)}).answer(resumed,context:rich,cities:[],findings:[])
        precondition(resumedAnswer.candidates.count==260 && resumedAnswer.collectionPage?.nextOffset==nil && resumedAnswer.agentTask?.orderedIDs.count==260)
        _ = try tools.checked(resumedAnswer)
        let resumedText=resumedAnswer.paragraphs.flatMap(\.spans).compactMap {if case .text(let value)=$0{return value};return nil}.joined()
        precondition(!resumedText.contains("Earlier results were kept.") && !resumedText.contains("Some work is unfinished."))
        let replacement=answer.candidates.enumerated().map {"\($0.offset+1). [[place:\($0.element.id)]]"}.joined(separator:"\n")
        let replacementPlanner=CollectionContextConversation([query(),query()],replacementText:replacement)
        let replacementExecutor=AskAgentExecutor(adapter:adapter,engine:engine,request:request,researcher:CollectionContextResearch(),searchMaps:{_ in []},fullCollectionContext:true)
        let replacementAnswer=try await AskConversationLoop(planner:replacementPlanner,availableCandidates:[:],execute:{call in try await replacementExecutor.execute(call,intent:interpretation)}).answer(request,context:rich,cities:[],findings:[])
        precondition(replacementAnswer.paragraphs.count==1 && replacementAnswer.candidates.count==260)
        _ = try tools.checked(replacementAnswer)
        let nativePlanner=CollectionContextConversation([query("details",search:"jazz",fields:["note"])],onePage:true,native:true)
        let nativeExecutor=AskAgentExecutor(adapter:adapter,engine:engine,request:request,researcher:CollectionContextResearch(),searchMaps:{_ in []},fullCollectionContext:true)
        _ = try await AskConversationLoop(planner:nativePlanner,availableCandidates:[:],execute:{call in try await nativeExecutor.execute(call,intent:interpretation)}).answer(request,context:rich,cities:[],findings:[])
        let nativeSteps=await nativePlanner.steps();precondition(nativeSteps.count==2 && nativeSteps.allSatisfy {$0.webAllowed==true} && nativeSteps[1].result?.output.records.first?.note?.contains("Collaborator")==true)
        let historyNativePlanner=CollectionContextConversation([query("details",search:"jazz",fields:["note"])],onePage:true,native:true)
        _ = try await AskConversationLoop(planner:historyNativePlanner,availableCandidates:[:],execute:{call in try await nativeExecutor.execute(call,intent:interpretation)}).answer(resumed,context:rich,cities:[],findings:[])
        let historyNativeSteps=await historyNativePlanner.steps();precondition(historyNativeSteps.allSatisfy {$0.webAllowed==true})
        let cityList=try await executor.execute(query(entity:"city"),intent:interpretation)
        precondition(cityList.output.records.count==2)
        let cityOrdinal=try await executor.execute(query("details",positions:[2],scope:"previous",entity:"city"),intent:interpretation)
        precondition(cityOrdinal.output.records.map(\.name)==["Synthetic Second City"])
        visible=[]
        let revoked=try await executor.execute(query("count"),intent:interpretation)
        precondition(revoked.output.totalCount==0 && revoked.output.records.isEmpty)
        visible=[city.id!,secondCity.id!]
        let endpoint=URL(string:"https://feast-owner-validation.jonmgalante.workers.dev/v1/answer")!
        let unsupported=AskHostedProvider(configuration:.init(environment:.production,endpoint:endpoint,scope:.savedMetadata,productionHost:"feast-owner-validation.jonmgalante.workers.dev",ownerValidation:true),token:{preconditionFailure("Unsupported rich capability read credentials")},approve:{_,_ in true},send:{_ in preconditionFailure("Unsupported rich capability transmitted data")},libraryToolsEnabled:{true},permission:{true},libraryPlanVersion:{6})
        do {_ = try await unsupported.conversationStep(.init(requestID:UUID().uuidString,step:0,text:"Synthetic",context:rich,cities:[],task:nil,findings:[],history:[],continuation:nil,result:nil));preconditionFailure("Unsupported rich backend accepted")}catch AskHostedError.disabled {}
        let archive=AskConversationStore(url:temporaryDirectory.appendingPathComponent("rich-history.json"))
        let turn=AskTurn(id:request.performanceID!,request:request,response:answer,status:.complete)
        // Rich history is separate from the legacy public projection.
        precondition(AskConversationProjection.messages([turn],fullCollection:true).last?.text==answer.collectionConversationText)
        precondition(AskConversationProjection.messages([turn]).allSatisfy {!$0.text.contains("Collection page: snapshot")})
        precondition(archive.save(.init(turns:[AskArchivedTurn(turn)])))
        let loaded=archive.load();precondition(loaded.turns.first?.response.collectionPage==answer.collectionPage && loaded.turns.first?.response.candidates.count==260)
        print("PASS rich collection: fresh consent, permission scope, notes/tags/status, >200 retrieval, byte budget, snapshots, ordinal250, count with oversized note, complete paged display and history; synthetic only")
    }
}
