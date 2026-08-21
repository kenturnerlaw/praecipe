import Foundation
import SwiftData

struct LawPayBankAccount: Codable, Identifiable, Hashable {
    let id: String
    let name: String
    let bankName: String
    let trust: Bool
    let currency: String
    let testMode: Bool
    let maskedAccount: String

    enum CodingKeys: String, CodingKey {
        case id, name, trust, currency
        case bankName = "bank_name"
        case testMode = "test_mode"
        case maskedAccount = "masked_account"
    }
}

struct LawPayConnectionStatus: Codable {
    let configured: Bool
    let connected: Bool
    let redirectURI: String
    let selectedBankAccountID: String
    let bankAccounts: [LawPayBankAccount]

    enum CodingKeys: String, CodingKey {
        case configured, connected
        case redirectURI = "redirect_uri"
        case selectedBankAccountID = "selected_bank_account_id"
        case bankAccounts = "bank_accounts"
    }
}

struct LawPayInvoiceResult: Codable {
    let ok: Bool
    let invoiceID: String
    let invoiceNumber: String
    let status: String
    let contactID: String
    let sourceID: String
    let sent: Bool

    enum CodingKeys: String, CodingKey {
        case ok, status, sent
        case invoiceID = "invoice_id"
        case invoiceNumber = "invoice_number"
        case contactID = "contact_id"
        case sourceID = "source_id"
    }
}

enum LawPayConfiguration {
    private static let serverURLKey = "lawpay.serverURL"
    private static let tokenAccount = "praecipe-server-api-token"

    static var serverURL: String {
        get { UserDefaults.standard.string(forKey: serverURLKey) ?? "" }
        set { UserDefaults.standard.set(newValue.trimmingCharacters(in: .whitespacesAndNewlines), forKey: serverURLKey) }
    }

    static var apiToken: String {
        get { KeychainStore.secret(account: tokenAccount) }
        set {
            if newValue.isEmpty {
                KeychainStore.deleteSecret(account: tokenAccount)
            } else {
                KeychainStore.saveSecret(newValue, account: tokenAccount)
            }
        }
    }

    static func validatedBaseURL() throws -> URL {
        let raw = serverURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: raw), let scheme = url.scheme?.lowercased(), url.host != nil else {
            throw LawPaySyncError.configuration("Enter the HTTPS address of the Praecipe billing server.")
        }
        #if DEBUG
        let debugLocal = scheme == "http" && ["127.0.0.1", "localhost"].contains(url.host?.lowercased() ?? "")
        #else
        let debugLocal = false
        #endif
        guard scheme == "https" || debugLocal else {
            throw LawPaySyncError.configuration("LawPay billing requires HTTPS so client and invoice data are encrypted in transit.")
        }
        return url
    }
}

enum LawPaySyncError: LocalizedError {
    case configuration(String)
    case server(String)
    case invalidResponse

    var errorDescription: String? {
        switch self {
        case .configuration(let message), .server(let message): return message
        case .invalidResponse: return "The Praecipe billing server returned an invalid response."
        }
    }
}

struct LawPaySyncService {
    private struct ConnectResponse: Codable {
        let authorizationURL: URL
        enum CodingKeys: String, CodingKey { case authorizationURL = "authorization_url" }
    }
    private struct ErrorResponse: Codable { let error: String }

    private struct InvoiceEntryPayload: Codable {
        let externalID: String
        let activity: String
        let description: String
        let minutes: Double
        let rate: Double
        let feeCents: Int
        let date: String
    }

    private struct InvoicePayload: Codable {
        let matterExternalID: String
        let clientName: String
        let clientEmail: String
        let reference: String
        let sourceID: String
        let invoiceDate: String
        let bankAccountID: String?
        let entries: [InvoiceEntryPayload]
        let sendEmail: Bool
        let testMode: Bool
    }

    func connectionStatus() async throws -> LawPayConnectionStatus {
        try await request("api/lawpay/status", method: "GET", response: LawPayConnectionStatus.self)
    }

    func authorizationURL() async throws -> URL {
        let result: ConnectResponse = try await request("api/lawpay/connect", method: "POST", response: ConnectResponse.self)
        return result.authorizationURL
    }

    func selectBankAccount(_ id: String) async throws -> LawPayConnectionStatus {
        try await request(
            "api/lawpay/bank-account",
            method: "POST",
            payload: ["bank_account_id": id],
            response: LawPayConnectionStatus.self
        )
    }

    @MainActor
    func createInvoice(
        entries: [TimeEntry],
        matter: Matter,
        bankAccountID: String?,
        sendEmail: Bool,
        testMode: Bool,
        context: ModelContext
    ) async throws -> LawPayInvoiceResult {
        guard !entries.isEmpty, entries.allSatisfy({ !$0.running }) else {
            throw LawPaySyncError.configuration("Select at least one stopped time entry.")
        }
        let email = matter.clientEmail.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard email.contains("@") else {
            throw LawPaySyncError.configuration("Add the client's email to the matter before creating a LawPay invoice.")
        }

        if matter.billingExternalID == nil { matter.billingExternalID = UUID().uuidString.lowercased() }
        for entry in entries where entry.billingExternalID == nil {
            entry.billingExternalID = UUID().uuidString.lowercased()
        }
        let existingSources = Set(entries.compactMap(\.lawPayInvoiceSourceID).filter { !$0.isEmpty })
        let sourceID: String
        if existingSources.count == 1, let existing = existingSources.first,
           entries.allSatisfy({ $0.lawPayInvoiceID == nil }) {
            sourceID = existing
        } else {
            sourceID = "praecipe:invoice:\(UUID().uuidString.lowercased())"
            entries.forEach { $0.lawPayInvoiceSourceID = sourceID }
        }
        try context.save()

        let dateFormatter = DateFormatter()
        dateFormatter.calendar = Calendar(identifier: .gregorian)
        dateFormatter.locale = Locale(identifier: "en_US_POSIX")
        dateFormatter.timeZone = TimeZone(secondsFromGMT: 0)
        dateFormatter.dateFormat = "yyyy-MM-dd"
        let itemPayloads = entries.map { entry in
            InvoiceEntryPayload(
                externalID: entry.billingExternalID!,
                activity: entry.activity,
                description: entry.entryDescription.isEmpty ? entry.activity : entry.entryDescription,
                minutes: entry.minutes,
                rate: entry.rate,
                feeCents: Int((entry.fee * 100).rounded()),
                date: dateFormatter.string(from: entry.createdAt)
            )
        }
        let payload = InvoicePayload(
            matterExternalID: matter.billingExternalID!,
            clientName: matter.clientName,
            clientEmail: email,
            reference: matter.caseNo.isEmpty ? matter.style : matter.caseNo,
            sourceID: sourceID,
            invoiceDate: dateFormatter.string(from: Date()),
            bankAccountID: bankAccountID,
            entries: itemPayloads,
            sendEmail: sendEmail,
            testMode: testMode
        )

        do {
            let result: LawPayInvoiceResult = try await request(
                "api/lawpay/invoices",
                method: "POST",
                payload: payload,
                response: LawPayInvoiceResult.self
            )
            let now = Date()
            for entry in entries {
                entry.billed = true
                entry.lawPayInvoiceID = result.invoiceID
                entry.lawPayInvoiceNumber = result.invoiceNumber
                entry.lawPayStatus = result.status
                entry.lawPaySyncedAt = now
                entry.lawPayError = nil
            }
            matter.lawPayContactID = result.contactID
            try context.save()
            return result
        } catch {
            for entry in entries {
                entry.lawPayStatus = "failed"
                entry.lawPayError = error.localizedDescription
            }
            try? context.save()
            throw error
        }
    }

    private func request<Response: Decodable>(
        _ path: String,
        method: String,
        response: Response.Type
    ) async throws -> Response {
        try await request(path, method: method, payloadData: nil, response: response)
    }

    private func request<Payload: Encodable, Response: Decodable>(
        _ path: String,
        method: String,
        payload: Payload,
        response: Response.Type
    ) async throws -> Response {
        let encoder = JSONEncoder()
        encoder.keyEncodingStrategy = .convertToSnakeCase
        return try await request(path, method: method, payloadData: encoder.encode(payload), response: response)
    }

    private func request<Response: Decodable>(
        _ path: String,
        method: String,
        payloadData: Data?,
        response: Response.Type
    ) async throws -> Response {
        let base = try LawPayConfiguration.validatedBaseURL()
        let url = base.appendingPathComponent(path)
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.timeoutInterval = 45
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let payloadData {
            request.httpBody = payloadData
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        let token = LawPayConfiguration.apiToken
        if !token.isEmpty { request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }

        let (data, rawResponse) = try await URLSession.shared.data(for: request)
        guard let http = rawResponse as? HTTPURLResponse else { throw LawPaySyncError.invalidResponse }
        let decoder = JSONDecoder()
        guard (200..<300).contains(http.statusCode) else {
            if let failure = try? decoder.decode(ErrorResponse.self, from: data) {
                throw LawPaySyncError.server(failure.error)
            }
            throw LawPaySyncError.server("The Praecipe billing server returned HTTP \(http.statusCode).")
        }
        do {
            return try decoder.decode(Response.self, from: data)
        } catch {
            throw LawPaySyncError.invalidResponse
        }
    }
}
