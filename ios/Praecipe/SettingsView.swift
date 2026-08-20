import SwiftData
import SwiftUI

struct SettingsView: View {
    @Environment(\.modelContext) private var context
    @Query private var accounts: [MailAccount]
    @Query private var signatures: [MailSignature]
    @State private var provider = MailProvider.all[0]
    @State private var email = ""
    @State private var display = ""
    @State private var password = ""
    @State private var imapUser = ""
    @State private var signInError = ""
    @State private var isSigningIn = false

    var body: some View {
        Form {
            Section("Mailboxes") {
                ForEach(accounts) { a in
                    VStack(alignment: .leading) {
                        Text(a.email).font(.headline)
                        Text("\(MailProvider.named(a.provider)?.label ?? a.provider) · \(a.authType == "oauth" ? "Signed in" : "App password")")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .onDelete { idx in
                    for a in idx.map({ accounts[$0] }) {
                        KeychainStore.deletePassword(account: a.email)
                        context.delete(a)
                    }
                }
            }
            Section("Add mailbox") {
                Picker("Provider", selection: $provider) {
                    ForEach(MailProvider.all) { p in Text(p.label).tag(p) }
                }
                Text(provider.help).font(.caption).foregroundStyle(.secondary)
                if let url = provider.appPasswordURL {
                    Link("Open \(provider.label) to get a password", destination: url)
                }
                TextField("Email", text: $email).keyboardType(.emailAddress).textInputAutocapitalization(.never)
                TextField("Your name", text: $display)
                if provider.id == "icloud" {
                    TextField("IMAP user (often the part before @)", text: $imapUser).textInputAutocapitalization(.never)
                }
                SecureField("App password", text: $password)
                if !signInError.isEmpty {
                    Text(signInError)
                        .font(.caption)
                        .foregroundStyle(.red)
                }
                Button(isSigningIn ? "Signing in…" : "Test and add account") {
                    Task { await addAccount() }
                }
                .disabled(email.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || normalizedPassword.isEmpty || isSigningIn)
            }
            Section("Signature") {
                ForEach(signatures) { s in
                    SignatureEditor(signature: s)
                }
            }
            Section {
                Text("Praecipe is a practice aid, not legal advice. Deadline counting follows Fla. Fam. L. R. P. 12.090 / Rule 2.514. Confirm against the current rules, any statute, the judge’s order, and local administrative practice.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .navigationTitle("Settings")
        .onChange(of: provider.id) { _, _ in
            email = ""
            password = ""
            signInError = ""
        }
    }

    @MainActor
    private func addAccount() async {
        let cleanEmail = email.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let cleanUser = imapUser.trimmingCharacters(in: .whitespacesAndNewlines)
        let user = cleanUser.isEmpty ? cleanEmail : cleanUser
        let cleanPassword = normalizedPassword
        signInError = ""
        isSigningIn = true
        defer { isSigningIn = false }

        do {
            try await MailTransport().testIMAP(
                host: provider.imapHost,
                port: Int(provider.imapPort) ?? 993,
                user: user,
                password: cleanPassword
            )
        } catch {
            signInError = error.localizedDescription
            return
        }

        if let existing = accounts.first(where: { $0.email.caseInsensitiveCompare(cleanEmail) == .orderedSame }) {
            KeychainStore.savePassword(cleanPassword, account: existing.email)
            existing.displayName = display.trimmingCharacters(in: .whitespacesAndNewlines)
            existing.imapUser = user
            existing.enabled = true
            existing.isDefault = true
            for other in accounts where other !== existing { other.isDefault = false }
            clearAccountForm()
            return
        }

        let a = MailAccount(provider: provider.id, email: cleanEmail, displayName: display.trimmingCharacters(in: .whitespacesAndNewlines))
        a.imapHost = provider.imapHost
        a.imapPort = provider.imapPort
        a.smtpHost = provider.smtpHost
        a.smtpPort = provider.smtpPort
        a.smtpTLS = provider.smtpTLS
        a.imapUser = user
        a.smtpUser = cleanEmail
        for other in accounts { other.isDefault = false }
        a.isDefault = true
        context.insert(a)
        KeychainStore.savePassword(cleanPassword, account: cleanEmail)
        clearAccountForm()
    }

    private var normalizedPassword: String {
        password.filter { !$0.isWhitespace }
    }

    private func clearAccountForm() {
        email = ""
        password = ""
        display = ""
        imapUser = ""
        signInError = ""
    }
}

extension MailProvider: Hashable {
    static func == (lhs: MailProvider, rhs: MailProvider) -> Bool { lhs.id == rhs.id }
    func hash(into hasher: inout Hasher) { hasher.combine(id) }
}

private struct SignatureEditor: View {
    @Bindable var signature: MailSignature
    var body: some View {
        TextField("Signature", text: $signature.body, axis: .vertical)
    }
}
