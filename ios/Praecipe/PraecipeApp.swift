import Foundation
import SwiftData
import SwiftUI

@main
struct PraecipeApp: App {
    var sharedModelContainer: ModelContainer = {
        let schema = Schema([
            MailAccount.self, Matter.self, MailMessage.self, MailAttachment.self,
            TimeEntry.self, PracticeNote.self, CalendarEvent.self, MatterFile.self,
            Person.self, MailSignature.self, AppSetting.self,
        ])
        #if PRAECIPE_ICLOUD
        let config = ModelConfiguration(schema: schema, isStoredInMemoryOnly: false, cloudKitDatabase: .automatic)
        #else
        let config = ModelConfiguration(schema: schema, isStoredInMemoryOnly: false)
        #endif
        do {
            return try ModelContainer(for: schema, configurations: [config])
        } catch {
            fatalError("SwiftData failed: \(error)")
        }
    }()

    var body: some Scene {
        WindowGroup {
            RootView()
        }
        .modelContainer(sharedModelContainer)
    }
}

enum AppStore {
    static let filesRoot: URL = {
        let url = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("matters", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        try? FileManager.default.setAttributes([.protectionKey: FileProtectionType.complete], ofItemAtPath: url.path)
        return url
    }()

    static func seedIfNeeded(_ context: ModelContext) {
        let matterCount = (try? context.fetchCount(FetchDescriptor<Matter>())) ?? 0
        if matterCount == 0 {
            let intake = Matter(caseNo: "INTAKE", style: "Intake / unassigned mail")
            intake.notes = "Park mail here until it is attached to a matter."
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
        try? context.save()
    }
}
