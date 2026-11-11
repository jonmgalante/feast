import Foundation
import CoreData

private struct HistoryNoFallback:AskFeastProvider {
    let label="Offline history fixture"
    func answer(_ request:AskRequest,tools:AskReadTools)async throws->AskResponse {preconditionFailure("Unexpected legacy fallback")}
}
private actor HistoryProjectionWire {
    let longAnswer:String?
    private var received:[AskConversationStep]=[]
    private var bodies:[Data]=[]
    init(longAnswer:String?=nil) {self.longAnswer=longAnswer}
    func steps()->[AskConversationStep] {received}
    func requests()->[Data] {bodies}
    func send(_ request:URLRequest)throws->(Data,HTTPURLResponse) {
        let step=try JSONDecoder().decode(AskConversationStep.self,from:request.httpBody!)
        bodies.append(request.httpBody!)
        received.append(step)
        let call:AskAgentReply.Call?
        let text:String
        if step.text.hasPrefix("Remember my lunch budget") {
            call=step.step==0 ? .init(name:"query_collection",callID:"notes",arguments:"{\"entity\":\"place\",\"query\":{\"operation\":\"list\",\"scope\":\"library\",\"positions\":[],\"fields\":[\"note\"]}}") : nil
            text=call==nil ? "Your saved notes are displayed below." : ""
        }else if step.text=="Give me the complete explanation" {
            call=nil;text=longAnswer!
        }else {
            let args=longAnswer==nil ? "{\"offset\":0,\"limit\":12}" : "{\"offset\":1,\"limit\":1,\"textOffset\":1800}"
            call=step.step==0 ? .init(name:"read_conversation",callID:"history",arguments:args) : nil
            text=call==nil ? "I checked the available earlier context." : ""
        }
        var reply=AskConversationReply(version:step.version,requestID:step.requestID,step:step.step,kind:call==nil ? "answer" : "tool",text:text,continuation:"mock-only",model:"gpt-6.1-sol",call:call)
        if step.version==10 {reply.nativeEvidence = .init(version:1,blocks:[],sources:[],actions:[]);reply.finalCitations=[]}
        return (try JSONEncoder().encode(reply),HTTPURLResponse(url:request.url!,statusCode:200,httpVersion:nil,headerFields:["Content-Type":"application/json"])!)
    }
}
@MainActor enum AskHistoryProjectionTests {
    static func legacyPublicPrivacy(model:NSManagedObjectModel,directory:URL)async throws {
        let folder=directory.appendingPathComponent("history-v6-privacy")
        try FileManager.default.createDirectory(at:folder,withIntermediateDirectories:true)
        let coordinator=NSPersistentStoreCoordinator(managedObjectModel:model)
        _ = try coordinator.addPersistentStore(ofType:NSSQLiteStoreType,configurationName:nil,at:folder.appendingPathComponent("collection.sqlite"))
        let context=NSManagedObjectContext(concurrencyType:.mainQueueConcurrencyType);context.persistentStoreCoordinator=coordinator
        let repo=FeastRepository(context:context),city=try repo.createFeastList(named:"Legacy Privacy City")
        let origin=try repo.createSavedPlace(from:.init(applePlaceID:"legacy-origin",displayNameSnapshot:"Earlier Public Origin",status:.wantToTry,placeType:.cafe,cuisines:[],tags:[],note:"LOCAL_PRIVATE_NOTE",websiteURL:nil,instagramURL:nil,feastList:city,listSection:nil))
        let originID=origin.id!.uuidString
        let adapter=AskSavedCollection(context:context,visibleCities:{[city.id!]})
        let engine=AskCollectionChangeEngine(adapter:adapter,journalURL:folder.appendingPathComponent("actions.json"))
        func provider(_ wire:HistoryProjectionWire)->AskAgentProvider {
            let hosted=AskHostedProvider(configuration:.init(environment:.development,endpoint:URL(string:"https://history-v6-fixture.workers.dev/v1/answer")!,scope:.savedMetadata),token:{String(repeating:"V",count:43)},approve:{_,_ in true},send:{try await wire.send($0)},libraryToolsEnabled:{true},permission:{true},libraryPlanVersion:{6},nativeResearchEnabled:{false})
            return .init(remote:hosted,fallback:HistoryNoFallback(),adapter:adapter,engine:engine,searchMaps:{_ in []})
        }
        let store=AskConversationStore(url:folder.appendingPathComponent("history.json"))
        let firstWire=HistoryProjectionWire(longAnswer:"REVOKED_PUBLIC_ORIGIN_TEXT"),first=AskSession(index:try adapter.index(),provider:provider(firstWire))
        first.restoreHistory(from:store);first.refreshIndex={try adapter.index()}
        first.input="Give me the complete explanation";first.run();while first.isLoading {await Task.yield()};first.flushHistory()
        precondition(first.turns.last?.status == .complete && first.response?.publicConversationText?.contains("REVOKED_PUBLIC_ORIGIN_TEXT")==true)
        precondition(first.response?.historyRecordIDs?.contains(originID)==true,"The public answer must retain its actual prompt origin")
        var oldRequest=try JSONSerialization.jsonObject(with:JSONEncoder().encode(first.turns[0].request)) as! [String:Any]
        oldRequest.removeValue(forKey:"publicHistory")
        let decoded=try JSONDecoder().decode(AskRequest.self,from:JSONSerialization.data(withJSONObject:oldRequest))
        precondition(decoded.publicHistory==nil,"Pre-upgrade requests must still decode without the optional public-history field")
        var library=try store.loadLibrary()
        let rich=AskResponse(summary:"PRIVATE_RICH_RAW_TEXT",candidates:[],paragraphs:[.init(id:"rich",spans:[.text("PRIVATE_RICH_RAW_TEXT")],sourceIDs:[],historyRecordIDs:[])],listedCandidateIDs:[],usesLocalCatalog:true,agentTask:.init(action:"query",fields:["note"],orderedIDs:[],sourcePolicy:"local_only",privateSelection:true),collectionConversationText:"PRIVATE_RICH_APPROVED_TEXT",historyRecordIDs:[],retainsIndependentQuestion:true)
        let independent=AskResponse(summary:"INDEPENDENT_PUBLIC_V6_TEXT",candidates:[],paragraphs:[.init(id:"public",spans:[.text("INDEPENDENT_PUBLIC_V6_TEXT")],sourceIDs:[],historyRecordIDs:[])],listedCandidateIDs:[],usesLocalCatalog:true,publicConversationText:"INDEPENDENT_PUBLIC_V6_TEXT",historyRecordIDs:[],retainsIndependentQuestion:true)
        library.chats[0].conversation.turns += [AskArchivedTurn(.init(id:UUID(),request:.init(mode:.collection,text:"Earlier private request",fromOCR:false),response:rich,status:.complete)),AskArchivedTurn(.init(id:UUID(),request:.init(mode:.collection,text:"Earlier independent public request",fromOCR:false),response:independent,status:.complete))]
        precondition(store.saveLibrary(library));try repo.delete(origin)
        let wire=HistoryProjectionWire(),session=AskSession(index:try adapter.index(),provider:provider(wire))
        session.restoreHistory(from:store);session.refreshIndex={try adapter.index()}
        session.input="Review the earlier public explanation";session.run();while session.isLoading {await Task.yield()}
        let steps=await wire.steps(),bodies=await wire.requests(),sent=bodies.map {String(decoding:$0,as:UTF8.self)}.joined()
        precondition(session.turns.last?.status == .complete && !steps.isEmpty)
        precondition(steps.allSatisfy {$0.version==9 && $0.context.collectionAccess==nil && $0.retainedHistoryVersion==nil},"The regression must exercise actual libraryPlanVersion 6 without rich or paging capability")
        precondition(!sent.contains("REVOKED_PUBLIC_ORIGIN_TEXT"),"The non-rich v6 route resent a public answer after its saved origin was removed")
        precondition(sent.contains("INDEPENDENT_PUBLIC_V6_TEXT") && !sent.contains("PRIVATE_RICH_"),"Legacy projection must preserve independent public history without promoting raw or approved rich history")
        let captured=try bodies.map {try JSONSerialization.jsonObject(with:$0)},path=folder.appendingPathComponent("requests.json")
        try JSONSerialization.data(withJSONObject:captured).write(to:path)
        let process=Process();process.executableURL=URL(fileURLWithPath:"/usr/bin/env");process.arguments=["node","Tests/validate-retained-channel-requests.mjs",path.path];try process.run();process.waitUntilExit();precondition(process.terminationStatus==0)
        let original=try store.loadLibrary().chats[0].conversation.turns[0].response
        precondition(original==library.chats[0].conversation.turns[0].response,"Permission filtering must not rewrite the original archive")
        print("PASS actual v6 public history is permission-filtered while independent public context survives and rich material stays local")
    }
    static func verifyRevokedArchive(store:AskConversationStore,adapter:AskSavedCollection,engine:AskCollectionChangeEngine,forbidden:String,requiredHistory:String?=nil)async throws {
        let wire=HistoryProjectionWire()
        let hosted=AskHostedProvider(configuration:.init(environment:.development,endpoint:URL(string:"https://history-fixture.workers.dev/v1/answer")!,scope:.savedMetadata),token:{String(repeating:"A",count:43)},approve:{_,_ in true},send:{try await wire.send($0)},libraryToolsEnabled:{true},permission:{true},libraryPlanVersion:{7},nativeResearchEnabled:{true},collectionQueriesEnabled:{true},retainedHistoryEnabled:{true})
        let provider=AskAgentProvider(remote:hosted,fallback:HistoryNoFallback(),adapter:adapter,engine:engine,searchMaps:{_ in []})
        let session=AskSession(index:try adapter.index(),provider:provider);session.restoreHistory(from:store);session.refreshIndex={try adapter.index()}
        session.input="Check the earlier context once more";session.run();while session.isLoading {await Task.yield()}
        let steps=await wire.steps();precondition(session.turns.last?.status == .complete && !steps.isEmpty)
        let body=String(data:try JSONEncoder().encode(steps),encoding:.utf8)!;precondition(!body.contains(forbidden),"Revoked deleted-record before-image reached a provider")
        if let requiredHistory {precondition(steps.flatMap {$0.result?.output.history ?? []}.map(\.text).joined().contains(requiredHistory),"Independent permitted native history must remain readable")}
    }
    static func legacyTail(directory:URL,adapter:AskSavedCollection,engine:AskCollectionChangeEngine)async throws {
        let marker="FINAL IMPORTANT POINT: choose South not North."
        for name in ["AskLegacyPublicHistory","AskLegacyClippedHistory","AskLegacyUnicodeClippedHistory"] {
            let fixture=name=="AskLegacyUnicodeClippedHistory" ? "AskLegacyClippedHistory" : name
            let source=URL(fileURLWithPath:#filePath).deletingLastPathComponent().appendingPathComponent("Fixtures/"+fixture+".json")
            let bytes=try Data(contentsOf:source)
            var library=try JSONDecoder().decode(AskChatLibrary.self,from:bytes)
            if name=="AskLegacyUnicodeClippedHistory" {
                // The old Character-bounded writer can stop well before 1,700
                // UTF-16 units when its next grapheme alone exceeds the budget.
                var original=library.chats[0].conversation.turns[0].turn
                original.response!.collectionConversationText="Short prelude "
                original.response!.paragraphs=[.init(id:"old-native",spans:[.text("Short prelude e"+String(repeating:"\u{301}",count:3500)+" LEGACY_UNPROVEN_RAW_TAIL")],sourceIDs:[])]
                library.chats[0].conversation.turns[0]=AskArchivedTurn(original)
            }
            precondition(library.chats[0].conversation.turns[0].response.retainsIndependentQuestion==nil)
            let store=AskConversationStore(url:directory.appendingPathComponent(name+".json"));precondition(store.saveLibrary(library))
            let wire=HistoryProjectionWire(longAnswer:marker)
            let hosted=AskHostedProvider(configuration:.init(environment:.development,endpoint:URL(string:"https://legacy-history-fixture.workers.dev/v1/answer")!,scope:.savedMetadata),token:{String(repeating:"L",count:43)},approve:{_,_ in true},send:{try await wire.send($0)},libraryToolsEnabled:{true},permission:{true},libraryPlanVersion:{7},nativeResearchEnabled:{true},retainedHistoryEnabled:{true})
            let provider=AskAgentProvider(remote:hosted,fallback:HistoryNoFallback(),adapter:adapter,engine:engine,searchMaps:{_ in []})
            let session=AskSession(index:try adapter.index(),provider:provider);session.refreshIndex={try adapter.index()};session.restoreHistory(from:store)
            session.input="Retrieve the final important point";session.run();while session.isLoading {await Task.yield()}
            precondition(session.turns.last?.status == .complete)
            let steps=await wire.steps(),body=String(data:try JSONEncoder().encode(steps),encoding:.utf8)!
            if name=="AskLegacyPublicHistory" {
                precondition(body.contains(marker),"The baseline serialized full public projection lost its tail during upgrade")
            }else {
                precondition(!body.contains(marker) && !body.contains("LEGACY_UNPROVEN_RAW_TAIL") && body.contains("Only the approved excerpt"),"Upgrade must not invent permission for unprojected legacy paragraphs, and must disclose the missing tail")
                precondition(steps.last?.result?.output.complete==false,"A clipped legacy projection must not claim full historical completeness")
            }
            let archived=try store.loadLibrary().chats[0].conversation.turns[0].response
            precondition(archived.paragraphs==library.chats[0].conversation.turns[0].response.paragraphs,"A retrieval limitation must not alter the original archived answer")
        }
        print("PASS authentic pre-upgrade full public projections page their tail; already-clipped rich projections remain unchanged and explicitly unavailable without leaking unproven raw paragraphs")
    }
    static func run(model:NSManagedObjectModel,directory:URL,tail:Bool)async throws {
        let label=tail ? "tail" : "fragments"
        let coordinator=NSPersistentStoreCoordinator(managedObjectModel:model)
        _ = try coordinator.addPersistentStore(ofType:NSSQLiteStoreType,configurationName:nil,at:directory.appendingPathComponent(label+"-history.sqlite"))
        let context=NSManagedObjectContext(concurrencyType:.mainQueueConcurrencyType);context.persistentStoreCoordinator=coordinator
        let repo=FeastRepository(context:context),firstCity=try repo.createFeastList(named:"Earlier City"),secondCity=try repo.createFeastList(named:"Still Permitted City")
        let unavailable=try repo.createSavedPlace(from:.init(applePlaceID:"history-hidden",displayNameSnapshot:"Earlier Cafe",status:.wantToTry,placeType:.cafe,cuisines:[],tags:[],note:"REVOKED_NOTE_NEVER_SEND",websiteURL:nil,instagramURL:nil,feastList:firstCity,listSection:nil))
        _ = try repo.createSavedPlace(from:.init(applePlaceID:"history-visible",displayNameSnapshot:"Permitted Cafe",status:.wantToTry,placeType:.cafe,cuisines:[],tags:[],note:"PERMITTED_NOTE_RETAIN",websiteURL:nil,instagramURL:nil,feastList:secondCity,listSection:nil))
        var visible:Set<UUID>=[firstCity.id!,secondCity.id!]
        let adapter=AskSavedCollection(context:context,visibleCities:{visible})
        let engine=AskCollectionChangeEngine(adapter:adapter,journalURL:directory.appendingPathComponent(label+"-history-actions.json"))
        let marker="FINAL IMPORTANT POINT: choose South not North."
        let longText=String(repeating:"Useful explanation. ",count:100)+marker
        let wire=HistoryProjectionWire(longAnswer:tail ? longText : nil)
        let hosted=AskHostedProvider(configuration:.init(environment:.development,endpoint:URL(string:"https://history-fixture.workers.dev/v1/answer")!,scope:.savedMetadata),token:{String(repeating:"A",count:43)},approve:{_,_ in true},send:{try await wire.send($0)},libraryToolsEnabled:{true},permission:{true},libraryPlanVersion:{7},nativeResearchEnabled:{true},collectionQueriesEnabled:{true},retainedHistoryEnabled:{true})
        let provider=AskAgentProvider(remote:hosted,fallback:HistoryNoFallback(),adapter:adapter,engine:engine,searchMaps:{_ in []})
        let store=AskConversationStore(url:directory.appendingPathComponent(label+"-history.json"))
        let session=AskSession(index:try adapter.index(),provider:provider);session.restoreHistory(from:store);session.refreshIndex={try adapter.index()}
        session.input=tail ? "Give me the complete explanation" : "Remember my lunch budget is $25; show both saved notes";session.run();while session.isLoading {await Task.yield()}
        precondition(session.turns.last?.status == .complete)
        session.flushHistory()
        if !tail {
            // Auxiliary archive payloads use the same originating response proof,
            // not an assumption that public/native evidence is independent.
            var library=try store.loadLibrary(),origin=library.chats[0].conversation.turns[0].turn
            origin.response!.publicResearch=[.init(id:UUID(),originatingTurn:origin.id,query:"REVOKED_RESEARCH_QUERY",result:.init(text:"REVOKED_RESEARCH_DETAIL",citations:[]))]
            origin.response!.mapChoices=[.init(id:UUID().uuidString,applePlaceID:"offline-map",name:"REVOKED_MAP_NAME",address:"REVOKED_MAP_DETAIL",city:"Earlier City",query:"REVOKED_MAP_QUERY",website:nil,originatingTurn:origin.id)]
            origin.response!.collectionActions=[.init(id:UUID(),title:"REVOKED_ACTION_TITLE",targetIDs:[unavailable.id!.uuidString],entity:"place",operation:"update",state:.needsConfirmation,undoable:false,detail:"REVOKED_ACTION_DETAIL"),.init(id:UUID(),title:"REVOKED_EMPTY_TARGET_TITLE",targetIDs:[],entity:"city",operation:"create",state:.needsConfirmation,undoable:false,detail:"REVOKED_EMPTY_TARGET_DETAIL")]
            let permitted=try adapter.personalPlaces().first {$0.name=="Permitted Cafe"}!
            let relatedFinding=AskVerifiedFinding(id:UUID(),recordID:permitted.id,identity:.init(permitted),field:"instagram",value:"https://www.instagram.com/related_research/",evidenceURL:"https://example.org/REVOKED_FINDING_SOURCE",verification:"cited_search",originatingTurn:origin.id,externallyReusable:true)
            origin.response!.verifiedPublicFindings=[relatedFinding]
            origin.response!.fieldActions=[.init(finding:relatedFinding)]
            library.chats[0].conversation.turns[0]=AskArchivedTurn(origin)
            var independent=AskResponse(summary:"INDEPENDENT_PUBLIC_RESULT",candidates:[],paragraphs:[.init(id:"independent",spans:[.text("INDEPENDENT_PUBLIC_RESULT")],sourceIDs:[],historyRecordIDs:[])],listedCandidateIDs:[],usesLocalCatalog:true,publicConversationText:"INDEPENDENT_PUBLIC_RESULT",historyRecordIDs:[],retainsIndependentQuestion:true)
            independent.publicResearch=[.init(id:UUID(),originatingTurn:UUID(),query:"INDEPENDENT_PUBLIC_QUERY",result:.init(text:"INDEPENDENT_PUBLIC_RESULT",citations:[]))]
            library.chats[0].conversation.turns.append(AskArchivedTurn(.init(id:UUID(),request:.init(mode:.collection,text:"Look up this independent public question",fromOCR:false),response:independent,status:.complete)))
            precondition(store.saveLibrary(library));try repo.delete(unavailable)
        }
        let reopened=AskSession(index:try adapter.index(),provider:provider);reopened.restoreHistory(from:store);reopened.refreshIndex={try adapter.index()}
        if !tail {
            let presented=reopened.presentedTurn(reopened.turns[0])
            let displayed=AskAnswerCopy.text(presented.response!)+presented.sources.map(\.excerpt).joined()
            precondition(displayed.contains("PERMITTED_NOTE_RETAIN") && !displayed.contains("REVOKED_NOTE_NEVER_SEND") && !displayed.contains("Earlier Cafe"),"Archived UI/copy leaked removed record details or hid permitted rows")
            let projected=String(data:try JSONEncoder().encode(presented.response),encoding:.utf8)!
            precondition(!projected.contains("REVOKED_"),"Dependent finding cards or targetless action details leaked through history presentation")
            var legacy=reopened.turns[0]
            legacy.response!.retainsIndependentQuestion=nil;legacy.response!.historyRecordIDs=nil
            for i in legacy.response!.paragraphs.indices {legacy.response!.paragraphs[i].historyRecordIDs=nil}
            let safe=AskConversationProjection.retainedMessages([legacy]).map {$0.permitted((try! adapter.index()).historyAccessIDs).message.text}.joined()
            precondition(!safe.contains("REVOKED_NOTE_NEVER_SEND") && !safe.contains("PERMITTED_NOTE_RETAIN"),"Legacy unproven prose was promoted to safe per-fragment history")
        }
        reopened.input=tail ? "Retrieve the final important point" : "What was my lunch budget and the remaining saved note?";reopened.run();while reopened.isLoading {await Task.yield()}
        precondition(reopened.turns.last?.status == .complete)
        let sent=await wire.steps(),followup=sent.filter {$0.text==reopened.turns.last!.request.text}
        let history=followup.flatMap {($0.result?.output.history ?? [])+$0.history}.map(\.text).joined(separator:"\n")
        if tail {
            precondition(history.contains(marker),"Retained answer tail is unreachable after archive reload/read_conversation")
            precondition(followup[0].history.last?.text.contains("excerpt")==true,"Bounded initial history must disclose its excerpt")
        }else {
            precondition(history.contains("lunch budget is $25"),"Removing one record erased an independent human preference")
            precondition(history.contains("PERMITTED_NOTE_RETAIN"),"Removing one record erased an unrelated native history fragment")
            precondition(!history.contains("REVOKED_NOTE_NEVER_SEND") && !history.contains("Earlier Cafe"),"Revoked history escaped its permission boundary")
            let body=String(data:try JSONEncoder().encode(followup),encoding:.utf8)!
            precondition(!body.contains("REVOKED_"),"An auxiliary retained channel leaked inaccessible context")
            precondition(body.contains("INDEPENDENT_PUBLIC_RESULT"),"Truly independent public evidence should remain available")
        }
        if tail {try await legacyTail(directory:directory,adapter:adapter,engine:engine)}
        // A real permission change without deleting collection data must have the same boundary.
        visible=[]
        let hidden=reopened.presentedTurn(reopened.turns[0])
        let hiddenText=AskAnswerCopy.text(hidden.response!)+hidden.sources.map(\.excerpt).joined()
        precondition(!hiddenText.contains("PERMITTED_NOTE_RETAIN") && !hiddenText.contains("REVOKED_NOTE_NEVER_SEND"))
        if tail {precondition(!hiddenText.contains(marker))}
        reopened.input="Check the earlier context once more";reopened.run();while reopened.isLoading {await Task.yield()}
        let deniedSteps=await wire.steps(),denied=deniedSteps.filter {$0.text=="Check the earlier context once more"}
        let deniedBody=String(data:try JSONEncoder().encode(denied),encoding:.utf8)!
        precondition(!deniedBody.contains("PERMITTED_NOTE_RETAIN") && !deniedBody.contains("REVOKED_NOTE_NEVER_SEND"))
        if tail {precondition(!deniedBody.contains(marker))}
        else {
            precondition(!deniedBody.contains("REVOKED_") && deniedBody.contains("INDEPENDENT_PUBLIC_RESULT"))
            var library=try store.loadLibrary();let original=library.chats[0].conversation.turns[0].turn
            library.chats[0].conversation.turns=(0..<100).map {i in AskArchivedTurn(.init(id:UUID(),request:.init(mode:.collection,text:"Historical question \(i)",fromOCR:false),response:original.response,sources:original.sources,status:.complete))}
            precondition(store.saveLibrary(library))
            let many=AskSession(index:try adapter.index(),provider:provider);many.restoreHistory(from:store)
            var reads=0;many.refreshIndex={reads+=1;return try adapter.index()}
            precondition(many.presentedTurns().count==100 && reads==1,"One render must use one collection access snapshot")
            _=many.source("not-present");precondition(reads==2,"One source lookup must not refetch the collection per turn")
        }
        let unicode=String(repeating:"🍜café ",count:500)
        let excerpt=AskConversationProjection.excerpt(unicode,offset:1)
        precondition(excerpt.utf16.count<=2000 && excerpt.contains("UTF-16 offset 2"))
        precondition(AskConversationProjection.excerpt(unicode,offset:unicode.utf16.count)=="End of retained message.")
        precondition(!AskConversationProjection.excerpt(unicode,canPage:false).contains("textOffset"))
        let giant="e"+String(repeating:"\u{301}",count:3500)+"🍜tail"
        var offset=0,recovered="",pages=0
        repeat {
            let page=AskConversationProjection.retainedExcerpt(giant,offset:offset)
            precondition(page.text.utf16.count<=2000)
            recovered+=page.text.components(separatedBy:"\n[Retained message excerpt")[0]
            pages+=1
            if let next=page.nextOffset {precondition(next>offset && page.text.contains("More remains"));offset=next}
            else {precondition(page.text.contains("End of retained message"));break}
        }while pages<10
        precondition(recovered==giant && pages==3,"Retained Unicode history must make progress without dropping a scalar or misreporting completion")
        print(tail ? "PASS full retained answer tail is retrieved on demand after Session/archive restart, initial excerpt is explicit, and revoked context is withheld" : "PASS record removal and access revocation redact only dependent new history fragments while preserving independent preferences and still-permitted notes through Session/archive/read_conversation")
    }
}
