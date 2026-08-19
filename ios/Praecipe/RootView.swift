import SwiftData
import SwiftUI

struct RootView: View {
    @Environment(\.modelContext) private var context
    @StateObject private var mail = MailSyncService()
    @Query private var reminders: [CalendarEvent]
    @State private var search = ""

    var body: some View {
        TabView {
            MailHomeView(search: $search)
                .tabItem { Label("Mail", systemImage: "envelope") }
            CalendarHomeView()
                .tabItem { Label("Calendar", systemImage: "calendar") }
            PeopleHomeView()
                .tabItem { Label("People", systemImage: "person.2") }
            MattersHomeView()
                .tabItem { Label("Matters", systemImage: "folder") }
            MoreHomeView()
                .tabItem { Label("More", systemImage: "ellipsis.circle") }
        }
        .environmentObject(mail)
        .safeAreaInset(edge: .top, spacing: 0) {
            if !dueReminders.isEmpty {
                Text(dueReminders.map(\.title).joined(separator: " · "))
                    .font(.footnote.weight(.semibold))
                    .padding(8)
                    .frame(maxWidth: .infinity)
                    .background(Color.orange)
            }
        }
        .onAppear {
            AppStore.seedIfNeeded(context)
            mail.startPolling(context: context)
        }
    }

    private var dueReminders: [CalendarEvent] {
        let soon = Date().addingTimeInterval(3600)
        return reminders.filter { !$0.dismissed && $0.startAt <= soon && $0.startAt >= Date().addingTimeInterval(-3600) }
    }
}

struct MoreHomeView: View {
    var body: some View {
        NavigationStack {
            List {
                NavigationLink { TimeHomeView() } label: { Label("Time", systemImage: "clock") }
                NavigationLink { NotesHomeView() } label: { Label("Notes", systemImage: "note.text") }
                NavigationLink { FilesHomeView() } label: { Label("Files", systemImage: "paperclip") }
                NavigationLink { RulesHomeView() } label: { Label("Rules", systemImage: "ruler") }
                NavigationLink { SettingsView() } label: { Label("Settings", systemImage: "gear") }
            }
            .navigationTitle("Praecipe")
        }
    }
}
