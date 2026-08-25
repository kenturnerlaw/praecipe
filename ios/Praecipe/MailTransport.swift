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

enum MailCredentials {
    case password(String)
    case oauth(accessToken: String)
}

/// IMAP (993 TLS) and SMTP (465 SSL or 587 STARTTLS). Microsoft 365 uses XOAUTH2, not LOGIN.
actor MailTransport {
    func fetchLatest(host: String, port: Int, user: String, credentials: MailCredentials, folder: String, afterUID: Int, limit: Int = 50) async throws -> (Bool, [IMAPEnvelope], [String]) {
        let conn = try MailStream.connect(host: host, port: port, tls: .implicit)
        defer { conn.close() }
        _ = try conn.readLine()
        try imapSignIn(conn, user: user, credentials: credentials)
        let boxes = try imapList(conn)
        let selectName = boxes.first(where: { $0.caseInsensitiveCompare(folder) == .orderedSame }) ?? folder
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

    func verify(host: String, port: Int, user: String, credentials: MailCredentials) async throws {
        let conn = try MailStream.connect(host: host, port: port, tls: .implicit)
        defer { conn.close() }
        _ = try conn.readLine()
        try imapSignIn(conn, user: user, credentials: credentials)
        guard try imapOK(conn, "SELECT \(imapQuote("INBOX"))") else {
            throw MailError.protocolFailure("Signed in, but Inbox would not open.")
        }
        _ = try? conn.command("LOGOUT")
    }

    func listMailboxes(host: String, port: Int, user: String, credentials: MailCredentials) async throws -> [String] {
        let conn = try MailStream.connect(host: host, port: port, tls: .implicit)
        defer { conn.close() }
        _ = try conn.readLine()
        try imapSignIn(conn, user: user, credentials: credentials)
        let boxes = try imapList(conn)
        _ = try? conn.command("LOGOUT")
        return boxes.sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
    }

    func setFlag(host: String, port: Int, user: String, credentials: MailCredentials, folder: String, uid: String, flag: String, add: Bool) async throws {
        let conn = try MailStream.connect(host: host, port: port, tls: .implicit)
        defer { conn.close() }
        _ = try conn.readLine()
        try imapSignIn(conn, user: user, credentials: credentials)
        _ = try imapOK(conn, "SELECT \(imapQuote(folder))")
        let op = add ? "+FLAGS.SILENT" : "-FLAGS.SILENT"
        _ = try conn.command("UID STORE \(uid) \(op) (\(flag))")
        _ = try? conn.command("LOGOUT")
    }

    /// Move a message to Junk/Spam or Trash. Prefers UID MOVE; falls back to COPY + \Deleted + EXPUNGE.
    func moveUID(
        host: String,
        port: Int,
        user: String,
        credentials: MailCredentials,
        fromFolder: String,
        uid: String,
        destHints: [String]
    ) async throws {
        let conn = try MailStream.connect(host: host, port: port, tls: .implicit)
        defer { conn.close() }
        _ = try conn.readLine()
        try imapSignIn(conn, user: user, credentials: credentials)
        let boxes = try imapList(conn)
        let source = boxes.first(where: { $0.caseInsensitiveCompare(fromFolder) == .orderedSame }) ?? fromFolder
        guard try imapOK(conn, "SELECT \(imapQuote(source))") else {
            throw MailError.protocolFailure("Could not open \(source).")
        }
        if let dest = pickMailbox(boxes, hints: destHints) {
            if try imapOK(conn, "UID MOVE \(uid) \(imapQuote(dest))") {
                _ = try? conn.command("LOGOUT")
                return
            }
            if try imapOK(conn, "UID COPY \(uid) \(imapQuote(dest))") {
                _ = try conn.command("UID STORE \(uid) +FLAGS.SILENT (\\Deleted)")
                _ = try? conn.command("UID EXPUNGE \(uid)")
                _ = try? conn.command("EXPUNGE")
                _ = try? conn.command("LOGOUT")
                return
            }
        }
        _ = try conn.command("UID STORE \(uid) +FLAGS.SILENT (\\Deleted)")
        _ = try? conn.command("UID EXPUNGE \(uid)")
        _ = try? conn.command("EXPUNGE")
        _ = try? conn.command("LOGOUT")
    }

    func sendMail(host: String, port: Int, tls: String, user: String, credentials: MailCredentials, from: String, to: [String], raw: String) async throws {
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
        try smtpSignIn(conn, user: user, credentials: credentials)
        let mailFrom = try conn.smtp("MAIL FROM:<\(from)>")
        if !mailFrom.hasPrefix("250") { throw MailError.protocolFailure(mailFrom) }
        for addr in to where addr.contains("@") {
            _ = try conn.smtp("RCPT TO:<\(addr)>")
        }
        _ = try conn.smtp("DATA")
        let escaped = raw.replacingOccurrences(of: "\n.", with: "\n..")
        _ = try conn.smtpRaw(escaped + "\r\n.")
        _ = try conn.smtp("QUIT")
    }

    private func imapSignIn(_ conn: MailStream, user: String, credentials: MailCredentials) throws {
        switch credentials {
        case .password(let password):
            let r = try conn.command("LOGIN \(imapQuote(user)) \(imapQuote(password))")
            if r.contains(" NO ") || r.contains(" BAD ") || (r.contains("NO") && r.contains("LOGIN")) {
                throw MailError.auth("Could not sign in. Check the email and password.")
            }
        case .oauth(let token):
            try conn.authenticateXOAUTH2(user: user, token: token)
        }
    }

    private func smtpSignIn(_ conn: MailStream, user: String, credentials: MailCredentials) throws {
        switch credentials {
        case .password(let password):
            _ = try conn.smtp("AUTH LOGIN")
            _ = try conn.smtp(Data(user.utf8).base64EncodedString())
            let auth = try conn.smtp(Data(password.utf8).base64EncodedString())
            if !auth.hasPrefix("235") {
                throw MailError.auth("SMTP login failed. Use an app password.")
            }
        case .oauth(let token):
            let b64 = MicrosoftOAuth.xoauth2(user: user, token: token)
            let auth = try conn.smtp("AUTH XOAUTH2 \(b64)")
            if !auth.hasPrefix("235") {
                throw MailError.auth("Microsoft would not send mail. Sign in again.")
            }
        }
    }

    private func imapList(_ conn: MailStream) throws -> [String] {
        let r = try conn.command("LIST \"\" \"*\"")
        var names: [String] = []
        for line in r.components(separatedBy: "\n") where line.hasPrefix("* LIST") {
            if let name = parseListName(line) { names.append(name) }
        }
        return names
    }

    private func imapOK(_ conn: MailStream, _ cmd: String) throws -> Bool {
        let r = try conn.command(cmd)
        return r.contains(" OK ")
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

    private func imapFetch(_ conn: MailStream, uid: Int) throws -> IMAPEnvelope? {
        let r = try conn.fetch("UID FETCH \(uid) (FLAGS RFC822)")
        guard let data = r.body, !data.isEmpty else { return nil }
        return IMAPEnvelope(uid: String(uid), flags: r.flags, rfc822: data)
    }
}

private func imapQuote(_ s: String) -> String {
    "\"" + s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
}

private func pickMailbox(_ boxes: [String], hints: [String]) -> String? {
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

    func authenticateXOAUTH2(user: String, token: String) throws {
        let t = "A\(tag)"
        tag += 1
        try write("\(t) \(MicrosoftOAuth.imapAuthenticateCommand(user: user, token: token))\r\n")
        while true {
            let line = try readLine()
            if line.hasPrefix("+") {
                try write("\r\n")
                continue
            }
            if line.hasPrefix("\(t) ") {
                if line.contains(" NO") || line.contains(" BAD") {
                    throw MailError.auth("IMAP_AUTH_REJECTED")
                }
                return
            }
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
