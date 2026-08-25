import Foundation
import Security

enum KeychainStore {
    private static let service = "com.kenturnerlaw.praecipe.mail"

    static func savePassword(_ password: String, account: String) throws {
        let key = account.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !password.isEmpty, !key.isEmpty else {
            throw MailError.auth("Email and password are required.")
        }
        let data = Data(password.utf8)
        let base: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
            kSecUseDataProtectionKeychain as String: true,
        ]
        SecItemDelete(base as CFDictionary)
        var add = base
        add[kSecValueData as String] = data
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let status = SecItemAdd(add as CFDictionary, nil)
        guard status == errSecSuccess || status == errSecDuplicateItem else {
            throw MailError.auth("Could not save the password on this iPhone (keychain \(status)).")
        }
        if status == errSecDuplicateItem {
            SecItemUpdate(base as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        }
        guard load(account: key) == password else {
            throw MailError.auth("Password did not save. Sign in again.")
        }
    }

    static func load(account: String) -> String {
        let key = account.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
            kSecUseDataProtectionKeychain as String: true,
        ]
        var out: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &out)
        guard status == errSecSuccess, let data = out as? Data else { return "" }
        return String(data: data, encoding: .utf8) ?? ""
    }

    static func deletePassword(account: String) {
        let key = account.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
            kSecUseDataProtectionKeychain as String: true,
        ]
        SecItemDelete(query as CFDictionary)
    }

    static func allAccountKeys() -> [String] {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecReturnAttributes as String: true,
            kSecMatchLimit as String: kSecMatchLimitAll,
            kSecUseDataProtectionKeychain as String: true,
        ]
        var out: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &out)
        guard status == errSecSuccess else { return [] }
        let rows = (out as? [[String: Any]]) ?? []
        return rows.compactMap { $0[kSecAttrAccount as String] as? String }
    }

    static func saveAccountMeta(email: String, provider: String, authType: String) {
        let payload = "\(provider)|\(authType)"
        try? savePassword(payload, account: "account-meta:\(email)")
    }

    static func loadAccountMeta(email: String) -> (provider: String, authType: String)? {
        let raw = load(account: "account-meta:\(email)")
        let parts = raw.split(separator: "|", maxSplits: 1).map(String.init)
        guard parts.count == 2, !parts[0].isEmpty else { return nil }
        return (parts[0], parts[1])
    }
}
