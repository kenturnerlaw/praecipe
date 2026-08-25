import Foundation

struct MailFolderItem: Identifiable, Hashable {
    var id: String { role }
    let role: String
    let imapName: String?
    let displayName: String
    let systemImage: String

    var isVirtual: Bool { imapName == nil }
}

enum MailFolders {
    private static let standardOrder: [(role: String, hints: [String], display: String, icon: String)] = [
        ("INBOX", ["INBOX"], "Inbox", "tray"),
        ("DRAFTS", ["Drafts", "Draft", "[Gmail]/Drafts"], "Drafts", "doc.text"),
        ("SENT", ["Sent", "Sent Items", "Sent Messages", "[Gmail]/Sent Mail", "SENT"], "Sent", "paperplane"),
        ("JUNK", ["Junk Email", "Junk", "Spam", "Junk E-mail", "[Gmail]/Spam"], "Junk", "xmark.bin"),
        ("TRASH", ["Deleted Items", "Trash", "Deleted", "[Gmail]/Trash"], "Trash", "trash"),
        ("ARCHIVE", ["Archive", "[Gmail]/All Mail", "All Mail"], "Archive", "archivebox"),
    ]

    static func role(for imapName: String) -> String {
        let n = imapName.lowercased()
        if n == "inbox" { return "INBOX" }
        if n.contains("draft") { return "DRAFTS" }
        if n.contains("sent") { return "SENT" }
        if n.contains("junk") || n.contains("spam") { return "JUNK" }
        if n.contains("trash") || n.contains("deleted") { return "TRASH" }
        if n.contains("archive") || n.contains("all mail") { return "ARCHIVE" }
        return imapName
    }

    static func displayName(for role: String) -> String {
        switch role.uppercased() {
        case "INBOX": return "Inbox"
        case "SENT": return "Sent"
        case "DRAFTS": return "Drafts"
        case "JUNK", "SPAM": return "Junk"
        case "TRASH": return "Trash"
        case "ARCHIVE": return "Archive"
        case "FLAGGED": return "Flagged"
        default:
            if role.contains("/") { return role.split(separator: "/").last.map(String.init) ?? role }
            return role
        }
    }

    static func systemImage(for role: String) -> String {
        switch role.uppercased() {
        case "INBOX": return "tray"
        case "SENT": return "paperplane"
        case "DRAFTS": return "doc.text"
        case "JUNK", "SPAM": return "xmark.bin"
        case "TRASH": return "trash"
        case "ARCHIVE": return "archivebox"
        case "FLAGGED": return "flag"
        default: return "folder"
        }
    }

    static func build(from imapNames: [String]) -> [MailFolderItem] {
        var items: [MailFolderItem] = []
        var matchedIMAP = Set<String>()

        for std in standardOrder {
            if let imap = pickMailbox(imapNames, hints: std.hints) {
                items.append(MailFolderItem(role: std.role, imapName: imap, displayName: std.display, systemImage: std.icon))
                matchedIMAP.insert(imap.lowercased())
            }
        }

        let standardRoles = Set(standardOrder.map(\.role))
        for name in imapNames.sorted(by: { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }) {
            if matchedIMAP.contains(name.lowercased()) { continue }
            let mapped = role(for: name)
            if standardRoles.contains(mapped), items.contains(where: { $0.role == mapped }) { continue }
            items.append(MailFolderItem(
                role: mapped,
                imapName: name,
                displayName: displayName(for: mapped == name ? name : mapped),
                systemImage: systemImage(for: mapped)
            ))
        }

        items.append(MailFolderItem(role: "FLAGGED", imapName: nil, displayName: "Flagged", systemImage: "flag"))
        return items
    }

    static func fallback() -> [MailFolderItem] {
        standardOrder.map {
            MailFolderItem(role: $0.role, imapName: $0.hints.first, displayName: $0.display, systemImage: $0.icon)
        } + [MailFolderItem(role: "FLAGGED", imapName: nil, displayName: "Flagged", systemImage: "flag")]
    }

    static func item(forRole role: String, in folders: [MailFolderItem]) -> MailFolderItem? {
        folders.first { $0.role == role }
    }

    static func imapName(forRole role: String, in folders: [MailFolderItem]) -> String? {
        item(forRole: role, in: folders)?.imapName
    }

    private static func pickMailbox(_ boxes: [String], hints: [String]) -> String? {
        for hint in hints {
            if let hit = boxes.first(where: { $0.caseInsensitiveCompare(hint) == .orderedSame }) {
                return hit
            }
        }
        for hint in hints {
            let h = hint.lowercased()
            if let hit = boxes.first(where: { $0.lowercased().contains(h) }) {
                return hit
            }
        }
        return nil
    }
}
