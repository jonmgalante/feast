import Foundation
import CoreData

/// Captures the actual HostedProvider JSON, including durable command envelopes.
/// Every reply and Maps match is synthetic; this transport never opens a socket.
private actor RetainedChannelWire {
    let native:Bool
    let retry:Bool
    let longAnswer:Bool
    var loseFirst:Bool
    var pendingPages:[(Int,Int)]=[]
    var requestedOffset=0
    let revoke:(@MainActor @Sendable ()throws->Void)?
    let sideTool:String?
    var sideRequests=0
    var captures:[Data]=[]
    var steps:[AskConversationStep]=[]
    var accepted:[String:AskConversationStep]=[:]
    var retrieved=""
    init(native:Bool=true,retry:Bool=false,longAnswer:Bool=false,loseFirst:Bool=false,revoke:(@MainActor @Sendable ()throws->Void)?=nil,sideTool:String?=nil) {self.native=native;self.retry=retry;self.longAnswer=longAnswer;self.loseFirst=loseFirst;self.revoke=revoke;self.sideTool=sideTool}
    func values()->([Data],[AskConversationStep],String) {(captures,steps,retrieved)}
    func sideDispatches()->Int {sideRequests}
    func send(_ request:URLRequest)async throws->(Data,HTTPURLResponse) {
        let object=try JSONSerialization.jsonObject(with:request.httpBody!) as! [String:Any]
        func reply(_ data:Data)->(Data,HTTPURLResponse) {(data,HTTPURLResponse(url:request.url!,statusCode:200,httpVersion:nil,headerFields:["Content-Type":"application/json"])!)}
        if object["mode"] as? String == "retryFence" {return reply(try JSONSerialization.data(withJSONObject:["version":9,"state":"fenced","roots":object["roots"]!]))}
        if ["authorizeChange","webSearch"].contains(object["mode"] as? String ?? "") {sideRequests+=1;throw URLError(.notConnectedToInternet)}
        let durable=object["op"] != nil,op=object["op"] as? String
        let step:AskConversationStep
        if durable,op != "submit" {step=accepted[(object["requestID"] as! String)+":"+String(object["step"] as! Int)]!}
        else {
            let data=durable ? try JSONSerialization.data(withJSONObject:object["request"]!) : request.httpBody!
            step=try JSONDecoder().decode(AskConversationStep.self,from:data)
            captures.append(request.httpBody!);steps.append(step);accepted[step.requestID+":"+String(step.step)]=step
            if loseFirst {loseFirst=false;throw URLError(.networkConnectionLost)}
        }
        if op=="ack" {return reply(try JSONSerialization.data(withJSONObject:["version":1,"requestID":step.requestID,"step":step.step,"state":"acknowledged","retryAfterMs":100,"result":NSNull()]))}
        let initial=step.text=="Find public alternatives" && !retry
        var call:AskAgentReply.Call?
        if initial,step.step==0 {call = .init(name:"search_maps",callID:"maps",arguments:"{\"query\":\"DEPENDENT_MAP_QUERY\",\"cityID\":null}")}
        else if !initial && !retry {
            if step.step==0 {try await revoke?()}
            let earlier=step.result?.output.history ?? []
            retrieved+=earlier.map(\.text).joined(separator:"\n")
            for (index,message) in earlier.enumerated() {
                if native,let match=message.text.range(of:#"textOffset (\d+)"#,options:.regularExpression),let next=Int(message.text[match].split(separator:" ").last!) {pendingPages.append((requestedOffset+index,next))}
            }
            if step.step==0,let sideTool {
                if sideTool=="search_maps" {call = .init(name:sideTool,callID:"revoked-side-map",arguments:"{\"query\":\"DEPENDENT_MAP_QUERY\",\"cityID\":null}")}
                else {call = .init(name:"propose_changes",callID:"revoked-side-authorization",arguments:"{\"entity\":\"city\",\"operation\":\"create\",\"targetIDs\":[],\"changes\":[{\"field\":\"name\",\"value\":\"Independent Destination\",\"source\":\"user\"}],\"instructionQuote\":\"Create a city named Independent Destination\"}")}
            }else if step.step==0 {
                requestedOffset=max(0,step.historyCount-12)
                call = .init(name:"read_conversation",callID:"history-0",arguments:"{\"offset\":\(requestedOffset),\"limit\":12}")
            }else if !pendingPages.isEmpty {
                let next=pendingPages.removeFirst();requestedOffset=next.0
                call = .init(name:"read_conversation",callID:"history-\(step.step)",arguments:"{\"offset\":\(next.0),\"limit\":1,\"textOffset\":\(next.1)}")
            }
        }
        let evidence:AskNativeEvidence = initial && step.step==0 ? .init(version:1,blocks:[.init(id:"research",text:"DEPENDENT_PUBLIC_RESEARCH "+String(repeating:"Public detail. ",count:100),phase:"commentary",observedAt:"2026-11-11T12:00:00Z",annotations:[])],sources:[],actions:[.init(id:"search",type:"search",observedAt:"2026-11-11T12:00:00Z",query:"DEPENDENT_RESEARCH_QUERY")]) : .init(version:1,blocks:[],sources:[],actions:[])
        let value=AskConversationReply(version:step.version,requestID:step.requestID,step:step.step,kind:call==nil ? "answer" : "tool",text:call==nil ? (initial ? (longAnswer ? String(repeating:"a",count:1600)+" OLD_PREFIX_POINT "+String(repeating:"More explanation. ",count:120)+" ORIGINAL_ANSWER_TAIL" : "") : "I checked the retained context.") : "",continuation:"offline-only",model:"gpt-6.1-sol",call:call,nativeEvidence:native ? evidence : nil,finalCitations:native ? [] : nil)
        let encoded=try JSONEncoder().encode(value)
        if !durable {return reply(encoded)}
        return reply(try JSONSerialization.data(withJSONObject:["version":1,"requestID":step.requestID,"step":step.step,"state":op=="ack" ? "acknowledged" : "completed","retryAfterMs":100,"result":op=="ack" ? NSNull() : JSONSerialization.jsonObject(with:encoded)]))
    }
}
@MainActor private final class RetainedChannelToken {
    var calls=0
    let revoke:(@MainActor @Sendable ()throws->Void)?
    init(revoke:(@MainActor @Sendable ()throws->Void)?=nil) {self.revoke=revoke}
    func value()throws->String {
        calls+=1
        if calls==2 {try revoke?()}
        return String(repeating:"C",count:43)
    }
}
@MainActor enum AskRetainedChannelTests {
    static func run(model:NSManagedObjectModel,directory:URL,kind:String)async throws {
        let folder=directory.appendingPathComponent("retained-channels-"+kind);try FileManager.default.createDirectory(at:folder,withIntermediateDirectories:true)
        let coordinator=NSPersistentStoreCoordinator(managedObjectModel:model)
        _ = try coordinator.addPersistentStore(ofType:NSSQLiteStoreType,configurationName:nil,at:folder.appendingPathComponent("collection.sqlite"))
        let context=NSManagedObjectContext(concurrencyType:.mainQueueConcurrencyType);context.persistentStoreCoordinator=coordinator
        let repo=FeastRepository(context:context),city=try repo.createFeastList(named:"Channel City")
        let origin=try repo.createSavedPlace(from:.init(applePlaceID:"origin",displayNameSnapshot:"ZZZ Origin",status:.wantToTry,placeType:.cafe,cuisines:[],tags:[],note:"ORIGIN_PRIVATE_NOTE",websiteURL:nil,instagramURL:nil,feastList:city,listSection:nil))
        origin.id=UUID(uuidString:"FFFFFFFF-FFFF-4FFF-BFFF-FFFFFFFFFFFF")!;try context.save()
        let originID=origin.id!.uuidString
        let adapter=AskSavedCollection(context:context,canMutate:{_,_,_ in true},canRecoverStore:{_ in true},visibleCities:{[city.id!]})
        let engine=AskCollectionChangeEngine(adapter:adapter,journalURL:folder.appendingPathComponent("actions.json"))
        let attemptsURL=folder.appendingPathComponent("attempts"),attempts=AskProviderAttempts(url:attemptsURL,requirePersistence:true)
        let store=AskConversationStore(url:folder.appendingPathComponent("history.json"))
        let native = !kind.hasPrefix("contract-v9"),durable=kind.hasPrefix("contract-durable")
        let checkpoints=durable ? AskTurnRecoveryStore(directory:folder.appendingPathComponent("checkpoints"),requirePersistence:true) : nil
        var mapsRequests=0
        func provider(_ wire:RetainedChannelWire,deleteDuringMaps:Bool=false,revokeAtAuthorizationToken:Bool=false)->AskAgentProvider {
            let revoke:(@MainActor @Sendable ()throws->Void)?
            if revokeAtAuthorizationToken {revoke={try repo.delete(origin)}}else{revoke=nil}
            let token=RetainedChannelToken(revoke:revoke)
            let hosted=AskHostedProvider(configuration:.init(environment:.development,endpoint:URL(string:"https://channel-fixture.workers.dev/v1/answer")!,scope:.savedMetadata),token:{try await token.value()},approve:{_,_ in true},send:{try await wire.send($0)},libraryToolsEnabled:{true},permission:{true},libraryPlanVersion:{7},nativeResearchEnabled:{native},retainedHistoryEnabled:{native},recoveryEnabled:{durable},recoveryRetainedHistoryEnabled:{durable})
            return AskAgentProvider(remote:hosted,fallback:hosted,adapter:adapter,engine:engine,searchMaps:{_ in
                mapsRequests+=1
                if deleteDuringMaps {try repo.delete(origin)}
                let expanded=kind=="contract-v9-capacity"
                let suffix=expanded ? String(repeating:"x",count:130) : ""
                let address=String(repeating:"Address ",count:expanded ? 60 : 30)
                let cityName=expanded ? String(repeating:"C",count:180) : "Public City"
                return (0..<6).map {ApplePlaceMatch(applePlaceID:"channel-map-\($0)",displayName:"DEPENDENT_MAP_\($0)"+suffix,secondaryText:address,coordinate:nil,suggestedSectionPath:.init(cityOrRegion:cityName,neighborhood:nil),websiteURL:nil,instagramURL:nil)}
            },recoveryStore:checkpoints)
        }
        let firstWire=RetainedChannelWire(native:native,longAnswer:kind.hasSuffix("long") || kind.hasSuffix("capacity"))
        let first=AskSession(index:try adapter.index(),provider:provider(firstWire,deleteDuringMaps:kind.hasPrefix("retry")),providerAttempts:attempts)
        first.restoreHistory(from:store);first.refreshIndex={try adapter.index()}
        first.input="Find public alternatives";first.run();while first.isLoading {await Task.yield()};first.flushHistory()
        if kind.hasPrefix("retry") {
            guard case .failed=first.turns.last?.status else{preconditionFailure("Expected the access fence to stop the first attempt after its read checkpoint")}
            let turn=first.turns.last!.id
            let stored=try JSONDecoder().decode(AskProviderAttempts.Entry.self,from:Data(contentsOf:attemptsURL.appendingPathComponent(turn.uuidString+".json")))
            precondition(stored.checkpoint?.mapChoices?.isEmpty==false && stored.checkpoint?.publicResearch?.isEmpty==false)
            precondition(stored.checkpoint?.agentTask?.orderedIDs.isEmpty==true,"The retry must not accidentally inherit origin proof from task membership")
            if kind=="retry-legacy" {
                var legacy=stored;legacy.checkpoint?.historyRecordIDs=nil;legacy.checkpoint?.retainsIndependentQuestion=nil
                try JSONEncoder().encode(legacy).write(to:attemptsURL.appendingPathComponent(turn.uuidString+".json"),options:.atomic)
            }
            let retryWire=RetainedChannelWire(retry:true),reloaded=AskProviderAttempts(url:attemptsURL,requirePersistence:true)
            let resumed=AskSession(index:try adapter.index(),provider:provider(retryWire),providerAttempts:reloaded);resumed.restoreHistory(from:store);resumed.refreshIndex={try adapter.index()};resumed.retry(turn)
            while resumed.isLoading {await Task.yield()}
            let values=await retryWire.values(),sent=values.0.map {String(decoding:$0,as:UTF8.self)}.joined()
            precondition(!values.1.isEmpty && !sent.contains("DEPENDENT_"),"A reloaded retry checkpoint leaked research/Maps data after its prompt source was removed")
            precondition(stored.checkpoint?.historyRecordIDs?.contains(originID)==true,"Completed read checkpoints must preserve their conservative originating dependency")
            let retained=try String(contentsOf:attemptsURL.appendingPathComponent(turn.uuidString+".json"),encoding:.utf8)
            precondition(retained.contains("DEPENDENT_"),"Outbound redaction must not erase the recoverable local read checkpoint")
            print("PASS actual Session/Loop read checkpoint reload/retry with missing origin does not transmit dependent Maps/research")
            return
        }
        precondition(first.turns.last?.status == .complete && first.response?.mapChoices?.count==6)
        precondition(first.response?.historyRecordIDs?.contains(originID)==true)
        if kind.hasPrefix("live") {
            for i in 0..<400 {
                let p=SavedPlace(context:context);p.id=UUID();p.applePlaceID="other-\(i)";p.displayNameSnapshot=String(format:"AAA %04d",i);p.feastList=city;p.placeStatus = .wantToTry;p.placeTypeValue = .cafe;p.cuisines=[];p.tags=[];p.createdAt=Date();p.updatedAt=Date()
            }
            try context.save()
        }
        if kind=="contract-many" || kind=="contract-v9-capacity" {
            var library=try store.loadLibrary();let source=library.chats[0].conversation.turns[0].turn
            library.chats[0].conversation.turns=(0..<99).map {_ in return AskArchivedTurn(.init(id:UUID(),request:source.request,response:source.response,sources:source.sources,status:source.status))}
            precondition(store.saveLibrary(library))
        }
        var revoke:(@MainActor @Sendable ()throws->Void)?
        if kind.hasPrefix("live"),kind != "live-authorization-token" {revoke={try repo.delete(origin)}}
        let followWire=RetainedChannelWire(native:native,loseFirst:kind=="contract-durable-restart",revoke:revoke,sideTool:kind=="live-maps" ? "search_maps" : kind.hasPrefix("live-authorization") ? "propose_changes" : nil)
        var follow=AskSession(index:try adapter.index(),provider:provider(followWire,revokeAtAuthorizationToken:kind=="live-authorization-token"),providerAttempts:attempts);follow.restoreHistory(from:store);follow.refreshIndex={try adapter.index()}
        follow.input=kind.hasPrefix("live-authorization") ? "Create a city named Independent Destination" : "Review the earlier public choices";follow.run();while follow.isLoading {await Task.yield()}
        if kind=="contract-durable-restart" {
            let turn=follow.turns.last!.id,saved=try checkpoints!.checkpoint(follow.turns.last!.id)!
            precondition(saved.phase == .awaitingReply && saved.request.collectionHistory?.count==saved.pendingRequest?.historyCount,"Recovery must store the exact combined history index once")
            precondition(saved.request.publicHistory==nil && saved.userRequest?.publicHistory==nil && saved.executorRequest?.publicHistory==nil,"Normalized recovery must not duplicate the public-history projection")
            follow.flushHistory();follow.setAppActive(false)
            let reopenedStore=AskTurnRecoveryStore(directory:folder.appendingPathComponent("checkpoints"),requirePersistence:true)
            var continuing=provider(followWire);continuing.recoveryStore=reopenedStore
            let reopened=AskSession(index:try adapter.index(),provider:continuing,providerAttempts:attempts);reopened.restoreHistory(from:store);reopened.refreshIndex={try adapter.index()};reopened.restorePendingRecovery()
            for _ in 0..<100_000 {if !reopened.isLoading && reopened.turns.last?.status == .complete {break};try await Task.sleep(nanoseconds:1_000_000)}
            precondition(reopened.turns.last?.id==turn && reopened.turns.last?.status == .complete)
            follow=reopened
        }
        let values=await followWire.values()
        if kind=="contract-durable-restart" {precondition(values.1.filter {$0.step==0}.count==1,"Recovery must not submit the accepted auxiliary-history step again")}
        if kind.hasPrefix("live") {
            precondition(values.1.first?.context.index.contains {$0.id==originID}==false,"The regression needs an origin outside the bounded catalog")
            let visible=try adapter.index().historyAccessIDs
            precondition(!visible.contains(originID),"The regression must reach its actual revocation boundary")
            let sideDispatches=await followWire.sideDispatches()
            precondition(mapsRequests==1 && sideDispatches==0,"A returned tool dispatched Maps/authorization after its retained origin was revoked during conversationStep")
            precondition(values.1.count==1,"Missing retained-channel origin failed to stop the second provider step")
            print("PASS outside-catalog auxiliary origin removal stops the next real Session provider step")
            return
        }
        let file=folder.appendingPathComponent("serialized-requests.json")
        let captured=await firstWire.values()
        let bodies=try (captured.0+values.0).map {try JSONSerialization.jsonObject(with:$0)}
        try JSONSerialization.data(withJSONObject:bodies,options:[.sortedKeys]).write(to:file)
        let process=Process();process.executableURL=URL(fileURLWithPath:"/usr/bin/env");process.arguments=["node","Tests/validate-retained-channel-requests.mjs",file.path];try process.run();process.waitUntilExit()
        precondition(process.terminationStatus==0,"Actual app request JSON was rejected by the real backend validator")
        precondition(follow.turns.last?.status == .complete)
        if kind=="contract-v9-capacity" {
            precondition(values.2.contains("DEPENDENT_MAP_0") && values.2.contains("cannot retrieve further excerpts") && values.1.contains {$0.result?.output.complete==false},"A real legacy message-capacity boundary must keep useful auxiliary data and report inaccessible overflow, not false completeness")
        }else {precondition(values.2.contains("DEPENDENT_MAP_5"),"read_conversation indexes or character paging lost retained auxiliary choices")}
        if kind.hasSuffix("long") || kind.hasSuffix("capacity") {precondition(values.2.contains("OLD_PREFIX_POINT"),"Retained auxiliary chunks hid a previously readable point in the original assistant prefix")}
        if native {precondition(values.2.contains("DEPENDENT_PUBLIC_RESEARCH"));if kind.hasSuffix("long") {precondition(values.2.contains("ORIGINAL_ANSWER_TAIL"),"Auxiliary projection must preserve the original long answer for negotiated paging")}}
        precondition(values.1.allSatisfy {$0.historyCount>=($0.history.count) && $0.historyCount<=200})
        print("PASS actual app→backend \(kind) serialized history count/schema and auxiliary read_conversation index/offset contract")
    }
}
