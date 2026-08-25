import CryptoKit
import Foundation
import SwiftData

enum MicrosoftOAuth {
    /// Kenneth’s work tenant.
    static let tenantID = "eedeccaf-01c1-4439-a88b-88e587be9f1c"
    /// Praecipe's registered public-client application in Kenneth's Entra tenant.
    static let clientID = "1f0ced9a-277d-46b6-be8b-7728315eb595"
    static let tokenURL = URL(string: "https://login.microsoftonline.com/\(tenantID)/oauth2/v2.0/token")!
    static let deviceURL = URL(string: "https://login.microsoftonline.com/\(tenantID)/oauth2/v2.0/devicecode")!
    static let authorizeURL = URL(string: "https://login.microsoftonline.com/\(tenantID)/oauth2/v2.0/authorize")!
    static let redirectURI = "https://login.microsoftonline.com/common/oauth2/nativeclient"
    static let scopes = "offline_access https://outlook.office.com/IMAP.AccessAsUser.All https://outlook.office.com/SMTP.Send"
    private static let consentFlagKey = "ms-consent-granted"
    private static let legacyClientSettingKey = "microsoft_oauth_client_id"

    struct BrowserStart {
        var url: URL
        var verifier: String
    }

    struct DeviceStart {
        var userCode: String
        var deviceCode: String
        var verifyURL: URL
        var interval: Int
    }

    static func isClientID(_ value: String) -> Bool {
        let v = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard v.count == 36 else { return false }
        let parts = v.split(separator: "-", omittingEmptySubsequences: false)
        guard parts.count == 5 else { return false }
        let lengths = [8, 4, 4, 4, 12]
        let hex = CharacterSet(charactersIn: "0123456789abcdefABCDEF")
        for (p, n) in zip(parts, lengths) {
            if p.count != n { return false }
            if p.unicodeScalars.contains(where: { !hex.contains($0) }) { return false }
        }
        return true
    }

    static func resolvedClientID(in context: ModelContext? = nil) -> String {
        _ = context
        return clientID
    }

    static func requireClientID(in context: ModelContext? = nil) throws -> String {
        resolvedClientID(in: context)
    }

    static func hasRefreshSession(email: String = "") -> Bool {
        if !email.isEmpty, !KeychainStore.load(account: "oauth-refresh:\(email.lowercased())").isEmpty {
            return true
        }
        return !storedOAuthEmails().isEmpty && KeychainStore.load(account: consentFlagKey) == "1"
    }

    static func markConsentGranted() {
        try? KeychainStore.savePassword("1", account: consentFlagKey)
    }

    static func isAdminConsentError(_ message: String) -> Bool {
        let lower = message.lowercased()
        return lower.contains("aadsts65001")
            || lower.contains("consent_required")
            || lower.contains("need admin approval")
            || lower.contains("approval_required")
            || (lower.contains("access_denied") && lower.contains("consent"))
    }

    static func friendlyError(_ message: String) -> String {
        let m = message
            .replacingOccurrences(of: "+", with: " ")
            .removingPercentEncoding ?? message
        let lower = m.lowercased()
        if lower.contains("aadsts50011") || lower.contains("redirect_uri") {
            return "Microsoft rejected Praecipe's return address. The Entra app must include https://login.microsoftonline.com/common/oauth2/nativeclient as a Mobile and desktop redirect URI."
        }
        if isAdminConsentError(m) {
            return "Microsoft has not granted Praecipe permission to use Outlook mail. Grant the configured IMAP and SMTP permissions in Entra, then sign in again."
        }
        if lower.contains("aadsts700016") || lower.contains("invalid_client") {
            return "Microsoft could not find Praecipe's Entra app registration (1f0ced9a-277d-46b6-be8b-7728315eb595) in this tenant."
        }
        if lower.contains("invalid_grant") {
            return "Microsoft sign-in expired. Sign in again."
        }
        if m.count > 180 { return "Couldn’t complete Microsoft sign-in. Tap Sign In to try again." }
        return m
    }

    /// Drop junk values like “ken” so they cannot become client_id. Never deletes tokens.
    static func discardJunkStoredClientIDs(_ context: ModelContext) {
        let stored = UserDefaults.standard.string(forKey: legacyClientSettingKey) ?? ""
        if !stored.isEmpty, !isClientID(stored) {
            UserDefaults.standard.removeObject(forKey: legacyClientSettingKey)
        }
        let all = (try? context.fetch(FetchDescriptor<AppSetting>())) ?? []
        for row in all where row.key == legacyClientSettingKey && !isClientID(row.value) {
            context.delete(row)
        }
        try? context.save()
    }

    static func startBrowser(clientID: String = MicrosoftOAuth.clientID, loginHint: String = "", prompt: String? = nil) throws -> BrowserStart {
        guard isClientID(clientID) else {
            throw MailError.auth("Microsoft sign-in is misconfigured.")
        }
        let hint = loginHint.trimmingCharacters(in: .whitespacesAndNewlines)
        let hasToken = !hint.isEmpty && !KeychainStore.load(account: "oauth-refresh:\(hint.lowercased())").isEmpty
        // Known break: prompt=admin_consent first → Authenticator/MFA then no mailbox token.
        // Known break: ASWebAuthenticationSession cannot intercept HTTPS nativeclient (no Associated Domains).
        // Sign-in is WKWebView in a full-screen cover; Authenticator returns via msauth.com.kenturnerlaw.praecipe.
        let promptValue: String?
        if let prompt, !prompt.isEmpty {
            promptValue = prompt
        } else if hasToken {
            promptValue = "select_account"
        } else {
            promptValue = nil
        }
        let verifier = pkceVerifier()
        let challenge = pkceChallenge(verifier)
        var items = [
            URLQueryItem(name: "client_id", value: clientID),
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "redirect_uri", value: redirectURI),
            URLQueryItem(name: "response_mode", value: "query"),
            URLQueryItem(name: "scope", value: scopes),
            URLQueryItem(name: "code_challenge", value: challenge),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
        ]
        if let promptValue {
            items.append(URLQueryItem(name: "prompt", value: promptValue))
        }
        if !hint.isEmpty {
            items.append(URLQueryItem(name: "login_hint", value: hint))
            // domain_hint must be the email domain (e.g. contoso.com), NEVER the tenant GUID.
            if let at = hint.firstIndex(of: "@") {
                let domain = String(hint[hint.index(after: at)...])
                if domain.contains(".") {
                    items.append(URLQueryItem(name: "domain_hint", value: domain))
                }
            }
        }
        var comp = URLComponents(url: authorizeURL, resolvingAgainstBaseURL: false)!
        comp.queryItems = items
        guard let url = comp.url else { throw MailError.auth("Could not start Microsoft sign-in.") }
        return BrowserStart(url: url, verifier: verifier)
    }

    static func exchangeCode(clientID: String = MicrosoftOAuth.clientID, code: String, verifier: String, loginHint: String = "") async throws -> (email: String, access: String, refresh: String, expires: Date) {
        guard isClientID(clientID) else {
            throw MailError.auth("Microsoft sign-in is misconfigured.")
        }
        let json = try await post(tokenURL, body: form([
            "grant_type": "authorization_code",
            "client_id": clientID,
            "code": code,
            "redirect_uri": redirectURI,
            "code_verifier": verifier,
            "scope": scopes,
        ]))
        return try tokens(from: json, loginHint: loginHint)
    }

    /// Redirect after `prompt=admin_consent` often has `admin_consent=True` and **no** auth code.
    enum RedirectOutcome {
        case code(String)
        case adminConsentOnly
        case failure(Error)
    }

    static let appBrokerScheme = "msauth.com.kenturnerlaw.praecipe"

    static func isOutgoingBrokerURL(_ url: URL) -> Bool {
        let scheme = (url.scheme ?? "").lowercased()
        if scheme == appBrokerScheme { return false }
        return scheme.hasPrefix("msauth")
            || scheme == "microsoft-authenticator"
            || scheme == "companyportal"
    }

    static func isOAuthCallback(_ url: URL) -> Bool {
        let abs = url.absoluteString.lowercased()
        if abs.hasPrefix(redirectURI.lowercased()) { return true }
        return (url.scheme ?? "").lowercased() == appBrokerScheme
    }

    static func outcomeFromRedirect(_ url: URL) -> RedirectOutcome? {
        guard isOAuthCallback(url) else { return nil }
        var items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        if items.isEmpty, let fragment = url.fragment, !fragment.isEmpty {
            items = URLComponents(string: "https://x.invalid?\(fragment)")?.queryItems ?? []
        }
        // Authenticator may resume the app without a code yet — don't abort the web view.
        let scheme = (url.scheme ?? "").lowercased()
        if scheme == appBrokerScheme,
           items.first(where: { $0.name == "code" })?.value?.isEmpty != false,
           items.first(where: { $0.name == "error" }) == nil {
            return nil
        }
        if let err = items.first(where: { $0.name == "error" })?.value {
            let desc = items.first(where: { $0.name == "error_description" })?.value ?? err
            return .failure(MailError.auth(friendlyError(desc)))
        }
        if let code = items.first(where: { $0.name == "code" })?.value, !code.isEmpty {
            return .code(code)
        }
        let admin = (items.first(where: { $0.name == "admin_consent" })?.value ?? "").lowercased()
        if admin == "true" || admin == "True" {
            return .adminConsentOnly
        }
        return .failure(MailError.auth("Microsoft did not return a sign-in code."))
    }

    static func codeFromRedirect(_ url: URL) -> Result<String, Error>? {
        switch outcomeFromRedirect(url) {
        case .none: return nil
        case .code(let c): return .success(c)
        case .adminConsentOnly:
            return .failure(MailError.auth("Microsoft recorded admin consent but did not issue a mailbox code. Tap Sign In again."))
        case .failure(let e): return .failure(e)
        }
    }

    static func startDevice(clientID: String = MicrosoftOAuth.clientID) async throws -> DeviceStart {
        guard isClientID(clientID) else {
            throw MailError.auth("Microsoft sign-in is misconfigured.")
        }
        let json = try await post(deviceURL, body: form(["client_id": clientID, "scope": scopes]))
        if let err = json["error"] as? String {
            throw MailError.auth(friendlyError((json["error_description"] as? String) ?? err))
        }
        let user = json["user_code"] as? String ?? ""
        let device = json["device_code"] as? String ?? ""
        let uri = json["verification_uri_complete"] as? String
            ?? "https://login.microsoft.com/device?otc=\(user.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? user)"
        guard !user.isEmpty, !device.isEmpty, let url = URL(string: uri) else {
            throw MailError.auth("Microsoft did not start sign-in.")
        }
        return DeviceStart(userCode: user, deviceCode: device, verifyURL: url, interval: max(5, jsonInt(json, "interval", 5)))
    }

    static func poll(clientID: String = MicrosoftOAuth.clientID, deviceCode: String, interval: Int) async throws -> (email: String, access: String, refresh: String, expires: Date) {
        let deadline = Date().addingTimeInterval(900)
        var wait = UInt64(interval) * 1_000_000_000
        while Date() < deadline {
            try await Task.sleep(nanoseconds: wait)
            guard isClientID(clientID) else {
                throw MailError.auth("Microsoft sign-in is misconfigured.")
            }
            let json = try await post(tokenURL, body: form([
                "grant_type": "urn:ietf:params:oauth:grant-type:device_code",
                "client_id": clientID,
                "device_code": deviceCode,
            ]))
            let err = json["error"] as? String ?? ""
            if err == "authorization_pending" { continue }
            if err == "slow_down" {
                wait += 5_000_000_000
                continue
            }
            if !err.isEmpty {
                throw MailError.auth(friendlyError((json["error_description"] as? String) ?? err))
            }
            return try tokens(from: json, loginHint: "")
        }
        throw MailError.auth("Microsoft sign-in timed out. Start again.")
    }

    static func hasStoredSession(email: String) -> Bool {
        !KeychainStore.load(account: "oauth-refresh:\(email)").isEmpty
            || !KeychainStore.load(account: "oauth-access:\(email)").isEmpty
    }

    static func storedOAuthEmails() -> [String] {
        KeychainStore.allAccountKeys().compactMap { key in
            if key.hasPrefix("oauth-refresh:") {
                return String(key.dropFirst("oauth-refresh:".count))
            }
            return nil
        }
    }

    /// Recreate MailAccount rows from Keychain after a store reset so launch stays signed in.
    static func restoreAccounts(into context: ModelContext) {
        let existing = (try? context.fetch(FetchDescriptor<MailAccount>())) ?? []
        var have = Set(existing.map { $0.email.lowercased() })
        var restored: [MailAccount] = existing

        func insertMicrosoft(_ email: String) {
            let key = email.lowercased()
            guard !have.contains(key), key.contains("@") else { return }
            guard let provider = MailProvider.named("microsoft") else { return }
            let account = MailAccount(provider: "microsoft", email: key)
            account.imapHost = provider.imapHost
            account.imapPort = provider.imapPort
            account.smtpHost = provider.smtpHost
            account.smtpPort = provider.smtpPort
            account.smtpTLS = provider.smtpTLS
            account.imapUser = key
            account.smtpUser = key
            account.authType = "oauth"
            account.enabled = true
            account.isDefault = restored.isEmpty
            account.selectedFolderRole = "INBOX"
            account.selectedFolderIMAP = "INBOX"
            context.insert(account)
            restored.append(account)
            have.insert(key)
            KeychainStore.saveAccountMeta(email: key, provider: "microsoft", authType: "oauth")
        }

        for email in storedOAuthEmails() {
            insertMicrosoft(email)
        }

        for key in KeychainStore.allAccountKeys() where key.hasPrefix("account-meta:") {
            let email = String(key.dropFirst("account-meta:".count)).lowercased()
            guard !have.contains(email), email.contains("@") else { continue }
            guard let meta = KeychainStore.loadAccountMeta(email: email),
                  let provider = MailProvider.named(meta.provider) else { continue }
            if meta.authType == "oauth" {
                insertMicrosoft(email)
                continue
            }
            guard !KeychainStore.load(account: email).isEmpty else { continue }
            let account = MailAccount(provider: provider.id, email: email)
            account.imapHost = provider.imapHost
            account.imapPort = provider.imapPort
            account.smtpHost = provider.smtpHost
            account.smtpPort = provider.smtpPort
            account.smtpTLS = provider.smtpTLS
            account.imapUser = email
            account.smtpUser = email
            account.authType = "password"
            account.enabled = true
            account.isDefault = restored.isEmpty
            account.selectedFolderRole = "INBOX"
            account.selectedFolderIMAP = "INBOX"
            context.insert(account)
            restored.append(account)
            have.insert(email)
        }

        if restored.filter(\.isDefault).count != 1, let first = restored.first {
            for a in restored { a.isDefault = (a.persistentModelID == first.persistentModelID) }
            first.isDefault = true
        }
        try? context.save()
    }

    static func accessToken(for account: MailAccount, clientID: String = MicrosoftOAuth.clientID, forceRefresh: Bool = false) async throws -> String {
        let cached = KeychainStore.load(account: "oauth-access:\(account.email)")
        let expires = tokenExpiresAt(email: account.email)
        if !forceRefresh, !cached.isEmpty, expires > Date().timeIntervalSince1970 + 45, !isClearlyGraphOnlyToken(cached) {
            return cached
        }
        let refresh = KeychainStore.load(account: "oauth-refresh:\(account.email)")
        guard !refresh.isEmpty else {
            clearAccessToken(email: account.email)
            throw MailError.auth("Sign in again to continue mail.")
        }
        guard isClientID(clientID) else {
            throw MailError.auth("Microsoft sign-in is misconfigured.")
        }
        let json = try await post(tokenURL, body: form([
            "grant_type": "refresh_token",
            "client_id": clientID,
            "refresh_token": refresh,
            "scope": scopes,
        ]))
        if let err = json["error"] as? String {
            if err == "invalid_grant" {
                clearTokens(email: account.email)
            }
            throw MailError.auth(friendlyError((json["error_description"] as? String) ?? err))
        }
        let access = json["access_token"] as? String ?? ""
        let newRefresh = json["refresh_token"] as? String ?? refresh
        let seconds = Double(jsonInt(json, "expires_in", 3600))
        guard !access.isEmpty else {
            throw MailError.auth("Microsoft did not refresh the sign-in.")
        }
        try storeTokens(
            email: account.email,
            access: access,
            refresh: newRefresh,
            expires: Date().addingTimeInterval(seconds - 60)
        )
        return access
    }

    static func storeTokens(email: String, access: String, refresh: String, expires: Date) throws {
        // Never block sign-in on JWT parsing — many Microsoft tokens are encrypted/opaque.
        try KeychainStore.savePassword(access, account: "oauth-access:\(email)")
        try KeychainStore.savePassword(refresh, account: "oauth-refresh:\(email)")
        try KeychainStore.savePassword(String(expires.timeIntervalSince1970), account: "oauth-expires:\(email)")
        markConsentGranted()
        KeychainStore.saveAccountMeta(email: email, provider: "microsoft", authType: "oauth")
    }

    static func clearAccessToken(email: String) {
        KeychainStore.deletePassword(account: "oauth-access:\(email)")
        KeychainStore.deletePassword(account: "oauth-expires:\(email)")
    }

    static func clearTokens(email: String) {
        clearAccessToken(email: email)
        KeychainStore.deletePassword(account: "oauth-refresh:\(email)")
    }

    /// Only reject tokens we can prove are Graph-only (those cannot open IMAP).
    static func isClearlyGraphOnlyToken(_ access: String) -> Bool {
        let claims = jwtClaims(access)
        guard !claims.isEmpty else { return false }
        let audValues: [String]
        if let s = claims["aud"] as? String {
            audValues = [s]
        } else if let a = claims["aud"] as? [String] {
            audValues = a
        } else {
            return false
        }
        let isGraph = audValues.contains { $0.lowercased().contains("graph.microsoft.com") }
        guard isGraph else { return false }
        let scp = ((claims["scp"] as? String) ?? "").lowercased()
        return !scp.contains("imap")
    }

    static func jwtClaims(_ token: String) -> [String: Any] {
        let parts = token.split(separator: ".")
        guard parts.count >= 2 else { return [:] }
        var payload = String(parts[1])
        let pad = String(repeating: "=", count: (4 - payload.count % 4) % 4)
        payload += pad
        guard let data = Data(base64Encoded: payload.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [:] }
        return obj
    }

    static func tokenExpiresAt(email: String) -> Double {
        Double(KeychainStore.load(account: "oauth-expires:\(email)")) ?? 0
    }

    static func xoauth2(user: String, token: String) -> String {
        let raw = "user=\(user)\u{1}auth=Bearer \(token)\u{1}\u{1}"
        return Data(raw.utf8).base64EncodedString()
    }

    static func imapAuthenticateCommand(user: String, token: String) -> String {
        "AUTHENTICATE XOAUTH2 \(xoauth2(user: user, token: token))"
    }

    static func emailFromJWT(_ token: String) -> String {
        let parts = token.split(separator: ".")
        guard parts.count >= 2 else { return "" }
        var payload = String(parts[1])
        let pad = String(repeating: "=", count: (4 - payload.count % 4) % 4)
        payload += pad
        guard let data = Data(base64Encoded: payload.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return "" }
        return (obj["preferred_username"] as? String)
            ?? (obj["upn"] as? String)
            ?? (obj["unique_name"] as? String)
            ?? (obj["email"] as? String)
            ?? ""
    }

    private static func tokens(from json: [String: Any], loginHint: String = "") throws -> (email: String, access: String, refresh: String, expires: Date) {
        if let err = json["error"] as? String {
            throw MailError.auth(friendlyError((json["error_description"] as? String) ?? err))
        }
        let access = json["access_token"] as? String ?? ""
        let refresh = json["refresh_token"] as? String ?? ""
        let seconds = Double(jsonInt(json, "expires_in", 3600))
        guard !access.isEmpty, !refresh.isEmpty else {
            throw MailError.auth("Microsoft signed in but did not return a refresh token.")
        }
        let hint = loginHint.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        var email = emailFromJWT(access).lowercased()
        if email.isEmpty, hint.contains("@") {
            email = hint
        }
        guard !email.isEmpty else {
            throw MailError.auth("Could not read the work email from Microsoft.")
        }
        return (email, access, refresh, Date().addingTimeInterval(seconds - 60))
    }

    private static func pkceVerifier() -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        return Data(bytes).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    private static func pkceChallenge(_ verifier: String) -> String {
        let hash = SHA256.hash(data: Data(verifier.utf8))
        return Data(hash).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    private static func jsonInt(_ json: [String: Any], _ key: String, _ fallback: Int) -> Int {
        if let i = json[key] as? Int { return i }
        if let d = json[key] as? Double { return Int(d) }
        if let n = json[key] as? NSNumber { return n.intValue }
        return fallback
    }

    static func form(_ fields: [String: String]) -> Data {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        return fields.map { key, value in
            let k = key.addingPercentEncoding(withAllowedCharacters: allowed) ?? key
            let v = value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
            return "\(k)=\(v)"
        }
        .joined(separator: "&")
        .data(using: .utf8) ?? Data()
    }

    private static func post(_ url: URL, body: Data) async throws -> [String: Any] {
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        req.httpBody = body
        let (data, resp) = try await URLSession.shared.data(for: req)
        let json = (try? JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
        if let http = resp as? HTTPURLResponse, http.statusCode >= 400, json["error"] == nil {
            throw MailError.auth(String(data: data, encoding: .utf8) ?? "Microsoft HTTP \(http.statusCode)")
        }
        return json
    }
}

enum MailAuthSelfCheck {
    static func failures() -> [String] {
        var out: [String] = []
        let x = MicrosoftOAuth.xoauth2(user: "test@example.com", token: "tok")
        if x != "dXNlcj10ZXN0QGV4YW1wbGUuY29tAWF1dGg9QmVhcmVyIHRvawEB" {
            out.append("XOAUTH2 payload mismatch")
        }
        let cmd = MicrosoftOAuth.imapAuthenticateCommand(user: "test@example.com", token: "tok")
        if !cmd.hasPrefix("AUTHENTICATE XOAUTH2 ") || cmd.contains("\n") {
            out.append("IMAP XOAUTH2 must be one AUTHENTICATE line")
        }
        let payload = Data("{\"preferred_username\":\"ken@firm.com\"}".utf8).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
        let jwt = "aaa.\(payload).sig"
        if MicrosoftOAuth.emailFromJWT(jwt) != "ken@firm.com" {
            out.append("JWT email parse failed")
        }
        if let redirect = URL(string: MicrosoftOAuth.redirectURI + "?code=abc123") {
            if case .success(let code) = MicrosoftOAuth.codeFromRedirect(redirect) {
                if code != "abc123" { out.append("redirect code parse failed") }
            } else {
                out.append("redirect not recognized")
            }
        }
        let form = String(data: MicrosoftOAuth.form(["scope": MicrosoftOAuth.scopes]), encoding: .utf8) ?? ""
        if !form.contains("scope=offline_access%20https%3A%2F%2Foutlook.office.com") {
            out.append("form encoding failed: \(form)")
        }
        if MicrosoftOAuth.isClientID("ken") { out.append("ken must not be a client ID") }
        if MicrosoftOAuth.isClientID("ken@firm.com") { out.append("email must not be a client ID") }
        if !MicrosoftOAuth.authorizeURL.absoluteString.contains(MicrosoftOAuth.tenantID) {
            out.append("authorize URL is not tenant-specific")
        }
        if (try? MicrosoftOAuth.startBrowser(clientID: "ken", loginHint: "lawyer@firm.com")) != nil {
            out.append("startBrowser must reject junk client_id=ken")
        }
        let firm = "11111111-2222-3333-4444-555555555555"
        if let url = try? MicrosoftOAuth.startBrowser(clientID: firm, loginHint: "lawyer@firm.com").url.absoluteString {
            if !url.contains("client_id=\(firm)") { out.append("startBrowser must use firm client ID") }
            if !url.contains("login_hint=lawyer") { out.append("login_hint missing from authorize URL") }
            if !url.contains("domain_hint=firm.com") { out.append("domain_hint must use email domain, not tenant id") }
            if url.contains("domain_hint=\(MicrosoftOAuth.tenantID)") { out.append("domain_hint must not be tenant GUID") }
            if url.contains("prompt=admin_consent") { out.append("default sign-in must not force admin_consent") }
        } else {
            out.append("startBrowser failed with valid firm ID")
        }
        if let admin = try? MicrosoftOAuth.startBrowser(clientID: firm, prompt: "admin_consent").url.absoluteString {
            if !admin.contains("prompt=admin_consent") { out.append("explicit admin_consent prompt must stick") }
        }
        if let later = try? MicrosoftOAuth.startBrowser(clientID: firm, prompt: "select_account").url.absoluteString {
            if later.contains("prompt=admin_consent") { out.append("returning sign-in must not force admin_consent") }
        }
        if MicrosoftOAuth.resolvedClientID() != MicrosoftOAuth.clientID {
            out.append("resolvedClientID must return baked client ID")
        }
        if MicrosoftOAuth.clientID != "1f0ced9a-277d-46b6-be8b-7728315eb595" {
            out.append("baked Entra client ID drifted")
        }
        if let extra = URL(string: MicrosoftOAuth.redirectURI + "?code=abc123&session_state=ss&client_info=ci") {
            if case .success(let code) = MicrosoftOAuth.codeFromRedirect(extra) {
                if code != "abc123" { out.append("redirect with extra query failed") }
            } else {
                out.append("redirect with extra query not recognized")
            }
        }
        if let broker = URL(string: "msauth.com.kenturnerlaw.praecipe://auth?code=broker-code") {
            if case .success(let code) = MicrosoftOAuth.codeFromRedirect(broker) {
                if code != "broker-code" { out.append("broker callback code parse failed") }
            } else {
                out.append("broker callback not recognized")
            }
        }
        if MicrosoftOAuth.isOutgoingBrokerURL(URL(string: "msauth://auth")!) == false {
            out.append("msauth must be treated as outgoing Authenticator")
        }
        if let baked = try? MicrosoftOAuth.startBrowser(loginHint: "lawyer@firm.com").url.absoluteString {
            if !baked.contains("client_id=\(MicrosoftOAuth.clientID)") {
                out.append("default startBrowser must use baked client ID")
            }
            if baked.contains("prompt=admin_consent") {
                out.append("baked startBrowser must not force admin_consent")
            }
        } else {
            out.append("startBrowser failed with baked client ID")
        }
        return out
    }
}

extension Notification.Name {
    static let praecipeMicrosoftOAuthURL = Notification.Name("praecipeMicrosoftOAuthURL")
}
