import Foundation

enum AskPerformanceStage: String, Codable, Sendable { case research, extraction, validation, network, render, overall, persistence }
struct AskPerformanceSample: Codable, Sendable {
    let traceID: UUID
    let stage: AskPerformanceStage
    let milliseconds: Double
}
/// Bounded metadata-only measurements. Never records questions, places, images, headers or credentials.
actor AskPerformanceRecorder {
    static let shared = AskPerformanceRecorder()
    private var samples: [AskPerformanceSample] = []
    private var pipelines:[AskPipelineSnapshot] = []
    func recordPipeline(_ value:AskPipelineSnapshot) {
        if let prior=pipelines.first(where:{$0.traceID==value.traceID}),prior.revision>value.revision {return}
        pipelines.removeAll {$0.traceID==value.traceID}
        pipelines.append(value)
        if pipelines.count>20 {pipelines.removeFirst(pipelines.count-20)}
#if !FEAST_TESTS
        guard let base=FileManager.default.urls(for:.documentDirectory,in:.userDomainMask).first else{return}
        _ = AskPipelineArchive.write(pipelines,to:base.appendingPathComponent("AskPipelineDiagnostics.json"))
#endif
    }
    func pipelineSnapshot()->[AskPipelineSnapshot] {pipelines}
    func record(_ stage: AskPerformanceStage, milliseconds: Double, traceID: UUID) {
        guard milliseconds.isFinite, (0...180000).contains(milliseconds) else { return }
        samples.append(.init(traceID: traceID, stage: stage, milliseconds: milliseconds))
        if samples.count > 100 { samples.removeFirst(samples.count - 100) }
#if !FEAST_TESTS
        if let base=FileManager.default.urls(for:.documentDirectory,in:.userDomainMask).first,let data=try? JSONEncoder().encode(samples) {try? data.write(to:base.appendingPathComponent("AskPerformanceDiagnostics.json"),options:.atomic)}
#endif
    }
    func snapshot() -> [AskPerformanceSample] { samples }
    static func milliseconds(since start: UInt64) -> Double { Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000 }
    func recordServerTiming(_ value: String?, traceID: UUID) {
        guard let value, value.count <= 512 else { return }
        for part in value.split(separator: ",").prefix(4) {
            let pair = part.trimmingCharacters(in: .whitespaces).components(separatedBy: ";dur=")
            guard pair.count == 2, let stage = AskPerformanceStage(rawValue: pair[0]), [.research,.extraction,.validation].contains(stage), let duration = Double(pair[1]) else { continue }
            record(stage, milliseconds: duration, traceID: traceID)
        }
    }
}

/// Local diagnostics only. Closed stage names and numeric counters prevent content,
/// URLs, tool arguments, headers, credentials and provider messages entering traces.
/// Stages are nested/overlapping; their durations must not be summed as wall time.
enum AskPipelineStage: String, Codable, Sendable {
    case preparation, context, transport, inputCount, provider, ledger, decode, dns, connection, tls, connectionMetrics
    case evidence, collectionRead, businessLookup, mapsLookup, websiteInspection, research, toolExecution
    case authorization, mutation, reconciliation, retry, assembly, persistence
    case validation, taskExit, answerAvailable, answerViewObserved, stopRequested
}
enum AskPipelineCounter: String, Codable, Sendable {
    case requestBytes, responseBytes, inputTokens, outputTokens, cachedInputTokens, reasoningTokens, networkTransactions, reusedConnections
    case evidenceSourcesSeen, evidenceSourcesRetained, evidenceSourcesOmitted, evidenceRequiredSources, evidenceTextUnits, evidenceActions, evidenceBlocks
}
struct AskPipelineSample: Codable, Sendable {
    let stage: AskPipelineStage
    let milliseconds: Double
    let counters: [String:Int]
    var calls:Int = 1
}
struct AskPipelineSnapshot: Codable, Sendable {
    let version: Int
    let traceID: UUID
    let turnID: UUID
    let revision: Int
    let droppedSamples: Int
    let outcome: AskPipelineOutcome
    let samples: [AskPipelineSample]
}
enum AskPipelineOutcome:String,Codable,Sendable {case running,completed,failed,cancelled}
/// One trace per attempt, inherited by child async calls. No global result cache.
final class AskPipelineTrace: @unchecked Sendable {
    let id: UUID
    let turnID: UUID
    let started = DispatchTime.now().uptimeNanoseconds
    private let lock = NSLock()
    private var samples: [AskPipelineSample] = []
    private var revision=0,dropped=0,ordinarySamples=0
    private static let terminalStages:Set<AskPipelineStage> = [.validation,.taskExit,.answerAvailable,.answerViewObserved,.stopRequested,.persistence]
    private var outcome:AskPipelineOutcome = .running
    init(id: UUID, turnID:UUID? = nil) { self.id=id;self.turnID=turnID ?? id }
    func finish(_ state:AskPipelineOutcome) {lock.withLock {outcome=state;revision+=1}}
    func record(_ stage: AskPipelineStage, milliseconds: Double, counters: [AskPipelineCounter:Int] = [:], calls:Int = 1) {
        guard milliseconds.isFinite,(0...3600000).contains(milliseconds),(1...64).contains(calls) else { return }
        let safe=Dictionary(uniqueKeysWithValues:counters.filter {(0...16777216).contains($0.value)}.map {($0.key.rawValue,$0.value)})
        lock.withLock {
            revision+=1
            let sample=AskPipelineSample(stage:stage,milliseconds:milliseconds,counters:safe,calls:calls)
            if Self.terminalStages.contains(stage) {
                if let i=samples.firstIndex(where:{$0.stage==stage}) {
                    if stage == .persistence {
                        let prior=samples[i],count=prior.calls+calls,ms=prior.milliseconds+milliseconds
                        if count<=64,ms<=3600000 {samples[i] = .init(stage:stage,milliseconds:ms,counters:[:],calls:count)}else{dropped+=1}
                    }else {samples[i]=sample}
                }
                else if samples.count<128 {samples.append(sample)}else{dropped+=1}
            }else if ordinarySamples<112 {samples.append(sample);ordinarySamples+=1}else{dropped+=1}
        }
    }
    func elapsed(_ stage: AskPipelineStage, since start: UInt64, counters: [AskPipelineCounter:Int] = [:]) {
        record(stage,milliseconds:AskPerformanceRecorder.milliseconds(since:start),counters:counters)
    }
    func snapshot() -> AskPipelineSnapshot { lock.withLock {.init(version:1,traceID:id,turnID:turnID,revision:revision,droppedSamples:dropped,outcome:outcome,samples:samples)} }
}
enum AskPipelineScope {
    @TaskLocal static var trace: AskPipelineTrace?
    static func record(_ stage:AskPipelineStage,since start:UInt64) { trace?.elapsed(stage,since:start) }
}
/// Optional additive transport diagnostics; never needed to accept an answer.
/// Parse numerics from an explicit allowlist, never arbitrary provider fields.
struct AskBackendPerformance: Sendable {
    let samples:[AskPipelineSample]
    init?(_ raw:Any?) {
        guard let value=raw as? [String:Any],value["version"] as? Int == 1,
              let stages=value["stages"] as? [String:Any],stages.count<=12 else {return nil}
        let counters=value["counters"] as? [String:Any] ?? [:]
        let safeCounters=Dictionary(uniqueKeysWithValues:AskPipelineCounter.all.map {key in (key.rawValue,counters[key.rawValue] as? Int)}.compactMap {key,value in value.flatMap {(0...16777216).contains($0) ? (key,$0) : nil}})
        samples=stages.keys.sorted().compactMap {key in
            guard let stage=AskPipelineStage(rawValue:key),[.preparation,.inputCount,.provider,.ledger,.decode,.assembly,.evidence].contains(stage),
                  let item=stages[key] as? [String:Any],let ms=item["milliseconds"] as? Double,ms.isFinite,(0...3600000).contains(ms),
                  let calls=item["calls"] as? Int,(1...64).contains(calls) else{return nil}
            // A sample per stage aggregate; call count is retained in receipt metadata below.
            return .init(stage:stage,milliseconds:ms,counters:safeCounters.filter {key,_ in
                let evidence=key.hasPrefix("evidence")
                return stage == .evidence ? evidence : stage == .provider && !evidence
            },calls:calls)
        }
    }
    func record() {
        for sample in samples { AskPipelineScope.trace?.record(sample.stage,milliseconds:sample.milliseconds,counters:Dictionary(uniqueKeysWithValues:sample.counters.compactMap {key,value in AskPipelineCounter(rawValue:key).map {($0,value)}}),calls:sample.calls) }
    }
}
private extension AskPipelineCounter {
    static let all:[Self] = [.requestBytes,.responseBytes,.inputTokens,.outputTokens,.cachedInputTokens,.reasoningTokens,.evidenceSourcesSeen,.evidenceSourcesRetained,.evidenceSourcesOmitted,.evidenceRequiredSources,.evidenceTextUnits,.evidenceActions,.evidenceBlocks]
}

/// Shared production/test persistence path. Failure only loses optional diagnostics.
enum AskPipelineArchive {
    static func write(_ snapshots:[AskPipelineSnapshot],to url:URL)->Bool {
        guard snapshots.count<=20 else{return false}
        var retained=snapshots
        var encoded=try? JSONEncoder().encode(retained)
        while let data=encoded,data.count>512000,retained.count>1 {retained.removeFirst();encoded=try? JSONEncoder().encode(retained)}
        guard let data=encoded,data.count<=512000 else{return false}
        do {try data.write(to:url,options:.atomic);var file=url;var values=URLResourceValues();values.isExcludedFromBackup=true;try file.setResourceValues(values);return true}catch{return false}
    }
}
