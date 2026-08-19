import SwiftData
import SwiftUI

struct MailHomeView: View {
    @Binding var search: String
    @Environment(\.modelContext) private var context
    @EnvironmentObject private var mail: MailSyncService
    @Query(sort: \MailMessage.sentAt, order: .reverse) private var messages: [MailMessage]
    @Query private var accounts: [MailAccount]
    @State private var folder = "INBOX"
    @State private var compose = false

    var body: some View {
        NavigationStack {
            List {
                Picker("Mailbox", selection: $folder) {
                    Text("Inbox").tag("INBOX")
                    Text("Sent").tag("SENT")
                    Text("Flagged").tag("FLAGGED")
                }
                .pickerStyle(.segmented)
                .listRowBackground(Color.clear)

                ForEach(filtered) { msg in
                    NavigationLink {
                        MessageDetailView(message: msg)
                    } label: {
                        VStack(alignment: .leading, spacing: 4) {
                            HStack {
                                Text(msg.fromAddr.isEmpty ? msg.toAddr : msg.fromAddr)
                                    .font(.subheadline.weight(msg.seen ? .regular : .semibold))
                                    .lineLimit(1)
                                Spacer()
                                if let sent = msg.sentAt {
                                    Text(sent, style: .time)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            }
                            Text(msg.subject.isEmpty ? "(no subject)" : msg.subject)
                                .font(.subheadline)
                                .lineLimit(1)
                            Text(msg.snippet)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(2)
                        }
                    }
                    .listRowBackground(msg.seen ? Color.clear : Color.blue.opacity(0.06))
                }
            }
            .navigationTitle("Praecipe")
            .searchable(text: $search, prompt: "Search")
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Get Mail") {
                        Task { await mail.sync(context: context) }
                    }
                    .disabled(mail.busy)
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        compose = true
                    } label: {
                        Image(systemName: "square.and.pencil")
                    }
                }
            }
            .safeAreaInset(edge: .bottom) {
                Text(mail.status)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.bottom, 4)
            }
            .sheet(isPresented: $compose) {
                ComposeView(prefill: .new)
            }
        }
    }

    private var filtered: [MailMessage] {
        messages.filter { msg in
            if msg.deleted { return false }
            if folder == "FLAGGED" { if !msg.flagged { return false } }
            else if msg.folder != folder { return false }
            if search.isEmpty { return true }
            let q = search.lowercased()
            return [msg.subject, msg.fromAddr, msg.toAddr, msg.bodyText].joined(separator: " ").lowercased().contains(q)
        }
    }
}

struct MessageDetailView: View {
    @Bindable var message: MailMessage
    @Environment(\.modelContext) private var context
    @EnvironmentObject private var mail: MailSyncService
    @Query private var matters: [Matter]
    @Query private var accounts: [MailAccount]
    @Query(sort: \MailMessage.sentAt, order: .reverse) private var allMail: [MailMessage]
    @State private var compose: ComposePrefill?
    @State private var billStatus = ""
    @State private var connect = true
    @State private var saveAtt = true
    @State private var downloadURLs = false
    @State private var emailClient = false
    @State private var addTime = true
    @State private var minutes = 12.0
    @State private var activity = "email"
    @State private var clientEmail = ""
    @State private var selectedMatter: Matter?
    @State private var docType: DocType = .correspondence

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text(message.subject.isEmpty ? "(no subject)" : message.subject)
                    .font(.title3.weight(.semibold))
                Text("\(message.fromAddr) → \(message.toAddr)")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                if let html = attributedBody {
                    Text(html)
                } else {
                    Text(message.bodyText.isEmpty ? stripHTML(message.bodyHTML) : message.bodyText)
                }
                if !message.attachments.isEmpty {
                    ForEach(message.attachments) { att in
                        Label(att.filename, systemImage: "paperclip")
                            .font(.footnote)
                    }
                }
                fileBill
            }
            .padding()
        }
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItemGroup(placement: .bottomBar) {
                Button("Reply") { compose = .reply(message, all: false) }
                Button("Reply All") { compose = .reply(message, all: true) }
                Button("Forward") { compose = .forward(message) }
                Button(message.flagged ? "Unflag" : "Flag") {
                    Task { await mail.toggleFlag(message, flag: "Flagged", add: !message.flagged, context: context) }
                }
            }
        }
        .sheet(item: $compose) { ComposeView(prefill: $0) }
        .onAppear {
            let from = emailAddresses(in: message.fromAddr).first ?? ""
            let prior = MatterMatcher.priorCounts(messages: allMail, from: from)
            let matches = MatterMatcher.match(message: message, matters: matters, priorFromSender: prior, contactMatter: [:])
            if selectedMatter == nil {
                selectedMatter = message.matter ?? matches.first(where: { $0.confidence >= 45 })?.matter ?? matches.first?.matter
            }
            docType = MatterMatcher.guessDocType(for: message)
            clientEmail = selectedMatter?.clientEmail ?? matches.first?.matter.clientEmail ?? ""
            downloadURLs = MailExtract.urls(in: message).contains(where: \.serviceLikely)
        }
    }

    private var attributedBody: AttributedString? {
        guard !message.bodyHTML.isEmpty, let data = message.bodyHTML.data(using: .utf8) else { return nil }
        return try? AttributedString(
            NSAttributedString(data: data, options: [.documentType: NSAttributedString.DocumentType.html], documentAttributes: nil)
        )
    }

    private var matches: [MatterMatch] {
        let from = emailAddresses(in: message.fromAddr).first ?? ""
        return MatterMatcher.match(
            message: message,
            matters: matters,
            priorFromSender: MatterMatcher.priorCounts(messages: allMail, from: from),
            contactMatter: [:]
        )
    }

    private var fileBill: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("File & Bill").font(.headline)
            Picker("Matter", selection: $selectedMatter) {
                Text("Choose").tag(Optional<Matter>.none)
                ForEach(matters) { m in
                    Text(label(for: m)).tag(Optional(m))
                }
            }
            if let top = matches.first {
                Text("\(top.confidence)% — \(top.reasons.joined(separator: "; "))")
                    .font(.caption)
                    .foregroundStyle(top.confidence >= 75 ? .green : top.confidence >= 45 ? .orange : .secondary)
            }
            Toggle("Connect this message to the matter", isOn: $connect)
            Toggle("Save attachments to the matter folder", isOn: $saveAtt)
            Picker("Document type", selection: $docType) {
                ForEach(DocType.allCases) { t in Text(t.title).tag(t) }
            }
            Toggle("Download service documents from URLs into that folder", isOn: $downloadURLs)
            Toggle("Email the client", isOn: $emailClient)
            TextField("Client email", text: $clientEmail)
                .textInputAutocapitalization(.never)
                .keyboardType(.emailAddress)
            Toggle("Time entry", isOn: $addTime)
            HStack {
                Text("Minutes")
                TextField("12", value: $minutes, format: .number)
                    .keyboardType(.decimalPad)
            }
            TextField("Activity", text: $activity)
            Button("Do all checked") {
                Task { await runFileBill() }
            }
            .buttonStyle(.borderedProminent)
            if !billStatus.isEmpty {
                Text(billStatus).font(.caption)
            }
        }
        .padding()
        .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 12))
    }

    private func label(for m: Matter) -> String {
        if let hit = matches.first(where: { $0.matter.persistentModelID == m.persistentModelID }) {
            return "\(m.label) (\(hit.confidence)%)"
        }
        return m.label
    }

    private func runFileBill() async {
        guard let matter = selectedMatter else {
            billStatus = "Pick a matter."
            return
        }
        billStatus = "Working…"
        let out = await FileAndBill.run(
            message: message,
            matter: matter,
            connect: connect,
            saveAttachments: saveAtt,
            docType: docType,
            downloadURLs: downloadURLs,
            emailClient: emailClient,
            clientEmail: clientEmail,
            addTime: addTime,
            minutes: minutes,
            activity: activity,
            context: context,
            mail: mail,
            account: accounts.first(where: \.isDefault) ?? accounts.first
        )
        var bits: [String] = []
        if out.connected { bits.append("connected") }
        if !out.saved.isEmpty { bits.append("\(out.saved.count) file(s)") }
        if !out.downloaded.isEmpty { bits.append("\(out.downloaded.count) URL(s)") }
        if let e = out.emailed { bits.append("emailed \(e)") }
        if let m = out.minutes { bits.append("\(m) min") }
        if let err = out.error { bits.append(err) }
        billStatus = bits.isEmpty ? "Done." : bits.joined(separator: " · ")
    }
}

enum ComposePrefill: Identifiable {
    case new, reply(MailMessage, all: Bool), forward(MailMessage)
    var id: String {
        switch self {
        case .new: return "new"
        case .reply(let m, let all): return "r-\(m.persistentModelID)-\(all)"
        case .forward(let m): return "f-\(m.persistentModelID)"
        }
    }
}

struct ComposeView: View {
    var prefill: ComposePrefill
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var context
    @EnvironmentObject private var mail: MailSyncService
    @Query private var accounts: [MailAccount]
    @Query private var people: [Person]
    @Query private var signatures: [MailSignature]
    @State private var to = ""
    @State private var cc = ""
    @State private var subject = ""
    @State private var messageBody = ""
    @State private var sendError = ""
    @State private var sending = false

    var body: some View {
        NavigationStack {
            Form {
                TextField("To", text: $to).textInputAutocapitalization(.never).keyboardType(.emailAddress)
                TextField("Cc", text: $cc).textInputAutocapitalization(.never).keyboardType(.emailAddress)
                TextField("Subject", text: $subject)
                TextEditor(text: $messageBody).frame(minHeight: 220)
                if !sendError.isEmpty { Text(sendError).foregroundStyle(.red) }
            }
            .navigationTitle("New Message")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Send") { Task { await send() } }
                        .disabled(sending)
                }
            }
            .onAppear { applyPrefill() }
        }
    }

    private func applyPrefill() {
        let sig = (signatures.first(where: \.isDefault) ?? signatures.first)?.body ?? ""
        switch prefill {
        case .new:
            if messageBody.isEmpty { messageBody = "\n\n" + sig }
        case .reply(let msg, let all):
            to = emailAddresses(in: msg.replyTo.isEmpty ? msg.fromAddr : msg.replyTo).joined(separator: ", ")
            if all {
                let others = emailAddresses(in: msg.toAddr + "," + msg.ccAddr)
                cc = others.filter { $0 != accounts.first?.email.lowercased() }.joined(separator: ", ")
            }
            subject = msg.subject.lowercased().hasPrefix("re:") ? msg.subject : "Re: \(msg.subject)"
            messageBody = "\n\n" + sig + "\n\nOn \(msg.sentAt?.formatted() ?? ""), \(msg.fromAddr) wrote:\n\(msg.bodyText)"
        case .forward(let msg):
            subject = msg.subject.lowercased().hasPrefix("fwd:") ? msg.subject : "Fwd: \(msg.subject)"
            messageBody = "\n\n" + sig + "\n\n---------- Forwarded message ----------\n\(msg.bodyText)"
        }
    }

    private func send() async {
        guard let account = accounts.first(where: \.isDefault) ?? accounts.first else {
            sendError = "Add a mailbox in Settings."
            return
        }
        sending = true
        sendError = ""
        do {
            try await mail.send(
                from: account,
                to: to.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) },
                cc: cc.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) },
                subject: subject,
                body: messageBody,
                inReplyTo: {
                    if case .reply(let m, _) = prefill { return m.messageIdHeader }
                    return ""
                }()
            )
            dismiss()
        } catch {
            sendError = error.localizedDescription
        }
        sending = false
    }
}
