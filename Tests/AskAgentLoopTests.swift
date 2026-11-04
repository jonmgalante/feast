import Foundation
private actor AgentPlanFixture:AskAgentPlanning {
    var calls:[AskAgentReply.Call]
    var steps:[AskAgentStep]=[]
    init(_ calls:[AskAgentReply.Call]){self.calls=calls}
    func agentStep(_ step:AskAgentStep)async throws->AskAgentReply {
        steps.append(step);guard !calls.isEmpty else {throw AskError.invalidEvidence}
        let call=calls.removeFirst()
        return .init(version:8,requestID:step.requestID,step:step.step,call:call,continuation:"fixture",model:"gpt-6-astra")
    }
    func count()->Int {steps.count}
}
@MainActor enum AskAgentLoopTests {
    static func run() async throws {
        let ids=(1...3).map {String(format:"00000000-0000-4000-8000-%012d",$0)}
        let context=AskSemanticContext(index:ids.enumerated().map {.init(id:$0.element,name:"Public business \($0.offset)",city:"Chicago",cuisines:[])},recent:[])
        func call(_ name:String,_ value:[String:Any])->AskAgentReply.Call {.init(name:name,callID:UUID().uuidString,arguments:String(data:try! JSONSerialization.data(withJSONObject:value),encoding:.utf8)!)}
        let intent=call("interpret_request",["goal":"research","sourcePolicy":"public_if_missing","fields":["instagram"],"selectionIDs":ids,"permissions":[]])
        let research=call("research_businesses",["targetIDs":ids,"fields":["instagram"],"sourcePolicy":"public_if_missing"])
        let finish=call("finish_response",["message":"Here are their profiles.","recordIDs":ids,"findingIDs":[]])
        let planner=AgentPlanFixture([intent,research,finish])
        let response=try await AskAgentLoop(planner:planner,execute:{ call,interpretation in
            precondition(call.name=="research_businesses" && interpretation.permissions.isEmpty)
            return .init(output:.init(status:"success",complete:true,totalCount:3,records:[],findings:[],message:"ok",localOnly:false),response:.init(summary:"Three exact results",candidates:[],listedCandidateIDs:[],usesLocalCatalog:true),orderedIDs:ids)
        }).answer(.init(mode:.collection,text:"Find their Instagrams",fromOCR:false),context:context,cities:[],findings:[])
        precondition(response.agentTask?.orderedIDs==ids && response.agentTask?.action=="research")
        let count=await planner.count();precondition(count==3)
        let fact=AskVerifiedFinding(id:UUID(),recordID:ids[0],identity:.init(name:"Public business 0",city:"Chicago",website:nil,applePlaceID:nil),field:"instagram",value:"https://www.instagram.com/public_business/",evidenceURL:"https://example.org/official",verification:"cited_search",originatingTurn:UUID())
        let retainedPlanner=AgentPlanFixture([intent,call("query_collection",[:]),call("finish_response",["message":"The save was undone. The previously found account is @public_business.","recordIDs":[ids[0]],"findingIDs":[fact.id.uuidString]])])
        var retainedRequest=AskRequest(mode:.collection,text:"What about that business?",fromOCR:false);retainedRequest.verifiedFindings=[fact]
        let retainedIndex=AskLocalIndex(records:[.init(id:ids[0],cityID:"visible-city",city:"Chicago",name:"Public business 0",neighborhood:"",cuisine:"",status:"",notes:[])],visibleCityIDs:["visible-city"],visibleNoteIDs:[],scope:.savedMetadata,personalPlaces:[.init(id:ids[0],name:"Public business 0",status:nil,type:nil,cuisines:[],city:"Chicago",neighborhood:"")])
        let retainedTools=try AskReadTools(request:retainedRequest,index:retainedIndex),retainedCandidate=retainedTools.localCandidate(ids[0])!
        let retainedResponse=try await AskAgentLoop(planner:retainedPlanner,execute:{_,_ in .init(output:.init(status:"success",complete:true,totalCount:1,records:[],findings:[],message:"ok",localOnly:false),response:.init(summary:"1 saved place",candidates:[retainedCandidate],paragraphs:[.init(id:"stored",spans:[.text("Instagram isn’t saved.")],sourceIDs:[])],listedCandidateIDs:[],usesLocalCatalog:true),orderedIDs:[ids[0]])}).answer(retainedRequest,context:context,cities:[],findings:[.init(id:fact.id.uuidString,recordID:fact.recordID,field:fact.field,value:fact.value,sourceURL:fact.evidenceURL)])
        _ = try retainedTools.checked(retainedResponse)
        precondition(retainedResponse.fieldActions?.first?.finding==fact)
        precondition(retainedResponse.verifiedPublicFindings==[fact] && retainedResponse.paragraphs.first?.citations.first?.url==fact.evidenceURL)
        let forged=AgentPlanFixture([intent,research,call("finish_response",["message":"Invented","recordIDs":[UUID().uuidString],"findingIDs":[]])])
        do {_ = try await AskAgentLoop(planner:forged,execute:{_,_ in .init(output:.init(status:"success",complete:true,totalCount:3,records:[],findings:[],message:"ok",localOnly:false),response:nil,orderedIDs:ids)}).answer(.init(mode:.collection,text:"Find their Instagrams",fromOCR:false),context:context,cities:[],findings:[]);preconditionFailure("Invented identity accepted")}catch {}
        let privatePlanner=AgentPlanFixture([call("interpret_request",["goal":"query","sourcePolicy":"local_only","fields":["status"],"selectionIDs":ids,"permissions":[]]),call("query_collection",[:])])
        let privateResponse=try await AskAgentLoop(planner:privatePlanner,execute:{_,_ in .init(output:.localPrivate(),response:.init(summary:"Locally recorded status",candidates:[],listedCandidateIDs:[],usesLocalCatalog:true),orderedIDs:ids)}).answer(.init(mode:.collection,text:"Which have I visited?",fromOCR:false),context:context,cities:[],findings:[])
        let privateCount=await privatePlanner.count();precondition(privateCount==2 && privateResponse.summary=="Locally recorded status" && privateResponse.agentTask?.sourcePolicy=="local_only")
        let partialPlanner=AgentPlanFixture([intent,research,research])
        actor Counter {var value=0;func next()->Int {value+=1;return value}}
        let counter=Counter()
        let partial=try await AskAgentLoop(planner:partialPlanner,execute:{_,_ in
            let n=await counter.next()
            return .init(output:.init(status:n==1 ? "success" : "budget_stopped",complete:n==1,totalCount:3,records:[],findings:[],message:n==1 ? "ok" : "budget_limit",localOnly:false),response:.init(summary:n==1 ? "Verified first result" : "Remaining research stopped",candidates:[],paragraphs:[.init(id:"same-tool-id",spans:[.text(n==1 ? "Verified first result" : "Remaining research stopped")],sourceIDs:[])],listedCandidateIDs:[],usesLocalCatalog:true),orderedIDs:ids,appendPreviousResults:true)
        }).answer(.init(mode:.collection,text:"Find their Instagrams",fromOCR:false),context:context,cities:[],findings:[])
        precondition(partial.paragraphs.count==2 && partial.agentTask?.orderedIDs==ids && Set(partial.paragraphs.map(\.id)).count==2)
        print("PASS model-led loop uses the same ordered selection for one/many, preserves accepted task, refuses invented final IDs and finishes private local results without uploading private tool data; mocked model contract only")
    }
}
