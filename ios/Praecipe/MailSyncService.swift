import Foundation
import SwiftData

@MainActor
final class MailSyncService: ObservableObject {
    @Published var status = ""
    @Published var busy = false
    @Published var lastError: String?
    @Published var needsSignIn = false
    private let transport = MailTransport()
    private var pollTask: Task<Void, Never>?
    private var imapAuthRetried = false

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
            status = ""
            lastError = nil
            needsSignIn = false
            return
        }
        await syncSelectedFolder(for: account, context: context, includeInbox: true)
    }

    func syncSelectedFolder(for account: MailAccount, context: ModelContext, includeInbox: Bool = false) async {
        guard !busy else { return }
        lastError = nil
        needsSignIn = false
        busy = true
        status = "Getting mail…"
        var added = 0
        do {
            let credentials = try await credentials(for: account, context: context)
            let imapNames = try await transport.listMailboxes(
                host: account.imapHost,
                port: Int(account.imapPort) ?? 993,
                user: account.imapUser.isEmpty ? account.email : account.imapUser,
                credentials: credentials
            )
            let folders = MailFolders.build(from: imapNames)
            let role = account.selectedFolderRole.isEmpty ? "INBOX" : account.selectedFolderRole
            let imap = account.selectedFolderIMAP.isEmpty
                ? (MailFolders.imapName(forRole: role, in: folders) ?? role)
                : account.selectedFolderIMAP

            var toSync: [(imap: String, role: String)] = []
            if includeInbox, role != "INBOX", role != "FLAGGED" {
                if let inbox = MailFolders.imapName(forRole: "INBOX", in: folders)
                    ?? imapNames.first(where: { $0.uppercased() == "INBOX" }) {
                    toSync.append((inbox, "INBOX"))
                }
            }
            if role == "FLAGGED" {
                if let inbox = MailFolders.imapName(forRole: "INBOX", in: folders)
                    ?? imapNames.first(where: { $0.uppercased() == "INBOX" }) {
                    toSync.append((inbox, "INBOX"))
                }
            } else {
                toSync.append((imap, role))
            }

            var seen = Set<String>()
            for item in toSync {
                let key = "\(item.imap.lowercased())|\(item.role)"
                guard seen.insert(key).inserted else { continue }
                added += try await fetchFolder(
                    imapName: item.imap,
                    role: item.role,
                    account: account,
                    credentials: credentials,
                    context: context
                )
            }
            try context.save()
            status = added == 0 ? "Updated just now" : "Updated · \(added) new"
            lastError = nil
        } catch {
            if await retryAfterIMAPAuthFailure(error, account: account, context: context) {
                busy = false
                return
            }
            lastError = Self.friendlyMailError(error)
            needsSignIn = Self.isReauthError(error)
            status = lastError ?? ""
        }
        busy = false
    }

    func syncFolder(role: String, imapName: String, account: MailAccount, context: ModelContext) async {
        guard !busy else { return }
        lastError = nil
        needsSignIn = false
        busy = true
        status = "Getting \(MailFolders.displayName(for: role))…"
        do {
            let credentials = try await credentials(for: account, context: context)
            let added = try await fetchFolder(
                imapName: imapName,
                role: role,
                account: account,
                credentials: credentials,
                context: context
            )
            account.selectedFolderRole = role
            account.selectedFolderIMAP = imapName
            try context.save()
            status = added == 0 ? "Updated just now" : "Updated · \(added) new"
            lastError = nil
        } catch {
            if await retryAfterIMAPAuthFailure(error, account: account, context: context, role: role, imapName: imapName) {
                busy = false
                return
            }
            lastError = Self.friendlyMailError(error)
            needsSignIn = Self.isReauthError(error)
            status = lastError ?? ""
        }
        busy = false
    }

    func loadFolderItems(for account: MailAccount, context: ModelContext) async -> [MailFolderItem] {
        do {
            let credentials = try await credentials(for: account, context: context)
            let imapNames = try await transport.listMailboxes(
                host: account.imapHost,
                port: Int(account.imapPort) ?? 993,
                user: account.imapUser.isEmpty ? account.email : account.imapUser,
                credentials: credentials
            )
            return MailFolders.build(from: imapNames)
        } catch {
            lastError = error.localizedDescription
            return MailFolders.fallback()
        }
    }

    private func fetchFolder(
        imapName: String,
        role: String,
        account: MailAccount,
        credentials: MailCredentials,
        context: ModelContext
    ) async throws -> Int {
        // If the local folder is empty (e.g. after a SwiftData wipe), do not trust
        // lastUID — that would search only for newer UIDs and leave Inbox blank.
        let localCount = localMessageCount(accountEmail: account.email, folder: role, context: context)
        var afterUID = 0
        if role == "INBOX", localCount > 0 {
            afterUID = account.lastUID
        } else if role == "INBOX", localCount == 0 {
            account.lastUID = 0
        }
        let (exists, envelopes, _) = try await transport.fetchLatest(
            host: account.imapHost,
            port: Int(account.imapPort) ?? 993,
            user: account.imapUser.isEmpty ? account.email : account.imapUser,
            credentials: credentials,
            folder: imapName,
            afterUID: afterUID
        )
        guard exists else { return 0 }
        var added = 0
        for env in envelopes {
            added += upsert(env, account: account, folder: role, context: context)
            if role == "INBOX", let n = Int(env.uid) {
                account.lastUID = max(account.lastUID, n)
            }
        }
        return added
    }

    private func localMessageCount(accountEmail: String, folder: String, context: ModelContext) -> Int {
        let email = accountEmail
        let role = folder
        let descriptor = FetchDescriptor<MailMessage>(predicate: #Predicate { msg in
            msg.accountEmail == email && msg.folder == role && msg.deleted == false
        })
        return (try? context.fetchCount(descriptor)) ?? 0
    }

    func verifyAndAdd(
        provider: MailProvider,
        email: String,
        password: String,
        imapUser: String,
        context: ModelContext,
        existing: [MailAccount]
    ) async throws {
        let email = email.trimmingCharacters(in: .whitespacesAndNewlines)
        let password = password.trimmingCharacters(in: .whitespacesAndNewlines)
        let user = imapUser.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? email : imapUser.trimmingCharacters(in: .whitespacesAndNewlines)
        lastError = nil
        status = "Signing In…"
        busy = true
        do {
            try await transport.verify(
                host: provider.imapHost,
                port: Int(provider.imapPort) ?? 993,
                user: user,
                credentials: .password(password)
            )
            try KeychainStore.savePassword(password, account: email)
        } catch {
            busy = false
            lastError = error.localizedDescription
            status = error.localizedDescription
            throw error
        }
        let key = email.lowercased()
        let account: MailAccount
        if let found = existing.first(where: { $0.email.lowercased() == key }) {
            account = found
        } else {
            account = MailAccount(provider: provider.id, email: email)
            context.insert(account)
        }
        account.provider = provider.id
        account.email = email
        account.imapHost = provider.imapHost
        account.imapPort = provider.imapPort
        account.smtpHost = provider.smtpHost
        account.smtpPort = provider.smtpPort
        account.smtpTLS = provider.smtpTLS
        account.imapUser = user
        account.smtpUser = email
        account.authType = "password"
        account.enabled = true
        KeychainStore.saveAccountMeta(email: email, provider: provider.id, authType: "password")
        for other in existing where other.persistentModelID != account.persistentModelID {
            other.isDefault = false
        }
        account.isDefault = true
        try context.save()
        busy = false
        status = "Signed In — Fetching Mail…"
        await sync(context: context)
    }

    func finishMicrosoft(
        email: String,
        access: String,
        refresh: String,
        expires: Date,
        context: ModelContext,
        existing: [MailAccount]
    ) async throws {
        guard let provider = MailProvider.named("microsoft") else {
            throw MailError.auth("Microsoft 365 is missing from this build.")
        }
        lastError = nil
        status = "Verifying Inbox access…"
        busy = true
        do {
            try await transport.verify(
                host: provider.imapHost,
                port: Int(provider.imapPort) ?? 993,
                user: email,
                credentials: .oauth(accessToken: access)
            )
            try MicrosoftOAuth.storeTokens(email: email, access: access, refresh: refresh, expires: expires)
        } catch {
            MicrosoftOAuth.clearTokens(email: email)
            busy = false
            lastError = Self.friendlyMailError(error)
            status = lastError ?? ""
            throw error
        }
        let key = email.lowercased()
        let account: MailAccount
        if let found = existing.first(where: { $0.email.lowercased() == key }) {
            account = found
        } else {
            account = MailAccount(provider: "microsoft", email: email)
            context.insert(account)
        }
        account.provider = "microsoft"
        account.email = email
        account.imapHost = provider.imapHost
        account.imapPort = provider.imapPort
        account.smtpHost = provider.smtpHost
        account.smtpPort = provider.smtpPort
        account.smtpTLS = provider.smtpTLS
        account.imapUser = email
        account.smtpUser = email
        account.authType = "oauth"
        account.enabled = true
        for other in existing where other.persistentModelID != account.persistentModelID {
            other.isDefault = false
        }
        account.isDefault = true
        do {
            try context.save()
        } catch {
            MicrosoftOAuth.clearTokens(email: email)
            busy = false
            throw error
        }
        busy = false
        status = "Signed in · Inbox verified · Fetching mail…"
        await sync(context: context)
    }

    func signOut(_ account: MailAccount, context: ModelContext) {
        let email = account.email
        MicrosoftOAuth.clearTokens(email: email)
        KeychainStore.deletePassword(account: email)
        KeychainStore.deletePassword(account: "account-meta:\(email)")
        let all = (try? context.fetch(FetchDescriptor<MailMessage>())) ?? []
        for msg in all where msg.accountEmail.lowercased() == email.lowercased() {
            context.delete(msg)
        }
        context.delete(account)
        try? context.save()
        lastError = nil
        status = "Signed out"
        busy = false
    }

    func markRead(_ message: MailMessage, context: ModelContext) async {
        guard !message.seen else { return }
        await toggleFlag(message, flag: "Seen", add: true, context: context)
    }

    func markUnread(_ message: MailMessage, context: ModelContext) async {
        guard message.seen else { return }
        await toggleFlag(message, flag: "Seen", add: false, context: context)
    }

    func archiveMessage(_ message: MailMessage, context: ModelContext) async {
        await relocate(message, role: .archive, context: context)
    }

    func moveMessage(_ message: MailMessage, toFolder dest: String, context: ModelContext) async {
        guard let account = account(for: message, context: context) else { return }
        do {
            let credentials = try await credentials(for: account, context: context)
            try await transport.moveUID(
                host: account.imapHost,
                port: Int(account.imapPort) ?? 993,
                user: account.imapUser.isEmpty ? account.email : account.imapUser,
                credentials: credentials,
                fromFolder: message.folder,
                uid: message.imapUID,
                destHints: [dest]
            )
            message.folder = MailFolders.role(for: dest)
            try? context.save()
        } catch {
            status = error.localizedDescription
            lastError = error.localizedDescription
        }
    }

    func listFolders(for account: MailAccount, context: ModelContext) async -> [String] {
        do {
            let credentials = try await credentials(for: account, context: context)
            return try await transport.listMailboxes(
                host: account.imapHost,
                port: Int(account.imapPort) ?? 993,
                user: account.imapUser.isEmpty ? account.email : account.imapUser,
                credentials: credentials
            )
        } catch {
            status = error.localizedDescription
            return []
        }
    }

    func toggleFlag(_ message: MailMessage, flag: String, add: Bool, context: ModelContext) async {
        guard let account = account(for: message, context: context) else { return }
        do {
            let credentials = try await credentials(for: account, context: context)
            try await transport.setFlag(
                host: account.imapHost,
                port: Int(account.imapPort) ?? 993,
                user: account.imapUser.isEmpty ? account.email : account.imapUser,
                credentials: credentials,
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

    func deleteMessage(_ message: MailMessage, context: ModelContext) async {
        await relocate(message, role: .trash, context: context)
    }

    func junkMessage(_ message: MailMessage, context: ModelContext) async {
        await relocate(message, role: .junk, context: context)
    }

    private enum RelocateRole { case trash, junk, archive }

    private func relocate(_ message: MailMessage, role: RelocateRole, context: ModelContext) async {
        guard let account = account(for: message, context: context) else { return }
        let dest: [String]
        let localFolder: String
        switch role {
        case .trash:
            dest = ["Deleted Items", "Trash", "Deleted", "[Gmail]/Trash"]
            localFolder = "TRASH"
        case .junk:
            dest = ["Junk Email", "Junk", "Spam", "Junk E-mail", "[Gmail]/Spam"]
            localFolder = "JUNK"
        case .archive:
            dest = ["Archive", "[Gmail]/All Mail", "All Mail"]
            localFolder = "ARCHIVE"
        }
        do {
            let credentials = try await credentials(for: account, context: context)
            try await transport.moveUID(
                host: account.imapHost,
                port: Int(account.imapPort) ?? 993,
                user: account.imapUser.isEmpty ? account.email : account.imapUser,
                credentials: credentials,
                fromFolder: message.folder,
                uid: message.imapUID,
                destHints: dest
            )
            message.deleted = role != .archive
            message.folder = localFolder
            try? context.save()
        } catch {
            status = error.localizedDescription
            lastError = error.localizedDescription
        }
    }

    func send(from account: MailAccount, to: [String], cc: [String] = [], subject: String, body: String, inReplyTo: String = "", references: String = "") async throws {
        let credentials = try await credentials(for: account)
        let fromHeader = account.displayName.isEmpty ? account.email : "\(account.displayName) <\(account.email)>"
        let raw = RFC822.buildRaw(from: fromHeader, to: to, cc: cc, subject: subject, body: body, inReplyTo: inReplyTo, references: references)
        try await transport.sendMail(
            host: account.smtpHost,
            port: Int(account.smtpPort) ?? 587,
            tls: account.smtpTLS,
            user: account.smtpUser.isEmpty ? account.email : account.smtpUser,
            credentials: credentials,
            from: account.email,
            to: to + cc,
            raw: raw
        )
    }

    private func credentials(for account: MailAccount, context: ModelContext? = nil) async throws -> MailCredentials {
        if account.authType == "oauth" || account.provider == "microsoft" {
            let token = try await MicrosoftOAuth.accessToken(for: account)
            try context?.save()
            return .oauth(accessToken: token)
        }
        let password = KeychainStore.load(account: account.email)
        guard !password.isEmpty else {
            throw MailError.auth("The password for \(account.email) is not saved. Sign in again.")
        }
        return .password(password)
    }

    /// Bad OAuth audience after admin_consent: drop access token, refresh once, re-sync.
    private func retryAfterIMAPAuthFailure(
        _ error: Error,
        account: MailAccount,
        context: ModelContext,
        role: String? = nil,
        imapName: String? = nil
    ) async -> Bool {
        let raw = error.localizedDescription
        guard raw == "IMAP_AUTH_REJECTED" || raw.lowercased().contains("imap_auth_rejected") else {
            return false
        }
        guard !imapAuthRetried else {
            MicrosoftOAuth.clearTokens(email: account.email)
            lastError = "Microsoft sign-in is not valid for mail. Tap Sign In and Accept again."
            needsSignIn = true
            status = lastError ?? ""
            return true
        }
        imapAuthRetried = true
        MicrosoftOAuth.clearAccessToken(email: account.email)
        do {
            _ = try await MicrosoftOAuth.accessToken(for: account, forceRefresh: true)
            if let role, let imapName {
                let credentials = try await credentials(for: account, context: context)
                let added = try await fetchFolder(
                    imapName: imapName,
                    role: role,
                    account: account,
                    credentials: credentials,
                    context: context
                )
                account.selectedFolderRole = role
                account.selectedFolderIMAP = imapName
                try context.save()
                status = added == 0 ? "Updated just now" : "Updated · \(added) new"
                lastError = nil
                needsSignIn = false
                return true
            }
            busy = false
            await syncSelectedFolder(for: account, context: context, includeInbox: true)
            return true
        } catch {
            MicrosoftOAuth.clearTokens(email: account.email)
            lastError = "Microsoft sign-in is not valid for mail. Tap Sign In and Accept again."
            needsSignIn = true
            status = lastError ?? ""
            return true
        }
    }

    private static func isReauthError(_ error: Error) -> Bool {
        let m = error.localizedDescription.lowercased()
        return m.contains("invalid_grant")
            || m.contains("sign in again")
            || m.contains("sign-in expired")
            || m.contains("imap_auth_rejected")
            || m.contains("not valid for outlook")
            || m.contains("cannot open mail")
    }

    /// Map transport codes to user-facing copy; never blame “enable IMAP” for a bad OAuth token.
    static func friendlyMailError(_ error: Error) -> String {
        let m = error.localizedDescription
        if m == "IMAP_AUTH_REJECTED" || m.lowercased().contains("imap_auth_rejected") {
            return "Microsoft sign-in is not valid for mail. Tap Sign In and Accept again."
        }
        return MicrosoftOAuth.friendlyError(m)
    }

    private func account(for message: MailMessage, context: ModelContext) -> MailAccount? {
        let email = message.accountEmail
        let all = (try? context.fetch(FetchDescriptor<MailAccount>())) ?? []
        return all.first { $0.email == email }
    }

    private func folderRole(_ name: String) -> String {
        MailFolders.role(for: name)
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
