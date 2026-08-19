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
                Button("Add account") { addAccount() }
                    .disabled(email.isEmpty || password.isEmpty)
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
        }
    }

    private func addAccount() {
        let a = MailAccount(provider: provider.id, email: email, displayName: display)
        a.imapHost = provider.imapHost
        a.imapPort = provider.imapPort
        a.smtpHost = provider.smtpHost
        a.smtpPort = provider.smtpPort
        a.smtpTLS = provider.smtpTLS
        a.imapUser = imapUser.isEmpty ? email : imapUser
        a.smtpUser = email
        a.isDefault = accounts.isEmpty
        for other in accounts { other.isDefault = false }
        a.isDefault = true
        context.insert(a)
        KeychainStore.savePassword(password, account: email)
        email = ""
        password = ""
        display = ""
        imapUser = ""
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
