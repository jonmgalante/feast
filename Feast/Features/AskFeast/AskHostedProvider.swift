import Foundation

/// Disabled-by-default hosted transport. No provider secret or automatic activation.
struct AskHostedConfiguration: Sendable {
    enum Environment: Sendable { case development, production }
    let environment: Environment
    let endpoint: URL
    var scope: AskDataScope = .synthetic
    var productionHost: String? = nil
    var ownerValidation = false
    func validate() throws {
        guard endpoint.scheme == "https",
              endpoint.host?.contains(".") == true,
              endpoint.user == nil, endpoint.password == nil, endpoint.port == nil,
              endpoint.query == nil, endpoint.fragment == nil,
              endpoint.path == "/v1/answer" else { throw AskHostedError.disabled }
        switch environment {
        case .development:
            guard endpoint.host?.hasSuffix(".workers.dev") == true else { throw AskHostedError.disabled }
        case .production:
            guard let productionHost, endpoint.host == productionHost,
                  productionHost != "feast-proxy-dev.jonmgalante.workers.dev",
                  productionHost != "localhost", !productionHost.hasSuffix(".invalid"), !productionHost.hasSuffix(".local"),
                  !productionHost.allSatisfy({$0.isNumber || $0 == "."}) else { throw AskHostedError.disabled }
        }
    }
}

enum AskHostedError: LocalizedError {
    case disabled, consentRequired, selectionUnavailable, invalidResponse, answerRejected, service(Int)
    var retryable: Bool {
        switch self { case .disabled, .consentRequired, .selectionUnavailable: return false
        case .service(let code): return ![401,403,409,429,503].contains(code)
        default: return true }
    }
    static func failure(status: Int, data: Data) -> Error {
        if data.count <= 4096, let value = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let code = value["error"] as? String,
           ["provider_billing_limit", "provider_billing_setup", "provider_rate_limit", "provider_authentication"].contains(code) {
            return AskConversationFailure(status: status, code: code)
        }
        return AskHostedError.service(status)
    }
    static func message(for error: Error) -> String {
        if let error = error as? URLError {
            if error.code == .notConnectedToInternet { return "You’re offline. Reconnect, then retry." }
            if error.code == .timedOut { return "The answer took too long. You can retry; the earlier request may still have incurred usage." }
        }
        return error.localizedDescription
    }
    var errorDescription: String? {
        switch self {
        case .disabled: "Online answers aren’t configured yet. You can still ask for saved-place lists."
        case .consentRequired: "Online AI needs your permission before sending."
        case .selectionUnavailable: "I couldn’t resolve the saved places for that request. Please send it again."
        case .invalidResponse, .answerRejected: "The AI returned an answer Feast couldn’t verify. Please try again."
        case .service(let status):
            switch status {
            case 401: "Ask Feast access has expired or isn’t available. Please check access before trying again."
            case 409: "This request attempt can’t be replayed. Its earlier outcome must be checked before continuing."
            case 429: "Ask Feast is handling too many requests. Try again shortly."
            case 503: "Ask Feast is currently unavailable. Try again after service is restored."
            case 502: "The AI service couldn’t complete the answer. Please try again."
            default: "Ask Feast couldn’t complete the request (HTTP \(status))."
            }
        }
    }
}

/// In-memory, single-consumption result; never persists chat or credentials.
actor AskBrokerAnswers {
    private var values: [UUID:(Date,Data)] = [:]
    func put(_ data:Data,for id:UUID) {
        values = values.filter {Date().timeIntervalSince($0.value.0) < 180}
        if values.count >= 4,let oldest=values.min(by:{$0.value.0 < $1.value.0})?.key {values.removeValue(forKey:oldest)}
        values[id]=(Date(),data)
    }
    func take(_ id:UUID) -> Data? {
        guard let value=values.removeValue(forKey:id),Date().timeIntervalSince(value.0)<180 else{return nil}
        return value.1
    }
}

/// Caller confines requests/evidence to its approved scope before obtaining a credential.
struct AskHostedProvider: AskFeastProvider {
    let label = "Ask Feast"
    let configuration: AskHostedConfiguration
    let token: @Sendable () async throws -> String
    let approve: @Sendable (AskRequest, AskEvidence) async throws -> Bool
    var send: @Sendable (URLRequest) async throws -> (Data, HTTPURLResponse)
    var webEnabled: @Sendable () async -> Bool = { false }
    var libraryToolsEnabled: @Sendable () async -> Bool = { false }
    var permission: @Sendable () async -> Bool = { true }
    var libraryPlanVersion: @Sendable () async -> Int = { 1 }
    var publicLookupEnabled: @Sendable () async -> Bool = {false}
    var brokerAnswers = AskBrokerAnswers()
    var prepareCapabilities:@Sendable ()async->Void = {}
    var nativeResearchEnabled:@Sendable ()async->Bool = {false}
    var collectionQueriesEnabled:@Sendable ()async->Bool = {false}
    var retainedHistoryEnabled:@Sendable ()async->Bool = {false}
    var recoveryEnabled:@Sendable ()async->Bool = {false}
    var recoveryRetainedHistoryEnabled:@Sendable ()async->Bool = {false}
    var recoveryCleanupToken:(@Sendable ()async throws->String)?=nil

    func answer(_ request: AskRequest, tools: AskReadTools) async throws -> AskResponse {
        try configuration.validate()
        guard await permission() else { throw AskHostedError.consentRequired }
        if request.mode == .discovery, configuration.scope == .savedMetadata { return try await discover(request) }
        if configuration.scope == .savedMetadata, request.mode != .collection || request.fromOCR { throw AskHostedError.consentRequired }
        if configuration.scope == .synthetic, request.attachment != nil { throw AskHostedError.consentRequired }
        let evidence: AskEvidence
        switch request.mode {
        case .collection: evidence = try tools.collection(.init(text: request.text, limit: 6))
        case .importText: evidence = try tools.importedText()
        case .discovery: throw AskHostedError.disabled
        }
        guard try await approve(request, evidence) else {
            if configuration.environment == .production { throw AskHostedError.selectionUnavailable }
            throw AskHostedError.consentRequired
        }
        if configuration.scope == .savedMetadata, evidence.candidates.isEmpty, request.attachment == nil {
            return .init(summary: "I couldn’t find a matching saved place.", candidates: [], paragraphs: [.init(id: "no-match", spans: [.text("I couldn’t find a matching saved place. Do you remember part of its name?")], sourceIDs: [])], listedCandidateIDs: [])
        }
        try Task.checkCancellation()
        if configuration.environment == .production {
            // The broker performed synthesis within the SAME held request. Never submit a second paid HTTP request.
            guard request.attachment == nil,let id=request.performanceID,let data=await brokerAnswers.take(id) else {throw AskHostedError.invalidResponse}
            return try decodeAnswer(data,evidence:evidence,tools:tools)
        }
        let credential = try await token()
        guard credential.count >= 43, credential.count <= 128,
              credential.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "_" || $0 == "-") }) else { throw AskHostedError.disabled }
        var payload: [String: Any] = [
            "version": configuration.scope == .synthetic ? 1 : 2, "synthetic": configuration.scope == .synthetic, "consent": true, "requestID": UUID().uuidString,
            "mode": request.mode == .collection ? "collection" : "importText", "text": request.text.isEmpty ? "What places are shown in this screenshot?" : request.text,
            "candidates": evidence.candidates.map { ["id": $0.id, "name": $0.name, "sourceIDs": $0.sourceIDs] as [String: Any] },
            "sources": evidence.sources.map { ["id": $0.id, "author": $0.author, "excerpt": $0.excerpt] }
        ]
        if let image = request.attachment {
            _ = try image.validated()
            payload["attachment"] = ["mime": "image/jpeg", "base64": image.jpeg.base64EncodedString(), "selected": true]
        }
        let body = try JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])
        guard body.count <= (request.attachment == nil ? 32768 : 300000) else { throw AskError.inputLimit }
        var http = URLRequest(url: configuration.endpoint)
        http.httpMethod = "POST"; http.httpBody = body; http.timeoutInterval = request.attachment == nil ? 45 : 60
        http.setValue("application/json", forHTTPHeaderField: "Content-Type")
        http.setValue("Feast/1.0", forHTTPHeaderField: "User-Agent")
        http.setValue("Bearer " + credential, forHTTPHeaderField: "Authorization")
        let networkStart = DispatchTime.now().uptimeNanoseconds
        let (data, response) = try await send(http)
        let trace = request.performanceID ?? UUID()
        await AskPerformanceRecorder.shared.record(.network, milliseconds: AskPerformanceRecorder.milliseconds(since: networkStart), traceID: trace)
        await AskPerformanceRecorder.shared.recordServerTiming(response.value(forHTTPHeaderField: "Server-Timing"), traceID: trace)
        try Task.checkCancellation()
        guard response.statusCode == 200 else {
            if response.statusCode == 502, data.count <= 4096,
               let diagnostic = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let reason = diagnostic["reason"] as? String, reason == "invalid_answer" || reason.hasPrefix("invalid_answer_") {
                throw AskHostedError.answerRejected
            }
            throw AskHostedError.failure(status: response.statusCode, data: data)
        }
        guard response.url == configuration.endpoint, data.count <= 65536,
              response.mimeType == "application/json" else { throw AskHostedError.invalidResponse }
        return try decodeAnswer(data,evidence:evidence,tools:tools)
    }
    private func decodeAnswer(_ data:Data,evidence:AskEvidence,tools:AskReadTools) throws -> AskResponse {
        let wire = try JSONDecoder().decode(WireAnswer.self, from: data)
        guard wire.version == 1, wire.summary.count <= 3000, wire.candidateIDs.count <= 6,
              Set(wire.candidateIDs).count == wire.candidateIDs.count else { throw AskHostedError.invalidResponse }
        let candidates = try wire.candidateIDs.map { id in
            guard let candidate = evidence.candidates.first(where: { $0.id == id }) else { throw AskHostedError.invalidResponse }
            return candidate
        }
        let paragraphs = try (wire.paragraphs ?? []).map { paragraph in
            let spans: [AskAnswerSpan] = try paragraph.spans.map { span in
                switch span.type {
                case "text": return .text(span.value)
                case "place": return .place(span.value)
                default: throw AskHostedError.invalidResponse
                }
            }
            return AskAnswerParagraph(id: paragraph.id, spans: spans, sourceIDs: paragraph.sourceIDs)
        }
        return try tools.checked(.init(summary: wire.summary, candidates: candidates, paragraphs: paragraphs, listedCandidateIDs: []))
    }
    private func discover(_ request: AskRequest) async throws -> AskResponse {
        guard request.attachment == nil else { throw AskHostedError.consentRequired }
        guard let criteria = AskPublicCriteria.make(request.retrievalText) else {
            return .init(summary: "Which city or area should I search?", candidates: [], paragraphs: [.init(id: "region", spans: [.text("Which city or area should I search?")], sourceIDs: [])], listedCandidateIDs: [])
        }
        guard await webEnabled() else {
            return .init(summary: "Current web search isn’t available yet.", candidates: [], paragraphs: [.init(id: "web-unavailable", spans: [.text("Current web search isn’t available yet. You can still ask about saved places.")], sourceIDs: [])], listedCandidateIDs: [])
        }
        try Task.checkCancellation()
        // Only enum public criteria leave the device: no raw question/history or saved records.
        let body = try JSONEncoder().encode(PublicRequest(version: 3, requestID: UUID().uuidString, mode: "discovery", criteria: criteria))
        let credential = try await token()
        guard (43...128).contains(credential.count), credential.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "_" || $0 == "-") }) else { throw AskHostedError.disabled }
        var http = URLRequest(url: configuration.endpoint)
        http.httpMethod = "POST"; http.httpBody = body; http.timeoutInterval = 75
        http.setValue("application/json", forHTTPHeaderField: "Content-Type")
        http.setValue("Feast/1.0", forHTTPHeaderField: "User-Agent")
        http.setValue("Bearer " + credential, forHTTPHeaderField: "Authorization")
        let networkStart = DispatchTime.now().uptimeNanoseconds
        let (data,response) = try await send(http)
        let trace = request.performanceID ?? UUID()
        await AskPerformanceRecorder.shared.record(.network, milliseconds: AskPerformanceRecorder.milliseconds(since: networkStart), traceID: trace)
        await AskPerformanceRecorder.shared.recordServerTiming(response.value(forHTTPHeaderField: "Server-Timing"), traceID: trace)
        try Task.checkCancellation()
        guard response.statusCode == 200 else { throw AskHostedError.failure(status: response.statusCode, data: data) }
        guard response.url == configuration.endpoint, response.mimeType == "application/json", data.count <= 65536 else { throw AskHostedError.invalidResponse }
        let wire = try JSONDecoder().decode(WebAnswer.self, from: data)
        guard wire.version == 2, wire.paragraphs.count <= 3, wire.places.count <= 3,
              wire.summary.count <= 3000, wire.paragraphs.allSatisfy({ !$0.text.isEmpty && $0.text.count <= 1000 && $0.citations.count <= 6 && $0.citations.allSatisfy { $0.safeURL != nil && $0.title.count <= 200 } }),
              wire.places.allSatisfy({ $0.region == criteria.region && $0.name.count <= 200 }) else { throw AskHostedError.invalidResponse }
        for place in wire.places {
            guard wire.paragraphs.flatMap(\.citations).contains(where: { $0.url == place.sourceURL }) else { throw AskHostedError.invalidResponse }
        }
        return .init(summary: wire.summary, candidates: [], paragraphs: wire.paragraphs.map { .init(id: $0.id, spans: [.text($0.text)], sourceIDs: [], citations: $0.citations) }, listedCandidateIDs: [], webPlaces: wire.places)
    }
    private struct PublicRequest: Encodable { let version: Int; let requestID: String; let mode: String; let criteria: AskPublicCriteria }
    private struct WebAnswer: Decodable { let version: Int; let summary: String; let paragraphs: [WebParagraph]; let places: [AskWebPlace] }
    private struct WebParagraph: Decodable { let id: String; let text: String; let citations: [AskWebCitation] }
    private struct WireAnswer: Decodable {
        let version: Int
        let summary: String
        let candidateIDs: [String]
        let paragraphs: [WireParagraph]?
    }
    private struct WireParagraph: Decodable {
        let id: String
        let spans: [WireSpan]
        let sourceIDs: [String]
    }
    private struct WireSpan: Decodable { let type: String; let value: String }
}

/// A private session rejects redirects so tester credentials cannot follow another host.
final class AskHostedHTTP: @unchecked Sendable {
    static let shared=AskHostedHTTP()
    private let session:URLSession
    init(configuration:URLSessionConfiguration = .ephemeral) {
        configuration.httpCookieStorage=nil;configuration.urlCache=nil
        configuration.httpShouldSetCookies=false;configuration.urlCredentialStorage=nil
        session=URLSession(configuration:configuration,delegate:AskHostedTransportDelegate(trace:nil),delegateQueue:nil)
    }
    deinit {session.invalidateAndCancel()}
    /// Stop prevents further reasoning/actions immediately. An exchange already
    /// dispatched must retain its connection until its bounded response/timeout so
    /// the service can settle usage. The caller records settlement metadata, then rejects a late answer before use.
    static func settleDispatched<T:Sendable>(_ operation:@escaping @Sendable ()async throws->T)async throws->T {
        try Task.checkCancellation()
        let exchange=Task {try await operation()}
        return try await exchange.value
    }
    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let body=request.httpBody.flatMap {(try? JSONSerialization.jsonObject(with:$0)) as? [String:Any]}
        if let lease=AskProviderAttemptScope.lease,request.httpMethod=="POST",request.url?.path=="/v1/answer",
           body?["mode"] as? String != "retryFence",let raw=body?["requestID"] as? String,let root=UUID(uuidString:raw) {
            try await AskProviderAttemptScope.store.register(root,lease:lease)
        }
        if request.httpMethod=="POST",request.url?.path=="/v1/answer",let mode=body?["mode"] as? String,["conversationStep","authorizeChange","webSearch"].contains(mode) {
            return try await Self.settleDispatched {try await self.exchange(request)}
        }
        return try await exchange(request)
    }
    private func exchange(_ request:URLRequest)async throws->(Data,HTTPURLResponse) {
        let (data, response) = try await session.data(for:request,delegate:AskHostedTransportDelegate(trace:AskPipelineScope.trace))
        guard let http = response as? HTTPURLResponse else { throw AskHostedError.invalidResponse }
        return (data, http)
    }
}

/// A separate delegate avoids the session -> owner -> session retain cycle.
/// Both the session and each task reject redirects. Metrics contain no destinations.
final class AskHostedTransportDelegate:NSObject,URLSessionTaskDelegate,@unchecked Sendable {
    let trace:AskPipelineTrace?
    init(trace:AskPipelineTrace?) {self.trace=trace}
    func urlSession(_ session:URLSession,task:URLSessionTask,didFinishCollecting metrics:URLSessionTaskMetrics) {
        trace?.record(.connectionMetrics,milliseconds:metrics.taskInterval.duration*1000,counters:[.networkTransactions:metrics.transactionMetrics.count,.reusedConnections:metrics.transactionMetrics.filter(\.isReusedConnection).count])
        for transaction in metrics.transactionMetrics {
            for (stage,start,end):(AskPipelineStage,Date?,Date?) in [(.dns,transaction.domainLookupStartDate,transaction.domainLookupEndDate),(.connection,transaction.connectStartDate,transaction.connectEndDate),(.tls,transaction.secureConnectionStartDate,transaction.secureConnectionEndDate)] {
                if let start,let end {trace?.record(stage,milliseconds:end.timeIntervalSince(start)*1000)}
            }
        }
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) { completionHandler(nil) }
}

/// Offline/local collection reads remain available; never invent a remote answer.
struct AskUnavailableProvider: AskFeastProvider {
    let label = "Ask Feast"
    func answer(_ request: AskRequest, tools: AskReadTools) async throws -> AskResponse { throw AskHostedError.disabled }
}
