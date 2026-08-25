import SwiftData
import SwiftUI
import UniformTypeIdentifiers

struct MattersHomeView: View {
    @Environment(\.modelContext) private var context
    @Query(sort: \Matter.createdAt, order: .reverse) private var matters: [Matter]
    @State private var adding = false

    var body: some View {
        NavigationStack {
            List {
                if matters.isEmpty {
                    ContentUnavailableView(
                        "No Matters",
                        systemImage: "folder.badge.plus",
                        description: Text("Tap + to add a Florida family law matter.")
                    )
                    .listRowSeparator(.hidden)
                }
                ForEach(matters) { m in
                    NavigationLink {
                        MatterDetailView(matter: m)
                    } label: {
                        VStack(alignment: .leading, spacing: 4) {
                            HStack(spacing: 6) {
                                Text(m.label).praecipeHeadline()
                                if m.isIntake {
                                    Text("INTAKE")
                                        .praecipeCaption2(.semibold)
                                        .foregroundStyle(PraecipeColors.warning)
                                }
                            }
                            if !m.style.isEmpty && !m.caseNo.isEmpty {
                                Text(m.style).praecipeSubheadline().praecipeSecondaryText()
                            }
                            let meta = [m.caseType.components(separatedBy: " - ").first, m.court, m.county]
                                .compactMap { $0 }
                                .filter { !$0.isEmpty }
                            if !meta.isEmpty {
                                Text(meta.joined(separator: " · "))
                                    .praecipeCaption()
                                    .praecipeSecondaryText()
                            }
                            Text(m.status).praecipeCaption2().praecipeTertiaryText()
                        }
                        .padding(.vertical, 2)
                    }
                }
            }
            .praecipeList()
            .navigationTitle("Matters")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        adding = true
                    } label: {
                        Label("Add Matter", systemImage: "plus")
                    }
                    .accessibilityLabel("Add Matter")
                }
            }
            .sheet(isPresented: $adding) {
                AddMatterSheet()
            }
        }
    }
}

struct AddMatterSheet: View {
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    @State private var caseNo = ""
    @State private var style = ""
    @State private var petitioner = ""
    @State private var respondent = ""
    @State private var court = "Circuit Court"
    @State private var county = "Collier"
    @State private var division = "Family"
    @State private var status = "Open"
    @State private var caseType = CaseType.dom.rawValue
    @State private var opposingCounsel = ""
    @State private var clientName = ""
    @State private var clientEmail = ""
    @State private var rate = 350.0
    @State private var notes = ""

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Text("Create a matter for Florida family law practice. Case number or style is enough to save.")
                        .praecipeFootnote()
                        .praecipeSecondaryText()
                        .listRowBackground(Color.clear)
                }
                Section("Case") {
                    TextField("Case number", text: $caseNo)
                        .textInputAutocapitalization(.characters)
                    TextField("Style (e.g. Smith v. Smith)", text: $style)
                    Picker("Case type", selection: $caseType) {
                        ForEach(CaseType.allCases) { Text($0.rawValue).tag($0.rawValue) }
                    }
                    Picker("Status", selection: $status) {
                        ForEach(["Open", "Pending", "Closed", "Intake"], id: \.self) { Text($0) }
                    }
                }
                Section("Parties") {
                    TextField("Petitioner", text: $petitioner)
                    TextField("Respondent", text: $respondent)
                    TextField("Client name", text: $clientName)
                    TextField("Client email", text: $clientEmail)
                        .textInputAutocapitalization(.never)
                        .keyboardType(.emailAddress)
                    TextField("Opposing counsel", text: $opposingCounsel)
                }
                Section("Court") {
                    TextField("Court", text: $court)
                    Picker("County", selection: $county) {
                        ForEach(FloridaCounties.all, id: \.self) { Text($0) }
                    }
                    TextField("Division", text: $division)
                }
                Section("Billing") {
                    TextField("Hourly rate", value: $rate, format: .currency(code: "USD"))
                        .keyboardType(.decimalPad)
                }
                Section("Notes") {
                    TextField("Notes", text: $notes, axis: .vertical)
                        .lineLimit(3...8)
                }
            }
            .scrollContentBackground(.hidden)
            .background(PraecipeColors.background)
            .navigationTitle("New Matter")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { save() }
                        .disabled(caseNo.trimmingCharacters(in: .whitespaces).isEmpty
                                  && style.trimmingCharacters(in: .whitespaces).isEmpty
                                  && petitioner.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
            .onChange(of: caseType) { _, _ in suggestStyleIfNeeded() }
            .onChange(of: petitioner) { _, _ in suggestStyleIfNeeded() }
            .onChange(of: respondent) { _, _ in suggestStyleIfNeeded() }
        }
    }

    private func suggestStyleIfNeeded() {
        guard style.trimmingCharacters(in: .whitespaces).isEmpty else { return }
        let p = petitioner.trimmingCharacters(in: .whitespaces)
        let r = respondent.trimmingCharacters(in: .whitespaces)
        if !p.isEmpty && !r.isEmpty {
            style = "\(p) v. \(r)"
        }
    }

    private func save() {
        let matter = Matter(
            caseNo: caseNo.trimmingCharacters(in: .whitespaces),
            style: style.trimmingCharacters(in: .whitespaces),
            status: status
        )
        matter.petitioner = petitioner.trimmingCharacters(in: .whitespaces)
        matter.respondent = respondent.trimmingCharacters(in: .whitespaces)
        let trimmedCourt = court.trimmingCharacters(in: .whitespaces)
        if !trimmedCourt.isEmpty { matter.court = trimmedCourt }
        matter.county = county
        matter.division = division.trimmingCharacters(in: .whitespaces)
        matter.caseType = caseType
        matter.opposingCounsel = opposingCounsel.trimmingCharacters(in: .whitespaces)
        matter.clientName = clientName.trimmingCharacters(in: .whitespaces)
        matter.clientEmail = clientEmail.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        matter.rate = rate
        matter.notes = notes.trimmingCharacters(in: .whitespacesAndNewlines)
        if matter.style.isEmpty, !matter.petitioner.isEmpty, !matter.respondent.isEmpty {
            matter.style = "\(matter.petitioner) v. \(matter.respondent)"
        }
        context.insert(matter)
        try? context.save()
        dismiss()
    }
}

struct MatterDetailView: View {
    @Bindable var matter: Matter
    @Environment(\.modelContext) private var context
    @Query(sort: \MailMessage.sentAt, order: .reverse) private var allMail: [MailMessage]
    @Query(sort: \TimeEntry.createdAt, order: .reverse) private var allTime: [TimeEntry]
    @Query(sort: \MatterFile.createdAt, order: .reverse) private var allFiles: [MatterFile]
    @State private var editing = false

    private var linkedMail: [MailMessage] {
        allMail.filter { $0.matter?.persistentModelID == matter.persistentModelID }
    }

    private var linkedTime: [TimeEntry] {
        allTime.filter { $0.matter?.persistentModelID == matter.persistentModelID }
    }

    private var linkedFiles: [MatterFile] {
        allFiles.filter { $0.matter?.persistentModelID == matter.persistentModelID }
    }

    var body: some View {
        List {
            Section {
                if matter.isIntake {
                    Label("INTAKE — park unassigned mail here until linked to a real matter.", systemImage: "tray.full")
                        .praecipeFootnote()
                        .foregroundStyle(PraecipeColors.warning)
                }
                LabeledContent("Case no", value: matter.caseNo.isEmpty ? "—" : matter.caseNo)
                LabeledContent("Style", value: matter.style.isEmpty ? "—" : matter.style)
                LabeledContent("Case type", value: matter.caseType.isEmpty ? "—" : matter.caseType)
                LabeledContent("Status", value: matter.status)
                LabeledContent("County", value: matter.county.isEmpty ? "—" : matter.county)
                LabeledContent("Court", value: [matter.court, matter.division].filter { !$0.isEmpty }.joined(separator: " · "))
                if !matter.clientName.isEmpty || !matter.clientEmail.isEmpty {
                    LabeledContent("Client", value: [matter.clientName, matter.clientEmail].filter { !$0.isEmpty }.joined(separator: " · "))
                }
                if matter.rate > 0 {
                    LabeledContent("Rate", value: matter.rate.formatted(.currency(code: "USD")))
                }
            }

            Section("Linked mail (\(linkedMail.count))") {
                if linkedMail.isEmpty {
                    Text("No messages connected yet. Use File & Bill → Connect to matter on an email.")
                        .praecipeCaption()
                        .praecipeSecondaryText()
                } else {
                    ForEach(linkedMail.prefix(25)) { msg in
                        VStack(alignment: .leading, spacing: 2) {
                            HStack {
                                Text(msg.subject.isEmpty ? "(no subject)" : msg.subject)
                                    .praecipeBody()
                                if msg.timeBilled || FileAndBill.existingTimeEntry(for: msg, context: context) != nil {
                                    Text("Billed")
                                        .praecipeCaption2(.semibold)
                                        .foregroundStyle(PraecipeColors.accent)
                                }
                            }
                            Text(msg.fromAddr)
                                .praecipeCaption()
                                .praecipeSecondaryText()
                        }
                        .padding(.vertical, 2)
                    }
                }
            }

            Section("Time (\(linkedTime.count))") {
                if linkedTime.isEmpty {
                    Text("No time entries for this matter.")
                        .praecipeCaption()
                        .praecipeSecondaryText()
                } else {
                    ForEach(linkedTime.prefix(25)) { entry in
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(entry.activity.isEmpty ? "Time" : entry.activity).praecipeBody()
                                Text(entry.entryDescription)
                                    .praecipeCaption()
                                    .praecipeSecondaryText()
                            }
                            Spacer()
                            Text(LegalTime.displayHours(entry.hours)).praecipeBody()
                        }
                        .padding(.vertical, 2)
                    }
                }
            }

            Section("Files (\(linkedFiles.count))") {
                if linkedFiles.isEmpty {
                    Text("No files filed to this matter yet.")
                        .praecipeCaption()
                        .praecipeSecondaryText()
                } else {
                    ForEach(linkedFiles.prefix(25)) { file in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(file.filename).praecipeBody()
                            Text("\(file.docType) · \(file.source)")
                                .praecipeCaption()
                                .praecipeSecondaryText()
                        }
                        .padding(.vertical, 2)
                    }
                }
            }

            if !matter.notes.isEmpty {
                Section("Notes") {
                    Text(matter.notes).praecipeBody()
                }
            }
        }
        .praecipeGroupedList()
        .navigationTitle(matter.isIntake ? "Intake" : (matter.caseNo.isEmpty ? "Matter" : matter.caseNo))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button("Edit") { editing = true }
            }
        }
        .sheet(isPresented: $editing) {
            MatterEditor(matter: matter)
        }
    }
}

struct MatterEditor: View {
    @Bindable var matter: Matter
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                Section("Case") {
                    TextField("Case number", text: $matter.caseNo)
                        .textInputAutocapitalization(.characters)
                    TextField("Style", text: $matter.style)
                    Picker("Case type", selection: $matter.caseType) {
                        ForEach(CaseType.allCases) { Text($0.rawValue).tag($0.rawValue) }
                        if !CaseType.allCases.map(\.rawValue).contains(matter.caseType), !matter.caseType.isEmpty {
                            Text(matter.caseType).tag(matter.caseType)
                        }
                    }
                    Picker("Status", selection: $matter.status) {
                        ForEach(["Open", "Pending", "Closed", "Intake"], id: \.self) { Text($0) }
                        if !["Open", "Pending", "Closed", "Intake"].contains(matter.status), !matter.status.isEmpty {
                            Text(matter.status).tag(matter.status)
                        }
                    }
                }
                Section("Parties") {
                    TextField("Petitioner", text: $matter.petitioner)
                    TextField("Respondent", text: $matter.respondent)
                    TextField("Client name", text: $matter.clientName)
                    TextField("Client email", text: $matter.clientEmail)
                        .keyboardType(.emailAddress)
                        .textInputAutocapitalization(.never)
                    TextField("Opposing counsel", text: $matter.opposingCounsel)
                }
                Section("Court") {
                    TextField("Court", text: $matter.court)
                    Picker("County", selection: $matter.county) {
                        ForEach(FloridaCounties.all, id: \.self) { Text($0) }
                        if !FloridaCounties.all.contains(matter.county), !matter.county.isEmpty {
                            Text(matter.county).tag(matter.county)
                        }
                    }
                    TextField("Division", text: $matter.division)
                }
                Section("Billing") {
                    TextField("Hourly rate", value: $matter.rate, format: .currency(code: "USD"))
                        .keyboardType(.decimalPad)
                }
                Section("Notes") {
                    TextField("Notes", text: $matter.notes, axis: .vertical)
                        .lineLimit(3...10)
                }
            }
            .scrollContentBackground(.hidden)
            .background(PraecipeColors.background)
            .navigationTitle("Edit Matter")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") {
                        try? context.save()
                        dismiss()
                    }
                }
            }
        }
    }
}

struct PeopleHomeView: View {
    @Environment(\.modelContext) private var context
    @Query(sort: \Person.name) private var people: [Person]
    @State private var adding = false

    var body: some View {
        NavigationStack {
            List {
                if people.isEmpty {
                    ContentUnavailableView("No Contacts", systemImage: "person.crop.circle", description: Text("Add people you email with."))
                        .listRowSeparator(.hidden)
                }
                ForEach(people) { p in
                    VStack(alignment: .leading, spacing: 4) {
                        Text(p.name.isEmpty ? p.email : p.name).praecipeHeadline()
                        if !p.name.isEmpty {
                            Text(p.email).praecipeSubheadline().praecipeSecondaryText()
                        }
                        if !p.phone.isEmpty {
                            Text(p.phone).praecipeCaption().praecipeSecondaryText()
                        }
                    }
                    .padding(.vertical, 2)
                }
                .onDelete { idx in
                    idx.map { people[$0] }.forEach(context.delete)
                    try? context.save()
                }
            }
            .praecipeList()
            .navigationTitle("People")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        adding = true
                    } label: {
                        Label("Add Contact", systemImage: "plus")
                    }
                }
            }
            .sheet(isPresented: $adding) {
                AddContactSheet()
            }
        }
    }
}

struct AddContactSheet: View {
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var email = ""
    @State private var phone = ""

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Name", text: $name)
                    TextField("Email", text: $email)
                        .textInputAutocapitalization(.never)
                        .keyboardType(.emailAddress)
                        .textContentType(.emailAddress)
                    TextField("Phone", text: $phone)
                        .keyboardType(.phonePad)
                        .textContentType(.telephoneNumber)
                }
            }
            .scrollContentBackground(.hidden)
            .background(PraecipeColors.background)
            .navigationTitle("New Contact")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { save() }
                        .disabled(!canSave)
                }
            }
        }
    }

    private var canSave: Bool {
        email.trimmingCharacters(in: .whitespaces).contains("@")
    }

    private func save() {
        let trimmedEmail = email.trimmingCharacters(in: .whitespaces).lowercased()
        guard trimmedEmail.contains("@") else { return }
        let person = Person(email: trimmedEmail, name: name.trimmingCharacters(in: .whitespaces))
        person.phone = phone.trimmingCharacters(in: .whitespaces)
        context.insert(person)
        try? context.save()
        dismiss()
    }
}

struct TimeHomeView: View {
    @Environment(\.modelContext) private var context
    @Query(sort: \TimeEntry.createdAt, order: .reverse) private var entries: [TimeEntry]
    @Query private var matters: [Matter]
    @State private var hours = LegalTime.defaultHours
    @State private var activity = "email"
    @State private var desc = ""
    @State private var matter: Matter?

    var body: some View {
        List {
            Section("Add") {
                Picker("Matter", selection: $matter) {
                    Text("None").tag(Optional<Matter>.none)
                    ForEach(matters) { m in Text(m.label).tag(Optional(m)) }
                }
                TextField("Activity", text: $activity)
                TextField("Description", text: $desc)
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
                Button("Add time") {
                    let e = TimeEntry(minutes: LegalTime.minutes(fromHours: hours), activity: activity, description: desc)
                    e.matter = matter
                    e.rate = matter?.rate ?? 0
                    context.insert(e)
                    desc = ""
                }
                if let running = entries.first(where: \.running) {
                    let elapsed = LegalTime.hours(fromMinutes: Date().timeIntervalSince(running.startedAt ?? Date()) / 60)
                    Button("Stop timer (\(LegalTime.displayBoth(elapsed)))") {
                        running.running = false
                        running.endedAt = Date()
                        if let start = running.startedAt {
                            running.minutes = LegalTime.roundMinutes(Date().timeIntervalSince(start) / 60)
                        }
                    }
                } else {
                    Button("Start timer") {
                        let e = TimeEntry(activity: activity, description: desc)
                        e.running = true
                        e.startedAt = Date()
                        e.matter = matter
                        context.insert(e)
                    }
                }
            }
            Section("Entries") {
                ForEach(entries) { e in
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(e.matter?.label ?? "No matter").praecipeBody()
                            Text(e.entryDescription).praecipeCaption().praecipeSecondaryText()
                        }
                        Spacer()
                        VStack(alignment: .trailing, spacing: 2) {
                            Text(LegalTime.displayHours(e.hours)).praecipeBody()
                            Text(LegalTime.displayMinutes(fromHours: e.hours))
                                .praecipeCaption2()
                                .praecipeSecondaryText()
                        }
                    }
                    .padding(.vertical, 2)
                }
            }
            if let csv = csvData {
                ShareLink(item: csv, preview: SharePreview("time.csv")) { Label("Export CSV", systemImage: "square.and.arrow.up") }
            }
        }
        .praecipeGroupedList()
        .navigationTitle("Time")
    }

    private var csvData: URL? {
        let header = "When,Matter,Activity,Description,Hours,Minutes,Fee\n"
        let rows = entries.map { e in
            "\(e.createdAt.ISO8601Format()),\(e.matter?.label ?? ""),\(e.activity),\(e.entryDescription),\(e.hours),\(Int(e.minutes)),\(e.fee)"
        }.joined(separator: "\n")
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("time.csv")
        try? (header + rows).write(to: url, atomically: true, encoding: .utf8)
        return url
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
                VStack(alignment: .leading, spacing: 4) {
                    Text(n.title).praecipeHeadline()
                    Text(n.body).praecipeCaption()
                    if let m = n.matter { Text(m.label).praecipeCaption2().praecipeSecondaryText() }
                }
                .padding(.vertical, 2)
            }
        }
        .praecipeGroupedList()
        .navigationTitle("Notes")
    }
}

struct FilesHomeView: View {
    @Query(sort: \MatterFile.createdAt, order: .reverse) private var files: [MatterFile]

    var body: some View {
        List(files) { f in
            VStack(alignment: .leading, spacing: 4) {
                Text(f.filename).praecipeHeadline()
                Text("\(f.docType) · \(f.matter?.label ?? "unfiled")").praecipeCaption().praecipeSecondaryText()
                Text(f.relativePath).praecipeCaption2().praecipeTertiaryText()
            }
            .padding(.vertical, 2)
        }
        .praecipeList()
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
