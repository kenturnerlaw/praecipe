import SwiftData
import SwiftUI
import UniformTypeIdentifiers
#if PRAECIPE_ICLOUD
import CloudKit
#endif

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
    @State private var repairPasswords: [String: String] = [:]
    @State private var repairErrors: [String: String] = [:]
    @State private var repairingAccount = ""
    @State private var microsoftStatus = ""
    @State private var connectedMailbox = ""
    @State private var showMicrosoftSuccess = false
    @State private var backupURL: URL?
    @State private var showingBackupImporter = false
    @State private var pendingRestoreURL: URL?
    @State private var confirmRestore = false
    @State private var dataMessage = ""
    @State private var showDataMessage = false
    @State private var iCloudStatus = "Checking Apple account…"

    var body: some View {
        Form {
            Section("Mailboxes") {
                ForEach(accounts) { a in
                    VStack(alignment: .leading) {
                        Text(a.email).font(.headline)
                        Text(accountStatus(a))
                            .font(.caption)
                            .foregroundStyle(accountIsConnected(a) ? Color.secondary : Color.red)
                        if a.provider == "microsoft", !MicrosoftOAuth.hasSession(email: a.email) {
                            Button(isSigningIn ? "Waiting for Microsoft…" : "Sign in with Microsoft") {
                                Task { await startMicrosoftSignIn(existing: a) }
                            }.disabled(isSigningIn)
                        } else if a.provider != "microsoft", !KeychainStore.hasPassword(account: a.email) {
                            SecureField(
                                "Paste a new app password",
                                text: Binding(
                                    get: { repairPasswords[a.email, default: ""] },
                                    set: { repairPasswords[a.email] = $0 }
                                )
                            )
                            if let error = repairErrors[a.email], !error.isEmpty {
                                Text(error).font(.caption).foregroundStyle(.red)
                            }
                            Button(repairingAccount == a.email ? "Testing…" : "Repair sign in") {
                                Task { await repairAccount(a) }
                            }
                            .disabled(normalizedRepairPassword(for: a.email).isEmpty || !repairingAccount.isEmpty)
                        }
                    }
                }
                .onDelete { idx in
                    for a in idx.map({ accounts[$0] }) {
                        KeychainStore.deletePassword(account: a.email)
                        MicrosoftOAuth.signOut(email: a.email)
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
                if provider.id != "microsoft" {
                    TextField("Email", text: $email).keyboardType(.emailAddress).textInputAutocapitalization(.never)
                }
                if provider.id != "microsoft" {
                    TextField("Your name", text: $display)
                }
                if provider.id == "icloud" {
                    TextField("IMAP user (often the part before @)", text: $imapUser).textInputAutocapitalization(.never)
                }
                if provider.id != "microsoft" {
                    SecureField("App password", text: $password)
                } else {
                    Text("Microsoft uses OAuth. Your password is never given to Praecipe. After the one-time authorization, encrypted refresh credentials keep mail signed in.")
                        .font(.caption).foregroundStyle(.secondary)
                    if !microsoftStatus.isEmpty {
                        Text(microsoftStatus)
                            .font(.caption)
                            .foregroundStyle(signInError.isEmpty ? Color.secondary : Color.red)
                    }
                }
                if !signInError.isEmpty {
                    Text(signInError)
                        .font(.caption)
                        .foregroundStyle(.red)
                }
                if provider.id == "microsoft" {
                    Button(isSigningIn ? "Waiting for Microsoft…" : "Sign in with Microsoft") {
                        Task { await startMicrosoftSignIn(existing: nil) }
                    }
                    .disabled(isSigningIn)
                } else {
                    Button(isSigningIn ? "Signing in…" : "Test and add account") {
                        Task { await addAccount() }
                    }
                    .disabled(email.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || normalizedPassword.isEmpty || isSigningIn)
                }
            }
            Section("Signature") {
                ForEach(signatures) { s in
                    SignatureEditor(signature: s)
                }
            }
            Section("Billing & data protection") {
                #if PRAECIPE_ICLOUD
                LabeledContent("iCloud account", value: iCloudStatus)
                Text("Praecipe automatically syncs its database records through the private iCloud account on this device. Files copied into the matter file vault remain protected in this device's app storage and are included in practice backups; automatic file-vault upload is a separate feature.")
                    .font(.caption).foregroundStyle(.secondary)
                #else
                LabeledContent("iCloud account", value: "Not included in this build")
                #endif
                NavigationLink { LawPaySettingsView() } label: {
                    Label("LawPay", systemImage: "creditcard")
                }
                Button {
                    do {
                        backupURL = try PracticeBackupService.export(context: context)
                        dataMessage = "Backup created. Use Share Backup now to save a copy outside this iPhone."
                        showDataMessage = true
                    } catch {
                        dataMessage = error.localizedDescription
                        showDataMessage = true
                    }
                } label: { Label("Create practice backup", systemImage: "externaldrive.badge.plus") }
                if let backupURL {
                    ShareLink(item: backupURL) {
                        Label("Share Backup", systemImage: "square.and.arrow.up")
                    }
                }
                Button {
                    showingBackupImporter = true
                } label: { Label("Restore from backup", systemImage: "arrow.counterclockwise.circle") }
                Text("The backup contains matters, billing, notes, calendar, people, document files, signatures, and app settings. Mail passwords and OAuth credentials remain protected in Keychain and are never exported.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section {
                Text("Praecipe is a practice aid, not legal advice. Deadline counting follows Fla. Fam. L. R. P. 12.090 / Rule 2.514. Confirm against the current rules, any statute, the judge’s order, and local administrative practice.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .navigationTitle("Settings")
        #if PRAECIPE_ICLOUD
        .task { await refreshICloudStatus() }
        #endif
        .onChange(of: provider.id) { _, _ in
            email = ""
            password = ""
            display = ""
            imapUser = ""
            microsoftStatus = ""
            signInError = ""
        }
        .alert("Microsoft mailbox connected", isPresented: $showMicrosoftSuccess) {
            Button("Done", role: .cancel) {}
        } message: {
            Text("Praecipe signed in and opened the Inbox for \(connectedMailbox).")
        }
        .fileImporter(
            isPresented: $showingBackupImporter,
            allowedContentTypes: [UTType(filenameExtension: "praecipebackup") ?? .data],
            allowsMultipleSelection: false
        ) { result in
            switch result {
            case .success(let urls):
                pendingRestoreURL = urls.first
                confirmRestore = pendingRestoreURL != nil
            case .failure(let error):
                dataMessage = error.localizedDescription
                showDataMessage = true
            }
        }
        .confirmationDialog(
            "Replace practice data from this backup?",
            isPresented: $confirmRestore,
            titleVisibility: .visible
        ) {
            Button("Replace and restore", role: .destructive) {
                guard let pendingRestoreURL else { return }
                do {
                    try PracticeBackupService.restore(from: pendingRestoreURL, context: context)
                    dataMessage = "Practice data restored successfully."
                } catch {
                    dataMessage = "Restore failed without completing: \(error.localizedDescription)"
                }
                self.pendingRestoreURL = nil
                showDataMessage = true
            }
            Button("Cancel", role: .cancel) { pendingRestoreURL = nil }
        } message: {
            Text("This replaces the current matters, billing, notes, calendar, people, files, signatures, and settings on this device. Create a current backup first if you may need it.")
        }
        .alert("Practice data", isPresented: $showDataMessage) {
            Button("OK", role: .cancel) {}
        } message: { Text(dataMessage) }
    }

    #if PRAECIPE_ICLOUD
    @MainActor
    private func refreshICloudStatus() async {
        do {
            switch try await CKContainer(identifier: "iCloud.com.kenturnerlaw.praecipe").accountStatus() {
            case .available:
                iCloudStatus = "Signed in — records sync automatically"
            case .noAccount:
                iCloudStatus = "Sign in to iCloud in Apple Settings"
            case .restricted:
                iCloudStatus = "Restricted on this device"
            case .couldNotDetermine:
                iCloudStatus = "Could not verify — try again"
            case .temporarilyUnavailable:
                iCloudStatus = "Temporarily unavailable"
            @unknown default:
                iCloudStatus = "Unavailable"
            }
        } catch {
            iCloudStatus = "Verification failed — try again"
        }
    }
    #endif

    private func accountIsConnected(_ account: MailAccount) -> Bool {
        account.provider == "microsoft" ? MicrosoftOAuth.hasSession(email: account.email) : KeychainStore.hasPassword(account: account.email)
    }

    private func accountStatus(_ account: MailAccount) -> String {
        let providerName = MailProvider.named(account.provider)?.label ?? account.provider
        if account.provider == "microsoft" {
            return "\(providerName) · \(MicrosoftOAuth.hasSession(email: account.email) ? "OAuth connected" : "Sign in required")"
        }
        return "\(providerName) · \(KeychainStore.hasPassword(account: account.email) ? "Password saved" : "Password missing")"
    }

    @MainActor
    private func startMicrosoftSignIn(existing: MailAccount?) async {
        let expectedEmail = existing?.email.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        signInError = ""
        microsoftStatus = "Opening Microsoft sign-in…"
        isSigningIn = true
        defer { isSigningIn = false }
        do {
            let cleanEmail = try await MicrosoftOAuth.signIn(expectedEmail: expectedEmail)
            microsoftStatus = "Microsoft authorized \(cleanEmail). Verifying Inbox access…"
            let spec = MailProvider.named("microsoft")!
            let accessToken = try await MicrosoftOAuth.accessToken(email: cleanEmail)
            try await MailTransport().testIMAP(
                host: spec.imapHost,
                port: Int(spec.imapPort) ?? 993,
                user: cleanEmail,
                password: "",
                oauthToken: accessToken
            )
            let account: MailAccount
            if let found = existing ?? accounts.first(where: { $0.email.caseInsensitiveCompare(cleanEmail) == .orderedSame }) {
                account = found
            } else {
                account = MailAccount(provider: "microsoft", email: cleanEmail)
                context.insert(account)
            }
            account.provider = "microsoft"
            account.authType = "oauth"
            KeychainStore.deletePassword(account: account.email)
            account.imapHost = spec.imapHost
            account.imapPort = spec.imapPort
            account.imapUser = cleanEmail
            account.smtpHost = spec.smtpHost
            account.smtpPort = spec.smtpPort
            account.smtpUser = cleanEmail
            account.smtpTLS = spec.smtpTLS
            account.enabled = true
            for other in accounts where other !== account { other.isDefault = false }
            account.isDefault = true
            try context.save()
            clearAccountForm()
            connectedMailbox = cleanEmail
            microsoftStatus = "Signed in and Inbox verified: \(cleanEmail)"
            showMicrosoftSuccess = true
        } catch {
            signInError = error.localizedDescription
            microsoftStatus = "Microsoft sign-in failed. See the error below and try again."
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

    private func normalizedRepairPassword(for email: String) -> String {
        repairPasswords[email, default: ""].filter { !$0.isWhitespace }
    }

    @MainActor
    private func repairAccount(_ account: MailAccount) async {
        let cleanPassword = normalizedRepairPassword(for: account.email)
        repairErrors[account.email] = ""
        repairingAccount = account.email
        defer { repairingAccount = "" }
        do {
            try await MailTransport().testIMAP(
                host: account.imapHost,
                port: Int(account.imapPort) ?? 993,
                user: account.imapUser.isEmpty ? account.email : account.imapUser,
                password: cleanPassword
            )
            KeychainStore.savePassword(cleanPassword, account: account.email)
            account.authType = "password"
            account.enabled = true
            repairPasswords.removeValue(forKey: account.email)
            repairErrors.removeValue(forKey: account.email)
        } catch {
            repairErrors[account.email] = error.localizedDescription
        }
    }

    private func clearAccountForm() {
        email = ""
        password = ""
        display = ""
        imapUser = ""
        signInError = ""
    }
}

private struct LawPaySettingsView: View {
    @Environment(\.openURL) private var openURL
    @State private var serverURL = LawPayConfiguration.serverURL
    @State private var apiToken = LawPayConfiguration.apiToken
    @State private var status: LawPayConnectionStatus?
    @State private var selectedBankAccountID = ""
    @State private var busy = false
    @State private var message = ""

    var body: some View {
        Form {
            Section("Secure billing server") {
                TextField("https://billing.example.com", text: $serverURL)
                    .textInputAutocapitalization(.never).keyboardType(.URL)
                SecureField("Praecipe server API token", text: $apiToken)
                Button(busy ? "Checking…" : "Save and verify") { Task { await saveAndRefresh() } }
                    .disabled(busy || serverURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                Text("Praecipe sends invoice details to your HTTPS server. LawPay's OAuth secret and access token stay on that server and never enter this iPhone app.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("LawPay connection") {
                LabeledContent("Partner application", value: status?.configured == true ? "Configured" : "Required")
                LabeledContent("LawPay account", value: status?.connected == true ? "Connected" : "Not connected")
                if status?.configured == true, status?.connected != true {
                    Button("Connect with LawPay") { Task { await connect() } }.disabled(busy)
                }
                if status?.connected == true {
                    Button("Refresh LawPay status") { Task { await refresh() } }.disabled(busy)
                }
            }
            if let accounts = status?.bankAccounts, !accounts.isEmpty {
                Section("Invoice deposit account") {
                    Picker("Account", selection: $selectedBankAccountID) {
                        Text("Choose account").tag("")
                        ForEach(accounts) { account in
                            Text(accountLabel(account)).tag(account.id)
                        }
                    }
                    Button("Use selected account") { Task { await selectAccount() } }
                        .disabled(busy || selectedBankAccountID.isEmpty)
                    Text("Trust and operating accounts are identified explicitly. Confirm the correct destination before sending a live invoice.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            if !message.isEmpty {
                Section { Text(message).foregroundStyle(message.lowercased().contains("failed") || message.lowercased().contains("required") ? Color.red : Color.secondary) }
            }
        }
        .navigationTitle("LawPay")
        .task { if !serverURL.isEmpty { await refresh() } }
    }

    private func accountLabel(_ account: LawPayBankAccount) -> String {
        let kind = account.trust ? "Trust" : "Operating"
        let mode = account.testMode ? " · TEST" : ""
        return "\(account.name) · \(kind) \(account.maskedAccount)\(mode)"
    }

    @MainActor
    private func saveAndRefresh() async {
        LawPayConfiguration.serverURL = serverURL
        LawPayConfiguration.apiToken = apiToken
        await refresh()
    }

    @MainActor
    private func refresh() async {
        busy = true; message = ""
        defer { busy = false }
        do {
            status = try await LawPaySyncService().connectionStatus()
            selectedBankAccountID = status?.selectedBankAccountID ?? ""
            if status?.configured != true {
                message = "An approved LawPay partner OAuth application is required on the billing server."
            } else if status?.connected == true {
                message = "LawPay connection verified."
            } else {
                message = "Partner application configured. Connect the LawPay merchant account."
            }
        } catch {
            status = nil
            message = "Verification failed: \(error.localizedDescription)"
        }
    }

    @MainActor
    private func connect() async {
        busy = true; message = ""
        defer { busy = false }
        do {
            let url = try await LawPaySyncService().authorizationURL()
            openURL(url)
            message = "Finish authorization in LawPay, then return here and tap Refresh LawPay status."
        } catch {
            message = "LawPay connection failed: \(error.localizedDescription)"
        }
    }

    @MainActor
    private func selectAccount() async {
        busy = true; message = ""
        defer { busy = false }
        do {
            status = try await LawPaySyncService().selectBankAccount(selectedBankAccountID)
            message = "LawPay deposit account saved and verified."
        } catch {
            message = "Account selection failed: \(error.localizedDescription)"
        }
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
