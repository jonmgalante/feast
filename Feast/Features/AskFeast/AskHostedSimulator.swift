import Foundation
import Security
import CryptoKit

#if DEBUG && targetEnvironment(simulator)
/// Explicit synthetic simulator setup only. Raw tokens never leave app Keychain.
enum AskHostedSimulator {
    struct KeychainFailure: LocalizedError {
        let stage: String
        let status: OSStatus
        var errorDescription: String? { "Keychain \(stage) failed (\(status)). No AI request sent." }
    }
    static let accounts = ["feast-dev-tester-one", "feast-dev-tester-two"]
    static let service = "com.jongalante.Feast.devAsk"
    static let expiry = "2026-11-22T14:30:00Z"
    static var synthetic: Bool { ProcessInfo.processInfo.arguments.contains("-feastSyntheticPreview") }
    static var enabled: Bool { synthetic && ProcessInfo.processInfo.arguments.contains("-feastHostedSynthetic") }
    static var savedPlaces: Bool {
        if AskSavedLaunchPolicy.enabled(arguments: ProcessInfo.processInfo.arguments,
            simulator: ProcessInfo.processInfo.environment["SIMULATOR_UDID"],
            approved: UserDefaults.standard.bool(forKey: AskSavedLaunchPolicy.key)) { return true }
        // Internal owner build can reuse already approved access, without provisioning or launch flags.
        guard ProcessInfo.processInfo.environment["SIMULATOR_UDID"] == AskSavedLaunchPolicy.originalSimulator else { return false }
        var lookup = query(accounts[0]); lookup[kSecReturnAttributes as String] = true
        lookup[kSecReturnData as String] = false; lookup[kSecUseAuthenticationUI as String] = kSecUseAuthenticationUIFail
        return SecItemCopyMatching(lookup as CFDictionary,nil) == errSecSuccess
    }
    static func rememberApprovedConfiguration() {
        if AskSavedLaunchPolicy.canRemember(arguments: ProcessInfo.processInfo.arguments, simulator: ProcessInfo.processInfo.environment["SIMULATOR_UDID"]) {
            UserDefaults.standard.set(true, forKey: AskSavedLaunchPolicy.key)
        }
    }
    static var setup: Bool { synthetic && ProcessInfo.processInfo.arguments.contains("-feastHostedSetup") }

    private static func query(_ account: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
         kSecAttrAccount as String: account, kSecAttrSynchronizable as String: false]
    }
    static func token(_ account: String = accounts[0]) throws -> String {
        guard synthetic || savedPlaces, accounts.contains(account) else { throw AskHostedError.disabled }
        var request = query(account)
        request[kSecReturnData as String] = true
        request[kSecMatchLimit as String] = kSecMatchLimitOne
        var value: CFTypeRef?
        guard SecItemCopyMatching(request as CFDictionary, &value) == errSecSuccess,
              let data = value as? Data, let token = String(data: data, encoding: .utf8) else { throw AskHostedError.disabled }
        return token
    }
}
#endif
