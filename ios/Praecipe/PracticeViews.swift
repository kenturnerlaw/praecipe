import SwiftData
import SwiftUI
import UniformTypeIdentifiers

struct MattersHomeView: View {
    @Environment(\.modelContext) private var context
    @Query(sort: \Matter.createdAt, order: .reverse) private var matters: [Matter]
    @State private var editing: Matter?

    var body: some View {
        NavigationStack {
            List(matters) { m in
                Button {
                    editing = m
                } label: {
                    VStack(alignment: .leading) {
                        Text(m.caseNo.isEmpty ? m.style : m.caseNo).font(.headline)
                        Text(m.style).font(.subheadline).foregroundStyle(.secondary)
                        Text("\(m.county) · \(m.status)").font(.caption)
                    }
                }
            }
            .navigationTitle("Matters")
            .toolbar {
                Button {
                    let m = Matter()
                    context.insert(m)
                    editing = m
                } label: { Image(systemName: "plus") }
            }
            .sheet(item: $editing) { MatterEditor(matter: $0) }
        }
    }
}

struct MatterEditor: View {
    @Bindable var matter: Matter
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                TextField("Case no", text: $matter.caseNo)
                TextField("Style", text: $matter.style)
                TextField("Petitioner", text: $matter.petitioner)
                TextField("Respondent", text: $matter.respondent)
                TextField("Court", text: $matter.court)
                TextField("County", text: $matter.county)
                TextField("Division", text: $matter.division)
                TextField("Status", text: $matter.status)
                TextField("Opposing counsel", text: $matter.opposingCounsel)
                TextField("Client name", text: $matter.clientName)
                TextField("Client email", text: $matter.clientEmail).keyboardType(.emailAddress).textInputAutocapitalization(.never)
                TextField("Rate", value: $matter.rate, format: .currency(code: "USD"))
                TextField("Notes", text: $matter.notes, axis: .vertical)
            }
            .navigationTitle("Matter")
            .toolbar { Button("Done") { dismiss() } }
        }
    }
}

struct PeopleHomeView: View {
    @Environment(\.modelContext) private var context
    @Query(sort: \Person.email) private var people: [Person]
    @Query private var matters: [Matter]
    @State private var newEmail = ""
    @State private var newName = ""

    var body: some View {
        NavigationStack {
            List {
                ForEach(people) { p in
                    VStack(alignment: .leading) {
                        Text(p.name.isEmpty ? p.email : p.name).font(.headline)
                        Text(p.email).font(.caption).foregroundStyle(.secondary)
                        if !p.firm.isEmpty { Text(p.firm).font(.caption) }
                    }
                }
                .onDelete { idx in
                    idx.map { people[$0] }.forEach(context.delete)
                }
            }
            .navigationTitle("People")
            .toolbar {
                Button {
                    guard newEmail.contains("@") else { return }
                    context.insert(Person(email: newEmail, name: newName))
                    newEmail = ""; newName = ""
                } label: { Image(systemName: "plus") }
            }
            .safeAreaInset(edge: .bottom) {
                HStack {
                    TextField("Name", text: $newName)
                    TextField("Email", text: $newEmail).keyboardType(.emailAddress).textInputAutocapitalization(.never)
                }
                .padding()
                .background(.bar)
            }
        }
    }
}

struct TimeHomeView: View {
    @Environment(\.modelContext) private var context
    @Query(sort: \TimeEntry.createdAt, order: .reverse) private var entries: [TimeEntry]
    @Query private var matters: [Matter]
    @State private var minutes = 12.0
    @State private var activity = "email"
    @State private var desc = ""
    @State private var matter: Matter?
    @State private var selectedEntryIDs: Set<PersistentIdentifier> = []
    @State private var lawPayStatus: LawPayConnectionStatus?
    @State private var invoiceBusy = false
    @State private var confirmInvoice = false
    @State private var csvURL: URL?
    @State private var pdfURL: URL?
    @State private var feedbackTitle = ""
    @State private var feedbackMessage = ""
    @State private var showFeedback = false

    var body: some View {
        List {
            Section("Add") {
                Picker("Matter", selection: $matter) {
                    Text("None").tag(Optional<Matter>.none)
                    ForEach(matters) { m in Text(m.label).tag(Optional(m)) }
                }
                TextField("Activity", text: $activity)
                TextField("Description", text: $desc)
                TextField("Minutes", value: $minutes, format: .number)
                Button("Add time") {
                    let e = TimeEntry(minutes: minutes, activity: activity, description: desc)
                    e.matter = matter
                    e.rate = matter?.rate ?? 0
                    context.insert(e)
                    do {
                        try context.save()
                        desc = ""
                        showFeedback("Time saved", "The \(String(format: "%.1f", e.minutes))-minute entry was saved to \(e.matter?.label ?? "No matter").")
                    } catch {
                        context.delete(e)
                        showFeedback("Time not saved", error.localizedDescription)
                    }
                }
                if let running = entries.first(where: \.running) {
                    Button("Stop timer (\(Int((Date().timeIntervalSince(running.startedAt ?? Date())) / 60)) min)") {
                        running.running = false
                        running.endedAt = Date()
                        if let start = running.startedAt {
                            running.minutes = max(0.1, Date().timeIntervalSince(start) / 60)
                        }
                        saveChange(title: "Timer stopped", message: "The time entry was saved and is ready to review.")
                    }
                } else {
                    Button("Start timer") {
                        let e = TimeEntry(activity: activity, description: desc)
                        e.running = true
                        e.startedAt = Date()
                        e.matter = matter
                        e.rate = matter?.rate ?? 0
                        context.insert(e)
                        saveChange(title: "Timer started", message: "Praecipe is recording time for \(matter?.label ?? "No matter").")
                    }
                }
            }
            Section {
                ForEach(entries) { e in
                    Button {
                        guard canInvoice(e) else { return }
                        if selectedEntryIDs.contains(e.persistentModelID) {
                            selectedEntryIDs.remove(e.persistentModelID)
                        } else {
                            selectedEntryIDs.insert(e.persistentModelID)
                        }
                    } label: {
                        HStack(spacing: 12) {
                            Image(systemName: selectedEntryIDs.contains(e.persistentModelID) ? "checkmark.circle.fill" : "circle")
                                .foregroundStyle(canInvoice(e) ? Color.accentColor : Color.secondary)
                        VStack(alignment: .leading) {
                            Text(e.matter?.label ?? "No matter")
                            Text(e.entryDescription).font(.caption).foregroundStyle(.secondary)
                                if let invoice = e.lawPayInvoiceNumber ?? e.lawPayInvoiceID {
                                    Text("LawPay \(invoice) · \(e.lawPayStatus ?? "created")")
                                        .font(.caption2).foregroundStyle(.green)
                                } else if let error = e.lawPayError, !error.isEmpty {
                                    Text("LawPay failed · \(error)").font(.caption2).foregroundStyle(.red).lineLimit(2)
                                }
                        }
                        Spacer()
                            VStack(alignment: .trailing) {
                                Text("\(e.minutes, specifier: "%.1f") m")
                                Text(e.fee, format: .currency(code: "USD")).font(.caption)
                            }
                        }
                    }
                    .buttonStyle(.plain)
                    .disabled(!canInvoice(e))
                }
            } header: {
                Text("Entries — select unbilled time for one matter")
            } footer: {
                Text("Only stopped, unbilled entries with a positive fee can be sent. LawPay invoice IDs and failures remain attached to each entry.")
            }
            Section("LawPay invoice") {
                LabeledContent("Connection", value: lawPayStatus?.connected == true ? "Connected" : "Not ready")
                LabeledContent("Selected", value: "\(selectedEntries.count) entries · \(selectedTotal.formatted(.currency(code: "USD")))")
                Button(invoiceBusy ? "Creating LawPay invoice…" : "Create LawPay invoice") {
                    confirmInvoice = true
                }
                .disabled(invoiceBusy || selectedEntries.isEmpty || lawPayStatus?.connected != true || selectedMatter == nil)
                if lawPayStatus?.connected != true {
                    Text("Configure and connect LawPay in Settings → LawPay before creating an invoice.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            Section("Export & recovery") {
                Button {
                    do { csvURL = try BillingExports.csv(entries: entries) }
                    catch { showFeedback("CSV export failed", error.localizedDescription) }
                } label: { Label("Prepare CSV", systemImage: "tablecells") }
                if let csvURL {
                    ShareLink(item: csvURL, preview: SharePreview("Praecipe time CSV")) {
                        Label("Share CSV", systemImage: "square.and.arrow.up")
                    }
                }
                Button {
                    do { pdfURL = try BillingExports.pdf(entries: entries) }
                    catch { showFeedback("PDF export failed", error.localizedDescription) }
                } label: { Label("Prepare PDF billing report", systemImage: "doc.richtext") }
                if let pdfURL {
                    ShareLink(item: pdfURL, preview: SharePreview("Praecipe billing report")) {
                        Label("Share PDF", systemImage: "square.and.arrow.up")
                    }
                }
            }
        }
        .navigationTitle("Time")
        .task { await refreshLawPayStatus() }
        .confirmationDialog("Create a LawPay invoice for \(selectedTotal, format: .currency(code: "USD"))?", isPresented: $confirmInvoice, titleVisibility: .visible) {
            Button("Create and email client") { Task { await createInvoice(sendEmail: true) } }
            Button("Create without emailing") { Task { await createInvoice(sendEmail: false) } }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Matter: \(selectedMatter?.label ?? "Multiple matters selected"). LawPay will create one invoice; this action does not charge a card or bank account.")
        }
        .alert(feedbackTitle, isPresented: $showFeedback) {
            Button("OK", role: .cancel) {}
        } message: { Text(feedbackMessage) }
    }

    private var selectedEntries: [TimeEntry] {
        entries.filter { selectedEntryIDs.contains($0.persistentModelID) && canInvoice($0) }
    }

    private var selectedMatter: Matter? {
        let found = Dictionary(grouping: selectedEntries.compactMap(\.matter), by: \.persistentModelID)
        return found.count == 1 ? found.values.first?.first : nil
    }

    private var selectedTotal: Double { selectedEntries.reduce(0) { $0 + $1.fee } }

    private func canInvoice(_ entry: TimeEntry) -> Bool {
        !entry.running && !entry.billed && entry.lawPayInvoiceID == nil && entry.matter != nil && entry.fee > 0
    }

    private func saveChange(title: String, message: String) {
        do {
            try context.save()
            showFeedback(title, message)
        } catch {
            context.rollback()
            showFeedback("Change not saved", error.localizedDescription)
        }
    }

    private func showFeedback(_ title: String, _ message: String) {
        feedbackTitle = title; feedbackMessage = message; showFeedback = true
    }

    @MainActor
    private func refreshLawPayStatus() async {
        guard !LawPayConfiguration.serverURL.isEmpty else { lawPayStatus = nil; return }
        lawPayStatus = try? await LawPaySyncService().connectionStatus()
    }

    @MainActor
    private func createInvoice(sendEmail: Bool) async {
        guard let matter = selectedMatter else {
            showFeedback("Choose one matter", "All selected time entries must belong to the same matter.")
            return
        }
        invoiceBusy = true
        defer { invoiceBusy = false }
        do {
            let bankID = lawPayStatus?.selectedBankAccountID
            let account = lawPayStatus?.bankAccounts.first(where: { $0.id == bankID })
            let result = try await LawPaySyncService().createInvoice(
                entries: selectedEntries,
                matter: matter,
                bankAccountID: bankID,
                sendEmail: sendEmail,
                testMode: account?.testMode ?? false,
                context: context
            )
            selectedEntryIDs.removeAll()
            let number = result.invoiceNumber.isEmpty ? result.invoiceID : result.invoiceNumber
            showFeedback("LawPay invoice created", "Invoice \(number) was created successfully\(result.sent ? " and emailed to \(matter.clientEmail)" : " without sending email").")
        } catch {
            showFeedback("LawPay invoice not created", error.localizedDescription)
        }
    }
}

struct NotesHomeView: View {
    @Environment(\.modelContext) private var context
    @Query(sort: \PracticeNote.updatedAt, order: .reverse) private var notes: [PracticeNote]
    @Query private var matters: [Matter]
    @State private var title = ""
    @State private var bodyText = ""
    @State private var matter: Matter?

    var body: some View {
        List {
            Section("New note") {
                TextField("Title", text: $title)
                TextField("Body", text: $bodyText, axis: .vertical)
                Picker("Matter", selection: $matter) {
                    Text("None").tag(Optional<Matter>.none)
                    ForEach(matters) { m in Text(m.label).tag(Optional(m)) }
                }
                Button("Save note") {
                    let n = PracticeNote(title: title, body: bodyText)
                    n.matter = matter
                    context.insert(n)
                    title = ""; bodyText = ""
                }
            }
            ForEach(notes) { n in
                VStack(alignment: .leading) {
                    Text(n.title).font(.headline)
                    Text(n.body).font(.caption)
                    if let m = n.matter { Text(m.label).font(.caption2).foregroundStyle(.secondary) }
                }
            }
        }
        .navigationTitle("Notes")
    }
}

struct FilesHomeView: View {
    @Query(sort: \MatterFile.createdAt, order: .reverse) private var files: [MatterFile]

    var body: some View {
        List(files) { f in
            VStack(alignment: .leading) {
                Text(f.filename).font(.headline)
                Text("\(f.docType) · \(f.matter?.label ?? "unfiled")").font(.caption).foregroundStyle(.secondary)
                Text(f.relativePath).font(.caption2).foregroundStyle(.tertiary)
            }
        }
        .navigationTitle("Files")
    }
}

extension Matter: Identifiable {}
extension Person: Identifiable {}
extension TimeEntry: Identifiable {}
extension PracticeNote: Identifiable {}
extension MatterFile: Identifiable {}
extension CalendarEvent: Identifiable {}
extension MailMessage: Identifiable {}
extension MailAttachment: Identifiable {}
extension MailAccount: Identifiable {}
extension MailSignature: Identifiable {}
