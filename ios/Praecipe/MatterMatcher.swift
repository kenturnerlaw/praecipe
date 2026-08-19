import Foundation
import SwiftData

struct MatterMatch: Identifiable {
    var id: PersistentIdentifier { matter.persistentModelID }
    var matter: Matter
    var confidence: Int
    var reasons: [String]
    var label: String { matter.label }
}

enum MatterMatcher {
    static let stop: Set<String> = [
        "the", "and", "for", "vs", "v", "aka", "nka", "fka", "estate", "minor", "child",
        "unknown", "intake", "unassigned", "mail", "petitioner", "respondent",
    ]

    static func guessDocType(for message: MailMessage) -> DocType {
        let names = message.attachments.map(\.filename).joined(separator: " ")
        let text = normalize(blob(message) + " " + names)
        let rules: [(DocType, [String])] = [
            (.service, ["summons", "return of service", "proof of service", "served", "process server"]),
            (.financial, ["financial affidavit", "mandatory disclosure", "tax return", "pay stub", "w-2", "w2"]),
            (.discovery, ["interrogator", "request to produce", "request for admission", "deposition", "duces tecum"]),
            (.order, ["order", "judgment", "fiat", "decree"]),
            (.notice, ["notice of hearing", "notice of trial", "notice of mediation", "notice of taking"]),
            (.pleading, ["petition", "motion", "response", "answer", "counterpetition"]),
        ]
        for (kind, needles) in rules where needles.contains(where: { text.contains($0) }) {
            return kind
        }
        return message.attachments.isEmpty ? .correspondence : .pleading
    }

    static func match(message: MailMessage, matters: [Matter], priorFromSender: [PersistentIdentifier: Int], contactMatter: [String: PersistentIdentifier]) -> [MatterMatch] {
        let blobText = blob(message)
        let norm = normalize(blobText)
        let addrs = Set(emailAddresses(in: blobText))
        let from = emailAddresses(in: message.fromAddr).first ?? ""
        var scored: [MatterMatch] = []
        for m in matters where m.status != "closed" {
            var reasons: [String] = []
            var score = 0
            let caseNo = m.caseNo.trimmingCharacters(in: .whitespaces)
            if !caseNo.isEmpty && caseNo.uppercased() != "INTAKE" {
                let compact = caseNo.uppercased().replacingOccurrences(of: "[\\s-]", with: "", options: .regularExpression)
                let rawCompact = blobText.uppercased().replacingOccurrences(of: "[\\s-]", with: "", options: .regularExpression)
                if !compact.isEmpty && rawCompact.contains(compact) {
                    score += 55
                    reasons.append("case number \(caseNo)")
                }
            }
            let pet = lastName(m.petitioner)
            let resp = lastName(m.respondent)
            var nameHits = 0
            if pet.count >= 3, word(pet, in: norm) { nameHits += 1; reasons.append("petitioner “\(pet)”") }
            if resp.count >= 3, word(resp, in: norm) { nameHits += 1; reasons.append("respondent “\(resp)”") }
            if nameHits == 2 { score += 40 } else if nameHits == 1 { score += 18 }
            let style = normalize(m.style)
            if style.count > 8 && norm.contains(style) {
                score += 20
                reasons.append("caption")
            }
            let oc = normalize(m.opposingCounsel)
            if oc.count > 4 && norm.contains(oc) {
                score += 15
                reasons.append("opposing counsel")
            }
            if let n = priorFromSender[m.persistentModelID], n > 0 {
                score += min(30, 12 + n * 3)
                reasons.append("prior mail from this sender (\(n))")
            }
            if !from.isEmpty, contactMatter[from] == m.persistentModelID {
                score += 25
                reasons.append("contact \(from)")
            }
            let client = m.clientEmail.lowercased()
            if !client.isEmpty && addrs.contains(client) {
                score += 20
                reasons.append("client on the thread")
            }
            if caseNo.uppercased() == "INTAKE" {
                score = min(score, 12)
                if reasons.isEmpty { reasons.append("intake fallback") }
            }
            score = max(0, min(99, score))
            if score <= 0 && caseNo.uppercased() == "INTAKE" {
                score = 8
                reasons.append("intake fallback")
            }
            if score > 0 {
                scored.append(MatterMatch(matter: m, confidence: score, reasons: reasons))
            }
        }
        return scored.sorted { $0.confidence > $1.confidence }.prefix(5).map { $0 }
    }

    static func priorCounts(messages: [MailMessage], from: String) -> [PersistentIdentifier: Int] {
        guard !from.isEmpty else { return [:] }
        var map: [PersistentIdentifier: Int] = [:]
        for msg in messages {
            guard let matter = msg.matter else { continue }
            if emailAddresses(in: msg.fromAddr).contains(from) {
                map[matter.persistentModelID, default: 0] += 1
            }
        }
        return map
    }

    private static func blob(_ m: MailMessage) -> String {
        [m.subject, m.fromAddr, m.toAddr, m.ccAddr, m.snippet, m.bodyText].joined(separator: " ")
    }

    private static func normalize(_ s: String) -> String {
        s.lowercased().replacingOccurrences(of: "[^a-z0-9]+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func lastName(_ party: String) -> String {
        if party.contains(",") {
            return normalize(party.split(separator: ",").first.map(String.init) ?? "").split(separator: " ").first.map(String.init) ?? ""
        }
        let parts = normalize(party).split(separator: " ").map(String.init).filter { !stop.contains($0) && $0.count > 2 }
        return parts.last ?? ""
    }

    private static func word(_ w: String, in blob: String) -> Bool {
        blob.split(separator: " ").contains(where: { $0 == w })
    }
}

enum MailExtract {
    static let serviceHosts = [
        "myflcourtaccess.com", "flcourts.org", "clerk", "e-portal", "eportal",
        "sharefile", "onedrive", "dropbox.com", "box.com", "filevine", "clio",
        "proofserve", "provest", "serve-now", "servenow",
    ]

    struct FoundURL: Identifiable {
        let id = UUID()
        let url: URL
        let serviceLikely: Bool
    }

    struct FoundEvent: Identifiable {
        let id = UUID()
        let title: String
        let date: Date
        let eventType: String
        let context: String
    }

    static func urls(in message: MailMessage) -> [FoundURL] {
        let text = message.bodyText + " " + message.bodyHTML
        let pattern = try? NSRegularExpression(pattern: "https?://[^\\s<>\"')\\]]+", options: .caseInsensitive)
        let ns = text as NSString
        let matches = pattern?.matches(in: text, range: NSRange(location: 0, length: ns.length)) ?? []
        var seen = Set<String>()
        var out: [FoundURL] = []
        for m in matches {
            let s = ns.substring(with: m.range).trimmingCharacters(in: CharacterSet(charactersIn: ".,);"))
            guard seen.insert(s).inserted, let url = URL(string: s) else { continue }
            let host = url.host?.lowercased() ?? ""
            let likely = serviceHosts.contains { host.contains($0) }
            out.append(FoundURL(url: url, serviceLikely: likely))
        }
        return out
    }
}
