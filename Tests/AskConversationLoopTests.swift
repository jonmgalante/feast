import Foundation
private actor DispatchedExchangeProbe {
    private var began=false,finished=false
    private var starters:[CheckedContinuation<Void,Never>]=[]
    private var completion:CheckedContinuation<Int,Never>?
    func run()async->Int {began=true;starters.forEach {$0.resume()};starters=[];let result=await withCheckedContinuation {completion=$0};finished=true;return result}
    func waitForStart()async {if began{return};await withCheckedContinuation {starters.append($0)}}
    func finish(){completion?.resume(returning:1);completion=nil}
    func didFinish()->Bool {finished}
}
private actor ConversationFixture:AskConversationPlanning {
    var replies:[AskConversationReply],steps:[AskConversationStep]=[],webQueries:[String]=[]
    let failure:AskConversationFailure?,native:Bool
    init(_ replies:[AskConversationReply],failure:AskConversationFailure?=nil,native:Bool=false){self.replies=replies;self.failure=failure;self.native=native}
    func conversationAvailable()async->Bool {true}
    func nativeResearchAvailable()async->Bool {native}
    func conversationStep(_ step:AskConversationStep)async throws->AskConversationReply {steps.append(step);guard !replies.isEmpty else{if let failure {throw failure};throw AskHostedError.service(503)};return replies.removeFirst()}
    func searchConversationWeb(_ query:String)async throws->AskWebResearchResult {webQueries.append(query);return .init(text:"Official visiting information",citations:[.init(title:"Museum",url:"https://www.metmuseum.org/visit")])}
    func authorizePendingConfirmation(_ actions:[AskCollectionAction],question:String,history:[String])async throws->AskHumanAuthorization {.init(approved:false,replaceExisting:false,deleteContents:false,reason:"no_instruction")}
    func authorizeConversationChange(_ proposal:AskChangeProposal,question:String,history:[String],targets:[AskAgentRecord])async throws->AskHumanAuthorization {.init(approved:false,replaceExisting:false,deleteContents:false,reason:"no_instruction")}
    func count()->Int {steps.count}
    func result()->AskConversationStep.Result? {steps.last?.result}
    func queryVersions()->[Int?] {steps.map(\.collectionQueryVersion)}
}
private actor ConversationCapabilities {var version=1,refreshes=0;func get()->Int {version};func refresh(){version=6;refreshes+=1};func count()->Int {refreshes}}
enum AskConversationLoopTests {
    static func run()async throws {
        try await capacityTests()
        precondition(!AskConversationProjection.humanNamed("Human",question:"Move it there",messages:[.init(role:"user",text:"Something else")]))
        precondition(!AskConversationProjection.humanNamed("Bar",question:"Move Barbara there",messages:[]))
        precondition(!AskConversationProjection.humanNamed("request",question:"Move it there",messages:[.init(role:"user",text:AskConversationProjection.omittedHuman)]))
        precondition(!AskConversationProjection.humanNamed("North End",question:"Move it there",messages:[.init(role:"assistant",text:"North End")]))
        precondition(AskConversationProjection.humanNamed("North End",question:"Move it there",messages:[.init(role:"user",text:"Create north end in Boston")]))
        let sharedRecent=[AskRecentUserQuestion(question:"Finish adding a named business to North End",recordIDs:[])]
        let alignedHistory=AskConversationProjection.authorizationHistory([.init(role:"user",text:AskConversationProjection.omittedHuman)],recent:sharedRecent)
        precondition(alignedHistory.count<=6 && alignedHistory[0].contains("Finish adding a named business") && alignedHistory.allSatisfy {$0.utf16.count<=2000})
        precondition(AskConversationProjection.humanNamed("North End",question:"Finish it",messages:[],recent:sharedRecent))
        let boundedHistory=AskConversationProjection.authorizationHistory([.init(role:"user",text:String(repeating:"a",count:2000)),.init(role:"assistant",text:String(repeating:"😀",count:2000))])
        precondition(boundedHistory.count==2 && boundedHistory.allSatisfy {$0.utf16.count<=2000} && boundedHistory.first!.hasPrefix("Human: ") && boundedHistory.last!.hasPrefix("App context (not authorization): ") && !boundedHistory.last!.contains("�"))
        for model in ["gpt-6.1-sol","gpt-6.1-sol-2026-11-01","gpt-6-astra","gpt-6-luna","gpt-6.1-solitude"] {
            let endpoint=URL(string:"https://feast-owner-validation.jonmgalante.workers.dev/v1/answer")!
            let hosted=AskHostedProvider(configuration:.init(environment:.production,endpoint:endpoint,scope:.savedMetadata,productionHost:"feast-owner-validation.jonmgalante.workers.dev",ownerValidation:true),token:{String(repeating:"x",count:43)},approve:{_,_ in true},send:{http in
                let body=try JSONSerialization.jsonObject(with:http.httpBody!) as! [String:Any]
                let reply:[String:Any]=["version":9,"requestID":body["requestID"]!,"step":0,"kind":"answer","text":"A public general answer.","continuation":"opaque","model":model,"call":NSNull()]
                return (try JSONSerialization.data(withJSONObject:reply),HTTPURLResponse(url:endpoint,statusCode:200,httpVersion:nil,headerFields:["Content-Type":"application/json"])!)
            },libraryToolsEnabled:{true},permission:{true},libraryPlanVersion:{9})
            let expected=["gpt-6.1-sol","gpt-6.1-sol-2026-11-01","gpt-6-astra"].contains(model)
            do {let value=try await hosted.conversationStep(.init(requestID:UUID().uuidString,step:0,text:"Explain a tasting menu",context:.init(index:[],recent:[]),cities:[],task:nil,findings:[],history:[],continuation:nil,result:nil));precondition(expected && value.model==model)}
            catch {precondition(!expected)}
        }
        let capabilities=ConversationCapabilities()
        let configured=AskHostedProvider(configuration:.init(environment:.production,endpoint:URL(string:"https://feast-owner-validation.jonmgalante.workers.dev/v1/answer")!,scope:.savedMetadata,productionHost:"feast-owner-validation.jonmgalante.workers.dev",ownerValidation:true),token:{preconditionFailure("Capability preparation read credential")},approve:{_,_ in false},send:{_ in preconditionFailure("Capability preparation sent AI request")},libraryToolsEnabled:{true},permission:{true},libraryPlanVersion:{await capabilities.get()},prepareCapabilities:{await capabilities.refresh()})
        let ready=await configured.agentAvailable(),refreshes=await capabilities.count();precondition(ready && refreshes==1)
        let nullTransport=AskHostedProvider(configuration:configured.configuration,token:{String(repeating:"x",count:43)},approve:{_,_ in true},send:{http in
            let body=try JSONSerialization.jsonObject(with:http.httpBody!) as! [String:Any]
            let proposal=body["proposal"] as! [String:Any],change=(proposal["changes"] as! [[String:Any]])[0]
            precondition(proposal["cityID"] is NSNull && proposal["sectionID"] is NSNull && change["value"] is NSNull && change["values"] is NSNull && change["findingID"] is NSNull && change["source"] as? String=="user")
            let response:[String:Any]=["version":9,"requestID":body["requestID"]!,"decision":["approved":true,"replaceExisting":true,"deleteContents":false,"reason":"explicit_instruction"]]
            return (try JSONSerialization.data(withJSONObject:response),HTTPURLResponse(url:configured.configuration.endpoint,statusCode:200,httpVersion:nil,headerFields:["Content-Type":"application/json"])!)
        },libraryToolsEnabled:{true},permission:{true})
        _ = try await nullTransport.authorizeConversationChange(.init(entity:"place",operation:"update",targetIDs:[],cityID:nil,sectionID:nil,mapMatchID:nil,changes:[.init(field:"note",value:nil,values:nil,findingID:nil,source:"user")],instructionQuote:"Clear that field"),question:"Clear that field",history:[],targets:[])

        let id=UUID().uuidString,root=UUID(),record=AskPersonalPlace(id:id,name:"Le Bernardin",status:nil,type:nil,cuisines:["French"],city:"New York",neighborhood:"")
        let index=AskLocalIndex(records:[.init(id:id,cityID:"city",city:"New York",name:record.name,neighborhood:"",cuisine:"French",status:"",notes:[])],visibleCityIDs:["city"],visibleNoteIDs:[],scope:.savedMetadata,personalPlaces:[record])
        let request=AskRequest(mode:.collection,text:"How does a tasting menu differ from à la carte?",fromOCR:false,performanceID:root)
        let tools=try AskReadTools(request:request,index:index),context=AskSemanticContext(index:[.init(id:id,name:record.name,city:record.city,cuisines:record.cuisines)],recent:[])
        let candidates=[id:tools.localCandidate(id)!]
        func reply(_ text:String,step:Int=0,call:AskAgentReply.Call?=nil)->AskConversationReply {.init(version:9,requestID:root.uuidString,step:step,kind:call==nil ? "answer" : "tool",text:text,continuation:"fixture",model:"gpt-6-astra",call:call)}
        let plain=ConversationFixture([reply("A tasting menu is a sequence selected by the kitchen; à la carte offers individual choices.")])
        let response=try await AskConversationLoop(planner:plain,availableCandidates:candidates,execute:{_ in preconditionFailure("Unnecessary tool")}).answer(request,context:context,cities:[],findings:[])
        _ = try tools.checked(response);precondition(response.candidates.isEmpty && response.publicConversationText != nil)
        let mapsCall=AskAgentReply.Call(name:"search_maps",callID:"maps-unavailable",arguments:"{\"query\":\"A real business\",\"cityID\":null}")
        let mapsRecovery=ConversationFixture([reply("",call:mapsCall),reply("Apple Maps could not complete the search. No place was added.",step:1)])
        let mapsAnswer=try await AskConversationLoop(planner:mapsRecovery,availableCandidates:candidates,execute:{_ in .init(output:.init(status:"unavailable",complete:false,totalCount:0,records:[],findings:[],message:"unavailable",localOnly:false),response:.init(summary:"Apple Maps couldn’t complete that search.",candidates:[],paragraphs:[.init(id:"maps-error",spans:[.text("Apple Maps couldn’t complete that search.")],sourceIDs:[])],listedCandidateIDs:[],usesLocalCatalog:true),orderedIDs:[],appendPreviousResults:true)}).answer(request,context:context,cities:[],findings:[])
        let mapsCount=await mapsRecovery.count(),mapsResult=await mapsRecovery.result()
        precondition(mapsCount==2 && mapsResult?.output.status=="unavailable" && mapsAnswer.paragraphs.contains {$0.spans.contains(.text("Apple Maps could not complete the search. No place was added."))})
        let direct=ConversationFixture([reply("Your French option is [[place:\(id.lowercased())]]. It could suit a tasting-menu evening.")])
        let linked=try await AskConversationLoop(planner:direct,availableCandidates:candidates,execute:{_ in preconditionFailure("Unnecessary tool")}).answer(request,context:context,cities:[],findings:[])
        _ = try tools.checked(linked);precondition(linked.agentTask?.orderedIDs==[id] && linked.candidates.first?.id==id)
        let search=ConversationFixture([reply("",call:.init(name:"search_web",callID:"web1",arguments:"{\"query\":\"museum visiting hours\"}")),reply("See the museum’s current visiting information.",step:1)])
        let rejectedRetention=ConversationFixture([reply("",call:.init(name:"search_web",callID:"research",arguments:"{\"query\":\"museum visiting hours\"}")),reply("",step:1,call:.init(name:"retain_findings",callID:"retain",arguments:"{}")),reply("The official visiting information is available; I have not saved a field.",step:2)])
        let continuedResearch=try await AskConversationLoop(planner:rejectedRetention,availableCandidates:candidates,execute:{_ in preconditionFailure("Rejected retention must not execute a collection action")},retainFindings:{_,_ in throw AskError.invalidEvidence}).answer(request,context:context,cities:[],findings:[])
        let rejectedResult=await rejectedRetention.result()
        precondition(rejectedResult?.callID=="retain" && rejectedResult?.output.status=="conflict" && rejectedResult?.output.complete==false && rejectedResult?.output.findings.isEmpty==true)
        precondition(continuedResearch.publicResearch?.count==1 && continuedResearch.fieldActions==nil && continuedResearch.collectionActions==nil && continuedResearch.paragraphs.first?.spans.first == .text("The official visiting information is available; I have not saved a field."))
        var privateRetentionRequest=request
        privateRetentionRequest.agentTask = .init(action:"query",fields:[],orderedIDs:[id],sourcePolicy:"public_if_missing",privateSelection:true)
        let privateRetention=ConversationFixture([reply("",call:.init(name:"retain_findings",callID:"retain-private",arguments:"{}")),reply("No field was retained.",step:1)])
        let privateRetentionResponse=try await AskConversationLoop(planner:privateRetention,availableCandidates:candidates,execute:{_ in preconditionFailure()},retainFindings:{_,_ in throw AskError.invalidEvidence}).answer(privateRetentionRequest,context:context,cities:[],findings:[])
        precondition(privateRetentionResponse.agentTask?.privateSelection==true && privateRetentionResponse.publicConversationText==nil && privateRetentionResponse.verifiedPublicFindings==nil)
        let cancelledRetention=ConversationFixture([reply("",call:.init(name:"retain_findings",callID:"cancel-retain",arguments:"{}"))])
        do {_ = try await AskConversationLoop(planner:cancelledRetention,availableCandidates:candidates,execute:{_ in preconditionFailure()},retainFindings:{_,_ in throw CancellationError()}).answer(request,context:context,cities:[],findings:[]);preconditionFailure("Retention cancellation swallowed")}catch is CancellationError {}
        let web=try await AskConversationLoop(planner:search,availableCandidates:candidates,execute:{_ in preconditionFailure("Wrong executor")}).answer(request,context:context,cities:[],findings:[])
        _ = try tools.checked(web);precondition(web.paragraphs.first?.citations.first?.url=="https://www.metmuseum.org/visit")
        let projected=await search.result();precondition(projected?.output.web?.citations.count==1)
        let privatePlanner=ConversationFixture([reply("",call:.init(name:"query_collection",callID:"read1",arguments:"{}")),reply("The requested saved details are displayed locally.",step:1)])
        let privateResponse=try await AskConversationLoop(planner:privatePlanner,availableCandidates:candidates,execute:{_ in .init(output:.localPrivate(),response:.init(summary:"Your saved note stays on this device.",candidates:[],listedCandidateIDs:[],usesLocalCatalog:true),orderedIDs:[id],selectionIsPrivate:true)}).answer(request,context:context,cities:[],findings:[])
        let count=await privatePlanner.count();precondition(count==2 && privateResponse.publicConversationText==nil)
        var privateTurn=AskTurn(id:UUID(),request:request,response:privateResponse,status:.complete)
        privateTurn.response?.publicConversationText="Never upload private-derived membership"
        let publicTurn=AskTurn(id:UUID(),request:request,response:linked,status:.complete)
        let projection=AskConversationProjection.messages([privateTurn,publicTurn]);precondition(projection.count==4 && !projection.contains(where:{$0.text.contains("Never upload")}))
        let legacy=AskTurn(id:UUID(),request:request,response:.init(summary:"Potential private legacy prose",candidates:[]),status:.complete)
        precondition(AskConversationProjection.messages([legacy]).isEmpty)
        var instructionTurn=AskTurn(id:UUID(),request:AskRequest(mode:.collection,text:"Replace the note for Le Bernardin with Dinner soon",fromOCR:false),response:privateResponse,status:.complete)
        instructionTurn.response?.publicConversationText="PRIVATE_STORED_NOTE_MUST_NOT_LEAVE"
        let preserved=AskConversationProjection.messages([instructionTurn])
        precondition(preserved.count==2 && preserved.first?.text.contains("private contents are omitted")==true && preserved.last?.text.contains("rendered locally")==true && !preserved.contains(where:{$0.text.contains("Dinner soon") || $0.text.contains("PRIVATE_STORED_NOTE")}))

        let lookupStatus=AskAnswerParagraph(id:"attempt",spans:[.text("Earlier lookup did not verify hours")],sourceIDs:[],transientToolStatus:true)
        let verifiedCard=AskAnswerParagraph(id:"found",spans:[.text("Verified website")],sourceIDs:[],representedField:"website")
        let intermediate=AskResponse(summary:"Partial lookup",candidates:[],paragraphs:[lookupStatus,verifiedCard],listedCandidateIDs:[],usesLocalCatalog:true)
        let recoveryPlanner=ConversationFixture([reply("",call:.init(name:"research_businesses",callID:"lookup",arguments:"{}")),reply("",step:1,call:.init(name:"search_web",callID:"web",arguments:"{\"query\":\"official hours\"}")),reply("Official hours are available at the cited source.",step:2)])
        let recoveredLookup=try await AskConversationLoop(planner:recoveryPlanner,availableCandidates:candidates,execute:{_ in .init(output:.init(status:"success",complete:true,totalCount:0,records:[],findings:[],message:"ok",localOnly:false),response:intermediate,orderedIDs:[])}).answer(request,context:context,cities:[],findings:[])
        precondition(!recoveredLookup.paragraphs.contains {$0.transientToolStatus==true})
        precondition(recoveredLookup.paragraphs.contains {$0.representedField=="website"})
        let mergedStatus=AskAgentLoop.merged(intermediate,intermediate)
        precondition(mergedStatus.paragraphs.contains {$0.transientToolStatus==true} && mergedStatus.paragraphs.contains {$0.representedField=="website"})
        let failedLookupPlanner=ConversationFixture([reply("",call:.init(name:"research_businesses",callID:"lookup",arguments:"{}"))])
        let interruptedLookup=try await AskConversationLoop(planner:failedLookupPlanner,availableCandidates:candidates,execute:{_ in .init(output:.init(status:"success",complete:true,totalCount:0,records:[],findings:[],message:"ok",localOnly:false),response:intermediate,orderedIDs:[])}).answer(request,context:context,cities:[],findings:[])
        precondition(interruptedLookup.paragraphs.contains {$0.transientToolStatus==true})
        print("PASS completed synthesis supersedes typed intermediate lookup failure while keeping verified cards; interrupted lookup retains fallback")
        let failedChangePlanner=ConversationFixture([reply("",call:.init(name:"propose_changes",callID:"failed",arguments:"{}")),reply("Saved both changes.",step:1)])
        let failedChangeResponse=try await AskConversationLoop(planner:failedChangePlanner,availableCandidates:candidates,execute:{_ in .init(output:.init(status:"conflict",complete:true,totalCount:0,records:[],findings:[],message:"target_mismatch",localOnly:true),response:.init(summary:"No change was applied.",candidates:[],paragraphs:[.init(id:"failure",spans:[.text("No change was applied.")],sourceIDs:[])],listedCandidateIDs:[],usesLocalCatalog:true),orderedIDs:[id])}).answer(request,context:context,cities:[],findings:[])
        let actualFailure=await failedChangePlanner.result()
        precondition(actualFailure?.output.status=="conflict" && actualFailure?.output.message=="target_mismatch")
        precondition(!failedChangeResponse.paragraphs.contains {$0.spans.contains(.text("Saved both changes."))})
        let failureA=AskChangeProposal(entity:"place",operation:"update",targetIDs:[id],cityID:nil,sectionID:nil,mapMatchID:nil,changes:[.init(field:"website",value:"https://example.org",values:nil,findingID:nil,source:"user")],instructionQuote:"Update both")
        var successB=failureA;successB.targetIDs=[UUID().uuidString]
        let firstCall=AskAgentReply.Call(name:"propose_changes",callID:"failure-a",arguments:String(data:try JSONEncoder().encode(failureA),encoding:.utf8)!)
        let secondCall=AskAgentReply.Call(name:"propose_changes",callID:"success-b",arguments:String(data:try JSONEncoder().encode(successB),encoding:.utf8)!)
        let mixedPlanner=ConversationFixture([reply("",call:firstCall),reply("",step:1,call:secondCall),reply("Everything saved.",step:2)])
        let mixed=try await AskConversationLoop(planner:mixedPlanner,availableCandidates:candidates,execute:{call in
            let failed=call.callID=="failure-a"
            return .init(output:.init(status:failed ? "conflict" : "applied",complete:true,totalCount:0,records:[],findings:[],message:failed ? "target_mismatch" : "changed",localOnly:false),response:.init(summary:failed ? "A failed" : "B saved",candidates:[],paragraphs:[.init(id:call.callID,spans:[.text(failed ? "A failed" : "B saved")],sourceIDs:[])],listedCandidateIDs:[],usesLocalCatalog:true),orderedIDs:[],appendPreviousResults:true)
        }).answer(request,context:context,cities:[],findings:[])
        precondition(!mixed.paragraphs.contains {$0.spans.contains(.text("Everything saved."))})
        let webThenFailure=ConversationFixture([reply("",call:.init(name:"search_web",callID:"paid-evidence",arguments:"{\"query\":\"Public Cafe official information\"}"))])
        let paidEvidence=try await AskConversationLoop(planner:webThenFailure,availableCandidates:candidates,execute:{_ in preconditionFailure("Unexpected local write")}).answer(request,context:context,cities:[],findings:[])
        precondition(paidEvidence.publicResearch?.count==1 && paidEvidence.publicResearch?.first?.result.citations.first?.url=="https://www.metmuseum.org/visit")
        let retained=AskRetainedResearch(id:UUID(),originatingTurn:UUID(),query:"Public Cafe official profile",result:.init(text:"Public Cafe uses @publiccafe.",citations:[.init(title:"Official",url:"https://example.org/cafe")]))
        var privateWithResearch=privateTurn
        privateWithResearch.response?.publicResearch=[retained]
        let archived=AskArchivedTurn(privateWithResearch)
        let roundtrip=try JSONDecoder().decode(AskArchivedTurn.self,from:JSONEncoder().encode(archived))
        precondition(roundtrip.response.publicResearch==[retained] && retained.projection.utf16.count<=2000)
        print("PASS failed local action is returned truthfully to planner and cannot render invented save success; public tool evidence survives private-result archive")
        let action=AskCollectionAction(id:UUID(),title:"Rename place",targetIDs:[id],entity:"place",operation:"update",state:.applied,undoable:true)
        let chain=ConversationFixture([reply("",call:.init(name:"propose_changes",callID:"write",arguments:"{}")),reply("",step:1,call:.init(name:"query_collection",callID:"read",arguments:"{}")),reply("Done.",step:2)])
        let actionResponse=try await AskConversationLoop(planner:chain,availableCandidates:candidates,execute:{call in
            .init(output:.init(status:call.name=="propose_changes" ? "applied" : "success",complete:true,totalCount:0,records:[],findings:[],message:call.name=="propose_changes" ? "changed" : "ok",localOnly:false),response:.init(summary:call.name,candidates:[],listedCandidateIDs:[],usesLocalCatalog:true,collectionActions:call.name=="propose_changes" ? [action] : nil),orderedIDs:[id],outcomes:call.name=="propose_changes" ? [.init(id:id,state:"applied")] : nil)
        }).answer(request,context:context,cities:[],findings:[])
        precondition(actionResponse.collectionActions==[action] && actionResponse.agentTask?.outcomes?.first?.state=="applied")
        let actionTurn=AskTurn(id:UUID(),request:request,response:actionResponse,status:.complete)
        precondition(AskConversationProjection.messages([actionTurn]).count==2)
        var oldRequest=request;oldRequest.dialogue=(0..<16).map {.init(role:$0%2==0 ? "user" : "assistant",text:"Public earlier context \($0)")}
        let oldReader=ConversationFixture([reply("",call:.init(name:"read_conversation",callID:"history",arguments:"{\"offset\":0,\"limit\":4}")),reply("Back to the earlier subject.",step:1)])
        _ = try await AskConversationLoop(planner:oldReader,availableCandidates:candidates,execute:{_ in preconditionFailure("History is not a database action")}).answer(oldRequest,context:context,cities:[],findings:[])
        let oldOutput=await oldReader.result();precondition(oldOutput?.output.history?.count==4 && oldOutput?.output.totalCount==16 && oldOutput?.output.complete==false)
        let interruptedPlanner=ConversationFixture([reply("",call:.init(name:"query_collection",callID:"read",arguments:"{}"))])
        let interrupted=try await AskConversationLoop(planner:interruptedPlanner,availableCandidates:candidates,execute:{_ in .init(output:.init(status:"success",complete:true,totalCount:1,records:[],findings:[],message:"ok",localOnly:false),response:.init(summary:"A public saved result",candidates:[],listedCandidateIDs:[],usesLocalCatalog:true),orderedIDs:[id])}).answer(request,context:context,cities:[],findings:[])
        precondition(interrupted.publicConversationText?.hasPrefix("Unfinished task.")==true && interrupted.summary=="This answer is unfinished." && interrupted.paragraphs.first?.id=="conversation-interrupted")
        let capacityPlanner=ConversationFixture([reply("",call:.init(name:"query_collection",callID:"capacity-read",arguments:"{}"))],failure:.init(status:413,code:"native_input_limit"),native:false)
        var richContext=context;richContext.collectionAccess="permitted_details_v1";richContext.totalCount=1
        let incomplete=try await AskConversationLoop(planner:capacityPlanner,availableCandidates:candidates,execute:{_ in
            .init(output:.init(status:"success",complete:true,totalCount:1,records:[],findings:[],message:"ok",localOnly:false),response:.init(summary:"Intermediate full list",candidates:[],paragraphs:[.init(id:"intermediate",spans:[.text("Intermediate full list")],sourceIDs:[])],listedCandidateIDs:[],usesLocalCatalog:true,collectionActions:[action]),orderedIDs:[id])
        },collectionQueryVersion:2,nativeResearch:true).answer(request,context:richContext,cities:[],findings:[])
        let incompleteText=incomplete.paragraphs.flatMap(\.spans).compactMap {if case .text(let text)=$0{return text};return nil}.joined(separator:" ")
        precondition(incomplete.summary=="This answer is unfinished." && incomplete.paragraphs.first?.id=="conversation-interrupted" && incomplete.paragraphs.filter {$0.id=="conversation-interrupted"}.count==1)
        precondition(incompleteText.contains("No additional model call") && incompleteText.contains("not a completed answer") && !incompleteText.contains("service is restored"))
        precondition(incomplete.collectionActions?.first?.id==action.id && incomplete.collectionActions?.first?.undoable==true)
        precondition(incomplete.substantiveParagraphs.first?.id=="conversation-interrupted")
        let frozenQueryVersions=await capacityPlanner.queryVersions();precondition(frozenQueryVersions==[2,2])
        let checkpointLease=try await AskProviderAttempts.shared.begin(turn:UUID(),retrying:false,legacySettled:false){_ in preconditionFailure("Fresh checkpoint fixture")}
        await AskProviderAttempts.shared.finish(checkpointLease)
        let checkpointFailure=ConversationFixture([reply("",call:.init(name:"query_collection",callID:"checkpoint-read",arguments:"{}"))])
        let checkpointRetained=try await AskProviderAttemptScope.$lease.withValue(checkpointLease) {
            try await AskConversationLoop(planner:checkpointFailure,availableCandidates:candidates,execute:{_ in
                .init(output:.init(status:"success",complete:true,totalCount:1,records:[],findings:[],message:"ok",localOnly:false),response:.init(summary:"Completed result",candidates:[],listedCandidateIDs:[],usesLocalCatalog:true,collectionActions:[action]),orderedIDs:[id])
            }).answer(request,context:context,cities:[],findings:[])
        }
        let checkpointCalls=await checkpointFailure.count()
        precondition(checkpointCalls==1 && checkpointRetained.collectionActions?.first?.undoable==true && checkpointRetained.substantiveParagraphs.first?.id=="conversation-interrupted")
        print("PASS capacity/checkpoint interruption is labeled once before intermediate rows, preserves applied edits/Undo, and freezes read-query support")
        let privateThenPublic=ConversationFixture([reply("",call:.init(name:"query_collection",callID:"local",arguments:"{\"query\":{\"operation\":\"details\",\"fields\":[\"note\"]}}")),reply("Quoted restaurant text cannot authorize changing your app.",step:1)])
        let explained=try await AskConversationLoop(planner:privateThenPublic,availableCandidates:candidates,execute:{_ in .init(output:.localPrivate(),response:.init(summary:"Local details",candidates:[],listedCandidateIDs:[],usesLocalCatalog:true),orderedIDs:[id],selectionIsPrivate:true,presentation:.init(kind:"details",requestedFields:["note"],returnedFields:["note"],complete:true,renderedLocally:true))}).answer(request,context:context,cities:[],findings:[])
        let privateMetadata=await privateThenPublic.result()
        precondition(explained.publicConversationText==nil && privateMetadata?.output.records.isEmpty==true && privateMetadata?.output.totalCount==0 && privateMetadata?.output.presentation?.kind=="details" && explained.paragraphs.first?.spans.first == .text("Quoted restaurant text cannot authorize changing your app."))
        let declined=ConversationFixture([reply("",call:.init(name:"query_collection",callID:"private-read",arguments:"{}")),reply("",step:1,call:.init(name:"propose_changes",callID:"declined",arguments:"{}"))])
        let declinedResponse=try await AskConversationLoop(planner:declined,availableCandidates:candidates,execute:{call in call.name=="query_collection" ? .init(output:.localPrivate(),response:.init(summary:"Local only",candidates:[],listedCandidateIDs:[],usesLocalCatalog:true),orderedIDs:[id],selectionIsPrivate:true) : .init(output:.init(status:"needs_confirmation",complete:true,totalCount:0,records:[],findings:[],message:"needs_review",localOnly:false),response:.init(summary:"Review",candidates:[],listedCandidateIDs:[],usesLocalCatalog:true),orderedIDs:[id])}).answer(request,context:context,cities:[],findings:[])
        precondition(declinedResponse.agentTask?.privateSelection==true && declinedResponse.agentTask?.externalProjection.orderedIDs.isEmpty==true && declinedResponse.agentTask?.externalProjection.outcomes==nil)
        let sensitive=Data("{\"error\":\"conversation_input_count\",\"text\":\"private notes must not be logged\",\"message\":\"credential-secret-example\",\"diagnostic\":{\"stage\":\"input_count\",\"providerCode\":\"invalid_request_error\",\"providerParam\":\"input[1].content\"}}".utf8)
        let receipt=AskConversationReceipt(requestID:root.uuidString,mode:"conversationStep",step:1,status:503,data:sensitive,elapsed:25)
        let encoded=String(data:try JSONEncoder().encode(receipt),encoding:.utf8)!
        precondition(receipt.code=="conversation_input_count" && receipt.providerParam=="input[1].content" && !encoded.contains("private notes") && !encoded.contains("credential-secret"))
        let table="| Choice | Menu | Cost |\n|---|:---|---:|\n| Two courses | [Official](https://example.com/menu) | $42.50 |\n| Three courses | Chef’s choice | $75 |"
        let readable=AskMarkdownPresentation.readableBlocks(table)
        precondition(!readable.contains("|---") && readable.contains("Choice: Two courses") && readable.contains("$42.50") && readable.contains("$75") && readable.contains("[Official](https://example.com/menu)"))
        precondition(AskMarkdownPresentation.readableBlocks("A | B\nnot a table")=="A | B\nnot a table")
        let inline=AskMarkdownPresentation.inline("Use [official details](https://www.metmuseum.org/visit), not [unsafe](file:///private).")
        precondition(inline.runs.compactMap(\.link).count==1)
        let exchangeProbe=DispatchedExchangeProbe()
        let cancelledExchange=Task {let value=try await AskHostedHTTP.settleDispatched {await exchangeProbe.run()};try Task.checkCancellation();return value}
        await exchangeProbe.waitForStart();cancelledExchange.cancel();await exchangeProbe.finish()
        do {_ = try await cancelledExchange.value;preconditionFailure("Late stopped answer was accepted")}catch is CancellationError {}
        let exchangeFinished=await exchangeProbe.didFinish();precondition(exchangeFinished)
        do {_ = try await AskProviderAttempts(requirePersistence:true).begin(turn:UUID(),retrying:false,legacySettled:false){_ in preconditionFailure("No dispatch without durable state")};preconditionFailure("Missing durable journal must stop") }catch AskRetryError.storage {}
        let attemptFile=FileManager.default.temporaryDirectory.appendingPathComponent("feast-attempt-test-"+UUID().uuidString+".json")
        defer {try? FileManager.default.removeItem(at:attemptFile)}
        let attempts=AskProviderAttempts(url:attemptFile),durableTurn=UUID()
        let first=try await attempts.begin(turn:durableTurn,retrying:false,legacySettled:false){_ in preconditionFailure("Fresh turn must not fence")}
        try await attempts.register(first.attempt,lease:first)
        try await attempts.keepReadContext(.init(summary:"Completed read",candidates:[]),lease:first)
        do {_ = try await attempts.begin(turn:durableTurn,retrying:true,legacySettled:false){_ in throw AskRetryError.active};preconditionFailure("Pending attempt must not restart")}catch AskRetryError.active {}
        do {try await attempts.register(UUID(),lease:first);preconditionFailure("Frozen task must not register a late dispatch")}catch AskRetryError.active {}
        let restarted=AskProviderAttempts(url:attemptFile)
        let second=try await restarted.begin(turn:durableTurn,retrying:true,legacySettled:false){roots in precondition(roots==[first.attempt])}
        precondition(second.turn==first.turn && second.attempt != first.attempt)
        let retainedRead=try await restarted.readContext(for:second);precondition(retainedRead?.summary=="Completed read context retained.")
        try await restarted.register(second.attempt,lease:second)
        do {try await restarted.register(UUID(),lease:first);preconditionFailure("An old task cannot dispatch after replacement")}catch AskRetryError.active {}
        do {_ = try await AskProviderAttempts().begin(turn:UUID(),retrying:true,legacySettled:false){_ in preconditionFailure("Unknown legacy outcome must not fence")};preconditionFailure("Unknown legacy retry must stop")}catch AskRetryError.unverified {}
        let legacyTurn=UUID()
        let legacyAttempt=try await AskProviderAttempts().begin(turn:legacyTurn,retrying:true,legacySettled:true){roots in precondition(roots==[legacyTurn])}
        precondition(legacyAttempt.attempt != legacyTurn)
        let evidence=String(repeating:"Public evidence. ",count:1000)
        let retainedForGrowth=(0..<4).map {_ in AskRetainedResearch(id:UUID(),originatingTurn:durableTurn,query:"Official source",result:.init(text:evidence,citations:[]))}
        let growing=AskProviderAttempts(url:attemptFile)
        for _ in 0..<20 {
            let lease=try await growing.begin(turn:UUID(),retrying:false,legacySettled:false){_ in preconditionFailure("New turn")}
            try await growing.register(lease.attempt,lease:lease)
            try await growing.keepReadContext(.init(summary:"",candidates:[],publicResearch:retainedForGrowth),lease:lease)
        }
        let files=try FileManager.default.contentsOfDirectory(at:attemptFile,includingPropertiesForKeys:[.fileSizeKey])
        let bytes=try files.reduce(0) {$0+(try $1.resourceValues(forKeys:[.fileSizeKey]).fileSize ?? 0)}
        precondition(bytes>1024*1024)
        let afterGrowth=try await AskProviderAttempts(url:attemptFile).begin(turn:durableTurn,retrying:true,legacySettled:false){roots in precondition(roots==[second.attempt])}
        precondition(afterGrowth.turn==durableTurn)
        print("PASS durable provider attempt identity/freeze/reconciliation: unknown blocks, settled retry retains context, old tasks cannot dispatch, relaunch restores state")
        print("PASS optional-tool conversation handles natural replies, direct catalog links, actual-result web continuation and private/legacy history projection; model responses mocked")
    }
    static func capacityTests()async throws {
        let endpoint=URL(string:"https://feast-owner-validation.jonmgalante.workers.dev/v1/answer")!
        let configuration=AskHostedConfiguration(environment:.production,endpoint:endpoint,scope:.savedMetadata,productionHost:endpoint.host!,ownerValidation:true)
        func nativeStep(_ text:String="Synthetic transport boundary")->AskConversationStep {
            var value=AskConversationStep(requestID:UUID().uuidString,step:0,text:text,context:.init(index:[],recent:[],collectionAccess:"permitted_details_v1",totalCount:0),cities:[],task:nil,findings:[],history:[],continuation:nil,result:nil)
            value.version=10;value.turnID=UUID().uuidString;value.webAllowed=true;value.collectionQueryVersion=2
            return value
        }
        func wireSize(_ step:AskConversationStep)throws->Int {
            var object=try JSONSerialization.jsonObject(with:JSONEncoder().encode(step)) as! [String:Any]
            for key in ["task","continuation","result"] where object[key]==nil {object[key]=NSNull()}
            return try JSONSerialization.data(withJSONObject:object,options:.sortedKeys).count
        }
        // Padding isolates the transport envelope from domain-field limits. All
        // provider replies here are synthetic; no network or paid call occurs.
        func provider(replyBytes:Int?=nil,continuation:String="opaque",expectedRequestBytes:Int?=nil)->AskHostedProvider {
            AskHostedProvider(configuration:configuration,token:{String(repeating:"x",count:43)},approve:{_,_ in true},send:{request in
                if let expectedRequestBytes {precondition(request.httpBody?.count==expectedRequestBytes)}
                precondition(request.timeoutInterval==220 && request.value(forHTTPHeaderField:"X-Feast-Agent-Protocol")=="10")
                let input=try JSONSerialization.jsonObject(with:request.httpBody!) as! [String:Any]
                var body:[String:Any]=["version":10,"requestID":input["requestID"]!,"step":input["step"]!,"kind":"answer","text":"Synthetic answer.","continuation":continuation,"model":"gpt-6.1-sol","call":NSNull(),"nativeEvidence":["version":1,"blocks":[],"sources":[],"actions":[]],"finalCitations":[],"budget":["chargedMicroUSD":123],"padding":""]
                if let replyBytes {let base=try JSONSerialization.data(withJSONObject:body,options:.sortedKeys).count;precondition(replyBytes>=base);body["padding"]=String(repeating:"x",count:replyBytes-base)}
                let data=try JSONSerialization.data(withJSONObject:body,options:.sortedKeys)
                if let replyBytes {precondition(data.count==replyBytes)}
                return (data,HTTPURLResponse(url:endpoint,statusCode:200,httpVersion:nil,headerFields:["Content-Type":"application/json"])!)
            },libraryToolsEnabled:{true},permission:{true},libraryPlanVersion:{7},nativeResearchEnabled:{true},collectionQueriesEnabled:{true})
        }
        let maximum=AskNativeCapacity.continuationBytes
        let larger=try await provider(replyBytes:AskNativeCapacity.replyBytes,continuation:String(repeating:"a",count:maximum)).conversationStep(nativeStep())
        precondition(larger.continuation.utf8.count==maximum && larger.nativeEvidence?.version==1)
        for oversized in [false,true] {
            do {
                _ = try await provider(replyBytes:oversized ? AskNativeCapacity.replyBytes+1 : nil,continuation:String(repeating:"a",count:oversized ? 1 : maximum+1)).conversationStep(nativeStep())
                preconditionFailure("Over-limit native reply was accepted")
            }catch let failure as AskConversationFailure {precondition(!failure.retryable && failure.code==(oversized ? "native_reply_limit" : "native_context_limit"))}
        }
        // UTF-8, not Character count, determines the opaque continuation bound.
        let unicode=String(repeating:"é",count:maximum/2)
        _ = try await provider(continuation:unicode).conversationStep(nativeStep())
        do {_ = try await provider(continuation:unicode+"a").conversationStep(nativeStep());preconditionFailure("UTF-8 continuation overrun")}
        catch let failure as AskConversationFailure {precondition(failure.code=="native_context_limit")}
        let skeleton=nativeStep("")
        let base=try wireSize(skeleton)
        let exact=nativeStep(String(repeating:"x",count:AskNativeCapacity.requestBytes-base))
        _ = try await provider(expectedRequestBytes:AskNativeCapacity.requestBytes).conversationStep(exact)
        let never=AskHostedProvider(configuration:configuration,token:{String(repeating:"x",count:43)},approve:{_,_ in true},send:{_ in preconditionFailure("Oversized request was dispatched")},libraryToolsEnabled:{true},permission:{true},libraryPlanVersion:{7},nativeResearchEnabled:{true})
        do {_ = try await never.conversationStep(nativeStep(exact.text+"a"));preconditionFailure("Oversized request was sent")}
        catch let failure as AskConversationFailure {precondition(failure.code=="native_request_limit" && !failure.retryable && failure.localizedDescription.contains("No additional model call"))}
        var old=nativeStep(String(repeating:"x",count:512001));old.version=9;old.webAllowed=nil;old.turnID=nil;old.collectionQueryVersion=nil
        do {_ = try await never.conversationStep(old);preconditionFailure("Legacy request limit expanded")}
        catch let failure as AskConversationFailure {precondition(failure.code=="request_limit")}
        for unsupported in [1,3] {
            var invalid=nativeStep();invalid.collectionQueryVersion=unsupported
            do {_ = try await never.conversationStep(invalid);preconditionFailure("Unsupported query feature marker was sent")}
            catch AskHostedError.invalidResponse {}
        }
        var legacyMarker=nativeStep();legacyMarker.version=9
        do {_ = try await never.conversationStep(legacyMarker);preconditionFailure("Native query marker escaped to legacy protocol")}
        catch AskHostedError.invalidResponse {}
        let step=nativeStep()
        let reply=AskConversationReply(version:10,requestID:step.requestID,step:0,kind:"answer",text:"",continuation:String(repeating:"a",count:350001),model:"gpt-6.1-sol",call:nil,nativeEvidence:.init(version:1,blocks:[],sources:[],actions:[]),finalCitations:[])
        do {_ = try never.checkedConversationReply(reply,step:step);preconditionFailure("Dormant recovery continuation limit expanded")}
        catch let failure as AskConversationFailure {precondition(failure.code=="native_context_limit")}
        let receiptData=try JSONSerialization.data(withJSONObject:["budget":["chargedMicroUSD":123],"padding":String(repeating:"x",count:700000)])
        let receipt=AskConversationReceipt(requestID:step.requestID,mode:"conversationStep",step:0,status:200,data:receiptData,elapsed:1,maximumResponseBytes:AskNativeCapacity.replyBytes)
        precondition(receipt.chargedMicroUSD==123)
        let legacyReceipt=AskConversationReceipt(requestID:step.requestID,mode:"conversationStep",step:0,status:200,data:receiptData,elapsed:1)
        precondition(legacyReceipt.chargedMicroUSD==nil)
        for code in AskConversationFailure.capacityCodes {
            let failure=AskConversationFailure(status:502,code:code)
            precondition(!failure.retryable && !failure.localizedDescription.contains("service is restored"))
        }
        let failure=AskConversationFailure(status:413,code:"native_input_limit")
        precondition(!failure.localizedDescription.contains("Nothing was sent"))
        let disabled=AskHostedProvider(configuration:configuration,token:{preconditionFailure()},approve:{_,_ in false},send:{_ in preconditionFailure()},permission:{false},collectionQueriesEnabled:{true})
        let allowed=await provider().collectionQueryVersion(),denied=await disabled.collectionQueryVersion()
        precondition(allowed==2 && denied==0)
        print("PASS direct native 2MiB request/reply and 1MiB UTF-8 continuation boundaries, diagnostic reader, unchanged legacy/recovery bounds, and nonretryable capacity messages; mocked transport only")
    }

}
