import Foundation

enum AskMarkdownPresentation {
    /// Provider control syntax is not prose or a source-to-claim association.
    /// Remove only complete recognized citations in presentation; keep malformed
    /// tokens, ordinary turn IDs, emoji and unrelated private-use characters.
    private static let providerCitation = try! NSRegularExpression(pattern:"\u{E200}cite\u{E202}turn[0-9]+(?:search|view|news)[0-9]+(?:\u{E202}turn[0-9]+(?:search|view|news)[0-9]+)*\u{E201}")
    static func visibleText(_ text:String)->String {
        providerCitation.stringByReplacingMatches(in:text,range:NSRange(text.startIndex...,in:text),withTemplate:"")
    }
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
        let visible=visibleText(text)
        var value=(try? AttributedString(markdown:readableBlocks(visible),options:.init(interpretedSyntax:.inlineOnlyPreservingWhitespace))) ?? AttributedString(visible)
        for run in value.runs {if let url=run.link,AskWebCitation(title:"Link",url:url.absoluteString).safeURL==nil {value[run.range].link=nil}}
        return value
    }
    static func inline(_ paragraph:AskAnswerParagraph,candidates:[AskCandidate])->AttributedString {
        let text=paragraph.spans.compactMap {span->String? in if case .text(let value)=span {return value};return nil}.joined()
        guard paragraph.spans.contains(where:{if case .place = $0 {return true};return false}) else{return inline(text)}
        // Opaque, per-occurrence placeholders let Markdown span saved references.
        // Names are inserted literally after parsing, never as Markdown or URLs.
        var prefix:String
        repeat {prefix="FEASTPLACE"+UUID().uuidString.replacingOccurrences(of:"-",with:"")} while text.contains(prefix) || candidates.contains(where:{$0.name.contains(prefix)})
        var replacements:[(token:String,candidate:AskCandidate)]=[]
        let markdown=paragraph.spans.map {span->String in
            switch span {
            case .text(let value): return value
            case .place(let id):
                guard let candidate=candidates.first(where:{$0.id==id}) else{return ""}
                let token=prefix+"N\(replacements.count)END"
                replacements.append((token,candidate));return token
            }
        }.joined()
        var value=inline(markdown)
        for replacement in replacements.reversed() {
            // Table-to-row presentation can repeat a heading's placeholder.
            // Names cannot contain this prefix, so inserted text is never matched.
            while let range=value.range(of:replacement.token) {
                var name=AttributedString(replacement.candidate.name,attributes:value[range].runs.first?.attributes ?? AttributeContainer())
                name.inlinePresentationIntent=(name.inlinePresentationIntent ?? []).union(.stronglyEmphasized)
                // All model-supplied internal links were removed by inline(_:).
                name.link=AskPlaceReference.url(for:replacement.candidate)
                value.replaceSubrange(range,with:name)
            }
        }
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
    static func messages(_ turns:[AskTurn],fullCollection:Bool=false)->[AskDialogueMessage] {
        var messages:[AskDialogueMessage]=[]
        // Only new explicitly public projections are reusable. Legacy answers may contain
        // private local fields; keep their safe task IDs, not their raw prose.
        for turn in turns.suffix(100) where turn.status == .complete && turn.request.attachment==nil && !turn.request.fromOCR {
            let privateResult=turn.response?.agentTask?.privateSelection==true || turn.response?.libraryContext?.excludesExternalReferences==true
            var answer:String
            if fullCollection,let text=turn.response?.collectionConversationText {answer=text}
            else if !privateResult,let publicText=turn.response?.publicConversationText {answer=publicText}
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
            messages.append(.init(role:"user",text:privateResult && !fullCollection ? omittedHuman : bounded(turn.request.text)))
            messages.append(.init(role:"assistant",text:bounded(answer)))
        }
        return messages
    }
}
/// Keep display identities independently of whether a candidate rendered. A missing
/// middle row must never turn the next row into a different ordinal on a save.
enum AskPlaceReferenceSequence {
    struct Sequence {let ids:[String];let incomplete:Bool;let explicitList:Bool}
    private static let token=try! NSRegularExpression(pattern:"\\[\\[place:([^\\]\\r\\n]+)\\]\\]")
    private static let row=try! NSRegularExpression(pattern:"(?m)^\\h*([0-9]+)[.)]\\h+([^\\r\\n]*)")
    private static let bullet=try! NSRegularExpression(pattern:"(?m)^\\h*[-*•]\\h+([^\\r\\n]*)")
    private static func tokens(_ text:String)->(ids:[String],incomplete:Bool) {
        let source=text as NSString,matches=token.matches(in:text,range:NSRange(location:0,length:source.length))
        let ids=matches.compactMap {UUID(uuidString:source.substring(with:$0.range(at:1)))?.uuidString}
        return (ids,ids.count != matches.count || text.components(separatedBy:"[[place:").count-1 != matches.count)
    }
    static func read(_ text:String)->Sequence {
        let all=tokens(text),source=text as NSString
        let numberedRows=row.matches(in:text,range:NSRange(location:0,length:source.length))
        let numbered=numberedRows.contains {source.substring(with:$0.range(at:2)).contains("[[place:")}
        let rows=numbered ? numberedRows : bullet.matches(in:text,range:NSRange(location:0,length:source.length))
        let bodyGroup=numbered ? 2 : 1
        // List rows, not repeated mentions in surrounding prose, define order.
        if rows.contains(where:{source.substring(with:$0.range(at:bodyGroup)).contains("[[place:")}) {
            var ids:[String]=[],incomplete=all.incomplete
            for (index,match) in rows.enumerated() {
                let item=tokens(source.substring(with:match.range(at:bodyGroup)))
                if (numbered && Int(source.substring(with:match.range(at:1))) != index+1) || item.ids.count != 1 || item.incomplete {incomplete=true}
                ids += item.ids
            }
            if Set(ids).count != ids.count {incomplete=true}
            var seen=Set<String>()
            return .init(ids:ids.filter {seen.insert($0).inserted},incomplete:incomplete,explicitList:true)
        }
        var seen=Set<String>()
        return .init(ids:all.ids.filter {seen.insert($0).inserted},incomplete:all.incomplete,explicitList:false)
    }
}
struct AskConversationLoop:Sendable {
    let planner:any AskConversationPlanning
    let availableCandidates:[String:AskCandidate]
    let execute:@Sendable (AskAgentReply.Call)async throws->AskAgentExecution
    var retainFindings:(@Sendable (AskAgentReply.Call,[AskRetainedResearch])async throws->AskAgentExecution)?=nil
    var recoverySnapshot:(@Sendable ()async throws->Data)?=nil
    var revalidateRecoveryAccess:@Sendable ([UUID])async throws->Void = {_ in}
    var collectionQueryVersion:Int=0
    var nativeResearch:Bool?=nil
    func answer(_ request:AskRequest,context:AskSemanticContext,cities:[AskAgentCity],findings:[AskAgentFinding])async throws->AskResponse {
        let fullCollection=context.collectionAccess=="permitted_details_v1"
        let root=(AskProviderAttemptScope.lease?.attempt ?? request.performanceID ?? UUID()).uuidString,task=try request.agentTask?.checked().projection(fullCollection:fullCollection)
        let recovery=AskRecoveryScope.handle
        var state=AskRecoveryLoopState()
        state.referencesIncomplete=request.agentTask?.referencesIncomplete
        state.ordered=request.agentTask?.orderedIDs ?? request.libraryContext?.ids ?? []
        state.privateScope=(request.agentTask?.privateSelection==true || request.libraryContext?.excludesExternalReferences==true)
        state.selectionIsOrdered=request.agentTask.map {$0.selectionIDs == nil} ?? (request.libraryContext?.selectionIDs == nil)
        if let membership=request.agentTask?.selectionIDs ?? request.libraryContext?.selectionIDs {state.ordered=membership}
        state.available=availableCandidates
        if fullCollection,let prior=request.collectionContinuation {for candidate in prior.candidates where state.available[candidate.id]==nil {state.available[candidate.id]=candidate}}
        state.publicResearch=request.publicResearch
        let native:Bool
        if recovery != nil {native=true}
        else if let nativeResearch {native=nativeResearch}
        else {native=await planner.nativeResearchAvailable()}
        // Query support is frozen for this attempt. This is not a capacity profile.
        let queryVersion = native && recovery == nil && fullCollection ? collectionQueryVersion : 0
        if let recovery,let checkpoint=try await recovery.store.checkpoint(recovery.turn) {
            if checkpoint.phase == .executingTool {throw AskRecoveryError.localStepUncertain}
            if checkpoint.loopInitialized {state=checkpoint.state}
        }
        func saveBoundary(nextStep:Int,phase:AskTurnCheckpoint.Phase)async throws {
            guard let recovery,var checkpoint=try await recovery.store.checkpoint(recovery.turn) else{return}
            state.nextStep=nextStep;checkpoint.state=state;checkpoint.phase=phase;checkpoint.loopInitialized=true
            checkpoint.executor=try await recoverySnapshot?()
            if phase == .ready {checkpoint.pendingRequest=nil;checkpoint.reply=nil}
            try await recovery.store.save(checkpoint)
        }
        func keepCollectionHistory(_ response:inout AskResponse,text:String) {
            guard fullCollection else{return}
            let nativeText=response.paragraphs.filter {$0.id != "conversation-answer"}.flatMap(\.spans).map {span->String in
                switch span {case .text(let value):return value;case .place(let id):return "[[place:"+id+"]] "+(state.available[id]?.name ?? "Saved place")}
            }.joined(separator:" ")
            var paging=""
            if let page=response.collectionPage {
                let next=page.nextOffset.map {String($0)} ?? "none"
                paging="\nCollection page: snapshot \(page.snapshot), returned \(page.returnedCount) of \(page.totalCount), nextOffset \(next)"
            }
            response.collectionConversationText=AskConversationProjection.bounded(text+"\n"+nativeText,units:1700)+paging
            response.publicConversationText=nil
        }
        func interrupted(_ error:Error)->AskResponse? {
            guard state.latest != nil || !state.publicResearch.isEmpty else{return nil}
            var response=state.latest ?? AskResponse(summary:"Public research was kept for your next message.",candidates:[],listedCandidateIDs:[],usesLocalCatalog:true)
            response.publicResearch=Array(state.publicResearch.suffix(4))
            response.operationRecords=state.operationRecords.isEmpty ? nil : state.operationRecords
            let explanation="This answer is unfinished. "+AskHostedError.message(for:error)+" Earlier results are retained below, not a completed answer."
            response.summary="This answer is unfinished."
            response.paragraphs.removeAll {$0.id=="conversation-interrupted"}
            response.paragraphs.insert(.init(id:"conversation-interrupted",spans:[.text(explanation)],sourceIDs:[]),at:0)
            if !state.durableActions.isEmpty {response.collectionActions=state.durableActions}
            response.agentTask = .init(action:state.attemptedChange || !state.durableActions.isEmpty ? "change" : "query",fields:state.taskFields,orderedIDs:state.selectionIsOrdered ? state.ordered : [],sourcePolicy:"public_if_missing",privateSelection:state.privateScope || state.privateHistory,outcomes:state.durableOutcomes.isEmpty ? nil : state.durableOutcomes,selectionIDs:state.selectionIsOrdered ? nil : state.ordered,referencesIncomplete:state.referencesIncomplete)
            response.publicConversationText=state.privateHistory || state.privateScope ? nil : "Unfinished task. "+(state.selectionIsOrdered ? "Saved result IDs: "+state.ordered.joined(separator:",")+". " : "The aggregate selection remains on device. ")+String(response.summary.prefix(1000))
            keepCollectionHistory(&response,text:"Unfinished task. Continue from the saved page metadata.")
            return response
        }
        if let recovery,let saved=try await recovery.store.checkpoint(recovery.turn),!saved.loopInitialized {try await saveBoundary(nextStep:0,phase:.ready)}
        for step in state.nextStep..<12 {
            try Task.checkCancellation()
            try await AskRecoveryActivity.check()
            if recovery != nil {try await revalidateRecoveryAccess(state.durableActions.map(\.id))}
            let reply:AskConversationReply
            do {
                var payload=AskConversationStep(requestID:root,step:step,text:request.text,context:context,cities:cities,task:task,findings:findings,history:Array(request.dialogue.suffix(12)),continuation:state.continuation,result:state.result,historyCount:request.dialogue.count)
                if native {payload.version=10;payload.webAllowed = (fullCollection || !state.currentPrivateTool) && !state.localOnlyTool;payload.turnID=(request.performanceID ?? UUID(uuidString:root)!).uuidString;payload.collectionQueryVersion=queryVersion==2 ? 2 : nil}
                reply=try await planner.conversationStep(payload)
            }
            catch {
                if recovery != nil {throw error}
                if let response=interrupted(error) {return response};throw error
            }
            state.continuation=reply.continuation
            if native,let evidence=reply.nativeEvidence,!evidence.blocks.isEmpty {
                let queries=evidence.actions.flatMap {($0.queries ?? [])+($0.query.map {[$0]} ?? [])}
                let researchID=UUID(uuidString:root)!
                let web=AskWebResearchResult(text:AskConversationProjection.bounded(evidence.blocks.map(\.text).joined(separator:"\n\n"),units:16000),citations:Array(evidence.sources.filter {$0.roles.contains("cited")}.prefix(20)).map {.init(title:$0.title,url:$0.url)},nativeEvidence:evidence)
                let retained=AskRetainedResearch(id:researchID,originatingTurn:request.performanceID ?? researchID,query:AskConversationProjection.bounded((queries.isEmpty ? ["Public native research"] : queries).joined(separator:"\n"),units:1500),result:web)
                state.publicResearch.removeAll {$0.id==researchID};state.publicResearch.append(retained)
            }
            if native {state.citations=reply.finalCitations ?? []}
            if let call=reply.call {
                try await AskRecoveryActivity.check()
                if recovery != nil {try await revalidateRecoveryAccess(state.durableActions.map(\.id))}
                try await saveBoundary(nextStep:step,phase:.executingTool)
                if call.name=="read_conversation" {
                    struct Range:Decodable {let offset,limit:Int}
                    let range=try JSONDecoder().decode(Range.self,from:Data(call.arguments.utf8))
                    guard (0...199).contains(range.offset),(1...12).contains(range.limit) else {throw AskError.inputLimit}
                    let messages=Array(request.dialogue.dropFirst(range.offset).prefix(range.limit))
                    var output=AskConversationToolResult(.init(status:messages.isEmpty ? "empty" : "success",complete:range.offset+messages.count>=request.dialogue.count,totalCount:request.dialogue.count,records:[],findings:[],message:messages.isEmpty ? "not_found" : "ok",localOnly:false))
                    output.history=messages
                    state.result = .init(callID:call.callID,output:output)
                }else if call.name=="search_web" {
                    // Prior private instruction contents are redacted from history.
                    // A private tool result in THIS task still cannot feed public search.
                    guard (fullCollection || !state.currentPrivateTool) && !state.localOnlyTool else {throw AskHostedError.answerRejected}
                    struct Search:Decodable {let query:String}
                    let q=try JSONDecoder().decode(Search.self,from:Data(call.arguments.utf8))
                    let web:AskWebResearchResult
                    do {web=try await planner.searchConversationWeb(q.query)}catch {if let response=interrupted(error){return response};throw error}
                    state.publicResearch.append(.init(id:UUID(),originatingTurn:request.performanceID ?? UUID(),query:q.query,result:web))
                    for source in web.citations where !state.citations.contains(where:{$0.url==source.url}) {state.citations.append(source)}
                    state.result = .init(callID:call.callID,output:.init(.init(status:"success",complete:true,totalCount:0,records:[],findings:[],message:"ok",localOnly:false),web:web))
                }else {
                    if call.name=="propose_changes",let proposal=try? JSONDecoder().decode(AskChangeProposal.self,from:Data(call.arguments.utf8)) {
                        state.attemptedChange=true
                        state.taskFields=proposal.changes.map(\.field)
                        if state.taskFields.contains(where:{["note","tags","status"].contains($0)}) {state.privateHistory=true}
                    }else if call.name=="query_collection",state.durableActions.isEmpty,let object=try? JSONSerialization.jsonObject(with:Data(call.arguments.utf8)) as? [String:Any],let query=object["query"] as? [String:Any] {state.taskFields=query["fields"] as? [String] ?? []}
                    var value:AskAgentExecution
                    do {
                        let operation=AskRecoveryOperationIdentity(turnID:request.performanceID ?? UUID(),step:step,callID:call.callID)
                        value=try await AskRecoveryOperationScope.$identity.withValue(recovery == nil ? nil : operation) {
                            if call.name=="retain_findings",let retainFindings {return try await retainFindings(call,state.publicResearch)}
                            return try await execute(call)
                        }
                    }catch {
                        if error is CancellationError || error is AskRecoveryError {throw error}
                        // Retention is optional evidence association, never a write.
                        // Reject the proposed association without discarding actual
                        // research or preventing a grounded answer from that research.
                        // The planner can correct identity/value/quote or answer
                        // without manufacturing a verified field or Save action.
                        let rejectedRetention:Bool
                        switch error {case AskError.invalidEvidence,AskError.inputLimit,is DecodingError:rejectedRetention=true;default:rejectedRetention=false}
                        if call.name=="retain_findings",rejectedRetention {
                            state.result = .init(callID:call.callID,output:.init(.init(status:"conflict",complete:false,totalCount:0,records:[],findings:[],message:"unavailable",localOnly:false)))
                            try await saveBoundary(nextStep:step+1,phase:.ready)
                            continue
                        }
                        if call.name=="propose_changes",let proposal=try? JSONDecoder().decode(AskChangeProposal.self,from:Data(call.arguments.utf8)) {
                            if state.latest==nil {state.latest = .init(summary:"The change could not be completed.",candidates:[],listedCandidateIDs:[],usesLocalCatalog:true)}
                            state.latest?.pendingProposal=proposal;state.latest?.executionStatus=error is AskChangeError ? "failed" : "unresolved"
                            state.operationRecords=AskOperationRecord.merged(state.operationRecords,.make(turn:request.performanceID ?? UUID(),proposal:proposal,actions:[],status:state.latest?.executionStatus ?? "unresolved",outcomes:[]))
                        }
                        if recovery != nil {throw error}
                        if let response=interrupted(error){return response};throw error
                    }
                    if call.name=="propose_changes" {
                        value.response?.pendingProposal=try? JSONDecoder().decode(AskChangeProposal.self,from:Data(call.arguments.utf8))
                        value.response?.executionStatus=value.output.status
                        if let proposal=value.response?.pendingProposal {
                            state.operationRecords=AskOperationRecord.merged(state.operationRecords,.make(turn:request.performanceID ?? UUID(),proposal:proposal,actions:value.response?.collectionActions ?? [],status:value.output.status,outcomes:value.outcomes ?? [],effectiveTargetIDs:value.effectiveTargetIDs))
                        }
                        if let proposal=value.response?.pendingProposal {
                            let fields=proposal.changes.map(\.field).sorted().joined(separator:",")
                            let targets=proposal.targetIDs.isEmpty ? [proposal.mapMatchID ?? proposal.changes.first(where:{$0.field=="name"})?.value ?? "current_selection"] : proposal.targetIDs
                            for target in targets {
                                let key=proposal.entity+":"+proposal.operation+":"+target+":"+fields
                                let leaf=value.outcomes?.last(where:{$0.id==target})?.state
                                if ["applied","unchanged"].contains(value.output.status) || ["applied","undone"].contains(leaf ?? "") {state.unresolvedChanges.remove(key)}
                                else {state.unresolvedChanges.insert(key)}
                            }
                        }else if !["applied","unchanged"].contains(value.output.status) {state.unresolvedChanges.insert(call.callID)}
                        if let fields=value.presentation?.requestedFields {state.taskFields=fields}
                    }
                    if let response=value.response {
                        for candidate in response.candidates {state.available[candidate.id]=candidate}
                        // A successful mutation invalidates earlier read snapshots. Keep
                        // durable receipts, but require fresh reads for current details.
                        if (response.collectionActions ?? []).contains(where:{$0.state == .applied || $0.state == .undone}) {state.latest=nil}
                        for action in response.collectionActions ?? [] {if let i=state.durableActions.firstIndex(where:{$0.id==action.id}) {state.durableActions[i]=action}else{state.durableActions.append(action)}}
                        let previousPage=state.latest ?? request.collectionContinuation
                        if fullCollection,let page=response.collectionPage,let prior=previousPage?.collectionPage,page.snapshot==prior.snapshot,page.offset==prior.offset+prior.returnedCount,let previous=previousPage {
                            var visiblePrevious=previous
                            visiblePrevious.paragraphs.removeAll {$0.id=="conversation-interrupted" || $0.id=="conversation-limit"}
                            var merged=AskAgentLoop.merged(visiblePrevious,response)
                            merged.paragraphs.removeAll {paragraph in paragraph.spans.count==1 && {if case .text(let value)=paragraph.spans[0] {return value.hasPrefix("Showing ") && value.contains("matching saved")};return false}()}
                            merged.collectionPage = .init(snapshot:page.snapshot,totalCount:page.totalCount,offset:prior.offset,returnedCount:prior.returnedCount+page.returnedCount,nextOffset:page.nextOffset)
                            if let context=merged.libraryContext {
                                // Prior answers may also reference places outside these pages.
                                // Only native row IDs participate in the continued query.
                                let ids=((previous.libraryContext?.ids ?? [])+context.ids).reduce(into:[String]()) {if !$0.contains($1) {$0.append($1)}}
                                merged.libraryContext = .init(ids:ids,filters:context.filters,excludesExternalReferences:true)
                                merged.answerMentionIDs=merged.answerMentionIDs.map {$0.filter {!ids.contains($0)}}
                                let byID=Dictionary(uniqueKeysWithValues:merged.candidates.map {($0.id,$0)})
                                merged.candidates=ids.compactMap {byID[$0]}+merged.candidates.filter {!ids.contains($0.id)}
                            }
                            if let remaining=page.nextOffset {merged.paragraphs.append(.init(id:"collection-page",spans:[.text("Showing \(remaining) of \(page.totalCount) matching saved places. More results remain.")],sourceIDs:[]))}
                            state.latest=merged
                        } else {state.latest=value.appendPreviousResults ? AskAgentLoop.merged(state.latest,response) : response}
                    }
                    for outcome in value.outcomes ?? [] {if let i=state.durableOutcomes.firstIndex(where:{$0.id==outcome.id}) {state.durableOutcomes[i]=outcome}else{state.durableOutcomes.append(outcome)}}
                    if !state.durableActions.isEmpty {let actions=state.durableActions;state.latest?.collectionActions=actions}
                    if call.name=="query_collection",["success","empty","local_only"].contains(value.output.status) {state.referencesIncomplete=nil}
                    state.ordered=value.orderedIDs;state.selectionIsOrdered=value.selectionIsOrdered;state.privateScope=value.selectionIsPrivate;state.privateHistory = state.privateHistory || value.selectionIsPrivate || value.output.localOnly;state.currentPrivateTool = state.currentPrivateTool || value.selectionIsPrivate || value.output.localOnly;state.localOnlyTool = state.localOnlyTool || value.output.localOnly
                    var output=AskConversationToolResult(value.output)
                    output.presentation=value.presentation
                    if output.presentation==nil,call.name=="propose_changes" {output.presentation = .init(kind:"action",requestedFields:[],returnedFields:[],complete:value.output.complete,renderedLocally:true)}
                    state.result = .init(callID:call.callID,output:output)
                    if ["budget_stopped","needs_confirmation","conflict","unavailable"].contains(value.output.status),!(call.name=="propose_changes" && ["conflict","unavailable"].contains(value.output.status)),!(call.name=="search_maps" && value.output.status=="unavailable"),var response=state.latest {response.publicResearch=Array(state.publicResearch.suffix(4));response.operationRecords=state.operationRecords.isEmpty ? nil : state.operationRecords;response.agentTask = .init(action:state.attemptedChange ? "change" : "query",fields:state.taskFields,orderedIDs:state.selectionIsOrdered ? state.ordered : [],sourcePolicy:"public_if_missing",privateSelection:state.privateScope || state.privateHistory,outcomes:state.durableOutcomes.isEmpty ? nil : state.durableOutcomes,selectionIDs:state.selectionIsOrdered ? nil : state.ordered,referencesIncomplete:state.referencesIncomplete);return response}
                }
                if recovery == nil,let lease=AskProviderAttemptScope.lease {
                    var checkpoint=state.latest ?? AskResponse(summary:"Completed research retained.",candidates:[],listedCandidateIDs:[],usesLocalCatalog:true)
                    checkpoint.publicResearch=Array(state.publicResearch.suffix(4))
                    checkpoint.agentTask = .init(action:"query",fields:state.taskFields,orderedIDs:state.selectionIsOrdered ? state.ordered : [],sourcePolicy:"public_if_missing",privateSelection:state.privateScope || state.privateHistory,selectionIDs:state.selectionIsOrdered ? nil : state.ordered,referencesIncomplete:state.referencesIncomplete)
                    do {try await AskProviderAttempts.shared.keepReadContext(checkpoint,lease:lease)}
                    catch {if let retained=interrupted(error) {return retained};throw error}
                }
                try await saveBoundary(nextStep:step+1,phase:.ready)
                continue
            }
            let assemblyStarted=DispatchTime.now().uptimeNanoseconds
            defer {AskPipelineScope.record(.assembly,since:assemblyStarted)}
            var response=state.latest ?? AskResponse(summary:String(reply.text.prefix(3000)),candidates:[],listedCandidateIDs:[],usesLocalCatalog:true)
            response.publicResearch=Array(state.publicResearch.suffix(4))
            response.operationRecords=state.operationRecords.isEmpty ? nil : state.operationRecords
            let finalText = !state.unresolvedChanges.isEmpty ? "" : reply.text
            var rendered=Self.paragraph(finalText,catalog:context.index,available:state.available,candidates:&response.candidates,citations:state.citations)
            if native {rendered.citationsAreResearchPool=false}
            if !finalText.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty {
                // Tool-attempt failures are fallback presentation, not final facts.
                // The agent has seen their structured status and may have resolved
                // them through another tool. Keep them only if work interrupts.
                response.paragraphs.removeAll {$0.transientToolStatus == true}
                if state.latest==nil {response.paragraphs=[rendered]}else{response.paragraphs.insert(rendered,at:0)}
            }
            let sequence=AskPlaceReferenceSequence.read(finalText)
            let references=sequence.ids
            let incomplete=sequence.incomplete || references.contains {state.available[$0]==nil}
            let nativeOperation=state.latest?.libraryContext?.filters.operation
            // A native aggregate has membership, not an ordinal list. Incidental
            // references in its explanation must not shrink/reorder that membership.
            let aggregate=nativeOperation.map {[AskLibraryPlan.Operation.count,.group,.catalog].contains($0)} ?? false
            // Compare with the original native rows, before paragraph rendering
            // adds references. An incidental extra place is not another result.
            let nativeIDs=state.latest?.libraryContext?.ids ?? state.latest?.candidates.map(\.id) ?? []
            let completeReplacement:Bool
            if fullCollection,!aggregate,sequence.explicitList,let page=response.collectionPage,page.offset==0,page.nextOffset==nil,!incomplete,!references.isEmpty,references.count==nativeIDs.count,Set(references)==Set(nativeIDs) {completeReplacement=true}else{completeReplacement=false}
            // Synthesized-answer queries do not show native rows. A verified
            // explicit subset may own the follow-up order without changing the
            // authoritative query membership or adding out-of-query targets.
            let explicitAnswerSelection=fullCollection && nativeOperation == .answer && sequence.explicitList && !incomplete && !references.isEmpty && Set(references).isSubset(of:Set(nativeIDs))
            if completeReplacement {
                response.paragraphs=[rendered]
                let byID=Dictionary(uniqueKeysWithValues:response.candidates.map {($0.id,$0)})
                let mentioned=Set(rendered.spans.compactMap {span->String? in if case .place(let id)=span {return id};return nil})
                response.candidates=references.compactMap {byID[$0]}+response.candidates.filter {!references.contains($0.id) && mentioned.contains($0.id)}
                if let previous=response.libraryContext {response.libraryContext = .init(ids:references,filters:previous.filters,excludesExternalReferences:true)}
                state.selectionIsOrdered=true;state.ordered=references;state.referencesIncomplete=nil
            } else if explicitAnswerSelection {
                state.selectionIsOrdered=true;state.ordered=references;state.referencesIncomplete=nil
            } else if nativeOperation == nil && !references.isEmpty {
                state.selectionIsOrdered=true;state.ordered=references;state.referencesIncomplete=incomplete ? true : nil
            }
            // Two conflicting displayed lists must not silently select one order.
            let aggregateListConflict=aggregate && sequence.explicitList && Set(references) != Set(state.ordered)
            let nativeListConflict=nativeOperation != nil && !aggregate && sequence.explicitList && !references.isEmpty && !completeReplacement && !explicitAnswerSelection && (fullCollection || references != state.ordered)
            // With no native rows and no unambiguous explicit list, query input
            // order is not a displayed recommendation order. Ask which place(s)
            // before a previous-selection save, while named saves stay available.
            let ambiguousAnswerSelection=fullCollection && nativeOperation == .answer && !completeReplacement && !explicitAnswerSelection
            if incomplete || aggregateListConflict || nativeListConflict || ambiguousAnswerSelection {state.referencesIncomplete=true}
            if let context=response.libraryContext {
                let native=Set(context.ids)
                let mentioned=Set(response.paragraphs.flatMap(\.spans).compactMap {span->String? in if case .place(let id)=span {return id};return nil})
                let extras=response.candidates.map(\.id).filter {!native.contains($0) && mentioned.contains($0)}
                response.answerMentionIDs=extras.isEmpty ? nil : extras
            }
            response.agentTask = .init(action:state.attemptedChange || !state.durableActions.isEmpty ? "change" : "query",fields:state.taskFields,orderedIDs:state.selectionIsOrdered ? state.ordered : [],sourcePolicy:"public_if_missing",privateSelection:state.privateScope || state.privateHistory,outcomes:state.durableOutcomes.isEmpty ? nil : state.durableOutcomes,selectionIDs:state.selectionIsOrdered ? nil : state.ordered,referencesIncomplete:state.referencesIncomplete)
            let acknowledgements=state.durableActions.map {"action \($0.id.uuidString) \($0.entity) \($0.operation) \($0.state.rawValue) targets \($0.targetIDs.joined(separator:","))"}.joined(separator:"; ")
            response.publicConversationText=state.privateHistory || state.privateScope ? nil : (!state.unresolvedChanges.isEmpty ? "The requested change was not completed. Check its execution result before retrying." : reply.text)+(acknowledgements.isEmpty ? "" : "\nApp outcomes: "+acknowledgements)
            keepCollectionHistory(&response,text:reply.text+"\n"+acknowledgements)
            return response
        }
        if var response=interrupted(AskHostedError.answerRejected) {
            response.summary="Some work is unfinished."
            response.paragraphs.removeAll {$0.id=="conversation-interrupted"}
            response.paragraphs.append(.init(id:"conversation-limit",spans:[.text("Some work is unfinished. You can continue from the completed results.")],sourceIDs:[]))
            keepCollectionHistory(&response,text:"Some work is unfinished. Continue from the saved page metadata.")
            return response
        }
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
            }else{spans.append(.text("a saved place I couldn’t match"))}
            cursor=NSMaxRange(match.range)
        }
        if cursor<source.length {spans.append(.text(source.substring(from:cursor)))}
        let sources=spans.compactMap {span->[String]? in if case .place(let id)=span {return available[id]?.sourceIDs};return nil}.flatMap {$0}
        return .init(id:"conversation-answer",spans:spans.isEmpty ? [.text("")] : spans,sourceIDs:Array(Set(sources)).sorted(),citations:citations,citationsAreResearchPool:true)
    }
}
