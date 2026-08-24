import Foundation

enum MailError: LocalizedError {
    case connect(String)
    case auth(String)
    case protocolFailure(String)

    var errorDescription: String? {
        switch self {
        case .connect(let s), .auth(let s), .protocolFailure(let s): return s
        }
    }
}

struct IMAPEnvelope {
    var uid: String
    var flags: [String]
    var rfc822: Data
}

enum MailDeleteResult {
    case movedToTrash

    var confirmation: String {
        "Moved to Trash."
    }
}

private struct IMAPMailboxList {
    var names: [String]
    var specialTrash: String?
}

/// IMAP (993 TLS) and SMTP (465 SSL or 587 STARTTLS) for app-password accounts.
actor MailTransport {
    func testIMAP(host: String, port: Int, user: String, password: String, oauthToken: String? = nil) async throws {
        let conn = try MailStream.connect(host: host, port: port, tls: .implicit)
        defer { conn.close() }
        _ = try conn.readLine()
        try imapLogin(conn, user: user, password: password, oauthToken: oauthToken)
        guard try imapOK(conn, "SELECT INBOX") else {
            throw MailError.protocolFailure("Signed in, but the Inbox could not be opened. Check that IMAP is enabled for this mailbox.")
        }
        _ = try? conn.command("LOGOUT")
    }

    func fetchLatest(host: String, port: Int, user: String, password: String, oauthToken: String? = nil, folder: String, afterUID: Int, limit: Int = 50) async throws -> (Bool, [IMAPEnvelope], [String]) {
        let conn = try MailStream.connect(host: host, port: port, tls: .implicit)
        defer { conn.close() }
        _ = try conn.readLine()
        try imapLogin(conn, user: user, password: password, oauthToken: oauthToken)
        let listing = try imapList(conn)
        let boxes = listing.names
        let selectName = resolveMailbox(folder, in: boxes) ?? folder
        guard try imapOK(conn, "SELECT \(imapQuote(selectName))") else {
            _ = try? conn.command("LOGOUT")
            return (false, [], boxes)
        }
        let uids = try imapSearch(conn, afterUID: afterUID)
        var out: [IMAPEnvelope] = []
        for uid in uids.suffix(limit) {
            if let env = try imapFetch(conn, uid: uid) { out.append(env) }
        }
        _ = try? conn.command("LOGOUT")
        return (true, out, boxes)
    }

    func setFlag(host: String, port: Int, user: String, password: String, oauthToken: String? = nil, folder: String, uid: String, flag: String, add: Bool) async throws {
        guard uid.allSatisfy(\.isNumber), !uid.isEmpty else {
            throw MailError.protocolFailure("This message has an invalid mailbox identifier.")
        }
        let conn = try MailStream.connect(host: host, port: port, tls: .implicit)
        defer { conn.close() }
        _ = try conn.readLine()
        try imapLogin(conn, user: user, password: password, oauthToken: oauthToken)
        let boxes = try imapList(conn).names
        let selected = resolveMailbox(folder, in: boxes) ?? folder
        guard try imapOK(conn, "SELECT \(imapQuote(selected))") else {
            throw MailError.protocolFailure("The mailbox folder could not be opened.")
        }
        let op = add ? "+FLAGS.SILENT" : "-FLAGS.SILENT"
        guard isOK(try conn.command("UID STORE \(uid) \(op) (\(flag))")) else {
            throw MailError.protocolFailure("The mail server did not update the message.")
        }
        _ = try? conn.command("LOGOUT")
    }

    func deleteMessage(host: String, port: Int, user: String, password: String, oauthToken: String? = nil, folder: String, uid: String) async throws -> MailDeleteResult {
        guard uid.allSatisfy(\.isNumber), !uid.isEmpty else {
            throw MailError.protocolFailure("This message has an invalid mailbox identifier.")
        }
        let conn = try MailStream.connect(host: host, port: port, tls: .implicit)
        defer { conn.close() }
        _ = try conn.readLine()
        try imapLogin(conn, user: user, password: password, oauthToken: oauthToken)

        let capability = (try? conn.command("CAPABILITY"))?.uppercased() ?? ""
        let listing = try imapList(conn)
        let boxes = listing.names
        let selected = resolveMailbox(folder, in: boxes) ?? folder
        guard try imapOK(conn, "SELECT \(imapQuote(selected))") else {
            throw MailError.protocolFailure("The mailbox folder could not be opened.")
        }
        let supportsUIDExpunge = capability.contains("UIDPLUS")
        let alreadyDeleted = supportsUIDExpunge ? [] : (try? imapDeletedUIDs(conn)) ?? []
        let safeToExpungeFolder = supportsUIDExpunge || alreadyDeleted.allSatisfy { String($0) == uid }

        guard let trash = listing.specialTrash ?? trashMailbox(in: boxes), trash.caseInsensitiveCompare(selected) != .orderedSame else {
            throw MailError.protocolFailure("The mail server did not provide a Trash folder, so the message was not deleted.")
        }
        if isOK(try conn.command("UID MOVE \(uid) \(imapQuote(trash))")) {
            _ = try? conn.command("LOGOUT")
            return .movedToTrash
        }

        // RFC 6851 MOVE is not universal. COPY + \Deleted provides the same
        // recoverable result, but only when this message can be expunged alone.
        if safeToExpungeFolder, isOK(try conn.command("UID COPY \(uid) \(imapQuote(trash))")) {
            guard isOK(try conn.command("UID STORE \(uid) +FLAGS.SILENT (\\Deleted)")) else {
                throw MailError.protocolFailure("The message was copied to Trash, but the original could not be removed.")
            }
            let expunge = supportsUIDExpunge ? "UID EXPUNGE \(uid)" : "EXPUNGE"
            guard isOK(try conn.command(expunge)) else {
                throw MailError.protocolFailure("The original message could not be removed after it was copied to Trash.")
            }
            _ = try? conn.command("LOGOUT")
            return .movedToTrash
        }
        throw MailError.protocolFailure("The mail server could not safely move this message to Trash.")
    }

    func sendMail(host: String, port: Int, tls: String, user: String, password: String, oauthToken: String? = nil, from: String, to: [String], raw: String) async throws {
        let mode: MailStream.TLSMode = tls == "ssl" ? .implicit : .plainThenSTARTTLS
        let conn = try MailStream.connect(host: host, port: port, tls: mode)
        defer { conn.close() }
        _ = try conn.readSMTP()
        _ = try conn.smtp("EHLO praecipe.local")
        if mode == .plainThenSTARTTLS {
            let start = try conn.smtp("STARTTLS")
            if !start.hasPrefix("220") { throw MailError.protocolFailure("STARTTLS refused: \(start)") }
            try conn.startTLS()
            _ = try conn.smtp("EHLO praecipe.local")
        }
        let auth: String
        if let oauthToken, !oauthToken.isEmpty {
            let xoauth = Data("user=\(user)\u{01}auth=Bearer \(oauthToken)\u{01}\u{01}".utf8).base64EncodedString()
            auth = try conn.smtp("AUTH XOAUTH2 \(xoauth)")
        } else {
            _ = try conn.smtp("AUTH LOGIN")
            _ = try conn.smtp(Data(user.utf8).base64EncodedString())
            auth = try conn.smtp(Data(password.utf8).base64EncodedString())
        }
        if !auth.hasPrefix("235") {
            let advice = oauthToken == nil ? " Check the app password." : " Open Settings and reconnect Microsoft."
            throw MailError.auth("SMTP authentication failed.\(advice)")
        }
        let mailFrom = try conn.smtp("MAIL FROM:<\(from)>")
        if !mailFrom.hasPrefix("250") { throw MailError.protocolFailure(mailFrom) }
        var acceptedRecipients = 0
        for addr in to where addr.contains("@") {
            let response = try conn.smtp("RCPT TO:<\(addr)>")
            if response.hasPrefix("250") || response.hasPrefix("251") { acceptedRecipients += 1 }
        }
        guard acceptedRecipients > 0 else { throw MailError.protocolFailure("The mail server rejected every recipient.") }
        let dataResponse = try conn.smtp("DATA")
        guard dataResponse.hasPrefix("354") else { throw MailError.protocolFailure("The mail server refused the message body: \(dataResponse)") }
        let escaped = raw.replacingOccurrences(of: "\n.", with: "\n..")
        let sentResponse = try conn.smtpRaw(escaped + "\r\n.")
        guard sentResponse.hasPrefix("250") else { throw MailError.protocolFailure("The mail server rejected the message: \(sentResponse)") }
        _ = try conn.smtp("QUIT")
    }

    private func imapLogin(_ conn: MailStream, user: String, password: String, oauthToken: String? = nil) throws {
        let r: String
        if let oauthToken, !oauthToken.isEmpty {
            let xoauth = Data("user=\(user)\u{01}auth=Bearer \(oauthToken)\u{01}\u{01}".utf8).base64EncodedString()
            r = try conn.command("AUTHENTICATE XOAUTH2 \(xoauth)")
        } else {
            r = try conn.command("LOGIN \(imapQuote(user)) \(imapQuote(password))")
        }
        guard r.components(separatedBy: "\n").last(where: { !$0.isEmpty })?.contains(" OK ") == true else {
            let advice = oauthToken == nil ? " Check the app password, not the regular account password." : " Open Settings and reconnect Microsoft."
            throw MailError.auth("IMAP authentication failed.\(advice)")
        }
    }

    private func imapList(_ conn: MailStream) throws -> IMAPMailboxList {
        let r = try conn.command("LIST \"\" \"*\"")
        var names: [String] = []
        var specialTrash: String?
        for line in r.components(separatedBy: "\n") where line.hasPrefix("* LIST") {
            if let name = parseListName(line) {
                names.append(name)
                if line.uppercased().contains("\\TRASH") { specialTrash = name }
            }
        }
        return IMAPMailboxList(names: names, specialTrash: specialTrash)
    }

    private func imapOK(_ conn: MailStream, _ cmd: String) throws -> Bool {
        let r = try conn.command(cmd)
        return isOK(r)
    }

    private func isOK(_ response: String) -> Bool {
        response.components(separatedBy: "\n")
            .last(where: { !$0.isEmpty })?
            .uppercased()
            .contains(" OK ") == true
    }

    private func resolveMailbox(_ requested: String, in boxes: [String]) -> String? {
        if let exact = boxes.first(where: { $0.caseInsensitiveCompare(requested) == .orderedSame }) {
            return exact
        }
        let role = requested.lowercased()
        if role == "sent" {
            return boxes.first(where: { $0.lowercased().contains("sent") })
        }
        if role == "trash" || role.contains("deleted") {
            return trashMailbox(in: boxes)
        }
        return nil
    }

    private func trashMailbox(in boxes: [String]) -> String? {
        let preferred = ["deleted items", "trash", "deleted messages", "bin"]
        for name in preferred {
            if let exact = boxes.first(where: {
                let leaf = $0.lowercased().split(separator: "/").last.map(String.init) ?? $0.lowercased()
                return leaf == name
            }) { return exact }
        }
        return boxes.first(where: {
            let value = $0.lowercased()
            return value.contains("trash") || value.contains("deleted items") || value.contains("deleted messages")
        })
    }

    private func imapSearch(_ conn: MailStream, afterUID: Int) throws -> [Int] {
        let spec = afterUID > 0 ? "UID \(afterUID + 1):*" : "ALL"
        let r = try conn.command("UID SEARCH \(spec)")
        var uids: [Int] = []
        for line in r.components(separatedBy: "\n") where line.hasPrefix("* SEARCH") {
            for p in line.split(separator: " ").dropFirst(2) {
                if let n = Int(p) { uids.append(n) }
            }
        }
        return uids.sorted()
    }

    private func imapDeletedUIDs(_ conn: MailStream) throws -> [Int] {
        let response = try conn.command("UID SEARCH DELETED")
        var uids: [Int] = []
        for line in response.components(separatedBy: "\n") where line.hasPrefix("* SEARCH") {
            for part in line.split(separator: " ").dropFirst(2) {
                if let uid = Int(part) { uids.append(uid) }
            }
        }
        return uids
    }

    private func imapFetch(_ conn: MailStream, uid: Int) throws -> IMAPEnvelope? {
        let r = try conn.fetch("UID FETCH \(uid) (FLAGS RFC822)")
        guard let data = r.body, !data.isEmpty else { return nil }
        return IMAPEnvelope(uid: String(uid), flags: r.flags, rfc822: data)
    }
}

private func imapQuote(_ s: String) -> String {
    "\"" + s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
}

private func parseListName(_ line: String) -> String? {
    guard let start = line.lastIndex(of: "\"") else {
        return line.split(separator: " ").last.map(String.init)
    }
    let before = line[..<start]
    if let open = before.lastIndex(of: "\"") {
        return String(line[line.index(after: open)..<start]).replacingOccurrences(of: "\\\"", with: "\"")
    }
    return nil
}

final class MailStream: NSObject, StreamDelegate {
    enum TLSMode { case implicit, plainThenSTARTTLS }

    private var input: InputStream
    private var output: OutputStream
    private var buffer = Data()
    private var tag = 1
    private let lock = NSLock()

    private init(input: InputStream, output: OutputStream) {
        self.input = input
        self.output = output
    }

    static func connect(host: String, port: Int, tls: TLSMode) throws -> MailStream {
        var read: Unmanaged<CFReadStream>?
        var write: Unmanaged<CFWriteStream>?
        CFStreamCreatePairWithSocketToHost(nil, host as CFString, UInt32(port), &read, &write)
        guard let r = read?.takeRetainedValue(), let w = write?.takeRetainedValue() else {
            throw MailError.connect("Could not open \(host):\(port)")
        }
        let input = r as InputStream
        let output = w as OutputStream
        if tls == .implicit {
            let settings: [String: Any] = [
                kCFStreamSSLValidatesCertificateChain as String: kCFBooleanTrue as Any,
            ]
            input.setProperty(settings, forKey: kCFStreamPropertySSLSettings as Stream.PropertyKey)
            output.setProperty(settings, forKey: kCFStreamPropertySSLSettings as Stream.PropertyKey)
        }
        input.open()
        output.open()
        let deadline = Date().addingTimeInterval(20)
        while input.streamStatus == .opening || output.streamStatus == .opening {
            if Date() > deadline { throw MailError.connect("Timed out connecting to \(host)") }
            Thread.sleep(forTimeInterval: 0.05)
        }
        if input.streamStatus == .error || output.streamStatus == .error {
            throw MailError.connect("Could not connect to \(host):\(port)")
        }
        return MailStream(input: input, output: output)
    }

    func startTLS() throws {
        let settings: [String: Any] = [
            kCFStreamSSLValidatesCertificateChain as String: kCFBooleanTrue as Any,
        ]
        input.setProperty(settings, forKey: kCFStreamPropertySSLSettings as Stream.PropertyKey)
        output.setProperty(settings, forKey: kCFStreamPropertySSLSettings as Stream.PropertyKey)
        Thread.sleep(forTimeInterval: 0.2)
    }

    func close() {
        input.close()
        output.close()
    }

    func command(_ command: String) throws -> String {
        let t = "A\(tag)"
        tag += 1
        try write("\(t) \(command)\r\n")
        var collected = ""
        while true {
            let line = try readLine()
            collected += line + "\n"
            if line.hasPrefix("\(t) ") { return collected }
        }
    }

    struct FetchResult { var flags: [String]; var body: Data? }

    func fetch(_ command: String) throws -> FetchResult {
        let t = "A\(tag)"
        tag += 1
        try write("\(t) \(command)\r\n")
        var flags: [String] = []
        var body: Data?
        while true {
            let line = try readLine()
            if let r = line.range(of: "FLAGS ("), let end = line[r.upperBound...].firstIndex(of: ")") {
                flags = line[r.upperBound..<end].split(separator: " ").map { String($0).replacingOccurrences(of: "\\", with: "") }
            }
            if let n = literalSize(line) {
                let data = try readExact(n)
                if body == nil { body = data }
                continue
            }
            if line.hasPrefix("\(t) ") { break }
        }
        return FetchResult(flags: flags, body: body)
    }

    func readSMTP() throws -> String {
        var lines: [String] = []
        while true {
            let line = try readLine()
            lines.append(line)
            if line.count >= 4, Array(line)[3] != "-" { break }
        }
        return lines.joined(separator: "\n")
    }

    func smtp(_ command: String) throws -> String {
        try write(command + "\r\n")
        return try readSMTP()
    }

    func smtpRaw(_ payload: String) throws -> String {
        try write(payload + "\r\n")
        return try readSMTP()
    }

    func readLine() throws -> String {
        while true {
            if let range = buffer.range(of: Data("\r\n".utf8)) {
                let line = buffer.subdata(in: 0..<range.lowerBound)
                buffer.removeSubrange(0..<range.upperBound)
                return String(data: line, encoding: .utf8) ?? String(decoding: line, as: UTF8.self)
            }
            try readMore()
        }
    }

    private func literalSize(_ line: String) -> Int? {
        guard let open = line.lastIndex(of: "{"), let close = line.lastIndex(of: "}"), open < close else { return nil }
        return Int(line[line.index(after: open)..<close])
    }

    private func write(_ s: String) throws {
        var data = Array(s.utf8)
        while !data.isEmpty {
            let n = output.write(&data, maxLength: data.count)
            if n <= 0 { throw MailError.connect("Write failed") }
            data.removeFirst(n)
        }
    }

    private func readExact(_ n: Int) throws -> Data {
        while buffer.count < n { try readMore() }
        let data = buffer.prefix(n)
        buffer.removeSubrange(0..<n)
        if buffer.starts(with: Data("\r\n".utf8)) { buffer.removeSubrange(0..<2) }
        return Data(data)
    }

    private func readMore() throws {
        let deadline = Date().addingTimeInterval(30)
        var tmp = [UInt8](repeating: 0, count: 8192)
        while input.hasBytesAvailable == false && Date() < deadline {
            if input.streamStatus == .error || input.streamStatus == .closed {
                throw MailError.connect("Connection closed")
            }
            Thread.sleep(forTimeInterval: 0.05)
        }
        let n = input.read(&tmp, maxLength: tmp.count)
        if n <= 0 { throw MailError.connect("Read failed") }
        buffer.append(contentsOf: tmp.prefix(n))
    }
}
