import Foundation
import SwiftData

struct FileBillResult {
    var connected = false
    var saved: [String] = []
    var downloaded: [String] = []
    var emailed: String?
    var minutes: Double?
    var error: String?
}

enum FileAndBill {
    @MainActor
    static func run(
        message: MailMessage,
        matter: Matter,
        connect: Bool,
        saveAttachments: Bool,
        docType: DocType,
        downloadURLs: Bool,
        emailClient: Bool,
        clientEmail: String,
        addTime: Bool,
        minutes: Double,
        activity: String,
        context: ModelContext,
        mail: MailSyncService,
        account: MailAccount?
    ) async -> FileBillResult {
        var result = FileBillResult()
        if connect {
            message.matter = matter
            result.connected = true
        }
        if saveAttachments {
            for att in message.attachments ?? [] {
                if let saved = save(data: att.data, filename: att.filename, matter: matter, docType: docType, source: "mail", message: message, context: context) {
                    result.saved.append(saved)
                    att.savedRelativePath = saved
                }
            }
        }
        if downloadURLs {
            for found in MailExtract.urls(in: message) where found.serviceLikely || downloadURLs {
                do {
                    let (data, response) = try await URLSession.shared.data(from: found.url)
                    let name = found.url.lastPathComponent.isEmpty ? "service-document.pdf" : found.url.lastPathComponent
                    if let saved = save(data: data, filename: name, matter: matter, docType: .service, source: "url", message: message, context: context, sourceURL: found.url.absoluteString) {
                        result.downloaded.append(saved)
                    }
                    _ = response
                } catch {
                    result.error = error.localizedDescription
                }
            }
        }
        if addTime {
            let entry = TimeEntry(minutes: minutes > 0 ? minutes : 12, activity: activity, description: message.subject)
            entry.matter = matter
            entry.message = message
            entry.rate = matter.rate
            context.insert(entry)
            result.minutes = entry.minutes
        }
        if emailClient {
            let addr = clientEmail.trimmingCharacters(in: .whitespacesAndNewlines)
            if addr.contains("@"), let account {
                let body = """
                Please see the enclosed correspondence regarding \(matter.label).

                \(message.subject)

                """ + (defaultSignature(context) ?? "")
                do {
                    try await mail.send(from: account, to: [addr], subject: "RE: \(message.subject)", body: body)
                    result.emailed = addr
                    if matter.clientEmail.isEmpty { matter.clientEmail = addr }
                } catch {
                    result.error = error.localizedDescription
                }
            } else {
                result.error = "Put the client’s email on the matter."
            }
        }
        do {
            try context.save()
        } catch {
            let saveError = "Praecipe completed the requested actions but could not save the practice record: \(error.localizedDescription)"
            result.error = result.error.map { "\($0) \(saveError)" } ?? saveError
        }
        return result
    }

    private static func defaultSignature(_ context: ModelContext) -> String? {
        let all = (try? context.fetch(FetchDescriptor<MailSignature>())) ?? []
        return (all.first(where: \.isDefault) ?? all.first)?.body
    }

    static func save(data: Data?, filename: String, matter: Matter, docType: DocType, source: String, message: MailMessage?, context: ModelContext, sourceURL: String = "") -> String? {
        guard let data, !data.isEmpty else { return nil }
        let safeMatter = matter.caseNo.isEmpty ? "matter" : matter.caseNo.replacingOccurrences(of: "/", with: "-")
        let dir = AppStore.filesRoot
            .appendingPathComponent(safeMatter, isDirectory: true)
            .appendingPathComponent(docType.rawValue, isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try? FileManager.default.setAttributes([.protectionKey: FileProtectionType.complete], ofItemAtPath: dir.path)
        let dest = dir.appendingPathComponent(filename)
        do {
            try data.write(to: dest, options: [.atomic, .completeFileProtection])
            let rel = "matters/\(safeMatter)/\(docType.rawValue)/\(filename)"
            let rec = MatterFile(filename: filename, relativePath: rel, docType: docType.rawValue, source: source)
            rec.matter = matter
            rec.message = message
            rec.sourceURL = sourceURL
            context.insert(rec)
            return filename
        } catch {
            return nil
        }
    }
}
