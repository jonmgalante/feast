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
    var displayOrder:[String]? = nil
    var invalidatesNativeQueries:Bool {
        (response?.collectionActions ?? []).contains {$0.state == .undone || ($0.state == .applied && $0.wasChanged)}
    }
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
        response.historyRecordIDs=Array(AskConversationProjection.dependencies(previous).union(AskConversationProjection.dependencies(next))).sorted()
        response.retainsIndependentQuestion=previous.retainsIndependentQuestion==true && next.retainsIndependentQuestion==true ? true : nil
        let native=Set(next.libraryContext?.ids ?? [])
        let mentions=((previous.answerMentionIDs ?? [])+(next.answerMentionIDs ?? [])).reduce(into:[String]()) {if !native.contains($1),!$0.contains($1) {$0.append($1)}}
        response.answerMentionIDs=mentions.isEmpty ? nil : mentions
        response.publicResearch=Array(((previous.publicResearch ?? [])+(next.publicResearch ?? [])).uniquedResearch().suffix(4))
        var operationRecords=previous.operationRecords ?? []
        for record in next.operationRecords ?? [] {operationRecords=AskOperationRecord.merged(operationRecords,record)}
        response.operationRecords=operationRecords.isEmpty ? nil : operationRecords
        response.mapChoices=((previous.mapChoices ?? [])+(next.mapChoices ?? [])).reduce(into:[]) {all,choice in if !all.contains(where:{$0.id==choice.id}) {all.append(choice)}}

        let paragraphs=(previous.paragraphs+next.paragraphs).reduce(into:[AskAnswerParagraph]()) {all,p in if !all.contains(where:{$0.spans==p.spans && $0.citations==p.citations && $0.sourceIDs==p.sourceIDs}) {all.append(p)}}
        response.paragraphs=paragraphs.enumerated().map {i,p in .init(id:"agent-result-\(i)",spans:p.spans,sourceIDs:p.sourceIDs,citations:p.citations,citationsAreResearchPool:p.citationsAreResearchPool ?? (AskMarkdownPresentation.hasResearchPoolProvenance(p,in:response) ? true : nil),representedField:p.representedField,transientToolStatus:p.transientToolStatus,operationStatus:p.operationStatus,historyRecordIDs:p.historyRecordIDs)}
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
    /// Preserve each native query's rows and scope. Only exact consecutive pages
    /// of that query merge membership/order; supplemental findings stay separate.
    static func retainingNative(_ prior:AskResponse?,_ incoming:AskResponse)->AskResponse {
        guard var previous=prior else{return incoming}
        var next=incoming,sections=previous.querySections ?? []
        func paging(_ p:AskAnswerParagraph)->Bool {p.spans.count==1 && {if case .text(let text)=p.spans[0] {return text.hasPrefix("Showing ") && text.contains("matching saved")};return false}()}
        for var section in next.querySections ?? [] {
            if let i=sections.firstIndex(where:{$0.id==section.id}) {
                let old=sections[i]
                if let a=old.page,let b=section.page,a.snapshot==b.snapshot,b.offset==a.offset+a.returnedCount {
                    section.page = .init(snapshot:b.snapshot,totalCount:b.totalCount,offset:a.offset,returnedCount:a.returnedCount+b.returnedCount,nextOffset:b.nextOffset)
                    if let context=section.context,let prior=old.context {
                        let ids=(prior.ids+context.ids).reduce(into:[String]()) {if !$0.contains($1) {$0.append($1)}}
                        let occurrences=(prior.displayOrder ?? prior.ids)+(context.displayOrder ?? context.ids)
                        section.context = .init(ids:ids,filters:context.filters,excludesExternalReferences:true,displayOrder:context.filters.groupBy != nil || occurrences != ids ? occurrences : nil)
                    }
                    let oldIDs=Set(old.paragraphIDs),newIDs=Set(section.paragraphIDs)
                    previous.paragraphs.removeAll {oldIDs.contains($0.id) && paging($0)}
                    next.paragraphs.removeAll {newIDs.contains($0.id) && paging($0)}
                    section.paragraphIDs=previous.paragraphs.filter {oldIDs.contains($0.id)}.map(\.id)+next.paragraphs.filter {newIDs.contains($0.id)}.map(\.id)
                    if let remaining=b.nextOffset {
                        let id="q"+String(section.id.prefix(24))+"-remaining"
                        next.paragraphs.append(.init(id:id,spans:[.text("Showing \(remaining) of \(b.totalCount) matching saved places. More results remain.")],sourceIDs:[],historyRecordIDs:section.selectionIDs))
                        section.paragraphIDs.append(id)
                    }
                }else {
                    let replaced=Set(old.paragraphIDs);previous.paragraphs.removeAll {replaced.contains($0.id)}
                }
                sections[i]=section
            }else{sections.append(section)}
        }
        var response=merged(previous,next)
        response.querySections=sections
        let nativeParagraphs=Set(sections.flatMap(\.paragraphIDs))
        var seen=Set<String>(),paragraphs:[AskAnswerParagraph]=[]
        for original in previous.paragraphs+next.paragraphs where original.id != "conversation-interrupted" && original.id != "conversation-limit" {
            if !nativeParagraphs.contains(original.id),paragraphs.contains(where:{$0.spans==original.spans && $0.sourceIDs==original.sourceIDs && $0.citations==original.citations}) {continue}
            // A continued answer keeps its earlier prose/extra mentions. Give
            // old synthesis its own local ID so the new final paragraph cannot
            // erase the only visible support for a retained extra candidate.
            var p=original.id=="conversation-answer" ? original.renamed("retained-answer-"+String(paragraphs.count)) : original
            if !seen.insert(p.id).inserted {p=p.renamed(String(p.id.prefix(60))+"-extra-"+String(paragraphs.count));seen.insert(p.id)}
            paragraphs.append(p)
        }
        paragraphs.removeAll {$0.id.hasPrefix("section-heading-")}
        // Pages can arrive interleaved (A1, B1, A2, B2). Display the complete
        // native sections in their original query order, never append A2 under
        // B's heading. Keep independent prose outside those contiguous blocks.
        if let firstNative=paragraphs.firstIndex(where:{nativeParagraphs.contains($0.id)}) {
            let byID=Dictionary(uniqueKeysWithValues:paragraphs.map {($0.id,$0)})
            let ordered=sections.flatMap {section in section.paragraphIDs.compactMap {byID[$0]}}
            let prefix=Array(paragraphs.prefix(firstNative))
            let supporting=paragraphs.dropFirst(firstNative).filter {!nativeParagraphs.contains($0.id)}
            paragraphs=prefix+ordered+supporting
        }
        let shown=sections.filter(\.displayed)
        if shown.count>1 {
            for (number,section) in shown.enumerated().reversed() {
                let plan=section.context?.filters
                let label=plan?.name ?? plan?.city ?? (section.entity=="place" ? "Saved places" : section.entity=="city" ? "Saved cities" : "Saved neighborhoods")
                let qualifier=plan.map {" · "+$0.operation.rawValue} ?? ""
                let heading=AskAnswerParagraph(id:"section-heading-"+String(section.id.prefix(24)),spans:[.text("Section \(number+1): "+String(label.prefix(200))+qualifier)],sourceIDs:[])
                if let index=paragraphs.firstIndex(where:{section.paragraphIDs.contains($0.id)}) {paragraphs.insert(heading,at:index)}
            }
        }
        response.paragraphs=paragraphs
        response.refreshNativeAuthority()
        let native=response.nativeMembership
        let mentions=Set(paragraphs.flatMap(\.spans).compactMap {span->String? in if case .place(let id)=span{return id};return nil}).subtracting(native)
        response.answerMentionIDs=mentions.isEmpty ? nil : mentions.sorted()
        let retained=native.union(mentions).union(response.supplementalFindingIDs)
        response.candidates.removeAll {!retained.contains($0.id)}
        let byID=Dictionary(uniqueKeysWithValues:response.candidates.map {($0.id,$0)})
        let ordered=sections.flatMap {$0.context?.ids ?? []}.reduce(into:[String]()) {if !$0.contains($1) {$0.append($1)}}
        response.candidates=ordered.compactMap {byID[$0]}+response.candidates.filter {!native.contains($0.id)}
        return response
    }
    func answer(_ request:AskRequest,context:AskSemanticContext,cities:[AskAgentCity],findings:[AskAgentFinding])async throws -> AskResponse {
        let root=(AskProviderAttemptScope.lease?.attempt ?? request.performanceID ?? UUID()).uuidString
        let acceptedTask=try request.agentTask?.checked().externalProjection
        var continuation:String?,result:AskAgentStep.Result?,interpretation:AskAgentInterpretation?
        var outcomes=request.agentTask?.outcomes
        var shownIsPrivate=request.agentTask?.privateSelection ?? (request.agentTask?.sourcePolicy=="local_only")
        var shownIsOrdered=true
        var displayOrder:[String]?
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
                response.agentTask = .init(action:interpretation.goal=="mixed" ? "research" : interpretation.goal,fields:interpretation.fields,orderedIDs:shownIsOrdered ? shown : [],sourcePolicy:interpretation.sourcePolicy,privateSelection:shownIsPrivate,outcomes:outcomes,selectionIDs:shownIsOrdered ? nil : shown,displayOrder:shownIsOrdered ? displayOrder : nil)
                return response
            }
            let execution=try await execute(reply.call,interpretation)
            try Task.checkCancellation()
            if let response=execution.response {latest=execution.appendPreviousResults ? Self.merged(latest,response) : response}
            shown=execution.orderedIDs;shownIsOrdered=execution.selectionIsOrdered;displayOrder=execution.displayOrder;shownIsPrivate=execution.selectionIsPrivate;outcomes=execution.outcomes
            // A fresh field result supersedes an older turn's evidence for that same
            // business/field. Do not append duplicate/stale facts during final synthesis.
            let freshKeys=Set(execution.output.findings.map {$0.recordID+":"+$0.field})
            for old in findings where freshKeys.contains(old.recordID+":"+old.field) {acceptedFindingIDs.remove(old.id)}
            acceptedFindingIDs.formUnion(execution.output.findings.map(\.id))
            result = .init(callID:reply.call.callID,output:execution.output)
            if execution.output.localOnly {
                guard var response=latest else {throw AskError.invalidEvidence}
                response.agentTask = .init(action:interpretation.goal=="mixed" ? "research" : interpretation.goal,fields:interpretation.fields,orderedIDs:shownIsOrdered ? shown : [],sourcePolicy:interpretation.sourcePolicy,privateSelection:shownIsPrivate,outcomes:outcomes,selectionIDs:shownIsOrdered ? nil : shown,displayOrder:shownIsOrdered ? displayOrder : nil)
                return response
            }
            if ["budget_stopped","needs_confirmation","conflict","unavailable"].contains(execution.output.status),var response=latest {
                response.agentTask = .init(action:interpretation.goal=="mixed" ? "research" : interpretation.goal,fields:interpretation.fields,orderedIDs:shownIsOrdered ? shown : [],sourcePolicy:interpretation.sourcePolicy,privateSelection:shownIsPrivate,outcomes:outcomes,selectionIDs:shownIsOrdered ? nil : shown,displayOrder:shownIsOrdered ? displayOrder : nil)
                return response
            }
        }
        // Do not spend on an automatic fallback or replay completed actions.
        if var latest,let interpretation {
            if outcomes?.contains(where:{$0.state=="pending" || $0.state=="failed"})==true {latest.summary="Some requested changes are still unfinished.";latest.paragraphs.insert(.init(id:"agent-incomplete-actions",spans:[.text("Some requested changes are still unfinished.")],sourceIDs:[],citations:[]),at:0)}
            latest.agentTask = .init(action:interpretation.goal=="mixed" ? "research" : interpretation.goal,fields:interpretation.fields,orderedIDs:shownIsOrdered ? shown : [],sourcePolicy:interpretation.sourcePolicy,privateSelection:shownIsPrivate,outcomes:outcomes,selectionIDs:shownIsOrdered ? nil : shown,displayOrder:shownIsOrdered ? displayOrder : nil)
            return latest
        }
        throw AskHostedError.answerRejected
    }
}
