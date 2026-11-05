import Foundation
import Combine
import CryptoKit

struct AskAccessEntry: Codable, Identifiable, Equatable {
    let id: UUID
    let label: String
    let role: String
    let state: String
    let createdAt: Double
    let expiresAt: Double
    let activatedAt: Double?
    var valid: Bool {
        !label.isEmpty && label.utf16.count <= 80 && ["owner", "member"].contains(role) &&
        ["active", "invited", "expired", "revoked"].contains(state) && createdAt.isFinite && createdAt >= 0 &&
        expiresAt.isFinite && expiresAt > createdAt && (activatedAt.map { $0.isFinite && $0 >= 0 } ?? true)
    }
}
struct AskAccessPending: Codable, Equatable {
    let kind: String
    let id: UUID
    let label: String?
    let invitation: String?
    let actorHash: String
    var valid: Bool {
        actorHash.count == 64 && actorHash.allSatisfy { $0.isHexDigit } &&
        ((kind == "invite" && label.map { !$0.isEmpty && $0.utf16.count <= 80 && !$0.unicodeScalars.contains(where:CharacterSet.controlCharacters.contains) } == true && invitation.map(AskPendingActivation.validToken) == true) ||
         (kind == "revoke" && label == nil && invitation == nil))
    }
    func body() throws -> Data {
        guard valid else { throw AskActivationError.keychain }
        var payload: [String: String] = ["kind":kind, "id":id.uuidString.lowercased()]
        if kind == "invite" {
            payload["label"] = label
            payload["sha256"] = Self.digest("phone-access-v1:invitation:" + invitation!)
        }
        return try JSONSerialization.data(withJSONObject:payload, options:.sortedKeys)
    }
    static func digest(_ value:String)->String { SHA256.hash(data:Data(value.utf8)).map {String(format:"%02x",$0)}.joined() }
}
@MainActor protocol AskManagementStoring {
    func activeToken() throws -> String
    func managementPending() throws -> AskAccessPending?
    func saveManagementPending(_ pending:AskAccessPending) throws
    func clearManagementPending() throws
}
@MainActor final class AskAccessManagement: ObservableObject {
    @Published private(set) var entries:[AskAccessEntry] = []
    @Published private(set) var working = false
    @Published private(set) var pending:AskAccessPending?
    @Published private(set) var confirmed:AskAccessEntry?
    @Published private(set) var canDiscardPending=false
    @Published private(set) var message:String?
    private let store:any AskManagementStoring
    private let send:(URLRequest)async throws -> (Data,HTTPURLResponse)
    private let makeToken:()throws -> String
    init(store:(any AskManagementStoring)?=nil, send:@escaping(URLRequest)async throws -> (Data,HTTPURLResponse)={try await AskHostedHTTP.shared.send($0)}, makeToken:@escaping()throws -> String=AskPhoneActivation.randomToken) {
        self.store=store ?? AskActivationKeychain();self.send=send;self.makeToken=makeToken
        do {pending=try self.store.managementPending()} catch {message="The saved access operation couldn't be read. Nothing was sent."}
    }
    private func request(_ body:Data,configuration:AskHostedConfiguration,token:String)async throws -> Data {
        try configuration.validate()
        guard !configuration.ownerValidation, configuration.environment == .production else {throw AskActivationError.unavailable}
        let endpoint=configuration.endpoint.deletingLastPathComponent().appendingPathComponent("access/manage")
        var request=URLRequest(url:endpoint);request.httpMethod="POST";request.timeoutInterval=20
        request.setValue("application/json",forHTTPHeaderField:"Content-Type");request.setValue("Bearer "+token,forHTTPHeaderField:"Authorization");request.httpBody=body
        let (data,response)=try await send(request)
        guard response.url==endpoint,response.mimeType=="application/json",data.count<=131072 else {throw AskActivationError.unavailable}
        guard response.statusCode==200 else {
            if [400,409].contains(response.statusCode) {canDiscardPending=true}
            if response.statusCode==401 || response.statusCode==403 {message="Owner access is required. Check access or use your Cloudflare recovery process."}
            else if response.statusCode==409 {message="This operation conflicts with an existing invitation or the access directory is full. No new code is ready to share."}
            throw AskActivationError.unavailable
        }
        return data
    }
    func refresh(configuration:AskHostedConfiguration)async {
        guard !working else{return};working=true;defer{working=false}
        do {
            let data=try await request(Data(#"{"kind":"list"}"#.utf8),configuration:configuration,token:store.activeToken())
            struct Result:Decodable {let version:Int;let entries:[AskAccessEntry]}
            let result=try JSONDecoder().decode(Result.self,from:data)
            guard result.version==1,result.entries.count<=320,result.entries.allSatisfy(\.valid),Set(result.entries.map(\.id)).count==result.entries.count else {throw AskActivationError.unavailable}
            if let p=pending,p.actorHash != AskAccessPending.digest(try store.activeToken()) {
                canDiscardPending=true // Fresh owner-authorized directory reconciles the prior identity.
            }
            entries=result.entries.sorted {$0.createdAt == $1.createdAt ? $0.id.uuidString < $1.id.uuidString : $0.createdAt > $1.createdAt};message=nil
        } catch {entries=[];if message==nil {message="Access couldn't be verified. Try again; no collection changes were made."}}
    }
    func create(label:String,configuration:AskHostedConfiguration)async {
        guard !working else{return}
        let clean=label.trimmingCharacters(in:.whitespacesAndNewlines)
        guard !clean.isEmpty,clean.utf16.count<=80,!clean.unicodeScalars.contains(where:CharacterSet.controlCharacters.contains) else {message="Use a short name for this invitation.";return}
        do {
            guard try store.managementPending()==nil else {message="Finish checking the pending operation first.";return}
            let p=AskAccessPending(kind:"invite",id:UUID(),label:clean,invitation:try makeToken(),actorHash:AskAccessPending.digest(try store.activeToken()))
            try store.saveManagementPending(p);pending=p
            await retry(configuration:configuration)
        } catch {message="The invitation couldn't be securely prepared. Nothing was sent."}
    }
    func revoke(_ entry:AskAccessEntry,configuration:AskHostedConfiguration)async {
        guard !working,entry.role=="member",entry.state != "revoked" else{return}
        do {
            guard try store.managementPending()==nil else {message="Finish checking the pending operation first.";return}
            let p=AskAccessPending(kind:"revoke",id:entry.id,label:nil,invitation:nil,actorHash:AskAccessPending.digest(try store.activeToken()))
            try store.saveManagementPending(p);pending=p
            await retry(configuration:configuration)
        } catch {message="Revocation couldn't be securely prepared. Nothing was sent."}
    }
    func retry(configuration:AskHostedConfiguration)async {
        guard !working else{return};working=true;message=nil;confirmed=nil;canDiscardPending=false;defer{working=false}
        do {
            guard let p=try store.managementPending(),p.valid else {throw AskActivationError.pending}
            pending=p
            let token=try store.activeToken()
            guard p.actorHash==AskAccessPending.digest(token) else {message="This pending operation belongs to the previous owner credential. Recover it through Cloudflare before continuing.";return}
            let data=try await request(p.body(),configuration:configuration,token:token)
            struct Result:Decodable {let version:Int;let entry:AskAccessEntry}
            let result=try JSONDecoder().decode(Result.self,from:data),e=result.entry
            guard result.version==1,e.valid,e.id==p.id,e.role=="member",p.kind=="revoke" ? e.state=="revoked" : e.label==p.label else {throw AskActivationError.unavailable}
            confirmed=e
            entries.removeAll {$0.id==e.id};entries.insert(e,at:0)
            if p.kind=="revoke" {try store.clearManagementPending();pending=nil;message="Access revoked."}
        } catch {if message==nil {
            message = confirmed?.state == "revoked" ? "Access was revoked, but local confirmation couldn't be saved. Retry safely checks it again." : "The outcome isn't confirmed. Retry checks the same operation; don't send another invitation."
        }}
    }
    func discardRejectedPending() {
        guard !working,canDiscardPending else{return}
        do {try store.clearManagementPending();pending=nil;confirmed=nil;canDiscardPending=false;message=nil}
        catch {message="The pending operation couldn't be cleared. Try again."}
    }
    func finishInvitation() {
        guard !working,let p=pending,confirmed?.id==p.id else{return}
        do {try store.clearManagementPending();pending=nil;confirmed=nil;message=nil} catch {message="The code remains securely saved on this phone. Try Done again."}
    }
}

// Static, editable request. Never populated from a collection, chat, or credential.
enum AskAccessRequest {
    static let address="jonmgalante@gmail.com"
    static let subject="Ask Feast access request"
    static let body="Hi Jon, I'd like an invitation to Ask Feast. Thanks!"
    static var url:URL {
        var parts=URLComponents();parts.scheme="mailto";parts.path=address
        parts.queryItems=[.init(name:"subject",value:subject),.init(name:"body",value:body)]
        return parts.url!
    }
}
