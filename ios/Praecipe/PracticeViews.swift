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
                    desc = ""
                }
                if let running = entries.first(where: \.running) {
                    Button("Stop timer (\(Int((Date().timeIntervalSince(running.startedAt ?? Date())) / 60)) min)") {
                        running.running = false
                        running.endedAt = Date()
                        if let start = running.startedAt {
                            running.minutes = max(0.1, Date().timeIntervalSince(start) / 60)
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
                        VStack(alignment: .leading) {
                            Text(e.matter?.label ?? "No matter")
                            Text(e.entryDescription).font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Text("\(e.minutes, specifier: "%.1f") m")
                    }
                }
            }
            if let csv = csvData {
                ShareLink(item: csv, preview: SharePreview("time.csv")) { Label("Export CSV", systemImage: "square.and.arrow.up") }
            }
        }
        .navigationTitle("Time")
    }

    private var csvData: URL? {
        let header = "When,Matter,Activity,Description,Minutes,Fee\n"
        let rows = entries.map { e in
            "\(e.createdAt.ISO8601Format()),\(e.matter?.label ?? ""),\(e.activity),\(e.entryDescription),\(e.minutes),\(e.fee)"
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
