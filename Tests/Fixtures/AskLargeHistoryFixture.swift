import Foundation
import CoreData

private struct NavigationNoResearch:AskBusinessResearching {
    func publicLookupAvailable()async->Bool {false}
    func businessResearch(_ request:AskBusinessRequest)async throws->AskBusinessResult {preconditionFailure("Offline navigation fixture must not call a provider")}
}
private actor NavigationPagedPlanner:AskConversationPlanning {
    func conversationAvailable()async->Bool {true}
    func conversationStep(_ step:AskConversationStep)async throws->AskConversationReply {
        var query:[String:Any] = ["operation":"list","scope":"library","positions":[],"fields":["note"],"limit":200]
        let more=step.step==0 || (step.step<10 && step.result?.output.nextOffset != nil)
        if step.step>0,let output=step.result?.output {query["offset"]=output.nextOffset;query["snapshot"]=output.snapshot}
        let call=more ? AskAgentReply.Call(name:"query_collection",callID:"page-\(step.step)",arguments:String(data:try JSONSerialization.data(withJSONObject:["entity":"place","query":query]),encoding:.utf8)!) : nil
        return .init(version:9,requestID:step.requestID,step:step.step,kind:more ? "tool" : "answer",text:more ? "" : "These are the requested saved notes.",continuation:"offline-navigation",model:"fixture",call:call)
    }
    func searchConversationWeb(_ query:String)async throws->AskWebResearchResult {preconditionFailure("No web calls")}
    func authorizePendingConfirmation(_ actions:[AskCollectionAction],question:String,history:[String])async throws->AskHumanAuthorization {preconditionFailure("Read-only fixture")}
    func authorizeConversationChange(_ proposal:AskChangeProposal,question:String,history:[String],targets:[AskAgentRecord])async throws->AskHumanAuthorization {preconditionFailure("Read-only fixture")}
}
struct AskLargeHistoryProvider:AskFeastProvider {
    let label="Offline navigation fixture"
    let adapter:AskSavedCollection,engine:AskCollectionChangeEngine
    func answer(_ request:AskRequest,tools:AskReadTools)async throws->AskResponse {
        let view=try await adapter.readView(),semantic=try AskSemanticContext.make(request,catalog:view.snapshot,fullCollection:true)
        let planner=NavigationPagedPlanner()
        let executor=await AskAgentExecutor(adapter:adapter,engine:engine,request:request,researcher:NavigationNoResearch(),searchMaps:{_ in []},fullCollectionContext:true,supportsCollectionQueryV2:true)
        let candidates=AskReadTools.localCandidates(Set(view.snapshot.places.map(\.id)),in:view.index)
        return try await AskConversationLoop(planner:planner,availableCandidates:candidates,execute:{try await executor.executeConversation($0,planner:planner)},collectionQueryVersion:2,nativeResearch:true).answer(request,context:semantic,cities:[],findings:[])
    }
}
/// Actual Session -> native loop -> paged SQLite query, not a fabricated response.
@MainActor struct AskLargeHistoryFixture {
    let adapter:AskSavedCollection,provider:AskLargeHistoryProvider
    init(model:NSManagedObjectModel,directory:URL)throws {
        try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:true)
        let coordinator=NSPersistentStoreCoordinator(managedObjectModel:model)
        try coordinator.addPersistentStore(ofType:NSSQLiteStoreType,configurationName:nil,at:directory.appendingPathComponent("collection.sqlite"))
        let context=NSManagedObjectContext(concurrencyType:.mainQueueConcurrencyType);context.persistentStoreCoordinator=coordinator
        let city=FeastList(context:context);city.id=UUID();city.name="Navigation City";city.createdAt=Date();city.updatedAt=Date()
        for i in 0..<200 {
            let place=SavedPlace(context:context);place.id=UUID();place.feastList=city;place.displayNameSnapshot=String(format:"Saved %03d",i);place.applePlaceID="navigation-\(i)";place.placeStatus = .wantToTry;place.placeTypeValue = .restaurant;place.cuisines=[];place.tags=[];place.note=String(repeating:"n",count:3500);place.createdAt=Date();place.updatedAt=Date()
        }
        try context.save()
        adapter = .init(context:context,visibleCities:{[city.id!]})
        provider = .init(adapter:adapter,engine:.init(adapter:adapter,journalURL:directory.appendingPathComponent("actions.json")))
    }
    func session(store:AskConversationStore?=nil)throws->AskSession {
        let session=AskSession(index:try adapter.index(),provider:provider);session.refreshIndex={try adapter.index()}
        if let store {session.restoreHistory(from:store)}
        return session
    }
    func answer(_ session:AskSession)async throws {
        session.input="Show saved places with their notes";session.run()
        for _ in 0..<20_000 {if !session.isLoading {break};try await Task.sleep(nanoseconds:1_000_000)}
        precondition(session.turns.last?.status == .complete && session.response?.collectionPage != nil,"The real large native fixture must be accepted")
    }
    func nearLimitLibrary(turn:AskTurn)throws->AskChatLibrary {
        var library=AskChatLibrary.empty()
        while true {
            var next=library
            var copy=turn;copy = .init(id:UUID(),request:turn.request,response:turn.response,sources:turn.sources,status:turn.status)
            next.chats[0].conversation.turns.append(.init(copy))
            if try JSONEncoder().encode(next).count>8*1024*1024 {break}
            library=next
        }
        precondition((1..<100).contains(library.chats[0].conversation.turns.count))
        return library
    }
}
