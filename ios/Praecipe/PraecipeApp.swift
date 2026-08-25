import Foundation
import SwiftData
import SwiftUI

@main
struct PraecipeApp: App {
    var sharedModelContainer: ModelContainer = AppStore.makeModelContainer()

    init() {
        PraecipeTheme.configureAppearance()
        #if DEBUG
        let fails = MailAuthSelfCheck.failures()
        assert(fails.isEmpty, fails.joined(separator: "\n"))
        #endif
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .praecipeThemed()
                .onOpenURL { url in
                    NotificationCenter.default.post(name: .praecipeMicrosoftOAuthURL, object: url)
                }
        }
        .modelContainer(sharedModelContainer)
    }
}

enum AppStore {
    static let filesRoot: URL = {
        let url = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("matters", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }()

    static func makeModelContainer() -> ModelContainer {
        let schema = Schema([
            MailAccount.self, Matter.self, MailMessage.self, MailAttachment.self,
            TimeEntry.self, PracticeNote.self, CalendarEvent.self, MatterFile.self,
            Person.self, MailSignature.self, AppSetting.self,
        ])
        let config = ModelConfiguration(schema: schema, isStoredInMemoryOnly: false)
        do {
            return try ModelContainer(for: schema, configurations: [config])
        } catch {
            // Schema changed on device — wipe local store once and reopen.
            removeSwiftDataStore(at: config.url)
            do {
                return try ModelContainer(for: schema, configurations: [config])
            } catch {
                let memory = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
                return try! ModelContainer(for: schema, configurations: [memory])
            }
        }
    }

    private static func removeSwiftDataStore(at url: URL) {
        let fm = FileManager.default
        for suffix in ["", "-wal", "-shm"] {
            let file = URL(fileURLWithPath: url.path + suffix)
            try? fm.removeItem(at: file)
        }
    }

    static func seedIfNeeded(_ context: ModelContext) {
        let matterCount = (try? context.fetchCount(FetchDescriptor<Matter>())) ?? 0
        if matterCount == 0 {
            let intake = Matter(caseNo: "INTAKE", style: "Intake / unassigned mail", status: "Intake")
            intake.notes = "Park mail here until it is attached to a matter."
            intake.caseType = CaseType.oth.rawValue
            intake.rate = 0
            context.insert(intake)
        }
        let sigCount = (try? context.fetchCount(FetchDescriptor<MailSignature>())) ?? 0
        if sigCount == 0 {
            let body = """
            Kenneth Turner
            Attorney and Counselor at Law

            CONFIDENTIALITY NOTICE: This electronic message and any attachments are confidential and may be protected by the attorney-client privilege. If you are not the intended recipient, please notify the sender immediately, delete the message, and do not copy or disclose its contents.
            """
            context.insert(MailSignature(name: "Standard", body: body, isDefault: true))
        }
        MicrosoftOAuth.discardJunkStoredClientIDs(context)
        MicrosoftOAuth.restoreAccounts(into: context)
        try? context.save()
    }
}
