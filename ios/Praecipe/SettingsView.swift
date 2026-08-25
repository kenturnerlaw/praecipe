import SwiftData
import SwiftUI
import UIKit
import WebKit

struct SettingsView: View {
    @Environment(\.modelContext) private var context
    @EnvironmentObject private var mail: MailSyncService
    @Query private var accounts: [MailAccount]
    @Query private var signatures: [MailSignature]
    @State private var adding = false

    var body: some View {
        List {
            Section {
                HStack(spacing: 12) {
                    Image("AppLogo")
                        .resizable()
                        .scaledToFit()
                        .frame(width: 40, height: 40)
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Praecipe Mail")
                            .praecipeHeadline()
                        Text("Account settings")
                            .praecipeCaption()
                            .praecipeSecondaryText()
                    }
                }
                .padding(.vertical, 2)
            }
            Section("ACCOUNTS") {
                if accounts.isEmpty {
                    Text("No accounts")
                        .praecipeSecondaryText()
                }
                ForEach(accounts) { a in
                    VStack(alignment: .leading, spacing: 8) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(a.email).praecipeBody()
                            Text(MailProvider.named(a.provider)?.label ?? a.provider)
                                .praecipeFootnote()
                                .praecipeSecondaryText()
                        }
                        Button("Sign Out", role: .destructive) {
                            mail.signOut(a, context: context)
                        }
                        .accessibilityIdentifier("signOutButton")
                    }
                }
                .onDelete { idx in
                    for a in idx.map({ accounts[$0] }) {
                        mail.signOut(a, context: context)
                    }
                }
                Button("Add Account") { adding = true }
                    .accessibilityIdentifier("addAccountButton")
            }
            Section("Signature") {
                ForEach(signatures) { s in
                    SignatureEditor(signature: s)
                }
            }
        }
        .praecipeGroupedList()
        .navigationTitle("Mail")
        .navigationBarTitleDisplayMode(.inline)
        .fullScreenCover(isPresented: $adding) {
            AddAccountSheet()
                .environmentObject(mail)
        }
    }
}

struct AddAccountSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var context
    @EnvironmentObject private var mail: MailSyncService
    @Query private var accounts: [MailAccount]
    @State private var step: Step = .pick
    @State private var provider: MailProvider?
    @State private var email = ""
    @State private var password = ""
    @State private var working = false
    @State private var verifying = false
    @State private var error = ""
    @State private var browser: MicrosoftOAuth.BrowserStart?
    @State private var connectedEmail = ""
    @State private var showConnected = false
    @State private var consumedCode = ""

    enum Step { case pick, credentials, microsoftPage }

    var body: some View {
        NavigationStack {
            ZStack {
                content
                if verifying {
                    PraecipeColors.background.opacity(0.92)
                    VStack(spacing: 12) {
                        ProgressView()
                        Text("Verifying Inbox…")
                            .praecipeHeadline()
                    }
                }
            }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(step == .microsoftPage ? "Back" : "Cancel") {
                        if step == .microsoftPage {
                            browser = nil
                            step = .credentials
                        } else {
                            dismiss()
                        }
                    }
                    .disabled(verifying)
                }
            }
            .alert("Microsoft mailbox connected", isPresented: $showConnected) {
                Button("Done") { dismiss() }
            } message: {
                Text("Praecipe signed in and verified Inbox access for \(connectedEmail).")
            }
            .alert("Cannot Sign In", isPresented: Binding(
                get: { !error.isEmpty && !verifying && step != .microsoftPage },
                set: { if !$0 { error = "" } }
            )) {
                Button("OK", role: .cancel) {}
                if provider?.id == "microsoft" {
                    Button("Try Again") { startMicrosoftSignIn() }
                }
            } message: {
                Text(error)
            }
            .onReceive(NotificationCenter.default.publisher(for: .praecipeMicrosoftOAuthURL)) { note in
                guard let url = note.object as? URL, let parsed = MicrosoftOAuth.codeFromRedirect(url) else { return }
                Task { await finishMicrosoft(parsed) }
            }
        }
        .interactiveDismissDisabled(working || verifying)
    }

    @ViewBuilder
    private var content: some View {
        if step == .pick {
            List {
                ForEach(MailProvider.all) { p in
                    Button {
                        provider = p
                        step = .credentials
                    } label: {
                        Text(p.label)
                            .praecipeBody()
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .accessibilityIdentifier("provider-\(p.id)")
                }
            }
            .praecipeGroupedList()
            .navigationTitle("Add Account")
            .navigationBarTitleDisplayMode(.inline)
        } else if let provider {
            if provider.id == "microsoft" {
                if step == .microsoftPage, let browser {
                    MicrosoftLoginWebView(startURL: browser.url) { result in
                        Task { await finishMicrosoft(result) }
                    }
                    .id(browser.verifier)
                    .ignoresSafeArea(edges: .bottom)
                    .navigationTitle("Microsoft Sign In")
                    .navigationBarTitleDisplayMode(.inline)
                    .accessibilityIdentifier("microsoftSignInPage")
                } else {
                    exchangeForm
                }
            } else {
                passwordForm(provider)
            }
        }
    }

    private var exchangeForm: some View {
        Form {
            Section {
                TextField("Email", text: $email)
                    .keyboardType(.emailAddress)
                    .textInputAutocapitalization(.never)
                    .textContentType(.username)
                    .autocorrectionDisabled()
                    .accessibilityIdentifier("microsoftEmailField")
            } footer: {
                Text("Opens Microsoft sign-in on this screen. Use password and/or Authenticator as your firm requires.")
                    .praecipeCaption()
            }
            Section {
                Button {
                    startMicrosoftSignIn()
                } label: {
                    Text("Sign In")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .disabled(email.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || verifying)
                .accessibilityIdentifier("microsoftSignInButton")
            }
        }
        .scrollContentBackground(.hidden)
        .background(PraecipeColors.background)
        .navigationTitle("Exchange")
        .navigationBarTitleDisplayMode(.inline)
    }

    @ViewBuilder
    private func passwordForm(_ provider: MailProvider) -> some View {
        Form {
            Section {
                TextField("Email", text: $email)
                    .keyboardType(.emailAddress)
                    .textInputAutocapitalization(.never)
                    .textContentType(.username)
                    .autocorrectionDisabled()
                PraecipePasswordField(text: $password)
            }
            Section {
                if working {
                    HStack {
                        ProgressView()
                        Text("Verifying")
                    }
                } else {
                    Button {
                        Task { await signInPassword(provider) }
                    } label: {
                        Text("Sign In")
                            .frame(maxWidth: .infinity)
                    }
                    .disabled(email.isEmpty || password.isEmpty)
                }
            }
        }
        .scrollContentBackground(.hidden)
        .background(PraecipeColors.background)
        .navigationTitle(provider.label)
        .navigationBarTitleDisplayMode(.inline)
    }

    /// Always show Microsoft in this cover. ASWebAuthenticationSession cannot intercept
    /// Microsoft's HTTPS nativeclient redirect (needs Associated Domains we don't have)
    /// and often presents no UI from a sheet — Sign In looks dead.
    private func startMicrosoftSignIn() {
        error = ""
        consumedCode = ""
        let hint = email.trimmingCharacters(in: .whitespacesAndNewlines)
        guard hint.contains("@") else {
            error = "Enter the work email."
            return
        }
        do {
            MicrosoftOAuth.clearTokens(email: hint.lowercased())
            browser = try MicrosoftOAuth.startBrowser(loginHint: hint)
            step = .microsoftPage
        } catch {
            self.error = error.localizedDescription
            step = .credentials
        }
    }

    private func finishMicrosoft(_ result: Result<String, Error>) async {
        switch result {
        case .failure(let err):
            error = MicrosoftOAuth.friendlyError(err.localizedDescription)
            verifying = false
            working = false
            browser = nil
            step = .credentials
        case .success(let code):
            guard consumedCode != code else { return }
            consumedCode = code
            verifying = true
            working = true
            mail.status = "Verifying"
            do {
                let tokens = try await MicrosoftOAuth.exchangeCode(
                    code: code,
                    verifier: browser?.verifier ?? "",
                    loginHint: email
                )
                try await mail.finishMicrosoft(
                    email: tokens.email,
                    access: tokens.access,
                    refresh: tokens.refresh,
                    expires: tokens.expires,
                    context: context,
                    existing: Array(accounts)
                )
                connectedEmail = tokens.email
                showConnected = true
            } catch {
                self.error = MailSyncService.friendlyMailError(error)
                mail.lastError = self.error
                browser = nil
                step = .credentials
            }
            verifying = false
            working = false
        }
    }

    private func signInPassword(_ provider: MailProvider) async {
        error = ""
        working = true
        do {
            try await mail.verifyAndAdd(
                provider: provider,
                email: email.trimmingCharacters(in: .whitespacesAndNewlines),
                password: password,
                imapUser: "",
                context: context,
                existing: Array(accounts)
            )
            dismiss()
        } catch {
            self.error = error.localizedDescription
        }
        working = false
    }
}

/// In-app Microsoft login. Intercepts nativeclient?code= and opens Authenticator (msauth) URLs.
private struct MicrosoftLoginWebView: UIViewRepresentable {
    let startURL: URL
    let onResult: (Result<String, Error>) -> Void

    func makeCoordinator() -> Coord { Coord(onResult: onResult) }

    func makeUIView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .default()
        config.defaultWebpagePreferences.allowsContentJavaScript = true
        let view = WKWebView(frame: .zero, configuration: config)
        view.navigationDelegate = context.coordinator
        view.uiDelegate = context.coordinator
        view.accessibilityIdentifier = "microsoftSignInWebView"
        context.coordinator.webView = view
        view.load(URLRequest(url: startURL))
        return view
    }

    func updateUIView(_ uiView: WKWebView, context: Context) {}

    final class Coord: NSObject, WKNavigationDelegate, WKUIDelegate {
        let onResult: (Result<String, Error>) -> Void
        private var finished = false
        weak var webView: WKWebView?
        private var oauthObserver: NSObjectProtocol?

        init(onResult: @escaping (Result<String, Error>) -> Void) {
            self.onResult = onResult
            super.init()
            oauthObserver = NotificationCenter.default.addObserver(
                forName: .praecipeMicrosoftOAuthURL,
                object: nil,
                queue: .main
            ) { [weak self] note in
                guard let self, let url = note.object as? URL else { return }
                self.handle(url, from: self.webView)
            }
        }

        deinit {
            if let oauthObserver {
                NotificationCenter.default.removeObserver(oauthObserver)
            }
        }

        func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration, for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
            if navigationAction.targetFrame == nil, let url = navigationAction.request.url {
                if handle(url, from: webView) { return nil }
                webView.load(navigationAction.request)
            }
            return nil
        }

        func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
            guard let url = navigationAction.request.url else {
                decisionHandler(.allow)
                return
            }
            if handle(url, from: webView) {
                decisionHandler(.cancel)
                return
            }
            decisionHandler(.allow)
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            if let url = webView.url {
                _ = handle(url, from: webView)
            }
        }

        func webView(_ webView: WKWebView, didReceiveServerRedirectForProvisionalNavigation navigation: WKNavigation!) {
            if let url = webView.url {
                _ = handle(url, from: webView)
            }
        }

        @discardableResult
        private func handle(_ url: URL, from webView: WKWebView?) -> Bool {
            if let parsed = MicrosoftOAuth.codeFromRedirect(url) {
                complete(parsed)
                return true
            }
            if MicrosoftOAuth.isOutgoingBrokerURL(url) {
                UIApplication.shared.open(url, options: [:], completionHandler: nil)
                return true
            }
            if (url.scheme ?? "").lowercased() == MicrosoftOAuth.appBrokerScheme, let webView {
                if let resume = resumeURL(from: url) {
                    webView.load(URLRequest(url: resume))
                    return true
                }
            }
            return false
        }

        private func resumeURL(from url: URL) -> URL? {
            let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
            for name in ["url", "redirect_uri", "resume_uri"] {
                if let raw = items.first(where: { $0.name == name })?.value,
                   let decoded = raw.removingPercentEncoding,
                   let resume = URL(string: decoded),
                   ["http", "https"].contains(resume.scheme?.lowercased() ?? "") {
                    return resume
                }
            }
            return nil
        }

        private func complete(_ parsed: Result<String, Error>) {
            guard !finished else { return }
            finished = true
            onResult(parsed)
        }
    }
}

private struct SignatureEditor: View {
    @Bindable var signature: MailSignature
    var body: some View {
        TextField("Signature", text: $signature.body, axis: .vertical)
    }
}
