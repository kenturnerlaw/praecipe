import Foundation

struct ParsedMail {
    var messageId: String = ""
    var inReplyTo: String = ""
    var references: String = ""
    var from: String = ""
    var to: String = ""
    var cc: String = ""
    var bcc: String = ""
    var replyTo: String = ""
    var subject: String = ""
    var date: Date?
    var text: String = ""
    var html: String = ""
    var attachments: [(filename: String, mime: String, data: Data)] = []
}

enum RFC822 {
    static func parse(_ data: Data) -> ParsedMail {
        let raw = String(data: data, encoding: .utf8)
            ?? String(data: data, encoding: .isoLatin1)
            ?? String(decoding: data, as: UTF8.self)
        let split = splitHeaderBody(raw)
        var mail = ParsedMail()
        let headers = unfold(split.headers)
        mail.messageId = header(headers, "message-id")
        mail.inReplyTo = header(headers, "in-reply-to")
        mail.references = header(headers, "references")
        mail.from = header(headers, "from")
        mail.to = header(headers, "to")
        mail.cc = header(headers, "cc")
        mail.bcc = header(headers, "bcc")
        mail.replyTo = header(headers, "reply-to")
        mail.subject = decodeWords(header(headers, "subject"))
        mail.date = parseDate(header(headers, "date"))
        let ctype = header(headers, "content-type")
        let encoding = header(headers, "content-transfer-encoding")
        parseBody(split.body, contentType: ctype, encoding: encoding, into: &mail)
        if mail.text.isEmpty, mail.html.isEmpty {
            mail.text = split.body.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return mail
    }

    static func buildRaw(from: String, to: [String], cc: [String] = [], subject: String, body: String, inReplyTo: String = "", references: String = "") -> String {
        let id = "<\(UUID().uuidString)@praecipe.local>"
        var lines = [
            "From: \(from)",
            "To: \(to.joined(separator: ", "))",
        ]
        if !cc.isEmpty { lines.append("Cc: \(cc.joined(separator: ", "))") }
        lines.append("Subject: \(subject)")
        lines.append("Date: \(imfDate(Date()))")
        lines.append("Message-ID: \(id)")
        lines.append("MIME-Version: 1.0")
        lines.append("Content-Type: text/plain; charset=utf-8")
        if !inReplyTo.isEmpty { lines.append("In-Reply-To: \(inReplyTo)") }
        if !references.isEmpty { lines.append("References: \(references)") }
        lines.append("")
        lines.append(body.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\n", with: "\r\n"))
        return lines.joined(separator: "\r\n")
    }

    private static func imfDate(_ date: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "EEE, dd MMM yyyy HH:mm:ss Z"
        return f.string(from: date)
    }

    private static func splitHeaderBody(_ raw: String) -> (headers: String, body: String) {
        let n = raw.replacingOccurrences(of: "\r\n", with: "\n")
        if let r = n.range(of: "\n\n") {
            return (String(n[..<r.lowerBound]), String(n[r.upperBound...]))
        }
        return (n, "")
    }

    private static func unfold(_ headers: String) -> [String: String] {
        var map: [String: String] = [:]
        var current = ""
        for line in headers.components(separatedBy: "\n") {
            if line.first?.isWhitespace == true {
                current += " " + line.trimmingCharacters(in: .whitespaces)
            } else {
                store(&map, current)
                current = line
            }
        }
        store(&map, current)
        return map
    }

    private static func store(_ map: inout [String: String], _ line: String) {
        guard let i = line.firstIndex(of: ":") else { return }
        let key = line[..<i].lowercased().trimmingCharacters(in: .whitespaces)
        let val = line[line.index(after: i)...].trimmingCharacters(in: .whitespaces)
        if map[key] == nil { map[key] = val }
    }

    private static func header(_ map: [String: String], _ name: String) -> String {
        map[name] ?? ""
    }

    private static func parseBody(_ body: String, contentType: String, encoding: String, into mail: inout ParsedMail) {
        let lower = contentType.lowercased()
        if lower.contains("multipart/") {
            guard let boundary = boundaryValue(contentType) else { return }
            let parts = splitMultipart(body, boundary: boundary)
            for part in parts {
                let split = splitHeaderBody(part)
                let h = unfold(split.headers)
                let ct = h["content-type"] ?? "text/plain"
                let enc = h["content-transfer-encoding"] ?? ""
                let disp = h["content-disposition"] ?? ""
                let decoded = decodeBody(split.body, encoding: enc)
                if disp.lowercased().contains("attachment") || filename(from: disp, contentType: ct) != nil && !ct.lowercased().contains("text/") {
                    let name = filename(from: disp, contentType: ct) ?? "attachment"
                    mail.attachments.append((name, mimeOnly(ct), decoded))
                } else if ct.lowercased().contains("text/html") {
                    mail.html = String(data: decoded, encoding: .utf8) ?? String(decoding: decoded, as: UTF8.self)
                } else if ct.lowercased().contains("text/plain") {
                    mail.text = String(data: decoded, encoding: .utf8) ?? String(decoding: decoded, as: UTF8.self)
                } else if ct.lowercased().contains("multipart/") {
                    parseBody(split.body, contentType: ct, encoding: enc, into: &mail)
                } else if let name = filename(from: disp, contentType: ct) {
                    mail.attachments.append((name, mimeOnly(ct), decoded))
                }
            }
            return
        }
        let decoded = decodeBody(body, encoding: encoding)
        let text = String(data: decoded, encoding: .utf8) ?? String(decoding: decoded, as: UTF8.self)
        if lower.contains("text/html") { mail.html = text } else { mail.text = text }
    }

    private static func mimeOnly(_ ct: String) -> String {
        ct.split(separator: ";").first.map { $0.trimmingCharacters(in: .whitespaces) } ?? "application/octet-stream"
    }

    private static func filename(from disposition: String, contentType: String) -> String? {
        for src in [disposition, contentType] {
            if let r = src.range(of: "filename=", options: .caseInsensitive) {
                var v = src[r.upperBound...].trimmingCharacters(in: .whitespaces)
                if let sc = v.firstIndex(of: ";") { v = String(v[..<sc]) }
                v = v.trimmingCharacters(in: CharacterSet(charactersIn: "\""))
                if !v.isEmpty { return v }
            }
        }
        return nil
    }

    private static func boundaryValue(_ contentType: String) -> String? {
        guard let r = contentType.range(of: "boundary=", options: .caseInsensitive) else { return nil }
        var v = contentType[r.upperBound...].trimmingCharacters(in: .whitespaces)
        if let sc = v.firstIndex(of: ";") { v = String(v[..<sc]) }
        return v.trimmingCharacters(in: CharacterSet(charactersIn: "\""))
    }

    private static func splitMultipart(_ body: String, boundary: String) -> [String] {
        let token = "--" + boundary
        return body.components(separatedBy: token)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && $0 != "--" && !$0.hasPrefix("--") }
    }

    private static func decodeBody(_ body: String, encoding: String) -> Data {
        let trimmed = body.replacingOccurrences(of: "\r\n", with: "\n")
        switch encoding.lowercased() {
        case "base64":
            let compact = trimmed.filter { !$0.isWhitespace }
            return Data(base64Encoded: compact) ?? Data(trimmed.utf8)
        case "quoted-printable":
            return decodeQP(trimmed)
        default:
            return Data(trimmed.utf8)
        }
    }

    private static func decodeQP(_ s: String) -> Data {
        var out = Data()
        let chars = Array(s)
        var i = 0
        while i < chars.count {
            if chars[i] == "=" {
                if i + 1 < chars.count && chars[i + 1] == "\n" {
                    i += 2
                    continue
                }
                if i + 2 < chars.count, let b = UInt8(String(chars[i+1...i+2]), radix: 16) {
                    out.append(b)
                    i += 3
                    continue
                }
            }
            if let v = chars[i].asciiValue { out.append(v) }
            i += 1
        }
        return out
    }

    private static func decodeWords(_ s: String) -> String {
        var result = s
        let pattern = try? NSRegularExpression(pattern: "=\\?([^?]+)\\?([bqBQ])\\?([^?]+)\\?=")
        let ns = s as NSString
        pattern?.matches(in: s, range: NSRange(location: 0, length: ns.length)).reversed().forEach { m in
            let charset = ns.substring(with: m.range(at: 1))
            let scheme = ns.substring(with: m.range(at: 2)).lowercased()
            let payload = ns.substring(with: m.range(at: 3))
            var data = Data()
            if scheme == "b" {
                data = Data(base64Encoded: payload) ?? Data()
            } else {
                data = decodeQP(payload.replacingOccurrences(of: "_", with: " "))
            }
            let decoded = String(data: data, encoding: encoding(charset)) ?? String(decoding: data, as: UTF8.self)
            if let r = Range(m.range, in: result) {
                result.replaceSubrange(r, with: decoded)
            }
        }
        return result
    }

    private static func encoding(_ name: String) -> String.Encoding {
        switch name.lowercased() {
        case "utf-8": return .utf8
        case "iso-8859-1", "latin-1": return .isoLatin1
        default: return .utf8
        }
    }

    private static func parseDate(_ s: String) -> Date? {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        for fmt in ["EEE, dd MMM yyyy HH:mm:ss Z", "dd MMM yyyy HH:mm:ss Z", "EEE, d MMM yyyy HH:mm:ss Z"] {
            f.dateFormat = fmt
            if let d = f.date(from: s) { return d }
        }
        return nil
    }
}
