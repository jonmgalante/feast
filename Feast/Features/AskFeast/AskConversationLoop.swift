import Foundation

enum AskMarkdownPresentation {
    /// Text cannot lay out Markdown tables. Convert only structurally complete
    /// pipe tables to labelled rows, retaining every cell, number and link.
    static func readableBlocks(_ text:String)->String {
        let lines=text.components(separatedBy:"\n")
        func cells(_ line:String)->[String] {
            var value=line.trimmingCharacters(in:.whitespaces)
            if value.hasPrefix("|"){value.removeFirst()}
            if value.hasSuffix("|") && !value.hasSuffix("\\|"){value.removeLast()}
            var result:[String]=[],current="",escaped=false
            for c in value {
                if c=="|" && !escaped {result.append(current.trimmingCharacters(in:.whitespaces));current=""}else{current.append(c)}
                if c=="\\" {escaped.toggle()}else{escaped=false}
            }
            result.append(current.trimmingCharacters(in:.whitespaces));return result
        }
        var output:[String]=[],i=0,inCode=false
        while i<lines.count {
            let line=lines[i],trimmed=line.trimmingCharacters(in:.whitespaces)
            if trimmed.hasPrefix("```"){inCode.toggle();output.append(line);i+=1;continue}
            if !inCode,i+1<lines.count,line.contains("|") {
                let headings=cells(line),separator=cells(lines[i+1])
                if headings.count>=2,separator.count==headings.count,separator.allSatisfy({$0.range(of:"^:?-{3,}:?$",options:.regularExpression) != nil}) {
                    var rows:[[String]]=[],end=i+2
                    while end<lines.count,lines[end].contains("|") {
                        let row=cells(lines[end]);guard row.count==headings.count else{break};rows.append(row);end+=1
                    }
                    if !rows.isEmpty {
                        for row in rows {
                            output.append(zip(headings,row).map {heading,value in heading.isEmpty ? value : heading+": "+value}.joined(separator:"\n"))
                            output.append("")
                        }
                        i=end;continue
                    }
                }
            }
            output.append(inCode ? line : line.replacingOccurrences(of:"^#{1,6} +",with:"",options:.regularExpression));i+=1
        }
        return output.joined(separator:"\n")
    }
    /// Presentation only. A trailing descriptive source link covers its own
    /// local prose block; a URL appearing elsewhere is not enough.
    static func locallyLinkedSources(_ paragraph:AskAnswerParagraph,researchPool:Bool=false)->Set<URL> {
        guard paragraph.spans.count==1,case .text(let text)=paragraph.spans[0] else{return []}
        var covered=Set<URL>()
        for block in text.components(separatedBy:"\n\n") {
            if block.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty {continue}
            let value=inline(block),runs=Array(value.runs)
            let linked=runs.compactMap {run->(URL,String)? in
                guard let link=run.link else{return nil}
                return (link,String(value[run.range].characters))
            }
            guard linked.count==1,let item=linked.first,
                  let source=AskCitationLink.acceptedURL(for:item.0,citations:paragraph.citations) else{if researchPool {continue};return []}
            let label=item.1.trimmingCharacters(in:.whitespacesAndNewlines)
            guard !label.isEmpty,label.rangeOfCharacter(from:.letters) != nil,
                  URL(string:label)?.scheme==nil else{if researchPool {continue};return []}
            var before="",after="",seen=false
            for run in runs {
                let part=String(value[run.range].characters)
                if run.link != nil {seen=true;continue}
                if seen {after+=part}else{before+=part}
            }
            guard before.rangeOfCharacter(from:.letters) != nil,
                  after.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty else{if researchPool {continue};return []}
            covered.insert(source)
        }
        return covered
    }
    static func hasResearchPoolProvenance(_ paragraph:AskAnswerParagraph,in response:AskResponse)->Bool {
        if let explicit=paragraph.citationsAreResearchPool {return explicit}
        // Backward-compatible interpretation of the existing adapter’s reserved
        // paragraph ID, corroborated by retained research. No archive rewrite.
        guard paragraph.id=="conversation-answer",!paragraph.citations.isEmpty else{return false}
        let wanted=Set(paragraph.citations.compactMap(\.safeURL))
        guard wanted.count==paragraph.citations.count else{return false}
        let retained=(response.publicResearch ?? []).map {Set($0.result.citations.compactMap(\.safeURL))}
        guard !retained.isEmpty,retained.count<=4 else{return false}
        for mask in 1..<(1<<retained.count) {
            var union=Set<URL>()
            for index in retained.indices where mask & (1<<index) != 0 {union.formUnion(retained[index])}
            if union==wanted {return true}
        }
        return false
    }
    static func inline(_ text:String)->AttributedString {
        var value=(try? AttributedString(markdown:readableBlocks(text),options:.init(interpretedSyntax:.inlineOnlyPreservingWhitespace))) ?? AttributedString(text)
        for run in value.runs {if let url=run.link,AskWebCitation(title:"Link",url:url.absoluteString).safeURL==nil {value[run.range].link=nil}}
        return value
    }
}
enum AskConversationProjection {
    static func bounded(_ text:String,units:Int=2000)->String {
        var result="",used=0
        for character in text {let size=String(character).utf16.count;guard used+size<=units else{break};result.append(character);used+=size}
        return result
    }
    static let omittedHuman="An earlier user request was handled locally; its private contents are omitted."
    /// Disclosure provenance only, not edit permission. Never match generated role
    /// labels/placeholders or a short name inside a different human word.
    static func humanNamed(_ name:String,question:String,messages:[AskDialogueMessage],recent:[AskRecentUserQuestion]=[])->Bool {
        let folded=name.folding(options:[.caseInsensitive,.diacriticInsensitive],locale:Locale(identifier:"en_US_POSIX"))
        guard folded.unicodeScalars.contains(where:{CharacterSet.alphanumerics.contains($0)}) else{return false}
        let pattern="(?<![\\p{L}\\p{N}\\p{M}_])"+NSRegularExpression.escapedPattern(for:folded)+"(?![\\p{L}\\p{N}\\p{M}_])"
        guard let regex=try? NSRegularExpression(pattern:pattern) else{return false}
        let human=[question]+recent.suffix(2).map {bounded($0.question)}+messages.suffix(6).filter {$0.role=="user" && $0.text != omittedHuman}.map {bounded($0.text)}
        return human.contains {text in let value=text.folding(options:[.caseInsensitive,.diacriticInsensitive],locale:Locale(identifier:"en_US_POSIX"));return regex.firstMatch(in:value,range:NSRange(value.startIndex...,in:value)) != nil}
    }
    static func authorizationHistory(_ messages:[AskDialogueMessage],recent:[AskRecentUserQuestion]=[])->[String] {
        // Match the already-approved recent HUMAN questions given to the planner.
        // They resolve references, never grant fresh permission or expose stored values.
        let references=recent.suffix(2).filter {item in !messages.contains {$0.role=="user" && $0.text==item.question}}.map {bounded("Earlier human request (reference only): "+$0.question)}
        return references+messages.suffix(6-references.count).map {bounded(($0.role=="user" ? "Human: " : "App context (not authorization): ")+$0.text)}
    }
    static func messages(_ turns:[AskTurn])->[AskDialogueMessage] {
        var messages:[AskDialogueMessage]=[]
        // Only new explicitly public projections are reusable. Legacy answers may contain
        // private local fields; keep their safe task IDs, not their raw prose.
        for turn in turns.suffix(100) where turn.status == .complete && turn.request.attachment==nil && !turn.request.fromOCR {
            let privateResult=turn.response?.agentTask?.privateSelection==true || turn.response?.libraryContext?.excludesExternalReferences==true
            var answer:String
            if !privateResult,let publicText=turn.response?.publicConversationText {answer=publicText}
            else {
                guard turn.response?.agentTask != nil || turn.response?.libraryContext != nil || !(turn.response?.collectionActions ?? []).isEmpty else{continue}
                // Preserve the human's previously disclosed request, never the
                // private answer, field contents, target membership or count.
                let outcomes=(turn.response?.collectionActions ?? []).map {"\($0.entity) \($0.operation): \($0.state.rawValue)"}
                let fields=(turn.response?.agentTask?.fields ?? []).filter {["name","city","neighborhood","cuisine","status","type","address","website","instagram","note","tags"].contains($0)}
                answer="Results rendered locally; private contents are unavailable to you."+(fields.isEmpty ? "" : " Requested field names: "+fields.joined(separator:", "))+(outcomes.isEmpty ? "" : " App outcomes: "+Array(Set(outcomes)).sorted().joined(separator:"; "))
            }
            if let proposal=turn.response?.pendingProposal,let state=turn.response?.executionStatus {
                let projected=proposal.changes.map {change in change.field+(["name","type","cuisines","website","instagram"].contains(change.field) ? "="+(change.value ?? change.values?.joined(separator:",") ?? "from retained finding") : " (local value omitted)")}.joined(separator:"; ")
                answer += "\nEdit attempt (not permission): "+proposal.entity+" "+proposal.operation+", "+state+"; "+projected
            }
            messages.append(.init(role:"user",text:privateResult ? omittedHuman : bounded(turn.request.text)))
            messages.append(.init(role:"assistant",text:bounded(answer)))
        }
        return messages
    }
}
struct AskConversationLoop:Sendable {
    let planner:any AskConversationPlanning
    let availableCandidates:[String:AskCandidate]
    let execute:@Sendable (AskAgentReply.Call)async throws->AskAgentExecution
    var retainFindings:(@Sendable (AskAgentReply.Call,[AskRetainedResearch])async throws->AskAgentExecution)?=nil
    func answer(_ request:AskRequest,context:AskSemanticContext,cities:[AskAgentCity],findings:[AskAgentFinding])async throws->AskResponse {
        let root=(AskProviderAttemptScope.lease?.attempt ?? request.performanceID ?? UUID()).uuidString,task=try request.agentTask?.checked().externalProjection
        var continuation:String?,result:AskConversationStep.Result?,latest:AskResponse?,ordered=request.agentTask?.orderedIDs ?? request.libraryContext?.ids ?? [],privateScope=(request.agentTask?.privateSelection==true || request.libraryContext?.excludesExternalReferences==true)
        var privateHistory=false,currentPrivateTool=false,taskFields:[String]=[]
        var selectionIsOrdered=request.agentTask.map {$0.selectionIDs == nil} ?? (request.libraryContext?.selectionIDs == nil)
        if let membership=request.agentTask?.selectionIDs ?? request.libraryContext?.selectionIDs {ordered=membership}
        var available=availableCandidates
        var publicResearch=request.publicResearch
        let native=await planner.nativeResearchAvailable()
        var attemptedChange=false
        var unresolvedChanges=Set<String>()
        var citations:[AskWebCitation]=[],durableActions:[AskCollectionAction]=[],durableOutcomes:[AskAgentOutcome]=[]
        var operationRecords:[AskOperationRecord]=[]
        func interrupted(_ error:Error)->AskResponse? {
            guard latest != nil || !publicResearch.isEmpty else{return nil}
            var response=latest ?? AskResponse(summary:"Public research was kept for your next message.",candidates:[],listedCandidateIDs:[],usesLocalCatalog:true)
            response.publicResearch=Array(publicResearch.suffix(4))
            response.operationRecords=operationRecords.isEmpty ? nil : operationRecords
            response.paragraphs.append(.init(id:"conversation-interrupted",spans:[.text("Earlier results were kept. "+AskHostedError.message(for:error))],sourceIDs:[]))
            if !durableActions.isEmpty {response.collectionActions=durableActions}
            response.agentTask = .init(action:attemptedChange || !durableActions.isEmpty ? "change" : "query",fields:taskFields,orderedIDs:selectionIsOrdered ? ordered : [],sourcePolicy:"public_if_missing",privateSelection:privateScope || privateHistory,outcomes:durableOutcomes.isEmpty ? nil : durableOutcomes,selectionIDs:selectionIsOrdered ? nil : ordered)
            response.publicConversationText=privateHistory || privateScope ? nil : "Unfinished task. "+(selectionIsOrdered ? "Saved result IDs: "+ordered.joined(separator:",")+". " : "The aggregate selection remains on device. ")+String(response.summary.prefix(1000))
            return response
        }
        for step in 0..<12 {
            try Task.checkCancellation()
            let reply:AskConversationReply
            do {
                var payload=AskConversationStep(requestID:root,step:step,text:request.text,context:context,cities:cities,task:task,findings:findings,history:Array(request.dialogue.suffix(12)),continuation:continuation,result:result,historyCount:request.dialogue.count)
                if native {payload.version=10;payload.webAllowed = !currentPrivateTool;payload.turnID=(request.performanceID ?? UUID(uuidString:root)!).uuidString}
                reply=try await planner.conversationStep(payload)
            }
            catch {
                if let response=interrupted(error) {return response};throw error
            }
            continuation=reply.continuation
            if native,let evidence=reply.nativeEvidence,!evidence.blocks.isEmpty {
                let queries=evidence.actions.flatMap {($0.queries ?? [])+($0.query.map {[$0]} ?? [])}
                let researchID=UUID(uuidString:root)!
                let web=AskWebResearchResult(text:AskConversationProjection.bounded(evidence.blocks.map(\.text).joined(separator:"\n\n"),units:16000),citations:Array(evidence.sources.filter {$0.roles.contains("cited")}.prefix(20)).map {.init(title:$0.title,url:$0.url)},nativeEvidence:evidence)
                let retained=AskRetainedResearch(id:researchID,originatingTurn:request.performanceID ?? researchID,query:AskConversationProjection.bounded((queries.isEmpty ? ["Public native research"] : queries).joined(separator:"\n"),units:1500),result:web)
                publicResearch.removeAll {$0.id==researchID};publicResearch.append(retained)
            }
            if native {citations=reply.finalCitations ?? []}
            if let call=reply.call {
                if call.name=="read_conversation" {
                    struct Range:Decodable {let offset,limit:Int}
                    let range=try JSONDecoder().decode(Range.self,from:Data(call.arguments.utf8))
                    guard (0...199).contains(range.offset),(1...12).contains(range.limit) else {throw AskError.inputLimit}
                    let messages=Array(request.dialogue.dropFirst(range.offset).prefix(range.limit))
                    var output=AskConversationToolResult(.init(status:messages.isEmpty ? "empty" : "success",complete:range.offset+messages.count>=request.dialogue.count,totalCount:request.dialogue.count,records:[],findings:[],message:messages.isEmpty ? "not_found" : "ok",localOnly:false))
                    output.history=messages
                    result = .init(callID:call.callID,output:output)
                }else if call.name=="search_web" {
                    // Prior private instruction contents are redacted from history.
                    // A private tool result in THIS task still cannot feed public search.
                    guard !currentPrivateTool else {throw AskHostedError.answerRejected}
                    struct Search:Decodable {let query:String}
                    let q=try JSONDecoder().decode(Search.self,from:Data(call.arguments.utf8))
                    let web:AskWebResearchResult
                    do {web=try await planner.searchConversationWeb(q.query)}catch {if let response=interrupted(error){return response};throw error}
                    publicResearch.append(.init(id:UUID(),originatingTurn:request.performanceID ?? UUID(),query:q.query,result:web))
                    for source in web.citations where !citations.contains(where:{$0.url==source.url}) {citations.append(source)}
                    result = .init(callID:call.callID,output:.init(.init(status:"success",complete:true,totalCount:0,records:[],findings:[],message:"ok",localOnly:false),web:web))
                }else {
                    if call.name=="propose_changes",let proposal=try? JSONDecoder().decode(AskChangeProposal.self,from:Data(call.arguments.utf8)) {
                        attemptedChange=true
                        taskFields=proposal.changes.map(\.field)
                        if taskFields.contains(where:{["note","tags","status"].contains($0)}) {privateHistory=true}
                    }else if call.name=="query_collection",durableActions.isEmpty,let object=try? JSONSerialization.jsonObject(with:Data(call.arguments.utf8)) as? [String:Any],let query=object["query"] as? [String:Any] {taskFields=query["fields"] as? [String] ?? []}
                    var value:AskAgentExecution
                    do {if call.name=="retain_findings",let retainFindings {value=try await retainFindings(call,publicResearch)}else{value=try await execute(call)}}catch {
                        if error is CancellationError {throw error}
                        // Retention is optional evidence association, never a write.
                        // Reject the proposed association without discarding actual
                        // research or preventing a grounded answer from that research.
                        // The planner can correct identity/value/quote or answer
                        // without manufacturing a verified field or Save action.
                        let rejectedRetention:Bool
                        switch error {case AskError.invalidEvidence,AskError.inputLimit,is DecodingError:rejectedRetention=true;default:rejectedRetention=false}
                        if call.name=="retain_findings",rejectedRetention {
                            result = .init(callID:call.callID,output:.init(.init(status:"conflict",complete:false,totalCount:0,records:[],findings:[],message:"unavailable",localOnly:false)))
                            continue
                        }
                        if call.name=="propose_changes",let proposal=try? JSONDecoder().decode(AskChangeProposal.self,from:Data(call.arguments.utf8)) {
                            if latest==nil {latest = .init(summary:"The change could not be completed.",candidates:[],listedCandidateIDs:[],usesLocalCatalog:true)}
                            latest?.pendingProposal=proposal;latest?.executionStatus=error is AskChangeError ? "failed" : "unresolved"
                            operationRecords=AskOperationRecord.merged(operationRecords,.make(turn:request.performanceID ?? UUID(),proposal:proposal,actions:[],status:latest?.executionStatus ?? "unresolved",outcomes:[]))
                        }
                        if let response=interrupted(error){return response};throw error
                    }
                    if call.name=="propose_changes" {
                        value.response?.pendingProposal=try? JSONDecoder().decode(AskChangeProposal.self,from:Data(call.arguments.utf8))
                        value.response?.executionStatus=value.output.status
                        if let proposal=value.response?.pendingProposal {
                            operationRecords=AskOperationRecord.merged(operationRecords,.make(turn:request.performanceID ?? UUID(),proposal:proposal,actions:value.response?.collectionActions ?? [],status:value.output.status,outcomes:value.outcomes ?? [],effectiveTargetIDs:value.effectiveTargetIDs))
                        }
                        if let proposal=value.response?.pendingProposal {
                            let fields=proposal.changes.map(\.field).sorted().joined(separator:",")
                            let targets=proposal.targetIDs.isEmpty ? [proposal.mapMatchID ?? proposal.changes.first(where:{$0.field=="name"})?.value ?? "current_selection"] : proposal.targetIDs
                            for target in targets {
                                let key=proposal.entity+":"+proposal.operation+":"+target+":"+fields
                                let leaf=value.outcomes?.last(where:{$0.id==target})?.state
                                if ["applied","unchanged"].contains(value.output.status) || ["applied","undone"].contains(leaf ?? "") {unresolvedChanges.remove(key)}
                                else {unresolvedChanges.insert(key)}
                            }
                        }else if !["applied","unchanged"].contains(value.output.status) {unresolvedChanges.insert(call.callID)}
                        if let fields=value.presentation?.requestedFields {taskFields=fields}
                    }
                    if let response=value.response {
                        for candidate in response.candidates {available[candidate.id]=candidate}
                        // A successful mutation invalidates earlier read snapshots. Keep
                        // durable receipts, but require fresh reads for current details.
                        if (response.collectionActions ?? []).contains(where:{$0.state == .applied || $0.state == .undone}) {latest=nil}
                        for action in response.collectionActions ?? [] {if let i=durableActions.firstIndex(where:{$0.id==action.id}) {durableActions[i]=action}else{durableActions.append(action)}}
                        latest=value.appendPreviousResults ? AskAgentLoop.merged(latest,response) : response
                    }
                    for outcome in value.outcomes ?? [] {if let i=durableOutcomes.firstIndex(where:{$0.id==outcome.id}) {durableOutcomes[i]=outcome}else{durableOutcomes.append(outcome)}}
                    if !durableActions.isEmpty {latest?.collectionActions=durableActions}
                    ordered=value.orderedIDs;selectionIsOrdered=value.selectionIsOrdered;privateScope=value.selectionIsPrivate;privateHistory = privateHistory || value.selectionIsPrivate || value.output.localOnly;currentPrivateTool = currentPrivateTool || value.selectionIsPrivate || value.output.localOnly
                    var output=AskConversationToolResult(value.output)
                    output.presentation=value.presentation
                    if output.presentation==nil,call.name=="propose_changes" {output.presentation = .init(kind:"action",requestedFields:[],returnedFields:[],complete:value.output.complete,renderedLocally:true)}
                    result = .init(callID:call.callID,output:output)
                    if ["budget_stopped","needs_confirmation","conflict","unavailable"].contains(value.output.status),!(call.name=="propose_changes" && ["conflict","unavailable"].contains(value.output.status)),!(call.name=="search_maps" && value.output.status=="unavailable"),var response=latest {response.publicResearch=Array(publicResearch.suffix(4));response.operationRecords=operationRecords.isEmpty ? nil : operationRecords;response.agentTask = .init(action:attemptedChange ? "change" : "query",fields:taskFields,orderedIDs:selectionIsOrdered ? ordered : [],sourcePolicy:"public_if_missing",privateSelection:privateScope || privateHistory,outcomes:durableOutcomes.isEmpty ? nil : durableOutcomes,selectionIDs:selectionIsOrdered ? nil : ordered);return response}
                }
                if let lease=AskProviderAttemptScope.lease {
                    var checkpoint=latest ?? AskResponse(summary:"Completed research retained.",candidates:[],listedCandidateIDs:[],usesLocalCatalog:true)
                    checkpoint.publicResearch=Array(publicResearch.suffix(4))
                    checkpoint.agentTask = .init(action:"query",fields:taskFields,orderedIDs:selectionIsOrdered ? ordered : [],sourcePolicy:"public_if_missing",privateSelection:privateScope || privateHistory,selectionIDs:selectionIsOrdered ? nil : ordered)
                    try await AskProviderAttempts.shared.keepReadContext(checkpoint,lease:lease)
                }
                continue
            }
            let assemblyStarted=DispatchTime.now().uptimeNanoseconds
            defer {AskPipelineScope.record(.assembly,since:assemblyStarted)}
            var response=latest ?? AskResponse(summary:String(reply.text.prefix(3000)),candidates:[],listedCandidateIDs:[],usesLocalCatalog:true)
            response.publicResearch=Array(publicResearch.suffix(4))
            response.operationRecords=operationRecords.isEmpty ? nil : operationRecords
            let finalText = !unresolvedChanges.isEmpty ? "" : reply.text
            var rendered=Self.paragraph(finalText,catalog:context.index,available:available,candidates:&response.candidates,citations:citations)
            if native {rendered.citationsAreResearchPool=false}
            if !finalText.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty {
                // Tool-attempt failures are fallback presentation, not final facts.
                // The agent has seen their structured status and may have resolved
                // them through another tool. Keep them only if work interrupts.
                response.paragraphs.removeAll {$0.transientToolStatus == true}
                if latest==nil {response.paragraphs=[rendered]}else{response.paragraphs.insert(rendered,at:0)}
            }
            let references=rendered.spans.compactMap {span->String? in if case .place(let id)=span{return id};return nil}
            if !references.isEmpty {selectionIsOrdered=true;ordered=references.reduce(into:[]) {if !$0.contains($1){$0.append($1)}}}
            response.agentTask = .init(action:attemptedChange || !durableActions.isEmpty ? "change" : "query",fields:taskFields,orderedIDs:selectionIsOrdered ? ordered : [],sourcePolicy:"public_if_missing",privateSelection:privateScope || privateHistory,outcomes:durableOutcomes.isEmpty ? nil : durableOutcomes,selectionIDs:selectionIsOrdered ? nil : ordered)
            let acknowledgements=durableActions.map {"action \($0.id.uuidString) \($0.entity) \($0.operation) \($0.state.rawValue) targets \($0.targetIDs.joined(separator:","))"}.joined(separator:"; ")
            response.publicConversationText=privateHistory || privateScope ? nil : (!unresolvedChanges.isEmpty ? "The requested change was not completed. Check its execution result before retrying." : reply.text)+(acknowledgements.isEmpty ? "" : "\nApp outcomes: "+acknowledgements)
            return response
        }
        if latest != nil || !publicResearch.isEmpty {var response=latest ?? AskResponse(summary:"Some work is unfinished.",candidates:[],listedCandidateIDs:[],usesLocalCatalog:true);response.publicResearch=Array(publicResearch.suffix(4));response.operationRecords=operationRecords.isEmpty ? nil : operationRecords;response.summary="Some work is unfinished.";response.paragraphs.append(.init(id:"conversation-limit",spans:[.text("Some work is unfinished. You can continue from the completed results.")],sourceIDs:[]));return response}
        throw AskHostedError.answerRejected
    }
    static func paragraph(_ text:String,catalog:[AskSemanticContext.Record],available:[String:AskCandidate],candidates:inout[AskCandidate],citations:[AskWebCitation])->AskAnswerParagraph {
        let regex=try! NSRegularExpression(pattern:"\\[\\[place:([A-Fa-f0-9-]{36})\\]\\]")
        let source=text as NSString,matches=regex.matches(in:text,range:NSRange(location:0,length:source.length))
        var cursor=0,spans:[AskAnswerSpan]=[]
        for match in matches {
            if match.range.location>cursor {spans.append(.text(source.substring(with:NSRange(location:cursor,length:match.range.location-cursor))))}
            let raw=source.substring(with:match.range(at:1)),id=UUID(uuidString:raw)?.uuidString
            if let id,let candidate=available[id] {
                if !candidates.contains(where:{$0.id==id}) {candidates.append(candidate)}
                spans.append(.place(id))
            }else{spans.append(.text("a place that is no longer available"))}
            cursor=NSMaxRange(match.range)
        }
        if cursor<source.length {spans.append(.text(source.substring(from:cursor)))}
        let sources=spans.compactMap {span->[String]? in if case .place(let id)=span {return available[id]?.sourceIDs};return nil}.flatMap {$0}
        return .init(id:"conversation-answer",spans:spans.isEmpty ? [.text("")] : spans,sourceIDs:Array(Set(sources)).sorted(),citations:citations,citationsAreResearchPool:true)
    }
}
