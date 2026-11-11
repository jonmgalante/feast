import Foundation
import Darwin
#if os(iOS)
import UIKit
#endif

/// Staged rollout only. A compatible server is required in addition to this flag.
enum AskRecoveryFeature {
    static var enabled:Bool {
#if FEAST_DURABLE_RECOVERY
        true
#else
        false
#endif
    }
}
enum AskRecoveryError:LocalizedError,Equatable {
    case storage, paused, localStepUncertain, stopped, expired, unavailable, alreadyRunning
    var errorDescription:String? {switch self {
    case .storage:"Recovery state couldn’t be saved. No new step was started."
    case .paused:"This answer is saved and will reconnect when you return."
    case .localStepUncertain:"A step on this device was interrupted. Earlier results were kept; that step hasn’t been repeated."
    case .stopped:"This answer was stopped."
    case .expired:"This saved answer is no longer available from the service. It hasn’t been sent again."
    case .unavailable:"This answer’s outcome couldn’t be verified. It hasn’t been sent again."
    case .alreadyRunning:"This answer is already running."
    }}
}
struct AskRecoveryLoopState:Codable,Sendable {
    var nextStep=0
    var continuation:String?
    var result:AskConversationStep.Result?
    var latest:AskResponse?
    var ordered:[String]=[]
    var privateScope=false,privateHistory=false,currentPrivateTool=false,localOnlyTool=false
    var taskFields:[String]=[]
    var selectionIsOrdered=true
    var displayOrder:[String]? = nil
    var referencesIncomplete:Bool? = nil
    var available:[String:AskCandidate]=[:]
    var publicResearch:[AskRetainedResearch]=[]
    var attemptedChange=false
    var unresolvedChanges:Set<String>=[]
    var citations:[AskWebCitation]=[]
    var durableActions:[AskCollectionAction]=[]
    var durableOutcomes:[AskAgentOutcome]=[]
    var operationRecords:[AskOperationRecord]=[]
    var historyRecordIDs:[String]? = nil
}
struct AskTurnCheckpoint:Codable,Sendable {
    enum Phase:String,Codable {case ready, awaitingReply, receivedReply, executingTool, completed, stopped, blocked}
    var version=1
    let turnID:UUID,chatID:UUID,attemptID:UUID
    let endpoint:String
    let request:AskRequest
    var userRequest:AskRequest?=nil
    var executorRequest:AskRequest?=nil
    let createdAt:Date
    var context:AskSemanticContext?
    var cities:[AskAgentCity]=[]
    var findings:[AskAgentFinding]=[]
    var state=AskRecoveryLoopState()
    var loopInitialized=false
    var phase:Phase = .ready
    var pendingRequest:AskConversationStep?
    var reply:AskConversationReply?
    var executor:Data?
    var finalResponse:AskResponse?
    var failure:String?
    var retainedRecordIDs:[String]=[]
    var retainedHistoryVersion:Int? = nil
    var resumable:Bool {![.stopped,.blocked].contains(phase)}
}
/// Local only, separate from the existing chat archive. A failed atomic write
/// never authorizes the next paid request or local operation. No credentials.
@MainActor final class AskTurnRecoveryStore {
    static let shared=AskTurnRecoveryStore()
    static let changed=Notification.Name("AskTurnRecoveryChanged")
    let directory:URL?
    let requirePersistence:Bool
    private var memory:[UUID:AskTurnCheckpoint]=[:]
    private var running=Set<UUID>()
    private var deleted=Set<UUID>()
    private var stoppedIDs=Set<UUID>()
    static let lifetime:TimeInterval=24*60*60
    var now:()->Date=Date.init
    var active=true
    init(directory:URL?=nil,requirePersistence:Bool?=nil) {
#if os(iOS)
        active=UIApplication.shared.applicationState == .active
#endif
#if FEAST_TESTS
        self.requirePersistence=requirePersistence ?? false
        self.directory=directory
#else
        self.requirePersistence=requirePersistence ?? true
        self.directory=directory ?? FileManager.default.urls(for:.applicationSupportDirectory,in:.userDomainMask).first?.appendingPathComponent("AskFeast/turn-checkpoints-v1")
#endif
    }
    func checkpoint(_ turn:UUID)throws->AskTurnCheckpoint? {
        if let value=memory[turn] {
            if value.phase != .completed,(value.resumable || value.finalResponse != nil),now().timeIntervalSince(value.createdAt)>=Self.lifetime {
                var expired=value;expired.phase = .blocked;expired.failure=AskRecoveryError.expired.localizedDescription
                let minimal=scrubbed(expired);memory[turn]=minimal;try save(minimal);return minimal
            }
            return value
        }
        guard let path=directory?.appendingPathComponent(turn.uuidString+".json"),FileManager.default.fileExists(atPath:path.path) else{return nil}
        do {
            guard let size=try path.resourceValues(forKeys:[.fileSizeKey]).fileSize,size<=16*1024*1024 else{throw AskRecoveryError.storage}
            let value=try JSONDecoder().decode(AskTurnCheckpoint.self,from:Data(contentsOf:path))
            try validate(value);guard value.turnID==turn else{throw AskRecoveryError.storage}
            memory[turn]=value;return try checkpoint(turn)
        }catch {throw AskRecoveryError.storage}
    }
    func checkpoints(chat:UUID?=nil)throws->[AskTurnCheckpoint] {
        if let directory,FileManager.default.fileExists(atPath:directory.path) {
            for file in try FileManager.default.contentsOfDirectory(at:directory,includingPropertiesForKeys:nil) where file.pathExtension=="json" {
                guard let id=UUID(uuidString:file.deletingPathExtension().lastPathComponent) else{continue}
                _ = try checkpoint(id)
            }
        }
        return memory.values.filter {chat==nil || $0.chatID==chat}.sorted {$0.createdAt<$1.createdAt}
    }
    private func validate(_ value:AskTurnCheckpoint)throws {
        guard value.version==1,value.request.performanceID==value.turnID,value.request.conversationID==value.chatID,value.request.attachment==nil,!value.request.fromOCR,
              (0...12).contains(value.state.nextStep),value.endpoint.hasPrefix("https://") else{throw AskRecoveryError.storage}
        _ = try value.request.validated()
        if let p=value.pendingRequest {guard p.version==10,p.mode=="conversationStep",p.requestID==value.attemptID.uuidString,p.step==value.state.nextStep else{throw AskRecoveryError.storage}}
        if let reply=value.reply {guard let p=value.pendingRequest,reply.requestID==p.requestID,reply.step==p.step,reply.version==10 else{throw AskRecoveryError.storage}}
    }
    private func scrubbed(_ value:AskTurnCheckpoint)->AskTurnCheckpoint {
        let original=value.userRequest ?? value.request
        let request=AskRequest(mode:original.mode,text:original.text,fromOCR:false,performanceID:value.turnID,conversationID:value.chatID)
        var minimal=AskTurnCheckpoint(turnID:value.turnID,chatID:value.chatID,attemptID:value.attemptID,endpoint:value.endpoint,request:request,createdAt:value.createdAt)
        minimal.phase=value.phase;minimal.failure=value.failure;minimal.state.nextStep=value.state.nextStep;minimal.retainedRecordIDs=value.retainedRecordIDs
        if value.phase == .completed {minimal.finalResponse=value.finalResponse}
        if value.phase == .blocked,now().timeIntervalSince(value.createdAt)<Self.lifetime {minimal.finalResponse=value.finalResponse}
        return minimal
    }
    func save(_ proposed:AskTurnCheckpoint)throws {
        let value = [AskTurnCheckpoint.Phase.stopped,.blocked].contains(proposed.phase) ? scrubbed(proposed) : proposed
        try validate(value)
        guard !requirePersistence || directory != nil else{throw AskRecoveryError.storage}
        guard !deleted.contains(value.turnID),!stoppedIDs.contains(value.turnID) || value.phase == .stopped else{throw AskRecoveryError.stopped}
        if value.phase != .stopped {try Task.checkCancellation()}
        // A late transport/tool completion cannot revive a locally stopped turn.
        if let existing=try checkpoint(value.turnID),existing.phase == .stopped,value.phase != .stopped {throw AskRecoveryError.stopped}
        do {
            let bytes=try JSONEncoder().encode(value);guard bytes.count<=16*1024*1024 else{throw AskRecoveryError.storage}
            if let directory {
                try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:true)
                let path=directory.appendingPathComponent(value.turnID.uuidString+".json")
                try bytes.write(to:path,options:.atomic)
                let handle=try FileHandle(forWritingTo:path);try handle.synchronize();try handle.close()
                let fd=Darwin.open(directory.path,O_RDONLY);guard fd>=0 else{throw AskRecoveryError.storage};defer{Darwin.close(fd)};guard fsync(fd)==0 else{throw AskRecoveryError.storage}
                let parent=Darwin.open(directory.deletingLastPathComponent().path,O_RDONLY);guard parent>=0 else{throw AskRecoveryError.storage};defer{Darwin.close(parent)};guard fsync(parent)==0 else{throw AskRecoveryError.storage}
                var local=path,values=URLResourceValues();values.isExcludedFromBackup=true;try local.setResourceValues(values)
#if os(iOS)
                try FileManager.default.setAttributes([.protectionKey:FileProtectionType.completeUntilFirstUserAuthentication],ofItemAtPath:path.path)
#endif
            }
            memory[value.turnID]=value
        }catch {throw AskRecoveryError.storage}
    }
    func claim(_ id:UUID)throws {guard running.insert(id).inserted else{throw AskRecoveryError.alreadyRunning}}
    func release(_ id:UUID) {running.remove(id);NotificationCenter.default.post(name:Self.changed,object:self)}
    func isRunning(_ id:UUID)->Bool {running.contains(id)}
    func check(_ id:UUID)throws {
        try Task.checkCancellation()
        guard !stoppedIDs.contains(id),let value=try checkpoint(id),value.resumable else{throw AskRecoveryError.stopped}
        guard active else{throw AskRecoveryError.paused}
    }
    func stop(_ id:UUID)throws {
        stoppedIDs.insert(id) // Also fences Stop during preflight, before any file exists.
        guard var value=try checkpoint(id) else{return}
        value.phase = .stopped;try save(value)
    }
    func complete(_ id:UUID,response:AskResponse)throws {
        guard var value=try checkpoint(id) else{throw AskRecoveryError.storage}
        let external=Set((value.request.mapChoices+(value.state.latest?.mapChoices ?? [])+(response.mapChoices ?? [])).map(\.id))
        var retained=Set(value.retainedRecordIDs)
        retained.formUnion(value.context?.index.map(\.id) ?? [])
        retained.formUnion(value.cities.map(\.id));retained.formUnion(value.state.available.keys)
        retained.formUnion(value.state.ordered);retained.formUnion(value.request.collectionDialogueIDs)
        retained.subtract(external)
        retained.formUnion(value.state.historyRecordIDs ?? [])
        retained.formUnion(AskConversationProjection.activeChannelRecordIDs(value.request))
        value.retainedRecordIDs=retained.sorted()
        value.finalResponse=response;value.phase = .completed;try save(scrubbed(value))
    }
    /// Only after the answer has been committed to its ORIGINAL chat archive.
    func removeCompleted(_ id:UUID)throws {
        guard let value=try checkpoint(id),value.phase == .completed else{return}
        if let path=directory?.appendingPathComponent(id.uuidString+".json") {try FileManager.default.removeItem(at:path)}
        memory.removeValue(forKey:id)
    }
    /// Explicit chat deletion removes the private checkpoint after Stop has
    /// fenced any in-memory completion. A tiny in-memory tombstone remains.
    func deleteChat(_ id:UUID)throws {
        for value in try checkpoints(chat:id) {
            try stop(value.turnID)
            deleted.insert(value.turnID)
            if let path=directory?.appendingPathComponent(value.turnID.uuidString+".json"),FileManager.default.fileExists(atPath:path.path) {try FileManager.default.removeItem(at:path)}
            memory.removeValue(forKey:value.turnID)
        }
    }
}
struct AskRecoveryHandle:Sendable {let store:AskTurnRecoveryStore;let turn:UUID;var permission:@Sendable ()async->Bool = {true}}
enum AskRecoveryScope {@TaskLocal static var handle:AskRecoveryHandle?}
enum AskRecoveryActivity {
    @MainActor static func checkNow()throws {if let handle=AskRecoveryScope.handle {try handle.store.check(handle.turn)}}
    static func check()async throws {
        guard let handle=AskRecoveryScope.handle else{return}
        while true {
            do {try await handle.store.check(handle.turn);guard await handle.permission() else{throw AskHostedError.consentRequired};return}
            catch AskRecoveryError.paused {try await Task.sleep(nanoseconds:100_000_000)}
        }
    }
}

struct AskAnswerJobReply:Decodable,Sendable {
    let version:Int,requestID:String,step:Int,state:String
    let result:AskConversationReply?
    let error:String?
    let retryAfterMs:Int?
}
extension AskHostedProvider {
    func recoveryJob(_ operation:String,step:AskConversationStep)async throws->AskAnswerJobReply {
        try configuration.validate()
        guard ["submit","status","cancel","ack"].contains(operation),UUID(uuidString:step.requestID) != nil,(0..<12).contains(step.step),operation != "submit" || step.version==10 else{throw AskHostedError.invalidResponse}
        guard configuration.scope == .savedMetadata else{throw AskHostedError.disabled}
        // Cleanup of an already accepted step sends only its opaque identity.
        // Revoking research consent must not prevent cancellation.
        if operation != "cancel" && operation != "ack" {
            guard await permission(),await libraryToolsEnabled() else{throw AskHostedError.consentRequired}
        }
        let cleanup=operation=="cancel" || operation=="ack"
        let credential:String
        if cleanup,let recoveryCleanupToken {credential=try await recoveryCleanupToken()}else{credential=try await token()}
        guard (43...128).contains(credential.count),credential.allSatisfy({$0.isASCII&&($0.isLetter||$0.isNumber||$0=="_"||$0=="-")}) else{throw AskHostedError.disabled}
        var object:[String:Any]=["version":1,"op":operation,"requestID":step.requestID,"step":step.step]
        if operation=="submit" {
            var request=try JSONSerialization.jsonObject(with:JSONEncoder().encode(step)) as! [String:Any]
            for key in ["task","continuation","result"] where request[key]==nil {request[key]=NSNull()}
            object=["version":1,"op":operation,"request":request]
        }
        let body=try JSONSerialization.data(withJSONObject:object,options:.sortedKeys)
        guard body.count<=512000 else{throw AskError.inputLimit}
        let url=configuration.endpoint.deletingLastPathComponent().appendingPathComponent("answer-jobs")
        var http=URLRequest(url:url);http.httpMethod="POST";http.httpBody=body;http.timeoutInterval=30
        http.setValue("10",forHTTPHeaderField:"X-Feast-Agent-Protocol");http.setValue("application/json",forHTTPHeaderField:"Content-Type");http.setValue("Feast/1.0",forHTTPHeaderField:"User-Agent");http.setValue("Bearer "+credential,forHTTPHeaderField:"Authorization")
        let started=DispatchTime.now().uptimeNanoseconds
        let data:Data,response:HTTPURLResponse
        do {(data,response)=try await sendWithHistoryAccessCheck(http)}catch {
            AskPipelineScope.trace?.elapsed(.transport,since:started,counters:[.requestBytes:body.count])
            var receipt=AskConversationReceipt(requestID:step.requestID,mode:"conversationStep",step:step.step,status:0,data:Data(),elapsed:AskPerformanceRecorder.milliseconds(since:started));receipt.code="recovery_network_interrupted";await AskConversationReceipts.shared.record(receipt);throw error
        }
        AskPipelineScope.trace?.elapsed(.transport,since:started,counters:[.requestBytes:body.count,.responseBytes:data.count])
        if operation=="submit" || operation=="status" {
            let outer=(try? JSONSerialization.jsonObject(with:data)) as? [String:Any]
            let result=(outer?["result"] as? [String:Any]).flatMap {try? JSONSerialization.data(withJSONObject:$0)} ?? data
            var receipt=AskConversationReceipt(requestID:step.requestID,mode:"conversationStep",step:step.step,status:response.statusCode,data:result,elapsed:AskPerformanceRecorder.milliseconds(since:started))
            if let state=outer?["state"] as? String,["queued","running","uncertain","failed","expired","cancelled"].contains(state) {receipt.code="recovery_"+state}
            await AskConversationReceipts.shared.record(receipt)
        }
        guard response.url==url,response.mimeType=="application/json",data.count<=450000 else{throw AskHostedError.invalidResponse}
        guard response.statusCode==200 || response.statusCode==202 else{throw AskConversationFailure(status:response.statusCode,code:"recovery_job_failed")}
        let value=try JSONDecoder().decode(AskAnswerJobReply.self,from:data)
        guard value.version==1,value.requestID==step.requestID,value.step==step.step,["queued","running","completed","failed","uncertain","cancelled","expired","acknowledged"].contains(value.state) else{throw AskHostedError.invalidResponse}
        return value
    }
    func recoveredConversationStep(_ step:AskConversationStep,handle:AskRecoveryHandle)async throws->AskConversationReply {
        guard var checkpoint=try await handle.store.checkpoint(handle.turn),checkpoint.endpoint==configuration.endpoint.absoluteString else{throw AskRecoveryError.unavailable}
        guard checkpoint.resumable else{throw AskRecoveryError.stopped}
        try Task.checkCancellation()
        if let pending=checkpoint.pendingRequest {
            let encoder=JSONEncoder();encoder.outputFormatting=[.sortedKeys]
            guard try encoder.encode(pending)==encoder.encode(step) else{throw AskRecoveryError.unavailable}
        }
        if let reply=checkpoint.reply {return try checkedConversationReply(reply,step:step)}
        let resume=checkpoint.phase == .awaitingReply
        checkpoint.pendingRequest=step;checkpoint.phase = .awaitingReply
        try await handle.store.save(checkpoint) // Durable intent precedes submit, even if its response is lost.
        var job:AskAnswerJobReply
        if resume {
            do {job=try await recoveryJob("status",step:step)}
            catch let e as AskConversationFailure where e.status==404 {job=try await recoveryJob("submit",step:step)}
        }else {job=try await recoveryJob("submit",step:step)}
        while true {
            try Task.checkCancellation()
            switch job.state {
            case "completed":
                guard let value=job.result else{throw AskHostedError.invalidResponse}
                let reply=try checkedConversationReply(value,step:step)
                guard var saved=try await handle.store.checkpoint(handle.turn) else{throw AskRecoveryError.storage}
                saved.reply=reply;saved.phase = .receivedReply;try await handle.store.save(saved)
                // Acknowledgement is cleanup, not part of the answer's critical
                // path. Carry opaque identity only; retain no request context.
                let identity=AskConversationStep(requestID:step.requestID,step:step.step,text:"",context:.init(index:[],recent:[]),cities:[],task:nil,findings:[],history:[],continuation:nil,result:nil)
                Task { _ = try? await recoveryJob("ack",step:identity) }
                return reply
            case "queued","running":
                try await Task.sleep(nanoseconds:UInt64(min(max(job.retryAfterMs ?? 1000,100),5000))*1_000_000)
                job=try await recoveryJob("status",step:step)
            case "cancelled":throw AskRecoveryError.stopped
            case "expired","acknowledged":throw AskRecoveryError.expired
            default:throw AskRecoveryError.unavailable
            }
        }
    }
}
