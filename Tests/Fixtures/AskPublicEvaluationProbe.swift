import Foundation
import Security
import CryptoKit
#if DEBUG && targetEnvironment(simulator)
/// Manual one-shot harness: isolated simulator only, existing tester-two Keychain only, public enums only.
@MainActor enum AskPublicEvaluationProbe {
    static var requested: Bool { ProcessInfo.processInfo.arguments.contains("-feastReplaceTesterTwoApproved") || ProcessInfo.processInfo.arguments.contains("-feastKeychainAttributesOnly") || ProcessInfo.processInfo.arguments.contains("-feastEvaluationStatusOnly") || ProcessInfo.processInfo.arguments.contains(where: { $0.hasPrefix("-feastEvaluationCase=") }) }
    static func run() async -> String {
        guard AskHostedSimulator.synthetic,
              ProcessInfo.processInfo.environment["SIMULATOR_UDID"] == "5325CDB2-9206-4CA4-B433-17DC93BC5A6B" else { return "STOP: Evaluation requires the isolated synthetic simulator. Nothing sent." }
        // Takes precedence over every network/setup flag. Never requests credential bytes.
        if ProcessInfo.processInfo.arguments.contains("-feastKeychainAttributesOnly") {
            return keychainAttributesOnly()
        }
        if ProcessInfo.processInfo.arguments.contains("-feastReplaceTesterTwoApproved") {
            return replaceApprovedAbsentTesterTwo()
        }
        let directory: URL
        do { directory = try FileManager.default.url(for: .documentDirectory, in: .userDomainMask, appropriateFor: nil, create: true) }
        catch { return "STOP: Evaluation evidence directory unavailable. Nothing sent." }
        let credential: String
        do { credential = try AskHostedSimulator.token(AskHostedSimulator.accounts[1]) }
        catch { return "STOP: Existing tester-two access unavailable. No credential created; no request sent." }
        let root = "https://feast-proxy-dev.jonmgalante.workers.dev"
        var statusRequest = URLRequest(url: URL(string: root + "/v1/evaluation/status")!)
        statusRequest.timeoutInterval = 20
        statusRequest.setValue("Feast/1.0", forHTTPHeaderField: "User-Agent")
        statusRequest.setValue("Bearer " + credential, forHTTPHeaderField: "Authorization")
        let status: AskEvaluationContract.Budget
        do {
            let (data,response) = try await AskHostedHTTP().send(statusRequest)
            guard response.statusCode == 200, response.url == statusRequest.url, response.mimeType == "application/json", data.count <= 8192 else { return "STOP: Budget status unavailable (HTTP \(response.statusCode)) or evaluation disabled. No model request." }
            status = try JSONDecoder().decode(AskEvaluationContract.Budget.self, from: data)
            guard status.verified else { return "STOP: Budget status could not be verified. No model request." }
            try JSONEncoder().encode(status).write(to: directory.appendingPathComponent("FeastEvaluationStatus.json"), options: .atomic)
        } catch { return "STOP: Budget read unsuccessful. No model request." }
        if ProcessInfo.processInfo.arguments.contains("-feastEvaluationStatusOnly") { return "Read-only evaluation budget recorded. No model request." }
        guard let flag = ProcessInfo.processInfo.arguments.first(where: { $0.hasPrefix("-feastEvaluationCase=") }) else { return "Read-only evaluation budget recorded. No model request." }
        let caseID = String(flag.dropFirst("-feastEvaluationCase=".count))
        guard ProcessInfo.processInfo.arguments.contains("-feastEvaluationLiveApproved"),
              let selected = AskEvaluationContract.cases.first(where: { $0.id == caseID }), status.availableAttempts > 0,
              status.cases.first(where: { $0.caseID == caseID })?.state == "not-attempted" else { return "STOP: Approved case/allowance unavailable. No model request." }
        let requestID = UUID().uuidString
        let marker = directory.appendingPathComponent("FeastEvaluation-" + caseID + ".json")
        do {
            let initial = ["phase":"starting","runID":AskEvaluationContract.runID,"caseID":caseID,"requestID":requestID]
            try JSONSerialization.data(withJSONObject: initial, options: [.sortedKeys]).write(to: marker, options: .withoutOverwriting)
        } catch { return "STOP: Case marker exists or cannot be created. Inspect outcome; do not repeat." }
        func write(_ value: [String: Any]) { if let data = try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]) { try? data.write(to: marker, options: .atomic) } }
        var http = URLRequest(url: URL(string: root + "/v1/evaluation/answer")!)
        http.httpMethod = "POST"; http.timeoutInterval = 80
        http.setValue("Feast/1.0", forHTTPHeaderField: "User-Agent")
        http.setValue("application/json", forHTTPHeaderField: "Content-Type")
        http.setValue("Bearer " + credential, forHTTPHeaderField: "Authorization")
        do { http.httpBody = try JSONEncoder().encode(AskEvaluationContract.Payload(requestID: requestID, criteria: selected.criteria)) }
        catch { write(["phase":"stopped-before-send","caseID":caseID,"requestID":requestID]); return "STOP: Public request encoding failed; no repeat." }
        do {
            let started = DispatchTime.now().uptimeNanoseconds
            let (data,response) = try await AskHostedHTTP().send(http)
            guard response.statusCode == 200, response.url == http.url, response.mimeType == "application/json", data.count <= 65536 else {
                var stopped: [String: Any] = ["phase":"stopped","httpStatus":response.statusCode,"caseID":caseID,"requestID":requestID,"noAutomaticRetry":true]
                if data.count <= 4096, let error = try? JSONSerialization.jsonObject(with: data) as? [String:Any], let reason = error["reason"] as? String ?? error["error"] as? String,
                   reason.range(of: "^[a-z0-9_]{1,80}$", options: .regularExpression) != nil { stopped["reason"] = reason }
                write(stopped)
                return "STOP: Evaluation failed. Inspect status/receipt before any next request. No automatic retry."
            }
            let reply = try JSONDecoder().decode(AskEvaluationContract.Reply.self, from: data)
            let safeData = try JSONEncoder().encode(reply)
            let safeReply = try JSONSerialization.jsonObject(with: safeData)
            guard reply.verified(caseID: caseID, before: status) else {
                write(["phase":"validation-failed","reason":"reply_contract_rejected","caseID":caseID,"requestID":requestID,"response":safeReply,"noAutomaticRetry":true])
                return "STOP: Comparison/accounting could not be verified. No repeat."
            }
            write(["phase":reply.evaluation.stop ? "stopped":"response-received-review-required","caseID":caseID,"requestID":requestID,"response":safeReply,"clientOverallMS":AskPerformanceRecorder.milliseconds(since: started),"noAutomaticRetry":true])
            return reply.evaluation.stop ? "STOP: Comparison halted the evaluation. Review retained result; no next case." : "Public comparison recorded. Review citations, event dates and accounting before any next case. No automatic continuation."
        } catch {
            write(["phase":"outcome-uncertain","caseID":caseID,"requestID":requestID,"noAutomaticRetry":true])
            return "STOP: Request outcome uncertain. Inspect read-only status; do not retry."
        }
    }

    private static func replaceApprovedAbsentTesterTwo() -> String {
        do {
            let directory = try FileManager.default.url(for: .documentDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
            let receipt = directory.appendingPathComponent("FeastTesterTwoReplacement.json")
            guard !FileManager.default.fileExists(atPath: receipt.path) else {
                return "Replacement receipt already exists. Inspect it; no new credential or request."
            }
            let identity: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: "com.jongalante.Feast.devAsk",
                kSecAttrAccount as String: "feast-dev-tester-two", kSecAttrSynchronizable as String: false]
            var lookup = identity
            lookup[kSecReturnAttributes as String] = true
            lookup[kSecReturnData as String] = false
            lookup[kSecUseAuthenticationUI as String] = kSecUseAuthenticationUIFail
            let status = SecItemCopyMatching(lookup as CFDictionary, nil)
            guard status == errSecItemNotFound else {
                return "STOP: Replacement requires confirmed absent tester-two (OSStatus \(status)). Nothing changed."
            }
            var bytes = [UInt8](repeating: 0, count: 32)
            guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else {
                return "STOP: Secure randomness unavailable. Nothing changed."
            }
            let credential = Data(bytes).base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
            var item = identity
            item[kSecValueData as String] = Data(credential.utf8)
            item[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
            let added = SecItemAdd(item as CFDictionary, nil)
            guard added == errSecSuccess else { return "STOP: Tester-two insertion failed (OSStatus \(added)). Inspect before retry. No request." }
            let hash = SHA256.hash(data: Data(credential.utf8)).map { String(format: "%02x", $0) }.joined()
            let report: [String: Any] = ["id": "feast-dev-tester-two", "sha256": hash,
                "expiresAt": "2026-11-22T14:30:00Z", "createdAt": ISO8601DateFormatter().string(from: Date()),
                "keychainWriteStatus": Int(added), "requestSent": false,
                "simulator": "5325CDB2-9206-4CA4-B433-17DC93BC5A6B"]
            try JSONSerialization.data(withJSONObject: report, options: [.sortedKeys, .prettyPrinted]).write(to: receipt, options: .withoutOverwriting)
            return "Tester-two replacement stored in isolated Keychain. Hash-only handoff ready; no request sent."
        } catch {
            return "STOP: Replacement receipt unavailable. Keychain outcome may have changed; inspect before retry. No request sent."
        }
    }

    private static func keychainAttributesOnly() -> String {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "com.jongalante.Feast.devAsk",
            kSecAttrAccount as String: "feast-dev-tester-two",
            kSecAttrSynchronizable as String: false,
            kSecReturnAttributes as String: true,
            kSecReturnData as String: false,
            kSecMatchLimit as String: kSecMatchLimitOne,
            kSecUseAuthenticationUI as String: kSecUseAuthenticationUIFail
        ]
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        // Whitelist output; never serialize the returned dictionary or any credential material.
        let attributes = result as? [String: Any] ?? [:]
        var report: [String: Any] = [
            "version": 1, "createdAt": ISO8601DateFormatter().string(from: Date()),
            "bundleIdentifier": Bundle.main.bundleIdentifier ?? "unavailable",
            "simulator": "5325CDB2-9206-4CA4-B433-17DC93BC5A6B",
            "account": "feast-dev-tester-two", "service": "com.jongalante.Feast.devAsk",
            "status": Int(status), "lookupSucceeded": status == errSecSuccess,
            "notFoundInCurrentContext": status == errSecItemNotFound,
            "requestSent": false, "credentialDataRequested": false
        ]
        for (output, key) in [("itemAccessGroup", kSecAttrAccessGroup), ("itemProtection", kSecAttrAccessible)] {
            if let value = attributes[key as String] as? String { report[output] = value }
        }
        if let value = attributes[kSecAttrSynchronizable as String] as? Bool { report["itemSynchronizable"] = value }
        do {
            let directory = try FileManager.default.url(for: .documentDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
            let data = try JSONSerialization.data(withJSONObject: report, options: [.sortedKeys, .prettyPrinted])
            try data.write(to: directory.appendingPathComponent("FeastKeychainAttributes.json"), options: .atomic)
            return "Attributes-only lookup recorded (OSStatus \(status)). No credential data requested; no network request."
        } catch {
            return "Attributes-only lookup OSStatus \(status); report write failed. No credential data requested; no network request."
        }
    }
}
#endif
