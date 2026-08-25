import AuthenticationServices
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
                    VStack(alignment: .leading, spacing: 2) {
                        Text(a.email).praecipeBody()
                        Text(MailProvider.named(a.provider)?.label ?? a.provider)
                            .praecipeFootnote()
                            .praecipeSecondaryText()
                    }
                }
                .onDelete { idx in
                    for a in idx.map({ accounts[$0] }) {
                        KeychainStore.deletePassword(account: a.email)
                        KeychainStore.deletePassword(account: "oauth-access:\(a.email)")
                        KeychainStore.deletePassword(account: "oauth-refresh:\(a.email)")
                        KeychainStore.deletePassword(account: "oauth-expires:\(a.email)")
                        context.delete(a)
                    }
                }
                Button("Add Account") { adding = true }
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
        .sheet(isPresented: $adding) {
            AddAccountSheet()
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
    @State private var consentRetries = 0
    @State private var authSession: MicrosoftAuthSessionController?
    @State private var useEmbeddedLogin = false

    enum Step { case pick, credentials, microsoftPage }

    var body: some View {
        NavigationStack {
            ZStack {
                content
                if verifying {
                    PraecipeColors.background.opacity(0.92)
                    VStack(spacing: 12) {
                        ProgressView()
                        Text("Verifying")
                            .praecipeHeadline()
                    }
                }
            }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                        .disabled(verifying)
                }
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
                    .id(browser.url.absoluteString + "-\(browser.verifier.prefix(8))")
                    .ignoresSafeArea(edges: .bottom)
                    .navigationTitle("Microsoft Sign In")
                    .navigationBarTitleDisplayMode(.inline)
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
            } footer: {
                Text("Opens Microsoft sign-in. Use password and/or Authenticator as your firm requires.")
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
            }
        }
        .scrollContentBackground(.hidden)
        .background(PraecipeColors.background)
        .navigationTitle("Exchange")
        .navigationBarTitleDisplayMode(.inline)
        .alert("Cannot Sign In", isPresented: Binding(
            get: { !error.isEmpty && !verifying },
            set: { if !$0 { error = "" } }
        )) {
            Button("OK", role: .cancel) {}
            Button("Try Again") { startMicrosoftSignIn() }
        } message: {
            Text(error)
        }
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
        .alert("Cannot Sign In", isPresented: Binding(
            get: { !error.isEmpty && !working },
            set: { if !$0 { error = "" } }
        )) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(error)
        }
    }

    private func startMicrosoftSignIn(prompt: String? = nil) {
        error = ""
        let hint = email.trimmingCharacters(in: .whitespacesAndNewlines)
        guard hint.contains("@") else {
            error = "Enter the work email."
            return
        }
        do {
            // Always push an in-app Microsoft page from this sheet.
            // ASWebAuthenticationSession often "starts" with no UI when launched from a nested sheet
            // (Sign In looks dead). WebView + msauth handoff is the reliable path here.
            let start = try MicrosoftOAuth.startBrowser(loginHint: hint, prompt: prompt)
            browser = start
            useEmbeddedLogin = true
            step = .microsoftPage
        } catch {
            self.error = error.localizedDescription
            step = .credentials
        }
    }

    private func finishMicrosoft(_ result: Result<String, Error>) async {
        switch result {
        case .failure(let err):
            let ns = err as NSError
            let raw = err.localizedDescription
            if ns.domain == ASWebAuthenticationSessionError.errorDomain,
               ns.code == ASWebAuthenticationSessionError.canceledLogin.rawValue {
                verifying = false
                working = false
                error = ""
                step = .credentials
                useEmbeddedLogin = false
                return
            }
            if raw.lowercased().contains("cancel") {
                verifying = false
                working = false
                error = ""
                step = .credentials
                useEmbeddedLogin = false
                return
            }
            if raw.contains("ADMIN_CONSENT_ONLY") {
                browser = nil
                useEmbeddedLogin = false
                step = .credentials
                startMicrosoftSignIn(prompt: "login")
                return
            }
            if MicrosoftOAuth.isAdminConsentError(raw), consentRetries < 1 {
                consentRetries += 1
                browser = nil
                useEmbeddedLogin = false
                step = .credentials
                startMicrosoftSignIn(prompt: "admin_consent")
                return
            }
            error = MicrosoftOAuth.friendlyError(raw)
            verifying = false
            working = false
            step = .credentials
            useEmbeddedLogin = false
        case .success(let code):
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
                dismiss()
            } catch {
                let msg = error.localizedDescription
                if MicrosoftOAuth.isAdminConsentError(msg), consentRetries < 1 {
                    consentRetries += 1
                    browser = nil
                    verifying = false
                    working = false
                    useEmbeddedLogin = false
                    step = .credentials
                    startMicrosoftSignIn(prompt: "admin_consent")
                    return
                }
                self.error = MailSyncService.friendlyMailError(error)
                mail.lastError = self.error
                step = .credentials
                useEmbeddedLogin = false
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

/// System auth sheet. Returns false if iOS refuses to present (caller falls back to WebView).
@MainActor
final class MicrosoftAuthSessionController: NSObject, ASWebAuthenticationPresentationContextProviding {
    private var session: ASWebAuthenticationSession?

    @discardableResult
    func start(url: URL, completion: @escaping (Result<String, Error>) -> Void) -> Bool {
        session?.cancel()
        let handler: ASWebAuthenticationSession.CompletionHandler = { callbackURL, error in
            if let error {
                completion(.failure(error))
                return
            }
            guard let callbackURL else {
                completion(.failure(MailError.auth("Microsoft did not return a sign-in code.")))
                return
            }
            guard let parsed = MicrosoftOAuth.codeFromRedirect(callbackURL) else {
                completion(.failure(MailError.auth("Microsoft did not return a sign-in code.")))
                return
            }
            completion(parsed)
        }
        let session: ASWebAuthenticationSession
        if #available(iOS 17.4, *) {
            session = ASWebAuthenticationSession(
                url: url,
                callback: .https(host: "login.microsoftonline.com", path: "/common/oauth2/nativeclient"),
                completionHandler: handler
            )
        } else {
            session = ASWebAuthenticationSession(
                url: url,
                callbackURLScheme: "https",
                completionHandler: handler
            )
        }
        session.prefersEphemeralWebBrowserSession = false
        session.presentationContextProvider = self
        self.session = session
        return session.start()
    }

    func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        let windows = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap(\.windows)
            .filter { !$0.isHidden && $0.alpha > 0.01 }
        if let key = windows.first(where: \.isKeyWindow) { return key }
        if let front = windows.max(by: { $0.windowLevel.rawValue < $1.windowLevel.rawValue }) { return front }
        return windows.first ?? ASPresentationAnchor()
    }
}

/// Fallback when ASWebAuthenticationSession will not present from a sheet.
/// Forwards Authenticator (`msauth`) URLs to the system; never scrapes page text for false errors.
private struct MicrosoftLoginWebView: UIViewRepresentable {
    let startURL: URL
    let onResult: (Result<String, Error>) -> Void

    func makeCoordinator() -> Coord { Coord(onResult: onResult) }

    func makeUIView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.defaultWebpagePreferences.allowsContentJavaScript = true
        let view = WKWebView(frame: .zero, configuration: config)
        view.navigationDelegate = context.coordinator
        view.load(URLRequest(url: startURL))
        return view
    }

    func updateUIView(_ uiView: WKWebView, context: Context) {}

    final class Coord: NSObject, WKNavigationDelegate {
        let onResult: (Result<String, Error>) -> Void
        private var finished = false

        init(onResult: @escaping (Result<String, Error>) -> Void) {
            self.onResult = onResult
        }

        func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
            guard let url = navigationAction.request.url else {
                decisionHandler(.allow)
                return
            }
            if let parsed = MicrosoftOAuth.codeFromRedirect(url) {
                decisionHandler(.cancel)
                guard !finished else { return }
                finished = true
                onResult(parsed)
                return
            }
            let scheme = (url.scheme ?? "").lowercased()
            // Hand Authenticator / broker URLs to iOS (WKWebView cannot complete MFA alone).
            if scheme.hasPrefix("msauth") || scheme == "microsoft-authenticator" || scheme == "companyportal" {
                UIApplication.shared.open(url, options: [:]) { ok in
                    if !ok, !self.finished {
                        self.finished = true
                        self.onResult(.failure(MailError.auth("Could not open Microsoft Authenticator. Install or unlock it, then try Sign In again.")))
                    }
                }
                decisionHandler(.cancel)
                return
            }
            decisionHandler(.allow)
        }
    }
}

private struct SignatureEditor: View {
    @Bindable var signature: MailSignature
    var body: some View {
        TextField("Signature", text: $signature.body, axis: .vertical)
    }
}
