import Foundation
import Darwin
import CryptoKit

/// One fixed contract for ordinary native answers. Legacy tools and dormant recovery
/// keep their existing independent bounds; no user-selectable capacity modes.
enum AskNativeCapacity {
    static let requestBytes = 2 * 1024 * 1024
    static let replyBytes = 2 * 1024 * 1024
    static let continuationBytes = 1024 * 1024
}

/// Bounded metadata only: never records question text, tool arguments, reasoning,
/// record names, URLs, headers, credential bytes or provider error messages.
struct AskConversationReceipt:Codable,Sendable {
    let requestID,mode:String
    let step:Int?
    let at:Date
    let elapsedMilliseconds:Double
    let status:Int
    var code:String
    let tool:String?
    let chargedMicroUSD,remainingMicroUSD:Int?
    let stage,providerCode,providerParam:String?
    let providerStatus:Int?
    let itemTypes:[String],itemKeys:[[String]]
    var authorizationApproved:Bool?=nil
    var authorizationReason:String?=nil
    var queryOperation:String?=nil
    var queryGroupBy:String?=nil
    var queryFields:[String]?=nil
    init(requestID:String,mode:String,step:Int?,status:Int,data:Data,elapsed:Double,maximumResponseBytes:Int=400000) {
        self.requestID=UUID(uuidString:requestID)?.uuidString ?? "unknown";self.mode=["conversationStep","authorizeChange","webSearch"].contains(mode) ? mode : "unknown";self.step=step
        at=Date();elapsedMilliseconds=elapsed.isFinite ? min(max(elapsed,0),240000) : 0;self.status=status
        let value=data.count<=maximumResponseBytes ? ((try? JSONSerialization.jsonObject(with:data)) as? [String:Any] ?? [:]) : [:]
        AskBackendPerformance(value["performance"])?.record()
        func bounded(_ value:Any?,_ pattern:String)->String? {guard let text=value as? String,text.range(of:pattern,options:.regularExpression) != nil else{return nil};return text}
        code=bounded(value["error"],"^[a-z_]{1,80}$") ?? (status==200 ? "ok" : "request_failed")
        let call=value["call"] as? [String:Any]
        let name=call?["name"] as? String
        tool=name.flatMap {["query_collection","research_businesses","search_maps","propose_changes","confirm_changes","search_web","read_conversation","retain_findings"].contains($0) ? $0 : nil}
        let budget=value["budget"] as? [String:Any]
        chargedMicroUSD=(budget?["chargedMicroUSD"] as? Int).flatMap {$0 >= 0 ? $0 : nil}
        remainingMicroUSD=(budget?["remainingMicroUSD"] as? Int).flatMap {$0 >= 0 ? $0 : nil}
        let diagnostic=value["diagnostic"] as? [String:Any]
        stage=bounded(diagnostic?["stage"],"^[a-z_]{1,40}$");providerCode=bounded(diagnostic?["providerCode"],"^[a-z_]{1,40}$");providerParam=bounded(diagnostic?["providerParam"],"^[a-zA-Z0-9_.\\[\\]]{1,80}$");providerStatus=diagnostic?["providerStatus"] as? Int
        let shape=Array(((diagnostic?["continuationShape"] as? [[String:Any]]) ?? []).prefix(8))
        itemTypes=shape.map {item in let type=item["type"] as? String ?? "other";return ["reasoning","message","function_call","function_call_output"].contains(type) ? type : "other"}
        let safeKeys:Set<String>=["id","type","summary","content","encrypted_content","status","call_id","name","arguments","role","output","phase"]
        itemKeys=shape.map {Array((($0["keys"] as? [String]) ?? []).filter {safeKeys.contains($0)}.prefix(16))}
        if let decision=value["decision"] as? [String:Any] {
            authorizationApproved=decision["approved"] as? Bool
            authorizationReason=(decision["reason"] as? String).flatMap {["explicit_instruction","accepted_pending","no_instruction","ambiguous","outside_scope"].contains($0) ? $0 : nil}
        }
        queryOperation=(diagnostic?["operation"] as? String).flatMap {["catalog","list","details","compare","count","group","answer"].contains($0) ? $0 : nil}
        queryGroupBy=(diagnostic?["groupBy"] as? String).flatMap {["city","neighborhood","cuisine","status","type"].contains($0) ? $0 : nil}
        queryFields=(diagnostic?["fields"] as? [String]).map {Array($0.filter {["name","city","neighborhood","cuisine","status","type","address","website","instagram","note","tags"].contains($0)}.prefix(11))}

    }
}
actor AskConversationReceipts {
    static let shared=AskConversationReceipts()
    private var entries:[AskConversationReceipt]=[]
    init() {
#if !FEAST_TESTS
        if let base=FileManager.default.urls(for:.documentDirectory,in:.userDomainMask).first,let data=try? Data(contentsOf:base.appendingPathComponent("AskConversationDiagnostics.json")),data.count<=200000,let saved=try? JSONDecoder().decode([AskConversationReceipt].self,from:data),saved.count<=100 {entries=saved}
#endif
    }
    func legacyStoppedAndSettled(_ id:UUID)->Bool {
        let matching=entries.filter {$0.requestID==id.uuidString && $0.mode=="conversationStep"}
        guard let index=matching.lastIndex(where:{$0.status==200 && $0.code=="stopped_settled"}) else{return false}
        return matching.suffix(from:matching.index(after:index)).allSatisfy {$0.status==409}
    }
    func record(_ entry:AskConversationReceipt) {
        let started=DispatchTime.now().uptimeNanoseconds
        defer {AskPipelineScope.record(.persistence,since:started)}
        entries.append(entry);if entries.count>100 {entries.removeFirst(entries.count-100)}
#if !FEAST_TESTS
        guard let base=FileManager.default.urls(for:.documentDirectory,in:.userDomainMask).first,let data=try? JSONEncoder().encode(entries) else{return}
        try? data.write(to:base.appendingPathComponent("AskConversationDiagnostics.json"),options:.atomic)
#endif
    }
}
struct AskProviderAttemptLease:Sendable {let turn:UUID;let attempt:UUID}
enum AskProviderAttemptScope {
    @TaskLocal static var lease:AskProviderAttemptLease?
    @TaskLocal static var store:AskProviderAttempts = .shared
}
enum AskRetryError:LocalizedError,Equatable {
    case unverified,active,mutations,storage,capacity
    var retryable:Bool {if case .capacity=self {return false};return true}
    var errorDescription:String? {switch self {
    case .unverified:"The previous attempt’s outcome isn’t verified yet. It hasn’t been sent again."
    case .active:"The previous attempt is still running or has unsettled usage. It hasn’t been sent again."
    case .mutations:"This request has recorded app actions. Continue in a new message so completed changes aren’t replayed."
    case .storage:"Retry state couldn’t be saved or verified. No further step was sent."
    case .capacity:"This step exceeds Feast’s local retry-context capacity. Earlier saved results were kept. No further step was sent."
    }}
}
/// Local attempt IDs and completed read context only; no credentials or automatic request replay.
actor AskProviderAttempts {
    struct Entry:Codable {
        var attempt:UUID;var roots:[UUID];var frozen:Bool;var checkpoint:AskResponse?=nil
        // Optional for existing small v1 files. A new checkpoint always gets a new revision.
        var checkpointRevision:UUID?=nil
    }
    struct ArchiveTicket:Equatable,Sendable {let turn:UUID,attempt:UUID;let revision:UUID?}
    /// Synchronous session deletion fences even a preflight that has not reached this actor yet.
    private final class Deletions:@unchecked Sendable {
        private let lock=NSLock()
        private var turns=Set<UUID>()
        func insert(_ ids:[UUID]) {lock.lock();defer{lock.unlock()};turns.formUnion(ids)}
        func contains(_ id:UUID)->Bool {lock.lock();defer{lock.unlock()};return turns.contains(id)}
    }
    static let shared=AskProviderAttempts()
    static let maximumBytes=8*1024*1024
    let url:URL?
    let requirePersistence:Bool
    // Persisted actors cache only small fencing metadata, never the bulky checkpoint.
    var entries:[UUID:Entry]=[:]
    var readable=true
    private var preparing=Set<UUID>()
    private var running:[UUID:UUID]=[:]
    private let deletions=Deletions()
    init(url:URL?=nil,requirePersistence:Bool?=nil) {
#if FEAST_TESTS
        self.requirePersistence=requirePersistence ?? false
        self.url=url
#else
        self.requirePersistence=requirePersistence ?? true
        self.url=url ?? FileManager.default.urls(for:.applicationSupportDirectory,in:.userDomainMask).first?.appendingPathComponent("AskFeast/provider-attempts-v1")
#endif
    }
    private func cache(_ entry:Entry,turn:UUID) {
        var metadata=entry;if url != nil {metadata.checkpoint=nil};entries[turn]=metadata
    }
    private func load(_ turn:UUID)throws->Entry? {
        guard readable else{throw AskRetryError.storage}
        guard let file=url?.appendingPathComponent(turn.uuidString+".json") else{return entries[turn]}
        guard FileManager.default.fileExists(atPath:file.path) else {
            // A previously durable identity disappearing is not a fresh turn.
            guard entries[turn]==nil else{entries[turn]?.frozen=true;throw AskRetryError.storage};return nil
        }
        do {
            guard let size=try file.resourceValues(forKeys:[.fileSizeKey]).fileSize,size<=Self.maximumBytes else{throw AskRetryError.capacity}
            let data=try Data(contentsOf:file);guard data.count<=Self.maximumBytes else{throw AskRetryError.capacity}
            var entry=try JSONDecoder().decode(Entry.self,from:data)
            guard entry.roots.count<=64,Set(entry.roots).count==entry.roots.count else{throw AskRetryError.storage}
            if let cached=entries[turn] {
                guard cached.attempt==entry.attempt,cached.roots==entry.roots,cached.checkpointRevision==entry.checkpointRevision else{throw AskRetryError.storage}
                entry.frozen = entry.frozen || cached.frozen
            }
            cache(entry,turn:turn);return entry
        }catch let error as AskRetryError {entries[turn]?.frozen=true;throw error}
        catch {entries[turn]?.frozen=true;throw AskRetryError.storage}
    }
    private func protect(_ path:URL)throws {
        var local=path,values=URLResourceValues();values.isExcludedFromBackup=true;try local.setResourceValues(values)
#if os(iOS)
        try FileManager.default.setAttributes([.protectionKey:FileProtectionType.completeUntilFirstUserAuthentication],ofItemAtPath:path.path)
#endif
    }
    private func write(_ data:Data,to file:URL)throws {
        guard let url else{throw AskRetryError.storage}
        try FileManager.default.createDirectory(at:url,withIntermediateDirectories:true)
        try protect(url)
#if os(iOS)
        try data.write(to:file,options:[.atomic,.completeFileProtectionUntilFirstUserAuthentication])
#else
        try data.write(to:file,options:.atomic)
#endif
        try protect(file)
        let handle=try FileHandle(forWritingTo:file);defer{try? handle.close()};try handle.synchronize()
        let fd=Darwin.open(url.path,O_RDONLY);guard fd>=0 else{throw AskRetryError.storage};defer{Darwin.close(fd)}
        guard fsync(fd)==0 else{throw AskRetryError.storage}
        let parent=Darwin.open(url.deletingLastPathComponent().path,O_RDONLY);guard parent>=0 else{throw AskRetryError.storage};defer{Darwin.close(parent)}
        guard fsync(parent)==0 else{throw AskRetryError.storage}
    }
    private func save(_ entry:Entry,turn:UUID)throws {
        do {
            guard !requirePersistence || url != nil else{throw AskRetryError.storage}
            let data=try JSONEncoder().encode(entry);guard data.count<=Self.maximumBytes else{throw AskRetryError.capacity}
            if let url {try write(data,to:url.appendingPathComponent(turn.uuidString+".json"))}
            cache(entry,turn:turn)
        }catch {
            // Do not replace the last readable checkpoint with an oversized candidate.
            var frozen=entries[turn] ?? entry;frozen.frozen=true;cache(frozen,turn:turn)
            if let error=error as? AskRetryError {throw error};throw AskRetryError.storage
        }
    }
    private func deleted(_ turn:UUID)->Bool {
        if deletions.contains(turn) {return true}
        if let marker=url?.appendingPathComponent(turn.uuidString+".deleted"),FileManager.default.fileExists(atPath:marker.path) {
            deletions.insert([turn]);return true
        }
        return false
    }
    func begin(turn:UUID,retrying:Bool,legacySettled:Bool,fence:@Sendable ([UUID])async throws->Void)async throws->AskProviderAttemptLease {
        guard !deleted(turn),!preparing.contains(turn) else{throw AskRetryError.active}
        let previous=try load(turn)
        preparing.insert(turn);defer{preparing.remove(turn)}
        if var old=previous {
            old.frozen=true;try save(old,turn:turn)
            if !old.roots.isEmpty {try await fence(old.roots)}
        }else if retrying {
            guard legacySettled else{throw AskRetryError.unverified}
            try save(Entry(attempt:turn,roots:[turn],frozen:true),turn:turn)
            try await fence([turn])
        }
        // Fence awaits are reentrant: deletion or an old completion must never revive this turn.
        guard !deleted(turn) else{throw AskRetryError.active}
        let attempt=UUID()
        let entry=Entry(attempt:attempt,roots:[],frozen:false,checkpoint:previous?.checkpoint,checkpointRevision:previous?.checkpointRevision)
        try save(entry,turn:turn);running[turn]=attempt
        return .init(turn:turn,attempt:attempt)
    }
    func readContext(for lease:AskProviderAttemptLease)throws->AskResponse? {
        guard !deleted(lease.turn) else{throw AskRetryError.active}
        guard let entry=try load(lease.turn),entry.attempt==lease.attempt else{return nil};return entry.checkpoint
    }
    private static func context(_ response:AskResponse)->AskResponse {
        var context=AskResponse(summary:"Completed read context retained.",candidates:[],listedCandidateIDs:[],usesLocalCatalog:true)
        context.historyRecordIDs=response.historyRecordIDs;context.retainsIndependentQuestion=response.retainsIndependentQuestion
        context.publicResearch=Array((response.publicResearch ?? []).suffix(4));context.verifiedPublicFindings=response.verifiedPublicFindings;context.agentTask=response.agentTask;context.mapChoices=response.mapChoices
        return context
    }
    func keepReadContext(_ response:AskResponse,lease:AskProviderAttemptLease)throws {
        guard !deleted(lease.turn),var entry=try load(lease.turn),entry.attempt==lease.attempt,!entry.frozen else{throw AskRetryError.active}
        entry.checkpoint=Self.context(response);entry.checkpointRevision=UUID();try save(entry,turn:lease.turn)
    }
    func register(_ root:UUID,lease:AskProviderAttemptLease)throws {
        guard !deleted(lease.turn),var entry=try load(lease.turn),entry.attempt==lease.attempt,!entry.frozen else{throw AskRetryError.active}
        if !entry.roots.contains(root) {
            guard entry.roots.count<64 else{entries[lease.turn]?.frozen=true;throw AskRetryError.storage}
            entry.roots.append(root);try save(entry,turn:lease.turn)
        }
    }
    /// Called only after the leased provider work has returned or thrown, not when Stop is tapped.
    func finish(_ lease:AskProviderAttemptLease) {
        guard running[lease.turn]==lease.attempt else{return}
        running.removeValue(forKey:lease.turn)
        guard !deleted(lease.turn) else{return}
        do {guard var entry=try load(lease.turn),entry.attempt==lease.attempt else{return};entry.frozen=true;try save(entry,turn:lease.turn)}
        catch {entries[lease.turn]?.frozen=true}
    }
    func archiveTicket(turn:UUID)throws->ArchiveTicket? {
        guard !deleted(turn),!preparing.contains(turn),running[turn]==nil,
              let entry=try load(turn),entry.frozen,entry.checkpoint != nil else{return nil}
        return .init(turn:turn,attempt:entry.attempt,revision:entry.checkpointRevision)
    }
    /// The caller has read back a successful archive commit containing this response.
    /// Only its exact, quiescent attempt/revision can release the redundant payload.
    @discardableResult func archiveCommitted(_ ticket:ArchiveTicket,response:AskResponse)throws->Bool {
        guard !deleted(ticket.turn),!preparing.contains(ticket.turn),running[ticket.turn]==nil,
              var entry=try load(ticket.turn),entry.attempt==ticket.attempt,entry.checkpointRevision==ticket.revision,
              entry.frozen,let checkpoint=entry.checkpoint else{return false}
        guard (checkpoint.publicResearch ?? []).allSatisfy({response.publicResearch?.contains($0)==true}),
              (checkpoint.verifiedPublicFindings ?? []).allSatisfy({response.verifiedPublicFindings?.contains($0)==true}),
              (checkpoint.mapChoices ?? []).allSatisfy({response.mapChoices?.contains($0)==true}),
              checkpoint.agentTask==nil || response.agentTask != nil else{return false}
        // The final task may supersede/reorder the read task. Evidence and Maps choices may not disappear.
        entry.checkpoint=nil;entry.checkpointRevision=nil;try save(entry,turn:ticket.turn);return true
    }
    nonisolated func markDeleted(_ turns:[UUID]) {deletions.insert(turns)}
    /// Keep accounting roots and a permanent small tombstone, including for preflight-only turns.
    func delete(_ turns:[UUID])throws {
        markDeleted(turns)
        var failed=false
        for turn in Set(turns) {
            running.removeValue(forKey:turn)
            do {
                if let url {try write(Data(turn.uuidString.utf8),to:url.appendingPathComponent(turn.uuidString+".deleted"))}
                else if requirePersistence {throw AskRetryError.storage}
                var entry=try load(turn) ?? Entry(attempt:turn,roots:[],frozen:true)
                entry.frozen=true;entry.checkpoint=nil;entry.checkpointRevision=nil;try save(entry,turn:turn)
            }catch {entries[turn]?.frozen=true;failed=true}
        }
        if failed {throw AskRetryError.storage}
    }
}

struct AskConversationFailure:LocalizedError {
    let status:Int,code:String
    var isCapacityFailure:Bool {Self.capacityCodes.contains(code)}
    static let capacityCodes:Set<String> = ["native_input_limit","native_request_limit","request_limit","native_reply_limit","native_context_limit","native_provider_response_limit","native_evidence_block_limit","native_final_citation_limit","native_required_sources_limit","native_evidence_text_limit","native_evidence_action_limit"]
    var retryable:Bool {!isCapacityFailure && ![401,403,409,413,429,503].contains(status)}
    var errorDescription:String? {
        if code=="native_input_limit" {return "The accumulated context is too large to continue this answer. No additional model call was made. Start a more focused question."}
        if code=="native_request_limit" || code=="request_limit" {return "The accumulated request is too large to send. No additional model call was made. Start a more focused question."}
        if code=="native_context_limit" {return "The accumulated context exceeds what Feast can retain, so this answer could not be finished. Start a more focused question."}
        if code=="native_reply_limit" {return "The answer and its supporting evidence exceed what Feast can receive, so this answer could not be finished. Start a more focused question."}
        if code=="native_provider_response_limit" {return "The AI response exceeded what Feast can safely receive. Its outcome is not fully verified, and it has not been sent again."}
        if code=="native_evidence_block_limit" {return "This step has more supporting evidence blocks than Feast can retain. Earlier results may still be available."}
        if code=="native_final_citation_limit" {return "This step has more inline citations than Feast can retain. Earlier results may still be available."}
        if code=="native_required_sources_limit" {return "Feast couldn’t retain all supporting sources for this step. Earlier results may still be available."}
        if code=="native_evidence_text_limit" {return "The supporting evidence for this step exceeds Feast’s capacity. Earlier results may still be available."}
        if code=="native_evidence_action_limit" {return "Research reached Feast’s action capacity. Earlier results may still be available."}
        if code=="provider_billing_limit" {return "OpenAI reports a billing or quota limit. Check your OpenAI API billing settings."}
        if code=="provider_billing_setup" {return "OpenAI reports that API billing isn’t active. Check your OpenAI API billing settings."}
        if code=="provider_rate_limit" {return "OpenAI is receiving too many requests. Try again shortly."}
        if code=="provider_authentication" {return "The AI service credentials need attention."}
        if code=="conversation_input_count" || code=="native_input_unverified" {return "The AI service couldn’t verify the next step’s input size. No additional model call was made."}
        if code=="conversation_provider" {return "The AI service couldn’t finish this step. Check its outcome before trying again."}
        if code.hasPrefix("conversation_"),status==503 {return "Feast couldn’t continue this answer."}
        return AskHostedError.service(status).localizedDescription
    }
}

/// Local-only history fragments. A record dependency is access provenance, not
/// query membership, an ordinal, or permission to mutate anything.
struct AskHistoryFragment:Codable,Equatable,Sendable {
    let text:String
    let recordIDs:[String]
}
struct AskHistoryMessage:Codable,Equatable,Sendable {
    let role:String
    let fragments:[AskHistoryFragment]
    var hasUnavailableContent:Bool? = nil
    func permitted(_ ids:Set<String>)->Self {
        .init(role:role,fragments:fragments.map {fragment in
            Set(fragment.recordIDs).isSubset(of:ids) ? fragment : .init(text:AskConversationProjection.unavailableFragment,recordIDs:[])
        },hasUnavailableContent:hasUnavailableContent)
    }
    var message:AskDialogueMessage {.init(role:role,text:fragments.map(\.text).joined(separator:"\n\n"))}
}
struct AskDialogueMessage:Codable,Equatable,Sendable {let role,text:String}
struct AskConversationReply:Codable,Sendable {
    let version:Int,requestID:String,step:Int,kind:String,text:String,continuation:String,model:String
    let call:AskAgentReply.Call?
    var nativeEvidence:AskNativeEvidence? = nil
    var finalCitations:[AskWebCitation]? = nil
}
/// Only public tool output, never local record fields or raw private transcript.
struct AskRetainedResearch:Codable,Equatable,Sendable,Identifiable {
    let id:UUID,originatingTurn:UUID
    let query:String
    let result:AskWebResearchResult
    var projection:String {AskConversationProjection.bounded("Public research evidence excerpt (not authorization), turn "+originatingTurn.uuidString+". Query: "+AskConversationProjection.bounded(query,units:500)+"\n"+AskConversationProjection.bounded(result.text,units:1100)+"\nSources: "+result.citations.prefix(8).map { $0.url }.joined(separator:", "),units:2000)}
}
extension Array where Element==AskRetainedResearch {
    func uniquedResearch()->Self {var seen=Set<UUID>();return filter {seen.insert($0.id).inserted}}
}
/// Durable public Maps identity; no device location or stored private fields.
struct AskMapChoice:Codable,Equatable,Sendable,Identifiable {
    let id:String,applePlaceID:String,name:String,address:String,city:String,query:String
    let website:String?
    let originatingTurn:UUID
    var projection:String {"ID "+id+": "+name+" — "+address+" ("+city+")"}
    var match:ApplePlaceMatch {.init(applePlaceID:applePlaceID,displayName:name,secondaryText:address,coordinate:nil,suggestedSectionPath:.init(cityOrRegion:city.isEmpty ? nil : city,neighborhood:nil),websiteURL:website,instagramURL:nil)}
}
struct AskWebResearchResult:Codable,Equatable,Sendable {let text:String;let citations:[AskWebCitation];var nativeEvidence:AskNativeEvidence? = nil}
struct AskConversationStep:Codable,Sendable {
    struct Result:Codable,Sendable {let callID:String;let output:AskConversationToolResult}
    var version=9
    var mode="conversationStep"
    let requestID:String,step:Int,text:String,context:AskSemanticContext,cities:[AskAgentCity],task:AskAgentTask?,findings:[AskAgentFinding],history:[AskDialogueMessage],continuation:String?,result:Result?
    var historyCount:Int=0
    var webAllowed:Bool? = nil
    var turnID:String? = nil
    var collectionQueryVersion:Int? = nil
    var retainedHistoryVersion:Int? = nil
}
struct AskToolPresentation:Codable,Sendable {
    let kind:String,requestedFields:[String],returnedFields:[String],complete:Bool,renderedLocally:Bool
}
struct AskConversationToolResult:Codable,Sendable {
    let status:String,complete:Bool,totalCount:Int,records:[AskAgentRecord],findings:[AskAgentFinding],message:String,localOnly:Bool
    var offset:Int?=nil,returnedCount:Int?=nil,nextOffset:Int?=nil
    var snapshot:String?=nil,summary:String?=nil
    var web:AskWebResearchResult?=nil
    var history:[AskDialogueMessage]?=nil
    var presentation:AskToolPresentation?=nil
    init(_ r:AskAgentResult,web:AskWebResearchResult?=nil){status=r.status;complete=r.complete;totalCount=r.totalCount;records=r.records;findings=r.findings;message=r.message;localOnly=r.localOnly;self.web=web;offset=r.offset;returnedCount=r.returnedCount;nextOffset=r.nextOffset;snapshot=r.snapshot;summary=r.summary}
}
struct AskHumanAuthorization:Decodable,Sendable {let approved,replaceExisting,deleteContents:Bool;let reason:String;var targetSelector:AskAgentSelector?=nil}
protocol AskConversationPlanning:Sendable {
    func conversationAvailable()async->Bool
    func nativeResearchAvailable()async->Bool
    func collectionQueryVersion()async->Int
    func retainedHistoryVersion()async->Int
    func conversationStep(_ step:AskConversationStep)async throws->AskConversationReply
    func searchConversationWeb(_ query:String)async throws->AskWebResearchResult
    func authorizePendingConfirmation(_ actions:[AskCollectionAction],question:String,history:[String])async throws->AskHumanAuthorization
    func authorizeConversationChange(_ proposal:AskChangeProposal,question:String,history:[String],targets:[AskAgentRecord])async throws->AskHumanAuthorization
}
extension AskConversationPlanning {
    func nativeResearchAvailable()async->Bool {false}
    func collectionQueryVersion()async->Int {0}
    func retainedHistoryVersion()async->Int {0}
}
extension AskHostedProvider:AskConversationPlanning {
    func prepareProviderAttempt(turn:UUID,retrying:Bool)async throws->AskProviderAttemptLease {
        let started=DispatchTime.now().uptimeNanoseconds
        defer {AskPipelineScope.record(retrying ? .retry : .reconciliation,since:started)}
        let legacy=await AskConversationReceipts.shared.legacyStoppedAndSettled(turn)
        return try await AskProviderAttemptScope.store.begin(turn:turn,retrying:retrying,legacySettled:legacy){roots in
            struct Fence:Decodable {let version:Int;let state:String;let roots:[UUID]}
            do {let result=try await conversationRequest(["version":9,"mode":"retryFence","roots":roots.map {$0.uuidString}],as:Fence.self)
                guard result.version==9,result.state=="fenced",Set(result.roots)==Set(roots) else{throw AskRetryError.unverified}
            }catch let error as AskConversationFailure {if error.status==409 {throw AskRetryError.active};throw error}
        }
    }
    func nativeResearchAvailable()async->Bool {guard await permission() else{return false};return await nativeResearchEnabled()}
    func collectionQueryVersion()async->Int {guard await permission() else{return 0};return await collectionQueriesEnabled() ? 2 : 0}
    func retainedHistoryVersion()async->Int {guard await permission() else{return 0};return await retainedHistoryEnabled() ? 1 : 0}
    func conversationAvailable()async->Bool {let allowed=await permission();let version=await libraryPlanVersion();return allowed && version>=6}
    private func conversationRequest<T:Decodable>(_ payload:[String:Any],as:T.Type)async throws->T {
        let preparation=DispatchTime.now().uptimeNanoseconds
        try configuration.validate()
        guard configuration.scope == .savedMetadata,await permission(),await libraryToolsEnabled() else {throw AskHostedError.consentRequired}
        let credential=try await token()
        guard (43...128).contains(credential.count),credential.allSatisfy({$0.isASCII&&($0.isLetter||$0.isNumber||$0=="_"||$0=="-")}) else {throw AskHostedError.disabled}
        let directNative=payload["version"] as? Int == 10 && payload["mode"] as? String == "conversationStep"
        let maximumReplyBytes=directNative ? AskNativeCapacity.replyBytes : 400000
        let body=try JSONSerialization.data(withJSONObject:payload,options:.sortedKeys)
        guard body.count <= (directNative ? AskNativeCapacity.requestBytes : 512000) else {
            throw AskConversationFailure(status:413,code:directNative ? "native_request_limit" : "request_limit")
        }
        var http=URLRequest(url:configuration.endpoint);http.httpMethod="POST";http.httpBody=body;http.timeoutInterval=220
        http.setValue(String(payload["version"] as? Int ?? 9),forHTTPHeaderField:"X-Feast-Agent-Protocol");http.setValue("application/json",forHTTPHeaderField:"Content-Type");http.setValue("Feast/1.0",forHTTPHeaderField:"User-Agent");http.setValue("Bearer "+credential,forHTTPHeaderField:"Authorization")
        let started=DispatchTime.now().uptimeNanoseconds
        AskPipelineScope.record(.preparation,since:preparation)
        try Task.checkCancellation()
        let data:Data,response:HTTPURLResponse
        do {(data,response)=try await sendWithHistoryAccessCheck(http)}catch {
            AskPipelineScope.trace?.elapsed(.transport,since:started,counters:[.requestBytes:body.count])
            var receipt=AskConversationReceipt(requestID:payload["requestID"] as? String ?? "",mode:payload["mode"] as? String ?? "",step:payload["step"] as? Int,status:0,data:Data(),elapsed:AskPerformanceRecorder.milliseconds(since:started));receipt.code="network_interrupted";await AskConversationReceipts.shared.record(receipt);throw error
        }
        AskPipelineScope.trace?.elapsed(.transport,since:started,counters:[.requestBytes:body.count,.responseBytes:data.count])
        let decodeStarted=DispatchTime.now().uptimeNanoseconds
        var receipt=AskConversationReceipt(requestID:payload["requestID"] as? String ?? "",mode:payload["mode"] as? String ?? "",step:payload["step"] as? Int,status:response.statusCode,data:data,elapsed:AskPerformanceRecorder.milliseconds(since:started),maximumResponseBytes:maximumReplyBytes)
        AskPipelineScope.record(.decode,since:decodeStarted)
        guard response.statusCode==200 else {await AskConversationReceipts.shared.record(receipt);throw AskConversationFailure(status:response.statusCode,code:receipt.code)}
        guard response.url==configuration.endpoint,response.mimeType=="application/json" else {receipt.code="response_shape";await AskConversationReceipts.shared.record(receipt);throw AskHostedError.invalidResponse}
        guard data.count<=maximumReplyBytes else {receipt.code=directNative ? "native_reply_limit" : "response_limit";await AskConversationReceipts.shared.record(receipt);throw AskConversationFailure(status:413,code:receipt.code)}
        let result:T
        do {let start=DispatchTime.now().uptimeNanoseconds;defer {AskPipelineScope.record(.decode,since:start)};result=try JSONDecoder().decode(T.self,from:data)}
        catch {receipt.code="response_decode";await AskConversationReceipts.shared.record(receipt);throw error}
        if Task.isCancelled {receipt.code="stopped_settled"}
        await AskConversationReceipts.shared.record(receipt)
        try Task.checkCancellation()
        return result
    }
    func conversationStep(_ step:AskConversationStep)async throws->AskConversationReply {
        guard [9,10].contains(step.version) else {throw AskHostedError.invalidResponse}
        if let queryVersion=step.collectionQueryVersion {
            guard queryVersion==2,step.version==10,step.context.collectionAccess=="permitted_details_v1",AskRecoveryScope.handle==nil else{throw AskHostedError.invalidResponse}
        }
        if let version=step.retainedHistoryVersion {
            guard version==1,step.version==10,step.context.collectionAccess=="permitted_details_v1" else{throw AskHostedError.invalidResponse}
        }
        if step.context.collectionAccess != nil {
            guard step.context.collectionAccess=="permitted_details_v1",await libraryPlanVersion()>=7 else{throw AskHostedError.disabled}
        }
        if step.version==10 {
            if AskRecoveryScope.handle==nil {guard await nativeResearchAvailable() else{throw AskHostedError.disabled}}
            guard step.webAllowed != nil,UUID(uuidString:step.turnID ?? "") != nil else{throw AskHostedError.disabled}
        }
        let encoded=try JSONEncoder().encode(step)
        guard var p=try JSONSerialization.jsonObject(with:encoded) as? [String:Any] else {throw AskError.invalidEvidence}
        for key in ["task","continuation","result"] where p[key]==nil {p[key]=NSNull()}
        if let handle=AskRecoveryScope.handle {return try await recoveredConversationStep(step,handle:handle)}
        let value=try await conversationRequest(p,as:AskConversationReply.self)
        return try checkedConversationReply(value,step:step,maximumContinuationBytes:step.version==10 ? AskNativeCapacity.continuationBytes : 350000)
    }
    func checkedConversationReply(_ value:AskConversationReply,step:AskConversationStep,maximumContinuationBytes:Int=350000)throws->AskConversationReply {
        guard value.continuation.utf8.count<=maximumContinuationBytes else{throw AskConversationFailure(status:413,code:"native_context_limit")}
        guard value.version==step.version,value.requestID==step.requestID,value.step==step.step,["answer","tool"].contains(value.kind),(value.kind=="tool")==(value.call != nil),value.text.count<=16000,value.model=="gpt-6-astra"||value.model.hasPrefix("gpt-6-astra-")||value.model=="gpt-6.1-sol"||value.model.hasPrefix("gpt-6.1-sol-") else {throw AskHostedError.invalidResponse}
        if step.version==10 {
            guard let evidence=value.nativeEvidence else {throw AskHostedError.invalidResponse}
            _ = try evidence.checked()
            guard let citations=value.finalCitations,citations.count<=20,citations.allSatisfy({$0.safeURL != nil}) else{throw AskHostedError.invalidResponse}
        }
        return value
    }
    func searchConversationWeb(_ query:String)async throws->AskWebResearchResult {
        struct Reply:Decodable {let version:Int,requestID:String,text:String,citations:[AskWebCitation]}
        let id=UUID().uuidString
        let reply=try await conversationRequest(["version":9,"mode":"webSearch","requestID":id,"query":query],as:Reply.self)
        guard reply.version==9,reply.requestID==id,reply.text.count<=16000,reply.citations.count<=20,reply.citations.allSatisfy({$0.safeURL != nil}) else {throw AskHostedError.invalidResponse}
        return .init(text:reply.text,citations:reply.citations)
    }
    func authorizePendingConfirmation(_ actions:[AskCollectionAction],question:String,history:[String])async throws->AskHumanAuthorization {
        struct Reply:Decodable {let version:Int,requestID:String,decision:AskHumanAuthorization}
        let id=UUID().uuidString
        let p:[String:Any]=["version":9,"mode":"authorizeChange","requestID":id,"text":question,"humanHistory":Array(history.suffix(6)),"proposal":["confirmActionIDs":actions.map {$0.id.uuidString}],"targets":[],"pending":actions.map {["id":$0.id.uuidString,"entity":$0.entity,"operation":$0.operation]}]
        let reply=try await conversationRequest(p,as:Reply.self)
        guard reply.version==9,reply.requestID==id else {throw AskHostedError.invalidResponse};return reply.decision
    }
    func authorizeConversationChange(_ proposal:AskChangeProposal,question:String,history:[String],targets:[AskAgentRecord])async throws->AskHumanAuthorization {
        struct Reply:Decodable {let version:Int,requestID:String,decision:AskHumanAuthorization}
        let id=UUID().uuidString
        let data=try JSONEncoder().encode(proposal)
        guard var projected=try JSONSerialization.jsonObject(with:data) as? [String:Any] else {throw AskError.invalidEvidence}
        // This is the model-generated proposed edit already returned by OpenAI,
        // never a stored value or native before-image. The authorization model must
        // compare that proposed value with the current human instruction. Existing
        // notes/tags/statuses, append results and Undo snapshots never enter it.
        for key in ["cityID","sectionID","mapMatchID"] where projected[key]==nil {projected[key]=NSNull()}
        if var changes=projected["changes"] as? [[String:Any]] {
            for i in changes.indices {for key in ["value","values","findingID"] where changes[i][key]==nil {changes[i][key]=NSNull()}}
            projected["changes"]=changes
        }
        projected["targetScope"]=proposal.targetIDs.isEmpty && proposal.operation != "create" ? "current_local_selection" : "explicit_catalog"
        let p:[String:Any]=["version":9,"mode":"authorizeChange","requestID":id,"text":question,"humanHistory":Array(history.suffix(6)),"proposal":projected,"targets":targets.map {["id":$0.id,"name":$0.name,"city":$0.city]},"pending":[]]
        let reply=try await conversationRequest(p,as:Reply.self)
        guard reply.version==9,reply.requestID==id else {throw AskHostedError.invalidResponse};return reply.decision
    }
}

/// Public provider evidence, not raw reasoning or an executable continuation.
/// Offsets remain attached to unchanged provider blocks; the legacy renderer
/// does not reinterpret them as Swift/Markdown character positions.
struct AskNativeEvidence:Codable,Equatable,Sendable {
    struct Inventory:Codable,Equatable,Sendable {
        let totalUniqueSources,omittedConsultedSources:Int
        let complete:Bool
    }
    struct Annotation:Codable,Equatable,Sendable {let sourceURL,title:String;let start,end:Int;let indexUnit:String}
    struct Block:Codable,Equatable,Sendable {let id,text,phase,observedAt:String;let annotations:[Annotation]}
    struct Source:Codable,Equatable,Sendable {let id,url,title:String;let roles:[String]}
    struct Action:Codable,Equatable,Sendable {
        let id,type,observedAt:String
        var url:String?=nil
        var query:String?=nil
        var queries:[String]?=nil
        var pattern:String?=nil
    }
    let version:Int,blocks:[Block],sources:[Source],actions:[Action]
    var inventory:Inventory? = nil // Historical evidence has unknown inventory completeness.
    func checked()throws->Self {
        guard version==1,blocks.count<=60,sources.count<=80,actions.count<=12,
              Set(blocks.map(\.id)).count==blocks.count,Set(sources.map(\.id)).count==sources.count,Set(actions.map(\.id)).count==actions.count,
              blocks.reduce(0,{$0+$1.text.utf16.count})<=64000 else{throw AskError.invalidEvidence}
        if let inventory {
            // Upper bound follows existing item/content/annotation/action limits;
            // these are counts only, not an enlarged allocation or payload limit.
            guard (sources.count...96972).contains(inventory.totalUniqueSources),
                  inventory.omittedConsultedSources==inventory.totalUniqueSources-sources.count,
                  inventory.complete==(inventory.omittedConsultedSources==0) else{throw AskError.invalidEvidence}
        }
        let formatter=ISO8601DateFormatter();formatter.formatOptions=[.withInternetDateTime,.withFractionalSeconds]
        let plain=ISO8601DateFormatter()
        let validDate:(String)->Bool = {$0.count<=40 && (formatter.date(from:$0) != nil || plain.date(from:$0) != nil)}
        for source in sources {
            let stableID=SHA256.hash(data:Data(source.url.utf8)).map {String(format:"%02x",$0)}.joined()
            guard source.id==stableID,source.title.count<=200,source.url.utf8.count<=2048,
                  AskWebCitation(title:source.title,url:source.url).safeURL != nil,!source.roles.isEmpty,Set(source.roles).count==source.roles.count,
                  source.roles.allSatisfy({["consulted","provider_opened","cited"].contains($0)}) else{throw AskError.invalidEvidence}
        }
        for block in blocks {
            guard !block.id.isEmpty,block.id.count<=220,block.text.utf16.count<=16000,["commentary","final_answer","unspecified"].contains(block.phase),validDate(block.observedAt),block.annotations.count<=80 else{throw AskError.invalidEvidence}
            for a in block.annotations {
                guard a.indexUnit=="provider_unmapped",a.start>=0,a.end>a.start,a.end<=block.text.utf8.count,a.title.count<=200,
                      sources.contains(where:{$0.url==a.sourceURL && $0.roles.contains("cited")}) else{throw AskError.invalidEvidence}
            }
        }
        for action in actions {
            guard !action.id.isEmpty,action.id.count<=200,["search","open_page","find_in_page"].contains(action.type),validDate(action.observedAt),
                  action.url.map({$0.utf8.count<=2048 && AskWebCitation(title:"",url:$0).safeURL != nil}) ?? true,
                  action.query.map({!$0.isEmpty && $0.utf16.count<=1500}) ?? true,
                  action.queries.map({!$0.isEmpty && $0.count<=12 && $0.allSatisfy {!$0.isEmpty && $0.utf16.count<=1500}}) ?? true else{throw AskError.invalidEvidence}
            if action.type=="search",action.query==nil,action.queries==nil {throw AskError.invalidEvidence}
            if action.type != "search" {
                guard let url=action.url,sources.contains(where:{$0.url==url && $0.roles.contains("provider_opened")}) else{throw AskError.invalidEvidence}
            }
            if action.type=="find_in_page",(action.pattern?.isEmpty != false || (action.pattern?.utf16.count ?? 0)>1500) {throw AskError.invalidEvidence}
        }
        return self
    }
    /// Block-level provider association only; never proof of a particular claim.
    func containsQuotedBlockWithSource(quote:String,url:String)->Bool {
        !quote.isEmpty && blocks.contains {$0.text.contains(quote) && $0.annotations.contains {$0.sourceURL==url}}
    }
    var queryIdentity:String {actions.flatMap {($0.queries ?? [])+($0.query.map {[$0]} ?? [])}.joined(separator:"\n")}
}
