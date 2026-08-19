import SwiftData
import SwiftUI

struct CalendarHomeView: View {
    @Environment(\.modelContext) private var context
    @Query(sort: \CalendarEvent.startAt) private var events: [CalendarEvent]
    @Query private var matters: [Matter]
    @State private var title = ""
    @State private var date = Date()
    @State private var allDay = true
    @State private var matter: Matter?
    @State private var month = Date()

    var body: some View {
        NavigationStack {
            List {
                Section(month.formatted(.dateTime.month(.wide).year())) {
                    ForEach(eventsInMonth) { e in
                        HStack {
                            VStack(alignment: .leading) {
                                Text(e.title).font(.headline)
                                Text(e.startAt, style: e.allDay ? .date : .date)
                                    .font(.caption)
                                if let m = e.matter { Text(m.label).font(.caption2).foregroundStyle(.secondary) }
                            }
                            Spacer()
                            if !e.ruleCite.isEmpty {
                                Text(e.ruleCite).font(.caption2).foregroundStyle(.orange)
                            }
                        }
                    }
                }
                Section("Add") {
                    TextField("Title", text: $title)
                    DatePicker("When", selection: $date, displayedComponents: allDay ? .date : [.date, .hourAndMinute])
                    Toggle("All day", isOn: $allDay)
                    Picker("Matter", selection: $matter) {
                        Text("None").tag(Optional<Matter>.none)
                        ForEach(matters) { m in Text(m.label).tag(Optional(m)) }
                    }
                    Button("Add to calendar") {
                        let e = CalendarEvent(title: title, startAt: date, allDay: allDay)
                        e.matter = matter
                        context.insert(e)
                        title = ""
                    }
                    .disabled(title.isEmpty)
                }
            }
            .navigationTitle("Calendar")
            .toolbar {
                NavigationLink("Rules") { RulesHomeView() }
            }
        }
    }

    private var eventsInMonth: [CalendarEvent] {
        let cal = Calendar.current
        return events.filter { cal.isDate($0.startAt, equalTo: month, toGranularity: .month) }
    }
}

struct RulesHomeView: View {
    @Environment(\.modelContext) private var context
    @Query private var matters: [Matter]
    @State private var rule = DeadlineEngine.catalog[0]
    @State private var trigger = Date()
    @State private var customDays = 20
    @State private var extra = false
    @State private var matter: Matter?
    @State private var result: DeadlineResult?

    var body: some View {
        Form {
            Picker("Rule", selection: $rule) {
                ForEach(DeadlineEngine.catalog) { r in
                    Text(r.title).tag(r)
                }
            }
            DatePicker(rule.triggerLabel, selection: $trigger, displayedComponents: .date)
            if rule.id == "custom" {
                Stepper("Days: \(customDays)", value: $customDays, in: 1...365)
            }
            Toggle("Add 5 days for mail/e-mail service (Rule 2.514(b))", isOn: $extra)
                .disabled(rule.statutory || !rule.serviceExtra)
            Picker("Matter", selection: $matter) {
                Text("None").tag(Optional<Matter>.none)
                ForEach(matters) { m in Text(m.label).tag(Optional(m)) }
            }
            Button("Compute") {
                result = DeadlineEngine.compute(
                    ruleId: rule.id,
                    trigger: trigger,
                    days: rule.id == "custom" ? customDays : nil,
                    serviceMailOrEmail: extra
                )
            }
            if let result {
                LabeledContent("Due", value: result.due.formatted(date: .long, time: .omitted))
                LabeledContent("Weekday", value: result.weekday)
                if result.serviceExtraApplied { Text("Includes extra 5 days after service.").font(.caption) }
                Text(result.note).font(.caption).foregroundStyle(.secondary)
                Text("Practice aid, not legal advice. Confirm against the current rules, any statute, the judge’s order, and local administrative practice.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Button("Put on calendar") {
                    let e = CalendarEvent(title: result.title, startAt: result.due, eventType: "deadline", allDay: true)
                    e.ruleCite = result.rule
                    e.matter = matter
                    e.notes = result.note
                    e.source = "rules"
                    context.insert(e)
                }
            }
        }
        .navigationTitle("Rules")
    }
}
