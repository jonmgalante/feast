// Synthetic Release-only regression entry point. The runner copies this over FeastApp.swift in an isolated source copy.
#if FEAST_DURABLE_RECOVERY
#error("Release first-send smoke must exercise the production recovery-off configuration")
#endif
import SwiftUI
import CoreData
import Foundation

@MainActor enum Repro {
    static let persistence = PersistenceController(inMemory: true, cloudKitSyncConfiguration: nil)
    static var didStart = false
    static func mark(_ value: String) {
        let line = "\(Date().timeIntervalSince1970) \(value)\n"
        print(line)
        let file = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("repro-stages.txt")
        let prior = (try? String(contentsOf: file, encoding: .utf8)) ?? ""
        try? (prior + line).write(to: file, atomically: true, encoding: .utf8)
    }
    static func wire(_ request: URLRequest) throws -> (Data, HTTPURLResponse) {
        mark("TRANSPORT_STUB_REACHED")
        if !ProcessInfo.processInfo.arguments.contains("-reproAnswer") { throw URLError(.notConnectedToInternet) }
        let step = try JSONDecoder().decode(AskConversationStep.self, from: request.httpBody ?? Data())
        var reply = AskConversationReply(version: step.version, requestID: step.requestID, step: step.step, kind: "answer", text: "This is a synthetic local answer.", continuation: "mock-only", model: "gpt-6.1-sol", call: nil)
        if step.version == 10 { reply.nativeEvidence = .init(version: 1, blocks: [], sources: [], actions: []); reply.finalCitations = [] }
        return (try JSONEncoder().encode(reply), HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: ["Content-Type": "application/json"])!)
    }
    static func start(_ state: AskFeastTabState) async {
        guard !didStart else { return }; didStart = true
        mark("HARNESS_START")
        do {
            let context = persistence.viewContext
            let city = FeastList(context: context); city.id = UUID(); city.name = "Synthetic Test City"; city.createdAt = Date(); city.updatedAt = Date()
            let count = ProcessInfo.processInfo.arguments.contains("-reproLarge") ? 2000 : 1
            for i in 0..<count {
                let place = SavedPlace(context: context); place.id = UUID(); place.applePlaceID = "synthetic-\(i)"; place.displayNameSnapshot = "Synthetic Cafe \(i)"; place.feastList = city
                place.createdAt = Date(); place.updatedAt = Date(); place.placeStatus = .wantToTry; place.placeTypeValue = .cafe
                place.note = String(repeating: "Synthetic note. ", count: 100)
            }
            try context.save()
            let adapter = AskSavedCollection(context: context, visibleCities: { [city.id!] })
            let hosted = AskHostedProvider(configuration: .init(environment: .development, endpoint: URL(string: "https://synthetic-repro.workers.dev/v1/answer")!, scope: .savedMetadata), token: { String(repeating: "A", count: 43) }, approve: { _,_ in true }, send: { request in try await MainActor.run { try wire(request) } }, libraryToolsEnabled: {true}, permission: {true}, libraryPlanVersion: {7}, nativeResearchEnabled: {true}, collectionQueriesEnabled: {true}, retainedHistoryEnabled: {true})
            state.prepareSavedCollection(adapter, provider: hosted)
            guard let session = state.session else { mark("PREPARE_FAILED \(state.error ?? "nil")"); return }
            guard state.collectionCount==count else {mark("HARNESS_ERROR synthetic collection count mismatch");return}
            mark("PREPARED count=\(state.collectionCount)")
            try await Task.sleep(for: .seconds(2))
            try state.refreshSavedCollection()
            session.input = "List my saved places in west village, sorted by name. Include their statuses."
            mark("BEFORE_SEND")
            session.runAutomatically()
            mark("AFTER_SEND")
            for i in 1...12 { try await Task.sleep(for: .seconds(1)); mark("TICK \(i) loading=\(session.isLoading) turns=\(session.turns.count) error=\(session.error ?? "nil")") }
            session.flushHistory()
            guard !session.isLoading, let turn=session.turns.last else { mark("HARNESS_ERROR turn did not settle"); return }
            if ProcessInfo.processInfo.arguments.contains("-reproAnswer") {
                guard turn.status == .complete else { mark("HARNESS_ERROR expected completed synthetic answer"); return }
            } else {
                guard case .failed(let message) = turn.status,
                      message==AskHostedError.message(for:URLError(.notConnectedToInternet)) else {
                    mark("HARNESS_ERROR expected offline transport failure");return
                }
            }
            guard let reopenedStore=AskConversationStore.applicationStore() else {mark("HARNESS_ERROR missing history store");return}
            let reopened=AskSession(index:try adapter.index(),provider:hosted)
            reopened.restoreHistory(from:reopenedStore)
            guard reopened.turns.count==1,let restored=reopened.turns.first,restored.id==turn.id,
                  restored.request.text==turn.request.text,restored.status==turn.status else {
                mark("HARNESS_ERROR durable history roundtrip differs");return
            }
            if ProcessInfo.processInfo.arguments.contains("-reproAnswer") {
                let expected="This is a synthetic local answer."
                guard let response=turn.response,AskAnswerCopy.text(response).contains(expected),
                      let restoredResponse=restored.response,AskAnswerCopy.text(restoredResponse).contains(expected),
                      let visible=session.presentedTurns().last?.response,AskAnswerCopy.text(visible).contains(expected) else {
                    mark("HARNESS_ERROR answer or restored/presented content differs");return
                }
                let diagnostics=await AskPerformanceRecorder.shared.pipelineSnapshot()
                guard diagnostics.contains(where:{$0.turnID==turn.id && $0.samples.contains(where:{$0.stage == .answerViewObserved})}) else {
                    mark("HARNESS_ERROR actual answer panel was not observed");return
                }
                mark("ANSWER_RENDER_VERIFIED")
            }
            mark("HISTORY_RELOAD_VERIFIED")
            mark("FINISHED")
        } catch { mark("HARNESS_ERROR \(error)") }
    }
}
struct ReproView: View {
    @StateObject private var state = AskFeastTabState()
    @FocusState private var composerFocused: Bool
    var body: some View {
        NavigationStack {
            Group {
                if let session = state.session { AskSavedCollectionPanel(state: state, session: session, focused: $composerFocused) }
                else { Text("Preparing synthetic crash reproduction") }
            }.navigationTitle("Synthetic crash reproduction")
        }
        .environment(\.managedObjectContext, Repro.persistence.viewContext)
        .environment(\.persistenceController, Repro.persistence)
        .task { await Repro.start(state) }
    }
}
@main struct FeastApp: App { var body: some Scene { WindowGroup { ReproView() } } }
