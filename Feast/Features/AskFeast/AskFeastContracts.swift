import Foundation
import Combine

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
    init(records: [AskCollectionRecord], visibleCityIDs: Set<String>, visibleNoteIDs: Set<String>, scope: AskDataScope = .synthetic, personalPlaces: [AskPersonalPlace] = [], catalogComplete: Bool = true) {
        self.scope = scope
        self.catalogComplete = catalogComplete
        self.personalPlaces = personalPlaces
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
struct AskScreenshot: Equatable, Sendable {
    let jpeg: Data
    func validated() throws -> Self {
        guard !jpeg.isEmpty, jpeg.count <= 196608, jpeg.starts(with: [0xff,0xd8]), jpeg.suffix(2) == Data([0xff,0xd9]) else { throw AskError.imageLimit }
        return self
    }
}
struct AskRequest: Equatable, Sendable {
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
    var pendingActions:[AskCollectionAction] = []
    var publicResearch:[AskRetainedResearch] = []
    var mapChoices:[AskMapChoice] = []
    func collectionReadVersion() -> Self {
        .init(mode:.collection,text:text,fromOCR:fromOCR,previousQuestion:previousQuestion,attachment:attachment,referencedIDs:referencedIDs,referenceOnly:referenceOnly,libraryContext:libraryContext,referencedWebPlaces:referencedWebPlaces,verifiedFindings:verifiedFindings,performanceID:performanceID,providerRetry:providerRetry,recentQuestions:recentQuestions,agentTask:agentTask,conversationID:conversationID,dialogue:dialogue,pendingActions:pendingActions,publicResearch:publicResearch,mapChoices:mapChoices)
    }
    var retrievalText: String {
        guard mode != .importText, let previousQuestion else { return text }
        return String((text + "\nEarlier question: " + previousQuestion).prefix(4_000))
    }
    func validated() throws -> Self {
        guard (!text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || attachment != nil), text.count <= 4_000, (previousQuestion?.count ?? 0) <= 2_000, referencedIDs.count <= 6, Set(referencedIDs).count == referencedIDs.count, referencedWebPlaces.count <= 3 else { throw AskError.inputLimit }
        if let context = libraryContext {
            guard context.ids.count <= 200, Set(context.ids).count == context.ids.count else { throw AskError.inputLimit }
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
}
enum AskResponseLayout:String,Codable,Sendable {case direct,list,lookup,clarification,action}
struct AskResponse: Codable, Equatable, Sendable {
    var summary: String
    var candidates: [AskCandidate]
    var paragraphs: [AskAnswerParagraph] = []
    // nil retains the bounded result list for adapters without rich paragraphs.
    // An empty list means a conversational answer with no repeated result rows.
    var listedCandidateIDs: [String]? = nil
    var usesLocalCatalog = false
    var libraryContext: AskLibraryContext? = nil
    var webPlaces: [AskWebPlace] = []
    var referenceWebPlaces: [AskWebPlace]? = nil
    var fieldActions: [AskFieldActionState]? = nil
    var requestsFieldSave: Bool? = nil
    var presentation:AskResponseLayout? = nil
    var agentTask:AskAgentTask? = nil
    var collectionActions:[AskCollectionAction]? = nil
    var verifiedPublicFindings:[AskVerifiedFinding]? = nil
    var publicConversationText:String? = nil
    var publicResearch:[AskRetainedResearch]? = nil
    var mapChoices:[AskMapChoice]? = nil
    var pendingProposal:AskChangeProposal? = nil
    var executionStatus:String? = nil
    var operationRecords:[AskOperationRecord]? = nil
    var undoFailures:[String:String]? = nil
    /// Refresh only the executor's generated review status, never model prose.
    mutating func refreshCollectionReviewStatus() {
        guard let actions=collectionActions,!actions.isEmpty,!actions.contains(where:{$0.state == .ready || $0.state == .needsConfirmation}) else{return}
        let text:String
        if actions.allSatisfy({$0.state == .undone}) {text="Undone."}
        else if actions.allSatisfy({$0.state == .applied || $0.state == .undone}) {text="Saved."}
        else {return}
        for i in paragraphs.indices where paragraphs[i].id=="agent-message" && ["Review this change before applying it.","Saved.","Undone."].contains(where:{paragraphs[i].spans == [.text($0)]}) {
            let old=paragraphs[i]
            paragraphs[i] = .init(id:old.id,spans:[.text(text)],sourceIDs:old.sourceIDs,citations:old.citations,citationsAreResearchPool:old.citationsAreResearchPool,representedField:old.representedField,transientToolStatus:old.transientToolStatus,operationStatus:old.operationStatus)
            if ["Review this change before applying it.","Saved.","Undone."].contains(summary) {summary=text}
        }
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
            return .init(id:paragraph.id,spans:spans,sourceIDs:sourceIDs,citations:paragraph.citations,citationsAreResearchPool:paragraph.citationsAreResearchPool,representedField:paragraph.representedField,transientToolStatus:paragraph.transientToolStatus)
        }
        response.listedCandidateIDs=response.listedCandidateIDs.map {$0.filter {available.contains($0)}}
        response.fieldActions=response.fieldActions.map {$0.filter {available.contains($0.finding.recordID)}}
        response.verifiedPublicFindings=response.verifiedPublicFindings.map {$0.filter {available.contains($0.recordID)}}
        if response.libraryContext?.ids != response.candidates.map(\.id) {response.libraryContext=nil}
        return response
    }
    func checked(_ response: AskResponse) throws -> AskResponse {
        let listing = response.usesLocalCatalog ? AskCollectionListingPlan.make(request, places: index.personalCatalog) : nil
        let localTool = response.usesLocalCatalog && (response.libraryContext != nil || response.agentTask != nil)
        let localListing = listing != nil || localTool
        guard response.summary.count <= 3_000, response.candidates.count <= (localListing ? 200 : 6),
              Set(response.candidates.map(\.id)).count == response.candidates.count else { throw AskError.invalidEvidence }
        let available = response.usesLocalCatalog ? localEvidence : evidence
        let catalog = Dictionary(uniqueKeysWithValues: available.candidates.map { ($0.id, $0) })
        let sources = Set(available.sources.map(\.id))
        for candidate in response.candidates {
            guard catalog[candidate.id] == candidate, !candidate.sourceIDs.isEmpty,
                  Set(candidate.sourceIDs).isSubset(of: sources),
                  candidate.facts.allSatisfy({ candidate.sourceIDs.contains($0.sourceID) }) else { throw AskError.invalidEvidence }
        }
        if let context = response.libraryContext {
            guard context.ids.count <= 200, Set(context.ids).count == context.ids.count, context.ids == response.candidates.map(\.id) else { throw AskError.invalidEvidence }
            if let selection=context.selectionIDs {
                guard response.usesLocalCatalog,[AskLibraryPlan.Operation.count,.group].contains(context.filters.operation),Set(selection).count == selection.count,Set(selection).isSubset(of:Set(index.personalCatalog.map(\.id))) else { throw AskError.invalidEvidence }
            }
        }
        if let listing, !localTool {
            let expected = Set(index.personalCatalog.filter(listing.matcher(all:index.personalCatalog)).map(\.id))
            guard Set(response.candidates.map(\.id)) == expected else { throw AskError.invalidEvidence }
        }
        if response.requestsFieldSave == true {
            guard request.verifiedFindings.count <= 6,response.fieldActions?.count == 1,
                  response.fieldActions?.allSatisfy({request.verifiedFindings.contains($0.finding)}) == true else {throw AskError.invalidEvidence}
        }
        if let choices=response.mapChoices {
            guard choices.count<=6,Set(choices.map(\.id)).count==choices.count,choices.allSatisfy({UUID(uuidString:$0.id) != nil && !$0.applePlaceID.isEmpty && $0.applePlaceID.count<=300 && !$0.name.isEmpty && $0.name.count<=200 && $0.address.count<=500 && $0.city.count<=200 && $0.query.count<=300 && ($0.website==nil || InstagramWebsiteClient.websiteURL($0.website!) != nil)}) else{throw AskError.invalidEvidence}
        }
        if let research=response.publicResearch {
            guard research.count<=4,research.allSatisfy({$0.query.count<=1500 && $0.result.text.count<=16000 && $0.result.citations.count<=20 && $0.result.citations.allSatisfy {$0.safeURL != nil}}) else{throw AskError.invalidEvidence}
        }
        for research in response.publicResearch ?? [] {_ = try research.result.nativeEvidence?.checked()}
        if let operations=response.operationRecords {
            let actionIDs=Set((response.collectionActions ?? []).map(\.id))
            guard operations.count<=24,Set(operations.map(\.id)).count==operations.count,
                  operations.allSatisfy({record in
                    record.id.count==64 && record.id.allSatisfy(\.isHexDigit) && ["place","city","neighborhood"].contains(record.entity) && ["create","update","append","move","delete","undo"].contains(record.operation) && record.targetIDs.count<=200 && record.targetIDs.allSatisfy {UUID(uuidString:$0) != nil} && Set(record.actionIDs).isSubset(of:actionIDs) && record.outcomes.count<=200
                  }) else{throw AskError.invalidEvidence}
        }
        if let findings=response.verifiedPublicFindings {
            guard findings.count<=24,Set(findings.map(\.id)).count==findings.count else {throw AskError.invalidEvidence}
            for finding in findings {_ = try finding.validated();guard response.candidates.contains(where:{$0.id==finding.recordID}) else {throw AskError.invalidEvidence}}
        }
        if let actions=response.fieldActions {
            guard actions.count <= (localTool ? 24 : 6),Set(actions.map { $0.finding.id }).count == actions.count else {throw AskError.invalidEvidence}
            for action in actions { _ = try action.finding.validated();guard action.finding.field=="instagram",response.candidates.contains(where:{$0.id == action.finding.recordID}) else {throw AskError.invalidEvidence} }
        }
        let returnedIDs = Set(response.candidates.map(\.id))
        if let rows = response.listedCandidateIDs {
            guard rows.count <= 6, Set(rows).count == rows.count, Set(rows).isSubset(of: returnedIDs) else { throw AskError.invalidEvidence }
        }
        guard response.paragraphs.count <= (localListing ? 4001 : 8), Set(response.paragraphs.map(\.id)).count == response.paragraphs.count else { throw AskError.invalidEvidence }
        let returnedSources = sources // Every cited source must be in the approved request evidence.
        var characters = 0
        for paragraph in response.paragraphs {
            guard paragraph.citations.count <= (localTool ? 20 : 6), paragraph.citations.allSatisfy({ $0.safeURL != nil && $0.title.count <= 200 }) else { throw AskError.invalidEvidence }
            guard !paragraph.id.isEmpty, paragraph.id.count <= 80, (1...(localTool ? 401 : 24)).contains(paragraph.spans.count),
                  Set(paragraph.sourceIDs).count == paragraph.sourceIDs.count,
                  Set(paragraph.sourceIDs).isSubset(of: returnedSources) else { throw AskError.invalidEvidence }
            for span in paragraph.spans {
                switch span {
                case .text(let text): characters += text.count
                case .place(let id):
                    guard let candidate = response.candidates.first(where: { $0.id == id }),
                          !Set(candidate.sourceIDs).isDisjoint(with: paragraph.sourceIDs) else { throw AskError.invalidEvidence }
                    characters += candidate.name.count
                }
            }
        }
        guard characters <= (localListing ? 60_000 : 3_000) else { throw AskError.invalidEvidence }
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
    var readContextMode:AskMode {response?.usesLocalCatalog == true && response?.libraryContext != nil ? .collection : request.mode}
}

@MainActor final class AskSession: ObservableObject {
    @Published var input = "" { didSet { if input.isEmpty { fromOCR = false }; scheduleHistory() } }
    @Published var mode: AskMode = .collection { didSet { if mode != oldValue { fromOCR = false } } }
    @Published var sourceOverride: AskMode? = nil
    @Published var fromOCR = false
    @Published var attachment: AskScreenshot?
    @Published private(set) var turns: [AskTurn] = []
    @Published private(set) var isLoading = false
    @Published private(set) var error: String?
    @Published private(set) var canRetry: [UUID: Bool] = [:]
    @Published private(set) var chats: [AskChatArchive] = []
    @Published private(set) var activeChatID = UUID()
    @Published private(set) var needsOnlineConsent = false
    private var consentTicket: UUID?
    private var historyMigration: AskChatMigration?
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
    private var pendingActivityAt:Date?
    private var previousActivityBeforeRequest:Date?
    var activityNow:()->Date = Date.init
    var fieldStatus:((AskFieldActionState)throws->AskFieldActionState)?
    var fieldExecutor: ((AskFieldActionState,AskFieldActionMode) throws -> AskFieldActionState)?
    var refreshIndex:(()throws->AskLocalIndex)?
    var collectionExecutor:((UUID,Bool)throws->AskCollectionAction)?
    var collectionStatus:((UUID)throws->AskCollectionAction)?
    var collectionReceipts:((UUID)throws->[AskCollectionAction])?
    var collectionRecovery:((UUID)throws->[AskRecoveredActionTurn])?
    var collectionClear:((UUID)throws->Void)?
    private var provider: any AskFeastProvider
    private var index: AskLocalIndex
    init(index: AskLocalIndex, provider: any AskFeastProvider) { self.index = index; self.provider = provider }
#if FEAST_TESTS
    convenience init(index: AskLocalIndex) { self.init(index: index, provider: MockAskFeastProvider()) }
#endif
    var response: AskResponse? { turns.last(where: { $0.response != nil })?.response }
    var providerLabel: String { provider.label }
    /// Activation changes transport only; keep the same chat, draft, findings and action journal.
    func replaceProviderWhenIdle(_ next:any AskFeastProvider)->Bool {
        guard !isLoading else{return false};provider=next;return true
    }
    func updateIndex(_ index: AskLocalIndex) { self.index = index }
    func source(_ id: String) -> AskSource? { turns.reversed().flatMap(\.sources).first { $0.id == id } }
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
        guard !isLoading, let original = turns.first(where: { $0.id == id }) else { return }
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
        guard history == nil || turns.filter({ $0.status == .complete && $0.request.attachment == nil }).count < 100 else {
            error = "This chat is full. Start a new chat to continue; its saved messages are unchanged.";return
        }
        let completed = turns.last { $0.status == .complete && $0.readContextMode == mode }
        let namedPublicReference = completed?.response.map { ($0.referenceWebPlaces ?? $0.webPlaces).contains { $0.name.caseInsensitiveCompare(input.trimmingCharacters(in: .whitespacesAndNewlines)) == .orderedSame } } == true
        let followUp = AskQueryPlan.isFollowUp(input) || namedPublicReference
        let knownWeb = completed?.response?.referenceWebPlaces ?? completed?.response?.webPlaces ?? []
        let criterionText = knownWeb.sorted { $0.name.count > $1.name.count }.reduce(input) { $0.replacingOccurrences(of: $1.name, with: "", options: .caseInsensitive) }
        let referenced = completed?.response?.paragraphs.flatMap(\.spans).compactMap { span -> String? in if case .place(let id) = span { return id }; return nil } ?? []
        let references = followUp ? Array(Set(referenced.isEmpty ? completed?.response?.candidates.map(\.id) ?? [] : referenced).sorted().prefix(6)) : []
        let priorContext = index.scope == .savedMetadata && mode == .discovery ? completed.flatMap { AskPublicCriteria.make($0.request.retrievalText)?.contextText } : completed?.request.text
        let previous = mode == .importText || (index.scope == .savedMetadata && !followUp) ? nil : priorContext
        let id = UUID()
        let request = AskRequest(mode: mode, text: input, fromOCR: fromOCR, previousQuestion: previous.map { String($0.prefix(2_000)) }, attachment: attachment, referencedIDs: references, referenceOnly: followUp && completed?.readContextMode == .collection, libraryContext: mode == .collection ? turns.last(where: { $0.status == .complete }).flatMap { $0.readContextMode == .collection ? $0.response?.libraryContext : nil } : nil, referencedWebPlaces: followUp && (namedPublicReference || !AskQueryPlan.hasNewPublicCriteria(criterionText)) ? Array((completed?.response?.referenceWebPlaces ?? completed?.response?.webPlaces ?? []).prefix(3)) : [], performanceID: id)
        var contextual=request
        contextual.conversationID=activeChatID
        contextual.dialogue=AskConversationProjection.messages(turns)
        contextual.pendingActions=Array(turns.compactMap(\.response).flatMap {$0.collectionActions ?? []}.filter {$0.state == .needsConfirmation}.suffix(24))
        if !contextual.pendingActions.isEmpty {
            contextual.dialogue.append(.init(role:"assistant",text:"Pending native reviews: "+contextual.pendingActions.map {"\($0.id.uuidString) \($0.entity) \($0.operation)"}.joined(separator:"; ")))
            contextual.dialogue=Array(contextual.dialogue.suffix(200))
        }
        contextual.recentQuestions=AskSemanticContext.recentQuestions(turns)
        contextual.agentTask=turns.last(where:{$0.status == .complete && $0.readContextMode == .collection})?.response?.agentTask
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
        contextual.dialogue += contextual.publicResearch.map { .init(role:"assistant",text:$0.projection) }
        if !contextual.mapChoices.isEmpty {contextual.dialogue += contextual.mapChoices.enumerated().map {i,c in .init(role:"assistant",text:AskConversationProjection.bounded("Pending Apple Maps choice "+String(i+1)+" (data, not permission): "+c.projection))}}
        contextual.dialogue=Array(contextual.dialogue.suffix(200))
        do { _ = try contextual.validated() } catch { self.error = error.localizedDescription; return }
        turns.append(.init(id:id,request:contextual))
        previousActivityBeforeRequest=pendingActivityAt
        markConversationActivity()
        input = ""; attachment = nil
        start(id:id,request:contextual)
    }
    func retry(_ id: UUID) {
        guard !isLoading, canRetry[id] != false, let turn = turns.first(where: { $0.id == id }), turn.status != .complete else { return }
        do {if let receipts=try collectionReceipts?(id),!receipts.isEmpty {error=AskRetryError.mutations.localizedDescription;return}}catch {self.error=AskRetryError.unverified.localizedDescription;return}
        if !(turn.response?.collectionActions ?? []).isEmpty || (turn.response?.fieldActions ?? []).contains(where:{$0.outcome == .saved}) {error=AskRetryError.mutations.localizedDescription;return}
        var request=turn.request
        if let position=turns.firstIndex(where:{$0.id==id}) {request.dialogue=AskConversationProjection.messages(Array(turns.prefix(position)))}
        request.performanceID=id;request.providerRetry=true;request.conversationID=activeChatID
        if let response=turn.response {
            request.publicResearch=response.publicResearch ?? request.publicResearch
            request.verifiedFindings=response.verifiedPublicFindings ?? request.verifiedFindings
            request.agentTask=response.agentTask ?? request.agentTask
            request.pendingActions=response.collectionActions ?? request.pendingActions
            request.mapChoices=response.mapChoices ?? request.mapChoices
        }
        start(id: id, request: request)
    }
    private func start(id: UUID, request: AskRequest) {
        let startedAt = DispatchTime.now().uptimeNanoseconds
        let trace=AskPipelineTrace(id:UUID(),turnID:id)
        if pipelineTraces.count>=20 {pipelineTraces.removeAll()}
        pipelineTraces[id]=trace
        generation = UUID(); let token = generation
        activeID = id; isLoading = true; error = nil; canRetry[id] = true
        scheduleHistory()
        setStatus(id, .loading)
        let tools: AskReadTools
        do { tools = try AskReadTools(request: request, index: index) }
        catch { trace.finish(.failed);trace.elapsed(.taskExit,since:startedAt);Task {await AskPerformanceRecorder.shared.recordPipeline(trace.snapshot())};setStatus(id, .failed(error.localizedDescription)); self.error = error.localizedDescription; isLoading = false; activeID = nil; return }
        trace.elapsed(.preparation,since:startedAt)
        task = Task { [weak self, provider] in
            defer {if trace.snapshot().outcome == .running {trace.finish(Task.isCancelled ? .cancelled : .failed)};trace.elapsed(.taskExit,since:startedAt);Task {await AskPerformanceRecorder.shared.recordPipeline(trace.snapshot())}}
            do {
                let result = try await AskPipelineScope.$trace.withValue(trace) {try await provider.answer(request, tools: tools)}
                try Task.checkCancellation()
                let validationStarted = DispatchTime.now().uptimeNanoseconds
                let currentTools:AskReadTools
                if let fresh=try self?.refreshIndex?() {self?.index=fresh;currentTools=try AskReadTools(request:request,index:fresh)}else{currentTools=tools}
                var checked = try currentTools.checked(currentTools.rebasedCatalogResponse(result))
                if let self {checked.fieldActions=checked.fieldActions?.map {self.currentFieldAction($0)}}
                let validationMS = AskPerformanceRecorder.milliseconds(since: validationStarted)
                trace.record(.validation,milliseconds:validationMS)
                guard let self, generation == token, let position = turns.firstIndex(where: { $0.id == id }) else { return }
                turns[position].response = checked
                if checked.requestsFieldSave == true {
                    for action in checked.fieldActions ?? [] { self.applyFieldAction(turn:id,findingID:action.finding.id,mode:.save,allowLoading:true) }
                }
                turns[position].sources = (checked.candidates.flatMap(\.sourceIDs) + checked.paragraphs.flatMap(\.sourceIDs)).reduce(into: [AskSource]()) { result, id in
                    if !result.contains(where: { $0.id == id }), let source = currentTools.source(id) { result.append(source) }
                }
                turns[position].status = .complete; isLoading = false; activeID = nil
                markConversationActivity()
                acceptedAt[id] = DispatchTime.now().uptimeNanoseconds
                answerRevisions[id,default:0]+=1
                trace.elapsed(.answerAvailable,since:startedAt);trace.finish(.completed)
                scheduleHistory(trace:trace)
                await AskPerformanceRecorder.shared.record(.validation, milliseconds: validationMS, traceID: id)
                await AskPerformanceRecorder.shared.record(.overall, milliseconds: AskPerformanceRecorder.milliseconds(since: startedAt), traceID: id)
            } catch AskHostedError.consentRequired {
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
                guard let self, generation == token, !Task.isCancelled else { return }
                canRetry[id] = (error as? AskConversationFailure)?.retryable ?? (error as? AskHostedError)?.retryable ?? true
                let message = AskHostedError.message(for: error)
                setStatus(id, .failed(message)); self.error = message
                markConversationActivity()
                scheduleHistory()
                isLoading = false; activeID = nil
            }
        }
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
        needsOnlineConsent = false;consentTicket = nil
        generation = UUID(); task?.cancel(); task = nil
        if let activeID {
            if let receipts=try? collectionReceipts?(activeID),!receipts.isEmpty,let position=turns.firstIndex(where:{$0.id==activeID}) {
                turns[position].response=actionReceiptResponse(receipts)
                setStatus(activeID,.complete)
            }else {setStatus(activeID,.stopped)}
            if userInitiated {markConversationActivity()}
        }
        if let id=activeID,let trace=pipelineTraces[id] {trace.elapsed(.stopRequested,since:trace.started);trace.finish(.cancelled)}
        activeID = nil; isLoading = false
        scheduleHistory()
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
        cancel(); historyTask?.cancel(); historyGeneration = UUID()
        do {try collectionClear?(activeChatID)}catch {self.error=error.localizedDescription;return}
        resetScreen(.init()); flushHistory()
    }
    private func actionReceiptResponse(_ actions:[AskCollectionAction])->AskResponse {
        let text="Changes recorded before this request stopped."
        return .init(summary:text,candidates:[],paragraphs:[.init(id:"action-recovery",spans:[.text(text)],sourceIDs:[],operationStatus:true)],listedCandidateIDs:[],usesLocalCatalog:true,agentTask:.init(action:"change",fields:[],orderedIDs:actions.flatMap(\.targetIDs),sourcePolicy:"local_only"),collectionActions:actions,executionStatus:"stopped")
    }
    private func resetScreen(_ value:AskConversationSnapshot) {
        turns = value.turns.map { $0.turn }; acceptedAt = [:]; input = value.draft
        if let collectionStatus {for i in turns.indices {guard var response=turns[i].response,var actions=response.collectionActions else{continue};for j in actions.indices {if let current=try? collectionStatus(actions[j].id) {actions[j]=current}else {actions[j].state = .unavailable;actions[j].undoable=false}};response.collectionActions=actions;response.refreshCollectionReviewStatus();turns[i].response=response}}
        if let fieldStatus {for i in turns.indices {guard var response=turns[i].response,let actions=response.fieldActions else{continue};response.fieldActions=actions.map {currentFieldAction($0)};turns[i].response=response}}
        if let recovered=try? collectionRecovery?(activeChatID) {
            for item in recovered where !turns.contains(where:{$0.id==item.id}) {
                turns.append(.init(id:item.id,request:.init(mode:.collection,text:item.question,fromOCR:false),response:actionReceiptResponse(item.actions),sources:[],status:.complete))
                if input==item.question {input=""}
            }
        }
        attachment = nil; canRetry = [:]; error = nil; needsOnlineConsent = false
        mode = .collection; sourceOverride = nil; fromOCR = false
    }
    func restoreHistory(from store: AskConversationStore) {
        guard history == nil else { return }
        history = store
        do {
            let library = try store.loadLibrary()
            chats = library.chats; activeChatID = library.activeID;historyMigration = library.migration
            resetScreen(chats.first { $0.id == activeChatID }!.conversation)
        } catch { historyReadable = false; self.error = error.localizedDescription }
    }
    private func commitChats(_ proposed:[AskChatArchive], active:UUID) -> Bool {
        guard historyReadable else { error = AskHistoryError.unreadable.localizedDescription; return false }
        guard (1...50).contains(proposed.count),proposed.allSatisfy({$0.conversation.turns.count <= 100}) else { error = AskHistoryError.limit.localizedDescription;return false }
        if let history, !history.saveLibrary(.init(activeID:active,chats:proposed,migration:historyMigration)) {
            error = "Chat history couldn’t be saved. Nothing was deleted.";return false
        }
        chats = proposed;activeChatID = active;return true
    }
    @discardableResult func newChat() -> Bool {
        suspend(); guard flushCurrentChat() else { return false }
        let chat = AskChatArchive(id:UUID(),title:"New chat",updatedAt:Date(),conversation:.init())
        guard commitChats(chats + [chat],active:chat.id) else { return false }
        historyGeneration = UUID();resetScreen(chat.conversation);return true
    }
    @discardableResult func openChat(_ id:UUID) -> Bool {
        guard id != activeChatID,chats.contains(where:{$0.id == id}) else { return false }
        suspend();guard flushCurrentChat(),commitChats(chats,active:id) else { return false }
        historyGeneration = UUID();resetScreen(chats.first {$0.id == id}!.conversation);return true
    }
    @discardableResult func renameChat(_ id:UUID,to name:String) -> Bool {
        let title = name.trimmingCharacters(in:.whitespacesAndNewlines)
        guard !title.isEmpty,title.count <= 80 else { error = "Use a chat name of 1–80 characters.";return false }
        guard flushCurrentChat(),let position = chats.firstIndex(where:{$0.id == id}) else { return false }
        var next = chats;next[position].title = title
        return commitChats(next,active:activeChatID)
    }
    @discardableResult func deleteChat(_ id:UUID) -> Bool {
        guard chats.contains(where:{$0.id == id}) else { return false }
        suspend()
        do {try collectionClear?(id)}catch {self.error=error.localizedDescription;return false}
        var next = currentChatSnapshot().filter {$0.id != id}
        if next.isEmpty { next = AskChatLibrary.empty().chats }
        let active = id == activeChatID ? next[0].id : activeChatID
        guard commitChats(next,active:active) else { return false }
        historyGeneration = UUID();resetScreen(next.first {$0.id == active}!.conversation)
        if let migration = historyMigration,migration.chatID == id,let history {
            if history.removeMigrationCopy(migration) {
                historyMigration = nil
                _ = commitChats(chats,active:activeChatID)
            } else { error = "The chat was deleted, but its changed or unreadable migration backup was kept." }
        }
        return true
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
        let completed = turns.filter { $0.status != .loading && $0.request.attachment == nil }.map(AskArchivedTurn.init)
        let interrupted = turns.last(where: { $0.status == .loading })
        return .init(version: 1, draft: String((input.isEmpty ? interrupted?.request.text ?? "" : input).prefix(4000)), turns: completed)
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
            if next[position].title == "New chat",let first = next[position].conversation.turns.first,
               !first.question.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty {
                next[position].title = String(first.question.prefix(80))
            }
        }
        return next
    }
    @discardableResult private func flushCurrentChat() -> Bool {
        guard history != nil else { return true }
        let saved=commitChats(currentChatSnapshot(),active:activeChatID)
        if saved {pendingActivityAt=nil}
        return saved
    }
    private func markConversationActivity() {pendingActivityAt=activityNow()}
    func flushHistory() { historyTask?.cancel(); _ = flushCurrentChat() }
    func suspend() {
        if input.isEmpty, let activeID, let turn = turns.first(where: { $0.id == activeID }) { input = turn.request.text }
        cancel(userInitiated:false); flushHistory()
    }
}
