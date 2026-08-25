import Foundation

enum MailLabels {
    static func parse(_ json: String) -> [String] {
        guard let data = json.data(using: .utf8),
              let decoded = try? JSONDecoder().decode([String].self, from: data) else { return [] }
        return decoded.map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }.filter { !$0.isEmpty }
    }

    static func encode(_ tags: [String]) -> String {
        let clean = tags.map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }.filter { !$0.isEmpty }
        guard let data = try? JSONEncoder().encode(Array(Set(clean)).sorted()) else { return "[]" }
        return String(data: data, encoding: .utf8) ?? "[]"
    }
}

extension MailMessage {
    var tags: [String] {
        get { MailLabels.parse(labelsJSON) }
        set { labelsJSON = MailLabels.encode(newValue) }
    }

    var isLikelySpam: Bool {
        let f = folder.uppercased()
        return f == "JUNK" || f == "SPAM" || f.contains("JUNK") || f.contains("SPAM")
    }

    func addTag(_ raw: String) {
        let tag = MailTagCatalog.normalize(raw)
        guard !tag.isEmpty else { return }
        var next = tags
        guard !next.contains(tag) else { return }
        next.append(tag)
        tags = next
    }

    func removeTag(_ tag: String) {
        tags = tags.filter { $0 != tag }
    }
}
