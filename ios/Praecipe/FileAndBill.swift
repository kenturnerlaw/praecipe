import Foundation
import SwiftData

struct FileBillResult {
    var connected = false
    var savedFiles: [URL] = []
    var downloadedFiles: [URL] = []
    var emailed: String?
    var hours: Double?
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
        hours: Double,
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
            for att in message.attachments {
                if let saved = save(data: att.data, filename: att.filename, matter: matter, docType: docType, source: "mail", message: message, context: context) {
                    result.savedFiles.append(saved.url)
                    att.savedRelativePath = saved.filename
                }
            }
        }
        if downloadURLs {
            for found in MailExtract.urls(in: message) where found.serviceLikely || downloadURLs {
                do {
                    let (data, response) = try await URLSession.shared.data(from: found.url)
                    let name = found.url.lastPathComponent.isEmpty ? "service-document.pdf" : found.url.lastPathComponent
                    if let saved = save(data: data, filename: name, matter: matter, docType: .service, source: "url", message: message, context: context, sourceURL: found.url.absoluteString) {
                        result.downloadedFiles.append(saved.url)
                    }
                    _ = response
                } catch {
                    result.error = error.localizedDescription
                }
            }
        }
        if addTime {
            if let existing = existingTimeEntry(for: message, context: context) {
                message.timeBilled = true
                result.hours = existing.hours
            } else if message.timeBilled {
                // Flag set without a linked entry (legacy / partial save) — do not create a second bill.
                result.hours = nil
            } else {
                let billedHours = hours > 0 ? hours : LegalTime.defaultHours
                let entry = TimeEntry(minutes: LegalTime.minutes(fromHours: billedHours), activity: activity, description: message.subject)
                entry.matter = matter
                entry.message = message
                entry.rate = matter.rate
                context.insert(entry)
                message.timeBilled = true
                result.hours = entry.hours
            }
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
        try? context.save()
        return result
    }

    private static func defaultSignature(_ context: ModelContext) -> String? {
        let all = (try? context.fetch(FetchDescriptor<MailSignature>())) ?? []
        return (all.first(where: \.isDefault) ?? all.first)?.body
    }

    /// One File & Bill time entry per message (idempotent).
    static func existingTimeEntry(for message: MailMessage, context: ModelContext) -> TimeEntry? {
        let messageID = message.persistentModelID
        let entries = (try? context.fetch(FetchDescriptor<TimeEntry>())) ?? []
        return entries.first { $0.message?.persistentModelID == messageID }
    }

    static func isTimeBilled(_ message: MailMessage, context: ModelContext) -> Bool {
        if message.timeBilled { return true }
        if existingTimeEntry(for: message, context: context) != nil {
            message.timeBilled = true
            return true
        }
        return false
    }

    struct SavedFile {
        let filename: String
        let url: URL
    }

    static func save(data: Data?, filename: String, matter: Matter, docType: DocType, source: String, message: MailMessage?, context: ModelContext, sourceURL: String = "") -> SavedFile? {
        guard let data, !data.isEmpty else { return nil }
        let safeMatter = matter.caseNo.isEmpty ? "matter" : matter.caseNo.replacingOccurrences(of: "/", with: "-")
        let dir = AppStore.filesRoot
            .appendingPathComponent(safeMatter, isDirectory: true)
            .appendingPathComponent(docType.rawValue, isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let dest = dir.appendingPathComponent(filename)
        do {
            try data.write(to: dest, options: .atomic)
            let rel = "matters/\(safeMatter)/\(docType.rawValue)/\(filename)"
            let rec = MatterFile(filename: filename, relativePath: rel, docType: docType.rawValue, source: source)
            rec.matter = matter
            rec.message = message
            rec.sourceURL = sourceURL
            context.insert(rec)
            return SavedFile(filename: filename, url: dest)
        } catch {
            return nil
        }
    }
}
