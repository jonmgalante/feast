import Foundation
import CryptoKit

/// Local presentation metadata, never authority or an alternate mutation path.
struct AskOperationAttempt:Codable,Equatable,Sendable {
    let id:String
    let targetID:String?
    let state:String
}
struct AskOperationRecord: Codable, Equatable, Sendable, Identifiable {
    let id: String
    let entity: String
    let operation: String
    var actionIDs: [UUID]
    var targetIDs: [String]
    var status: String
    var outcomes: [AskAgentOutcome]
    var attempts:[AskOperationAttempt]? = nil
    static func make(turn: UUID, proposal: AskChangeProposal, actions: [AskCollectionAction], status: String, outcomes: [AskAgentOutcome],effectiveTargetIDs:[String]?=nil) -> Self {
        let key = [turn.uuidString,proposal.entity,proposal.operation,proposal.instructionQuote.trimmingCharacters(in:.whitespacesAndNewlines)].joined(separator:"\n")
        let id = SHA256.hash(data:Data(key.utf8)).map {String(format:"%02x",$0)}.joined()
        let ids = ((effectiveTargetIDs ?? proposal.targetIDs) + actions.flatMap(\.targetIDs)).reduce(into:[String]()) {if !$0.contains($1) {$0.append($1)}}
        let fields=["update","append"].contains(proposal.operation) && !proposal.changes.isEmpty ? proposal.changes.map(\.field).sorted() : ["operation"]
        let attempts=ids.flatMap {target in fields.map {field->AskOperationAttempt in
            let state=outcomes.last(where:{$0.id==target})?.state ?? (actions.contains(where:{$0.targetIDs.contains(target) && $0.state == .applied}) ? "applied" : status)
            return .init(id:field+":"+target,targetID:target,state:state)
        }}
        let unknown=fields.map {AskOperationAttempt(id:$0+":unknown",targetID:nil,state:"unresolved")}
        return .init(id:id,entity:proposal.entity,operation:proposal.operation,actionIDs:actions.map(\.id),targetIDs:ids,status:status,outcomes:outcomes.filter {ids.contains($0.id)},attempts:attempts.isEmpty && status=="unresolved" ? unknown : attempts)
    }

    static func merged(_ previous: [Self], _ next: Self) -> [Self] {
        var result=previous
        // One authoritative receipt is displayed once even if the model changes
        // its quoted span while continuing the same operation.
        let matches=result.indices.filter {result[$0].id==next.id || !Set(result[$0].actionIDs).isDisjoint(with:Set(next.actionIDs))}
        var merged=next
        for i in matches.reversed() {
            let old=result.remove(at:i)
            merged.actionIDs=(old.actionIDs+merged.actionIDs).reduce(into:[]) {if !$0.contains($1) {$0.append($1)}}
            merged.targetIDs=(old.targetIDs+merged.targetIDs).reduce(into:[]) {if !$0.contains($1) {$0.append($1)}}
            var states=old.outcomes
            for value in merged.outcomes {states.removeAll {$0.id==value.id};states.append(value)}
            merged.outcomes=states
            var attempts=old.attempts ?? []
            for attempt in merged.attempts ?? [] {attempts.removeAll {$0.id==attempt.id};attempts.append(attempt)}
            merged.attempts=attempts.isEmpty ? nil : attempts
        }
        result.append(merged);return result
    }
}

/// UI grouping only: action IDs and target sets remain the execution authority.
struct AskReceiptDetailRow:Identifiable,Equatable {
    let id:String
    let actions:[AskCollectionAction]
    var targetIDs:[String] {actions.flatMap(\.targetIDs).reduce(into:[]){if !$0.contains($1){$0.append($1)}}}
    var undoActions:[AskCollectionAction] {actions.filter {$0.state == .applied && $0.undoable && $0.wasChanged}}
    func title(names:[String:String])->String {
        let labels=targetIDs.compactMap {names[$0]}
        return labels.count==targetIDs.count && !labels.isEmpty ? labels.joined(separator:", ") : actions.first?.title ?? "Recorded change"
    }
    static func make(_ actions:[AskCollectionAction])->[Self] {
        var groups:[Self]=[]
        for action in actions {
            let key=action.entity+":"+(action.targetIDs.isEmpty ? action.id.uuidString : action.targetIDs.sorted().joined(separator:","))
            if let index=groups.firstIndex(where:{$0.id==key}) {groups[index] = .init(id:key,actions:groups[index].actions+[action])}
            else {groups.append(.init(id:key,actions:[action]))}
        }
        return groups
    }
}

struct AskOperationPresentation: Identifiable, Equatable {
    let id: String
    let record: AskOperationRecord
    let actions: [AskCollectionAction]
    let changed: Set<String>
    let unchanged: Set<String>
    let undone: Set<String>
    let attention: Set<String>
    let undoBlocked:Set<String>
    let unresolved: Bool
    var undoActions: [AskCollectionAction] { actions.filter {$0.state == .applied && $0.undoable && $0.wasChanged} }
    var viewIDs: [String] {actions.filter {$0.entity=="place" && $0.state != .undone}.flatMap(\.targetIDs).reduce(into:[]) {if !$0.contains($1) {$0.append($1)}}}
    func title(names: [String:String]) -> String {
        let unit=record.entity=="place" ? "place" : record.entity=="city" ? "city" : record.entity=="neighborhood" ? "neighborhood" : "record"
        func count(_ n:Int)->String {"\(n) "+(n==1 ? unit : unit=="city" ? "cities" : unit+"s")}
        let base:String
        if !changed.isEmpty {
            if changed.count==1,record.entity=="place",let name=names[changed.first!] {base=(record.operation=="delete" ? "Removed " : "Saved ")+name}
            else {base=(record.operation=="delete" ? "Removed " : record.operation=="create" ? "Saved " : "Updated ")+count(changed.count)}
        }else if !undone.isEmpty {base="Undone · "+count(undone.count)}
        else if !unchanged.isEmpty {base="Unchanged · "+count(unchanged.count)}
        else if actions.contains(where:{$0.state == .ready || $0.state == .needsConfirmation}) {base="Review change"}
        else if record.status=="needs_confirmation" {base="Clarification needed"}
        else if unresolved {base="Outcome unresolved"}
        else if !attention.isEmpty || ["failed","conflict","unavailable"].contains(record.status) {base="No change saved"}
        else {base="Recorded changes"}
        let suffix = (!attention.isEmpty ? " · \(attention.count) incomplete" : unresolved && !changed.isEmpty ? " · outcome unresolved" : "") + (!changed.isEmpty && !undone.isEmpty ? " · \(undone.count) undone" : "") + (!undoBlocked.isEmpty ? " · \(undoBlocked.count) Undo blocked" : "")
        return base+suffix
    }
    static func make(response: AskResponse, turnID: UUID) -> [Self] {
        var unique:[AskCollectionAction]=[]
        for action in response.collectionActions ?? [] {unique.removeAll {$0.id==action.id};unique.append(action)}
        var records=response.operationRecords ?? []
        let covered=Set(records.flatMap(\.actionIDs))
        let legacy=unique.filter {!covered.contains($0.id)}
        if !legacy.isEmpty {records.append(.init(id:"legacy-"+turnID.uuidString,entity:legacy.allSatisfy {$0.entity==legacy.first?.entity} ? legacy[0].entity : "item",operation:legacy.allSatisfy {$0.operation==legacy.first?.operation} ? legacy[0].operation : "change",actionIDs:legacy.map(\.id),targetIDs:legacy.flatMap(\.targetIDs),status:response.executionStatus ?? "recorded",outcomes:[]))}
        return records.map {record in
            let actions=unique.filter {record.actionIDs.contains($0.id)}
            let changed=Set(actions.filter {$0.wasChanged && $0.state != .undone}.flatMap(\.targetIDs))
            let unchanged=Set(actions.filter {$0.state == .applied && !$0.wasChanged}.flatMap(\.targetIDs)).subtracting(changed)
            let undone=Set(actions.filter {$0.state == .undone}.flatMap(\.targetIDs)).subtracting(changed)
            var attention=Set(actions.filter {[AskCollectionAction.State.failed,.conflict,.unavailable].contains($0.state)}.flatMap(\.targetIDs))
            let undoBlocked=Set(actions.filter {response.undoFailures?[$0.id.uuidString] != nil}.flatMap(\.targetIDs))
            if let attempts=record.attempts {attention.formUnion(attempts.filter {["failed","pending","unresolved","conflict","unavailable"].contains($0.state)}.compactMap(\.targetID))}
            else {attention.formUnion(record.outcomes.filter {["failed","pending","unresolved"].contains($0.state)}.map(\.id))}
            if ["partial","failed","conflict","unavailable"].contains(record.status) {attention.formUnion(Set(record.targetIDs).subtracting(Set(actions.flatMap(\.targetIDs))))}
            return .init(id:record.id,record:record,actions:actions,changed:changed,unchanged:unchanged,undone:undone,attention:attention,undoBlocked:undoBlocked,unresolved:record.status=="unresolved" || record.status=="stopped" || record.attempts?.contains(where:{$0.state=="unresolved"})==true || actions.contains(where:{[AskCollectionAction.State.conflict,.unavailable].contains($0.state) && $0.committedChange==nil}))
        }
    }
}

extension AskResponse {
    /// Only executor-owned status paragraphs are secondary. Never classify or
    /// rewrite arbitrary model prose using English phrase matching.
    var substantiveParagraphs: [AskAnswerParagraph] {
        guard !(collectionActions ?? []).isEmpty || !(operationRecords ?? []).isEmpty else{return paragraphs}
        let secondary=Set(legacyOperationParagraphs.map(\.id))
        return paragraphs.filter {$0.operationStatus != true && !secondary.contains($0.id)}
    }
    /// Older executor paragraphs lack a typed status distinction. Keep their
    /// exact content in Details rather than guessing which English prose to erase.
    var legacyOperationParagraphs:[AskAnswerParagraph] {
        guard !(collectionActions ?? []).isEmpty else{return []}
        return paragraphs.filter {$0.operationStatus==nil && ["agent-message","action-recovery"].contains($0.id)}
    }
}

/// Display-only History values. Raw archived text never reaches row controls.
struct AskChatHistoryRow:Identifiable {
    let id:UUID
    let title,preview,date:String
    var accessibilityLabel:String {title+", "+date+". "+preview}
}
enum AskHistoryPresentation {
    static func compact(_ text:String, limit:Int) -> String {
        let clean=text.split(whereSeparator:{$0.isWhitespace}).joined(separator:" ")
        guard clean.count>limit else{return clean}
        let prefix=String(clean.prefix(limit));let boundary=prefix.lastIndex(of:" ")
        return (boundary.map {String(prefix[..<$0])} ?? prefix)+"…"
    }
    static func title(_ chat:AskChatArchive,questionUnavailable:Bool=false)->String {
        let first=chat.conversation.turns.first
        let auto=chat.title=="New chat" || first.map {chat.title==String($0.question.prefix(80))}==true
        guard auto else{return chat.title}
        guard !questionUnavailable else{return "Collection conversation"}
        guard let first else{return "New chat"}
        let projected=AskConversationProjection.messages([first.turn]).first(where:{$0.role=="user"})?.text
        guard let projected,projected != AskConversationProjection.omittedHuman else{return "Collection conversation"}
        return compact(projected,limit:56)
    }
    static func preview(_ chat:AskChatArchive,presentedResponse:AskResponse?=nil,presentedQuestions:[UUID:String]?=nil)->String {
        guard !chat.conversation.turns.isEmpty else{return chat.conversation.draft.isEmpty ? "No messages yet" : "Draft message"}
        if let last=chat.conversation.turns.last {
            let displayed=presentedResponse ?? last.response
            let operations=AskOperationPresentation.make(response:displayed,turnID:last.id)
            if !operations.isEmpty {return compact(operations.map {$0.title(names:[:])}.joined(separator:"; "),limit:120)}
            if last.response.publicConversationText != nil,last.response.agentTask?.privateSelection != true,last.response.libraryContext?.excludesExternalReferences != true {
                for paragraph in displayed.substantiveParagraphs where paragraph.id != "library-city-heading" && paragraph.transientToolStatus != true {
                    let clean=String(AskMarkdownPresentation.inline(paragraph,candidates:displayed.candidates).characters)
                    if !clean.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty {return compact(clean,limit:120)}
                }
            }
        }
        for turn in chat.conversation.turns.reversed() {
            // Unknown-provenance legacy questions may be hidden even when their
            // old archive forgot the private-selection flag. Never fall back to
            // that raw question after the active presentation denied it.
            if let presentedQuestions,presentedQuestions[turn.id] != turn.question {continue}
            let human=AskConversationProjection.messages([turn.turn]).first(where:{$0.role=="user"})?.text
            if let human,human != AskConversationProjection.omittedHuman,human.split(whereSeparator:{$0.isWhitespace}).count>=3 {return compact(human,limit:120)}
        }
        return "Collection conversation"
    }
    static func date(_ chat:AskChatArchive)->String {
        let value=chat.lastActivityAt ?? chat.updatedAt
        guard value.timeIntervalSinceReferenceDate.isFinite,value != .distantPast else{return "Date unavailable"}
        let format=DateFormatter();format.dateStyle = .medium;format.timeStyle = .short
        return (chat.lastActivityAt==nil ? (chat.conversation.turns.isEmpty ? "Created " : "Saved ") : "")+format.string(from:value)
    }
    static func ordered(_ chats:[AskChatArchive])->[AskChatArchive] {
        chats.sorted {a,b in
            let lhs=a.lastActivityAt ?? (a.conversation.turns.isEmpty ? .distantPast : a.updatedAt),rhs=b.lastActivityAt ?? (b.conversation.turns.isEmpty ? .distantPast : b.updatedAt)
            return lhs==rhs ? a.id.uuidString < b.id.uuidString : lhs>rhs
        }
    }
}
