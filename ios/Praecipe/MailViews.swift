import SwiftData
import SwiftUI

struct MailHomeView: View {
    @Binding var search: String
    @Environment(\.modelContext) private var context
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @EnvironmentObject private var mail: MailSyncService
    @Query(sort: \MailMessage.sentAt, order: .reverse) private var messages: [MailMessage]
    @Query private var accounts: [MailAccount]
    @State private var selectedRole = "INBOX"
    @State private var folders: [MailFolderItem] = MailFolders.fallback()
    @State private var loadingFolders = false
    @State private var composePrefill: ComposePrefill?
    @State private var addAccount = false
    @State private var moveTarget: MoveFolderTarget?
    @State private var tagPickerTarget: MailTagPickerTarget?
    @State private var showTagManagement = false

    var body: some View {
        Group {
            if horizontalSizeClass == .regular {
                NavigationSplitView {
                    mailboxSidebar
                } detail: {
                    mailListStack
                }
            } else {
                NavigationStack {
                    mailListStack
                }
            }
        }
        .task(id: defaultAccount?.persistentModelID) {
            await refreshMailboxes()
        }
    }

    private var defaultAccount: MailAccount? {
        accounts.first(where: \.isDefault) ?? accounts.first
    }

    private var mailboxSidebar: some View {
        List {
            ForEach(folders) { folder in
                Button {
                    selectedRole = folder.role
                    Task { await selectFolder(role: folder.role) }
                } label: {
                    HStack {
                        Label(folder.displayName, systemImage: folder.systemImage)
                            .praecipeBody(selectedRole == folder.role ? .semibold : .regular)
                        Spacer()
                        if selectedRole == folder.role {
                            Image(systemName: "checkmark")
                                .foregroundStyle(PraecipeColors.accent)
                        }
                    }
                }
                .buttonStyle(.plain)
            }
        }
        .praecipeList()
        .navigationTitle("Mailboxes")
        .overlay {
            if loadingFolders {
                ProgressView("Loading mailboxes…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(PraecipeColors.background.opacity(0.85))
            }
        }
    }

    private var mailListStack: some View {
        mailMessageList
            .navigationTitle(folderTitle)
            .navigationBarTitleDisplayMode(.large)
            .searchable(text: $search, prompt: "Search or #tag")
            .toolbar { mailToolbar }
            .refreshable {
                await refreshCurrentFolder(includeInbox: true)
            }
            .safeAreaInset(edge: .top) { mailStatusBanner }
            .sheet(item: $composePrefill) { ComposeView(prefill: $0) }
            .sheet(item: $moveTarget) { target in
                MoveFolderSheet(message: target.message)
            }
            .sheet(isPresented: $addAccount) {
                AddAccountSheet()
            }
            .sheet(item: $tagPickerTarget) { target in
                MailTagPickerSheet(
                    message: target.message,
                    allMessages: messages,
                    focusNewTag: target.focusNewTag
                )
            }
            .navigationDestination(isPresented: $showTagManagement) {
                MailTagManagementView(search: $search)
            }
            .onAppear {
                restoreFolderSelection()
                if !accounts.isEmpty && filtered.isEmpty && !mail.busy {
                    Task { await refreshCurrentFolder(includeInbox: true) }
                }
            }
    }

    @ToolbarContentBuilder
    private var mailToolbar: some ToolbarContent {
        if horizontalSizeClass == .compact {
            ToolbarItem(placement: .topBarLeading) {
                Menu {
                    mailboxMenuContent
                } label: {
                    Label(folderTitle, systemImage: "tray.2")
                }
                .accessibilityLabel("Mailboxes")
            }
        }
        ToolbarItem(placement: .topBarTrailing) {
            if mail.busy {
                ProgressView()
            }
        }
        ToolbarItem(placement: .topBarTrailing) {
            Button {
                composePrefill = .new
            } label: {
                Image(systemName: "square.and.pencil")
            }
        }
    }

    @ViewBuilder
    private var mailboxMenuContent: some View {
        if loadingFolders {
            Text("Loading mailboxes…")
        }
        ForEach(folders) { folder in
            Button {
                selectedRole = folder.role
                Task { await selectFolder(role: folder.role) }
            } label: {
                if selectedRole == folder.role {
                    Label(folder.displayName, systemImage: folder.systemImage)
                } else {
                    Text(folder.displayName)
                }
            }
        }
        Divider()
        Button("Manage Tags…") { showTagManagement = true }
    }

    private var mailMessageList: some View {
        List {
            if filtered.isEmpty && !mail.busy {
                ContentUnavailableView {
                    Label(accounts.isEmpty ? "No Mail Accounts" : "No Mail", systemImage: "envelope")
                } description: {
                    Text(accounts.isEmpty ? "Add an account to fetch mail." : "\(folderTitle) is empty. Pull down to refresh.")
                } actions: {
                    if accounts.isEmpty {
                        Button("Add Account") { addAccount = true }
                    } else {
                        Button("Get Mail") {
                            Task { await refreshCurrentFolder(includeInbox: true) }
                        }
                    }
                }
                .listRowSeparator(.hidden)
            }
            ForEach(filtered) { msg in
                NavigationLink {
                    MessageDetailView(message: msg)
                } label: {
                    MailRow(message: msg, search: $search)
                        .contentShape(Rectangle())
                        .contextMenu {
                            MailMessageContextMenu(
                                message: msg,
                                allMessages: messages,
                                composePrefill: $composePrefill,
                                moveTarget: $moveTarget,
                                tagPickerTarget: $tagPickerTarget
                            )
                        }
                }
                .swipeActions(edge: .leading, allowsFullSwipe: true) {
                    Button {
                        Task { await mail.junkMessage(msg, context: context) }
                    } label: {
                        Label("Junk", systemImage: "xmark.bin")
                    }
                    .tint(PraecipeColors.junk)
                }
                .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                    Button(role: .destructive) {
                        Task { await mail.deleteMessage(msg, context: context) }
                    } label: {
                        Label("Delete", systemImage: "trash")
                    }
                }
            }
        }
        .praecipeList()
    }

    @ViewBuilder
    private var mailStatusBanner: some View {
        if mail.busy {
            HStack(spacing: 8) {
                ProgressView()
                Text(mail.status.isEmpty ? "Updating…" : mail.status)
                    .praecipeFootnote()
                    .praecipeSecondaryText()
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 8)
            .background(PraecipeColors.infoBanner)
        } else if mail.needsSignIn {
            VStack(spacing: 8) {
                if let err = mail.lastError { Text(err).praecipeSubheadline().multilineTextAlignment(.center) }
                Button("Sign In") { addAccount = true }
                    .buttonStyle(PraecipeBorderedProminentButtonStyle())
            }
            .frame(maxWidth: .infinity)
            .padding()
            .background(PraecipeColors.errorBanner)
        } else if let err = mail.lastError, !err.isEmpty {
            VStack(spacing: 8) {
                Text(err)
                    .praecipeSubheadline()
                    .multilineTextAlignment(.center)
                Button("Try Again") {
                    Task { await refreshCurrentFolder(includeInbox: true) }
                }
                .buttonStyle(PraecipeBorderedProminentButtonStyle())
            }
            .frame(maxWidth: .infinity)
            .padding()
            .background(PraecipeColors.errorBanner)
        }
    }

    private var folderTitle: String {
        MailFolders.displayName(for: selectedRole)
    }

    private var filtered: [MailMessage] {
        let tagFilter: String? = {
            guard search.hasPrefix("#") else { return nil }
            let tag = String(search.dropFirst()).trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            return tag.isEmpty ? nil : tag
        }()
        let textQuery = tagFilter != nil ? "" : search

        return messages.filter { msg in
            if msg.deleted { return false }
            if selectedRole == "FLAGGED" {
                if !msg.flagged { return false }
            } else if msg.folder != selectedRole {
                return false
            }
            if let tagFilter, !msg.tags.contains(tagFilter) { return false }
            if textQuery.isEmpty { return true }
            let q = textQuery.lowercased()
            let blob = ([msg.subject, msg.fromAddr, msg.toAddr, msg.bodyText] + msg.tags).joined(separator: " ").lowercased()
            return blob.contains(q)
        }
    }

    private func restoreFolderSelection() {
        guard let account = defaultAccount else { return }
        let role = account.selectedFolderRole.isEmpty ? "INBOX" : account.selectedFolderRole
        selectedRole = role
    }

    private func refreshMailboxes() async {
        guard let account = defaultAccount else {
            folders = MailFolders.fallback()
            return
        }
        loadingFolders = true
        folders = await mail.loadFolderItems(for: account, context: context)
        restoreFolderSelection()
        if !folders.contains(where: { $0.role == selectedRole }) {
            selectedRole = folders.first?.role ?? "INBOX"
        }
        loadingFolders = false
    }

    private func selectFolder(role: String) async {
        selectedRole = role
        guard let account = defaultAccount else { return }
        guard let folder = MailFolders.item(forRole: role, in: folders) else { return }

        account.selectedFolderRole = role
        if let imap = folder.imapName {
            account.selectedFolderIMAP = imap
            await mail.syncFolder(role: role, imapName: imap, account: account, context: context)
        } else {
            try? context.save()
        }
    }

    private func refreshCurrentFolder(includeInbox: Bool) async {
        guard let account = defaultAccount else {
            await mail.sync(context: context)
            return
        }
        restoreFolderSelection()
        if selectedRole == "FLAGGED" {
            await mail.syncSelectedFolder(for: account, context: context, includeInbox: true)
            return
        }
        if let imap = MailFolders.imapName(forRole: selectedRole, in: folders) ?? account.selectedFolderIMAP.nilIfEmpty {
            await mail.syncFolder(role: selectedRole, imapName: imap, account: account, context: context)
        } else {
            await mail.syncSelectedFolder(for: account, context: context, includeInbox: includeInbox)
        }
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}

private struct MailRow: View {
    let message: MailMessage
    @Binding var search: String

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Circle()
                .fill(message.seen ? Color.clear : PraecipeColors.unreadDot)
                .frame(width: 10, height: 10)
                .padding(.top, 6)
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 4) {
                    Text(sender)
                        .praecipeBody(message.seen ? .regular : .semibold)
                        .lineLimit(1)
                    if message.flagged {
                        Image(systemName: "flag.fill")
                            .praecipeCaption2(.bold)
                            .foregroundStyle(PraecipeColors.flag)
                            .accessibilityLabel("Flagged")
                    }
                    Spacer()
                    if let sent = message.sentAt {
                        Text(sent, style: .relative)
                            .praecipeFootnote()
                            .praecipeSecondaryText()
                    }
                }
                Text(message.subject.isEmpty ? "No Subject" : message.subject)
                    .praecipeSubheadline(message.seen ? .regular : .medium)
                    .lineLimit(1)
                Text(message.snippet.isEmpty ? " " : message.snippet)
                    .praecipeSubheadline()
                    .praecipeSecondaryText()
                    .lineLimit(2)
                if !message.tags.isEmpty {
                    TagChipRow(tags: message.tags.sorted(), compact: true) { tag in
                        search = MailTagCatalog.display(tag)
                    }
                }
            }
        }
        .padding(.vertical, 4)
    }

    private var sender: String {
        let raw = message.folder == "SENT" ? message.toAddr : message.fromAddr
        let name = displayName(in: raw, email: emailAddresses(in: raw).first ?? "")
        if !name.isEmpty { return name }
        return raw.isEmpty ? "(unknown)" : raw
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
    @State private var hours = LegalTime.defaultHours
    @State private var activity = "email"
    @State private var clientEmail = ""
    @State private var selectedMatter: Matter?
    @State private var docType: DocType = .correspondence
    @State private var savingFileBill = false
    @State private var confirmEmailSend = false
    @State private var showTagPicker = false
    @State private var savedFileURLs: [URL] = []
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text(message.subject.isEmpty ? "(no subject)" : message.subject)
                    .praecipeTitle3()
                Text("\(message.fromAddr) → \(message.toAddr)")
                    .praecipeFootnote()
                    .praecipeSecondaryText()
                if let html = attributedBody {
                    Text(html)
                        .praecipeBody()
                } else {
                    Text(message.bodyText.isEmpty ? stripHTML(message.bodyHTML) : message.bodyText)
                        .praecipeBody()
                }
                if !message.attachments.isEmpty {
                    ForEach(message.attachments) { att in
                        MailAttachmentShareRow(attachment: att)
                    }
                }
                mailTags
                fileBill
            }
            .padding()
        }
        .background(PraecipeColors.background)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("Save") {
                    if emailClient && hasValidClientEmail {
                        confirmEmailSend = true
                    } else {
                        Task { await runFileBill() }
                    }
                }
                .disabled(savingFileBill || selectedMatter == nil || (emailClient && !emailClientAllowed))
            }
            ToolbarItem(placement: .topBarTrailing) {
                MailMessageShareMenu(message: message) {
                    Image(systemName: "square.and.arrow.up")
                }
                .accessibilityLabel("Share")
            }
            ToolbarItem(placement: .topBarTrailing) {
                Button(role: .destructive) {
                    Task {
                        await mail.deleteMessage(message, context: context)
                        dismiss()
                    }
                } label: {
                    Image(systemName: "trash")
                }
                .accessibilityLabel("Delete")
            }
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    Task { await mail.junkMessage(message, context: context); dismiss() }
                } label: {
                    Image(systemName: "xmark.bin")
                }
                .accessibilityLabel("Junk")
            }
            ToolbarItemGroup(placement: .bottomBar) {
                Button("Reply") { compose = .reply(message, all: false) }
                Button("Reply All") { compose = .reply(message, all: true) }
                Button("Forward") { compose = .forward(message) }
                Button(message.flagged ? "Unflag" : "Flag") {
                    Task { await mail.toggleFlag(message, flag: "Flagged", add: !message.flagged, context: context) }
                }
                Button("Tag") { showTagPicker = true }
            }
        }
        .sheet(isPresented: $showTagPicker) {
            MailTagPickerSheet(message: message, allMessages: allMail, focusNewTag: false)
        }
        .sheet(item: $compose) { ComposeView(prefill: $0) }
        .alert("Email client?", isPresented: $confirmEmailSend) {
            Button("Cancel", role: .cancel) {}
            Button("Send to \(trimmedClientEmail)") {
                Task { await runFileBill() }
            }
        } message: {
            Text("Praecipe will email \(trimmedClientEmail) about “\(selectedMatter?.label ?? "this matter")” with subject RE: \(message.subject.isEmpty ? "(no subject)" : message.subject).")
        }
        .onChange(of: selectedMatter) { _, matter in
            if let matter, !matter.clientEmail.isEmpty {
                clientEmail = matter.clientEmail
            }
            if emailClient && !emailClientAllowed {
                emailClient = false
            }
        }
        .onChange(of: emailClient) { _, on in
            if on && !emailClientAllowed {
                emailClient = false
            }
        }
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
            if FileAndBill.isTimeBilled(message, context: context) {
                addTime = false
            }
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

    private var trimmedClientEmail: String {
        clientEmail.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var hasValidClientEmail: Bool {
        trimmedClientEmail.contains("@")
    }

    private var lowConfidenceMatch: Bool {
        guard let top = matches.first else { return true }
        return top.confidence < 45
    }

    private var emailClientAllowed: Bool {
        guard hasValidClientEmail else { return false }
        if message.isLikelySpam && (selectedMatter == nil || lowConfidenceMatch) { return false }
        return true
    }

    private var mailTags: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Tags")
                    .praecipeHeadline()
                Spacer()
                Button("Edit Tags…") { showTagPicker = true }
                    .praecipeSubheadline()
            }
            if !message.tags.isEmpty {
                TagChipRow(tags: message.tags.sorted()) { tag in
                    message.removeTag(tag)
                    try? context.save()
                }
            } else {
                Text("No tags")
                    .praecipeSubheadline()
                    .praecipeSecondaryText()
            }
            Text("Quick add")
                .praecipeCaption(.semibold)
                .praecipeSecondaryText()
            TagChipRow(
                tags: MailTagIndex.pickerTags(in: allMail),
                compact: true,
                isSelected: { message.hasTag($0) }
            ) { tag in
                message.toggleTag(tag)
                try? context.save()
            }
            Text("Search mail with #tag. Tags are separate from the IMAP flag.")
                .praecipeCaption()
                .praecipeSecondaryText()
        }
        .praecipeCard()
    }

    private var fileBill: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("File & Bill")
                .praecipeHeadline()
                .padding(.bottom, 12)
            Picker("Matter", selection: $selectedMatter) {
                Text("Choose").tag(Optional<Matter>.none)
                ForEach(matters) { m in
                    Text(label(for: m)).tag(Optional(m))
                }
            }
            if let top = matches.first, top.confidence >= 45 {
                Text("Suggested match · \(top.confidence)%")
                    .praecipeCaption()
                    .praecipeSecondaryText()
                    .padding(.top, 4)
            }
            Divider().padding(.vertical, 12).overlay(PraecipeColors.separator.opacity(0.55))
            Toggle("Connect to matter", isOn: $connect)
            Toggle("Save attachments", isOn: $saveAtt)
            Picker("Document type", selection: $docType) {
                ForEach(DocType.allCases) { t in Text(t.title).tag(t) }
            }
            Toggle("Download URLs to folder", isOn: $downloadURLs)
            Toggle("Email client", isOn: $emailClient)
                .disabled(!emailClientAllowed && !emailClient)
            if emailClient {
                TextField("Client email", text: $clientEmail)
                    .textInputAutocapitalization(.never)
                    .keyboardType(.emailAddress)
                if hasValidClientEmail {
                    Label("Will email \(trimmedClientEmail)", systemImage: "envelope")
                        .praecipeFootnote()
                        .praecipeSecondaryText()
                } else {
                    Label("Enter the client’s email address.", systemImage: "exclamationmark.triangle")
                        .praecipeFootnote()
                        .foregroundStyle(PraecipeColors.warning)
                }
                if message.isLikelySpam && lowConfidenceMatch {
                    Label("Spam with no confident matter match — email client disabled.", systemImage: "xmark.octagon")
                        .praecipeFootnote()
                        .foregroundStyle(PraecipeColors.destructive)
                }
            } else if let matter = selectedMatter, matter.clientEmail.isEmpty, !hasValidClientEmail {
                Label("No client email on this matter.", systemImage: "info.circle")
                    .praecipeFootnote()
                    .praecipeSecondaryText()
            }
            if alreadyBilled {
                Label("Billed — time already recorded for this email", systemImage: "checkmark.seal.fill")
                    .praecipeFootnote()
                    .foregroundStyle(PraecipeColors.accent)
                    .padding(.top, 4)
                if let billedHours = FileAndBill.existingTimeEntry(for: message, context: context)?.hours {
                    Text(LegalTime.displayBoth(billedHours))
                        .praecipeCaption()
                        .praecipeSecondaryText()
                }
            } else {
                Toggle("Add time entry", isOn: $addTime)
                if addTime {
                    HStack {
                        Text("Hours")
                        Spacer()
                        TextField("0.2", value: $hours, format: .number.precision(.fractionLength(1)))
                            .keyboardType(.decimalPad)
                            .multilineTextAlignment(.trailing)
                            .frame(maxWidth: 80)
                    }
                    Text(LegalTime.displayMinutes(fromHours: hours))
                        .praecipeCaption()
                        .praecipeSecondaryText()
                    TextField("Activity", text: $activity)
                }
            }
            if !billStatus.isEmpty {
                Text(billStatus)
                    .praecipeFootnote()
                    .praecipeSecondaryText()
                    .padding(.top, 8)
            }
            if !savedFileURLs.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Saved files")
                        .praecipeCaption(.semibold)
                        .praecipeSecondaryText()
                    ForEach(savedFileURLs, id: \.absoluteString) { url in
                        SavedFileShareRow(url: url)
                    }
                }
                .padding(.top, 8)
            }
        }
        .praecipeCard()
    }

    private var alreadyBilled: Bool {
        FileAndBill.isTimeBilled(message, context: context)
    }

    private func label(for m: Matter) -> String {
        if let hit = matches.first(where: { $0.matter.persistentModelID == m.persistentModelID }) {
            return "\(m.label) (\(hit.confidence)%)"
        }
        return m.label
    }

    private func runFileBill() async {
        guard let matter = selectedMatter else {
            billStatus = "Choose a matter."
            return
        }
        savingFileBill = true
        billStatus = ""
        let wasBilled = alreadyBilled
        let out = await FileAndBill.run(
            message: message,
            matter: matter,
            connect: connect,
            saveAttachments: saveAtt,
            docType: docType,
            downloadURLs: downloadURLs,
            emailClient: emailClient,
            clientEmail: clientEmail,
            addTime: wasBilled ? false : addTime,
            hours: hours,
            activity: activity,
            context: context,
            mail: mail,
            account: accounts.first(where: \.isDefault) ?? accounts.first
        )
        var bits: [String] = []
        if out.connected { bits.append("connected") }
        if !out.savedFiles.isEmpty { bits.append("\(out.savedFiles.count) file(s)") }
        if !out.downloadedFiles.isEmpty { bits.append("\(out.downloadedFiles.count) URL(s)") }
        if let e = out.emailed { bits.append("emailed \(e)") }
        if let h = out.hours {
            bits.append(wasBilled ? "already billed \(LegalTime.displayBoth(h))" : LegalTime.displayBoth(h))
        } else if wasBilled {
            bits.append("already billed")
        }
        if let err = out.error { bits.append(err) }
        billStatus = bits.isEmpty ? "Saved." : bits.joined(separator: " · ")
        savedFileURLs = out.savedFiles + out.downloadedFiles
        if FileAndBill.isTimeBilled(message, context: context) {
            addTime = false
        }
        savingFileBill = false
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
                if !sendError.isEmpty { Text(sendError).foregroundStyle(PraecipeColors.destructive) }
            }
            .scrollContentBackground(.hidden)
            .background(PraecipeColors.background)
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

private struct MoveFolderTarget: Identifiable {
    let id: PersistentIdentifier
    let message: MailMessage

    init(_ message: MailMessage) {
        self.message = message
        self.id = message.persistentModelID
    }
}

private struct MailMessageContextMenu: View {
    let message: MailMessage
    let allMessages: [MailMessage]
    @Binding var composePrefill: ComposePrefill?
    @Binding var moveTarget: MoveFolderTarget?
    @Binding var tagPickerTarget: MailTagPickerTarget?
    @Environment(\.modelContext) private var context
    @EnvironmentObject private var mail: MailSyncService

    private var pickerTags: [String] {
        MailTagIndex.pickerTags(in: allMessages)
    }

    var body: some View {
        Group {
            Button {
                composePrefill = .reply(message, all: false)
            } label: {
                Label("Reply", systemImage: "arrowshape.turn.up.left")
            }
            Button {
                composePrefill = .reply(message, all: true)
            } label: {
                Label("Reply All", systemImage: "arrowshape.turn.up.left.2")
            }
            Button {
                composePrefill = .forward(message)
            } label: {
                Label("Forward", systemImage: "arrowshape.turn.up.right")
            }

            MailMessageShareMenu(message: message) {
                Label("Share…", systemImage: "square.and.arrow.up")
            }

            Divider()

            if message.seen {
                Button {
                    Task { await mail.markUnread(message, context: context) }
                } label: {
                    Label("Mark as Unread", systemImage: "envelope.badge")
                }
            } else {
                Button {
                    Task { await mail.markRead(message, context: context) }
                } label: {
                    Label("Mark as Read", systemImage: "envelope.open")
                }
            }

            Divider()

            ForEach(pickerTags, id: \.self) { tag in
                Button {
                    message.toggleTag(tag)
                    try? context.save()
                } label: {
                    if message.hasTag(tag) {
                        Label(MailTagCatalog.display(tag), systemImage: "checkmark")
                    } else {
                        Label(MailTagCatalog.display(tag), systemImage: "number")
                    }
                }
            }
            Button {
                tagPickerTarget = MailTagPickerTarget(message, focusNewTag: true)
            } label: {
                Label("New Tag…", systemImage: "plus")
            }

            Divider()

            Button {
                Task { await mail.toggleFlag(message, flag: "Flagged", add: !message.flagged, context: context) }
            } label: {
                Label(message.flagged ? "Unflag" : "Flag", systemImage: message.flagged ? "flag.slash" : "flag")
            }
            Button {
                Task { await mail.archiveMessage(message, context: context) }
            } label: {
                Label("Archive", systemImage: "archivebox")
            }
            Button {
                moveTarget = MoveFolderTarget(message)
            } label: {
                Label("Move to…", systemImage: "folder")
            }

            Divider()

            Button {
                Task { await mail.junkMessage(message, context: context) }
            } label: {
                Label("Junk", systemImage: "xmark.bin")
            }
            Button(role: .destructive) {
                Task { await mail.deleteMessage(message, context: context) }
            } label: {
                Label("Delete", systemImage: "trash")
            }
        }
    }
}

private struct MoveFolderSheet: View {
    let message: MailMessage
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var context
    @EnvironmentObject private var mail: MailSyncService
    @Query private var accounts: [MailAccount]
    @State private var folders: [String] = []
    @State private var loading = true
    @State private var error = ""

    var body: some View {
        NavigationStack {
            Group {
                if loading {
                    ProgressView("Loading folders…")
                } else if folders.isEmpty {
                    ContentUnavailableView("No Folders", systemImage: "folder", description: Text(error.isEmpty ? "Could not list mailboxes." : error))
                } else {
                    List(folders, id: \.self) { folder in
                        Button(folder) {
                            Task {
                                await mail.moveMessage(message, toFolder: folder, context: context)
                                dismiss()
                            }
                        }
                    }
                    .praecipeList()
                }
            }
            .navigationTitle("Move to Folder")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
            .task {
                guard let account = accounts.first(where: { $0.email == message.accountEmail }) ?? accounts.first(where: \.isDefault) ?? accounts.first else {
                    error = "No mail account."
                    loading = false
                    return
                }
                folders = await mail.listFolders(for: account, context: context)
                if folders.isEmpty { error = mail.lastError ?? "Could not list folders." }
                loading = false
            }
        }
    }
}
