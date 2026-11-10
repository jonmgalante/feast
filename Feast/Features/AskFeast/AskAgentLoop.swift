import Foundation

struct AskAgentSelector:Codable,Sendable {let city:String?,name:String?,neighborhood:String?,cuisine:String?,status:String?,placeType:String?;var scope:String?=nil;var positions:[Int]?=nil}
struct AskAgentExpectedChange:Decodable,Sendable {let field,source:String;let value:String?;let values:[String]?}
struct AskAgentPermission:Decodable,Sendable {
    let entity:String,operations:[String],fields:[String],targetIDs:[String],instructionQuote:String
    var selector:AskAgentSelector? = nil
    var changes:[AskAgentExpectedChange]? = nil
    var destinationCityID:String? = nil
    var destinationNeighborhood:String? = nil
    var mapQuery:String? = nil
}
struct AskAgentInterpretation:Decodable,Sendable {
    let goal:String,sourcePolicy:String,fields:[String],selectionIDs:[String]
    let permissions:[AskAgentPermission]
    func checked(question:String,visibleIDs:Set<String>)throws->Self {
        guard ["query","research","change","mixed"].contains(goal),["stored_only","public_if_missing","local_only"].contains(sourcePolicy),fields.count<=11,selectionIDs.count<=200,Set(selectionIDs).isSubset(of:visibleIDs),permissions.count<=4,!["query","research"].contains(goal)||permissions.isEmpty else {throw AskError.invalidEvidence}
        for grant in permissions {
            guard ["city","neighborhood","place"].contains(grant.entity),!grant.operations.isEmpty,Set(grant.operations).isSubset(of:["create","update","append","move","delete","undo"]),grant.fields.count<=8,grant.targetIDs.count<=200,Set(grant.targetIDs).isSubset(of:visibleIDs),!grant.instructionQuote.isEmpty,question.contains(grant.instructionQuote) else {throw AskError.invalidEvidence}
        }
        return self
    }
}
struct AskAgentExecution:Sendable {
    let output:AskAgentResult
    var response:AskResponse?
    var orderedIDs:[String]
    var appendPreviousResults=false
    var selectionIsPrivate=false
    var outcomes:[AskAgentOutcome]? = nil
    var presentation:AskToolPresentation? = nil
    var effectiveTargetIDs:[String]? = nil
    var selectionIsOrdered=true
}
/// One sequential tool loop for any cardinality. The app owns tool execution and writes;
/// the model chooses the next tool from the actual previous result, never an English routing gate.
struct AskAgentLoop:Sendable {
    let planner:any AskAgentPlanning
    let execute:@Sendable (AskAgentReply.Call,AskAgentInterpretation) async throws -> AskAgentExecution
    var prepareIntent:@Sendable (AskAgentInterpretation) async throws -> Void = {_ in}
    static func merged(_ previous:AskResponse?,_ next:AskResponse)->AskResponse {
        guard let previous else {return next}
        var response=next
        var candidates=previous.candidates
        for candidate in next.candidates {if let i=candidates.firstIndex(where:{$0.id==candidate.id}) {candidates[i]=candidate}else{candidates.append(candidate)}}
        response.candidates=candidates
        let native=Set(next.libraryContext?.ids ?? [])
        let mentions=((previous.answerMentionIDs ?? [])+(next.answerMentionIDs ?? [])).reduce(into:[String]()) {if !native.contains($1),!$0.contains($1) {$0.append($1)}}
        response.answerMentionIDs=mentions.isEmpty ? nil : mentions
        response.publicResearch=Array(((previous.publicResearch ?? [])+(next.publicResearch ?? [])).uniquedResearch().suffix(4))
        var operationRecords=previous.operationRecords ?? []
        for record in next.operationRecords ?? [] {operationRecords=AskOperationRecord.merged(operationRecords,record)}
        response.operationRecords=operationRecords.isEmpty ? nil : operationRecords
        response.mapChoices=((previous.mapChoices ?? [])+(next.mapChoices ?? [])).reduce(into:[]) {all,choice in if !all.contains(where:{$0.id==choice.id}) {all.append(choice)}}

        let paragraphs=(previous.paragraphs+next.paragraphs).reduce(into:[AskAnswerParagraph]()) {all,p in if !all.contains(where:{$0.spans==p.spans && $0.citations==p.citations && $0.sourceIDs==p.sourceIDs}) {all.append(p)}}
        response.paragraphs=paragraphs.enumerated().map {i,p in .init(id:"agent-result-\(i)",spans:p.spans,sourceIDs:p.sourceIDs,citations:p.citations,citationsAreResearchPool:p.citationsAreResearchPool ?? (AskMarkdownPresentation.hasResearchPoolProvenance(p,in:response) ? true : nil),representedField:p.representedField,transientToolStatus:p.transientToolStatus,operationStatus:p.operationStatus)}
        var actions=previous.fieldActions ?? []
        for action in next.fieldActions ?? [] {if let i=actions.firstIndex(where:{$0.finding.recordID==action.finding.recordID && $0.finding.field==action.finding.field}) {actions[i]=action}else{actions.append(action)}}
        response.fieldActions=actions.isEmpty ? nil : actions
        var changes=previous.collectionActions ?? []
        for action in next.collectionActions ?? [] {if let i=changes.firstIndex(where:{$0.id==action.id}) {changes[i]=action}else{changes.append(action)}}
        response.collectionActions=changes.isEmpty ? nil : changes
        var facts=previous.verifiedPublicFindings ?? []
        for finding in next.verifiedPublicFindings ?? [] {facts.removeAll {$0.recordID==finding.recordID&&$0.field==finding.field};facts.append(finding)}
        response.verifiedPublicFindings=facts.isEmpty ? nil : facts
        return response
    }
    func answer(_ request:AskRequest,context:AskSemanticContext,cities:[AskAgentCity],findings:[AskAgentFinding])async throws -> AskResponse {
        let root=(AskProviderAttemptScope.lease?.attempt ?? request.performanceID ?? UUID()).uuidString
        let acceptedTask=try request.agentTask?.checked().externalProjection
        var continuation:String?,result:AskAgentStep.Result?,interpretation:AskAgentInterpretation?
        var outcomes=request.agentTask?.outcomes
        var shownIsPrivate=request.agentTask?.privateSelection ?? (request.agentTask?.sourcePolicy=="local_only")
        var shownIsOrdered=true
        var latest:AskResponse?,shown:[String]=[],acceptedFindingIDs=Set(findings.map(\.id))
        let visibleIDs=Set(context.index.map(\.id)+cities.map(\.id)+(acceptedTask?.orderedIDs ?? []))
        for index in 0..<6 {
            try Task.checkCancellation()
            let reply=try await planner.agentStep(.init(requestID:root,step:index,text:request.text,context:context,cities:cities,task:acceptedTask,findings:findings,continuation:continuation,result:result))
            continuation=reply.continuation
            if index==0 {
                guard reply.call.name=="interpret_request",let data=reply.call.arguments.data(using:.utf8) else {throw AskError.invalidEvidence}
                let value=try JSONDecoder().decode(AskAgentInterpretation.self,from:data).checked(question:request.text,visibleIDs:visibleIDs)
                try await prepareIntent(value)
                interpretation=value
                let records=value.selectionIDs.compactMap {id in context.index.first(where:{$0.id==id})}.map {AskAgentRecord(id:$0.id,name:$0.name,city:$0.city,cuisines:$0.cuisines,kind:"place")}
                result = .init(callID:reply.call.callID,output:.init(status:"success",complete:true,totalCount:records.count,records:records,findings:[],message:"ok",localOnly:false))
                continue
            }
            guard let interpretation,reply.call.name != "interpret_request" else {throw AskError.invalidEvidence}
            if reply.call.name=="finish_response" {
                struct Finish:Decodable {let message:String,recordIDs:[String],findingIDs:[String]}
                let finish=try JSONDecoder().decode(Finish.self,from:Data(reply.call.arguments.utf8))
                guard finish.message.count<=1500,finish.recordIDs.count<=200,Set(finish.recordIDs).isSubset(of:Set(shown)),Set(finish.findingIDs).isSubset(of:acceptedFindingIDs) else {throw AskError.invalidEvidence}
                var response=latest ?? AskResponse(summary:finish.message,candidates:[],listedCandidateIDs:[],usesLocalCatalog:true)
                // A follow-up may cite an accepted earlier public finding after the current
                // stored value was undone. Carry its typed evidence into this answer, rather
                // than turning the correct model reply into an unlinked text assertion.
                let retained=request.verifiedFindings.filter {fact in
                    response.candidates.contains(where:{$0.id==fact.recordID}) && response.verifiedPublicFindings?.contains(where:{$0.recordID==fact.recordID && $0.field==fact.field}) != true && finish.findingIDs.contains(fact.id.uuidString) && findings.contains(where:{$0.id==fact.id.uuidString && $0.recordID==fact.recordID && $0.field==fact.field && $0.value==fact.value && $0.sourceURL==fact.evidenceURL})
                }
                for fact in retained {
                    _ = try fact.validated()
                    if response.verifiedPublicFindings?.contains(where:{$0.id==fact.id}) != true {response.verifiedPublicFindings=(response.verifiedPublicFindings ?? [])+[fact]}
                    if fact.field=="instagram",response.candidates.contains(where:{$0.id==fact.recordID}),response.fieldActions?.contains(where:{$0.finding.recordID==fact.recordID && $0.finding.field==fact.field}) != true {
                        response.fieldActions=(response.fieldActions ?? [])+[.init(finding:fact)]
                    }
                }
                // Exact local tool output is authoritative, including private fields not projected to the model.
                if response.paragraphs.isEmpty,response.candidates.isEmpty,response.collectionActions?.isEmpty != false {response = .init(summary:finish.message,candidates:[],listedCandidateIDs:[],usesLocalCatalog:true)}
                if !finish.message.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty,!response.paragraphs.isEmpty {
                    let facts=(response.verifiedPublicFindings ?? []).filter {finish.findingIDs.contains($0.id.uuidString)}
                    var urls=Set<String>()
                    let citations=facts.compactMap {finding->AskWebCitation? in guard urls.insert(finding.evidenceURL).inserted else{return nil};return .init(title:"Source",url:finding.evidenceURL)}
                    response.paragraphs.insert(.init(id:"agent-synthesis",spans:[.text(finish.message)],sourceIDs:[],citations:Array(citations.prefix(6))),at:0)
                }
                if outcomes?.contains(where:{$0.state=="pending" || $0.state=="failed"})==true {
                    response.summary="Some requested changes are still unfinished."
                    response.paragraphs.insert(.init(id:"agent-incomplete-actions",spans:[.text("Some requested changes are still unfinished.")],sourceIDs:[],citations:[]),at:0)
                }
                response.agentTask = .init(action:interpretation.goal=="mixed" ? "research" : interpretation.goal,fields:interpretation.fields,orderedIDs:shownIsOrdered ? shown : [],sourcePolicy:interpretation.sourcePolicy,privateSelection:shownIsPrivate,outcomes:outcomes,selectionIDs:shownIsOrdered ? nil : shown)
                return response
            }
            let execution=try await execute(reply.call,interpretation)
            try Task.checkCancellation()
            if let response=execution.response {latest=execution.appendPreviousResults ? Self.merged(latest,response) : response}
            shown=execution.orderedIDs;shownIsOrdered=execution.selectionIsOrdered;shownIsPrivate=execution.selectionIsPrivate;outcomes=execution.outcomes
            // A fresh field result supersedes an older turn's evidence for that same
            // business/field. Do not append duplicate/stale facts during final synthesis.
            let freshKeys=Set(execution.output.findings.map {$0.recordID+":"+$0.field})
            for old in findings where freshKeys.contains(old.recordID+":"+old.field) {acceptedFindingIDs.remove(old.id)}
            acceptedFindingIDs.formUnion(execution.output.findings.map(\.id))
            result = .init(callID:reply.call.callID,output:execution.output)
            if execution.output.localOnly {
                guard var response=latest else {throw AskError.invalidEvidence}
                response.agentTask = .init(action:interpretation.goal=="mixed" ? "research" : interpretation.goal,fields:interpretation.fields,orderedIDs:shownIsOrdered ? shown : [],sourcePolicy:interpretation.sourcePolicy,privateSelection:shownIsPrivate,outcomes:outcomes,selectionIDs:shownIsOrdered ? nil : shown)
                return response
            }
            if ["budget_stopped","needs_confirmation","conflict","unavailable"].contains(execution.output.status),var response=latest {
                response.agentTask = .init(action:interpretation.goal=="mixed" ? "research" : interpretation.goal,fields:interpretation.fields,orderedIDs:shownIsOrdered ? shown : [],sourcePolicy:interpretation.sourcePolicy,privateSelection:shownIsPrivate,outcomes:outcomes,selectionIDs:shownIsOrdered ? nil : shown)
                return response
            }
        }
        // Do not spend on an automatic fallback or replay completed actions.
        if var latest,let interpretation {
            if outcomes?.contains(where:{$0.state=="pending" || $0.state=="failed"})==true {latest.summary="Some requested changes are still unfinished.";latest.paragraphs.insert(.init(id:"agent-incomplete-actions",spans:[.text("Some requested changes are still unfinished.")],sourceIDs:[],citations:[]),at:0)}
            latest.agentTask = .init(action:interpretation.goal=="mixed" ? "research" : interpretation.goal,fields:interpretation.fields,orderedIDs:shownIsOrdered ? shown : [],sourcePolicy:interpretation.sourcePolicy,privateSelection:shownIsPrivate,outcomes:outcomes,selectionIDs:shownIsOrdered ? nil : shown)
            return latest
        }
        throw AskHostedError.answerRejected
    }
}
