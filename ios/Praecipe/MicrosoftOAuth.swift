import AuthenticationServices
import CryptoKit
import Foundation
import Security
import UIKit

enum MicrosoftOAuthError: LocalizedError {
    case message(String)
    case oauth(String, String)
    var errorDescription: String? {
        switch self {
        case .message(let value): return value
        case .oauth(_, let value): return value
        }
    }
}

@MainActor
private final class MicrosoftWebAuthentication: NSObject, ASWebAuthenticationPresentationContextProviding {
    static let shared = MicrosoftWebAuthentication()
    private var session: ASWebAuthenticationSession?

    func authorize(url: URL) async throws -> URL {
        try await withCheckedThrowingContinuation { continuation in
            let session = ASWebAuthenticationSession(url: url, callbackURLScheme: "msauth.com.kenturnerlaw.praecipe") { [weak self] callbackURL, error in
                self?.session = nil
                if let authError = error as? ASWebAuthenticationSessionError, authError.code == .canceledLogin {
                    continuation.resume(throwing: MicrosoftOAuthError.message("Microsoft sign-in was canceled."))
                } else if let error {
                    continuation.resume(throwing: error)
                } else if let callbackURL {
                    continuation.resume(returning: callbackURL)
                } else {
                    continuation.resume(throwing: MicrosoftOAuthError.message("Microsoft did not return to Praecipe."))
                }
            }
            session.presentationContextProvider = self
            session.prefersEphemeralWebBrowserSession = false
            self.session = session
            guard session.start() else {
                self.session = nil
                continuation.resume(throwing: MicrosoftOAuthError.message("Microsoft sign-in could not be opened."))
                return
            }
        }
    }

    func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap(\.windows)
            .first(where: \.isKeyWindow) ?? ASPresentationAnchor()
    }
}

enum MicrosoftOAuth {
    static let clientID = "2a91c11c-e4a7-4982-acc7-92da3f3385c4"
    private static let authority = "https://login.microsoftonline.com/eedeccaf-01c1-4439-a88b-88e587be9f1c/oauth2/v2.0"
    private static let redirectURI = "msauth.com.kenturnerlaw.praecipe://auth"
    private static let scopes = "openid profile email offline_access https://outlook.office.com/IMAP.AccessAsUser.All https://outlook.office.com/SMTP.Send"

    static func hasSession(email: String) -> Bool {
        !KeychainStore.secret(account: refreshKey(email)).isEmpty
    }

    @MainActor
    static func signIn(expectedEmail: String? = nil) async throws -> String {
        let verifier = randomURLSafeString(byteCount: 32)
        let challenge = Data(SHA256.hash(data: Data(verifier.utf8))).base64URLEncodedString()
        let state = randomURLSafeString(byteCount: 24)
        let nonce = randomURLSafeString(byteCount: 24)
        var components = URLComponents(string: "\(authority)/authorize")!
        components.queryItems = [
            URLQueryItem(name: "client_id", value: clientID),
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "redirect_uri", value: redirectURI),
            URLQueryItem(name: "response_mode", value: "query"),
            URLQueryItem(name: "scope", value: scopes),
            URLQueryItem(name: "state", value: state),
            URLQueryItem(name: "nonce", value: nonce),
            URLQueryItem(name: "code_challenge", value: challenge),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
            URLQueryItem(name: "prompt", value: "select_account"),
        ]
        guard let authorizationURL = components.url else {
            throw MicrosoftOAuthError.message("Microsoft sign-in URL could not be created.")
        }
        let callbackURL = try await MicrosoftWebAuthentication.shared.authorize(url: authorizationURL)
        guard callbackURL.scheme?.caseInsensitiveCompare("msauth.com.kenturnerlaw.praecipe") == .orderedSame,
              callbackURL.host?.caseInsensitiveCompare("auth") == .orderedSame else {
            throw MicrosoftOAuthError.message("Microsoft returned an invalid callback to Praecipe.")
        }
        let callback = URLComponents(url: callbackURL, resolvingAgainstBaseURL: false)
        var values: [String: String] = [:]
        for item in callback?.queryItems ?? [] where values[item.name] == nil {
            values[item.name] = item.value ?? ""
        }
        guard values["state"] == state else {
            throw MicrosoftOAuthError.message("Microsoft returned an invalid sign-in response.")
        }
        if let error = values["error"], !error.isEmpty {
            throw MicrosoftOAuthError.message(values["error_description"] ?? error)
        }
        guard let code = values["code"], !code.isEmpty else {
            throw MicrosoftOAuthError.message("Microsoft did not authorize Praecipe.")
        }
        let response = try await post("\(authority)/token", values: [
            "client_id": clientID,
            "grant_type": "authorization_code",
            "code": code,
            "redirect_uri": redirectURI,
            "code_verifier": verifier,
            "scope": scopes,
        ])
        let authorizedEmail = try identityEmail(response, expectedNonce: nonce)
        if let expectedEmail, !expectedEmail.isEmpty,
           authorizedEmail.caseInsensitiveCompare(expectedEmail) != .orderedSame {
            throw MicrosoftOAuthError.message("Microsoft authorized \(authorizedEmail), but this mailbox is \(expectedEmail). Sign in with the matching work account.")
        }
        try saveTokens(response, email: authorizedEmail)
        return authorizedEmail
    }

    static func accessToken(email: String) async throws -> String {
        let access = KeychainStore.secret(account: accessKey(email))
        let expiry = UserDefaults.standard.double(forKey: expiryKey(email))
        if !access.isEmpty, expiry > Date().timeIntervalSince1970 + 60 { return access }
        let refresh = KeychainStore.secret(account: refreshKey(email))
        guard !refresh.isEmpty else {
            throw MicrosoftOAuthError.message("Microsoft sign-in is required. Open Settings and sign in once.")
        }
        let response: [String: Any]
        do {
            response = try await post("\(authority)/token", values: [
                "client_id": clientID,
                "grant_type": "refresh_token",
                "refresh_token": refresh,
                "scope": scopes,
            ])
        } catch MicrosoftOAuthError.oauth {
            signOut(email: email)
            throw MicrosoftOAuthError.message("Microsoft sign-in expired or was revoked. Open Settings and sign in again.")
        }
        try saveTokens(response, email: email)
        return KeychainStore.secret(account: accessKey(email))
    }

    static func signOut(email: String) {
        KeychainStore.deleteSecret(account: accessKey(email))
        KeychainStore.deleteSecret(account: refreshKey(email))
        UserDefaults.standard.removeObject(forKey: expiryKey(email))
        // Remove credentials issued to the retired client ID used by earlier builds.
        KeychainStore.deleteSecret(account: legacyAccessKey(email))
        KeychainStore.deleteSecret(account: legacyRefreshKey(email))
        UserDefaults.standard.removeObject(forKey: legacyExpiryKey(email))
    }

    private static func saveTokens(_ response: [String: Any], email: String) throws {
        guard let access = response["access_token"] as? String, !access.isEmpty else {
            throw MicrosoftOAuthError.message(errorMessage(response, fallback: "Microsoft did not return an access token."))
        }
        KeychainStore.saveSecret(access, account: accessKey(email))
        if let refresh = response["refresh_token"] as? String, !refresh.isEmpty {
            KeychainStore.saveSecret(refresh, account: refreshKey(email))
        }
        let expires = (response["expires_in"] as? NSNumber)?.doubleValue ?? 3600
        UserDefaults.standard.set(Date().timeIntervalSince1970 + expires, forKey: expiryKey(email))
        KeychainStore.deleteSecret(account: legacyAccessKey(email))
        KeychainStore.deleteSecret(account: legacyRefreshKey(email))
        UserDefaults.standard.removeObject(forKey: legacyExpiryKey(email))
    }

    private static func identityEmail(_ response: [String: Any], expectedNonce: String) throws -> String {
        guard let token = response["id_token"] as? String else {
            throw MicrosoftOAuthError.message("Microsoft did not return the signed-in account identity.")
        }
        let parts = token.split(separator: ".")
        guard parts.count >= 2, let data = Data(base64URL: String(parts[1])),
              let claims = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            throw MicrosoftOAuthError.message("Microsoft returned an unreadable identity token.")
        }
        guard claims["aud"] as? String == clientID,
              claims["tid"] as? String == "eedeccaf-01c1-4439-a88b-88e587be9f1c",
              claims["nonce"] as? String == expectedNonce else {
            throw MicrosoftOAuthError.message("Microsoft returned an identity token for a different app or tenant.")
        }
        let email = ((claims["preferred_username"] as? String) ?? (claims["email"] as? String) ?? (claims["upn"] as? String) ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard email.contains("@") else { throw MicrosoftOAuthError.message("Microsoft did not identify the mailbox address.") }
        return email
    }

    private static func post(_ urlString: String, values: [String: String]) async throws -> [String: Any] {
        guard let url = URL(string: urlString) else { throw MicrosoftOAuthError.message("Invalid Microsoft sign-in URL.") }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = values.map { "\(formEncode($0.key))=\(formEncode($0.value))" }.sorted().joined(separator: "&").data(using: .utf8)
        let (data, response) = try await URLSession.shared.data(for: request)
        let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else {
            let code = object["error"] as? String ?? "http_\(status)"
            throw MicrosoftOAuthError.oauth(code, errorMessage(object, fallback: "Microsoft sign-in failed (HTTP \(status))."))
        }
        return object
    }

    private static func randomURLSafeString(byteCount: Int) -> String {
        var bytes = [UInt8](repeating: 0, count: byteCount)
        guard SecRandomCopyBytes(kSecRandomDefault, byteCount, &bytes) == errSecSuccess else {
            return UUID().uuidString.replacingOccurrences(of: "-", with: "")
        }
        return Data(bytes).base64URLEncodedString()
    }

    private static func errorMessage(_ object: [String: Any], fallback: String) -> String {
        (object["error_description"] as? String) ?? (object["message"] as? String) ?? fallback
    }

    private static func formEncode(_ value: String) -> String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        return value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
    }

    private static func normalized(_ email: String) -> String { email.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
    private static func accessKey(_ email: String) -> String { "microsoft.oauth.\(clientID).access.\(normalized(email))" }
    private static func refreshKey(_ email: String) -> String { "microsoft.oauth.\(clientID).refresh.\(normalized(email))" }
    private static func expiryKey(_ email: String) -> String { "microsoft.oauth.\(clientID).expiry.\(normalized(email))" }
    private static func legacyAccessKey(_ email: String) -> String { "microsoft.oauth.access.\(normalized(email))" }
    private static func legacyRefreshKey(_ email: String) -> String { "microsoft.oauth.refresh.\(normalized(email))" }
    private static func legacyExpiryKey(_ email: String) -> String { "microsoft.oauth.expiry.\(normalized(email))" }
}

private extension Data {
    func base64URLEncodedString() -> String {
        base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    }

    init?(base64URL: String) {
        var value = base64URL.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        value += String(repeating: "=", count: (4 - value.count % 4) % 4)
        self.init(base64Encoded: value)
    }
}
