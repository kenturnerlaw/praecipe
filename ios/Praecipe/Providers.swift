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
            id: "icloud",
            label: "iCloud",
            imapHost: "imap.mail.me.com",
            imapPort: "993",
            smtpHost: "smtp.mail.me.com",
            smtpPort: "587",
            smtpTLS: "starttls",
            appPasswordURL: URL(string: "https://account.apple.com/account/manage/section/security"),
            help: "Use an app-specific password."
        ),
        MailProvider(
            id: "microsoft",
            label: "Microsoft Exchange",
            imapHost: "outlook.office365.com",
            imapPort: "993",
            smtpHost: "smtp.office365.com",
            smtpPort: "587",
            smtpTLS: "starttls",
            appPasswordURL: nil,
            help: ""
        ),
        MailProvider(
            id: "gmail",
            label: "Google",
            imapHost: "imap.gmail.com",
            imapPort: "993",
            smtpHost: "smtp.gmail.com",
            smtpPort: "465",
            smtpTLS: "ssl",
            appPasswordURL: URL(string: "https://myaccount.google.com/apppasswords"),
            help: "Use a 16-character app password."
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
            help: "Use a Yahoo app password."
        ),
    ]

    static func named(_ id: String) -> MailProvider? { all.first { $0.id == id } }
}
