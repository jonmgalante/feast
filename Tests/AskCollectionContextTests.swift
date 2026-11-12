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
private actor CollectionQueryHTTPFixture {
    let call:AskAgentReply.Call,expectedIDs:[String]
    private var count=0
    init(call:AskAgentReply.Call,expectedIDs:[String]) {self.call=call;self.expectedIDs=expectedIDs}
    func send(_ request:URLRequest)throws->(Data,HTTPURLResponse) {
        let payload=try JSONSerialization.jsonObject(with:request.httpBody!) as! [String:Any]
        precondition(request.url?.path=="/v1/answer" && payload["mode"] as? String=="conversationStep")
        precondition(payload["version"] as? Int==10 && payload["collectionQueryVersion"] as? Int==2)
        let step=payload["step"] as! Int
        precondition(step==count && step<2);count+=1
        if step==1 {
            let output=(payload["result"] as! [String:Any])["output"] as! [String:Any]
            let records=output["records"] as! [[String:Any]]
            precondition(output["totalCount"] as? Int==41 && output["complete"] as? Bool==true && records.compactMap {$0["id"] as? String}==expectedIDs)
            precondition(records.allSatisfy {$0["instagram"] is NSNull && $0["note"]==nil && $0["status"]==nil})
        }
        let reply:[String:Any] = ["version":10,"requestID":payload["requestID"]!,"step":step,"kind":step==0 ? "tool" : "answer","text":"","continuation":"synthetic-direct-query","model":"gpt-6.1-sol","call":step==0 ? ["name":call.name,"callID":call.callID,"arguments":call.arguments] : NSNull(),"nativeEvidence":["version":1,"blocks":[],"sources":[],"actions":[]],"finalCitations":[]]
        return (try JSONSerialization.data(withJSONObject:reply),HTTPURLResponse(url:request.url!,statusCode:200,httpVersion:nil,headerFields:["Content-Type":"application/json"])!)
    }
    func calls()->Int {count}
}
@MainActor enum AskCollectionContextTests {
    static func run(model:NSManagedObjectModel,temporaryDirectory:URL)async throws {
        try await auditQueryContracts(model:model,temporaryDirectory:temporaryDirectory)
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
        for term in ["Cloudflare","OpenAI","questions","recent conversation","relevant collection details","shared notes","search providers","public websites","may retain"] {precondition(AskPrivacy.disclosure.contains(term))}
        for term in ["chosen images","24-hour","recovery window","temporarily stores"] {precondition(!AskPrivacy.disclosure.contains(term))}
        print("PASS recovery-off disclosure states essential external data sharing without inactive image/recovery claims; existing consent behavior unchanged")
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
        try await queryV2(model:model,temporaryDirectory:temporaryDirectory)
        print("PASS rich collection: fresh consent, permission scope, notes/tags/status, >200 retrieval, byte budget, snapshots, ordinal250, count with oversized note, complete paged display and history; synthetic only")
    }
    private static func queryV2(model:NSManagedObjectModel,temporaryDirectory:URL)async throws {
        let coordinator=NSPersistentStoreCoordinator(managedObjectModel:model)
        _ = try coordinator.addPersistentStore(ofType:NSSQLiteStoreType,configurationName:nil,at:temporaryDirectory.appendingPathComponent("query-v2.sqlite"))
        let context=NSManagedObjectContext(concurrencyType:.mainQueueConcurrencyType);context.persistentStoreCoordinator=coordinator
        let repo=FeastRepository(context:context),nyc=try repo.createFeastList(named:"NYC"),large=try repo.createFeastList(named:"Large City"),hidden=try repo.createFeastList(named:"Hidden City")
        _ = try repo.createListSection(named:"Saved Neighborhood",in:nyc)
        var nycPlaces:[SavedPlace]=[],largePlaces:[SavedPlace]=[]
        for i in 0..<157 {
            nycPlaces.append(try repo.createSavedPlace(from:.init(applePlaceID:"query-nyc-\(i)",displayNameSnapshot:String(format:"NYC Place %03d",i),status:.love,placeType:.restaurant,cuisines:["Italian"],tags:["Collaborator tag"],note:"Collaborator note not requested",websiteURL:"https://example.org/\(i)",instagramURL:i<41 ? nil : "https://www.instagram.com/synthetic_\(i)/",feastList:nyc,listSection:nil)))
        }
        for i in 0..<245 {
            largePlaces.append(try repo.createSavedPlace(from:.init(applePlaceID:"query-large-\(i)",displayNameSnapshot:String(format:"Large Place %03d",i),status:.wantToTry,placeType:.cafe,cuisines:["Coffee"],tags:["Shared"],note:String(repeating:"Unrequested stored detail ",count:250),websiteURL:"https://example.org/"+String(repeating:"x",count:1700),instagramURL:nil,feastList:large,listSection:nil)))
        }
        _ = try repo.createSavedPlace(from:.init(applePlaceID:"query-hidden",displayNameSnapshot:"Withheld place",status:.love,placeType:.bar,cuisines:[],tags:[],note:"WITHHELD_NOTE",websiteURL:nil,instagramURL:nil,feastList:hidden,listSection:nil))
        // Exercise literal persisted values, not an import or URL-normalization path.
        for i in 20..<30 {nycPlaces[i].instagramURL=""}
        for i in 30..<41 {nycPlaces[i].instagramURL=" \n\t "}
        nycPlaces[41].instagramURL="not a valid profile URL"
        nycPlaces[0].websiteURL=nil;nycPlaces[1].websiteURL="  ";nycPlaces[2].websiteURL="invalid website value"
        try context.save()
        var visible=Set([nyc.id!,large.id!])
        let adapter=AskSavedCollection(context:context,visibleCities:{visible})
        let engine=AskCollectionChangeEngine(adapter:adapter,journalURL:temporaryDirectory.appendingPathComponent("query-v2-actions.json"))
        let request=AskRequest(mode:.collection,text:"Which NYC places are missing Instagram?",fromOCR:false,performanceID:UUID())
        func executor(_ v2:Bool=true,_ rich:Bool=true)->AskAgentExecutor {
            .init(adapter:adapter,engine:engine,request:request,researcher:CollectionContextResearch(),searchMaps:{_ in preconditionFailure("Read-only test must not use Maps")},fullCollectionContext:rich,supportsCollectionQueryV2:v2)
        }
        func query(_ operation:String="list",city:String?="NYC",field:String?="instagram",presence:String="missing",fields:[String]=[],scope:String="library",positions:[Int]=[],offset:Int?=nil,limit:Int?=nil,snapshot:String?=nil,entity:String="place",search:String?=nil,groupBy:String?=nil)->AskAgentReply.Call {
            var q:[String:Any] = ["operation":operation,"scope":scope,"positions":positions,"fields":fields]
            if let city {q["city"]=city};if let field {q["fieldPresence"]=["field":field,"presence":presence]}
            if let offset {q["offset"]=offset};if let limit {q["limit"]=limit};if let snapshot {q["snapshot"]=snapshot};if let search {q["searchText"]=search};if let groupBy {q["groupBy"]=groupBy}
            return .init(name:"query_collection",callID:UUID().uuidString,arguments:String(data:try! JSONSerialization.data(withJSONObject:["entity":entity,"query":q]),encoding:.utf8)!)
        }
        func rowJSON(_ value:AskAgentRecord)throws->[String:Any] {try JSONSerialization.jsonObject(with:JSONEncoder().encode(value)) as! [String:Any]}
        func storedState()throws->[String:[String:String]] {
            // KVC may bridge UUID/String values to Foundation objects after a
            // refault. Their descriptions can contain object addresses or change
            // quoting; compare exact typed data instead, including date bits.
            var rows:[String:[String:String]]=[:]
            for place in try repo.fetchSavedPlaces() {
                var values:[String:String]=[:]
                for key in place.entity.attributesByName.keys {
                    let raw=place.value(forKey:key),value:String
                    if let date=raw as? Date {value="date:"+String(date.timeIntervalSinceReferenceDate.bitPattern)}
                    else if let id=raw as? UUID {value="uuid:"+id.uuidString}
                    else if let text=raw as? String {value="text:"+text}
                    else if let bytes=raw as? Data {value="data:"+bytes.base64EncodedString()}
                    else if raw==nil {value="nil"}
                    else {preconditionFailure("Unhandled saved attribute type: "+key)}
                    values[key]=value
                }
                for (key,object) in [("city",place.feastList as NSManagedObject?),("section",place.listSection as NSManagedObject?)] {
                    values["relationship:"+key]=object.map {$0.objectID.uriRepresentation().absoluteString+":"+(($0.value(forKey:"id") as? UUID)?.uuidString ?? "nil")} ?? "nil"
                }
                rows[place.objectID.uriRepresentation().absoluteString]=values
            }
            return rows
        }
        let before=try storedState()
        let intent=AskAgentInterpretation(goal:"query",sourcePolicy:"stored_only",fields:["instagram"],selectionIDs:[],permissions:[])
        let reader=executor(),expected=nycPlaces.prefix(41).map {$0.id!.uuidString}
        let count=try await reader.execute(query("count"),intent:intent)
        precondition(count.output.totalCount==41 && count.output.complete && count.output.records.isEmpty && count.orderedIDs==expected && !count.selectionIsOrdered)
        precondition(count.presentation?.kind=="count" && count.presentation?.returnedFields==[] && count.response?.candidates.isEmpty==true)
        let noOrdinal=try await reader.execute(query("details",city:nil,field:nil,scope:"previous",positions:[2]),intent:intent)
        precondition(noOrdinal.output.status=="stale" && noOrdinal.output.records.isEmpty)
        let list=try await reader.execute(query(fields:["instagram"],scope:"previous"),intent:intent)
        precondition(list.output.totalCount==41 && list.output.complete && list.output.records.map(\.id)==expected && list.response?.candidates.map(\.id)==expected && list.selectionIsOrdered)
        precondition(list.presentation?.kind=="rows" && list.presentation?.returnedFields==["instagram"] && list.presentation?.renderedLocally==true)
        for record in list.output.records {
            let row=try rowJSON(record)
            precondition(Set(row.keys)==Set(["id","name","city","cuisines","kind","instagram"]) && row["instagram"] is NSNull)
            let bytes=try JSONEncoder().encode(record),restored=try JSONDecoder().decode(AskAgentRecord.self,from:bytes)
            let restoredRow=try rowJSON(restored)
            precondition(restored==record && restoredRow["instagram"] is NSNull)
        }
        let recent=AskSemanticContext.recentQuestions([.init(id:UUID(),request:request,response:list.response,status:.complete)])
        precondition(recent.count==1 && recent[0].question==request.text && recent[0].recordIDs.isEmpty)
        var followupRequest=AskRequest(mode:.collection,text:"The second one",fromOCR:false,performanceID:UUID());followupRequest.libraryContext=list.response?.libraryContext
        let followup=AskAgentExecutor(adapter:adapter,engine:engine,request:followupRequest,researcher:CollectionContextResearch(),searchMaps:{_ in []},fullCollectionContext:true,supportsCollectionQueryV2:true)
        let acrossTurns=try await followup.execute(query("details",city:nil,field:nil,fields:["instagram"],scope:"previous",positions:[2]),intent:intent)
        precondition(acrossTurns.output.records.map(\.id)==[expected[1]])
        let second=try await reader.execute(query("details",city:nil,field:nil,fields:["instagram"],scope:"previous",positions:[2]),intent:intent)
        precondition(second.output.records.map(\.id)==[expected[1]] && second.response?.candidates.map(\.id)==[expected[1]])
        let present=try await reader.execute(query(presence:"present",fields:["instagram"]),intent:intent)
        precondition(present.output.totalCount==116 && present.output.records.first?.id==nycPlaces[41].id!.uuidString && present.output.records.first?.instagram=="not a valid profile URL")
        let invalidText=present.response!.paragraphs.flatMap(\.spans).compactMap {if case .text(let value)=$0{return value};return nil}.joined()
        precondition(invalidText.contains("isn’t a valid profile URL"))
        let websites=try await reader.execute(query("count",field:"website"),intent:intent)
        precondition(websites.output.totalCount==2 && websites.orderedIDs==Array(nycPlaces.prefix(2)).map {$0.id!.uuidString})
        let projected=try await reader.execute(query(field:nil,fields:["name"]),intent:intent)
        precondition(projected.output.totalCount==157 && projected.output.records.count==157)
        let ordinalDoesNotMatch=try await reader.execute(query("details",scope:"previous",positions:[42]),intent:intent)
        precondition(ordinalDoesNotMatch.output.status=="empty" && ordinalDoesNotMatch.output.records.isEmpty)
        let projectedRow=try rowJSON(projected.output.records[0])
        precondition(Set(projectedRow.keys)==Set(["id","name","city","cuisines","kind"]))
        let unavailableField=try await reader.execute(query(field:nil,fields:["address"]),intent:intent)
        let unavailableRow=try rowJSON(unavailableField.output.records[0])
        precondition(unavailableRow["address"]==nil)
        precondition(unavailableField.presentation?.returnedFields==[])
        let requested=try await reader.execute(query("details",field:nil,fields:["note","tags","status","neighborhood","type","website","instagram"],limit:1),intent:intent)
        let requestedRow=try rowJSON(requested.output.records[0])
        precondition(requestedRow["note"] as? String=="Collaborator note not requested" && requestedRow["tags"] as? [String]==["Collaborator Tag"] && requestedRow["neighborhood"] is NSNull && requestedRow["website"] is NSNull && requestedRow["instagram"] is NSNull)
        let defaultList=try await reader.execute(query(field:nil,limit:1),intent:intent)
        let defaultListRow=try rowJSON(defaultList.output.records[0])
        precondition(defaultListRow["status"] as? String=="Love" && defaultListRow["website"] is NSNull && defaultListRow["instagram"] is NSNull && defaultListRow["note"]==nil && defaultListRow["tags"]==nil)
        for operation in ["details","compare","answer"] {
            let defaults=try await reader.execute(query(operation,field:nil,limit:1),intent:intent)
            let row=try rowJSON(defaults.output.records[0])
            precondition(row["note"] as? String=="Collaborator note not requested" && row["tags"] as? [String]==["Collaborator Tag"] && row["status"] as? String=="Love" && row["instagram"] is NSNull)
            let narrow=try await reader.execute(query(operation,field:nil,fields:["name"],limit:1),intent:intent)
            let narrowRow=try rowJSON(narrow.output.records[0])
            precondition(Set(narrowRow.keys)==Set(["id","name","city","cuisines","kind"]))
        }
        let neighborhoodDefaults=try await reader.execute(query(field:nil,entity:"neighborhood"),intent:intent)
        let neighborhoodRow=try rowJSON(neighborhoodDefaults.output.records[0])
        precondition(neighborhoodRow["neighborhood"] as? String=="Saved Neighborhood")
        let neighborhoodNarrow=try await reader.execute(query(field:nil,fields:["name"],entity:"neighborhood"),intent:intent)
        let neighborhoodNarrowRow=try rowJSON(neighborhoodNarrow.output.records[0])
        precondition(neighborhoodNarrowRow["neighborhood"]==nil)
        let groups=try await reader.execute(query("group",groupBy:"status"),intent:intent)
        precondition(groups.output.totalCount==41 && groups.output.records.isEmpty && groups.output.summary?.contains("Love: 41")==true && groups.presentation?.kind=="groups")
        for rejected in [query(field:"address"),query(field:"note"),query(presence:"invalid"),query(entity:"city"),query(entity:"neighborhood"),query("catalog")] {
            do {_ = try await reader.execute(rejected,intent:intent);preconditionFailure("Unsupported presence predicate accepted")}catch {}
        }
        for legacy in [executor(false,true),executor(false,false),executor(true,false)] {
            do {_ = try await legacy.execute(query("count"),intent:intent);preconditionFailure("Presence predicate accepted without rich v2 permission")}catch {}
        }
        let localPlan=try JSONDecoder().decode(AskLibraryPlan.self,from:JSONSerialization.data(withJSONObject:["operation":"count","scope":"library","positions":[],"fields":[],"fieldPresence":["field":"instagram","presence":"missing"]]))
        do {_ = try AskLibraryReadTools.execute(localPlan,snapshot:adapter.librarySnapshot(),context:nil);preconditionFailure("Legacy read tools accepted presence") }catch {}
        let freshPlaces=try adapter.librarySnapshot().places
        let displayed=[nycPlaces[41].id!.uuidString,nycPlaces[0].id!.uuidString,nycPlaces[1].id!.uuidString]
        let displayedContext=AskLibraryContext(ids:displayed,filters:localPlan)
        var ordinalPlan=localPlan;ordinalPlan.scope = .previous;ordinalPlan.positions=[2]
        let exactOrdinal=try AskLibraryReadTools.execute(ordinalPlan,snapshot:.init(places:freshPlaces,totalCount:freshPlaces.count),context:displayedContext,allowStoredFieldPresence:true)
        precondition(exactOrdinal.records.map(\.id)==[displayed[1]])
        ordinalPlan.positions=[1]
        let absentOrdinal=try AskLibraryReadTools.execute(ordinalPlan,snapshot:.init(places:freshPlaces,totalCount:freshPlaces.count),context:displayedContext,allowStoredFieldPresence:true)
        precondition(absentOrdinal.status == .success && absentOrdinal.records.isEmpty)
        let pager=executor()
        let first=try await pager.execute(query(city:"Large City",fields:["name"]),intent:intent)
        precondition(first.output.totalCount==245 && first.output.records.count==200 && first.output.nextOffset==200 && !first.output.complete)
        let firstBytes=try JSONEncoder().encode(first.output)
        precondition(firstBytes.count<58_000)
        let next=try await pager.execute(query(city:"Large City",fields:["name"],offset:200,snapshot:first.output.snapshot),intent:intent)
        precondition(next.output.records.count==45 && next.output.nextOffset==nil && next.selectionIsOrdered)
        let ordinal=try await pager.execute(query("details",city:nil,field:nil,fields:["name"],scope:"previous",positions:[240]),intent:intent)
        precondition(ordinal.output.records.map(\.id)==[largePlaces[239].id!.uuidString])
        // Same projected rows do not make an unrelated query the same snapshot.
        let unrelated=try await pager.execute(query(city:"Large City",fields:["name"],offset:200,snapshot:first.output.snapshot,search:"Large Place"),intent:intent)
        precondition(unrelated.output.status=="stale")
        let changedProjection=try await pager.execute(query(city:"Large City",fields:["instagram"],offset:200,snapshot:first.output.snapshot),intent:intent)
        precondition(changedProjection.output.status=="stale")
        // A byte-budgeted page still preserves exact membership and explicit nextOffset.
        let bytePage=try await pager.execute(query(city:"Large City",fields:["website"]),intent:intent)
        let pageBytes=try JSONEncoder().encode(bytePage.output)
        precondition(bytePage.output.totalCount==245 && bytePage.output.records.count>0 && bytePage.output.records.count<200 && bytePage.output.nextOffset==bytePage.output.records.count && pageBytes.count<=60_000)
        let allVisible=try await reader.execute(query("count",city:nil),intent:intent)
        precondition(allVisible.output.totalCount==286 && allVisible.output.complete)
        // The installed recovery store is not the route. A server-disabled
        // recovery feature must still negotiate and execute direct native v2.
        let wire=CollectionQueryHTTPFixture(call:query(fields:["name","instagram"]),expectedIDs:expected)
        let endpoint=URL(string:"https://query-route-fixture.workers.dev/v1/answer")!
        let hosted=AskHostedProvider(configuration:.init(environment:.production,endpoint:endpoint,scope:.savedMetadata,productionHost:endpoint.host!,ownerValidation:true),token:{String(repeating:"x",count:43)},approve:{_,_ in true},send:{try await wire.send($0)},libraryToolsEnabled:{true},permission:{true},libraryPlanVersion:{7},nativeResearchEnabled:{true},collectionQueriesEnabled:{true},recoveryEnabled:{false})
        let dormantRecovery=AskTurnRecoveryStore(directory:temporaryDirectory.appendingPathComponent("query-v2-dormant-recovery"))
        let provider=AskAgentProvider(remote:hosted,fallback:hosted,adapter:adapter,engine:engine,searchMaps:{_ in preconditionFailure("Read-only direct query used Maps")},recoveryStore:dormantRecovery)
        var routeRequest=AskRequest(mode:.collection,text:request.text,fromOCR:false,performanceID:UUID());routeRequest.conversationID=UUID()
        let direct=try await provider.answer(routeRequest,tools:AskReadTools(request:routeRequest,index:adapter.index()))
        let dispatched=await wire.calls(),checkpoint=try dormantRecovery.checkpoint(routeRequest.performanceID!)
        precondition(dispatched==2 && direct.candidates.map(\.id)==expected && checkpoint==nil)
        let after=try storedState()
        precondition(after==before,"Read-only query changed a saved attribute or relationship")
        precondition(!context.hasChanges && !FileManager.default.fileExists(atPath:temporaryDirectory.appendingPathComponent("query-v2-actions.json").path))
        // Presence stays missing, but the relevant raw value changes off-projection.
        largePlaces[0].instagramURL=" ";try context.save()
        let rawStale=try await pager.execute(query(city:"Large City",fields:["name"],offset:200,snapshot:first.output.snapshot),intent:intent)
        precondition(rawStale.output.status=="stale")
        let fresh=try await pager.execute(query(city:"Large City",fields:["name"]),intent:intent)
        largePlaces[244].instagramURL="invalid but stored";try context.save()
        let membershipStale=try await pager.execute(query(city:"Large City",fields:["name"],offset:200,snapshot:fresh.output.snapshot),intent:intent)
        precondition(membershipStale.output.status=="stale")
        let updatedCount=try await pager.execute(query("count",city:"Large City"),intent:intent)
        precondition(updatedCount.output.totalCount==244)
        // A malformed/unavailable persisted row is not classified as missing.
        nycPlaces[50].instagramURL=String(repeating:"x",count:2001);try context.save()
        let incomplete=try await reader.execute(query("count"),intent:intent)
        precondition(incomplete.output.status=="partial" && !incomplete.output.complete && incomplete.output.records.isEmpty && incomplete.output.summary==nil)
        let unaffected=try await reader.execute(query("count",city:"Large City"),intent:intent)
        precondition(unaffected.output.totalCount==244 && unaffected.output.complete)
        visible=[large.id!]
        let revoked=try await reader.execute(query("count"),intent:intent)
        precondition(revoked.output.totalCount==0 && revoked.output.records.isEmpty)
        visible=[]
        let withheld=try await reader.execute(query("count",city:nil),intent:intent)
        precondition(withheld.output.totalCount==0 && withheld.output.records.isEmpty)
        print("PASS query v2: synthetic 157 NYC / 41 missing Instagram, exact list and second ordinal, null/omitted/unavailable, invalid-present URLs, 245-match paging, raw/query snapshot binding, permission scope, no writes")
    }

    private static func auditQueryContracts(model:NSManagedObjectModel,temporaryDirectory:URL)async throws {
        let coordinator=NSPersistentStoreCoordinator(managedObjectModel:model)
        let store=try coordinator.addPersistentStore(ofType:NSSQLiteStoreType,configurationName:nil,at:temporaryDirectory.appendingPathComponent("audit-query-contracts.sqlite"))
        let context=NSManagedObjectContext(concurrencyType:.mainQueueConcurrencyType);context.persistentStoreCoordinator=coordinator
        let repo=FeastRepository(context:context),zurich=try repo.createFeastList(named:"Zurich"),amsterdam=try repo.createFeastList(named:"Amsterdam")
        let north=try repo.createListSection(named:"North",in:zurich),south=try repo.createListSection(named:"South",in:zurich)
        let a=try repo.createSavedPlace(from:.init(applePlaceID:"audit-a",displayNameSnapshot:"A",status:.been,placeType:.cafe,cuisines:["Alpha","Zulu"],tags:[],note:nil,websiteURL:"https://example.org/needle-website",instagramURL:"https://www.instagram.com/needleprofile/",feastList:zurich,listSection:north))
        let b=try repo.createSavedPlace(from:.init(applePlaceID:"audit-b",displayNameSnapshot:"B",status:.love,placeType:.cafe,cuisines:["Alpha"],tags:[],note:nil,websiteURL:nil,instagramURL:nil,feastList:amsterdam,listSection:nil))
        let c=try repo.createSavedPlace(from:.init(applePlaceID:"audit-c",displayNameSnapshot:"C",status:.love,placeType:.cafe,cuisines:["Zulu"],tags:[],note:nil,websiteURL:nil,instagramURL:nil,feastList:zurich,listSection:south))
        let adapter=AskSavedCollection(context:context,canMutate:{_,_,_ in true},canRecoverStore:{$0==store.identifier},visibleCities:{[zurich.id!,amsterdam.id!]})
        let engine=AskCollectionChangeEngine(adapter:adapter,journalURL:temporaryDirectory.appendingPathComponent("audit-query-actions.json"))
        let request=AskRequest(mode:.collection,text:"List saved places grouped by city",fromOCR:false,performanceID:UUID())
        let intent=AskAgentInterpretation(goal:"query",sourcePolicy:"public_if_missing",fields:[],selectionIDs:[],permissions:[])
        func reader(_ request:AskRequest,full:Bool=true)->AskAgentExecutor {AskAgentExecutor(adapter:adapter,engine:engine,request:request,researcher:CollectionContextResearch(),searchMaps:{_ in []},fullCollectionContext:full,supportsCollectionQueryV2:full)}
        func call(entity:String="place",operation:String="list",scope:String="library",positions:[Int]=[],groupBy:String?=nil,city:String?=nil,neighborhood:String?=nil,status:String?=nil,search:String?=nil,limit:Int?=nil,offset:Int?=nil,snapshot:String?=nil)->AskAgentReply.Call {
            var q:[String:Any] = ["operation":operation,"scope":scope,"positions":positions,"fields":["name"]]
            for (key,value) in [("groupBy",groupBy),("city",city),("neighborhood",neighborhood),("status",status),("searchText",search),("snapshot",snapshot)] {if let value {q[key]=value}}
            if let limit {q["limit"]=limit};if let offset {q["offset"]=offset}
            return .init(name:"query_collection",callID:UUID().uuidString,arguments:String(data:try! JSONSerialization.data(withJSONObject:["entity":entity,"query":q]),encoding:.utf8)!)
        }
        var failures:[String]=[]
        func check(_ value:Bool,_ message:String) {if !value {failures.append(message);print("FAIL audit query: "+message)}}
        let groupedReader=reader(request),grouped=try await groupedReader.execute(call(groupBy:"city"),intent:intent)
        let displayed=grouped.response!.paragraphs.flatMap(\.spans).compactMap {if case .place(let id)=$0{return id};return nil}
        check(displayed==[b.id!.uuidString,a.id!.uuidString,c.id!.uuidString],"city grouping display fixture")
        let first=try await groupedReader.execute(call(operation:"details",scope:"previous",positions:[1]),intent:intent)
        check(first.output.records.map(\.id)==[b.id!.uuidString],"grouped first must resolve displayed B, not name-sorted A")
        let fallbackReader=reader(request,full:false)
        _ = try await fallbackReader.execute(call(groupBy:"cuisine"),intent:intent)
        let fallbackThird=try await fallbackReader.execute(call(operation:"details",scope:"previous",positions:[3]),intent:intent)
        check(fallbackThird.orderedIDs==[a.id!.uuidString],"legacy capability path must use the same third cuisine occurrence")
        do {_ = try await fallbackReader.execute(call(operation:"details",scope:"previous",positions:[1,1]),intent:intent);check(false,"legacy duplicate ordinal input must reject before normalization")}catch {}
        let filterReader=reader(request)
        _ = try await filterReader.execute(call(),intent:intent)
        let filtered=try await filterReader.execute(call(operation:"details",scope:"previous",positions:[2],status:"Love"),intent:intent)
        check(filtered.output.records.map(\.id)==[b.id!.uuidString],"ordinal must resolve B before status filter, not shift to C")
        for filter in [String?.none,"Zurich"] {
            let citiesReader=reader(request)
            _ = try await citiesReader.execute(call(entity:"city"),intent:intent)
            let reversed=try await citiesReader.execute(call(entity:"city",operation:"details",scope:"previous",positions:[2,1],city:filter),intent:intent)
            check(reversed.output.records.map(\.name)==(filter==nil ? ["Zurich","Amsterdam"] : ["Zurich"]),"city positional order must survive predicates without resorting")
        }
        let empty=try await reader(request).execute(call(entity:"neighborhood",neighborhood:"Absent"),intent:intent)
        check(empty.output.records.isEmpty && empty.output.complete,"unknown neighborhood filter must not return North and South")
        let neighborhood=try await reader(request).execute(call(entity:"neighborhood",city:"Zurich",neighborhood:"North"),intent:intent)
        check(neighborhood.output.records.map(\.id)==[north.id!.uuidString] && neighborhood.output.complete,"neighborhood filter must select only North")
        do {_ = try await reader(request).execute(call(entity:"city",neighborhood:"North"),intent:intent);check(false,"unsupported city/neighborhood filter must reject")}catch {}
        do {_ = try await reader(request).execute(call(entity:"neighborhood",groupBy:"city"),intent:intent);check(false,"unsupported non-place grouping must reject rather than claim completeness")}catch {}
        for search in ["needle-website","NEEDLEPROFILE"] {
            let found=try await reader(request).execute(call(search:search),intent:intent)
            check(found.output.records.map(\.id)==[a.id!.uuidString],"stored link substring must match "+search)
            check(found.output.records.allSatisfy {$0.website==nil && $0.instagram==nil},"matching link must not expand name-only projection")
        }
        // A search-relevant raw link changing within the same match must stale a page,
        // even when that field was not projected and membership did not change.
        b.websiteURL="invalid needle-website b";try context.save()
        let linkPager=reader(request),page=try await linkPager.execute(call(search:"needle-website",limit:1),intent:intent)
        a.websiteURL="https://example.org/needle-website-new";try context.save()
        let stale=try await linkPager.execute(call(search:"needle-website",limit:1,offset:1,snapshot:page.output.snapshot),intent:intent)
        check(stale.output.status=="stale","unprojected raw link change must invalidate search fingerprint")
        // Preserve repeated cuisine occurrences through answer acceptance and archive.
        let cuisineReader=reader(request),cuisineCall=call(groupBy:"cuisine")
        let planner=CollectionContextConversation([cuisineCall],onePage:true)
        let catalog=try AskSemanticContext.make(request,catalog:adapter.librarySnapshot(),fullCollection:true)
        let answer=try await AskConversationLoop(planner:planner,availableCandidates:[:],execute:{try await cuisineReader.execute($0,intent:intent)}).answer(request,context:catalog,cities:[],findings:[])
        let expected=[a.id!.uuidString,b.id!.uuidString,a.id!.uuidString,c.id!.uuidString]
        check(answer.agentTask?.displayOrder==expected,"overlapping cuisine occurrences must be retained, not deduplicated")
        _ = try AskReadTools(request:request,index:adapter.readView().index).checked(answer)
        let archive=AskConversationStore(url:temporaryDirectory.appendingPathComponent("audit-query-history.json"))
        check(archive.save(.init(turns:[AskArchivedTurn(.init(id:UUID(),request:request,response:answer,status:.complete))])),"grouped answer must archive")
        let restored=archive.load().turns[0].response
        var followup=AskRequest(mode:.collection,text:"Mark the third one Regulars",fromOCR:false,performanceID:UUID())
        followup.agentTask=restored.agentTask;followup.libraryContext=restored.libraryContext
        let reloaded=reader(followup)
        let third=try await reloaded.execute(call(operation:"details",scope:"previous",positions:[3]),intent:intent)
        check(third.output.records.map(\.id)==[a.id!.uuidString],"third displayed cuisine occurrence after reload is A, not C")
        // Decode the old grouped archive wire shape, where only name-sorted
        // membership existed. Never silently guess an ordinal across an upgrade.
        var legacyWire=try JSONSerialization.jsonObject(with:JSONEncoder().encode(AskConversationSnapshot(turns:[AskArchivedTurn(.init(id:UUID(),request:request,response:answer,status:.complete))]))) as! [String:Any]
        var oldTurns=legacyWire["turns"] as! [[String:Any]],oldResponse=oldTurns[0]["response"] as! [String:Any]
        var oldContext=oldResponse["libraryContext"] as! [String:Any],oldTask=oldResponse["agentTask"] as! [String:Any]
        oldContext.removeValue(forKey:"displayOrder");oldTask.removeValue(forKey:"displayOrder");oldTask["orderedIDs"]=[a.id!.uuidString,b.id!.uuidString,c.id!.uuidString]
        oldResponse["libraryContext"]=oldContext;oldResponse["agentTask"]=oldTask;oldTurns[0]["response"]=oldResponse;legacyWire["turns"]=oldTurns
        let legacy=try JSONDecoder().decode(AskConversationSnapshot.self,from:JSONSerialization.data(withJSONObject:legacyWire)).turns[0].response
        var legacyRequest=followup;legacyRequest.agentTask=legacy.agentTask;legacyRequest.libraryContext=legacy.libraryContext
        let legacyReader=reader(legacyRequest)
        let legacyOrdinal=try await legacyReader.execute(call(operation:"details",scope:"previous",positions:[3]),intent:intent)
        check(legacyOrdinal.output.status=="stale" && legacyOrdinal.output.records.isEmpty,"legacy grouped archive must not invent displayed ordinal order")
        let legacyPermission=AskAgentPermission(entity:"place",operations:["update"],fields:["status"],targetIDs:[],instructionQuote:legacyRequest.text,selector:.init(city:nil,name:nil,neighborhood:nil,cuisine:nil,status:nil,placeType:nil,scope:"previous",positions:[3]),changes:[.init(field:"status",source:"user",value:"Regulars",values:nil)])
        do {try legacyReader.prepare(.init(goal:"change",sourcePolicy:"local_only",fields:["status"],selectionIDs:[],permissions:[legacyPermission]));check(false,"legacy grouped positional mutation must require a fresh list")}catch {}
        check(a.status=="Been" && b.status=="Love" && c.status=="Love","legacy archive ambiguity must never mutate a record")
        let narrowedReader=reader(followup)
        let narrow=call(operation:"details",scope:"previous")
        var narrowObject=try JSONSerialization.jsonObject(with:Data(narrow.arguments.utf8)) as! [String:Any]
        narrowObject["selectionIDs"]=[b.id!.uuidString]
        let narrowed=try await narrowedReader.execute(.init(name:narrow.name,callID:narrow.callID,arguments:String(data:try JSONSerialization.data(withJSONObject:narrowObject),encoding:.utf8)!),intent:intent)
        check(narrowed.output.records.map(\.id)==[b.id!.uuidString],"explicit narrowed read after grouped occurrences must remain supported")
        let mismatchReader=reader(followup)
        narrowObject["query"] = ["operation":"details","scope":"previous","positions":[3],"fields":["name"]]
        let intersected=try await mismatchReader.execute(.init(name:narrow.name,callID:narrow.callID,arguments:String(data:try JSONSerialization.data(withJSONObject:narrowObject),encoding:.utf8)!),intent:intent)
        check(intersected.output.records.isEmpty,"explicit IDs must not renumber original display ordinals")
        let mutationReader=reader(followup)
        let permission=AskAgentPermission(entity:"place",operations:["update"],fields:["status"],targetIDs:[],instructionQuote:followup.text,selector:.init(city:nil,name:nil,neighborhood:nil,cuisine:nil,status:nil,placeType:nil,scope:"previous",positions:[3]),changes:[.init(field:"status",source:"user",value:"Regulars",values:nil)])
        let changing=AskAgentInterpretation(goal:"change",sourcePolicy:"local_only",fields:["status"],selectionIDs:[],permissions:[permission])
        try mutationReader.prepare(changing)
        let proposal=AskChangeProposal(entity:"place",operation:"update",targetIDs:[a.id!.uuidString],cityID:nil,sectionID:nil,mapMatchID:nil,changes:[.init(field:"status",value:"Regulars",values:nil,findingID:nil)],instructionQuote:followup.text)
        let applied=try await mutationReader.execute(.init(name:"propose_changes",callID:"grouped-write",arguments:String(data:try JSONEncoder().encode(proposal),encoding:.utf8)!),intent:changing)
        check(applied.response?.collectionActions?.first?.state == .applied && a.status=="Regulars" && b.status=="Love" && c.status=="Love","ordinal mutation must change only A after grouped archive reload")
        // A synthesized explicit subset owns its own order. Native query
        // membership remains larger, but must not leak back into positional edits.
        let subsetReader=reader(request),subsetCall=call(operation:"answer",groupBy:"cuisine")
        let subsetPlanner=CollectionContextConversation([subsetCall],onePage:true,replacementText:"1. [[place:\(b.id!.uuidString)]]")
        let subset=try await AskConversationLoop(planner:subsetPlanner,availableCandidates:[:],execute:{try await subsetReader.execute($0,intent:intent)}).answer(request,context:catalog,cities:[],findings:[])
        check(subset.agentTask?.orderedIDs==[b.id!.uuidString] && subset.agentTask?.displayOrder==nil && subset.libraryContext?.ids.count==3,"synthesized subset fixture must separate displayed selection from full query")
        var subsetRequest=AskRequest(mode:.collection,text:"Mark the first Been",fromOCR:false,performanceID:UUID())
        subsetRequest.agentTask=subset.agentTask;subsetRequest.libraryContext=subset.libraryContext
        let subsetOrdinal=try await reader(subsetRequest).execute(call(operation:"details",scope:"previous",positions:[1]),intent:intent)
        check(subsetOrdinal.output.records.map(\.id)==[b.id!.uuidString],"synthesized subset ordinal must not fall back to native grouped A")
        let subsetWriter=reader(subsetRequest)
        let subsetPermission=AskAgentPermission(entity:"place",operations:["update"],fields:["status"],targetIDs:[],instructionQuote:subsetRequest.text,selector:.init(city:nil,name:nil,neighborhood:nil,cuisine:nil,status:nil,placeType:nil,scope:"previous",positions:[1]),changes:[.init(field:"status",source:"user",value:"Been",values:nil)])
        let subsetChange=AskAgentInterpretation(goal:"change",sourcePolicy:"local_only",fields:["status"],selectionIDs:[],permissions:[subsetPermission])
        try subsetWriter.prepare(subsetChange)
        let subsetProposal=AskChangeProposal(entity:"place",operation:"update",targetIDs:[b.id!.uuidString],cityID:nil,sectionID:nil,mapMatchID:nil,changes:[.init(field:"status",value:"Been",values:nil,findingID:nil)],instructionQuote:subsetRequest.text)
        _ = try await subsetWriter.execute(.init(name:"propose_changes",callID:"subset-write",arguments:String(data:try JSONEncoder().encode(subsetProposal),encoding:.utf8)!),intent:subsetChange)
        check(a.status=="Regulars" && b.status=="Been" && c.status=="Love","synthesized subset positional write must only change B")
        // New grouped provenance remains explicit even when the occurrence
        // sequence happens to equal the unique membership, including synthesis.
        for replacement in [String?.none,"1. [[place:\(a.id!.uuidString)]]\n2. [[place:\(c.id!.uuidString)]]"] {
            let singleReader=reader(request),singleCall=call(groupBy:"city",city:"Zurich",limit:1)
            let singlePlanner=CollectionContextConversation([singleCall,singleCall],replacementText:replacement)
            let singleAnswer=try await AskConversationLoop(planner:singlePlanner,availableCandidates:[:],execute:{try await singleReader.execute($0,intent:intent)}).answer(request,context:catalog,cities:[],findings:[])
            check(singleAnswer.libraryContext?.displayOrder==[a.id!.uuidString,c.id!.uuidString],"new grouped pages/replacement must retain occurrence provenance when order equals IDs")
            var singleFollowup=request;singleFollowup.agentTask=singleAnswer.agentTask;singleFollowup.libraryContext=singleAnswer.libraryContext
            let singleOrdinal=try await reader(singleFollowup).execute(call(operation:"details",scope:"previous",positions:[2]),intent:intent)
            check(singleOrdinal.output.records.map(\.id)==[c.id!.uuidString],"new grouped result must not be mistaken for a legacy archive")
        }
        // The real conversation merger must not deduplicate repeated native
        // rows inside an earlier page when appending another page.
        b.cuisines=["Alpha","Zulu"];try context.save()
        let pageLoopReader=reader(request),pageCall=call(groupBy:"cuisine",limit:2)
        let pagePlanner=CollectionContextConversation([pageCall,pageCall])
        let pageAnswer=try await AskConversationLoop(planner:pagePlanner,availableCandidates:[:],execute:{try await pageLoopReader.execute($0,intent:intent)}).answer(request,context:catalog,cities:[],findings:[])
        let pageOccurrences=pageAnswer.paragraphs.flatMap(\.spans).compactMap {if case .place(let id)=$0{return id};return nil}
        let expectedPages=[a.id!.uuidString,b.id!.uuidString,a.id!.uuidString,b.id!.uuidString,c.id!.uuidString]
        check(pageOccurrences==expectedPages && pageAnswer.agentTask?.displayOrder==expectedPages && pageAnswer.libraryContext?.displayOrder==expectedPages,"conversation page merge must preserve every overlapping native row and exact ordinal metadata")
        _ = try AskReadTools(request:request,index:adapter.readView().index).checked(pageAnswer)
        b.cuisines=["Alpha"];try context.save()
        // Page-local grouping is the order actually rendered. Across three pages,
        // A occurs twice before B; restart must not recompute a global name order.
        let pager=reader(request)
        let one=try await pager.execute(call(groupBy:"cuisine",limit:1),intent:intent)
        let checkpoint=try pager.recoverySnapshot(),continued=reader(request)
        try continued.restoreRecoverySnapshot(checkpoint)
        _ = try await continued.execute(call(groupBy:"cuisine",limit:1,offset:1,snapshot:one.output.snapshot),intent:intent)
        let three=try await continued.execute(call(groupBy:"cuisine",limit:1,offset:2,snapshot:one.output.snapshot),intent:intent)
        check(three.displayOrder==[a.id!.uuidString,a.id!.uuidString,b.id!.uuidString,c.id!.uuidString],"paged occurrence order must survive restart")
        let pagedThird=try await continued.execute(call(operation:"details",scope:"previous",positions:[3]),intent:intent)
        check(pagedThird.output.records.map(\.id)==[b.id!.uuidString],"third actually displayed paged occurrence must be B")
        precondition(failures.isEmpty,failures.joined(separator:"; "))
        print("PASS audit query contracts: grouped and filtered ordinal identity, neighborhood predicates, stored-link search with projection and snapshot integrity")
    }

}
