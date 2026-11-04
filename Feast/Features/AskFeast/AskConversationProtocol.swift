import Foundation
import Darwin
import CryptoKit

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
    init(requestID:String,mode:String,step:Int?,status:Int,data:Data,elapsed:Double) {
        self.requestID=UUID(uuidString:requestID)?.uuidString ?? "unknown";self.mode=["conversationStep","authorizeChange","webSearch"].contains(mode) ? mode : "unknown";self.step=step
        at=Date();elapsedMilliseconds=elapsed.isFinite ? min(max(elapsed,0),240000) : 0;self.status=status
        let value=data.count<=400000 ? ((try? JSONSerialization.jsonObject(with:data)) as? [String:Any] ?? [:]) : [:]
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
enum AskProviderAttemptScope {@TaskLocal static var lease:AskProviderAttemptLease?}
enum AskRetryError:LocalizedError {
    case unverified,active,mutations,storage
    var errorDescription:String? {switch self {
    case .unverified:"The previous attempt’s outcome isn’t verified yet. It hasn’t been sent again."
    case .active:"The previous attempt is still running or has unsettled usage. It hasn’t been sent again."
    case .mutations:"This request has recorded app actions. Continue in a new message so completed changes aren’t replayed."
    case .storage:"Retry state couldn’t be saved. Nothing new was sent."
    }}
}
/// Local attempt IDs and completed read context only; no credentials or automatic request replay.
actor AskProviderAttempts {
    struct Entry:Codable {var attempt:UUID;var roots:[UUID];var frozen:Bool;var checkpoint:AskResponse?=nil}
    static let shared=AskProviderAttempts()
    let url:URL?
    let requirePersistence:Bool
    var entries:[UUID:Entry]=[:]
    var readable=true
    var preparing=Set<UUID>()
    init(url:URL?=nil,requirePersistence:Bool?=nil) {
#if FEAST_TESTS
        self.requirePersistence=requirePersistence ?? false
        self.url=url
#else
        self.requirePersistence=requirePersistence ?? true
        self.url=url ?? FileManager.default.urls(for:.applicationSupportDirectory,in:.userDomainMask).first?.appendingPathComponent("AskFeast/provider-attempts-v1")
#endif
    }
    private func load(_ turn:UUID)throws {
        guard entries[turn]==nil,let file=url?.appendingPathComponent(turn.uuidString+".json"),FileManager.default.fileExists(atPath:file.path) else{return}
        do {let data=try Data(contentsOf:file);guard data.count<=1024*1024 else{throw AskRetryError.storage};let entry=try JSONDecoder().decode(Entry.self,from:data);guard entry.roots.count<=64,Set(entry.roots).count==entry.roots.count else{throw AskRetryError.storage};entries[turn]=entry}catch{throw AskRetryError.storage}
    }
    private func save(_ turn:UUID)throws {
        guard !requirePersistence || url != nil,let entry=entries[turn] else{throw AskRetryError.storage}
        if let url {do {
            // Per-turn files avoid an ever-growing aggregate blocking unrelated turns.
            let data=try JSONEncoder().encode(entry);guard data.count<=1024*1024 else{throw AskRetryError.storage}
            try FileManager.default.createDirectory(at:url,withIntermediateDirectories:true)
            let file=url.appendingPathComponent(turn.uuidString+".json")
            try data.write(to:file,options:.atomic)
            let handle=try FileHandle(forWritingTo:file);try handle.synchronize();try handle.close()
            let fd=Darwin.open(url.path,O_RDONLY);guard fd>=0 else{throw AskRetryError.storage};defer{Darwin.close(fd)}
            guard fsync(fd)==0 else{throw AskRetryError.storage}
            let parent=Darwin.open(url.deletingLastPathComponent().path,O_RDONLY);guard parent>=0 else{throw AskRetryError.storage};defer{Darwin.close(parent)};guard fsync(parent)==0 else{throw AskRetryError.storage}
        }catch{entries[turn]?.frozen=true;throw AskRetryError.storage}}
    }
    func begin(turn:UUID,retrying:Bool,legacySettled:Bool,fence:@Sendable ([UUID])async throws->Void)async throws->AskProviderAttemptLease {
        try load(turn)
        guard readable else{throw AskRetryError.storage}
        guard !preparing.contains(turn) else{throw AskRetryError.active}
        preparing.insert(turn);defer{preparing.remove(turn)}
        let checkpoint=entries[turn]?.checkpoint
        if var old=entries[turn] {
            old.frozen=true;entries[turn]=old;try save(turn)
            do {if !old.roots.isEmpty {try await fence(old.roots)}}catch {entries[turn]=old;throw error}
        }else if retrying {
            guard legacySettled else{throw AskRetryError.unverified}
            entries[turn]=Entry(attempt:turn,roots:[turn],frozen:true);try save(turn)
            try await fence([turn])
        }
        let attempt=UUID();entries[turn]=Entry(attempt:attempt,roots:[],frozen:false,checkpoint:checkpoint);try save(turn)
        return .init(turn:turn,attempt:attempt)
    }
    func readContext(for lease:AskProviderAttemptLease)->AskResponse? {guard entries[lease.turn]?.attempt==lease.attempt else{return nil};return entries[lease.turn]?.checkpoint}
    func keepReadContext(_ response:AskResponse,lease:AskProviderAttemptLease)throws {
        guard var entry=entries[lease.turn],entry.attempt==lease.attempt,!entry.frozen else{throw AskRetryError.active}
        var context=AskResponse(summary:"Completed read context retained.",candidates:[],listedCandidateIDs:[],usesLocalCatalog:true)
        context.publicResearch=Array((response.publicResearch ?? []).suffix(4));context.verifiedPublicFindings=response.verifiedPublicFindings;context.agentTask=response.agentTask;context.mapChoices=response.mapChoices
        entry.checkpoint=context;entries[lease.turn]=entry;try save(lease.turn)
    }
    func register(_ root:UUID,lease:AskProviderAttemptLease)throws {
        guard var entry=entries[lease.turn],entry.attempt==lease.attempt,!entry.frozen else{throw AskRetryError.active}
        if !entry.roots.contains(root){guard entry.roots.count<64 else{throw AskRetryError.storage};entry.roots.append(root);entries[lease.turn]=entry;try save(lease.turn)}
    }
}

struct AskConversationFailure:LocalizedError {
    let status:Int,code:String
    var retryable:Bool {![401,403,409,429,503].contains(status)}
    var errorDescription:String? {
        if code=="native_reply_limit" || code=="native_context_limit" {return "The combined research evidence and continuation for this step exceed Feast’s capacity. Earlier results may still be available."}
        if code=="native_evidence_block_limit" {return "This step has more supporting evidence blocks than Feast can retain. Earlier results may still be available."}
        if code=="native_final_citation_limit" {return "This step has more inline citations than Feast can retain. Earlier results may still be available."}
        if code=="native_required_sources_limit" {return "Feast couldn’t retain all supporting sources for this step. Earlier results may still be available."}
        if code=="native_evidence_text_limit" {return "The supporting evidence for this step exceeds Feast’s capacity. Earlier results may still be available."}
        if code=="native_evidence_action_limit" {return "Research reached Feast’s action capacity. Earlier results may still be available."}
        if code=="provider_billing_limit" {return "OpenAI reports a billing or quota limit. Check your OpenAI API billing settings."}
        if code=="provider_billing_setup" {return "OpenAI reports that API billing isn’t active. Check your OpenAI API billing settings."}
        if code=="provider_rate_limit" {return "OpenAI is receiving too many requests. Try again shortly."}
        if code=="provider_authentication" {return "The AI service credentials need attention."}
        if code=="conversation_input_count" {return "The AI service couldn’t prepare the next step. No further model call was made."}
        if code=="conversation_provider" {return "The AI service couldn’t finish this step. Check its outcome before trying again."}
        if code.hasPrefix("conversation_"),status==503 {return "Feast couldn’t continue this answer."}
        return AskHostedError.service(status).localizedDescription
    }
}

struct AskDialogueMessage:Codable,Equatable,Sendable {let role,text:String}
struct AskConversationReply:Decodable,Sendable {
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
struct AskConversationStep:Encodable,Sendable {
    struct Result:Encodable,Sendable {let callID:String;let output:AskConversationToolResult}
    var version=9
    let mode="conversationStep"
    let requestID:String,step:Int,text:String,context:AskSemanticContext,cities:[AskAgentCity],task:AskAgentTask?,findings:[AskAgentFinding],history:[AskDialogueMessage],continuation:String?,result:Result?
    var historyCount:Int=0
    var webAllowed:Bool? = nil
    var turnID:String? = nil
}
struct AskToolPresentation:Encodable,Sendable {
    let kind:String,requestedFields:[String],returnedFields:[String],complete:Bool,renderedLocally:Bool
}
struct AskConversationToolResult:Encodable,Sendable {
    let status:String,complete:Bool,totalCount:Int,records:[AskAgentRecord],findings:[AskAgentFinding],message:String,localOnly:Bool
    var web:AskWebResearchResult?=nil
    var history:[AskDialogueMessage]?=nil
    var presentation:AskToolPresentation?=nil
    init(_ r:AskAgentResult,web:AskWebResearchResult?=nil){status=r.status;complete=r.complete;totalCount=r.totalCount;records=r.records;findings=r.findings;message=r.message;localOnly=r.localOnly;self.web=web}
}
struct AskHumanAuthorization:Decodable,Sendable {let approved,replaceExisting,deleteContents:Bool;let reason:String;var targetSelector:AskAgentSelector?=nil}
protocol AskConversationPlanning:Sendable {
    func conversationAvailable()async->Bool
    func nativeResearchAvailable()async->Bool
    func conversationStep(_ step:AskConversationStep)async throws->AskConversationReply
    func searchConversationWeb(_ query:String)async throws->AskWebResearchResult
    func authorizePendingConfirmation(_ actions:[AskCollectionAction],question:String,history:[String])async throws->AskHumanAuthorization
    func authorizeConversationChange(_ proposal:AskChangeProposal,question:String,history:[String],targets:[AskAgentRecord])async throws->AskHumanAuthorization
}
extension AskConversationPlanning {
    func nativeResearchAvailable()async->Bool {false}
}
extension AskHostedProvider:AskConversationPlanning {
    func prepareProviderAttempt(turn:UUID,retrying:Bool)async throws->AskProviderAttemptLease {
        let started=DispatchTime.now().uptimeNanoseconds
        defer {AskPipelineScope.record(retrying ? .retry : .reconciliation,since:started)}
        let legacy=await AskConversationReceipts.shared.legacyStoppedAndSettled(turn)
        return try await AskProviderAttempts.shared.begin(turn:turn,retrying:retrying,legacySettled:legacy){roots in
            struct Fence:Decodable {let version:Int;let state:String;let roots:[UUID]}
            do {let result=try await conversationRequest(["version":9,"mode":"retryFence","roots":roots.map {$0.uuidString}],as:Fence.self)
                guard result.version==9,result.state=="fenced",Set(result.roots)==Set(roots) else{throw AskRetryError.unverified}
            }catch let error as AskConversationFailure {if error.status==409 {throw AskRetryError.active};throw error}
        }
    }
    func nativeResearchAvailable()async->Bool {guard await permission() else{return false};return await nativeResearchEnabled()}
    func conversationAvailable()async->Bool {let allowed=await permission();let version=await libraryPlanVersion();return allowed && version>=6}
    private func conversationRequest<T:Decodable>(_ payload:[String:Any],as:T.Type)async throws->T {
        let preparation=DispatchTime.now().uptimeNanoseconds
        try configuration.validate()
        guard configuration.scope == .savedMetadata,await permission(),await libraryToolsEnabled() else {throw AskHostedError.consentRequired}
        let credential=try await token()
        guard (43...128).contains(credential.count),credential.allSatisfy({$0.isASCII&&($0.isLetter||$0.isNumber||$0=="_"||$0=="-")}) else {throw AskHostedError.disabled}
        let body=try JSONSerialization.data(withJSONObject:payload,options:.sortedKeys)
        guard body.count<=512000 else {throw AskError.inputLimit}
        var http=URLRequest(url:configuration.endpoint);http.httpMethod="POST";http.httpBody=body;http.timeoutInterval=220
        http.setValue(String(payload["version"] as? Int ?? 9),forHTTPHeaderField:"X-Feast-Agent-Protocol");http.setValue("application/json",forHTTPHeaderField:"Content-Type");http.setValue("Feast/1.0",forHTTPHeaderField:"User-Agent");http.setValue("Bearer "+credential,forHTTPHeaderField:"Authorization")
        let started=DispatchTime.now().uptimeNanoseconds
        AskPipelineScope.record(.preparation,since:preparation)
        try Task.checkCancellation()
        let data:Data,response:HTTPURLResponse
        do {(data,response)=try await send(http)}catch {
            AskPipelineScope.trace?.elapsed(.transport,since:started,counters:[.requestBytes:body.count])
            var receipt=AskConversationReceipt(requestID:payload["requestID"] as? String ?? "",mode:payload["mode"] as? String ?? "",step:payload["step"] as? Int,status:0,data:Data(),elapsed:AskPerformanceRecorder.milliseconds(since:started));receipt.code="network_interrupted";await AskConversationReceipts.shared.record(receipt);throw error
        }
        AskPipelineScope.trace?.elapsed(.transport,since:started,counters:[.requestBytes:body.count,.responseBytes:data.count])
        let decodeStarted=DispatchTime.now().uptimeNanoseconds
        var receipt=AskConversationReceipt(requestID:payload["requestID"] as? String ?? "",mode:payload["mode"] as? String ?? "",step:payload["step"] as? Int,status:response.statusCode,data:data,elapsed:AskPerformanceRecorder.milliseconds(since:started))
        AskPipelineScope.record(.decode,since:decodeStarted)
        guard response.statusCode==200 else {await AskConversationReceipts.shared.record(receipt);throw AskConversationFailure(status:response.statusCode,code:receipt.code)}
        guard response.url==configuration.endpoint,response.mimeType=="application/json",data.count<=400000 else {receipt.code="response_shape";await AskConversationReceipts.shared.record(receipt);throw AskHostedError.invalidResponse}
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
        if step.version==10 {guard await nativeResearchAvailable(),step.webAllowed != nil,UUID(uuidString:step.turnID ?? "") != nil else {throw AskHostedError.disabled}}
        let encoded=try JSONEncoder().encode(step)
        guard var p=try JSONSerialization.jsonObject(with:encoded) as? [String:Any] else {throw AskError.invalidEvidence}
        for key in ["task","continuation","result"] where p[key]==nil {p[key]=NSNull()}
        let value=try await conversationRequest(p,as:AskConversationReply.self)
        guard value.version==step.version,value.requestID==step.requestID,value.step==step.step,["answer","tool"].contains(value.kind),(value.kind=="tool")==(value.call != nil),value.text.count<=16000,value.continuation.utf8.count<=350000,value.model=="gpt-6-astra"||value.model.hasPrefix("gpt-6-astra-")||value.model=="gpt-6.1-sol"||value.model.hasPrefix("gpt-6.1-sol-") else {throw AskHostedError.invalidResponse}
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
