import Foundation
import SwiftData

@Model
final class MailAccount {
    var provider: String
    var email: String
    var displayName: String
    var accountDescription: String
    var imapHost: String
    var imapPort: String
    var imapUser: String
    var smtpHost: String
    var smtpPort: String
    var smtpUser: String
    var smtpTLS: String
    var authType: String
    var isDefault: Bool
    var enabled: Bool
    var createdAt: Date
    var lastUID: Int

    init(provider: String, email: String, displayName: String = "") {
        self.provider = provider
        self.email = email
        self.displayName = displayName
        self.accountDescription = "Praecipe"
        self.imapHost = ""
        self.imapPort = "993"
        self.imapUser = email
        self.smtpHost = ""
        self.smtpPort = "587"
        self.smtpUser = email
        self.smtpTLS = "starttls"
        self.authType = "password"
        self.isDefault = true
        self.enabled = true
        self.createdAt = Date()
        self.lastUID = 0
    }
}

@Model
final class Matter {
    var caseNo: String
    var petitioner: String
    var respondent: String
    var style: String
    var court: String
    var county: String
    var division: String
    var status: String
    var opposingCounsel: String
    var clientEmail: String
    var clientName: String
    var rate: Double
    var notes: String
    var createdAt: Date
    var billingExternalID: String?
    var lawPayContactID: String?

    init(caseNo: String = "", style: String = "", status: String = "open") {
        self.caseNo = caseNo
        self.petitioner = ""
        self.respondent = ""
        self.style = style
        self.court = "Circuit Court"
        self.county = ""
        self.division = "Family"
        self.status = status
        self.opposingCounsel = ""
        self.clientEmail = ""
        self.clientName = ""
        self.rate = 0
        self.notes = ""
        self.createdAt = Date()
        self.billingExternalID = nil
        self.lawPayContactID = nil
    }

    var label: String {
        if !caseNo.isEmpty { return "\(caseNo) — \(style.isEmpty ? "Matter" : style)" }
        return style.isEmpty ? "Matter" : style
    }
}

@Model
final class MailMessage {
    var accountEmail: String
    var imapUID: String
    var folder: String
    var messageIdHeader: String
    var inReplyTo: String
    var referencesHeader: String
    var fromAddr: String
    var toAddr: String
    var ccAddr: String
    var bccAddr: String
    var replyTo: String
    var subject: String
    var sentAt: Date?
    var snippet: String
    var bodyText: String
    var bodyHTML: String
    var seen: Bool
    var flagged: Bool
    var deleted: Bool
    var answered: Bool
    var hasAttachments: Bool
    var labelsJSON: String
    var syncedAt: Date
    var matter: Matter?

    @Relationship(deleteRule: .cascade) var attachments: [MailAttachment]

    init(accountEmail: String, folder: String, imapUID: String) {
        self.accountEmail = accountEmail
        self.imapUID = imapUID
        self.folder = folder
        self.messageIdHeader = ""
        self.inReplyTo = ""
        self.referencesHeader = ""
        self.fromAddr = ""
        self.toAddr = ""
        self.ccAddr = ""
        self.bccAddr = ""
        self.replyTo = ""
        self.subject = ""
        self.sentAt = nil
        self.snippet = ""
        self.bodyText = ""
        self.bodyHTML = ""
        self.seen = false
        self.flagged = false
        self.deleted = false
        self.answered = false
        self.hasAttachments = false
        self.labelsJSON = "[]"
        self.syncedAt = Date()
        self.attachments = []
    }
}

@Model
final class MailAttachment {
    var filename: String
    var mime: String
    var size: Int
    var data: Data?
    var savedRelativePath: String
    var message: MailMessage?

    init(filename: String, mime: String, data: Data?) {
        self.filename = filename
        self.mime = mime
        self.size = data?.count ?? 0
        self.data = data
        self.savedRelativePath = ""
    }
}

@Model
final class TimeEntry {
    var matter: Matter?
    var message: MailMessage?
    var startedAt: Date?
    var endedAt: Date?
    var minutes: Double
    var activity: String
    var entryDescription: String
    var billed: Bool
    var rate: Double
    var running: Bool
    var createdAt: Date
    var billingExternalID: String?
    var lawPayInvoiceSourceID: String?
    var lawPayInvoiceID: String?
    var lawPayInvoiceNumber: String?
    var lawPayStatus: String?
    var lawPaySyncedAt: Date?
    var lawPayError: String?

    init(minutes: Double = 0, activity: String = "email", description: String = "") {
        self.minutes = minutes
        self.activity = activity
        self.entryDescription = description
        self.billed = false
        self.rate = 0
        self.running = false
        self.createdAt = Date()
        self.billingExternalID = nil
        self.lawPayInvoiceSourceID = nil
        self.lawPayInvoiceID = nil
        self.lawPayInvoiceNumber = nil
        self.lawPayStatus = nil
        self.lawPaySyncedAt = nil
        self.lawPayError = nil
    }

    var fee: Double { minutes / 60.0 * rate }
}

@Model
final class PracticeNote {
    var matter: Matter?
    var title: String
    var body: String
    var createdAt: Date
    var updatedAt: Date

    init(title: String, body: String) {
        self.title = title
        self.body = body
        self.createdAt = Date()
        self.updatedAt = Date()
    }
}

@Model
final class CalendarEvent {
    var matter: Matter?
    var message: MailMessage?
    var title: String
    var eventType: String
    var startAt: Date
    var endAt: Date?
    var allDay: Bool
    var location: String
    var ruleCite: String
    var source: String
    var notes: String
    var remindMinutes: Int
    var dismissed: Bool
    var createdAt: Date

    init(title: String, startAt: Date, eventType: String = "appointment", allDay: Bool = true) {
        self.title = title
        self.eventType = eventType
        self.startAt = startAt
        self.endAt = nil
        self.allDay = allDay
        self.location = ""
        self.ruleCite = ""
        self.source = "manual"
        self.notes = ""
        self.remindMinutes = 30
        self.dismissed = false
        self.createdAt = Date()
    }
}

@Model
final class MatterFile {
    var matter: Matter?
    var message: MailMessage?
    var filename: String
    var relativePath: String
    var source: String
    var sourceURL: String
    var docType: String
    var createdAt: Date

    init(filename: String, relativePath: String, docType: String, source: String) {
        self.filename = filename
        self.relativePath = relativePath
        self.docType = docType
        self.source = source
        self.sourceURL = ""
        self.createdAt = Date()
    }
}

@Model
final class Person {
    var name: String
    var email: String
    var phone: String
    var firm: String
    var notes: String
    var matter: Matter?
    var createdAt: Date

    init(email: String, name: String = "") {
        self.email = email.lowercased()
        self.name = name
        self.phone = ""
        self.firm = ""
        self.notes = ""
        self.createdAt = Date()
    }
}

@Model
final class MailSignature {
    var name: String
    var body: String
    var isDefault: Bool
    var createdAt: Date

    init(name: String, body: String, isDefault: Bool) {
        self.name = name
        self.body = body
        self.isDefault = isDefault
        self.createdAt = Date()
    }
}

@Model
final class AppSetting {
    var key: String
    var value: String

    init(key: String, value: String) {
        self.key = key
        self.value = value
    }
}

enum DocType: String, CaseIterable, Identifiable {
    case correspondence, pleading, notice, discovery, financial, order, service, other
    var id: String { rawValue }
    var title: String {
        switch self {
        case .correspondence: return "Correspondence"
        case .pleading: return "Pleading"
        case .notice: return "Notice / hearing"
        case .discovery: return "Discovery"
        case .financial: return "Financial / disclosure"
        case .order: return "Order / judgment"
        case .service: return "Service / summons"
        case .other: return "Other"
        }
    }
}
