import Foundation
import Combine
import Darwin

enum AskMode: String, Codable, CaseIterable, Identifiable, Sendable {
    case collection = "My collection", discovery = "Web discovery", importText = "Import"
    var id: String { rawValue }
}

/// Local routing only; never changes privacy boundaries or enables web/AI services.
enum AskIntentRouter {
    static func mode(for text: String, fromOCR: Bool, previous: AskMode?, override: AskMode?) -> AskMode {
        if fromOCR { return .importText }
        if let override { return override }
        if AskQueryPlan.route(text) != .personal { return .discovery }
        let value = text.lowercased()
        let words = Set(value.split { !$0.isLetter }.map(String.init))
        if value.contains("https://") || value.contains("http://") || words.contains("import") || words.contains("paste") { return .importText }
        if !words.isDisjoint(with: ["saved", "remember", "notes", "note", "collection"]) { return .collection }
        if !words.isDisjoint(with: ["upcoming", "opening", "openings", "discover"]) ||
            ["somewhere new", "new places", "new restaurant", "what's new"].contains(where: value.contains) { return .discovery }
        if let previous, previous != .importText, AskQueryPlan.isFollowUp(text) { return previous }
        return .collection
    }
}

enum AskSourceKind: String, Codable, Sendable { case savedNote, savedMetadata, selectedScreenshot, webFixture, pastedText, localOCR }
struct AskSource: Codable, Identifiable, Equatable, Sendable {
    let id: String
    let title: String
    let kind: AskSourceKind
    let author: String // Explicit attribution, never inferred from the city owner.
    let published: String?
    let checked: String
    let url: String?
    let excerpt: String
}
struct AskAuthoredNote: Equatable, Sendable {
    let id: String
    let author: String
    let text: String
}
struct AskCollectionRecord: Equatable, Sendable {
    let id: String
    let cityID: String
    let city: String
    let name: String
    let neighborhood: String
    let cuisine: String
    let status: String
    let notes: [AskAuthoredNote]
    var address: String? = nil
    var branch: String? = nil
    var rating: Double? = nil
}

/// Construct on-device only after checking current collection and note visibility.
/// No Core Data contexts or hidden records are exposed to a provider.
enum AskDataScope: String, Sendable { case synthetic, savedMetadata }
struct AskLocalIndex: Sendable {
    let scope: AskDataScope
    let records: [AskCollectionRecord]
    private let personalPlaces: [AskPersonalPlace]
    let catalogComplete: Bool
    /// Fresh local access set, including city/neighborhood identities used by history.
    let historyAccessIDs:Set<String>
    init(records: [AskCollectionRecord], visibleCityIDs: Set<String>, visibleNoteIDs: Set<String>, scope: AskDataScope = .synthetic, personalPlaces: [AskPersonalPlace] = [], catalogComplete: Bool = true, visibleSectionIDs:Set<String> = []) {
        self.scope = scope
        self.catalogComplete = catalogComplete
        self.personalPlaces = personalPlaces
        self.historyAccessIDs=Set(records.filter {visibleCityIDs.contains($0.cityID)}.map(\.id)).union(visibleCityIDs).union(visibleSectionIDs)
        self.records = records.filter { visibleCityIDs.contains($0.cityID) }.map { record in
            AskCollectionRecord(id: record.id, cityID: record.cityID, city: scope == .savedMetadata ? "" : record.city, name: record.name,
                neighborhood: scope == .savedMetadata ? "" : record.neighborhood, cuisine: record.cuisine, status: scope == .savedMetadata ? "" : record.status,
                notes: (scope == .savedMetadata ? [] : record.notes).filter { visibleNoteIDs.contains($0.id) }.prefix(10).map {
                    AskAuthoredNote(id: $0.id, author: String($0.author.prefix(120)), text: String($0.text.prefix(1500)))
                }, address: record.address, branch: record.branch, rating: record.rating)
        }
    }
    var personalCatalog: [AskPersonalPlace] { personalPlaces }
    func search(_ text: String, limit: Int, referencedIDs: [String] = []) -> [AskCollectionRecord] {
        let expanded = text.lowercased().replacingOccurrences(of: "ues", with: "upper east side")
        let conversationalWords: Set<String> = ["which", "what", "where", "when", "why", "how", "can", "could", "would", "should", "have", "has", "had", "are", "was", "were", "with", "without", "the", "and", "for", "from", "but", "its", "this", "that", "these", "those", "some", "any", "our", "you", "your", "might", "remember", "saved", "places", "place", "restaurant", "restaurants", "recorded", "cuisine", "cuisines", "good", "best", "want", "like", "eat", "tell", "confirm", "looking", "find", "know", "does", "details"]
        let words = Set(expanded.split { !$0.isLetter && !$0.isNumber }.prefix(40).map(String.init).filter {
            $0.count > 2 && (scope != .savedMetadata || !conversationalWords.contains($0))
        })
        var scored: [(record: AskCollectionRecord, score: Int)] = []
        let localByID = scope == .savedMetadata ? Dictionary(grouping:personalPlaces,by:\.id) : [:]
        let matches = scope == .savedMetadata ? AskQueryPlan.matcher(text:text,all:personalPlaces) : nil
        for record in records {
            if !referencedIDs.isEmpty && !referencedIDs.contains(record.id) { continue }
            if let matches,let local=localByID[record.id] {
                guard local.count==1,matches(local[0]) else{continue}
            }
            let fields = scope == .savedMetadata ? [record.name, record.cuisine, record.address ?? ""] : [record.name, record.city, record.neighborhood, record.cuisine, record.status] + record.notes.map { $0.author + " " + $0.text }
            let haystack = fields.joined(separator: " ").lowercased()
            // Whole clue words avoid matching "the" or fragments of unrelated names.
            let fieldWords = Set(haystack.split { !$0.isLetter && !$0.isNumber }.map(String.init))
            let score = scope == .savedMetadata ? words.intersection(fieldWords).count : words.filter { haystack.contains($0) }.count
            if score > 0 || !referencedIDs.isEmpty { scored.append((record, score)) }
        }
        scored.sort { a, b in a.score == b.score ? a.record.id < b.record.id : a.score > b.score }
        return scored.prefix(max(0, min(limit, 6))).map { $0.record }
    }
}

enum AskFactKind: String, Codable, Sendable { case rating = "Rating", address = "Address", neighborhood = "Neighborhood", cuisine = "Cuisine", opening = "Announced opening", type = "Type" }
struct AskFact: Codable, Equatable, Sendable {
    let kind: AskFactKind
    let value: String
    let sourceID: String
}
struct AskMapOption: Codable, Identifiable, Equatable, Sendable {
    let id: String // Synthetic Maps identifier; never sent to live MapKit.
    let name: String
    let address: String
}
struct AskCandidate: Codable, Identifiable, Equatable, Sendable {
    let id: String
    let name: String
    let city: String
    let facts: [AskFact]
    let sourceIDs: [String]
    let uncertainty: String
    let mapOptions: [AskMapOption]
    let existingRecordID: String?
    var valueForReview: String { facts.map { "\($0.kind.rawValue): \($0.value)" }.joined(separator: "\n") }
}
struct AskEvidence: Sendable {
    let candidates: [AskCandidate]
    let sources: [AskSource]
}
struct AskScreenshot: Codable, Equatable, Sendable {
    let jpeg: Data
    func validated() throws -> Self {
        guard !jpeg.isEmpty, jpeg.count <= 196608, jpeg.starts(with: [0xff,0xd8]), jpeg.suffix(2) == Data([0xff,0xd9]) else { throw AskError.imageLimit }
        return self
    }
}
struct AskRequest: Codable, Equatable, Sendable {
    let mode: AskMode
    let text: String
    let fromOCR: Bool
    var previousQuestion: String? = nil
    var attachment: AskScreenshot? = nil
    var referencedIDs: [String] = []
    var referenceOnly = false
    var libraryContext: AskLibraryContext? = nil
    var referencedWebPlaces: [AskWebPlace] = []
    var verifiedFindings: [AskVerifiedFinding] = []
    var performanceID: UUID? = nil
    var providerRetry=false
    var recentQuestions:[AskRecentUserQuestion] = []
    var agentTask:AskAgentTask? = nil
    var conversationID:UUID? = nil
    var dialogue:[AskDialogueMessage] = []
    var collectionDialogue:[AskDialogueMessage] = []
    var collectionDialogueIDs:[String] = []
    var collectionContinuation:AskResponse? = nil
    var pendingActions:[AskCollectionAction] = []
    var publicResearch:[AskRetainedResearch] = []
    var mapChoices:[AskMapChoice] = []
    // Local-only provenance and complete, permission-checked retrieval text.
    // Neither is encoded into AskConversationStep or any external task projection.
    var collectionHistory:[AskHistoryMessage]? = nil
    var publicHistory:[AskHistoryMessage]? = nil
    var retainedChannelDependencies:[String:[String]]? = nil
    var referenceSections:[AskQuerySection]? = nil
    var referenceSectionsTurnID:UUID? = nil
    func collectionReadVersion() -> Self {
        .init(mode:.collection,text:text,fromOCR:fromOCR,previousQuestion:previousQuestion,attachment:attachment,referencedIDs:referencedIDs,referenceOnly:referenceOnly,libraryContext:libraryContext,referencedWebPlaces:referencedWebPlaces,verifiedFindings:verifiedFindings,performanceID:performanceID,providerRetry:providerRetry,recentQuestions:recentQuestions,agentTask:agentTask,conversationID:conversationID,dialogue:dialogue,collectionDialogue:collectionDialogue,collectionDialogueIDs:collectionDialogueIDs,collectionContinuation:collectionContinuation,pendingActions:pendingActions,publicResearch:publicResearch,mapChoices:mapChoices,collectionHistory:collectionHistory,publicHistory:publicHistory,retainedChannelDependencies:retainedChannelDependencies,referenceSections:referenceSections,referenceSectionsTurnID:referenceSectionsTurnID)
    }
    var retrievalText: String {
        guard mode != .importText, let previousQuestion else { return text }
        return String((text + "\nEarlier question: " + previousQuestion).prefix(4_000))
    }
    func validated() throws -> Self {
        guard (!text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || attachment != nil), text.count <= 4_000, (previousQuestion?.count ?? 0) <= 2_000, referencedIDs.count <= 6, Set(referencedIDs).count == referencedIDs.count, referencedWebPlaces.count <= 3 else { throw AskError.inputLimit }
        if let context = libraryContext {
            guard context.validDisplayOrder,context.ids.count <= AskCollectionPage.maximumRenderedRecords, Set(context.ids).count == context.ids.count else { throw AskError.inputLimit }
            _ = try context.filters.validated()
        }
        if let attachment { _ = try attachment.validated() }
        return self
    }
}
struct AskCollectionQuery: Sendable { let text: String; let limit: Int }
struct AskDiscoveryQuery: Sendable { let text: String; let limit: Int }
struct AskSavedCandidateKey: Hashable, Sendable {
    let turnID: UUID
    let candidateID: String
}

enum AskAnswerSpan: Codable, Equatable, Sendable { case text(String), place(String) }
struct AskAnswerParagraph: Codable, Identifiable, Equatable, Sendable {
    let id: String
    let spans: [AskAnswerSpan]
    let sourceIDs: [String]
    var citations: [AskWebCitation] = []
    // True only for the conversation adapter’s available research-source pool,
    // not a claim-to-source annotation. Missing retains conservative behavior.
    var citationsAreResearchPool:Bool? = nil
    var representedField:String? = nil
    var transientToolStatus:Bool? = nil
    var operationStatus:Bool? = nil
    /// Local fragment dependencies. nil is legacy/unknown, never an empty grant.
    var historyRecordIDs:[String]? = nil
    func renamed(_ value:String)->Self {.init(id:value,spans:spans,sourceIDs:sourceIDs,citations:citations,citationsAreResearchPool:citationsAreResearchPool,representedField:representedField,transientToolStatus:transientToolStatus,operationStatus:operationStatus,historyRecordIDs:historyRecordIDs)}
}
enum AskResponseLayout:String,Codable,Sendable {case direct,list,lookup,clarification,action}
struct AskCollectionPage:Codable,Equatable,Sendable {
    let snapshot:String,totalCount:Int,offset:Int,returnedCount:Int,nextOffset:Int?
    static let maximumRenderedRecords=2400 // 12 tool steps × 200; longer tasks stay explicitly partial.
    var valid:Bool {snapshot.count==64 && snapshot.allSatisfy(\.isHexDigit) && offset>=0 && returnedCount>=0 && totalCount>=offset && returnedCount<=totalCount-offset && (nextOffset==nil ? offset+returnedCount==totalCount : nextOffset==offset+returnedCount && nextOffset!<totalCount)}
}
/// One native query's local identity, membership and displayed occurrences.
/// Independent sections are never flattened into a single mutation scope.
struct AskQuerySection:Codable,Equatable,Sendable {
    let id:String,entity:String
    var context:AskLibraryContext?
    var page:AskCollectionPage?
    var selectionIDs:[String]
    var ordered:Bool
    var displayOrder:[String]?
    var paragraphIDs:[String]
    let displayed:Bool
}
struct AskResponse: Codable, Equatable, Sendable {
    var summary: String
    var candidates: [AskCandidate]
    var paragraphs: [AskAnswerParagraph] = []
    // nil retains the bounded result list for adapters without rich paragraphs.
    // An empty list means a conversational answer with no repeated result rows.
    var listedCandidateIDs: [String]? = nil
    var usesLocalCatalog = false
    var libraryContext: AskLibraryContext? = nil
    /// Verified references in answer prose outside the native query rows. These
    /// are display evidence, never query membership or a follow-up write scope.
    var answerMentionIDs: [String]? = nil
    static let maximumAnswerMentions = 200
    var webPlaces: [AskWebPlace] = []
    var referenceWebPlaces: [AskWebPlace]? = nil
    var fieldActions: [AskFieldActionState]? = nil
    var requestsFieldSave: Bool? = nil
    var presentation:AskResponseLayout? = nil
    var agentTask:AskAgentTask? = nil
    var collectionActions:[AskCollectionAction]? = nil
    var verifiedPublicFindings:[AskVerifiedFinding]? = nil
    var publicConversationText:String? = nil
    var collectionConversationText:String? = nil
    var collectionPage:AskCollectionPage? = nil
    var querySections:[AskQuerySection]? = nil
    var publicResearch:[AskRetainedResearch]? = nil
    var mapChoices:[AskMapChoice]? = nil
    var pendingProposal:AskChangeProposal? = nil
    var executionStatus:String? = nil
    var operationRecords:[AskOperationRecord]? = nil
    var undoFailures:[String:String]? = nil
    var historyRecordIDs:[String]? = nil
    var retainsIndependentQuestion:Bool? = nil
    /// Refresh only the executor's generated review status, never model prose.
    mutating func refreshCollectionReviewStatus() {
        guard let actions=collectionActions,!actions.isEmpty,!actions.contains(where:{$0.state == .ready || $0.state == .needsConfirmation}) else{return}
        let text:String
        if actions.allSatisfy({$0.state == .undone}) {text="Undone."}
        else if actions.allSatisfy({$0.state == .applied || $0.state == .undone}) {text="Saved."}
        else {return}
        for i in paragraphs.indices where paragraphs[i].id=="agent-message" && ["Review this change before applying it.","Saved.","Undone."].contains(where:{paragraphs[i].spans == [.text($0)]}) {
            let old=paragraphs[i]
            paragraphs[i] = .init(id:old.id,spans:[.text(text)],sourceIDs:old.sourceIDs,citations:old.citations,citationsAreResearchPool:old.citationsAreResearchPool,representedField:old.representedField,transientToolStatus:old.transientToolStatus,operationStatus:old.operationStatus,historyRecordIDs:old.historyRecordIDs)
            if ["Review this change before applying it.","Saved.","Undone."].contains(summary) {summary=text}
        }
    }
    var nativeContexts:[AskLibraryContext] {querySections?.compactMap(\.context) ?? libraryContext.map {[$0]} ?? []}
    var nativeMembership:Set<String> {Set(nativeContexts.flatMap(\.ids))}
    var hasPagedNativeResults:Bool {collectionPage != nil || querySections?.contains {$0.page != nil}==true}
    var nativeAuthoritySection:AskQuerySection? {
        guard let querySections else{return nil}
        let shown=querySections.filter(\.displayed)
        return shown.count==1 ? shown[0] : shown.isEmpty && querySections.count==1 ? querySections[0] : nil
    }
    var ambiguousNativeSections:Bool {querySections?.isEmpty==false && nativeAuthoritySection==nil}
    mutating func refreshNativeAuthority() {
        guard querySections != nil else{return}
        libraryContext=nativeAuthoritySection?.context;collectionPage=nativeAuthoritySection?.page
    }
    /// Retained findings are independently verified evidence, not necessarily
    /// prose mentions or native query members. They never grant edit authority.
    var supplementalFindingIDs:Set<String> {
        Set((verifiedPublicFindings ?? []).map(\.recordID)).subtracting(nativeMembership)
    }
    /// Shared admission/archive bounds: additional display evidence never consumes
    /// native query membership, and cannot enlarge that membership by declaration.
    var archiveAdditionalIDs:Set<String>? {
        let mentions=answerMentionIDs ?? [],mentionSet=Set(mentions),candidateIDs=Set(candidates.map(\.id))
        let supplemental=supplementalFindingIDs
        let referenced=Set(paragraphs.flatMap(\.spans).compactMap {span->String? in if case .place(let id)=span{return id};return nil})
        guard candidateIDs.count==candidates.count,mentions.count<=Self.maximumAnswerMentions,
              mentionSet.count==mentions.count,mentionSet.isSubset(of:candidateIDs),mentionSet.isSubset(of:referenced),
              mentionSet.isDisjoint(with:nativeMembership),mentions.isEmpty || usesLocalCatalog,
              supplemental.count<=24,supplemental.isSubset(of:candidateIDs),
              libraryContext == nil || supplemental.isEmpty || usesLocalCatalog else{return nil}
        let extra=mentionSet.union(supplemental)
        if let sections=querySections {
            let paragraphIDs=Set(paragraphs.map(\.id))
            guard !sections.isEmpty,sections.count<=100,Set(sections.map(\.id)).count==sections.count,
                  sections.allSatisfy({section in
                      section.id.count==64 && section.id.allSatisfy(\.isHexDigit) && ["place","city","neighborhood"].contains(section.entity) &&
                      Set(section.selectionIDs).count==section.selectionIDs.count && section.selectionIDs.allSatisfy {UUID(uuidString:$0) != nil} &&
                      Set(section.paragraphIDs).count==section.paragraphIDs.count && Set(section.paragraphIDs).isSubset(of:paragraphIDs) && (section.page?.valid ?? true) && (section.context?.validDisplayOrder ?? true) &&
                      (!section.ordered || section.selectionIDs.count<=AskCollectionPage.maximumRenderedRecords) &&
                      (section.displayOrder.map {section.ordered && $0.count<=section.selectionIDs.count*20 && Set($0)==Set(section.selectionIDs)} ?? true) &&
                      (section.context.map {Set($0.ids).isSubset(of:Set(section.selectionIDs))} ?? true)
                  }),nativeMembership==candidateIDs.subtracting(extra) else{return nil}
        } else if let context=libraryContext {
            guard context.validDisplayOrder,Set(context.ids).count==context.ids.count,
                  context.ids==candidates.map(\.id).filter({!extra.contains($0)}) else{return nil}
        }
        return libraryContext == nil && querySections==nil ? [] : extra
    }
    var maximumArchiveSources:Int {
        usesLocalCatalog ? (hasPagedNativeResults ? AskCollectionPage.maximumRenderedRecords : 200)+(archiveAdditionalIDs?.count ?? 0) : 60
    }
    var hasArchiveCompatibleBounds:Bool {
        guard let extra=archiveAdditionalIDs else{return false}
        func validDependencies(_ ids:[String]?)->Bool {ids.map {Set($0).count==$0.count && $0.allSatisfy {UUID(uuidString:$0) != nil}} ?? true}
        guard validDependencies(historyRecordIDs),paragraphs.allSatisfy({validDependencies($0.historyRecordIDs)}) else{return false}
        let nativeLimit=hasPagedNativeResults ? AskCollectionPage.maximumRenderedRecords : usesLocalCatalog ? 200 : 6
        let usedSources=Set(candidates.flatMap(\.sourceIDs)+paragraphs.flatMap(\.sourceIDs))
        return summary.count<=3000 && candidates.count-extra.count<=nativeLimit &&
            paragraphs.count<=(usesLocalCatalog ? 4001 : 8) && usedSources.count<=maximumArchiveSources
    }
    var layout:AskResponseLayout {
        if let fieldActions,!fieldActions.isEmpty {return fieldActions.allSatisfy {$0.outcome == .ready || $0.outcome == .alreadySaved} ? .lookup : .action}
        return presentation ?? (candidates.count > 1 ? .list : .direct)
    }
}


/// Display only: source evidence remains intact for checking, copy and restoration.
enum AskSourcePresentation {
    // Internal serialized metadata is validation evidence, never a readable public source.
    static func visible(_ sources:[AskSource]) -> [AskSource] { sources.filter {$0.kind != .savedMetadata} }
    static func dates(_ source:AskSource) -> String? {
        func meaningful(_ value:String?) -> String? {
            guard let v=value?.trimmingCharacters(in:.whitespacesAndNewlines),!v.isEmpty,v.lowercased() != "unknown" else {return nil};return v
        }
        let parts=[meaningful(source.published).map {"Published: " + $0},meaningful(source.checked).map {"Checked: " + $0}].compactMap {$0}
        return parts.isEmpty ? nil : parts.joined(separator:" · ")
    }

    static func disclosedSources(response: AskResponse, sources: [AskSource], availableIDs: Set<String>?) -> [AskSource] {
        guard let availableIDs else { return sources }
        return sources.filter { source in
            guard source.kind == .savedMetadata else { return true }
            let claims = response.paragraphs.filter { $0.sourceIDs.contains(source.id) }
            guard !claims.isEmpty else { return true }
            return !claims.allSatisfy { paragraph in
                paragraph.spans.contains { span in
                    guard case .place(let id) = span,
                          let candidate = response.candidates.first(where: { $0.id == id }),
                          candidate.sourceIDs.contains(source.id),
                          let record = candidate.existingRecordID, let uuid = UUID(uuidString: record),
                          availableIDs.contains(uuid.uuidString), AskPlaceReference.url(for: candidate) != nil else { return false }
                    return true
                }
            }
        }
    }
}

enum AskAnswerCopy {
    static func text(_ response: AskResponse) -> String {
        let paragraphs = response.paragraphs.map { String(AskMarkdownPresentation.inline($0,candidates:response.candidates).characters) }.joined(separator: "\n\n")
        var seen = Set<String>()
        let links = response.paragraphs.flatMap(\.citations).filter { $0.safeURL != nil && seen.insert($0.url).inserted }.map { "\($0.title): \($0.url)" }
        return ([paragraphs.isEmpty ? String(AskMarkdownPresentation.inline(response.summary).characters) : paragraphs] + links).joined(separator: "\n")
    }
}

/// Internal navigation only. Never turns a mock Maps ID or source URL into a listing.
enum AskPlaceReference {
    static func url(for candidate: AskCandidate) -> URL? {
        guard let raw = candidate.existingRecordID, let id = UUID(uuidString: raw) else { return nil }
        return URL(string: "feast-ask-place://open/" + id.uuidString)
    }
    static func candidate(for url: URL, in candidates: [AskCandidate]) -> AskCandidate? {
        guard url.scheme == "feast-ask-place", url.host == "open", url.user == nil, url.password == nil, url.port == nil, url.query == nil, url.fragment == nil,
              url.pathComponents.count == 2, let id = UUID(uuidString: url.lastPathComponent) else { return nil }
        let matches = candidates.filter { $0.existingRecordID.flatMap(UUID.init(uuidString:)) == id }
        return matches.count == 1 ? matches[0] : nil
    }
}

enum AskError: LocalizedError {
    case inputLimit, toolLimit, invalidEvidence, imageLimit, unreadableImage, noText, incompleteCollection
    var errorDescription: String? {
        switch self {
        case .incompleteCollection: "I couldn’t check the complete collection. Open a city to review its saved places."
        case .inputLimit: "Enter between 1 and 4,000 characters. Nothing was sent."
        case .toolLimit: "This request exceeds the supported lookup limits."
        case .invalidEvidence: "The answer didn't match the available evidence. No result was accepted."
        case .imageLimit: "Choose one image under 8 MB and 30 megapixels. Only that image is read locally."
        case .unreadableImage: "This image couldn't be read. Try a clear screenshot or paste the text."
        case .noText: "No readable text was found. Try another screenshot or paste text."
        }
    }
}

/// Read-only, bounded tools. No arbitrary URL fetching, SQL, model writes, or credentials.
struct AskReadTools: Sendable {
    private let request: AskRequest
    private let index: AskLocalIndex
    private var evidence: AskEvidence
    init(request: AskRequest, index: AskLocalIndex) throws {
        self.request = try request.validated()
        self.index = index
        switch request.mode {
        case .collection:
            let matches = request.referenceOnly && request.referencedIDs.isEmpty ? [] : index.search(request.retrievalText, limit: 6, referencedIDs: request.referencedIDs)
            if index.scope == .savedMetadata { evidence = AskSavedMetadataEvidence.build(matches) }
            else {
#if FEAST_TESTS
                evidence = AskFixtures.collectionEvidence(matches)
#else
                throw AskError.invalidEvidence
#endif
            }
        case .discovery:
#if FEAST_TESTS
            evidence = index.scope == .savedMetadata ? .init(candidates: [], sources: []) : AskFixtures.webEvidence(request.retrievalText)
#else
            evidence = .init(candidates: [], sources: [])
#endif
        case .importText:
#if FEAST_TESTS
            evidence = index.scope == .savedMetadata ? .init(candidates: [], sources: []) : AskFixtures.importEvidence(request.text, fromOCR: request.fromOCR)
#else
            evidence = .init(candidates: [], sources: [])
#endif
        }
        if request.attachment != nil {
            evidence = .init(candidates: evidence.candidates, sources: evidence.sources + [.init(id: "selected-screenshot", title: "Selected screenshot", kind: .selectedScreenshot, author: "Selected screenshot", published: nil, checked: "", url: nil, excerpt: "Image deliberately attached to this question.")])
        }
    }
    func collection(_ query: AskCollectionQuery) throws -> AskEvidence {
        guard request.mode == .collection, query.text == request.text, (1...6).contains(query.limit) else { throw AskError.toolLimit }
        return bounded(query.limit)
    }
    func discovery(_ query: AskDiscoveryQuery) throws -> AskEvidence {
        guard request.mode == .discovery, query.text == request.text, (1...6).contains(query.limit) else { throw AskError.toolLimit }
        return bounded(query.limit)
    }
    func importedText() throws -> AskEvidence {
        guard request.mode == .importText else { throw AskError.toolLimit }
        return bounded(6)
    }
    private func bounded(_ limit: Int) -> AskEvidence {
        let candidates = Array(evidence.candidates.prefix(limit))
        let needed = Set(candidates.flatMap(\.sourceIDs))
        return AskEvidence(candidates: candidates, sources: Array(evidence.sources.filter { needed.contains($0.id) || (request.attachment != nil && $0.kind == .selectedScreenshot) }.prefix(12)))
    }
    func rebasedCatalogResponse(_ original:AskResponse)->AskResponse {
        guard original.usesLocalCatalog,original.collectionActions?.isEmpty==false else{return original}
        var response=original
        let byID=Dictionary(uniqueKeysWithValues:localEvidence.candidates.map {($0.id,$0)})
        let previous=Dictionary(uniqueKeysWithValues:original.candidates.map {($0.id,$0)})
        response.candidates=original.candidates.compactMap {byID[$0.id]}
        let available=Set(response.candidates.map(\.id)),sources=Set(localEvidence.sources.map(\.id))
        response.paragraphs=original.paragraphs.map {paragraph in
            var sourceIDs=paragraph.sourceIDs.filter {sources.contains($0)}
            let spans=paragraph.spans.map {span->AskAnswerSpan in
                guard case .place(let id)=span else{return span}
                guard let candidate=byID[id] else{return .text((previous[id]?.name ?? "This place")+" (no longer saved)")}
                for source in candidate.sourceIDs where !sourceIDs.contains(source) {sourceIDs.append(source)}
                return .place(id)
            }
            return .init(id:paragraph.id,spans:spans,sourceIDs:sourceIDs,citations:paragraph.citations,citationsAreResearchPool:paragraph.citationsAreResearchPool,representedField:paragraph.representedField,transientToolStatus:paragraph.transientToolStatus,operationStatus:paragraph.operationStatus,historyRecordIDs:paragraph.historyRecordIDs)
        }
        response.listedCandidateIDs=response.listedCandidateIDs.map {$0.filter {available.contains($0)}}
        response.fieldActions=response.fieldActions.map {$0.filter {available.contains($0.finding.recordID)}}
        response.verifiedPublicFindings=response.verifiedPublicFindings.map {$0.filter {available.contains($0.recordID)}}
        response.answerMentionIDs=response.answerMentionIDs.map {$0.filter {available.contains($0)}}
        let supplemental=Set(response.answerMentionIDs ?? []).union(response.supplementalFindingIDs)
        if response.libraryContext?.ids != response.candidates.map(\.id).filter({!supplemental.contains($0)}) {response.libraryContext=nil}
        return response
    }
    func checked(_ response: AskResponse, validationTrace:AskPipelineTrace?=nil) throws -> AskResponse {
        func rejected(_ reason:AskAnswerValidationReason)->AskError {validationTrace?.rejectAnswer(reason);return .invalidEvidence}
        let mentions=response.answerMentionIDs ?? []
        let mentionSet=Set(mentions),candidateIDs=Set(response.candidates.map(\.id))
        let supplemental=response.supplementalFindingIDs
        guard supplemental.count<=24,supplemental.isSubset(of:candidateIDs),response.libraryContext == nil || supplemental.isEmpty || response.usesLocalCatalog else {throw rejected(.findings)}
        let extraIDs=mentionSet.union(supplemental)
        let referenced=Set(response.paragraphs.flatMap(\.spans).compactMap {span->String? in if case .place(let id)=span {return id};return nil})
        guard mentions.count<=AskResponse.maximumAnswerMentions,mentionSet.count==mentions.count,
              mentionSet.isSubset(of:candidateIDs),mentionSet.isSubset(of:referenced),
              mentionSet.isDisjoint(with:response.nativeMembership),mentions.isEmpty || response.usesLocalCatalog else {throw rejected(.answerMentions)}
        let listing = response.usesLocalCatalog ? AskCollectionListingPlan.make(request, places: index.personalCatalog) : nil
        let localTool = response.usesLocalCatalog && (response.libraryContext != nil || response.agentTask != nil)
        let localListing = listing != nil || localTool
        guard response.summary.count <= 3_000, response.candidates.count - (response.libraryContext == nil && response.querySections==nil ? 0 : extraIDs.count) <= (response.hasPagedNativeResults ? AskCollectionPage.maximumRenderedRecords : localListing ? 200 : 6),
              Set(response.candidates.map(\.id)).count == response.candidates.count else { throw rejected(.responseBounds) }
        let available = response.usesLocalCatalog ? localEvidence : evidence
        let catalog = Dictionary(uniqueKeysWithValues: available.candidates.map { ($0.id, $0) })
        let sources = Set(available.sources.map(\.id))
        for candidate in response.candidates {
            guard catalog[candidate.id] == candidate, !candidate.sourceIDs.isEmpty,
                  Set(candidate.sourceIDs).isSubset(of: sources),
                  candidate.facts.allSatisfy({ candidate.sourceIDs.contains($0.sourceID) }) else { throw rejected(.candidateEvidence) }
        }
        if response.querySections != nil {guard response.nativeMembership==candidateIDs.subtracting(extraIDs) else{throw rejected(.queryMembership)}}
        for context in response.nativeContexts {
            guard context.validDisplayOrder,context.ids.count <= (response.hasPagedNativeResults ? AskCollectionPage.maximumRenderedRecords : 200), Set(context.ids).count == context.ids.count, response.querySections != nil || context.ids == response.candidates.map(\.id).filter({!extraIDs.contains($0)}) else { throw rejected(.queryMembership) }
            if let selection=context.selectionIDs {
                guard response.usesLocalCatalog,[AskLibraryPlan.Operation.count,.group].contains(context.filters.operation),Set(selection).count == selection.count,Set(selection).isSubset(of:Set(index.personalCatalog.map(\.id))) else { throw rejected(.aggregateMembership) }
            }
        }
        if let listing, !localTool {
            let expected = Set(index.personalCatalog.filter(listing.matcher(all:index.personalCatalog)).map(\.id))
            guard Set(response.candidates.map(\.id)) == expected else { throw rejected(.listingMembership) }
        }
        if response.requestsFieldSave == true {
            guard request.verifiedFindings.count <= 6,response.fieldActions?.count == 1,
                  response.fieldActions?.allSatisfy({request.verifiedFindings.contains($0.finding)}) == true else {throw rejected(.fieldSave)}
        }
        if let choices=response.mapChoices {
            guard choices.count<=6,Set(choices.map(\.id)).count==choices.count,choices.allSatisfy({UUID(uuidString:$0.id) != nil && !$0.applePlaceID.isEmpty && $0.applePlaceID.count<=300 && !$0.name.isEmpty && $0.name.count<=200 && $0.address.count<=500 && $0.city.count<=200 && $0.query.count<=300 && ($0.website==nil || InstagramWebsiteClient.websiteURL($0.website!) != nil)}) else{throw rejected(.mapChoices)}
        }
        if let research=response.publicResearch {
            guard research.count<=4,research.allSatisfy({$0.query.count<=1500 && $0.result.text.count<=16000 && $0.result.citations.count<=20 && $0.result.citations.allSatisfy {$0.safeURL != nil}}) else{throw rejected(.research)}
        }
        do {for research in response.publicResearch ?? [] {_ = try research.result.nativeEvidence?.checked()}}catch {throw rejected(.nativeEvidence)}
        if let operations=response.operationRecords {
            let actionIDs=Set((response.collectionActions ?? []).map(\.id))
            guard operations.count<=24,Set(operations.map(\.id)).count==operations.count,
                  operations.allSatisfy({record in
                    record.id.count==64 && record.id.allSatisfy(\.isHexDigit) && ["place","city","neighborhood"].contains(record.entity) && ["create","update","append","move","delete","undo"].contains(record.operation) && record.targetIDs.count<=200 && record.targetIDs.allSatisfy {UUID(uuidString:$0) != nil} && Set(record.actionIDs).isSubset(of:actionIDs) && record.outcomes.count<=200
                  }) else{throw rejected(.operationRecords)}
        }
        if let findings=response.verifiedPublicFindings {
            guard findings.count<=24,Set(findings.map(\.id)).count==findings.count else {throw rejected(.findings)}
            for finding in findings {do {_ = try finding.validated()}catch {throw rejected(.findings)};guard response.candidates.contains(where:{$0.id==finding.recordID}) else {throw rejected(.findings)}}
        }
        if let actions=response.fieldActions {
            guard actions.count <= (localTool ? 24 : 6),Set(actions.map { $0.finding.id }).count == actions.count else {throw rejected(.fieldActions)}
            for action in actions { do {_ = try action.finding.validated()}catch {throw rejected(.fieldActions)};guard action.finding.field=="instagram",response.candidates.contains(where:{$0.id == action.finding.recordID}) else {throw rejected(.fieldActions)} }
        }
        if let page=response.collectionPage {guard page.snapshot.count==64,page.snapshot.allSatisfy(\.isHexDigit),page.offset>=0,page.returnedCount>=0,page.offset+page.returnedCount<=page.totalCount,page.nextOffset==nil ? page.offset+page.returnedCount==page.totalCount : page.nextOffset==page.offset+page.returnedCount && page.nextOffset!<page.totalCount else{throw rejected(.collectionPage)}}
        let returnedIDs = Set(response.candidates.map(\.id))
        if let rows = response.listedCandidateIDs {
            guard rows.count <= 6, Set(rows).count == rows.count, Set(rows).isSubset(of: returnedIDs) else { throw rejected(.listedCandidates) }
        }
        guard response.paragraphs.count <= (localListing ? 4001 : 8), Set(response.paragraphs.map(\.id)).count == response.paragraphs.count else { throw rejected(.paragraphBounds) }
        let returnedSources = sources // Every cited source must be in the approved request evidence.
        var characters = 0
        for paragraph in response.paragraphs {
            guard paragraph.citations.count <= (localTool ? 20 : 6), paragraph.citations.allSatisfy({ $0.safeURL != nil && $0.title.count <= 200 }) else { throw rejected(.citations) }
            guard !paragraph.id.isEmpty, paragraph.id.count <= 80, (1...(response.hasPagedNativeResults ? 4801 : localTool ? 401 : 24)).contains(paragraph.spans.count),
                  Set(paragraph.sourceIDs).count == paragraph.sourceIDs.count,
                  Set(paragraph.sourceIDs).isSubset(of: returnedSources) else { throw rejected(.paragraphEvidence) }
            for span in paragraph.spans {
                switch span {
                case .text(let text): characters += text.count
                case .place(let id):
                    guard let candidate = response.candidates.first(where: { $0.id == id }),
                          !Set(candidate.sourceIDs).isDisjoint(with: paragraph.sourceIDs) else { throw rejected(.placeReference) }
                    characters += candidate.name.count
                }
            }
        }
        guard characters <= (response.hasPagedNativeResults ? 720_000 : localListing ? 60_000 : 3_000) else { throw rejected(.answerLength) }
        // Retain the precise existing evidence/membership rejection reason, then
        // ensure every accepted response also meets the shared archive envelope.
        guard response.hasArchiveCompatibleBounds else {throw rejected(.responseBounds)}
        return response
    }
    private var localEvidence: AskEvidence {
        let chunks = index.records.map { AskSavedMetadataEvidence.build([$0]) }
        return .init(candidates: chunks.flatMap(\.candidates), sources: chunks.flatMap(\.sources))
    }
    func localRecordsMatch(_ records: [AskPersonalPlace]) -> Bool {
        records.allSatisfy { record in index.personalCatalog.contains(record) }
    }
    func resolving(_ ids: [String]) throws -> (AskRequest, AskReadTools) {
        guard (1...6).contains(ids.count), Set(ids).count == ids.count, ids.allSatisfy({ localCandidate($0) != nil }) else { throw AskError.invalidEvidence }
        var resolved = request
        resolved.referencedIDs = ids; resolved.referenceOnly = true
        resolved.previousQuestion = nil; resolved.libraryContext = nil
        var scoped = try AskReadTools(request: resolved, index: index)
        if index.scope == .savedMetadata {
            // IDs already came from the fresh typed tool result. Do not veto them with a second English text search.
            scoped.evidence = AskSavedMetadataEvidence.build(ids.compactMap { id in index.records.first {$0.id == id} })
        }
        return (resolved, scoped)
    }
    func collectionReadTools() throws -> Self {try AskReadTools(request:request.collectionReadVersion(),index:index)}
    var completeLocalCatalog: Bool { index.catalogComplete }
    /// Resolve exact current IDs in one local scan. This does not enlarge model input.
    func localCandidates(_ ids:Set<String>)->[String:AskCandidate] {Self.localCandidates(ids,in:index)}
    static func localCandidates(_ ids:Set<String>,in index:AskLocalIndex)->[String:AskCandidate] {
        let records=Dictionary(grouping:index.records.filter {ids.contains($0.id)},by: \.id)
        return records.reduce(into:[:]) {result,entry in
            guard entry.value.count==1,let candidate=AskSavedMetadataEvidence.build(entry.value).candidates.first else{return}
            result[entry.key]=candidate
        }
    }
    func localCandidate(_ id: String) -> AskCandidate? {
        guard let record=index.records.first(where:{$0.id==id}) else{return nil}
        return AskSavedMetadataEvidence.build([record]).candidates.first
    }
    func source(_ id: String) -> AskSource? {
        if let source=evidence.sources.first(where:{$0.id==id}) {return source}
        guard let record=index.records.first(where:{"metadata-"+$0.id==id}) else{return nil}
        return AskSavedMetadataEvidence.build([record]).sources.first
    }
}

protocol AskFeastProvider: Sendable {
    var label: String { get }
    func answer(_ request: AskRequest, tools: AskReadTools) async throws -> AskResponse
}


enum AskTurnStatus: Equatable { case loading, complete, stopped, failed(String) }
struct AskTurn: Identifiable, Equatable {
    let id: UUID
    let request: AskRequest
    var response: AskResponse?
    var sources: [AskSource] = []
    var status: AskTurnStatus = .loading
    var wasInterrupted = false
    var stoppedMessage: String {wasInterrupted ? "Answer interrupted. Keep Ask Feast open until it finishes." : "Stopped."}
    var isArchiveEligible:Bool {status != .loading && request.attachment == nil}
    var readContextMode:AskMode {response?.usesLocalCatalog == true && response?.libraryContext != nil ? .collection : request.mode}
}

@MainActor final class AskSession: ObservableObject {
    @Published var input = "" { didSet { fallbackDraftTurnID=nil; if input.isEmpty { fromOCR = false }; scheduleHistory() } }
    private var fallbackDraftTurnID:UUID?
    @Published var mode: AskMode = .collection { didSet { if mode != oldValue { fromOCR = false } } }
    @Published var sourceOverride: AskMode? = nil
    @Published var fromOCR = false
    @Published var attachment: AskScreenshot?
    @Published private(set) var turns: [AskTurn] = []
    @Published private(set) var isLoading = false
    @Published private(set) var error: String?
    @Published private(set) var historyWarning:String?
    private struct VolatileScreen {let turns:[AskTurn],canRetry:[UUID:Bool]}
    private var volatileScreens:[UUID:VolatileScreen]=[:]
    private var unsavedChatIDs=Set<UUID>()
    var unsavedHistoryChatIDs:Set<UUID> {unsavedChatIDs}
#if FEAST_TESTS
    var historyDestructiveInterruption:((String)->Bool)?
#endif
    private func interruptHistoryDestruction(_ point:String)->Bool {
#if FEAST_TESTS
        return historyDestructiveInterruption?(point) ?? false
#else
        return false
#endif
    }
    @Published private(set) var canRetry: [UUID: Bool] = [:]
    @Published private(set) var chats: [AskChatArchive] = []
    @Published private(set) var activeChatID = UUID()
    @Published private(set) var needsOnlineConsent = false
    private var consentTicket: UUID?
    private var historyMigration: AskChatMigration?
    private var migrationCleanupWarning:String?
    private var removalCleanupWarning:String?
    private let historyWriterID=UUID()
    private var historyReadable = true
    private var history: AskConversationStore?
    private var historyTask: Task<Void, Never>?
    private var historyGeneration = UUID()
    private var acceptedAt: [UUID: UInt64] = [:]
    @Published private(set) var answerRevisions:[UUID:Int] = [:]
    private var pipelineTraces:[UUID:AskPipelineTrace] = [:]
    private var generation = UUID()
    private var task: Task<Void, Never>?
    private var activeID: UUID?
    private var recoveryTasks:[UUID:Task<Void,Never>]=[:]
    private var recoveryRequests:[UUID:AskRequest]=[:]
    private var recoveryResumeRequested=Set<UUID>()
    private var recoveryStore:AskTurnRecoveryStore? {(provider as? AskAgentProvider)?.recoveryStore}
    private var pendingActivityAt:Date?
    private var previousActivityBeforeRequest:Date?
    private let providerAttempts:AskProviderAttempts
    private var retryArchiveTickets:[UUID:AskProviderAttempts.ArchiveTicket]=[:]
    var activityNow:()->Date = Date.init
    var fieldStatus:((AskFieldActionState)throws->AskFieldActionState)?
    var fieldExecutor: ((AskFieldActionState,AskFieldActionMode) throws -> AskFieldActionState)?
    var refreshIndex:(()throws->AskLocalIndex)?
    var collectionExecutor:((UUID,Bool)throws->AskCollectionAction)?
    var collectionStatus:((UUID)throws->AskCollectionAction)?
    var historyDeletedRecordIDs:((UUID,[UUID])throws->Set<String>)?
    var collectionReceipts:((UUID)throws->[AskCollectionAction])?
    var collectionRecovery:((UUID)throws->[AskRecoveredActionTurn])?
    var collectionClear:((UUID)throws->Void)?
    private var provider: any AskFeastProvider
    private var index: AskLocalIndex
    init(index: AskLocalIndex, provider: any AskFeastProvider, providerAttempts:AskProviderAttempts = .shared) { self.index = index; self.provider = provider; self.providerAttempts=providerAttempts }
#if FEAST_TESTS
    convenience init(index: AskLocalIndex) { self.init(index: index, provider: MockAskFeastProvider()) }
#endif
    var response: AskResponse? { turns.last(where: { $0.response != nil })?.response }
    var providerLabel: String { provider.label }
    /// Hide only the identical error already attached to the latest turn, not
    /// unrelated current storage/admission errors after a historical failure.
    var composerError:String? {
        let current=error.flatMap {turns.last?.status == .failed($0) ? nil : $0}
        return composedError(current)
    }
    // History does not show the inline failed turn, so retain its existing
    // request error while also surfacing sticky history warnings.
    var historyError:String? {composedError(error)}
    private func composedError(_ current:String?)->String? {
        let messages=[historyWarning,current==historyWarning ? nil : current].compactMap {$0}
        return messages.isEmpty ? nil : messages.joined(separator:"\n")
    }
    private func combinedHistoryWarning(additional:String?=nil)->String? {
        // Historical loss needs its own visible explanation even when current
        // state is durable and an independent cleanup obligation remains.
        var seen=Set<String>()
        let messages=[history?.unsavedNotice,additional,history?.maintenanceWarning,migrationCleanupWarning,removalCleanupWarning].compactMap {$0}.filter {seen.insert($0).inserted}
        if !messages.isEmpty {return messages.joined(separator:"\n")}
        return history?.preservation == .pending ? "Your messages and draft are saved on this device in pending history. The regular history file is full or this draft exceeds its limits." : nil
    }
    var canDismissHistoryNotice:Bool {unsavedChatIDs.isEmpty && history?.unsavedNotice != nil}
    func dismissHistoryNotice() {
        guard canDismissHistoryNotice else{return}
        guard history?.acknowledgeUnsavedNotice()==true else {error="This history notice couldn’t be cleared. Saved history is unchanged.";return}
        historyWarning=combinedHistoryWarning()
    }
    private func admitNewTurn()->Bool {
        guard history == nil || turns.filter(\.isArchiveEligible).count < AskConversationSnapshot.maximumTurns else {
            error="This chat is full. Start a new chat to continue; its saved messages are unchanged."
            return false
        }
        return true
    }
    /// Activation changes transport only; keep the same chat, draft, findings and action journal.
    func replaceProviderWhenIdle(_ next:any AskFeastProvider)->Bool {
        guard !isLoading,recoveryTasks.isEmpty else{return false};provider=next;return true
    }
    func updateIndex(_ index: AskLocalIndex) { self.index = index }
    func presentedTurns()->[AskTurn] {
        let permitted=refreshIndex==nil ? index.historyAccessIDs : ((try? refreshIndex?())?.historyAccessIDs ?? [])
        return presented(turns,permitted:permitted)
    }
    private func presented(_ values:[AskTurn],permitted:Set<String>,forHistoryRows:Bool=false)->[AskTurn] {
        let legacy=values.compactMap(\.response).reduce(into:Set<String>()) {$0.formUnion(AskConversationProjection.dependencies($1))}
        return values.map {turn in
            var access=permitted
            if let historyDeletedRecordIDs,let deleted=try? historyDeletedRecordIDs(turn.id,(turn.response?.collectionActions ?? []).map(\.id)) {access.formUnion(deleted)}
            let projected=AskConversationProjection.presented(turn,permitted:access,legacyDependencies:legacy)
            // A private selection may carry an older independent-question marker.
            // History must not promote that request into a title/preview after
            // its source access is denied. Use the same fresh access and verified
            // deleted-record proof as the local projection; leave the transcript
            // and deliberately renamed titles unchanged.
            if forHistoryRows,let response=turn.response,
               response.agentTask?.privateSelection==true || response.libraryContext?.excludesExternalReferences==true,
               !AskConversationProjection.dependencies(response).isSubset(of:access) {
                return .init(id:projected.id,request:.init(mode:projected.request.mode,text:AskConversationProjection.omittedHuman,fromOCR:false),response:projected.response,sources:projected.sources,status:projected.status)
            }
            return projected
        }
    }
    func historyRows()->[AskChatHistoryRow] {
        let permitted=refreshIndex==nil ? index.historyAccessIDs : ((try? refreshIndex?())?.historyAccessIDs ?? [])
        return AskHistoryPresentation.ordered(chats).map {chat in
            let visible=presented(chat.conversation.turns.map(\.turn),permitted:permitted,forHistoryRows:true)
            // Classify automatic/manual title on the ORIGINAL archive. Projecting
            // its first question first would misclassify the old automatic title.
            let questions=Dictionary(uniqueKeysWithValues:visible.map {($0.id,$0.request.text)})
            let hiddenQuestion=chat.conversation.turns.first.map {questions[$0.id] != $0.question} ?? false
            let title=AskHistoryPresentation.title(chat,questionUnavailable:hiddenQuestion,presentedQuestion:visible.first?.request.text)
            return .init(id:chat.id,title:title,preview:AskHistoryPresentation.preview(chat,presentedResponse:visible.last?.response,presentedQuestions:questions),date:AskHistoryPresentation.date(chat))
        }
    }
    func presentedTurn(_ turn:AskTurn)->AskTurn {presentedTurns().first {$0.id==turn.id} ?? AskConversationProjection.presented(turn,permitted:[])}
    func source(_ id: String) -> AskSource? { presentedTurns().reversed().flatMap(\.sources).first { $0.id == id } }
    func runAutomatically() {
        let exactPublicReference = turns.last(where: { $0.status == .complete })?.response.map { ($0.referenceWebPlaces ?? $0.webPlaces).contains { $0.name.caseInsensitiveCompare(input.trimmingCharacters(in: .whitespacesAndNewlines)) == .orderedSame } } == true
        let resolved = exactPublicReference ? AskMode.discovery : AskIntentRouter.mode(for: input, fromOCR: fromOCR,
            previous: turns.last(where: { $0.status == .complete })?.readContextMode, override: sourceOverride)
        let wasOCR = fromOCR
        mode = resolved
        fromOCR = wasOCR
        run()
    }
    /// A correction appends a new answer while preserving the user's unsent draft.
    func answerAgain(_ id: UUID, using mode: AskMode) {
        guard !isLoading, let original = turns.first(where: { $0.id == id }),admitNewTurn() else { return }
        let request = AskRequest(mode: mode, text: original.request.text, fromOCR: mode == .importText && original.request.fromOCR)
        do { _ = try request.validated() } catch { self.error = error.localizedDescription; return }
        let turnID = UUID()
        turns.append(.init(id: turnID, request: request))
        start(id: turnID, request: request)
    }
    func chooseMapChoice(turnID:UUID,choiceID:String) {
        guard !isLoading,input.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty,
              let turn=turns.first(where:{$0.id==turnID}),let choices=turn.response?.mapChoices,
              let choice=choices.first(where:{$0.id==choiceID}) else{return}
        input="Use the Maps match "+choice.name+" at "+choice.address+" (choice "+choice.id+") to complete this request: "+turn.request.text
        run(selectedChoices:choices)
    }
    func run(selectedChoices:[AskMapChoice]?=nil) {
        guard !isLoading else { return }
        guard admitNewTurn() else{return}
        let completed = turns.last { $0.status == .complete && $0.readContextMode == mode }
        let namedPublicReference = completed?.response.map { ($0.referenceWebPlaces ?? $0.webPlaces).contains { $0.name.caseInsensitiveCompare(input.trimmingCharacters(in: .whitespacesAndNewlines)) == .orderedSame } } == true
        let followUp = AskQueryPlan.isFollowUp(input) || namedPublicReference
        let knownWeb = completed?.response?.referenceWebPlaces ?? completed?.response?.webPlaces ?? []
        let criterionText = knownWeb.sorted { $0.name.count > $1.name.count }.reduce(input) { $0.replacingOccurrences(of: $1.name, with: "", options: .caseInsensitive) }
        let supplemental=completed?.response.flatMap {$0.libraryContext == nil ? nil : $0.supplementalFindingIDs} ?? []
        let nonQueryReferences=Set(completed?.response?.answerMentionIDs ?? []).union(supplemental)
        let referenced = completed?.response?.paragraphs.flatMap(\.spans).compactMap { span -> String? in if case .place(let id) = span, !nonQueryReferences.contains(id) { return id }; return nil } ?? []
        let references = followUp ? Array(Set(referenced.isEmpty ? (completed?.response?.candidates.map(\.id) ?? []).filter {!nonQueryReferences.contains($0)} : referenced).sorted().prefix(6)) : []
        let priorContext = index.scope == .savedMetadata && mode == .discovery ? completed.flatMap { AskPublicCriteria.make($0.request.retrievalText)?.contextText } : completed?.request.text
        let previous = mode == .importText || (index.scope == .savedMetadata && !followUp) ? nil : priorContext
        let id = UUID()
        let request = AskRequest(mode: mode, text: input, fromOCR: fromOCR, previousQuestion: previous.map { String($0.prefix(2_000)) }, attachment: attachment, referencedIDs: references, referenceOnly: followUp && completed?.readContextMode == .collection, libraryContext: mode == .collection ? turns.last(where: { $0.status == .complete }).flatMap { $0.readContextMode == .collection ? $0.response?.libraryContext : nil } : nil, referencedWebPlaces: followUp && (namedPublicReference || !AskQueryPlan.hasNewPublicCriteria(criterionText)) ? Array((completed?.response?.referenceWebPlaces ?? completed?.response?.webPlaces ?? []).prefix(3)) : [], performanceID: id)
        var contextual=request
        contextual.conversationID=activeChatID
        contextual.dialogue=AskConversationProjection.messages(turns)
        contextual.collectionDialogue=AskConversationProjection.messages(turns,fullCollection:true)
        contextual.collectionHistory=AskConversationProjection.retainedMessages(turns)
        contextual.publicHistory=AskConversationProjection.publicRetainedMessages(turns)
        contextual.retainedChannelDependencies=AskConversationProjection.channelDependencies(turns)
        contextual.collectionContinuation=turns.last(where:{$0.status == .complete})?.response.flatMap {$0.collectionPage?.nextOffset != nil || $0.querySections?.contains(where:{$0.page?.nextOffset != nil})==true ? $0 : nil}
        contextual.collectionDialogueIDs=Array(Set(turns.compactMap(\.response).flatMap {($0.agentTask?.selectionIDs ?? $0.agentTask?.orderedIDs ?? [])+$0.candidates.map(\.id)}))
        contextual.pendingActions=Array(turns.compactMap(\.response).flatMap {$0.collectionActions ?? []}.filter {$0.state == .needsConfirmation}.suffix(24))
        contextual.recentQuestions=AskSemanticContext.recentQuestions(turns)
        contextual.agentTask=turns.last(where:{$0.status == .complete && $0.readContextMode == .collection})?.response?.agentTask
        let sectionTurn=turns.last(where:{$0.status == .complete}).flatMap {$0.readContextMode == .collection ? $0 : nil}
        contextual.referenceSections=sectionTurn?.response?.querySections
        contextual.referenceSectionsTurnID=sectionTurn?.id
        var findingKeys=Set<String>()
        var recentFindings:[AskVerifiedFinding]=[]
        let accepted=turns.filter {$0.status == .complete}.suffix(6)
        for prior in accepted.reversed() {
            for finding in (prior.response?.verifiedPublicFindings ?? [])+(prior.response?.fieldActions ?? []).map(\.finding) {
                guard finding.externallyReusable==true || (prior.response?.agentTask?.privateSelection != true && prior.response?.libraryContext?.excludesExternalReferences != true) else{continue}
                let key=finding.recordID+":"+finding.field
                if recentFindings.count < 24,findingKeys.insert(key).inserted {recentFindings.append(finding)}
            }
        }
        contextual.verifiedFindings=recentFindings
        contextual.publicResearch=Array(accepted.flatMap {$0.response?.publicResearch ?? []}.uniquedResearch().suffix(4))
        contextual.mapChoices=selectedChoices ?? Array(accepted.reversed().compactMap {$0.response?.mapChoices}.first ?? [])
        let extras=AskConversationProjection.channelMessages(contextual)
        contextual.dialogue += extras.map(\.message)
        contextual.collectionDialogue += extras.map(\.message)
        contextual.collectionDialogue=Array(contextual.collectionDialogue.suffix(200))
        contextual.dialogue=Array(contextual.dialogue.suffix(200))
        do { _ = try contextual.validated() } catch { self.error = error.localizedDescription; return }
        turns.append(.init(id:id,request:contextual))
        previousActivityBeforeRequest=pendingActivityAt
        markConversationActivity()
        input = ""; attachment = nil
        start(id:id,request:contextual)
    }
    func retry(_ id: UUID) {
        // Reconcile the exact durable step, never create a fresh paid attempt.
        if let recoveryStore,let saved=try? recoveryStore.checkpoint(id) {
            if saved.resumable {restorePendingRecovery()}else{error=saved.failure ?? AskRecoveryError.stopped.localizedDescription}
            return
        }
        guard !isLoading, canRetry[id] != false, let turn = turns.first(where: { $0.id == id }), turn.status != .complete else { return }
        do {if let receipts=try collectionReceipts?(id),!receipts.isEmpty {error=AskRetryError.mutations.localizedDescription;return}}catch {self.error=AskRetryError.unverified.localizedDescription;return}
        if !(turn.response?.collectionActions ?? []).isEmpty || (turn.response?.fieldActions ?? []).contains(where:{$0.outcome == .saved}) {error=AskRetryError.mutations.localizedDescription;return}
        var request=turn.request
        if let position=turns.firstIndex(where:{$0.id==id}) {request.dialogue=AskConversationProjection.messages(Array(turns.prefix(position)));request.collectionDialogue=AskConversationProjection.messages(Array(turns.prefix(position)),fullCollection:true);request.collectionHistory=AskConversationProjection.retainedMessages(Array(turns.prefix(position)));request.publicHistory=AskConversationProjection.publicRetainedMessages(Array(turns.prefix(position)))}
        request.performanceID=id;request.providerRetry=true;request.conversationID=activeChatID
        request.retainedChannelDependencies=AskConversationProjection.channelDependencies(turns)
        if let response=turn.response {
            request.publicResearch=response.publicResearch ?? request.publicResearch
            request.verifiedFindings=response.verifiedPublicFindings ?? request.verifiedFindings
            request.agentTask=response.agentTask ?? request.agentTask
            request.pendingActions=response.collectionActions ?? request.pendingActions
            request.mapChoices=response.mapChoices ?? request.mapChoices
        }
        start(id: id, request: request)
    }
    private func validateRetryAfterFence(_ id:UUID,token:UUID)throws {
        try Task.checkCancellation()
        guard generation==token,activeID==id,isLoading else{throw CancellationError()}
        do {if let receipts=try collectionReceipts?(id),!receipts.isEmpty {throw AskRetryError.mutations}}
        catch let error as AskRetryError {throw error}
        catch {throw AskRetryError.unverified}
        guard let turn=turns.first(where:{$0.id==id}) else{throw CancellationError()}
        if !(turn.response?.collectionActions ?? []).isEmpty || (turn.response?.fieldActions ?? []).contains(where:{$0.outcome == .saved}) {throw AskRetryError.mutations}
    }
    private func start(id: UUID, request original: AskRequest) {
        retryArchiveTickets.removeValue(forKey:id)
        var request=original
        if recoveryStore != nil {request.performanceID=id;if request.conversationID==nil {request.conversationID=activeChatID}}
        let startedAt = DispatchTime.now().uptimeNanoseconds
        let trace=AskPipelineTrace(id:UUID(),turnID:id)
        if pipelineTraces.count>=20 {pipelineTraces.removeAll()}
        pipelineTraces[id]=trace
        let visible=request.conversationID==nil || request.conversationID==activeChatID
        if visible {generation = UUID()}; let token = generation
        if visible {activeID = id; isLoading = true; error = nil; canRetry[id] = true}
        scheduleHistory()
        setStatus(id, .loading)
        let tools: AskReadTools
        do { tools = try AskReadTools(request: request, index: index) }
        catch { trace.finish(.failed);trace.elapsed(.taskExit,since:startedAt);Task {await AskPerformanceRecorder.shared.recordPipeline(trace.snapshot())};setStatus(id, .failed(error.localizedDescription)); self.error = error.localizedDescription; isLoading = false; activeID = nil; refreshActiveRecoveryTask(); return }
        trace.elapsed(.preparation,since:startedAt)
        if recoveryStore != nil {recoveryRequests[id]=request}
        let work = Task { [weak self, provider, providerAttempts] in
            var reconcileAfterExit=false
            defer {
                self?.finishRecoveryTask(id)
                if reconcileAfterExit,self?.recoveryStore?.active==true {self?.restorePendingRecovery()}
            }
            defer {if trace.snapshot().outcome == .running {trace.finish(Task.isCancelled ? .cancelled : .failed)};trace.elapsed(.taskExit,since:startedAt);Task {await AskPerformanceRecorder.shared.recordPipeline(trace.snapshot())}}
            do {
                let result = try await AskProviderAttemptScope.$store.withValue(providerAttempts) {
                    try await AskProviderAttemptScope.$validateExplicitRetry.withValue({ [weak self] in
                        guard let self else{throw CancellationError()}
                        try await self.validateRetryAfterFence(id,token:token)
                    }) {
                        try await AskPipelineScope.$trace.withValue(trace) {try await provider.answer(request, tools: tools)}
                    }
                }
                let retryTicket=try? await providerAttempts.archiveTicket(turn:id)
                try Task.checkCancellation()
                if let self,let recoveryStore=self.recoveryStore {
                    while !recoveryStore.active {try await Task.sleep(nanoseconds:100_000_000);try Task.checkCancellation()}
                    if let saved=try recoveryStore.checkpoint(id) {
                        guard saved.resumable else{throw AskRecoveryError.stopped}
                        guard recoveryAccessIsCurrent(saved) else{throw AskHostedError.selectionUnavailable}
                    }
                }
                let validationStarted = DispatchTime.now().uptimeNanoseconds
                let currentTools:AskReadTools
                var checked:AskResponse
                do {
                    // Failed final checks must be observable too, without retaining
                    // the rejected content or changing acceptance/error behavior.
                    defer {trace.elapsed(.validation,since:validationStarted)}
                    do {
                        if let fresh=try self?.refreshIndex?() {self?.index=fresh;currentTools=try AskReadTools(request:request,index:fresh)}else{currentTools=tools}
                    }catch {trace.rejectAnswer(.catalogRefresh);throw error}
                    checked = try currentTools.checked(currentTools.rebasedCatalogResponse(result),validationTrace:trace)
                    if let self {checked.fieldActions=checked.fieldActions?.map {self.currentFieldAction($0)};checked=self.currentCollectionActions(checked)}
                }
                let validationMS = AskPerformanceRecorder.milliseconds(since: validationStarted)
                guard let self else{return}
                if recoveryStore != nil,let origin=request.conversationID,origin != activeChatID {
                    let sources=(checked.candidates.flatMap(\.sourceIDs)+checked.paragraphs.flatMap(\.sourceIDs)).reduce(into:[AskSource]()) {all,id in if !all.contains(where:{$0.id==id}),let source=currentTools.source(id) {all.append(source)}}
                    if archiveRecovered(.init(id:id,request:request,response:checked,sources:sources,status:.complete),chat:origin) {try? recoveryStore?.removeCompleted(id)}
                    trace.finish(.completed);return
                }
                guard generation == token || recoveryRequests[id] != nil,let position=turns.firstIndex(where:{$0.id==id}) else{return}
                if let retryTicket {retryArchiveTickets[id]=retryTicket}
                turns[position].response = checked
                if checked.requestsFieldSave == true {
                    for action in checked.fieldActions ?? [] { self.applyFieldAction(turn:id,findingID:action.finding.id,mode:.save,allowLoading:true) }
                }
                turns[position].sources = (checked.candidates.flatMap(\.sourceIDs) + checked.paragraphs.flatMap(\.sourceIDs)).reduce(into: [AskSource]()) { result, id in
                    if !result.contains(where: { $0.id == id }), let source = currentTools.source(id) { result.append(source) }
                }
                turns[position].status = .complete; isLoading = false; activeID = nil
                if fallbackDraftTurnID==id {input=""}
                finishRecoveryTask(id)
                markConversationActivity()
                acceptedAt[id] = DispatchTime.now().uptimeNanoseconds
                answerRevisions[id,default:0]+=1
                trace.elapsed(.answerAvailable,since:startedAt);trace.finish(.completed)
                scheduleHistory(trace:trace)
                if recoveryStore != nil,flushCurrentChat() {try? recoveryStore?.removeCompleted(id)}
                await AskPerformanceRecorder.shared.record(.validation, milliseconds: validationMS, traceID: id)
                await AskPerformanceRecorder.shared.record(.overall, milliseconds: AskPerformanceRecorder.milliseconds(since: startedAt), traceID: id)
            } catch AskHostedError.consentRequired {
                if let self,let store=recoveryStore,(try? store.checkpoint(id)) != nil {
                    try? store.stop(id)
                    if request.conversationID==activeChatID {setStatus(id,.stopped);isLoading=false;activeID=nil;flushHistory()}
                    return
                }
                // Nothing was sent. Restore the draft instead of an error/retry turn.
                guard let self, generation == token, !Task.isCancelled else { return }
                turns.removeAll { $0.id == id }
                pendingActivityAt=previousActivityBeforeRequest
                if input.isEmpty { input = request.text; mode = request.mode; fromOCR = request.fromOCR }
                if attachment == nil { attachment = request.attachment }
                self.error = nil; isLoading = false; activeID = nil
                if !AskPrivacy.onlineAllowed { needsOnlineConsent = true;consentTicket = UUID() }
                else { self.error = "This request couldn’t be sent with the permitted details." }
                scheduleHistory()
            } catch is CancellationError { }
            catch {
                let retryTicket=try? await providerAttempts.archiveTicket(turn:id)
                guard let self,!Task.isCancelled else{return}
                if let recoveryStore,let saved=try? recoveryStore.checkpoint(id) {
                    // A foreground event may precede the suspended transport's
                    // delayed failure. Reconcile once, without a retry loop.
                    let resumedWhileRunning=recoveryResumeRequested.remove(id) != nil
                    reconcileAfterExit=resumedWhileRunning && recoveryStore.active && saved.phase == .awaitingReply && error is URLError
                    let message=saved.phase == .executingTool ? AskRecoveryError.localStepUncertain.localizedDescription : error.localizedDescription
                    let retained=recoveryInterruptedResponse(saved,message:message)
                    var stopped=saved
                    if saved.phase == .executingTool || error is AskHostedError || (error as? AskRecoveryError) == .expired || (error as? AskRecoveryError) == .unavailable {
                        stopped.phase = .blocked;stopped.failure=message;stopped.finalResponse=retained;try? recoveryStore.save(stopped)
                    }
                    if request.conversationID==activeChatID {
                        if let i=turns.firstIndex(where:{$0.id==id}) {turns[i].response=retained}
                        setStatus(id,.failed(message));self.error=message;isLoading=false;activeID=nil;canRetry[id]=false;finishRecoveryTask(id);flushHistory()
                    }else if let origin=request.conversationID {
                        _ = archiveRecovered(.init(id:id,request:request,response:retained,sources:[],status:.failed(message)),chat:origin)
                    }
                    return
                }
                if recoveryStore != nil,let origin=request.conversationID,origin != activeChatID {
                    _ = archiveRecovered(.init(id:id,request:request,response:nil,sources:[],status:.failed(error.localizedDescription)),chat:origin);return
                }
                guard generation == token else{return}
                if let retryTicket {retryArchiveTickets[id]=retryTicket}
                canRetry[id] = (error as? AskConversationFailure)?.retryable ?? (error as? AskHostedError)?.retryable ?? (error as? AskRetryError)?.retryable ?? true
                let message = AskHostedError.message(for: error)
                setStatus(id, .failed(message)); self.error = message
                markConversationActivity()
                scheduleHistory()
                isLoading = false; activeID = nil
                finishRecoveryTask(id)
            }
        }
        if visible {task=work}
        if recoveryStore != nil {recoveryTasks[id]=work}
    }
    private func currentCollectionActions(_ original:AskResponse)->AskResponse {
        guard let collectionStatus,var actions=original.collectionActions else{return original}
        for i in actions.indices {
            if let current=try? collectionStatus(actions[i].id) {actions[i]=current}else{actions[i].state = .unavailable;actions[i].undoable=false}
        }
        var response=original;response.collectionActions=actions;response.refreshCollectionReviewStatus();return response
    }
    private func currentFieldAction(_ action:AskFieldActionState)->AskFieldActionState {
        guard let fieldStatus else{return action}
        do {return try fieldStatus(action)}catch {var failed=action;failed.outcome = .unavailable;return failed}
    }
    private func refreshFieldActions() {
        for i in turns.indices {guard var response=turns[i].response,let actions=response.fieldActions else{continue};response.fieldActions=actions.map {currentFieldAction($0)};turns[i].response=response}
    }
    func applyCollectionAction(turn:UUID,actionID:UUID,undo:Bool) {
        guard !isLoading,let position=turns.firstIndex(where:{$0.id==turn}),turns[position].response?.collectionActions?.contains(where:{$0.id==actionID})==true,let collectionExecutor else {return}
        do {
            let previous=turns[position].response?.collectionActions?.first {$0.id==actionID}
            let updated=try collectionExecutor(actionID,undo)
            for i in turns.indices {guard var response=turns[i].response,var actions=response.collectionActions else {continue};for j in actions.indices where actions[j].id==actionID {actions[j]=updated};response.undoFailures?.removeValue(forKey:actionID.uuidString);response.collectionActions=actions;response.refreshCollectionReviewStatus();turns[i].response=response}
            if previous != updated {markConversationActivity()}
            error=nil;refreshFieldActions();scheduleHistory()
        } catch {
            self.error=error.localizedDescription
            if undo {
                let code:String
                if case AskChangeError.conflict=error {code="newer_edit"}else{code="unavailable"}
                let previous=turns[position].response?.undoFailures?[actionID.uuidString]
                for i in turns.indices where turns[i].response?.collectionActions?.contains(where:{$0.id==actionID})==true {
                    if turns[i].response?.undoFailures==nil {turns[i].response?.undoFailures=[:]}
                    turns[i].response?.undoFailures?[actionID.uuidString]=code
                }
                if previous != code {markConversationActivity()}
                scheduleHistory()
            }
        }
    }
    /// Best-effort reversal of this displayed operation, never an atomic promise.
    func undoCollectionOperation(turn:UUID,actionIDs:[UUID]) {
        guard !isLoading else{return}
        for id in actionIDs.reversed() {
            guard turns.first(where:{$0.id==turn})?.response?.collectionActions?.contains(where:{$0.id==id && $0.state == .applied && $0.undoable})==true else{continue}
            applyCollectionAction(turn:turn,actionID:id,undo:true)
            if error != nil {break}
        }
    }
    func applyFieldAction(turn:UUID,findingID:UUID,mode:AskFieldActionMode,allowLoading:Bool=false) {
        guard (!isLoading || allowLoading),let position=turns.firstIndex(where:{$0.id==turn}),var response=turns[position].response,
              var actions=response.fieldActions,let i=actions.firstIndex(where:{$0.finding.id==findingID}),let fieldExecutor else {return}
        let existing=turns.compactMap(\.response).flatMap {$0.fieldActions ?? []}.first {$0.finding.id==findingID && $0.outcome == .saved}
        if mode == .save,let existing {actions[i]=existing}
        let before=actions[i]
        do {actions[i]=try fieldExecutor(actions[i],mode);self.error=nil} catch {
            if mode != .undo {actions[i].outcome = .failed} else {self.error="Couldn’t undo. Try again."}
        }
        response.fieldActions=actions;response.requestsFieldSave=false
        if before != actions[i] {markConversationActivity()}
        turns[position].response=response
        let updated=actions[i]
        for n in turns.indices where n != position {
            guard var other=turns[n].response,var shared=other.fieldActions else {continue}
            for j in shared.indices where shared[j].finding.id == findingID {shared[j]=updated}
            other.fieldActions=shared;turns[n].response=other
        }
        refreshFieldActions();scheduleHistory()
    }
    private func setStatus(_ id: UUID, _ status: AskTurnStatus) {
        if let position = turns.firstIndex(where: { $0.id == id }) { turns[position].status = status }
    }
    func cancel(userInitiated:Bool=true) {
        if !userInitiated,recoveryStore != nil {flushHistory();return}
        if let activeID,let recoveryStore {
            do {try recoveryStore.stop(activeID)}catch {self.error=error.localizedDescription}
            recoveryTasks[activeID]?.cancel();recoveryTasks.removeValue(forKey:activeID);recoveryRequests.removeValue(forKey:activeID);canRetry[activeID]=false
            cancelRecoveryJob(activeID)
        }
        needsOnlineConsent = false;consentTicket = nil
        generation = UUID(); task?.cancel(); task = nil
        if let activeID {
            if let receipts=try? collectionReceipts?(activeID),!receipts.isEmpty,let position=turns.firstIndex(where:{$0.id==activeID}) {
                turns[position].response=actionReceiptResponse(receipts)
                setStatus(activeID,.complete)
            }else {
                if let position=turns.firstIndex(where:{$0.id==activeID}) {turns[position].wasInterrupted = !userInitiated}
                setStatus(activeID,.stopped)
            }
            if userInitiated {markConversationActivity()}
        }
        if let id=activeID,let trace=pipelineTraces[id] {trace.elapsed(.stopRequested,since:trace.started);trace.finish(.cancelled)}
        activeID = nil; isLoading = false
        scheduleHistory()
        if recoveryStore != nil {refreshActiveRecoveryTask();flushHistory()}
    }
    var progressLabel: String {
        // Buffered server responses do not expose a truthful live research phase.
        // Never infer “searching” from the question or claim a saved-only operation.
        "Thinking..."
    }
    func markRendered(_ id: UUID) {
        guard let started = acceptedAt.removeValue(forKey: id) else { return }
        if let trace=pipelineTraces[id] {
            trace.elapsed(.answerViewObserved,since:trace.started)
            Task {await AskPerformanceRecorder.shared.recordPipeline(trace.snapshot())}
        }
        let duration = AskPerformanceRecorder.milliseconds(since: started)
        Task { await AskPerformanceRecorder.shared.record(.render, milliseconds: duration, traceID: id) }
    }
    func clearConversation() {
        let oldID=activeChatID,removed=Array(Set(turns.map(\.id)+(chats.first(where:{$0.id==oldID})?.conversation.turns.map(\.id) ?? [])))
        var next=currentChatSnapshot()
        let replacement:AskChatArchive
        if let i=next.firstIndex(where:{$0.id==oldID}) {
            let old=next[i]
            replacement = .init(id:UUID(),title:old.title,updatedAt:old.updatedAt,conversation:.init(),lastActivityAt:old.lastActivityAt,hasCustomTitle:old.hasCustomTitle)
            next[i]=replacement
        } else {replacement = .init(id:UUID(),title:"New chat",updatedAt:Date(),conversation:.init());next=[replacement]}
        // No cancel/stop before commit: stopping can scrub a recovery checkpoint.
        // A new durable chat identity is the bounded clear/recovery barrier.
        guard commitChats(next,active:replacement.id,removing:[oldID]) else{return}
        if interruptHistoryDestruction("clear-committed") {return}
        historyTask?.cancel();historyGeneration=UUID();generation=UUID();task?.cancel();task=nil;activeID=nil;isLoading=false
        volatileScreens.removeValue(forKey:oldID)
        resetScreen(replacement.conversation);cleanupMigration(oldID)
        cleanupRemovedChat(oldID,turns:removed)
    }
    private func actionReceiptResponse(_ actions:[AskCollectionAction])->AskResponse {
        let text="Changes recorded before this request stopped."
        return .init(summary:text,candidates:[],paragraphs:[.init(id:"action-recovery",spans:[.text(text)],sourceIDs:[],operationStatus:true)],listedCandidateIDs:[],usesLocalCatalog:true,agentTask:.init(action:"change",fields:[],orderedIDs:actions.flatMap(\.targetIDs),sourcePolicy:"local_only"),collectionActions:actions,executionStatus:"stopped")
    }
    private func resetScreen(_ value:AskConversationSnapshot) {
        // The old screen's timestamp was captured with its snapshot. It must
        // never be applied by a later draft-only save of the selected chat.
        pendingActivityAt=nil
        if recoveryStore != nil {activeID=nil;isLoading=false;task=nil}
        let retained=volatileScreens[activeChatID]
        let encoder=JSONEncoder();encoder.outputFormatting = .sortedKeys
        let matches=retained.map {(try? encoder.encode($0.turns.filter(\.isArchiveEligible).map(AskArchivedTurn.init))) == (try? encoder.encode(value.turns))} ?? false
        turns = matches ? retained!.turns : value.turns.map { $0.turn }; acceptedAt = [:]; input = value.draft;fallbackDraftTurnID=value.fallbackDraftTurnID
        if let collectionStatus {for i in turns.indices {guard var response=turns[i].response,var actions=response.collectionActions else{continue};for j in actions.indices {if let current=try? collectionStatus(actions[j].id) {actions[j]=current}else {actions[j].state = .unavailable;actions[j].undoable=false}};response.collectionActions=actions;response.refreshCollectionReviewStatus();turns[i].response=response}}
        if let fieldStatus {for i in turns.indices {guard var response=turns[i].response,let actions=response.fieldActions else{continue};response.fieldActions=actions.map {currentFieldAction($0)};turns[i].response=response}}
        if let recovered=try? collectionRecovery?(activeChatID) {
            for item in recovered where !turns.contains(where:{$0.id==item.id}) {
                turns.append(.init(id:item.id,request:.init(mode:.collection,text:item.question,fromOCR:false),response:actionReceiptResponse(item.actions),sources:[],status:.complete))
                if fallbackDraftTurnID==item.id,input==item.question {input=""}
            }
        }
        attachment = nil; canRetry = matches ? retained!.canRetry : [:]; error = nil; needsOnlineConsent = false
        mode = .collection; sourceOverride = nil; fromOCR = false
        restorePendingRecovery()
    }
    func restoreHistory(from store: AskConversationStore) {
        guard history == nil else { return }
        history = store
        do {
            let library = try store.loadLibrary(forSession:historyWriterID)
            chats = library.chats; activeChatID = library.activeID;historyMigration = library.migration
            historyWarning=combinedHistoryWarning()
            resetScreen(chats.first { $0.id == activeChatID }!.conversation)
            // An absent migrated ID in the committed library is the prior
            // explicit removal barrier, not permission to delete changed bytes.
            if let migration=historyMigration,!chats.contains(where:{$0.id==migration.chatID}) {cleanupMigration(migration.chatID)}
        } catch { historyReadable = false; self.error = error.localizedDescription }
    }
    /// True means the exact whole candidate is durable, never merely navigable.
    private func commitChats(_ proposed:[AskChatArchive], active:UUID,allowVolatile:Bool=false,removing:Set<UUID>=[],changedChatIDs:Set<UUID>=[]) -> Bool {
        guard historyReadable else {error=AskHistoryError.unreadable.localizedDescription;return false}
        guard (1...50).contains(proposed.count),proposed.contains(where:{$0.id==active}) else {error=AskHistoryError.limit.localizedDescription;return false}
        let outcome=history?.preserveLibrary(.init(activeID:active,chats:proposed,migration:historyMigration),removingChatIDs:removing,session:historyWriterID) ?? .canonical
        if outcome == .unsaved {
            // Recovery can finish in a nonselected chat while this candidate
            // also captures newer edits on the visible screen.
            unsavedChatIDs.formUnion(changedChatIDs.union([activeChatID,active]))
            let count=proposed.filter {unsavedChatIDs.contains($0.id)}.count
            var current="Changes in "+(count==1 ? "this chat are" : "\(max(count,1)) chats are")+" not saved. Keep the app open; you can return to them in History."
            if let unresolved=history?.unresolvedRemovalWarning {current=unresolved+" "+current}
            historyWarning=combinedHistoryWarning(additional:current)
            error=historyWarning
            guard allowVolatile else{return false}
            volatileScreens[activeChatID] = .init(turns:turns,canRetry:canRetry)
        } else {
            if error==historyWarning {error=nil}
            unsavedChatIDs=[]
            historyWarning=combinedHistoryWarning()
        }
        chats=proposed;activeChatID=active
        if outcome != .unsaved,!retryArchiveTickets.isEmpty,let history,let verified=try? durableRetryArchive(history) {
            for turn in verified.chats.flatMap({$0.conversation.turns}) {
                guard let ticket=retryArchiveTickets[turn.id],proposed.contains(where:{$0.conversation.turns.contains(where:{$0.id==turn.id && $0.response==turn.response})}) else{continue}
                Task { [weak self,providerAttempts] in
                    if (try? await providerAttempts.archiveCommitted(ticket,response:turn.response))==true,self?.retryArchiveTickets[turn.id]==ticket {self?.retryArchiveTickets.removeValue(forKey:turn.id)}
                }
            }
        }
        return outcome != .unsaved
    }
    private func durableRetryArchive(_ history:AskConversationStore)throws->AskChatLibrary {try history.durableLibrary()}
    private func deleteRetryContexts(_ turns:[UUID]) {
        providerAttempts.markDeleted(turns)
        for id in turns {retryArchiveTickets.removeValue(forKey:id)}
        Task { [weak self,providerAttempts] in
            do {try await providerAttempts.delete(turns)}
            catch {self?.error="The chat was deleted, but some local retry context couldn’t be cleared. Its attempts remain blocked."}
        }
    }
    private func prepareNavigation() {
        if recoveryStore==nil {
            if input.isEmpty,let activeID,let turn=turns.first(where:{$0.id==activeID}) {input=turn.request.text}
            cancel(userInitiated:false)
        }
        historyTask?.cancel()
    }
    @discardableResult func newChat() -> Bool {
        prepareNavigation()
        guard historyReadable else{return false}
        guard chats.count<50 else {_ = flushCurrentChat();error=AskHistoryError.limit.localizedDescription;return false}
        let chat=AskChatArchive(id:UUID(),title:"New chat",updatedAt:Date(),conversation:.init())
        // Current screen and selection move form one exact whole-library commit.
        _ = commitChats(currentChatSnapshot()+[chat],active:chat.id,allowVolatile:true)
        guard activeChatID==chat.id else{return false}
        historyGeneration=UUID();resetScreen(chat.conversation);return true
    }
    @discardableResult func openChat(_ id:UUID) -> Bool {
        guard id != activeChatID,chats.contains(where:{$0.id==id}) else{return false}
        prepareNavigation();_ = commitChats(currentChatSnapshot(),active:id,allowVolatile:true)
        guard activeChatID==id else{return false}
        historyGeneration=UUID();resetScreen(chats.first {$0.id==id}!.conversation);restorePendingRecovery(activityResume:true);return true
    }
    @discardableResult func renameChat(_ id:UUID,to name:String) -> Bool {
        let title = name.trimmingCharacters(in:.whitespacesAndNewlines)
        guard !title.isEmpty,title.count <= 80 else { error = "Use a chat name of 1–80 characters.";return false }
        guard flushCurrentChat(),let position = chats.firstIndex(where:{$0.id == id}) else { return false }
        var next = chats;next[position].title = title;next[position].hasCustomTitle = true
        return commitChats(next,active:activeChatID)
    }
    @discardableResult func deleteChat(_ id:UUID) -> Bool {
        guard let removedChat=chats.first(where:{$0.id==id}) else{return false}
        let wasActive=id==activeChatID,removed=Array(Set(removedChat.conversation.turns.map(\.id)+(wasActive ? turns.map(\.id) : [])))
        var next=currentChatSnapshot().filter {$0.id != id}
        if next.isEmpty {next=AskChatLibrary.empty().chats}
        let active=wasActive ? next[0].id : activeChatID
        guard commitChats(next,active:active,removing:[id]) else{return false}
        if interruptHistoryDestruction("delete-committed") {return true}
        historyTask?.cancel();historyGeneration=UUID()
        if wasActive {generation=UUID();task?.cancel();task=nil;activeID=nil;isLoading=false}
        volatileScreens.removeValue(forKey:id)
        if wasActive {resetScreen(next.first {$0.id==active}!.conversation)}
        cleanupMigration(id)
        cleanupRemovedChat(id,turns:removed)
        return true
    }
    private func cleanupRemovedChat(_ id:UUID,turns:[UUID]) {
        // Membership was already durably removed. Cleanup failure cannot restore
        // old work into the replacement chat, and must not erase new-chat data.
        if interruptHistoryDestruction("before-recovery-cleanup") {return}
        // A nonactive chat can own an unarchived running turn. Capture its exact
        // identities before stop/delete removes the recovery-to-chat binding.
        var removed=Set(turns)
        removed.formUnion(recoveryRequests.filter {$0.value.conversationID==id}.map(\.key))
        if let recoveryStore {
            do {removed.formUnion(try recoveryStore.checkpoints(chat:id).map(\.turnID))}
            catch {recordRemovalCleanupFailure()}
        }
        do {try stopRecoveryChat(id)}catch {recordRemovalCleanupFailure()}
        if interruptHistoryDestruction("before-journal-cleanup") {return}
        do {try collectionClear?(id)}catch {recordRemovalCleanupFailure()}
        if interruptHistoryDestruction("before-retry-cleanup") {return}
        deleteRetryContexts(Array(removed))
    }
    private func recordRemovalCleanupFailure() {
        // Later saves verify current history, not the removed chat's separate
        // recovery/journal cleanup. Keep this live-session warning visible.
        removalCleanupWarning="The chat was removed, but some older local recovery data couldn’t be cleared."
        historyWarning=combinedHistoryWarning()
    }
    private func cleanupMigration(_ id:UUID) {
        guard let migration=historyMigration,migration.chatID==id,let history else{return}
        if history.removeMigrationCopy(migration) {historyMigration=nil;migrationCleanupWarning=nil;_ = commitChats(currentChatSnapshot(),active:activeChatID,allowVolatile:true)}
        else {migrationCleanupWarning="The chat was removed, but its changed or unreadable migration backup was kept.";historyWarning=combinedHistoryWarning()}
    }
    func dismissConsent() { needsOnlineConsent = false;consentTicket = nil }
    func prepareConsentSend() -> UUID? {
        guard needsOnlineConsent,let consentTicket else { return nil }
        needsOnlineConsent = false;return consentTicket
    }
    func resumeAfterConsent(_ ticket:UUID) {
        guard consentTicket == ticket,!isLoading,AskPrivacy.onlineAllowed else { return }
        consentTicket = nil
        if attachment != nil { mode = .collection;run() } else { runAutomatically() }
    }
    private func snapshot() -> AskConversationSnapshot {
        let completed = turns.filter(\.isArchiveEligible).map(AskArchivedTurn.init)
        let interrupted = turns.last(where: { $0.status == .loading && (try? recoveryStore?.checkpoint($0.id)) == nil })
        let fallback=input.isEmpty ? interrupted?.id : fallbackDraftTurnID
        return .init(version: 1, draft: input.isEmpty ? interrupted?.request.text ?? "" : input, turns: completed,fallbackDraftTurnID:fallback)
    }
    private func scheduleHistory(trace:AskPipelineTrace? = nil) {
        guard history != nil else { return }
        let trace=trace ?? activeID.flatMap {pipelineTraces[$0]}
        historyTask?.cancel(); let token = historyGeneration
        historyTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 300_000_000)
            guard !Task.isCancelled, let self, historyGeneration == token else { return }
            AskPipelineScope.$trace.withValue(trace) {self.flushHistory()}
            if let trace {Task {await AskPerformanceRecorder.shared.recordPipeline(trace.snapshot())}}
        }
    }
    private func currentChatSnapshot() -> [AskChatArchive] {
        var next = chats
        if let position = next.firstIndex(where:{$0.id == activeChatID}) {
            next[position].conversation = snapshot()
            if let pendingActivityAt {next[position].lastActivityAt=pendingActivityAt;next[position].updatedAt=pendingActivityAt}
            if next[position].hasCustomTitle != true,next[position].title == "New chat",let first = next[position].conversation.turns.first,
               !first.question.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty {
                next[position].title = String(first.question.prefix(80))
            }
        }
        return next
    }
    @discardableResult private func flushCurrentChat() -> Bool {
        guard history != nil else { return true }
        let saved=commitChats(currentChatSnapshot(),active:activeChatID,allowVolatile:true)
        if saved {pendingActivityAt=nil}
        return saved
    }
    private func markConversationActivity() {pendingActivityAt=activityNow()}
    func flushHistory() { historyTask?.cancel(); _ = flushCurrentChat() }
    func suspend() {
        if recoveryStore != nil {flushHistory();return}
        if input.isEmpty, let activeID, let turn = turns.first(where: { $0.id == activeID }) { input = turn.request.text }
        cancel(userInitiated:false); flushHistory()
    }
    private func refreshActiveRecoveryTask() {
        guard recoveryStore != nil else{return}
        // Multiple accepted turns may reconnect together. Completion of one
        // must not hide Stop or enable edits while another visible turn runs.
        let remaining=turns.reversed().first {turn in recoveryRequests[turn.id]?.conversationID==activeChatID && recoveryTasks[turn.id] != nil}
        activeID=remaining?.id;isLoading=remaining != nil;task=remaining.flatMap {recoveryTasks[$0.id]}
    }
    private func finishRecoveryTask(_ id:UUID) {
        recoveryResumeRequested.remove(id)
        guard recoveryRequests.removeValue(forKey:id) != nil else{return}
        recoveryTasks.removeValue(forKey:id)
        refreshActiveRecoveryTask()
    }
    private func recoveryAccessIsCurrent(_ saved:AskTurnCheckpoint)->Bool {
        guard let agent=provider as? AskAgentProvider,let researcher=agent.remote as? any AskBusinessResearching else{return false}
        let verifier=AskAgentExecutor(adapter:agent.adapter,engine:agent.engine,request:saved.executorRequest ?? saved.request,researcher:researcher,searchMaps:{_ in []})
        guard let permitted=try? verifier.permittedRecordIDs(),let deleted=try? agent.engine.recoveryDeletedRecordIDs(forTurn:saved.turnID,includingActionIDs:Set((saved.state.durableActions+(saved.finalResponse?.collectionActions ?? [])).map(\.id))) else{return false}
        let external=Set((saved.request.mapChoices+(saved.state.latest?.mapChoices ?? [])+(saved.finalResponse?.mapChoices ?? [])).map(\.id))
        let references=Set((saved.context?.index.map(\.id) ?? [])+saved.retainedRecordIDs+Array(saved.state.available.keys)+saved.state.ordered+saved.cities.map(\.id)).subtracting(external)
        return references.isSubset(of:permitted.union(deleted))
    }
    private func recoveryInterruptedResponse(_ saved:AskTurnCheckpoint,message:String)->AskResponse? {
        // Error presentation is also a read. Never expose retained private
        // results if sharing access changed while the request was away.
        guard recoveryAccessIsCurrent(saved) else{return nil}
        var response=saved.finalResponse ?? saved.state.latest
        var actions=saved.state.durableActions
        for action in (try? collectionReceipts?(saved.turnID)) ?? [] {
            if let i=actions.firstIndex(where:{$0.id==action.id}) {actions[i]=action}else{actions.append(action)}
        }
        if response==nil,!actions.isEmpty {response=actionReceiptResponse(actions)}
        if response==nil,!saved.state.publicResearch.isEmpty {response = .init(summary:"Earlier research was kept.",candidates:[],listedCandidateIDs:[],usesLocalCatalog:true)}
        guard var retained=response else{return nil}
        if !actions.isEmpty {retained.collectionActions=actions}
        if !saved.state.publicResearch.isEmpty {retained.publicResearch=saved.state.publicResearch}
        if !saved.state.operationRecords.isEmpty {retained.operationRecords=saved.state.operationRecords}
        retained.paragraphs.removeAll {$0.id=="recovery-interrupted"}
        retained.paragraphs.append(.init(id:"recovery-interrupted",spans:[.text(message)],sourceIDs:[],operationStatus:true))
        retained=currentCollectionActions(retained)
        if let fresh=try? refreshIndex?(),let tools=try? AskReadTools(request:saved.userRequest ?? saved.request,index:fresh) {
            guard let checked=try? tools.checked(tools.rebasedCatalogResponse(retained)) else{return nil};retained=checked
        }
        return retained
    }
    private func archiveRecovered(_ turn:AskTurn,chat:UUID)->Bool {
        guard let position=chats.firstIndex(where:{$0.id==chat}) else{return false}
        var next=currentChatSnapshot()
        next[position].conversation.turns.removeAll {$0.id==turn.id}
        next[position].conversation.turns.append(.init(turn))
        if turn.status == .complete,next[position].conversation.fallbackDraftTurnID==turn.id {
            next[position].conversation.draft="";next[position].conversation.fallbackDraftTurnID=nil
        }
        next[position].lastActivityAt=activityNow();next[position].updatedAt=activityNow()
        if next[position].hasCustomTitle != true,next[position].title=="New chat" {next[position].title=String(turn.request.text.prefix(80))}
        return commitChats(next,active:activeChatID,allowVolatile:true,changedChatIDs:[chat])
    }
    private func cancelRecoveryJob(_ turn:UUID) {
        guard let saved=try? recoveryStore?.checkpoint(turn),
              let agent=provider as? AskAgentProvider,let hosted=agent.remote as? AskHostedProvider,saved.endpoint==hosted.configuration.endpoint.absoluteString else{return}
        let step=saved.pendingRequest ?? AskConversationStep(requestID:saved.attemptID.uuidString,step:min(saved.state.nextStep,11),text:"",context:.init(index:[],recent:[]),cities:[],task:nil,findings:[],history:[],continuation:nil,result:nil)
        Task { _ = try? await hosted.recoveryJob("cancel",step:step) }
    }
    private func stopRecoveryChat(_ chat:UUID)throws {
        guard let recoveryStore else{return}
        for (id,request) in recoveryRequests where request.conversationID==chat {recoveryTasks[id]?.cancel();recoveryTasks.removeValue(forKey:id);recoveryRequests.removeValue(forKey:id)}
        for saved in try recoveryStore.checkpoints(chat:chat) {try recoveryStore.stop(saved.turnID);cancelRecoveryJob(saved.turnID)}
        try recoveryStore.deleteChat(chat)
    }
    func revokeRecovery() {
        guard recoveryStore != nil else{suspend();return}
        if let recoveryStore {
            for saved in (try? recoveryStore.checkpoints()) ?? [] {try? recoveryStore.stop(saved.turnID);cancelRecoveryJob(saved.turnID)}
            for work in recoveryTasks.values {work.cancel()};recoveryTasks.removeAll();recoveryRequests.removeAll()
        }
        cancel();flushHistory()
    }
    func setAppActive(_ active:Bool) {
        guard let recoveryStore else{return}
        let returning=active && !recoveryStore.active
        recoveryStore.active=active
        if active {restorePendingRecovery(activityResume:returning)}else{flushHistory()}
    }
    func restorePendingRecovery(activityResume:Bool=false) {
        guard historyReadable,let recoveryStore,recoveryStore.active else{return}
        do {
            let saved=try recoveryStore.checkpoints()
            // The archive remains authoritative for deletion. Never resurrect a chat.
            for item in saved where chats.contains(where:{$0.id==item.chatID}) {
                let request=item.userRequest ?? item.request
                if chats.first(where:{$0.id==item.chatID})?.conversation.turns.first(where:{$0.id==item.turnID})?.stopped==true {
                    try recoveryStore.stop(item.turnID);continue
                }
                if !item.resumable {
                    if item.chatID==activeChatID,!turns.contains(where:{$0.id==item.turnID}) {
                        turns.append(.init(id:item.turnID,request:request,response:recoveryInterruptedResponse(item,message:item.failure ?? AskRecoveryError.unavailable.localizedDescription),sources:[],status:item.phase == .stopped ? .stopped : .failed(item.failure ?? AskRecoveryError.unavailable.localizedDescription)))
                        flushHistory()
                    }
                    continue
                }
                if item.chatID==activeChatID,!turns.contains(where:{$0.id==item.turnID}) {turns.append(.init(id:item.turnID,request:request))}
                if recoveryTasks[item.turnID] != nil {
                    if activityResume,item.phase == .awaitingReply {recoveryResumeRequested.insert(item.turnID)}
                    if item.chatID==activeChatID {activeID=item.turnID;isLoading=true;task=recoveryTasks[item.turnID];setStatus(item.turnID,.loading)}
                    continue
                }
                if !recoveryStore.isRunning(item.turnID) {start(id:item.turnID,request:request)}
            }
            // Navigation during preflight has no durable request yet, but its
            // existing task still belongs to the original chat, not the draft.
            for (id,request) in recoveryRequests where request.conversationID==activeChatID && !turns.contains(where:{$0.id==id}) {
                turns.append(.init(id:id,request:request));activeID=id;isLoading=true;task=recoveryTasks[id]
            }
        }catch {self.error=error.localizedDescription}
    }

}
