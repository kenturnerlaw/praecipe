import Foundation
import SwiftData

enum PracticeBackupError: LocalizedError {
    case unsupportedVersion(Int)
    case unsafeFilePath

    var errorDescription: String? {
        switch self {
        case .unsupportedVersion(let version): return "This backup uses unsupported format version \(version)."
        case .unsafeFilePath: return "The backup contains an unsafe file path and was not restored."
        }
    }
}

enum PracticeBackupService {
    private struct Archive: Codable {
        let formatVersion: Int
        let createdAt: Date
        let matters: [MatterRecord]
        let timeEntries: [TimeRecord]
        let notes: [NoteRecord]
        let events: [EventRecord]
        let people: [PersonRecord]
        let files: [FileRecord]
        let signatures: [SignatureRecord]
        let settings: [SettingRecord]
    }

    private struct MatterRecord: Codable {
        let id: String
        let caseNo, petitioner, respondent, style, court, county, division, status: String
        let opposingCounsel, clientEmail, clientName, notes: String
        let rate: Double
        let createdAt: Date
        let billingExternalID, lawPayContactID: String?
    }

    private struct TimeRecord: Codable {
        let matterID: String?
        let startedAt, endedAt: Date?
        let minutes: Double
        let activity, description: String
        let billed: Bool
        let rate: Double
        let running: Bool
        let createdAt: Date
        let billingExternalID, lawPayInvoiceSourceID, lawPayInvoiceID, lawPayInvoiceNumber, lawPayStatus: String?
        let lawPaySyncedAt: Date?
        let lawPayError: String?
    }

    private struct NoteRecord: Codable {
        let matterID: String?
        let title, body: String
        let createdAt, updatedAt: Date
    }

    private struct EventRecord: Codable {
        let matterID: String?
        let title, eventType: String
        let startAt, endAt: Date?
        let allDay: Bool
        let location, ruleCite, source, notes: String
        let remindMinutes: Int
        let dismissed: Bool
        let createdAt: Date
    }

    private struct PersonRecord: Codable {
        let matterID: String?
        let name, email, phone, firm, notes: String
        let createdAt: Date
    }

    private struct FileRecord: Codable {
        let matterID: String?
        let filename, relativePath, source, sourceURL, docType: String
        let createdAt: Date
        let data: Data?
    }

    private struct SignatureRecord: Codable { let name, body: String; let isDefault: Bool; let createdAt: Date }
    private struct SettingRecord: Codable { let key, value: String }

    @MainActor
    static func export(context: ModelContext) throws -> URL {
        let matters = try context.fetch(FetchDescriptor<Matter>())
        let matterIDs = Dictionary(uniqueKeysWithValues: matters.map { ($0.persistentModelID, UUID().uuidString) })
        let archive = Archive(
            formatVersion: 1,
            createdAt: Date(),
            matters: matters.map { matter in
                MatterRecord(
                    id: matterIDs[matter.persistentModelID]!, caseNo: matter.caseNo, petitioner: matter.petitioner,
                    respondent: matter.respondent, style: matter.style, court: matter.court, county: matter.county,
                    division: matter.division, status: matter.status, opposingCounsel: matter.opposingCounsel,
                    clientEmail: matter.clientEmail, clientName: matter.clientName, notes: matter.notes, rate: matter.rate,
                    createdAt: matter.createdAt, billingExternalID: matter.billingExternalID, lawPayContactID: matter.lawPayContactID
                )
            },
            timeEntries: try context.fetch(FetchDescriptor<TimeEntry>()).map { entry in
                TimeRecord(
                    matterID: entry.matter.flatMap { matterIDs[$0.persistentModelID] }, startedAt: entry.startedAt,
                    endedAt: entry.endedAt, minutes: entry.minutes, activity: entry.activity,
                    description: entry.entryDescription, billed: entry.billed, rate: entry.rate, running: entry.running,
                    createdAt: entry.createdAt, billingExternalID: entry.billingExternalID,
                    lawPayInvoiceSourceID: entry.lawPayInvoiceSourceID, lawPayInvoiceID: entry.lawPayInvoiceID,
                    lawPayInvoiceNumber: entry.lawPayInvoiceNumber, lawPayStatus: entry.lawPayStatus,
                    lawPaySyncedAt: entry.lawPaySyncedAt, lawPayError: entry.lawPayError
                )
            },
            notes: try context.fetch(FetchDescriptor<PracticeNote>()).map {
                NoteRecord(matterID: $0.matter.flatMap { matterIDs[$0.persistentModelID] }, title: $0.title, body: $0.body, createdAt: $0.createdAt, updatedAt: $0.updatedAt)
            },
            events: try context.fetch(FetchDescriptor<CalendarEvent>()).map {
                EventRecord(matterID: $0.matter.flatMap { matterIDs[$0.persistentModelID] }, title: $0.title, eventType: $0.eventType, startAt: $0.startAt, endAt: $0.endAt, allDay: $0.allDay, location: $0.location, ruleCite: $0.ruleCite, source: $0.source, notes: $0.notes, remindMinutes: $0.remindMinutes, dismissed: $0.dismissed, createdAt: $0.createdAt)
            },
            people: try context.fetch(FetchDescriptor<Person>()).map {
                PersonRecord(matterID: $0.matter.flatMap { matterIDs[$0.persistentModelID] }, name: $0.name, email: $0.email, phone: $0.phone, firm: $0.firm, notes: $0.notes, createdAt: $0.createdAt)
            },
            files: try context.fetch(FetchDescriptor<MatterFile>()).map { file in
                FileRecord(matterID: file.matter.flatMap { matterIDs[$0.persistentModelID] }, filename: file.filename, relativePath: file.relativePath, source: file.source, sourceURL: file.sourceURL, docType: file.docType, createdAt: file.createdAt, data: try? Data(contentsOf: fileURL(for: file.relativePath)))
            },
            signatures: try context.fetch(FetchDescriptor<MailSignature>()).map {
                SignatureRecord(name: $0.name, body: $0.body, isDefault: $0.isDefault, createdAt: $0.createdAt)
            },
            settings: try context.fetch(FetchDescriptor<AppSetting>()).map { SettingRecord(key: $0.key, value: $0.value) }
                + [SettingRecord(key: "lawpay.serverURL", value: LawPayConfiguration.serverURL)]
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(archive)
        let stamp = Date().formatted(.iso8601.year().month().day())
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("Praecipe-Practice-Backup-\(stamp).praecipebackup")
        try data.write(to: url, options: [.atomic, .completeFileProtection])
        return url
    }

    @MainActor
    static func restore(from url: URL, context: ModelContext) throws {
        let accessed = url.startAccessingSecurityScopedResource()
        defer { if accessed { url.stopAccessingSecurityScopedResource() } }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let archive = try decoder.decode(Archive.self, from: Data(contentsOf: url))
        guard archive.formatVersion == 1 else { throw PracticeBackupError.unsupportedVersion(archive.formatVersion) }

        let stagingRoot = FileManager.default.temporaryDirectory.appendingPathComponent("Praecipe-Restore-\(UUID().uuidString)", isDirectory: true)
        let stagingDocuments = stagingRoot.appendingPathComponent("Documents", isDirectory: true)
        try FileManager.default.createDirectory(at: stagingDocuments, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: stagingRoot) }
        for record in archive.files {
            guard let data = record.data else { continue }
            let destination = try safeRestoreURL(for: record.relativePath, under: stagingDocuments)
            try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: destination, options: [.atomic, .completeFileProtection])
        }

        try deleteAll(PracticeNote.self, context: context)
        try deleteAll(CalendarEvent.self, context: context)
        try deleteAll(Person.self, context: context)
        try deleteAll(MatterFile.self, context: context)
        try deleteAll(TimeEntry.self, context: context)
        try deleteAll(Matter.self, context: context)
        try deleteAll(MailSignature.self, context: context)
        try deleteAll(AppSetting.self, context: context)

        var matterMap: [String: Matter] = [:]
        for record in archive.matters {
            let matter = Matter(caseNo: record.caseNo, style: record.style, status: record.status)
            matter.petitioner = record.petitioner; matter.respondent = record.respondent; matter.court = record.court
            matter.county = record.county; matter.division = record.division; matter.opposingCounsel = record.opposingCounsel
            matter.clientEmail = record.clientEmail; matter.clientName = record.clientName; matter.notes = record.notes
            matter.rate = record.rate; matter.createdAt = record.createdAt; matter.billingExternalID = record.billingExternalID
            matter.lawPayContactID = record.lawPayContactID
            context.insert(matter); matterMap[record.id] = matter
        }
        for record in archive.timeEntries {
            let entry = TimeEntry(minutes: record.minutes, activity: record.activity, description: record.description)
            entry.matter = record.matterID.flatMap { matterMap[$0] }; entry.startedAt = record.startedAt; entry.endedAt = record.endedAt
            entry.billed = record.billed; entry.rate = record.rate; entry.running = record.running; entry.createdAt = record.createdAt
            entry.billingExternalID = record.billingExternalID; entry.lawPayInvoiceSourceID = record.lawPayInvoiceSourceID
            entry.lawPayInvoiceID = record.lawPayInvoiceID; entry.lawPayInvoiceNumber = record.lawPayInvoiceNumber
            entry.lawPayStatus = record.lawPayStatus; entry.lawPaySyncedAt = record.lawPaySyncedAt; entry.lawPayError = record.lawPayError
            context.insert(entry)
        }
        for record in archive.notes {
            let note = PracticeNote(title: record.title, body: record.body); note.matter = record.matterID.flatMap { matterMap[$0] }
            note.createdAt = record.createdAt; note.updatedAt = record.updatedAt; context.insert(note)
        }
        for record in archive.events {
            let event = CalendarEvent(title: record.title, startAt: record.startAt ?? Date(), eventType: record.eventType, allDay: record.allDay)
            event.matter = record.matterID.flatMap { matterMap[$0] }; event.endAt = record.endAt; event.location = record.location
            event.ruleCite = record.ruleCite; event.source = record.source; event.notes = record.notes; event.remindMinutes = record.remindMinutes
            event.dismissed = record.dismissed; event.createdAt = record.createdAt; context.insert(event)
        }
        for record in archive.people {
            let person = Person(email: record.email, name: record.name); person.matter = record.matterID.flatMap { matterMap[$0] }
            person.phone = record.phone; person.firm = record.firm; person.notes = record.notes; person.createdAt = record.createdAt; context.insert(person)
        }
        for record in archive.files {
            let file = MatterFile(filename: record.filename, relativePath: record.relativePath, docType: record.docType, source: record.source)
            file.matter = record.matterID.flatMap { matterMap[$0] }; file.sourceURL = record.sourceURL; file.createdAt = record.createdAt
            context.insert(file)
        }
        for record in archive.signatures {
            let signature = MailSignature(name: record.name, body: record.body, isDefault: record.isDefault)
            signature.createdAt = record.createdAt; context.insert(signature)
        }
        for record in archive.settings {
            if record.key == "lawpay.serverURL" {
                LawPayConfiguration.serverURL = record.value
            } else {
                context.insert(AppSetting(key: record.key, value: record.value))
            }
        }

        let activeFiles = AppStore.filesRoot
        let stagedFiles = stagingDocuments.appendingPathComponent("matters", isDirectory: true)
        let oldFiles = stagingRoot.appendingPathComponent("Previous-matters", isDirectory: true)
        var movedOldFiles = false
        var installedNewFiles = false
        do {
            if FileManager.default.fileExists(atPath: activeFiles.path) {
                try FileManager.default.moveItem(at: activeFiles, to: oldFiles)
                movedOldFiles = true
            }
            if FileManager.default.fileExists(atPath: stagedFiles.path) {
                try FileManager.default.moveItem(at: stagedFiles, to: activeFiles)
            } else {
                try FileManager.default.createDirectory(at: activeFiles, withIntermediateDirectories: true)
            }
            installedNewFiles = true
            try context.save()
            if movedOldFiles { try FileManager.default.removeItem(at: oldFiles) }
        } catch {
            context.rollback()
            if installedNewFiles, FileManager.default.fileExists(atPath: activeFiles.path) {
                try? FileManager.default.removeItem(at: activeFiles)
            }
            if movedOldFiles, FileManager.default.fileExists(atPath: oldFiles.path) {
                try? FileManager.default.moveItem(at: oldFiles, to: activeFiles)
            }
            throw error
        }
    }

    @MainActor
    private static func deleteAll<T: PersistentModel>(_ type: T.Type, context: ModelContext) throws {
        for item in try context.fetch(FetchDescriptor<T>()) { context.delete(item) }
    }

    private static func documentsRoot() -> URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
    }

    private static func fileURL(for relativePath: String) -> URL {
        documentsRoot().appendingPathComponent(relativePath)
    }

    private static func safeRestoreURL(for relativePath: String, under rootURL: URL) throws -> URL {
        guard relativePath == "matters" || relativePath.hasPrefix("matters/") else { throw PracticeBackupError.unsafeFilePath }
        let root = rootURL.standardizedFileURL
        let destination = root.appendingPathComponent(relativePath).standardizedFileURL
        guard destination.path.hasPrefix(root.path + "/") else { throw PracticeBackupError.unsafeFilePath }
        return destination
    }
}
