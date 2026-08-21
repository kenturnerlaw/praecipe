import Foundation
import SwiftData

@MainActor
final class MailSyncService: ObservableObject {
    @Published var status = "Ready"
    @Published var busy = false
    private let transport = MailTransport()
    private var pollTask: Task<Void, Never>?

    func startPolling(context: ModelContext) {
        pollTask?.cancel()
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.sync(context: context)
                try? await Task.sleep(nanoseconds: 120_000_000_000)
            }
        }
    }

    func stop() { pollTask?.cancel() }

    func sync(context: ModelContext) async {
        guard !busy else { return }
        let accounts = (try? context.fetch(FetchDescriptor<MailAccount>())) ?? []
        let enabled = accounts.filter(\.enabled)
        guard let account = enabled.first(where: \.isDefault) ?? enabled.first else {
            status = "Add a mailbox in Settings."
            return
        }
        busy = true
        status = "Getting mail…"
        do {
            let credential = try await credential(for: account)
            let folders = ["INBOX", "Sent", "SENT", "[Gmail]/Sent Mail"]
            var added = 0
            for folder in Array(Set(folders)) {
                let (exists, envelopes, boxes) = try await transport.fetchLatest(
                    host: account.imapHost,
                    port: Int(account.imapPort) ?? 993,
                    user: account.imapUser,
                    password: credential.password,
                    oauthToken: credential.oauthToken,
                    folder: folder,
                    afterUID: folder.uppercased() == "INBOX" ? account.lastUID : 0
                )
                if !boxes.isEmpty { _ = boxes }
                guard exists else { continue }
                for env in envelopes {
                    added += upsert(env, account: account, folder: folder == "INBOX" ? "INBOX" : folderRole(folder), context: context)
                    if folder.uppercased() == "INBOX", let n = Int(env.uid) {
                        account.lastUID = max(account.lastUID, n)
                    }
                }
            }
            try context.save()
            status = added == 0 ? "Up to date." : "Added \(added) message(s)."
        } catch {
            status = error.localizedDescription
        }
        busy = false
    }

    func toggleFlag(_ message: MailMessage, flag: String, add: Bool, context: ModelContext) async {
        guard let account = account(for: message, context: context) else { return }
        do {
            let credential = try await credential(for: account)
            try await transport.setFlag(
                host: account.imapHost,
                port: Int(account.imapPort) ?? 993,
                user: account.imapUser,
                password: credential.password,
                oauthToken: credential.oauthToken,
                folder: message.folder,
                uid: message.imapUID,
                flag: "\\" + flag,
                add: add
            )
            if flag == "Seen" { message.seen = add }
            if flag == "Flagged" { message.flagged = add }
            try? context.save()
        } catch {
            status = error.localizedDescription
        }
    }

    func send(from account: MailAccount, to: [String], cc: [String] = [], subject: String, body: String, inReplyTo: String = "", references: String = "") async throws {
        let credential = try await credential(for: account)
        let fromHeader = account.displayName.isEmpty ? account.email : "\(account.displayName) <\(account.email)>"
        let raw = RFC822.buildRaw(from: fromHeader, to: to, cc: cc, subject: subject, body: body, inReplyTo: inReplyTo, references: references)
        try await transport.sendMail(
            host: account.smtpHost,
            port: Int(account.smtpPort) ?? 587,
            tls: account.smtpTLS,
            user: account.smtpUser.isEmpty ? account.email : account.smtpUser,
            password: credential.password,
            oauthToken: credential.oauthToken,
            from: account.email,
            to: to + cc,
            raw: raw
        )
    }

    private func credential(for account: MailAccount) async throws -> (password: String, oauthToken: String?) {
        if account.provider == "microsoft" || account.authType == "oauth" {
            return ("", try await MicrosoftOAuth.accessToken(email: account.email))
        }
        let password = KeychainStore.password(account: account.email)
        guard !password.isEmpty else { throw MailError.auth("Mailbox password missing. Open Settings to repair sign in.") }
        return (password, nil)
    }

    private func account(for message: MailMessage, context: ModelContext) -> MailAccount? {
        let email = message.accountEmail
        let all = (try? context.fetch(FetchDescriptor<MailAccount>())) ?? []
        return all.first { $0.email == email }
    }

    private func folderRole(_ name: String) -> String {
        let n = name.lowercased()
        if n.contains("sent") { return "SENT" }
        if n.contains("draft") { return "DRAFTS" }
        if n.contains("trash") || n.contains("deleted") { return "TRASH" }
        return name
    }

    @discardableResult
    private func upsert(_ env: IMAPEnvelope, account: MailAccount, folder: String, context: ModelContext) -> Int {
        let parsed = RFC822.parse(env.rfc822)
        let mid = parsed.messageId.isEmpty ? "uid-\(env.uid)" : parsed.messageId
        let email = account.email
        var descriptor = FetchDescriptor<MailMessage>(predicate: #Predicate { msg in
            msg.messageIdHeader == mid && msg.accountEmail == email
        })
        descriptor.fetchLimit = 1
        if let existing = try? context.fetch(descriptor).first {
            existing.seen = env.flags.contains { $0.caseInsensitiveCompare("Seen") == .orderedSame }
            existing.flagged = env.flags.contains { $0.caseInsensitiveCompare("Flagged") == .orderedSame }
            return 0
        }
        let msg = MailMessage(accountEmail: account.email, folder: folder, imapUID: env.uid)
        msg.messageIdHeader = mid
        msg.inReplyTo = parsed.inReplyTo
        msg.referencesHeader = parsed.references
        msg.fromAddr = parsed.from
        msg.toAddr = parsed.to
        msg.ccAddr = parsed.cc
        msg.bccAddr = parsed.bcc
        msg.replyTo = parsed.replyTo
        msg.subject = parsed.subject
        msg.sentAt = parsed.date
        msg.bodyText = parsed.text
        msg.bodyHTML = parsed.html
        msg.snippet = String((parsed.text.isEmpty ? stripHTML(parsed.html) : parsed.text).prefix(240))
        msg.seen = env.flags.contains { $0.caseInsensitiveCompare("Seen") == .orderedSame }
        msg.flagged = env.flags.contains { $0.caseInsensitiveCompare("Flagged") == .orderedSame }
        msg.hasAttachments = !parsed.attachments.isEmpty
        for att in parsed.attachments {
            let a = MailAttachment(filename: att.filename, mime: att.mime, data: att.data)
            a.message = msg
            msg.attachments.append(a)
        }
        context.insert(msg)
        ingestContacts(from: msg, context: context)
        return 1
    }

    private func ingestContacts(from msg: MailMessage, context: ModelContext) {
        let blob = [msg.fromAddr, msg.toAddr, msg.ccAddr].joined(separator: ", ")
        let emails = emailAddresses(in: blob)
        let existing = (try? context.fetch(FetchDescriptor<Person>())) ?? []
        let have = Set(existing.map { $0.email.lowercased() })
        for addr in emails where !have.contains(addr) {
            context.insert(Person(email: addr, name: displayName(in: blob, email: addr)))
        }
    }
}

func stripHTML(_ html: String) -> String {
    html.replacingOccurrences(of: "<[^>]+>", with: " ", options: .regularExpression)
        .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
        .trimmingCharacters(in: .whitespacesAndNewlines)
}

func emailAddresses(in header: String) -> [String] {
    let pattern = try? NSRegularExpression(pattern: "[A-Z0-9._%+-]+@[A-Z0-9.-]+\\.[A-Z]{2,}", options: .caseInsensitive)
    let ns = header as NSString
    return pattern?.matches(in: header, range: NSRange(location: 0, length: ns.length)).compactMap {
        ns.substring(with: $0.range).lowercased()
    } ?? []
}

func displayName(in header: String, email: String) -> String {
    if let r = header.range(of: email, options: .caseInsensitive) {
        let before = header[..<r.lowerBound]
        let cleaned = before.replacingOccurrences(of: "<", with: "").trimmingCharacters(in: .whitespacesAndNewlines.union(CharacterSet(charactersIn: "\"")))
        if cleaned.contains("@") { return "" }
        return cleaned.trimmingCharacters(in: CharacterSet(charactersIn: ",;"))
    }
    return ""
}
