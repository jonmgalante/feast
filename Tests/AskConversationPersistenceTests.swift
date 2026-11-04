import Foundation
import CoreData
import CryptoKit
private struct ApprovedConversationFixture:AskConversationPlanning {
    func conversationAvailable()async->Bool {true}
    func conversationStep(_ step:AskConversationStep)async throws->AskConversationReply {throw AskError.invalidEvidence}
    func searchConversationWeb(_ query:String)async throws->AskWebResearchResult {throw AskError.invalidEvidence}
    func authorizeConversationChange(_ proposal:AskChangeProposal,question:String,history:[String],targets:[AskAgentRecord])async throws->AskHumanAuthorization {.init(approved:true,replaceExisting:true,deleteContents:false,reason:"explicit_instruction")}
    func authorizePendingConfirmation(_ actions:[AskCollectionAction],question:String,history:[String])async throws->AskHumanAuthorization {.init(approved:true,replaceExisting:true,deleteContents:false,reason:"accepted_pending")}
}
private actor RecordingConversationFixture:AskConversationPlanning {
    var targets:[[String]]=[]
    var selector:AskAgentSelector?=nil
    var destination:String?=nil
    var undoContext:[AskUndoDescriptor]?=nil
    var references:[AskAuthorizationReference]?=nil
    var findingContext:[AskAgentFinding]?=nil
    var approved=true
    func lastFindings()->[AskAgentFinding]? {findingContext}
    func setApproval(_ value:Bool){approved=value}
    func setSelector(_ value:AskAgentSelector){selector=value}
    func conversationAvailable()async->Bool {true}
    func conversationStep(_ step:AskConversationStep)async throws->AskConversationReply {throw AskError.invalidEvidence}
    func searchConversationWeb(_ query:String)async throws->AskWebResearchResult {throw AskError.invalidEvidence}
    func authorizeConversationChange(_ proposal:AskChangeProposal,question:String,history:[String],targets:[AskAgentRecord])async throws->AskHumanAuthorization {self.targets.append(targets.map(\.id));destination=proposal.sectionID;undoContext=proposal.undoContext;references=proposal.referenceContext;findingContext=proposal.findingContext;return .init(approved:approved,replaceExisting:true,deleteContents:false,reason:"explicit_instruction",targetSelector:selector)}
    func authorizePendingConfirmation(_ actions:[AskCollectionAction],question:String,history:[String])async throws->AskHumanAuthorization {throw AskError.invalidEvidence}
    func lastTargets()->[String] {targets.last ?? []}
    func lastDestination()->String? {destination}
    func lastUndoContext()->[AskUndoDescriptor]? {undoContext}
    func lastReferences()->[AskAuthorizationReference]? {references}
}
private struct ConcurrentConversationFixture:AskConversationPlanning {
    let mutate:@MainActor @Sendable ()throws->Void
    func conversationAvailable()async->Bool {true}
    func conversationStep(_ step:AskConversationStep)async throws->AskConversationReply {throw AskError.invalidEvidence}
    func searchConversationWeb(_ query:String)async throws->AskWebResearchResult {throw AskError.invalidEvidence}
    func authorizeConversationChange(_ proposal:AskChangeProposal,question:String,history:[String],targets:[AskAgentRecord])async throws->AskHumanAuthorization {try await mutate();return .init(approved:true,replaceExisting:true,deleteContents:false,reason:"explicit_instruction")}
    func authorizePendingConfirmation(_ actions:[AskCollectionAction],question:String,history:[String])async throws->AskHumanAuthorization {throw AskError.invalidEvidence}
}
private struct NoConversationResearch:AskBusinessResearching {
    func publicLookupAvailable()async->Bool {false}
    func businessResearch(_ request:AskBusinessRequest)async throws->AskBusinessResult {throw AskError.invalidEvidence}
}
@MainActor enum AskConversationPersistenceTests {
    static func run(model:NSManagedObjectModel,directory:URL)async throws {
        let coordinator=NSPersistentStoreCoordinator(managedObjectModel:model)
        let store=try coordinator.addPersistentStore(ofType:NSSQLiteStoreType,configurationName:nil,at:directory.appendingPathComponent("conversation-actions.sqlite"))
        let context=NSManagedObjectContext(concurrencyType:.mainQueueConcurrencyType);context.persistentStoreCoordinator=coordinator
        let repo=FeastRepository(context:context),city=try repo.createFeastList(named:"New York")
        let place=try repo.createSavedPlace(from:.init(applePlaceID:"isolated-le-bernardin",displayNameSnapshot:"Le Bernardin",status:.love,placeType:.restaurant,cuisines:["French"],tags:["Dinner"],note:"Local-only note",websiteURL:nil,instagramURL:"https://www.instagram.com/lebernardinny/",feastList:city,listSection:nil))
        let other=try repo.createSavedPlace(from:.init(applePlaceID:"isolated-gramercy",displayNameSnapshot:"Gramercy Tavern",status:.wantToTry,placeType:.restaurant,cuisines:["American"],tags:[],note:nil,websiteURL:nil,instagramURL:nil,feastList:city,listSection:nil))
        let adapter=AskSavedCollection(context:context,canMutate:{_,_,_ in true},canRecoverStore:{$0==store.identifier},visibleCities:{Set(try context.fetch(FeastList.fetchRequest()).compactMap(\.id))})
        let engine=AskCollectionChangeEngine(adapter:adapter,journalURL:directory.appendingPathComponent("conversation-actions.json"))
        let blocked=AskHostedProvider(configuration:.init(environment:.production,endpoint:URL(string:"https://feast-owner-validation.jonmgalante.workers.dev/v1/answer")!,scope:.savedMetadata,productionHost:"feast-owner-validation.jonmgalante.workers.dev",ownerValidation:true),token:{preconditionFailure("Credential read before consent")},approve:{_,_ in preconditionFailure("Upload before consent")},send:{_ in preconditionFailure("Network before consent")},permission:{false})
        let legacy=AskLibraryProvider(remote:blocked,places:{try await adapter.personalPlaces()},intentPlanner:blocked,snapshot:{try await adapter.librarySnapshot()})
        let provider=AskAgentProvider(remote:blocked,fallback:legacy,adapter:adapter,engine:engine,searchMaps:{_ in []})
        let general=AskRequest(mode:.collection,text:"Explain how a tasting menu differs from choosing dishes individually",fromOCR:false)
        do {_ = try await provider.answer(general,tools:AskReadTools(request:general,index:adapter.index()));preconditionFailure("Configured consent gate reported unavailable")}catch AskHostedError.consentRequired {}
        let root=UUID(),question="Create Berlin and Rome. Rename Le Bernardin for dinner, then clear its Instagram."
        let finding=AskVerifiedFinding(id:UUID(),recordID:place.id!.uuidString,identity:.init(name:"Le Bernardin",city:"New York",website:nil,applePlaceID:"isolated-le-bernardin"),field:"instagram",value:"https://www.instagram.com/lebernardinny/",evidenceURL:"https://www.le-bernardin.com/",verification:"official_website",originatingTurn:UUID())
        let request=AskRequest(mode:.collection,text:question,fromOCR:false,verifiedFindings:[finding],performanceID:root)
        let executor=AskAgentExecutor(adapter:adapter,engine:engine,request:request,researcher:NoConversationResearch(),searchMaps:{_ in []})
        let planner=ApprovedConversationFixture()
        func call(_ p:AskChangeProposal)->AskAgentReply.Call {.init(name:"propose_changes",callID:UUID().uuidString,arguments:String(data:try! JSONEncoder().encode(p),encoding:.utf8)!)}
        func create(_ name:String)->AskChangeProposal {.init(entity:"city",operation:"create",targetIDs:[],cityID:nil,sectionID:nil,mapMatchID:nil,changes:[.init(field:"name",value:name,values:nil,findingID:nil,source:"user")],instructionQuote:question)}
        let berlin=try await executor.executeConversation(call(create("Berlin")),planner:planner)
        let rome=try await executor.executeConversation(call(create("Rome")),planner:planner)
        let repeated=try await executor.executeConversation(call(create("Berlin")),planner:planner)
        precondition(berlin.orderedIDs != rome.orderedIDs && repeated.response?.collectionActions?.first?.id==berlin.response?.collectionActions?.first?.id)
        let createReceipts=try engine.receipts(forTurn:root);precondition(createReceipts.count==2)
        let id=place.id!.uuidString
        let both=AskChangeProposal(entity:"place",operation:"update",targetIDs:[id],cityID:nil,sectionID:nil,mapMatchID:nil,changes:[.init(field:"name",value:"Le Bernardin — dinner",values:nil,findingID:nil,source:"user"),.init(field:"cuisines",value:nil,values:["French"],findingID:nil,source:"user")],instructionQuote:question)
        _ = try await executor.executeConversation(call(both),planner:planner)
        var single=both;single.changes=Array(both.changes.prefix(1));_ = try await executor.executeConversation(call(single),planner:planner)
        let updateReceipts=try engine.receipts(forTurn:root);precondition(updateReceipts.count==3)
        context.refreshAllObjects();place.note="New unrelated local note";try context.save()
        _ = try await executor.executeConversation(call(single),planner:planner)
        let afterUnrelated=try engine.receipts(forTurn:root);precondition(afterUnrelated.count==3)
        place.displayNameSnapshot="Le Bernardin — newer local name";try context.save()
        do {_ = try await executor.executeConversation(call(single),planner:planner);preconditionFailure("Stale consumed change replayed")}catch AskChangeError.conflict {}
        context.refreshAllObjects();precondition(place.displayNameSnapshot=="Le Bernardin — newer local name")
        let clear=AskChangeProposal(entity:"place",operation:"update",targetIDs:[id],cityID:nil,sectionID:nil,mapMatchID:nil,changes:[.init(field:"instagram",value:nil,values:nil,findingID:nil,source:"user")],instructionQuote:question)
        _ = try await executor.executeConversation(call(clear),planner:planner)
        context.refreshAllObjects();precondition(place.instagramURL==nil && place.note=="New unrelated local note" && place.tags==["Dinner"])
        let composedRequest=AskRequest(mode:.collection,text:"Create a New York neighborhood named Dinner plans and move Gramercy Tavern into it",fromOCR:false,performanceID:UUID())
        let composed=AskAgentExecutor(adapter:adapter,engine:engine,request:composedRequest,researcher:NoConversationResearch(),searchMaps:{_ in []})
        let neighborhood=AskChangeProposal(entity:"neighborhood",operation:"create",targetIDs:[],cityID:city.id!.uuidString,sectionID:nil,mapMatchID:nil,changes:[.init(field:"name",value:"Dinner plans",values:nil,findingID:nil,source:"user")],instructionQuote:composedRequest.text)
        let made=try await composed.executeConversation(call(neighborhood),planner:planner)
        precondition(made.output.records.count==1 && made.output.records[0].kind=="neighborhood" && made.output.records[0].name=="Dinner plans")
        let move=AskChangeProposal(entity:"place",operation:"move",targetIDs:[other.id!.uuidString],cityID:city.id!.uuidString,sectionID:made.output.records[0].id,mapMatchID:nil,changes:[],instructionQuote:composedRequest.text)
        let destinationPlanner=RecordingConversationFixture()
        _ = try await composed.executeConversation(call(move),planner:destinationPlanner)
        let destinationReferences=await destinationPlanner.lastReferences()
        precondition(destinationReferences?.contains(.init(kind:"neighborhood",id:made.output.records[0].id,name:"Dinner plans",city:"New York"))==true)
        context.refreshAllObjects();precondition(other.listSection?.id?.uuidString==made.output.records[0].id && other.feastList==city && other.note==nil)
        let namedSection=try repo.createListSection(named:"Evening plans",in:city)
        let namedMove=AskChangeProposal(entity:"place",operation:"move",targetIDs:[other.id!.uuidString],cityID:city.id!.uuidString,sectionID:"Evening plans",mapMatchID:nil,changes:[],instructionQuote:composedRequest.text)
        let namedPlanner=RecordingConversationFixture()
        _ = try await composed.executeConversation(call(namedMove),planner:namedPlanner)
        let authorizedDestination=await namedPlanner.lastDestination()
        context.refreshAllObjects();precondition(other.listSection==namedSection && authorizedDestination=="Evening plans")
        let privateMoveRequest=AskRequest(mode:.collection,text:"Move those into Dinner plans",fromOCR:false,performanceID:UUID(),agentTask:.init(action:"query",fields:["note"],orderedIDs:[other.id!.uuidString],sourcePolicy:"local_only",privateSelection:true))
        let privateMoveExecutor=AskAgentExecutor(adapter:adapter,engine:engine,request:privateMoveRequest,researcher:NoConversationResearch(),searchMaps:{_ in []}),privateMovePlanner=RecordingConversationFixture()
        await privateMovePlanner.setSelector(.init(city:nil,name:nil,neighborhood:nil,cuisine:nil,status:nil,placeType:nil,scope:"previous",positions:[]))
        let privateMove=AskChangeProposal(entity:"place",operation:"move",targetIDs:[],cityID:nil,sectionID:"Dinner plans",mapMatchID:nil,changes:[],instructionQuote:privateMoveRequest.text)
        _ = try await privateMoveExecutor.executeConversation(call(privateMove),planner:privateMovePlanner)
        let privateReferences=await privateMovePlanner.lastReferences(),privateTargets=await privateMovePlanner.lastTargets()
        precondition(privateReferences==nil && privateTargets.isEmpty)
        context.refreshAllObjects();precondition(other.listSection?.name=="Dinner plans")
        other.listSection=namedSection;try context.save()
        let driftRequest=AskRequest(mode:.collection,text:"Move Gramercy Tavern into Evening plans",fromOCR:false,performanceID:UUID())
        let drifting=AskAgentExecutor(adapter:adapter,engine:engine,request:driftRequest,researcher:NoConversationResearch(),searchMaps:{_ in []})
        let concurrent=ConcurrentConversationFixture(mutate:{namedSection.name="Renamed while awaiting";try context.save()})
        do {_ = try await drifting.executeConversation(call(namedMove),planner:concurrent);preconditionFailure("Destination rebound after concurrent rename")}catch AskChangeError.conflict {}
        context.refreshAllObjects();precondition(other.listSection==namedSection)
        let explicit=AskRequest(mode:.collection,text:"Append Dinner to Gramercy Tavern’s tags",fromOCR:false,performanceID:UUID(),agentTask:.init(action:"query",fields:["note"],orderedIDs:[id],sourcePolicy:"local_only",privateSelection:true))
        let explicitExecutor=AskAgentExecutor(adapter:adapter,engine:engine,request:explicit,researcher:NoConversationResearch(),searchMaps:{_ in []}),recording=RecordingConversationFixture()
        let append=AskChangeProposal(entity:"place",operation:"append",targetIDs:[other.id!.uuidString],cityID:nil,sectionID:nil,mapMatchID:nil,changes:[.init(field:"tags",value:nil,values:["Dinner"],findingID:nil,source:"user")],instructionQuote:explicit.text)
        _ = try await explicitExecutor.executeConversation(call(append),planner:recording)
        let sentTargets=await recording.lastTargets();precondition(sentTargets==[other.id!.uuidString])
        context.refreshAllObjects();precondition(other.tags.contains("Dinner") && place.tags==["Dinner"])
        for operation in [AskLibraryPlan.Operation.count,.group,.list] {
            let q=AskLibraryPlan(operation:operation,scope:.library,city:nil,cuisine:nil,status:nil,placeType:nil,name:nil,positions:[],fields:["name","note"],groupBy:"city")
            let data=try JSONSerialization.data(withJSONObject:["entity":"place","query":JSONSerialization.jsonObject(with:JSONEncoder().encode(q)),"selectionIDs":NSNull()])
            let read=try await composed.executeConversation(.init(name:"query_collection",callID:UUID().uuidString,arguments:String(data:data,encoding:.utf8)!),planner:planner)
            precondition(read.output.localOnly && read.output.records.isEmpty)
            if operation == .list {precondition(read.presentation?.returnedFields.contains("note")==true && read.response!.paragraphs.flatMap(\.spans).contains(.place(other.id!.uuidString)))}
            else {precondition(read.presentation?.kind=="groups" && read.presentation?.returnedFields==["city"] && read.response!.paragraphs.flatMap(\.spans).allSatisfy {if case .place=($0){return false};return true})}
            _ = try AskReadTools(request:composedRequest,index:adapter.index()).checked(read.response!)
        }
        let ordinalRequest=AskRequest(mode:.collection,text:"Append Dinner to the second place’s tags",fromOCR:false,performanceID:UUID(),agentTask:.init(action:"query",fields:[],orderedIDs:[id,other.id!.uuidString],sourcePolicy:"local_only",privateSelection:true))
        let ordinal=AskAgentExecutor(adapter:adapter,engine:engine,request:ordinalRequest,researcher:NoConversationResearch(),searchMaps:{_ in []})
        let ordinalPlanner=RecordingConversationFixture()
        await ordinalPlanner.setSelector(.init(city:nil,name:nil,neighborhood:nil,cuisine:nil,status:nil,placeType:nil,scope:"previous",positions:[2]))
        let wrongOrdinal=AskChangeProposal(entity:"place",operation:"append",targetIDs:[id],cityID:nil,sectionID:nil,mapMatchID:nil,changes:append.changes,instructionQuote:ordinalRequest.text)
        do {_ = try await ordinal.executeConversation(call(wrongOrdinal),planner:ordinalPlanner);preconditionFailure("Wrong target accepted despite independent ordinal selector")}catch AskChangeError.permission {}
        var correctOrdinal=wrongOrdinal;correctOrdinal.targetIDs=[other.id!.uuidString]
        _ = try await ordinal.executeConversation(call(correctOrdinal),planner:ordinalPlanner)
        print("PASS composable count/list groups retain local private fields without invalid references; explicit targets survive prior private selection; created neighborhood receipt supports dependent move in real SQLite; authorization mocked")
        let privateSection=try repo.createListSection(named:"Bar",in:city)
        let hiddenDestinationRequest=AskRequest(mode:.collection,text:"Move Barbara there",fromOCR:false,performanceID:UUID(),agentTask:.init(action:"query",fields:["note"],orderedIDs:[other.id!.uuidString],sourcePolicy:"local_only",privateSelection:true))
        let hiddenDestination=AskAgentExecutor(adapter:adapter,engine:engine,request:hiddenDestinationRequest,researcher:NoConversationResearch(),searchMaps:{_ in []}),hiddenPlanner=RecordingConversationFixture()
        await hiddenPlanner.setApproval(false)
        let hiddenProposal=AskChangeProposal(entity:"place",operation:"move",targetIDs:[],cityID:nil,sectionID:privateSection.id!.uuidString,mapMatchID:nil,changes:[],instructionQuote:hiddenDestinationRequest.text)
        _ = try await hiddenDestination.executeConversation(call(hiddenProposal),planner:hiddenPlanner)
        let hiddenReferences=await hiddenPlanner.lastReferences();precondition(hiddenReferences==nil)
        let clearForUndo=AskRequest(mode:.collection,text:"Clear Gramercy Tavern’s note",fromOCR:false,performanceID:UUID())
        other.note="Before-image must stay local";try context.save()
        let clearExecutor=AskAgentExecutor(adapter:adapter,engine:engine,request:clearForUndo,researcher:NoConversationResearch(),searchMaps:{_ in []})
        let clearProposal=AskChangeProposal(entity:"place",operation:"update",targetIDs:[other.id!.uuidString],cityID:nil,sectionID:nil,mapMatchID:nil,changes:[.init(field:"note",value:nil,values:nil,findingID:nil,source:"user")],instructionQuote:clearForUndo.text)
        _ = try await clearExecutor.executeConversation(call(clearProposal),planner:planner)
        let undoRequest=AskRequest(mode:.collection,text:"Undo only that clearing",fromOCR:false,performanceID:UUID(),agentTask:.init(action:"change",fields:["note"],orderedIDs:[other.id!.uuidString],sourcePolicy:"local_only",privateSelection:true))
        let undoExecutor=AskAgentExecutor(adapter:adapter,engine:engine,request:undoRequest,researcher:NoConversationResearch(),searchMaps:{_ in []}),undoPlanner=RecordingConversationFixture()
        await undoPlanner.setSelector(.init(city:nil,name:nil,neighborhood:nil,cuisine:nil,status:nil,placeType:nil,scope:"previous",positions:[]))
        let undoProposal=AskChangeProposal(entity:"place",operation:"undo",targetIDs:[],cityID:nil,sectionID:nil,mapMatchID:nil,changes:[],instructionQuote:undoRequest.text)
        _ = try await undoExecutor.executeConversation(call(undoProposal),planner:undoPlanner)
        let undoMetadata=await undoPlanner.lastUndoContext()
        precondition(undoMetadata==[.init(entity:"place",operation:"update",effect:"clear",fields:["note"])])
        let metadataJSON=String(data:try JSONEncoder().encode(undoMetadata),encoding:.utf8)!
        context.refreshAllObjects();precondition(other.note=="Before-image must stay local" && !metadataJSON.contains("Before-image"))
        let secondClear=AskRequest(mode:.collection,text:clearForUndo.text,fromOCR:false,performanceID:UUID())
        let secondClearExecutor=AskAgentExecutor(adapter:adapter,engine:engine,request:secondClear,researcher:NoConversationResearch(),searchMaps:{_ in []})
        _ = try await secondClearExecutor.executeConversation(call(clearProposal),planner:planner)
        let racingUndo=AskAgentExecutor(adapter:adapter,engine:engine,request:undoRequest,researcher:NoConversationResearch(),searchMaps:{_ in []})
        var explicitUndo=undoProposal;explicitUndo.targetIDs=[other.id!.uuidString]
        let concurrentUndo=ConcurrentConversationFixture(mutate:{
            let newer=AskChangeProposal(entity:"place",operation:"update",targetIDs:[other.id!.uuidString],cityID:nil,sectionID:nil,mapMatchID:nil,changes:[.init(field:"note",value:"Concurrent new note",values:nil,findingID:nil,source:"user")],instructionQuote:"Set this new note")
            let grant=AskChangeGrant(question:"Set this new note",entity:"place",operations:["update"],fields:["note"],targetIDs:[other.id!.uuidString],allowsCreation:false,boundProposal:newer,allowsReplacement:true)
            let ready=try engine.prepare(newer,question:"Set this new note",authorization:grant,findings:[],turnID:UUID())
            _ = try engine.apply(ready.id,authorization:grant)
        })
        do {_ = try await racingUndo.executeConversation(call(explicitUndo),planner:concurrentUndo);preconditionFailure("Undo rebound to newer journal action during authorization")}catch AskChangeError.conflict {}
        context.refreshAllObjects();precondition(other.note=="Concurrent new note")
        let createMapsRequest=AskRequest(mode:.collection,text:"Add The Modern to New York",fromOCR:false,performanceID:UUID())
        let mapExecutor=AskAgentExecutor(adapter:adapter,engine:engine,request:createMapsRequest,researcher:NoConversationResearch(),searchMaps:{query in precondition(query=="The Modern, New York");return [.init(applePlaceID:"isolated-modern",displayName:"The Modern",secondaryText:"New York",coordinate:nil,suggestedSectionPath:.init(cityOrRegion:"New York",neighborhood:nil),websiteURL:nil,instagramURL:nil)]})
        let search=try JSONSerialization.data(withJSONObject:["query":"The Modern","cityID":city.id!.uuidString])
        let mapResult=try await mapExecutor.executeConversation(.init(name:"search_maps",callID:"maps",arguments:String(data:search,encoding:.utf8)!),planner:planner)
        let mapID=mapResult.output.records[0].id,mapPlanner=RecordingConversationFixture()
        let createMap=AskChangeProposal(entity:"place",operation:"create",targetIDs:[],cityID:city.id!.uuidString,sectionID:nil,mapMatchID:mapID,changes:[],instructionQuote:createMapsRequest.text)
        let restoredChoices=try JSONDecoder().decode([AskMapChoice].self,from:JSONEncoder().encode(mapResult.response!.mapChoices!))
        let repeatedMapResult=try await mapExecutor.executeConversation(.init(name:"search_maps",callID:"maps-repeat",arguments:String(data:search,encoding:.utf8)!),planner:planner)
        precondition(repeatedMapResult.response?.mapChoices?.map(\.id)==restoredChoices.map(\.id) && repeatedMapResult.output.records.first?.detail=="New York")
        var restoredMapsRequest=createMapsRequest;restoredMapsRequest.mapChoices=restoredChoices
        let restoredMapsExecutor=AskAgentExecutor(adapter:adapter,engine:engine,request:restoredMapsRequest,researcher:NoConversationResearch(),searchMaps:{_ in preconditionFailure("Restored choice discarded its task")},resolveMaps:{id in restoredChoices.first(where:{$0.applePlaceID==id})?.match})
        _ = try await restoredMapsExecutor.executeConversation(call(createMap),planner:mapPlanner)
        _ = try await restoredMapsExecutor.executeConversation(call(createMap),planner:mapPlanner)
        let staleMapsExecutor=AskAgentExecutor(adapter:adapter,engine:engine,request:restoredMapsRequest,researcher:NoConversationResearch(),searchMaps:{_ in []},resolveMaps:{_ in nil})
        let staleChoice=try await staleMapsExecutor.executeConversation(call(createMap),planner:mapPlanner)
        precondition(staleChoice.output.status=="stale" && staleChoice.response?.executionStatus=="unresolved")
        print("PASS stable addressed Maps choices survive encoding, fresh revalidation and repeated execution; stale choice makes no write")
        let mapReferences=await mapPlanner.lastReferences()
        precondition(mapReferences?.contains(.init(kind:"maps",id:mapID,name:"The Modern",city:"New York"))==true && mapReferences?.contains(.init(kind:"city",id:city.id!.uuidString,name:"New York",city:"New York"))==true)
        let brokenMaps=AskAgentExecutor(adapter:adapter,engine:engine,request:createMapsRequest,researcher:NoConversationResearch(),searchMaps:{_ in throw NSError(domain:"MKErrorDomain",code:4)})
        let unavailableMaps=try await brokenMaps.executeConversation(.init(name:"search_maps",callID:"maps-failed",arguments:String(data:search,encoding:.utf8)!),planner:planner)
        precondition(unavailableMaps.output.status=="unavailable" && !unavailableMaps.output.complete && unavailableMaps.output.records.isEmpty && unavailableMaps.appendPreviousResults)
        precondition(!unavailableMaps.response!.summary.contains("MKErrorDomain"))
        let cancelledMaps=AskAgentExecutor(adapter:adapter,engine:engine,request:createMapsRequest,researcher:NoConversationResearch(),searchMaps:{_ in throw CancellationError()})
        do {_ = try await cancelledMaps.executeConversation(.init(name:"search_maps",callID:"maps-cancelled",arguments:String(data:search,encoding:.utf8)!),planner:planner);preconditionFailure("Cancellation was converted to empty/search failure")}catch is CancellationError {}
        context.refreshAllObjects()
        let currentName=place.displayNameSnapshot!,evidenceURL="https://www.le-bernardin.com/"
        let research=AskRetainedResearch(id:UUID(),originatingTurn:UUID(),query:currentName+" Instagram",result:.init(text:currentName+" official Instagram @lebernardinny",citations:[.init(title:"Official",url:evidenceURL)]))
        let saveResearchRequest=AskRequest(mode:.collection,text:"Save that Instagram",fromOCR:false,performanceID:UUID(),publicResearch:[research])
        let retainingExecutor=AskAgentExecutor(adapter:adapter,engine:engine,request:saveResearchRequest,researcher:NoConversationResearch(),searchMaps:{_ in []})
        func retainedCall(_ source:String,_ value:String)->AskAgentReply.Call {.init(name:"retain_findings",callID:"retain",arguments:String(data:try! JSONSerialization.data(withJSONObject:["findings":[["recordID":id,"field":"instagram","value":value,"sourceURL":source,"quote":research.result.text]]]),encoding:.utf8)!)}
        let retained=try retainingExecutor.retainPublicFindings(retainedCall(evidenceURL,"https://www.instagram.com/lebernardinny/"),evidence:[research])
        precondition(retained.response?.verifiedPublicFindings?.first?.externallyReusable==true)
        let repeatedRetention=try retainingExecutor.retainPublicFindings(retainedCall(evidenceURL,"https://www.instagram.com/lebernardinny/"),evidence:[research])
        precondition(repeatedRetention.response?.verifiedPublicFindings?.first?.id==retained.response?.verifiedPublicFindings?.first?.id)
        let nativeSourceID=SHA256.hash(data:Data(evidenceURL.utf8)).map {String(format:"%02x",$0)}.joined()
        let nativeEvidence=try AskNativeEvidence(version:1,blocks:[.init(id:"public:0",text:research.result.text,phase:"commentary",observedAt:"2026-11-02T22:00:00Z",annotations:[.init(sourceURL:evidenceURL,title:"Official",start:0,end:3,indexUnit:"provider_unmapped")])],sources:[.init(id:nativeSourceID,url:evidenceURL,title:"Official",roles:["cited"])],actions:[]).checked()
        let nativeResearch=AskRetainedResearch(id:UUID(),originatingTurn:research.originatingTurn,query:"Public native research",result:.init(text:"A bounded display excerpt",citations:[],nativeEvidence:nativeEvidence))
        let nativeRetained=try retainingExecutor.retainPublicFindings(retainedCall(evidenceURL,"https://www.instagram.com/lebernardinny/"),evidence:[nativeResearch])
        precondition(nativeRetained.response?.verifiedPublicFindings?.first?.id==retained.response?.verifiedPublicFindings?.first?.id)
        print("PASS native original source blocks associate a finding without relying on rewritten summary/query; existing save/no-op/persistence path reused")
        let mergedRetention=AskAgentLoop.merged(retained.response,repeatedRetention.response!)
        precondition(mergedRetention.fieldActions?.count==1)
        for invalid in [retainedCall("https://unrelated.example/","https://www.instagram.com/lebernardinny/"),retainedCall(evidenceURL,"https://www.instagram.com/unrelated/")] {
            do {_ = try retainingExecutor.retainPublicFindings(invalid,evidence:[research]);preconditionFailure("Forged public evidence retained")}catch AskError.invalidEvidence {}
        }
        let multiEvidence=AskRetainedResearch(id:UUID(),originatingTurn:UUID(),query:currentName+" official profile",result:.init(text:research.result.text+" Website "+evidenceURL,citations:research.result.citations))
        let multiItems:[[String:String]]=[["recordID":id,"field":"instagram","value":"https://www.instagram.com/lebernardinny/","sourceURL":evidenceURL,"quote":multiEvidence.result.text],["recordID":id,"field":"website","value":evidenceURL,"sourceURL":evidenceURL,"quote":multiEvidence.result.text]]
        let multiCall=AskAgentReply.Call(name:"retain_findings",callID:"multiple-fields",arguments:String(data:try JSONSerialization.data(withJSONObject:["findings":multiItems]),encoding:.utf8)!)
        let multiRetained=try retainingExecutor.retainPublicFindings(multiCall,evidence:[multiEvidence])
        precondition(multiRetained.orderedIDs==[id] && multiRetained.output.findings.count==2)
        let duplicateCall=AskAgentReply.Call(name:"retain_findings",callID:"duplicate-field",arguments:String(data:try JSONSerialization.data(withJSONObject:["findings":[multiItems[0],multiItems[0]]]),encoding:.utf8)!)
        do {_ = try retainingExecutor.retainPublicFindings(duplicateCall,evidence:[multiEvidence]);preconditionFailure("Duplicate record-field evidence accepted")}catch AskError.invalidEvidence {}
        let evidencePlanner=RecordingConversationFixture()
        let researchedEdit=AskChangeProposal(entity:"place",operation:"update",targetIDs:[id],cityID:nil,sectionID:nil,mapMatchID:nil,changes:[.init(field:"instagram",value:nil,values:nil,findingID:nil,source:"verified_finding")],instructionQuote:saveResearchRequest.text)
        let researchedSave=try await retainingExecutor.executeConversation(call(researchedEdit),planner:evidencePlanner)
        precondition(researchedSave.response?.verifiedPublicFindings?.contains(where:{$0.field=="instagram"})==true)
        let authorizationFindings=await evidencePlanner.lastFindings();precondition(authorizationFindings?.first?.value=="https://www.instagram.com/lebernardinny/")
        context.refreshAllObjects();precondition(place.instagramURL=="https://www.instagram.com/lebernardinny/")
        let truthfulCard=try adapter.fieldActionStatus(retained.response!.fieldActions!.first!)
        precondition(truthfulCard.outcome == .alreadySaved)
        let websiteEdit=AskChangeProposal(entity:"place",operation:"update",targetIDs:[id],cityID:nil,sectionID:nil,mapMatchID:nil,changes:[.init(field:"website",value:evidenceURL,values:nil,findingID:nil,source:"verified_finding")],instructionQuote:saveResearchRequest.text)
        let websiteSave=try await retainingExecutor.executeConversation(call(websiteEdit),planner:evidencePlanner)
        let websiteFact=websiteSave.response!.verifiedPublicFindings!.first(where:{$0.field=="website"})!
        precondition(websiteFact.id==multiRetained.response!.verifiedPublicFindings!.first(where:{$0.field=="website"})!.id && websiteFact.identity.website==evidenceURL && websiteFact.evidenceURL==evidenceURL)
        let archivedWebsite=try JSONDecoder().decode(AskResponse.self,from:JSONEncoder().encode(websiteSave.response!))
        let repeatWebsiteRequest=AskRequest(mode:.collection,text:"Save that same website again",fromOCR:false,verifiedFindings:archivedWebsite.verifiedPublicFindings!,performanceID:UUID())
        let repeatWebsiteExecutor=AskAgentExecutor(adapter:adapter,engine:engine,request:repeatWebsiteRequest,researcher:NoConversationResearch(),searchMaps:{_ in []})
        let repeatWebsiteProposal=AskChangeProposal(entity:"place",operation:"update",targetIDs:[id],cityID:nil,sectionID:nil,mapMatchID:nil,changes:websiteEdit.changes,instructionQuote:repeatWebsiteRequest.text)
        let repeatWebsite=try await repeatWebsiteExecutor.executeConversation(call(repeatWebsiteProposal),planner:evidencePlanner)
        precondition(repeatWebsite.output.status=="unchanged" && repeatWebsite.response?.collectionActions?.allSatisfy({!$0.undoable})==true && repeatWebsite.response?.verifiedPublicFindings?.contains(where:{$0.id==websiteFact.id})==true)
        context.refreshAllObjects();place.displayNameSnapshot=currentName+" — branch changed";try context.save()
        let postCommitDriftRequest=AskRequest(mode:.collection,text:"Change its type to Cafe",fromOCR:false,verifiedFindings:[websiteFact],performanceID:UUID())
        let postCommitDriftExecutor=AskAgentExecutor(adapter:adapter,engine:engine,request:postCommitDriftRequest,researcher:NoConversationResearch(),searchMaps:{_ in []})
        let postCommitDriftProposal=AskChangeProposal(entity:"place",operation:"update",targetIDs:[id],cityID:nil,sectionID:nil,mapMatchID:nil,changes:[.init(field:"type",value:PlaceType.cafe.rawValue,values:nil,findingID:nil,source:"user")],instructionQuote:postCommitDriftRequest.text)
        let postCommitDriftResponse=try await postCommitDriftExecutor.executeConversation(call(postCommitDriftProposal),planner:evidencePlanner)
        precondition(postCommitDriftResponse.output.status=="applied" && postCommitDriftResponse.response?.verifiedPublicFindings==nil)
        print("PASS source-quoted public finding flows to both planner result and authorization context, then narrow persistence; forged source/value rejected")
        let concurrentUpdateRequest=AskRequest(mode:.collection,text:"Replace the note for Gramercy Tavern",fromOCR:false,performanceID:UUID())
        let concurrentUpdate=AskAgentExecutor(adapter:adapter,engine:engine,request:concurrentUpdateRequest,researcher:NoConversationResearch(),searchMaps:{_ in []})
        var pendingNote=clearProposal;pendingNote.changes=[.init(field:"note",value:"Requested note",values:nil,findingID:nil,source:"user")]
        let competing=ConcurrentConversationFixture(mutate:{other.note="Newer user note";try context.save()})
        do {_ = try await concurrentUpdate.executeConversation(call(pendingNote),planner:competing);preconditionFailure("A changed field was overwritten after awaiting authorization")}catch AskChangeError.conflict {}
        context.refreshAllObjects();precondition(other.note=="Newer user note")
        let removeRequest=AskRequest(mode:.collection,text:"Remove those two places",fromOCR:false,performanceID:UUID())
        let remover=AskAgentExecutor(adapter:adapter,engine:engine,request:removeRequest,researcher:NoConversationResearch(),searchMaps:{_ in []})
        let removal=AskChangeProposal(entity:"place",operation:"delete",targetIDs:[id,other.id!.uuidString],cityID:nil,sectionID:nil,mapMatchID:nil,changes:[],instructionQuote:removeRequest.text)
        let pending=try await remover.executeConversation(call(removal),planner:planner)
        let reviews=pending.response!.collectionActions!;precondition(reviews.count==2 && reviews.allSatisfy {$0.state == .needsConfirmation})
        other.displayNameSnapshot="Gramercy Tavern — newer edit";try context.save()
        let confirmRequest=AskRequest(mode:.collection,text:"Confirm both removals",fromOCR:false,pendingActions:reviews)
        let confirmer=AskAgentExecutor(adapter:adapter,engine:engine,request:confirmRequest,researcher:NoConversationResearch(),searchMaps:{_ in []})
        let args=try JSONSerialization.data(withJSONObject:["actionIDs":reviews.map {$0.id.uuidString}])
        let partial=try await confirmer.executeConversation(.init(name:"confirm_changes",callID:"confirm",arguments:String(data:args,encoding:.utf8)!),planner:planner)
        precondition(partial.output.status=="unavailable" && partial.response?.collectionActions?.count==1 && partial.selectionIsPrivate)
        context.refreshAllObjects();let survivors=try context.fetch(SavedPlace.fetchRequest());precondition(!survivors.contains {$0.id?.uuidString==id} && survivors.contains {$0.id==other.id})
        var reviewedResponse=pending.response!
        var settled=reviews;for i in settled.indices {settled[i].state = .applied}
        reviewedResponse.collectionActions=settled;reviewedResponse.refreshCollectionReviewStatus()
        precondition(reviewedResponse.summary=="Saved." && reviewedResponse.paragraphs.first?.spans==[.text("Saved.")])
        for i in settled.indices {settled[i].state = .undone}
        var undoneReview=reviewedResponse;undoneReview.collectionActions=settled;undoneReview.refreshCollectionReviewStatus()
        precondition(undoneReview.summary=="Undone.")
        var explanation=reviewedResponse;explanation.paragraphs=[.init(id:"agent-message",spans:[.text("A useful explanation with 16 places.")],sourceIDs:[])];explanation.refreshCollectionReviewStatus()
        precondition(explanation.paragraphs[0].spans==[.text("A useful explanation with 16 places.")])
        print("PASS new conversation executor uses real SQLite for distinct creates, grouped-to-single replay, explicit clear with retained finding, narrow fields and partial confirmation receipts; authorization model mocked")
    }
}
