import Foundation
import Combine
import CryptoKit
import Security

enum AskActivationError: LocalizedError {
    case invalidCode, unavailable, keychain, rejected, pending, alreadyActive
    var errorDescription: String? {
        switch self {
        case .invalidCode: "Enter the complete activation code you received."
        case .unavailable: "Activation couldn't be verified. Retry activation to check the same attempt; your saved places are unchanged."
        case .keychain: "Feast couldn't read or securely store access on this device. Any pending activation is retained for checking; your saved places are unchanged."
        case .rejected: "This activation code is unavailable, expired or already used. Ask for a new code."
        case .pending: "An activation is already waiting to be checked. Retry that activation first."
        case .alreadyActive: "Ask Feast is already activated on this device."
        }
    }
}
struct AskPendingActivation: Codable, Equatable {
    let invitation: String
    let deviceToken: String
    let deviceID: UUID
    let activationID: UUID
    static func validToken(_ value: String) -> Bool {
        value.utf8.count == 43 && value.utf8.allSatisfy { (65...90).contains($0) || (97...122).contains($0) || (48...57).contains($0) || $0 == 45 || $0 == 95 }
    }
    var valid: Bool { Self.validToken(invitation) && Self.validToken(deviceToken) }
    var credentialHash: String {
        SHA256.hash(data: Data(("phone-access-v1:device:" + deviceToken).utf8)).map { String(format:"%02x", $0) }.joined()
    }
    func body() throws -> Data {
        guard valid else { throw AskActivationError.keychain }
        return try JSONSerialization.data(withJSONObject: ["version":1,"invitation":invitation,"credentialHash":credentialHash,
            "deviceID":deviceID.uuidString.lowercased(),"activationID":activationID.uuidString.lowercased()],options:.sortedKeys)
    }
    func accepts(_ data: Data) -> Bool {
        guard data.count <= 4096, let v=try? JSONSerialization.jsonObject(with:data) as? [String:Any],
              Set(v.keys)==["version","grantID","deviceID","activationID","activatedAt"],
              v["version"] as? Int == 1,let grant=v["grantID"] as? String,UUID(uuidString:grant) != nil,
              v["deviceID"] as? String == deviceID.uuidString.lowercased(),v["activationID"] as? String == activationID.uuidString.lowercased(),
              let at=v["activatedAt"] as? Double,at.isFinite,at>=0,at.rounded()==at else { return false }
        return true
    }
}
@MainActor protocol AskActivationStoring {
    func active() -> Bool
    func pending() throws -> AskPendingActivation?
    func savePending(_ value: AskPendingActivation) throws
    func commit(_ value: AskPendingActivation) throws
    func removeRejectedPending() throws
    func activeToken() throws -> String
    func removeRevokedCredential(_ token:String) throws
}
/// Separate pending and active Keychain items. A lost reply never causes a new device secret.
/// These items are device-only, non-synchronizing, and never written to preferences or files.
@MainActor final class AskActivationKeychain: AskActivationStoring, AskManagementStoring {
    private let service="com.jongalante.Feast.ask.production"
    private func query(_ account:String)->[String:Any] {
        [kSecClass as String:kSecClassGenericPassword,kSecAttrService as String:service,
         kSecAttrAccount as String:account,kSecAttrSynchronizable as String:false,
         kSecUseAuthenticationUI as String:kSecUseAuthenticationUIFail]
    }
    func managementPending()throws->AskAccessPending? {
        guard let data=try read("management-pending") else{return nil}
        guard data.count<=4096,let value=try? JSONDecoder().decode(AskAccessPending.self,from:data),value.valid else{throw AskActivationError.keychain};return value
    }
    func saveManagementPending(_ value:AskAccessPending)throws {
        guard value.valid,try managementPending()==nil else{throw AskActivationError.pending}
        try add(JSONEncoder().encode(value),account:"management-pending")
    }
    func clearManagementPending()throws {
        let status=SecItemDelete(query("management-pending") as CFDictionary)
        guard status==errSecSuccess||status==errSecItemNotFound else{throw AskActivationError.keychain}
    }
    func active()->Bool { AskProductionAccess.credentialAvailable }
    private func read(_ account:String)throws->Data? {
        var q=query(account);q[kSecReturnData as String]=true;q[kSecMatchLimit as String]=kSecMatchLimitOne
        var result:CFTypeRef?;let status=SecItemCopyMatching(q as CFDictionary,&result)
        if status==errSecItemNotFound{return nil}
        guard status==errSecSuccess,let data=result as? Data else {throw AskActivationError.keychain};return data
    }
    func pending()throws->AskPendingActivation? {
        guard let data=try read("activation-pending") else{return nil}
        guard let p=try? JSONDecoder().decode(AskPendingActivation.self,from:data),p.valid else {throw AskActivationError.keychain};return p
    }
    private func add(_ data:Data,account:String)throws {
        var q=query(account);q.removeValue(forKey:kSecUseAuthenticationUI as String)
        q[kSecAttrAccessible as String]=kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly;q[kSecValueData as String]=data
        guard SecItemAdd(q as CFDictionary,nil)==errSecSuccess else {throw AskActivationError.keychain}
    }
    func savePending(_ value:AskPendingActivation)throws {
        guard value.valid,!active() else {throw AskActivationError.alreadyActive}
        if let prior=try pending(){guard prior==value else {throw AskActivationError.pending};return}
        try add(JSONEncoder().encode(value),account:"activation-pending")
    }
    func commit(_ value:AskPendingActivation)throws {
        guard try pending()==value else {throw AskActivationError.keychain}
        if let old=try read("device") {guard old==Data(value.deviceToken.utf8) else {throw AskActivationError.alreadyActive}}
        else {try add(Data(value.deviceToken.utf8),account:"device")}
        // If this cleanup fails, the active credential remains valid and the exact
        // pending receipt remains recoverable. Never replace an existing credential.
        let status=SecItemDelete(query("activation-pending") as CFDictionary)
        guard status==errSecSuccess||status==errSecItemNotFound else {throw AskActivationError.keychain}
    }
    func removeRejectedPending()throws {
        let status=SecItemDelete(query("activation-pending") as CFDictionary)
        guard status==errSecSuccess||status==errSecItemNotFound else {throw AskActivationError.keychain}
    }
    func activeToken()throws->String {
        guard let data=try read("device"),let token=String(data:data,encoding:.utf8),AskPendingActivation.validToken(token) else{throw AskActivationError.keychain};return token
    }
    func removeRevokedCredential(_ token:String)throws {
        guard try activeToken()==token else{throw AskActivationError.keychain}
        if let pending=try pending(),pending.deviceToken==token{try removeRejectedPending()}
        let status=SecItemDelete(query("device") as CFDictionary)
        guard status==errSecSuccess||status==errSecItemNotFound else{throw AskActivationError.keychain}
    }
}
@MainActor final class AskPhoneActivation: ObservableObject {
    @Published private(set) var working=false
    @Published private(set) var hasPending=false
    @Published private(set) var activated=false
    @Published private(set) var isOwner=false
    @Published private(set) var message:String?
    private let store:any AskActivationStoring
    private let send:(URLRequest)async throws->(Data,HTTPURLResponse)
    private let makeToken:()throws->String
    init(store:(any AskActivationStoring)?=nil,send:@escaping(URLRequest)async throws->(Data,HTTPURLResponse)={try await AskHostedHTTP.shared.send($0)},makeToken:@escaping()throws->String=AskPhoneActivation.randomToken){
        self.store=store ?? AskActivationKeychain();self.send=send;self.makeToken=makeToken;refresh()
    }
    func refresh(){activated=store.active();do{hasPending=try store.pending() != nil}catch{message=AskActivationError.keychain.localizedDescription}}
    nonisolated static func randomToken()throws->String {
        var bytes=[UInt8](repeating:0,count:32)
        guard SecRandomCopyBytes(kSecRandomDefault,bytes.count,&bytes)==errSecSuccess else {throw AskActivationError.keychain}
        return Data(bytes).base64EncodedString().replacingOccurrences(of:"+",with:"-").replacingOccurrences(of:"/",with:"_").replacingOccurrences(of:"=",with:"")
    }
    /// Explicit free access check, not AI consent and not an automatic credential reset.
    func checkAccess(configuration:AskHostedConfiguration)async {
        guard !working else{return};working=true;message=nil;isOwner=false;defer{working=false;refresh()}
        do {
            try configuration.validate();guard !configuration.ownerValidation,configuration.environment == .production else{throw AskActivationError.unavailable}
            let token=try store.activeToken(),endpoint=configuration.endpoint.deletingLastPathComponent().appendingPathComponent("access/status")
            var request=URLRequest(url:endpoint);request.timeoutInterval=15;request.setValue("Bearer "+token,forHTTPHeaderField:"Authorization")
            let(data,response)=try await send(request)
            guard response.url==endpoint,response.mimeType=="application/json",data.count<=4096,let value=try JSONSerialization.jsonObject(with:data) as? [String:Any] else{throw AskActivationError.unavailable}
            if response.statusCode==401,value["error"] as? String=="unauthorized" {
                try store.removeRevokedCredential(token);message="This device no longer has Ask Feast access. You can enter a new activation code."
            } else {
                guard response.statusCode==200,value["version"] as? Int==1,let id=value["deviceID"] as? String,UUID(uuidString:id) != nil else{throw AskActivationError.unavailable}
                isOwner=value["role"] as? String == "owner"
                message="Ask Feast access is active."
            }
        }catch{message=AskActivationError.unavailable.localizedDescription}
    }
    func activate(code:String,configuration:AskHostedConfiguration)async {
        guard !working else{return};working=true;message=nil;defer{working=false;refresh()}
        do {
            try configuration.validate()
            guard !configuration.ownerValidation,configuration.environment == .production else {throw AskActivationError.unavailable}
            guard !store.active() else {throw AskActivationError.alreadyActive}
            let pending:AskPendingActivation
            if let prior=try store.pending(){pending=prior}
            else {
                let clean=code.trimmingCharacters(in:.whitespacesAndNewlines)
                guard AskPendingActivation.validToken(clean) else {throw AskActivationError.invalidCode}
                pending=AskPendingActivation(invitation:clean,deviceToken:try makeToken(),deviceID:UUID(),activationID:UUID())
                try store.savePending(pending) // Durable before dispatch. No secret leaves before this succeeds.
            }
            hasPending=true
            let endpoint=configuration.endpoint.deletingLastPathComponent().appendingPathComponent("access/activate")
            var request=URLRequest(url:endpoint);request.httpMethod="POST";request.timeoutInterval=20
            request.setValue("application/json",forHTTPHeaderField:"Content-Type");request.httpBody=try pending.body()
            let (data,response)=try await send(request)
            guard response.url==endpoint,response.mimeType=="application/json",data.count<=4096 else {throw AskActivationError.unavailable}
            if response.statusCode==403,let v=try? JSONSerialization.jsonObject(with:data) as? [String:Any],v["error"] as? String=="invitation_unavailable" {
                try store.removeRejectedPending();throw AskActivationError.rejected
            }
            guard response.statusCode==200,pending.accepts(data) else {throw AskActivationError.unavailable}
            try store.commit(pending);activated=true
        } catch let error as AskActivationError {message=error.localizedDescription}
        catch {message=AskActivationError.unavailable.localizedDescription}
    }
}
