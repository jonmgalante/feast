import Combine
import Foundation
import CoreData

/// Root-owned lifetime: changing tabs never recreates the collection/session.
@MainActor final class AskFeastTabState: ObservableObject {
#if FEAST_TESTS
    @Published private(set) var sandbox: AskPrototypeSandbox?
#endif
    @Published private(set) var session: AskSession?
    @Published private(set) var error: String?
    @Published private(set) var savedCollection: AskSavedCollection?
    @Published private(set) var collectionCount = 0
    @Published private(set) var availableRecordIDs: Set<String> = []
    @Published private(set) var availablePersonalPlaces: [AskPersonalPlace] = []
    @Published private(set) var screenshotSendingAvailable = false
    @Published private(set) var discoveryAvailable = false
    @Published private(set) var libraryToolsAvailable = false
    @Published private(set) var libraryToolsVersion = 1
    @Published private(set) var publicBusinessAvailable = false
    @Published private(set) var nativeResearchAvailable = false
    @Published private(set) var recoveryAvailable = false
    private var changeEngine:AskCollectionChangeEngine?
    @Published var savedMessage: String?
    @Published var savedCandidates: [AskSavedCandidateKey: String] = [:]
    @Published var savedRecordIDs: [AskSavedCandidateKey: String] = [:]
    /// Rebuild the legacy hosted-answer metadata projection. Rich conversation tools use their separate consented scope.
    func approveHosted(_ request: AskRequest, evidence: AskEvidence, exactSelection:Bool = false) async -> Bool {
        guard request.mode == .collection, !request.fromOCR, !Task.isCancelled else { return false }
        do {
            let index: AskLocalIndex
            if let savedCollection { index = try requestIndex(savedCollection) }
            else {
#if FEAST_TESTS
                guard hostedSynthetic, let sandbox else { return false }
                index = try sandbox.localIndex()
#else
                return false
#endif
            }
            return try Self.verifiedHostedEvidence(request,index:index,evidence:evidence,exactSelection:exactSelection)
        } catch { return false }
    }

    static func verifiedHostedEvidence(_ request:AskRequest,index:AskLocalIndex,evidence:AskEvidence,exactSelection:Bool) throws -> Bool {
        var tools=try AskReadTools(request:request,index:index)
        if exactSelection {
            guard request.referenceOnly else {return false}
            tools=try tools.resolving(request.referencedIDs).1
        }
        let expected=try tools.collection(.init(text:request.text,limit:6))
        return evidence.candidates == expected.candidates && evidence.sources == expected.sources
    }

    func prepareSavedCollection(_ adapter: AskSavedCollection, provider: any AskFeastProvider) {
        guard session == nil else { return }
        do {
            let index = try requestIndex(adapter)
            savedCollection = adapter; collectionCount = index.records.count; availableRecordIDs = Set(index.records.map(\.id)); availablePersonalPlaces = try adapter.personalPlaces()
            let legacy=AskLibraryProvider(remote:provider,places:{try await adapter.personalPlaces()},intentPlanner:provider as? any AskLibraryIntentPlanning,snapshot:{try await adapter.librarySnapshot()})
            guard let base=FileManager.default.urls(for:.applicationSupportDirectory,in:.userDomainMask).first else {throw AskError.invalidEvidence}
            let engine=AskCollectionChangeEngine(adapter:adapter,journalURL:base.appendingPathComponent("AskFeast/collection-actions-v1.json"))
            changeEngine=engine
            session=AskSession(index:index,provider:AskAgentProvider(remote:provider,fallback:legacy,adapter:adapter,engine:engine,searchMaps:{query in try await ApplePlacesService().search(query:query)},recoveryStore:AskRecoveryFeature.enabled ? AskTurnRecoveryStore.shared : nil,resolveMaps:{id in try await ApplePlacesService().resolve(placeID:id)}))
            session?.refreshIndex={try adapter.index()}
            session?.collectionExecutor={id,undo in try engine.performExplicitAction(id,undo:undo)}
            session?.collectionStatus={id in try engine.actionStatus(id)}
            session?.collectionReceipts={id in try engine.receipts(forTurn:id)}
            session?.collectionRecovery={chat in try engine.recoverableTurns(in:chat)}
            session?.collectionClear={chat in try engine.dismissRecovery(in:chat)}
            session?.fieldStatus = {action in try adapter.fieldActionStatus(action)}
            session?.fieldExecutor = { action,mode in try adapter.apply(action,mode:mode) }
            if let store = AskConversationStore.applicationStore() {
                session?.restoreHistory(from: store)
            }
            error = nil
        } catch { self.error = "Saved places could not be read. Nothing was sent." }
    }
    private func requestIndex(_ adapter: AskSavedCollection) throws -> AskLocalIndex {

        return try adapter.index()
    }
    func connectActivatedPhone(_ configuration:AskHostedConfiguration)->Bool {
        guard let adapter=savedCollection,let engine=changeEngine,let session,!session.isLoading else{return false}
        let provider=productionProvider(configuration:configuration)
        let legacy=AskLibraryProvider(remote:provider,places:{try await adapter.personalPlaces()},intentPlanner:provider,snapshot:{try await adapter.librarySnapshot()})
        return session.replaceProviderWhenIdle(AskAgentProvider(remote:provider,fallback:legacy,adapter:adapter,engine:engine,searchMaps:{query in try await ApplePlacesService().search(query:query)},recoveryStore:AskRecoveryFeature.enabled ? AskTurnRecoveryStore.shared : nil,resolveMaps:{id in try await ApplePlacesService().resolve(placeID:id)}))
    }
    private var capabilitiesEndpoint: URL?
    func refreshHostedCapabilities(endpoint: URL? = nil) async {
        if let endpoint {if capabilitiesEndpoint != endpoint {nativeResearchAvailable=false;recoveryAvailable=false};capabilitiesEndpoint = endpoint }
        guard AskPrivacy.onlineAllowed else { return }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil; configuration.urlCache = nil
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        let health = capabilitiesEndpoint.map { $0.deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("health") } ?? URL(string:"https://feast-proxy-dev.jonmgalante.workers.dev/health")!
        var request = URLRequest(url: health)
        request.timeoutInterval = 10
        request.setValue("Feast/1.0", forHTTPHeaderField: "User-Agent")
        guard let (data,response) = try? await session.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200, data.count < 4096,
              let info = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }
        recoveryAvailable = info["answerJobsVersion"] as? Int == 1
        nativeResearchAvailable = info["nativeResearchEnabled"] as? Bool == true && (info["agentProtocolVersions"] as? [Int])?.contains(10)==true
        screenshotSendingAvailable = info["selectedScreenshotEnabled"] as? Bool == true
        discoveryAvailable = info["webDiscoveryEnabled"] as? Bool == true
        libraryToolsAvailable = info["savedToolsEnabled"] as? Bool == true
        publicBusinessAvailable = info["publicBusinessLookupEnabled"] as? Bool == true && info["publicBusinessToolsVersion"] as? Int == 1
        libraryToolsVersion = [2,3].contains(info["savedToolsVersion"] as? Int ?? 1) ? info["savedToolsVersion"] as! Int : 1
        if publicBusinessAvailable {libraryToolsVersion=4}
        if info["agentProtocolVersion"] as? Int == 8,info["agentToolsEnabled"] as? Bool == true {libraryToolsVersion=5}
        if (info["agentProtocolVersions"] as? [Int])?.contains(9)==true,info["agentToolsEnabled"] as? Bool == true {libraryToolsVersion=6}
        if libraryToolsVersion>=6,info["collectionContextVersion"] as? Int==1 {libraryToolsVersion=7}
    }
    func refreshSavedCollection() throws {
        guard let savedCollection else { throw AskError.invalidEvidence }
        let index = try requestIndex(savedCollection)
        collectionCount = index.records.count
        availableRecordIDs = Set(index.records.map(\.id))
        availablePersonalPlaces = try savedCollection.personalPlaces()
        session?.updateIndex(index)
    }

    @Published var hostedSynthetic = false
    @Published var hostedSetupMessage: String?
    var appliedQA = false
    var selectedInitialQA = false

    func markUnavailable(message: String? = nil) {
        error = message ?? "Ask Feast isn’t configured on this device yet."
    }
#if FEAST_TESTS
    /// Automated test harness only; normal/Release navigation never calls this fixture factory.
    func prepare(model: NSManagedObjectModel? = nil, provider: any AskFeastProvider = MockAskFeastProvider()) {
        guard sandbox == nil else { return }
        do {
            let sandbox = try AskPrototypeSandbox(model: model)
            let session = AskSession(index: try sandbox.localIndex(), provider: provider)
            self.sandbox = sandbox
            self.session = session
            error = nil
        } catch { self.error = error.localizedDescription }
    }
#endif
    /// Prepared for the separately approved simulator credential handoff; never selected automatically.
    func hostedProvider(scope: AskDataScope = .synthetic, token: @escaping @Sendable () async throws -> String,
                        send: @escaping @Sendable (URLRequest) async throws -> (Data, HTTPURLResponse)) -> AskHostedProvider {
        AskHostedProvider(configuration: .init(environment: .development,
            endpoint: URL(string: "https://feast-proxy-dev.jonmgalante.workers.dev/v1/answer")!, scope: scope),
            token: token, approve: { [weak self] request, evidence in
                guard let self else { return false }
                return await self.approveHosted(request, evidence: evidence)
            }, send: send, webEnabled: { [weak self] in await self?.discoveryAvailable ?? false }, libraryToolsEnabled: { [weak self] in await self?.libraryToolsAvailable ?? false }, permission: { AskPrivacy.onlineAllowed },libraryPlanVersion:{ [weak self] in await self?.libraryToolsVersion ?? 1 },publicLookupEnabled:{[weak self] in await self?.publicBusinessAvailable ?? false},nativeResearchEnabled:{[weak self] in await self?.nativeResearchAvailable ?? false},recoveryEnabled:{[weak self] in guard AskRecoveryFeature.enabled else{return false};return await self?.recoveryAvailable ?? false})
    }
    func productionProvider(configuration: AskHostedConfiguration) -> AskHostedProvider {
        AskHostedProvider(configuration:configuration,token:{ try configuration.ownerValidation ? AskOwnerValidationAccess.credential() : AskProductionAccess.credential() },approve:{ [weak self] request,evidence in
            guard let self else { return false }; return await self.approveHosted(request,evidence:evidence,exactSelection:true)
        },send:{ try await AskHostedHTTP.shared.send($0) },webEnabled:{ [weak self] in await self?.discoveryAvailable ?? false },libraryToolsEnabled:{ [weak self] in await self?.libraryToolsAvailable ?? false },permission:{ AskPrivacy.onlineAllowed },libraryPlanVersion:{ [weak self] in await self?.libraryToolsVersion ?? 1 },publicLookupEnabled:{[weak self] in await self?.publicBusinessAvailable ?? false},prepareCapabilities:{[weak self] in await self?.refreshHostedCapabilities(endpoint:configuration.endpoint)},nativeResearchEnabled:{[weak self] in await self?.nativeResearchAvailable ?? false},recoveryEnabled:{[weak self] in guard AskRecoveryFeature.enabled else{return false};return await self?.recoveryAvailable ?? false},recoveryCleanupToken:{try configuration.ownerValidation ? AskOwnerValidationAccess.recoveryCleanupCredential(endpoint:configuration.endpoint) : AskProductionAccess.recoveryCleanupCredential(endpoint:configuration.endpoint)})
    }
    func disableOnline() {
        session?.revokeRecovery(); session?.attachment = nil
        screenshotSendingAvailable = false; discoveryAvailable = false; libraryToolsAvailable = false;publicBusinessAvailable=false;libraryToolsVersion = 1
    }
    func recordSave(turnID: UUID, candidateID: String, name: String, city: String, recordID: String?) {
        let key = AskSavedCandidateKey(turnID: turnID, candidateID: candidateID)
        savedCandidates[key] = city
        savedRecordIDs[key] = recordID.flatMap { UUID(uuidString: $0)?.uuidString }
        savedMessage = "Saved \(name) to \(city) in Feast."
    }
    func selectionChanged(to tab: Int) { if tab != 2 { session?.cancel(userInitiated:false) } else {session?.restorePendingRecovery(activityResume:true)} }
}
