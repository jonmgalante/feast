import Foundation
import CryptoKit

enum AskNativeResearchTests {
    @MainActor static func run()throws {
        let url="https://example.org/announcement",text="An opening was announced; current operation remains uncertain."
        let sourceID=SHA256.hash(data:Data(url.utf8)).map {String(format:"%02x",$0)}.joined()
        let source=AskNativeEvidence.Source(id:sourceID,url:url,title:"Announcement",roles:["consulted","cited"])
        let annotation=AskNativeEvidence.Annotation(sourceURL:url,title:"Announcement",start:0,end:2,indexUnit:"provider_unmapped")
        let block=AskNativeEvidence.Block(id:"message:0",text:text,phase:"final_answer",observedAt:"2026-11-02T22:00:00.000Z",annotations:[annotation,annotation])
        let action=AskNativeEvidence.Action(id:"web1",type:"search",observedAt:"2026-11-02T22:00:00.000Z",query:"Public cafe announcement")
        let evidence=try AskNativeEvidence(version:1,blocks:[block],sources:[source],actions:[action]).checked()
        precondition(evidence.containsQuotedBlockWithSource(quote:"current operation remains uncertain",url:url))
        precondition(!evidence.containsQuotedBlockWithSource(quote:"is open now",url:url))
        precondition(!evidence.containsQuotedBlockWithSource(quote:"opening",url:"https://different.org/"))
        let id=UUID(),research=AskRetainedResearch(id:id,originatingTurn:UUID(),query:"Public query",result:.init(text:text,citations:[.init(title:"Announcement",url:url)],nativeEvidence:evidence))
        var response=AskResponse(summary:"Research",candidates:[],paragraphs:[.init(id:"answer",spans:[.text(text)],sourceIDs:[],citations:[.init(title:"Announcement",url:url)])],listedCandidateIDs:[],usesLocalCatalog:true)
        response.publicResearch=[research]
        let roundtrip=try JSONDecoder().decode(AskResponse.self,from:JSONEncoder().encode(response))
        precondition(roundtrip.publicResearch?.first?.result.nativeEvidence==evidence)
        let legacy=try JSONDecoder().decode(AskWebResearchResult.self,from:Data("{\"text\":\"Earlier public answer\",\"citations\":[]}".utf8));precondition(legacy.nativeEvidence==nil)
        var object=try JSONSerialization.jsonObject(with:JSONEncoder().encode(evidence)) as! [String:Any]
        object["blocks"]=[["id":"bad","text":"x","phase":"final_answer","observedAt":"not a date","annotations":[]]]
        do {_ = try JSONDecoder().decode(AskNativeEvidence.self,from:JSONSerialization.data(withJSONObject:object)).checked();preconditionFailure()}catch {}
        precondition(!evidence.containsQuotedBlockWithSource(quote:"",url:url))
        for badRoles in [["verified"],["private"]] {
            var malformed=try JSONSerialization.jsonObject(with:JSONEncoder().encode(evidence)) as! [String:Any]
            malformed["sources"]=[["id":sourceID,"url":url,"title":"Announcement","roles":badRoles]]
            do {_ = try JSONDecoder().decode(AskNativeEvidence.self,from:JSONSerialization.data(withJSONObject:malformed)).checked();preconditionFailure()}catch {}
        }
        var duplicate=try JSONSerialization.jsonObject(with:JSONEncoder().encode(evidence)) as! [String:Any]
        let sourceObjects=duplicate["sources"] as! [[String:Any]];duplicate["sources"]=sourceObjects+sourceObjects
        do {_ = try JSONDecoder().decode(AskNativeEvidence.self,from:JSONSerialization.data(withJSONObject:duplicate)).checked();preconditionFailure()}catch {}
        let encoded=try JSONEncoder().encode(evidence);precondition(!String(data:encoded,encoding:.utf8)!.contains("encrypted_content"))
        var compact=evidence
        let extras=(1..<80).map {i -> AskNativeEvidence.Source in
            let u="https://example.org/consulted-"+String(i)
            return .init(id:SHA256.hash(data:Data(u.utf8)).map {String(format:"%02x",$0)}.joined(),url:u,title:"Consulted source",roles:["consulted"])
        }
        let essential=AskNativeEvidence.Source(id:sourceID,url:url,title:"Announcement",roles:["consulted","cited","provider_opened"])
        let opened=AskNativeEvidence.Action(id:"opened",type:"open_page",observedAt:"2026-11-02T22:00:00Z",url:url)
        compact = try AskNativeEvidence(version:1,blocks:[block],sources:[essential]+extras,actions:[action,opened],inventory:.init(totalUniqueSources:83,omittedConsultedSources:3,complete:false)).checked()
        precondition(compact.containsQuotedBlockWithSource(quote:"current operation remains uncertain",url:url))
        let legacyData=try JSONEncoder().encode(evidence)
        let decodedLegacy=try JSONDecoder().decode(AskNativeEvidence.self,from:legacyData).checked()
        precondition(decodedLegacy.inventory==nil)
        var raw=try JSONSerialization.jsonObject(with:JSONEncoder().encode(compact)) as! [String:Any]
        for bad in [["totalUniqueSources":79,"omittedConsultedSources":0,"complete":true],["totalUniqueSources":83,"omittedConsultedSources":2,"complete":false],["totalUniqueSources":83,"omittedConsultedSources":3,"complete":true]] as [[String:Any]] {
            raw["inventory"]=bad
            do {_ = try JSONDecoder().decode(AskNativeEvidence.self,from:JSONSerialization.data(withJSONObject:raw)).checked();preconditionFailure()}catch {}
        }
        let noOpened=AskNativeEvidence(version:1,blocks:[block],sources:[source]+extras,actions:[opened])
        do {_ = try noOpened.checked();preconditionFailure()}catch {}
        let directory=FileManager.default.temporaryDirectory.appendingPathComponent("feast-evidence-history-"+UUID().uuidString)
        try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:true)
        defer {try? FileManager.default.removeItem(at:directory)}
        let store=AskConversationStore(url:directory.appendingPathComponent("chats.json"))
        var saved=AskResponse(summary:"A public answer with honest uncertainty.",candidates:[],listedCandidateIDs:[],usesLocalCatalog:true)
        saved.publicResearch=[.init(id:id,originatingTurn:id,query:"Public research",result:.init(text:text,citations:[.init(title:"Announcement",url:url)],nativeEvidence:compact))]
        let turn=AskTurn(id:id,request:.init(mode:.collection,text:"A public question",fromOCR:false),response:saved,sources:[],status:.complete)
        var library=AskChatLibrary.empty();library.chats[0].conversation.turns=[AskArchivedTurn(turn)]
        precondition(store.saveLibrary(library))
        let restoredHistory=try AskConversationStore(url:directory.appendingPathComponent("chats.json")).loadLibrary()
        precondition(restoredHistory.chats[0].conversation.turns[0].id==id)
        let restoredEvidence=restoredHistory.chats[0].conversation.turns[0].response.publicResearch![0].result.nativeEvidence!
        precondition(restoredEvidence==compact && restoredEvidence.inventory?.complete==false && restoredEvidence.inventory?.omittedConsultedSources==3)
        precondition(AskConversationFailure(status:503,code:"native_required_sources_limit").localizedDescription.contains("supporting sources"))
        precondition(!AskConversationFailure(status:503,code:"native_required_sources_limit").localizedDescription.contains("billing"))
        print("PASS evidence projection retains essential attribution, accurate omission counts, old-history compatibility and real-file restoration")
        print("PASS native public evidence retains original citation blocks, uncertainty and observations; legacy persistence needs no migration")
    }
}

private actor NativeLoopFixture:AskConversationPlanning {
    var steps:[AskConversationStep]=[]
    let evidence:AskNativeEvidence
    init(_ evidence:AskNativeEvidence){self.evidence=evidence}
    func conversationAvailable()async->Bool {true}
    func nativeResearchAvailable()async->Bool {true}
    func conversationStep(_ p:AskConversationStep)async throws->AskConversationReply {
        steps.append(p)
        let call=p.step==0 ? AskAgentReply.Call(name:"query_collection",callID:"read",arguments:"{}") : nil
        return .init(version:10,requestID:p.requestID,step:p.step,kind:call == nil ? "answer" : "tool",text:call == nil ? "A concise sourced answer." : "",continuation:"opaque",model:"gpt-6.1-sol",call:call,nativeEvidence:evidence,finalCitations:call == nil ? [.init(title:"Announcement",url:evidence.sources[0].url)] : [])
    }
    func searchConversationWeb(_ query:String)async throws->AskWebResearchResult {preconditionFailure("Native path restarted staged search")}
    func authorizePendingConfirmation(_ actions:[AskCollectionAction],question:String,history:[String])async throws->AskHumanAuthorization {preconditionFailure()}
    func authorizeConversationChange(_ proposal:AskChangeProposal,question:String,history:[String],targets:[AskAgentRecord])async throws->AskHumanAuthorization {preconditionFailure()}
    func captured()->[AskConversationStep] {steps}
}
extension AskNativeResearchTests {
    static func runLoop()async throws {
        let url="https://example.org/announcement",sourceID=SHA256.hash(data:Data(url.utf8)).map {String(format:"%02x",$0)}.joined()
        let evidence=AskNativeEvidence(version:1,blocks:[.init(id:"m:0",text:"The announced date remains uncertain.",phase:"commentary",observedAt:"2026-11-02T22:00:00Z",annotations:[.init(sourceURL:url,title:"Announcement",start:0,end:3,indexUnit:"provider_unmapped")])],sources:[.init(id:sourceID,url:url,title:"Announcement",roles:["cited"])],actions:[.init(id:"w",type:"search",observedAt:"2026-11-02T22:00:00Z",query:"A public announcement")])
        let planner=NativeLoopFixture(evidence),turn=UUID()
        let request=AskRequest(mode:.collection,text:"Compare the public announcement with my collection; private sentinel DO_NOT_REPLAY",fromOCR:false,performanceID:turn)
        let output=try await AskConversationLoop(planner:planner,availableCandidates:[:],execute:{_ in .init(output:.init(status:"local_only",complete:true,totalCount:0,records:[],findings:[],message:"private_result",localOnly:true),response:nil,orderedIDs:[],selectionIsPrivate:true)}).answer(request,context:.init(index:[],recent:[]),cities:[],findings:[])
        precondition(!(output.publicResearch?.first?.query.contains("DO_NOT_REPLAY") ?? true))
        let restored=try JSONDecoder().decode(AskResponse.self,from:JSONEncoder().encode(output))
        precondition(!(restored.publicResearch?.first?.projection.contains("DO_NOT_REPLAY") ?? true))
        let steps=await planner.captured()
        precondition(steps.count==2 && steps.allSatisfy {$0.version==10 && $0.turnID==turn.uuidString})
        let retryPlanner=NativeLoopFixture(evidence),retryAttempts=AskProviderAttempts()
        let oldLease=try await retryAttempts.begin(turn:turn,retrying:false,legacySettled:false){_ in}
        try await retryAttempts.register(oldLease.attempt,lease:oldLease)
        await retryAttempts.finish(oldLease)
        let retryLease=try await retryAttempts.begin(turn:turn,retrying:true,legacySettled:false,restart:{_,_ in}){_ in preconditionFailure()}
        let successor=retryLease.attempt
        _ = try await AskProviderAttemptScope.$store.withValue(retryAttempts) {
            try await AskProviderAttemptScope.$lease.withValue(retryLease) {
                try await AskConversationLoop(planner:retryPlanner,availableCandidates:[:],execute:{_ in .init(output:.init(status:"local_only",complete:true,totalCount:0,records:[],findings:[],message:"empty",localOnly:true),response:nil,orderedIDs:[],selectionIsPrivate:true)}).answer(request,context:.init(index:[],recent:[]),cities:[],findings:[])
            }
        }
        let retrySteps=await retryPlanner.captured()
        precondition(retrySteps.count==2 && retrySteps.allSatisfy {$0.requestID==successor.uuidString && $0.turnID==successor.uuidString})
        precondition(request.performanceID==turn)
        print("PASS explicit retry uses its authorized accounting generation while preserving the original visual turn")
        precondition(steps[0].webAllowed==true && steps[1].webAllowed==false)
        precondition(output.publicResearch?.count==1 && output.publicResearch?.first?.result.nativeEvidence==evidence)
        precondition(output.paragraphs.first?.citations.first?.url==url && output.paragraphs.first?.citationsAreResearchPool==false)
        precondition(output.publicConversationText==nil)
        let encoded=try JSONEncoder().encode(steps[0]);let wire=try JSONSerialization.jsonObject(with:encoded) as! [String:Any]
        precondition(wire["version"] as? Int==10 && wire["turnID"] as? String==turn.uuidString)
        var legacy=steps[0];legacy.version=9;legacy.webAllowed=nil;legacy.turnID=nil
        let old=try JSONSerialization.jsonObject(with:JSONEncoder().encode(legacy)) as! [String:Any]
        precondition(old["webAllowed"]==nil && old["turnID"]==nil)
        print("PASS native client loop keeps public evidence, uses final citations, latches private phase and avoids staged search; provider mocked")
    }
}
