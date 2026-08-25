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
                    .praecipeFootnote(.semibold)
                    .foregroundStyle(PraecipeColors.textPrimary)
                    .padding(10)
                    .frame(maxWidth: .infinity)
                    .background(PraecipeColors.warning.opacity(0.55))
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
                Section {
                    HStack(spacing: 16) {
                        Image("AppLogo")
                            .resizable()
                            .scaledToFit()
                            .frame(width: 56, height: 56)
                            .accessibilityHidden(true)
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Praecipe")
                                .praecipeTitle()
                            Text("Legal practice on iPhone")
                                .praecipeSubheadline()
                                .praecipeSecondaryText()
                        }
                    }
                    .padding(.vertical, 4)
                }
                NavigationLink { TimeHomeView() } label: { Label("Time", systemImage: "clock") }
                NavigationLink { NotesHomeView() } label: { Label("Notes", systemImage: "note.text") }
                NavigationLink { FilesHomeView() } label: { Label("Files", systemImage: "paperclip") }
                NavigationLink { RulesHomeView() } label: { Label("Rules", systemImage: "ruler") }
                NavigationLink { SettingsView() } label: { Label("Mail Accounts", systemImage: "gear") }
                    .accessibilityIdentifier("mailAccountsLink")
                Section("About") {
                    LabeledContent("Version", value: AppInfo.version)
                    LabeledContent("Build", value: AppInfo.build)
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Copyright © \(AppInfo.copyrightYear) Destrier")
                            .praecipeSubheadline()
                        Text("Made by Destrier")
                            .praecipeCaption()
                            .praecipeSecondaryText()
                    }
                    .padding(.vertical, 2)
                }
            }
            .praecipeGroupedList()
            .navigationTitle("More")
        }
    }
}

enum AppInfo {
    static var version: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "—"
    }

    static var build: String {
        Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "—"
    }

    static var copyrightYear: String {
        "2026"
    }
}
