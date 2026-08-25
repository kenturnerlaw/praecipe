import SwiftUI
import UIKit

enum MailShare {
    static func plainBody(_ message: MailMessage) -> String {
        if !message.bodyText.isEmpty { return message.bodyText }
        if !message.bodyHTML.isEmpty { return stripHTML(message.bodyHTML) }
        return ""
    }

    static func plainSummary(_ message: MailMessage) -> String {
        var lines: [String] = []
        lines.append("From: \(message.fromAddr)")
        lines.append("To: \(message.toAddr)")
        if !message.ccAddr.isEmpty { lines.append("Cc: \(message.ccAddr)") }
        let subject = message.subject.isEmpty ? "(no subject)" : message.subject
        lines.append("Subject: \(subject)")
        if let sent = message.sentAt {
            lines.append("Date: \(sent.formatted(date: .complete, time: .shortened))")
        }
        lines.append("")
        lines.append(plainBody(message))
        return lines.joined(separator: "\n")
    }

    static func emlText(_ message: MailMessage) -> String {
        var lines = [
            "From: \(message.fromAddr)",
            "To: \(message.toAddr)",
        ]
        if !message.ccAddr.isEmpty { lines.append("Cc: \(message.ccAddr)") }
        lines.append("Subject: \(message.subject.isEmpty ? "(no subject)" : message.subject)")
        if let sent = message.sentAt {
            lines.append("Date: \(imfDate(sent))")
        }
        if !message.messageIdHeader.isEmpty {
            lines.append("Message-ID: \(message.messageIdHeader)")
        }
        lines.append("MIME-Version: 1.0")
        if !message.bodyHTML.isEmpty {
            lines.append("Content-Type: multipart/alternative; boundary=\"praecipe-boundary\"")
            lines.append("")
            lines.append("--praecipe-boundary")
            lines.append("Content-Type: text/plain; charset=utf-8")
            lines.append("")
            lines.append(plainBody(message).replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\n", with: "\r\n"))
            lines.append("--praecipe-boundary")
            lines.append("Content-Type: text/html; charset=utf-8")
            lines.append("")
            lines.append(message.bodyHTML.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\n", with: "\r\n"))
            lines.append("--praecipe-boundary--")
        } else {
            lines.append("Content-Type: text/plain; charset=utf-8")
            lines.append("")
            lines.append(plainBody(message).replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\n", with: "\r\n"))
        }
        return lines.joined(separator: "\r\n")
    }

    static func emlFileURL(_ message: MailMessage) -> URL? {
        let name = safeFilename(message.subject.isEmpty ? "message" : message.subject, ext: "eml")
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(name)
        do {
            try emlText(message).write(to: url, atomically: true, encoding: .utf8)
            return url
        } catch {
            return nil
        }
    }

    static func attachmentURL(_ attachment: MailAttachment) -> URL? {
        guard let data = attachment.data, !data.isEmpty else { return nil }
        let name = safeFilename(attachment.filename, ext: nil)
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(name)
        do {
            try data.write(to: url, options: .atomic)
            return url
        } catch {
            return nil
        }
    }

    static func matterFileURL(relativePath: String) -> URL {
        AppStore.filesRoot.deletingLastPathComponent().appendingPathComponent(relativePath)
    }

    private static func safeFilename(_ base: String, ext: String?) -> String {
        var name = base
            .replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ":", with: "-")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if name.isEmpty { name = "shared" }
        if name.count > 80 { name = String(name.prefix(80)) }
        if let ext, !name.lowercased().hasSuffix(".\(ext.lowercased())") {
            name += ".\(ext)"
        }
        return name
    }

    private static func imfDate(_ date: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "EEE, dd MMM yyyy HH:mm:ss Z"
        return f.string(from: date)
    }
}

struct MailMessageShareMenu<MenuLabel: View>: View {
    let message: MailMessage
    @ViewBuilder var label: () -> MenuLabel

    private var subject: String {
        message.subject.isEmpty ? "(no subject)" : message.subject
    }

    var body: some View {
        Menu {
            ShareLink(
                item: MailShare.plainSummary(message),
                subject: Text(subject),
                message: Text("Email from Praecipe")
            ) {
                Label("Summary (plain text)", systemImage: "doc.text")
            }
            ShareLink(
                item: MailShare.emlText(message),
                subject: Text(subject),
                message: Text("Email (.eml-style)")
            ) {
                Label("Email (.eml-style text)", systemImage: "envelope")
            }
            if let url = MailShare.emlFileURL(message) {
                ShareLink(item: url, preview: SharePreview(subject, icon: "envelope")) {
                    Label("Email (.eml file)", systemImage: "doc")
                }
            }
        } label: {
            label()
        }
    }
}

struct MailAttachmentShareRow: View {
    let attachment: MailAttachment
    @State private var showShare = false

    var body: some View {
        Button {
            showShare = true
        } label: {
            Label(attachment.filename, systemImage: "paperclip")
                .font(.footnote)
        }
        .disabled(MailShare.attachmentURL(attachment) == nil)
        .sheet(isPresented: $showShare) {
            if let url = MailShare.attachmentURL(attachment) {
                ActivityView(items: [url])
                    .presentationDetents([.medium, .large])
            }
        }
    }
}

struct SavedFileShareRow: View {
    let url: URL

    var body: some View {
        ShareLink(item: url, preview: SharePreview(url.lastPathComponent, icon: "doc")) {
            Label("Share \(url.lastPathComponent)", systemImage: "square.and.arrow.up")
                .font(.footnote)
        }
    }
}

struct ActivityView: UIViewControllerRepresentable {
    let items: [Any]
    var activities: [UIActivity]? = nil

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: activities)
    }

    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}
