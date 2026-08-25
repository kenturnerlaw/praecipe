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
    var selectedFolderRole: String
    var selectedFolderIMAP: String

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
        self.selectedFolderRole = "INBOX"
        self.selectedFolderIMAP = "INBOX"
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
    /// Destrier-style case type (e.g. "DOM - Dissolution of Marriage").
    var caseType: String
    var createdAt: Date

    init(caseNo: String = "", style: String = "", status: String = "Open") {
        self.caseNo = caseNo
        self.petitioner = ""
        self.respondent = ""
        self.style = style
        self.court = "Circuit Court"
        self.county = "Collier"
        self.division = "Family"
        self.status = status
        self.opposingCounsel = ""
        self.clientEmail = ""
        self.clientName = ""
        self.rate = 350
        self.notes = ""
        self.caseType = CaseType.dom.rawValue
        self.createdAt = Date()
    }

    var label: String {
        if !caseNo.isEmpty { return "\(caseNo) — \(style.isEmpty ? "Matter" : style)" }
        if !style.isEmpty { return style }
        if !caseType.isEmpty {
            let code = caseType.components(separatedBy: " - ").first ?? caseType
            return "\(code) · \(county.isEmpty ? "Matter" : county)"
        }
        return "Matter"
    }

    var isIntake: Bool {
        caseNo.trimmingCharacters(in: .whitespacesAndNewlines).uppercased() == "INTAKE"
    }
}

enum CaseType: String, CaseIterable, Identifiable {
    case dom = "DOM - Dissolution of Marriage"
    case pat = "PAT - Paternity"
    case mod = "MOD - Modification"
    case enf = "ENF - Enforcement / Contempt"
    case sup = "SUP - Support"
    case inj = "INJ - Injunction"
    case adp = "ADP - Adoption"
    case oth = "OTH - Other"
    var id: String { rawValue }
    var code: String { rawValue.components(separatedBy: " - ").first ?? rawValue }
}

enum FloridaCounties {
    static let all = [
        "Alachua", "Baker", "Bay", "Bradford", "Brevard", "Broward", "Calhoun", "Charlotte",
        "Citrus", "Clay", "Collier", "Columbia", "DeSoto", "Dixie", "Duval", "Escambia",
        "Flagler", "Franklin", "Gadsden", "Gilchrist", "Glades", "Gulf", "Hamilton", "Hardee",
        "Hendry", "Hernando", "Highlands", "Hillsborough", "Holmes", "Indian River", "Jackson",
        "Jefferson", "Lafayette", "Lake", "Lee", "Leon", "Levy", "Liberty", "Madison", "Manatee",
        "Marion", "Martin", "Miami-Dade", "Monroe", "Nassau", "Okaloosa", "Okeechobee", "Orange",
        "Osceola", "Palm Beach", "Pasco", "Pinellas", "Polk", "Putnam", "Santa Rosa", "Sarasota",
        "Seminole", "St. Johns", "St. Lucie", "Sumter", "Suwannee", "Taylor", "Union", "Volusia",
        "Wakulla", "Walton", "Washington",
    ]
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
    /// True once File & Bill (or message detail) has recorded time for this email — blocks a second time entry.
    var timeBilled: Bool
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
        self.timeBilled = false
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

    init(minutes: Double = 0, activity: String = "email", description: String = "") {
        self.minutes = minutes
        self.activity = activity
        self.entryDescription = description
        self.billed = false
        self.rate = 0
        self.running = false
        self.createdAt = Date()
    }

    var fee: Double { minutes / 60.0 * rate }

    var hours: Double { LegalTime.hours(fromMinutes: minutes) }

    func setHours(_ hours: Double) {
        minutes = LegalTime.minutes(fromHours: hours)
    }
}

enum LegalTime {
    static let defaultHours: Double = 0.2
    static let minimumHours: Double = 0.1
    static let increment: Double = 0.1

    static func minutes(fromHours hours: Double) -> Double {
        max(minimumHours, hours) * 60
    }

    static func hours(fromMinutes minutes: Double) -> Double {
        guard minutes > 0 else { return 0 }
        let tenths = (minutes / 60 * 10).rounded()
        return max(minimumHours, tenths / 10)
    }

    static func roundMinutes(_ rawMinutes: Double) -> Double {
        LegalTime.minutes(fromHours: hours(fromMinutes: rawMinutes))
    }

    static func displayHours(_ hours: Double) -> String {
        String(format: "%.1f hr", hours)
    }

    static func displayMinutes(fromHours hours: Double) -> String {
        "\(Int((hours * 60).rounded())) min"
    }

    static func displayBoth(_ hours: Double) -> String {
        "\(displayHours(hours)) (\(displayMinutes(fromHours: hours)))"
    }
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
    @Attribute(.unique) var key: String
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
