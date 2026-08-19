import Foundation
import Security

struct MailProvider: Identifiable {
    let id: String
    let label: String
    let imapHost: String
    let imapPort: String
    let smtpHost: String
    let smtpPort: String
    let smtpTLS: String
    let appPasswordURL: URL?
    let help: String

    static let all: [MailProvider] = [
        MailProvider(
            id: "gmail",
            label: "Google",
            imapHost: "imap.gmail.com",
            imapPort: "993",
            smtpHost: "smtp.gmail.com",
            smtpPort: "465",
            smtpTLS: "ssl",
            appPasswordURL: URL(string: "https://myaccount.google.com/apppasswords"),
            help: "Create a 16-character app password named Praecipe. Regular Gmail passwords are rejected."
        ),
        MailProvider(
            id: "microsoft",
            label: "Microsoft 365",
            imapHost: "outlook.office365.com",
            imapPort: "993",
            smtpHost: "smtp.office365.com",
            smtpPort: "587",
            smtpTLS: "starttls",
            appPasswordURL: nil,
            help: "Work or school mailbox. Use IMAP with an app password if your tenant allows it, or add the account after enabling IMAP in the admin center."
        ),
        MailProvider(
            id: "icloud",
            label: "iCloud",
            imapHost: "imap.mail.me.com",
            imapPort: "993",
            smtpHost: "smtp.mail.me.com",
            smtpPort: "587",
            smtpTLS: "starttls",
            appPasswordURL: URL(string: "https://account.apple.com/account/manage/section/security"),
            help: "Create an app-specific password. Your Apple ID password will be rejected."
        ),
        MailProvider(
            id: "yahoo",
            label: "Yahoo",
            imapHost: "imap.mail.yahoo.com",
            imapPort: "993",
            smtpHost: "smtp.mail.yahoo.com",
            smtpPort: "465",
            smtpTLS: "ssl",
            appPasswordURL: URL(string: "https://login.yahoo.com/account/security"),
            help: "Generate a Yahoo app password and paste it here."
        ),
    ]

    static func named(_ id: String) -> MailProvider? { all.first { $0.id == id } }
}

enum KeychainStore {
    private static let service = "com.kenturnerlaw.praecipe"

    static func savePassword(_ password: String, account: String) {
        let data = Data(password.utf8)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(query as CFDictionary)
        var add = query
        add[kSecValueData as String] = data
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        SecItemAdd(add as CFDictionary, nil)
    }

    static func password(account: String) -> String {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var out: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &out)
        guard status == errSecSuccess, let data = out as? Data else { return "" }
        return String(data: data, encoding: .utf8) ?? ""
    }

    static func deletePassword(account: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(query as CFDictionary)
    }
}
