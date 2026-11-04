import Foundation
import Security

enum AskPublicLinks {
    static func url(_ key:String,info:[String:Any]=Bundle.main.infoDictionary ?? [:])->URL? {
        guard ["FeastPrivacyPolicyURL","FeastSupportURL"].contains(key),
              let raw=info[key] as? String,let url=URL(string:raw),url.scheme=="https",
              let host=url.host,host.contains("."),url.user==nil,url.password==nil else {return nil}
        return url
    }
}

enum AskPrivacy {
    // A new provider or materially broader payload requires a new scope key and fresh user consent.
    static let onlineKey = "AskFeast.onlinePermission.cloudflare-openai.catalog-public-dialogue-selected-images.v4"
    static func accept() { UserDefaults.standard.set(true,forKey:onlineKey) }
    static func withdraw() { UserDefaults.standard.set(false,forKey:onlineKey) }
    static var onlineAllowed: Bool { UserDefaults.standard.bool(forKey: onlineKey) }
    static let disclosure = "Your question, a compact index of saved-place names, cities and cuisines, a limited recent conversation with relevant public findings and place references, and images you attach pass through Cloudflare to OpenAI. Notes, tags, saved statuses and unselected photos aren’t sent to these AI services."
}

/// Release configuration is nonsecret bundle metadata, never a hardcoded development token.
enum AskProductionAccess {
    static func configuration(info: [String: Any]) -> AskHostedConfiguration? {
        guard let raw = info["FeastAskProductionEndpoint"] as? String, let endpoint = URL(string:raw),
              let host = info["FeastAskProductionHost"] as? String, !host.isEmpty else { return nil }
        let configuration = AskHostedConfiguration(environment:.production,endpoint:endpoint,scope:.savedMetadata,productionHost:host)
        return (try? configuration.validate()) == nil ? nil : configuration
    }
    /// Existence only; do not request credential bytes or show authentication UI before consent.
    static var credentialAvailable: Bool {
        let query: [String:Any] = [kSecClass as String:kSecClassGenericPassword,
            kSecAttrService as String:"com.jongalante.Feast.ask.production",kSecAttrAccount as String:"device",
            kSecAttrSynchronizable as String:false,kSecReturnAttributes as String:true,kSecMatchLimit as String:kSecMatchLimitOne,
            kSecUseAuthenticationUI as String:kSecUseAuthenticationUIFail]
        return SecItemCopyMatching(query as CFDictionary,nil) == errSecSuccess
    }
    static func credential() throws -> String {
        guard AskPrivacy.onlineAllowed else { throw AskHostedError.consentRequired }
        let query: [String:Any] = [kSecClass as String:kSecClassGenericPassword,
            kSecAttrService as String:"com.jongalante.Feast.ask.production",kSecAttrAccount as String:"device",
            kSecAttrSynchronizable as String:false,kSecReturnData as String:true,kSecMatchLimit as String:kSecMatchLimitOne,
            kSecUseAuthenticationUI as String:kSecUseAuthenticationUIFail]
        var value:CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary,&value) == errSecSuccess, let data = value as? Data, let token = String(data:data,encoding:.utf8) else { throw AskHostedError.disabled }
        return token
    }
}

/// Separate, temporary owner-validation route. Excluded from physical-device builds;
/// it cannot turn the public production endpoint into a simulator authentication bypass.
enum AskOwnerValidationAccess {
    static let host = "feast-owner-validation.jonmgalante.workers.dev"
    static let service = "com.jongalante.Feast.ask.owner-validation"
    static func configuration(info:[String:Any]) -> AskHostedConfiguration? {
#if targetEnvironment(simulator) || FEAST_TESTS
        guard (info["FeastAskOwnerValidationEnabled"] as? Bool == true || info["FeastAskOwnerValidationEnabled"] as? String == "YES"),
              info["FeastAskOwnerValidationEndpoint"] as? String == "https://" + host + "/v1/answer" else {return nil}
        return .init(environment:.production,endpoint:URL(string:"https://" + host + "/v1/answer")!,scope:.savedMetadata,productionHost:host,ownerValidation:true)
#else
        return nil
#endif
    }
    static var credentialAvailable:Bool {
#if targetEnvironment(simulator)
        return SecItemCopyMatching(query(returnData:false) as CFDictionary,nil) == errSecSuccess
#else
        return false
#endif
    }
    static func credential() throws -> String {
#if targetEnvironment(simulator)
        guard AskPrivacy.onlineAllowed else {throw AskHostedError.consentRequired}
        var value:CFTypeRef?
        guard SecItemCopyMatching(query(returnData:true) as CFDictionary,&value) == errSecSuccess,
              let data=value as? Data,let token=String(data:data,encoding:.utf8) else {throw AskHostedError.disabled}
        return token
#else
        throw AskHostedError.disabled
#endif
    }
#if targetEnvironment(simulator) && FEAST_OWNER_VALIDATION
    /// Only the explicit operator status command uses this; it sends no AI input and cannot dispatch a model.
    static func budgetStatusCredential() throws -> String {
        var value:CFTypeRef?
        guard SecItemCopyMatching(query(returnData:true) as CFDictionary,&value) == errSecSuccess,
              let data=value as? Data,let token=String(data:data,encoding:.utf8) else {throw AskHostedError.disabled}
        return token
    }
#endif
    private static func query(returnData:Bool) -> [String:Any] {
        [kSecClass as String:kSecClassGenericPassword,kSecAttrService as String:service,kSecAttrAccount as String:"device",
         kSecAttrSynchronizable as String:false,(returnData ? kSecReturnData : kSecReturnAttributes) as String:true,
         kSecMatchLimit as String:kSecMatchLimitOne,kSecUseAuthenticationUI as String:kSecUseAuthenticationUIFail]
    }
}

#if targetEnvironment(simulator) && FEAST_OWNER_VALIDATION
import CryptoKit
/// Explicit operator-only enrollment, compiled out of normal builds. Never called by ordinary icon launch.
enum AskOwnerEnrollment {
    private static var intendedBuild:Bool {
        ProcessInfo.processInfo.environment["SIMULATOR_UDID"] == "4F6EAF55-E0E2-4895-9D19-C2D1D4D89D8D" && Bundle.main.bundleIdentifier == "com.jongalante.Feast" && AskOwnerValidationAccess.configuration(info:Bundle.main.infoDictionary ?? [:]) != nil
    }
    static var pilotRequested:Bool {
        AskPilotLaunchPlan.requested(ProcessInfo.processInfo.arguments)
    }
    private static func pilotRequest(runID:String,mode:String,workloadID:String="museums",arm:String="legacy")async throws->[String:Any] {
        let endpoint=URL(string:"https://"+AskOwnerValidationAccess.host+"/v1/answer")!
        var request=URLRequest(url:endpoint);request.httpMethod="POST";request.timeoutInterval=600
        request.setValue("application/json",forHTTPHeaderField:"Content-Type");request.setValue("11",forHTTPHeaderField:"X-Feast-Agent-Protocol")
        request.setValue("Bearer "+(try AskOwnerValidationAccess.budgetStatusCredential()),forHTTPHeaderField:"Authorization")
        request.httpBody=try JSONSerialization.data(withJSONObject:["version":11,"mode":mode,"runID":runID,"workloadID":workloadID,"arm":arm])
        let (data,response)=try await AskHostedHTTP().send(request)
        guard response.url==endpoint,response.mimeType=="application/json",data.count<=400000,let value=try JSONSerialization.jsonObject(with:data) as? [String:Any] else{throw AskHostedError.invalidResponse}
        guard response.statusCode==200 else {throw AskConversationFailure(status:response.statusCode,code:value["error"] as? String ?? "pilot_failed")}
        if mode=="researchPilot" {guard value["version"] as? Int==11,value["runID"] as? String==runID,value["workloadID"] as? String==workloadID,value["arm"] as? String==arm else{throw AskHostedError.invalidResponse}}
        else if mode=="researchPilotStop" {guard value["stopped"] as? Bool==true else{throw AskHostedError.invalidResponse}}
        else {guard value["version"] as? Int==1,value["runID"] as? String==runID else{throw AskHostedError.invalidResponse}}
        return value
    }
    /// Operator-only fixed public pilot. Never reads the collection, current chat,
    /// drafts or settings and never runs on ordinary icon launch.
    static func researchPilotIfRequested()async {
        let args=ProcessInfo.processInfo.arguments
        guard pilotRequested,intendedBuild else{return}
        let sequence=AskPilotSequence()
        var receipt:[String:Any]=["state":"failed","checkedAt":ISO8601DateFormatter().string(from:Date())]
        do {
            guard let plan=try AskPilotLaunchPlan.make(args,intendedBuild:intendedBuild) else{return}
            let runID=plan.runID;receipt["runID"]=runID
            switch plan.mode {
            case .stop:receipt["result"]=try await pilotRequest(runID:runID,mode:"researchPilotStop");receipt["state"]="stopped"
            case .status:receipt["result"]=try await pilotRequest(runID:runID,mode:"researchPilotStatus");receipt["state"]="status"
            case .run:
                try await sequence.run(consent:{AskPrivacy.onlineAllowed},request:{workload,arm in
                    let value=try await pilotRequest(runID:runID,mode:"researchPilot",workloadID:workload,arm:arm)
                    return try JSONSerialization.data(withJSONObject:value)
                },stop:{_ = try? await pilotRequest(runID:runID,mode:"researchPilotStop")})
                receipt["state"]="completed"
            }
        }catch {receipt["code"]=(error as? AskConversationFailure)?.code ?? (error is CancellationError ? "cancelled" : "pilot_failed")}
        let partial=await sequence.snapshot()
        if !partial.isEmpty {receipt["results"]=partial.compactMap {try? JSONSerialization.jsonObject(with:$0)}}
        do {let directory=try FileManager.default.url(for:.documentDirectory,in:.userDomainMask,appropriateFor:nil,create:true)
            try JSONSerialization.data(withJSONObject:receipt,options:[.sortedKeys]).write(to:directory.appendingPathComponent("FeastResearchPilotReceipt.json"),options:.atomic)
            print("Research pilot receipt ready. No collection data or credentials exported.")
        }catch {print("Research pilot receipt unavailable; do not retry paid work without checking server status.")}
    }
    static func readBudgetIfRequested() async {
        guard ProcessInfo.processInfo.arguments.contains("-feastOwnerBudgetStatus"),intendedBuild else {return}
        var result:[String:Any] = ["state":"failed","checkedAt":ISO8601DateFormatter().string(from:Date())]
        do {
            let endpoint=URL(string:"https://"+AskOwnerValidationAccess.host+"/v1/status")!
            var request=URLRequest(url:endpoint);request.timeoutInterval=20
            request.setValue("Bearer "+(try AskOwnerValidationAccess.budgetStatusCredential()),forHTTPHeaderField:"Authorization")
            let (data,response)=try await AskHostedHTTP().send(request)
            result["httpStatus"]=response.statusCode
            guard response.statusCode == 200,response.url == endpoint,response.mimeType == "application/json",data.count <= 4096,
                  let value=try JSONSerialization.jsonObject(with:data) as? [String:Any],value["protocol"] as? Int == 1,
                  value["capMicroUSD"] is NSNull,let reserved=value["reservedMicroUSD"] as? Int,reserved >= 0,
                  value["remainingMicroUSD"] is NSNull,let halted=value["halted"] as? Bool else {throw AskHostedError.invalidResponse}
            result["state"]="verified";result["budget"]=value;result["eligibleForOneHold"] = !halted
        } catch { /* No response body, token, prompt, or error description is logged. */ }
        do {
            let directory=try FileManager.default.url(for:.documentDirectory,in:.userDomainMask,appropriateFor:nil,create:true)
            try JSONSerialization.data(withJSONObject:result,options:[.sortedKeys]).write(to:directory.appendingPathComponent("FeastOwnerBudgetStatus.json"),options:.atomic)
            print("Owner budget-status receipt ready. No model request made.")
        } catch {print("Owner budget-status receipt unavailable. Stop before paid requests.")}
    }
    // Explicit operator renewal only; ordinary app launch never creates or changes access.
    static func renewIfRequested() async {
        let args=ProcessInfo.processInfo.arguments
        guard args.contains("-feastPrepareOwnerRenewal") || args.contains("-feastVerifyOwnerRenewal"),intendedBuild else {return}
        var pending:[String:Any]=[kSecClass as String:kSecClassGenericPassword,kSecAttrService as String:AskOwnerValidationAccess.service,kSecAttrAccount as String:"pending-30day",kSecAttrSynchronizable as String:false,kSecUseAuthenticationUI as String:kSecUseAuthenticationUIFail]
        let directory:URL
        do {directory=try FileManager.default.url(for:.documentDirectory,in:.userDomainMask,appropriateFor:nil,create:true)} catch {return}
        if args.contains("-feastPrepareOwnerRenewal") {
            guard SecItemCopyMatching(pending as CFDictionary,nil)==errSecItemNotFound else {print("Owner renewal pending or unavailable. No replacement generated.");return}
            var bytes=[UInt8](repeating:0,count:32)
            guard SecRandomCopyBytes(kSecRandomDefault,bytes.count,&bytes)==errSecSuccess else {return}
            defer {bytes.withUnsafeMutableBytes {$0.initializeMemory(as:UInt8.self,repeating:0)}}
            let token=Data(bytes).base64EncodedString().replacingOccurrences(of:"+",with:"-").replacingOccurrences(of:"/",with:"_").replacingOccurrences(of:"=",with:"")
            var item=pending;item.removeValue(forKey:kSecUseAuthenticationUI as String)
            item[kSecAttrAccessible as String]=kSecAttrAccessibleWhenUnlockedThisDeviceOnly;item[kSecValueData as String]=Data(token.utf8)
            guard SecItemAdd(item as CFDictionary,nil)==errSecSuccess else {return}
            let now=Date(),formatter=ISO8601DateFormatter()
            let record=["id":"owner-original-iphone17","sha256":SHA256.hash(data:Data(token.utf8)).map {String(format:"%02x",$0)}.joined(),"createdAt":formatter.string(from:now),"expiresAt":formatter.string(from:now.addingTimeInterval(30*24*3600))]
            do {try JSONSerialization.data(withJSONObject:[record],options:[.sortedKeys]).write(to:directory.appendingPathComponent("FeastOwnerRenewal.json"),options:.atomic);print("Owner renewal staged in Keychain. Hash-only metadata ready; active access unchanged.")} catch {print("Owner renewal staged but metadata unavailable. Stop; do not repeat.")}
            return
        }
        var receipt:[String:Any]=["state":"failed","checkedAt":ISO8601DateFormatter().string(from:Date())]
        do {
            pending[kSecReturnData as String]=true;pending[kSecMatchLimit as String]=kSecMatchLimitOne
            var value:CFTypeRef?
            guard SecItemCopyMatching(pending as CFDictionary,&value)==errSecSuccess,let bytes=value as? Data,let token=String(data:bytes,encoding:.utf8) else {throw AskHostedError.invalidResponse}
            let endpoint=URL(string:"https://"+AskOwnerValidationAccess.host+"/v1/status")!
            var request=URLRequest(url:endpoint);request.timeoutInterval=20;request.setValue("Bearer "+token,forHTTPHeaderField:"Authorization")
            let (data,response)=try await AskHostedHTTP().send(request)
            guard response.statusCode==200,response.url==endpoint,response.mimeType=="application/json",data.count<=4096,let budget=try JSONSerialization.jsonObject(with:data) as? [String:Any],budget["protocol"] as? Int==1,budget["accountingVersion"] as? Int==2,budget["capMicroUSD"] is NSNull,let reserved=budget["reservedMicroUSD"] as? Int,reserved >= 0,budget["remainingMicroUSD"] is NSNull,budget["halted"] as? Bool==false,budget["pendingMicroUSD"] as? Int==0,budget["legacyUncertainMicroUSD"] as? Int==0 else {throw AskHostedError.invalidResponse}
            var oldRequest=URLRequest(url:endpoint);oldRequest.timeoutInterval=20
            oldRequest.setValue("Bearer "+(try AskOwnerValidationAccess.budgetStatusCredential()),forHTTPHeaderField:"Authorization")
            let (_,oldResponse)=try await AskHostedHTTP().send(oldRequest)
            guard oldResponse.statusCode==401 else {throw AskHostedError.invalidResponse}
            receipt["oldCredentialRejected"]=true
            let active:[String:Any]=[kSecClass as String:kSecClassGenericPassword,kSecAttrService as String:AskOwnerValidationAccess.service,kSecAttrAccount as String:"device",kSecAttrSynchronizable as String:false,kSecUseAuthenticationUI as String:kSecUseAuthenticationUIFail]
            guard SecItemUpdate(active as CFDictionary,[kSecValueData as String:bytes] as CFDictionary)==errSecSuccess else {throw AskHostedError.invalidResponse}
            var removal=pending;removal.removeValue(forKey:kSecReturnData as String);removal.removeValue(forKey:kSecMatchLimit as String)
            let removed=SecItemDelete(removal as CFDictionary)
            receipt["state"]=removed==errSecSuccess ? "verified-promoted" : "promoted-pending-cleanup";receipt["pendingRemoved"]=removed==errSecSuccess;receipt["budget"]=budget
        } catch { /* Never log credential, headers, error description or response body. */ }
        try? JSONSerialization.data(withJSONObject:receipt,options:[.sortedKeys]).write(to:directory.appendingPathComponent("FeastOwnerRenewalStatus.json"),options:.atomic)
    }
    static func runIfRequested() {
        guard ProcessInfo.processInfo.arguments.contains("-feastProvisionOwnerValidation") else {return}
        guard intendedBuild else {
            print("Owner enrollment refused: wrong build or simulator.");return
        }
        let identity:[String:Any] = [kSecClass as String:kSecClassGenericPassword,kSecAttrService as String:AskOwnerValidationAccess.service,
            kSecAttrAccount as String:"device",kSecAttrSynchronizable as String:false,kSecUseAuthenticationUI as String:kSecUseAuthenticationUIFail]
        let status=SecItemCopyMatching(identity as CFDictionary,nil)
        guard status == errSecItemNotFound else {print("Owner enrollment refused: credential exists or Keychain unavailable (\(status)). No replacement.");return}
        var bytes=[UInt8](repeating:0,count:32)
        guard SecRandomCopyBytes(kSecRandomDefault,bytes.count,&bytes) == errSecSuccess else {print("Owner enrollment stopped: entropy unavailable.");return}
        defer {bytes.withUnsafeMutableBytes {$0.initializeMemory(as:UInt8.self,repeating:0)}}
        let token=Data(bytes).base64EncodedString().replacingOccurrences(of:"+",with:"-").replacingOccurrences(of:"/",with:"_").replacingOccurrences(of:"=",with:"")
        var item=identity;item.removeValue(forKey:kSecUseAuthenticationUI as String)
        item[kSecAttrAccessible as String]=kSecAttrAccessibleWhenUnlockedThisDeviceOnly;item[kSecValueData as String]=Data(token.utf8)
        let added=SecItemAdd(item as CFDictionary,nil)
        guard added == errSecSuccess else {print("Owner enrollment stopped: Keychain write failed (\(added)).");return}
        let now=Date(),formatter=ISO8601DateFormatter()
        let hash=SHA256.hash(data:Data(token.utf8)).map {String(format:"%02x",$0)}.joined()
        let record=["id":"owner-original-iphone17","sha256":hash,"createdAt":formatter.string(from:now),"expiresAt":formatter.string(from:now.addingTimeInterval(48*3600))]
        do {
            let directory=try FileManager.default.url(for:.documentDirectory,in:.userDomainMask,appropriateFor:nil,create:true)
            let data=try JSONSerialization.data(withJSONObject:[record],options:[.sortedKeys])
            try data.write(to:directory.appendingPathComponent("FeastOwnerEnrollment.json"),options:.atomic)
            print("Owner credential installed. Hash-only enrollment metadata ready. No network request made.")
        } catch {print("Owner credential installed but metadata write failed. Stop; do not repeat enrollment.")}
    }
}
#endif
