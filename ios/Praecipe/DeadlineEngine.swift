import Foundation

struct DeadlineRule: Identifiable, Hashable {
    var id: String
    var title: String
    var rule: String
    var days: Int?
    var direction: String
    var unit: String
    var serviceExtra: Bool
    var statutory: Bool
    var triggerLabel: String
    var note: String
}

struct DeadlineResult {
    var ruleId: String
    var title: String
    var rule: String
    var trigger: Date
    var days: Int
    var direction: String
    var unit: String
    var due: Date
    var serviceExtraApplied: Bool
    var statutory: Bool
    var weekday: String
    var note: String
}

enum DeadlineEngine {
    static let catalog: [DeadlineRule] = [
        .init(id: "answer_20", title: "Answer / responsive pleading", rule: "Fla. Fam. L. R. P. 12.140; Fla. R. Civ. P. 1.140(a)", days: 20, direction: "after", unit: "days", serviceExtra: true, statutory: false, triggerLabel: "Date of service of process", note: "Twenty days after service of original process and the initial pleading, unless a statute or order shortens or enlarges the time."),
        .init(id: "counter_20", title: "Answer to counterpetition", rule: "Fla. Fam. L. R. P. 12.140; Fla. R. Civ. P. 1.140(a)", days: 20, direction: "after", unit: "days", serviceExtra: true, statutory: false, triggerLabel: "Date counterpetition was served", note: "Same responsive period as an initial pleading."),
        .init(id: "mandatory_disclosure_45", title: "Mandatory disclosure — initial", rule: "Fla. Fam. L. R. P. 12.285(b)", days: 45, direction: "after", unit: "days", serviceExtra: true, statutory: false, triggerLabel: "Date initial pleading was served on respondent", note: "Each party files and serves a financial affidavit and the 12.285(c) documents within 45 days of service of the initial pleading on the respondent."),
        .init(id: "temp_financial_2bd", title: "Temporary financial relief disclosures", rule: "Fla. Fam. L. R. P. 12.285(d)", days: 2, direction: "before", unit: "business_days", serviceExtra: false, statutory: false, triggerLabel: "Temporary financial hearing date", note: "Serve the financial affidavit and 12.285(c) disclosures at least 2 business days before the hearing if not already provided."),
        .init(id: "supplement_24h", title: "Supplemental disclosure before hearing", rule: "Fla. Fam. L. R. P. 12.285", days: 1, direction: "before", unit: "days", serviceExtra: false, statutory: false, triggerLabel: "Hearing date", note: "Continuing duty to supplement. Serve supplemental disclosure as soon as possible and in no event later than 24 hours before the applicable hearing."),
        .init(id: "rogs_30", title: "Answers to interrogatories", rule: "Fla. Fam. L. R. P. 12.340; Fla. R. Civ. P. 1.340", days: 30, direction: "after", unit: "days", serviceExtra: true, statutory: false, triggerLabel: "Date interrogatories were served", note: "Serve answers (and objections) within 30 days after service of the interrogatories."),
        .init(id: "rtp_30", title: "Response to request to produce", rule: "Fla. Fam. L. R. P. 12.350; Fla. R. Civ. P. 1.350", days: 30, direction: "after", unit: "days", serviceExtra: true, statutory: false, triggerLabel: "Date request to produce was served", note: "Written response within 30 days after service of the request."),
        .init(id: "rfa_30", title: "Response to requests for admission", rule: "Fla. Fam. L. R. P. 12.370; Fla. R. Civ. P. 1.370", days: 30, direction: "after", unit: "days", serviceExtra: true, statutory: false, triggerLabel: "Date requests for admission were served", note: "A matter is admitted unless a written answer or objection is served within 30 days after service of the request."),
        .init(id: "exam_30", title: "Response / objection to examination of persons", rule: "Fla. Fam. L. R. P. 12.360; Fla. R. Civ. P. 1.360", days: 30, direction: "after", unit: "days", serviceExtra: true, statutory: false, triggerLabel: "Date request for examination was served", note: "Serve a response stating compliance or objections within 30 days after service of the request."),
        .init(id: "magistrate_obj_10", title: "Objection to referral to general magistrate", rule: "Fla. Fam. L. R. P. 12.490", days: 10, direction: "after", unit: "days", serviceExtra: true, statutory: false, triggerLabel: "Date order of referral was served", note: "File an objection to the referral within 10 days of service of the order of referral."),
        .init(id: "magistrate_ex_10", title: "Exceptions to general magistrate report", rule: "Fla. Fam. L. R. P. 12.490", days: 10, direction: "after", unit: "days", serviceExtra: true, statutory: false, triggerLabel: "Date magistrate report was served", note: "File exceptions within 10 days from service of the report and recommendations."),
        .init(id: "csho_ex_10", title: "Exceptions to child support hearing officer", rule: "Fla. Fam. L. R. P. 12.491", days: 10, direction: "after", unit: "days", serviceExtra: true, statutory: false, triggerLabel: "Date recommended order was received / served", note: "File exceptions to the recommended order within 10 days of receipt."),
        .init(id: "rehearing_15", title: "Motion for rehearing", rule: "Fla. Fam. L. R. P. 12.530; Fla. R. Civ. P. 1.530", days: 15, direction: "after", unit: "days", serviceExtra: false, statutory: false, triggerLabel: "Date judgment / order was filed", note: "Serve a motion for rehearing not later than 15 days after the date of filing of the judgment."),
        .init(id: "default_check_20", title: "Possible default (no response)", rule: "Fla. Fam. L. R. P. 12.500; Fla. R. Civ. P. 1.500", days: 20, direction: "after", unit: "days", serviceExtra: false, statutory: false, triggerLabel: "Date of service of process", note: "Calendar the date after which a default may be sought if no paper is served."),
        .init(id: "injunction_return", title: "Injunction for protection — return hearing", rule: "Fla. Fam. L. R. P. 12.610; § 741.30 / 784.046, Fla. Stat.", days: 15, direction: "after", unit: "days", serviceExtra: false, statutory: true, triggerLabel: "Date temporary injunction issued / filed", note: "Return hearing is typically set within 15 days. Use the actual notice when a date is already on the order."),
        .init(id: "pfs_90", title: "Proposal for settlement — earliest serve", rule: "Fla. R. Civ. P. 1.442", days: 90, direction: "after", unit: "days", serviceExtra: false, statutory: false, triggerLabel: "Date of service of process", note: "A proposal may not be served sooner than 90 days after service of process."),
        .init(id: "pfs_accept_30", title: "Proposal for settlement — time to accept", rule: "Fla. R. Civ. P. 1.442", days: 30, direction: "after", unit: "days", serviceExtra: false, statutory: false, triggerLabel: "Date proposal for settlement was served", note: "A proposal is deemed rejected unless accepted in writing within 30 days after service."),
        .init(id: "pfs_45_before_trial", title: "Proposal for settlement — latest serve", rule: "Fla. R. Civ. P. 1.442", days: 45, direction: "before", unit: "days", serviceExtra: false, statutory: false, triggerLabel: "Trial date", note: "Do not serve a proposal later than 45 days before the trial date."),
        .init(id: "appeal_final_30", title: "Appeal of final order", rule: "Fla. R. App. P. 9.110(b)", days: 30, direction: "after", unit: "days", serviceExtra: false, statutory: true, triggerLabel: "Date order / judgment was rendered (filed)", note: "Notice of appeal generally must be filed within 30 days of rendition. No extra 5 days."),
        .init(id: "appeal_nonfinal_30", title: "Appeal of nonfinal order", rule: "Fla. R. App. P. 9.130", days: 30, direction: "after", unit: "days", serviceExtra: false, statutory: true, triggerLabel: "Date nonfinal order was rendered", note: "Thirty days from rendition of an appealable nonfinal order. No extra 5 days."),
        .init(id: "relocation_notice_60", title: "Relocation — notice before moving", rule: "§ 61.13001, Fla. Stat.", days: 60, direction: "before", unit: "days", serviceExtra: false, statutory: true, triggerLabel: "Proposed relocation date", note: "A parent must typically give notice of a proposed relocation 60 days before. Use the statute and form 12.950."),
        .init(id: "relocation_obj_20", title: "Relocation — objection", rule: "§ 61.13001, Fla. Stat.; Form 12.950", days: 20, direction: "after", unit: "days", serviceExtra: false, statutory: true, triggerLabel: "Date notice of intent to relocate was served", note: "File and serve a written objection within the statutory window stated on the notice (commonly 20 days)."),
        .init(id: "notice_hearing_7", title: "Notice of hearing (reasonable notice)", rule: "Fla. Fam. L. R. P. 12.090; 12.440; local practice", days: 7, direction: "before", unit: "days", serviceExtra: false, statutory: false, triggerLabel: "Hearing date", note: "Many family divisions expect at least 5–7 days unless the court shortens time."),
        .init(id: "discovery_cutoff_30", title: "Discovery cutoff (if no order)", rule: "Fla. Fam. L. R. P. 12.200 / trial order", days: 30, direction: "before", unit: "days", serviceExtra: false, statutory: false, triggerLabel: "Trial date", note: "Use the case-management or trial order when one exists."),
        .init(id: "custom", title: "Custom period (Rule 12.090 / 2.514 counting)", rule: "Fla. Fam. L. R. P. 12.090; Fla. R. Gen. Prac. & Jud. Admin. 2.514", days: nil, direction: "after", unit: "days", serviceExtra: true, statutory: false, triggerLabel: "Trigger date", note: "Counting excludes the trigger day, includes intermediate weekends, and rolls the last day if it is a Saturday, Sunday, or legal holiday."),
    ]

    static func compute(ruleId: String, trigger: Date, days: Int? = nil, serviceMailOrEmail: Bool = false) -> DeadlineResult? {
        guard let item = catalog.first(where: { $0.id == ruleId }) else { return nil }
        guard let n = days ?? item.days else { return nil }
        let calendar = Calendar.current
        let triggerDay = calendar.startOfDay(for: trigger)
        let extraOK = item.serviceExtra && !item.statutory && serviceMailOrEmail
        var due: Date
        if item.unit == "business_days" {
            due = addBusinessDays(triggerDay, n, before: item.direction == "before")
        } else if item.direction == "before" {
            due = addDays2514(triggerDay, -n)
        } else {
            due = addDays2514(triggerDay, n)
        }
        var extra = false
        if extraOK && item.direction == "after" && item.unit == "days" {
            due = addFiveAfterService(due)
            extra = true
        }
        let df = DateFormatter()
        df.dateFormat = "EEEE"
        return DeadlineResult(
            ruleId: item.id, title: item.title, rule: item.rule, trigger: triggerDay,
            days: n, direction: item.direction, unit: item.unit, due: due,
            serviceExtraApplied: extra, statutory: item.statutory,
            weekday: df.string(from: due), note: item.note
        )
    }

    static func legalHolidays(_ year: Int) -> Set<DateComponents> {
        [
            DateComponents(year: year, month: 1, day: 1),
            nthWeekday(year, 1, 2, 3),
            nthWeekday(year, 2, 2, 3),
            lastWeekday(year, 5, 2),
            DateComponents(year: year, month: 7, day: 4),
            nthWeekday(year, 9, 2, 1),
            nthWeekday(year, 10, 2, 2),
            DateComponents(year: year, month: 11, day: 11),
            nthWeekday(year, 11, 5, 4),
            DateComponents(year: year, month: 12, day: 25),
        ]
    }

    static func isLegalHoliday(_ date: Date) -> Bool {
        let c = Calendar.current
        let y = c.component(.year, from: date)
        let md = DateComponents(year: y, month: c.component(.month, from: date), day: c.component(.day, from: date))
        return legalHolidays(y).contains(md) || legalHolidays(y - 1).contains(md) || legalHolidays(y + 1).contains(md)
    }

    static func isNonBusiness(_ date: Date) -> Bool {
        let w = Calendar.current.component(.weekday, from: date)
        return w == 1 || w == 7 || isLegalHoliday(date)
    }

    static func rollForward(_ date: Date) -> Date {
        var d = date
        while isNonBusiness(d) { d = Calendar.current.date(byAdding: .day, value: 1, to: d)! }
        return d
    }

    static func addDays2514(_ trigger: Date, _ days: Int) -> Date {
        if days == 0 { return rollForward(trigger) }
        let step = days > 0 ? 1 : -1
        var remaining = abs(days)
        var current = trigger
        while remaining > 0 {
            current = Calendar.current.date(byAdding: .day, value: step, to: current)!
            remaining -= 1
        }
        if days > 0 { return rollForward(current) }
        while isNonBusiness(current) {
            current = Calendar.current.date(byAdding: .day, value: -1, to: current)!
        }
        return current
    }

    static func addFiveAfterService(_ expiry: Date) -> Date {
        rollForward(Calendar.current.date(byAdding: .day, value: 5, to: expiry)!)
    }

    static func addBusinessDays(_ start: Date, _ n: Int, before: Bool) -> Date {
        let step = before ? -1 : 1
        var remaining = abs(n)
        var current = start
        while remaining > 0 {
            current = Calendar.current.date(byAdding: .day, value: step, to: current)!
            if !isNonBusiness(current) { remaining -= 1 }
        }
        return current
    }

    private static func nthWeekday(_ year: Int, _ month: Int, _ weekday: Int, _ n: Int) -> DateComponents {
        var c = DateComponents(year: year, month: month, weekday: weekday, weekdayOrdinal: n)
        if let d = Calendar.current.date(from: c) {
            return Calendar.current.dateComponents([.year, .month, .day], from: d)
        }
        return c
    }

    private static func lastWeekday(_ year: Int, _ month: Int, _ weekday: Int) -> DateComponents {
        var c = DateComponents(year: year, month: month, weekday: weekday, weekdayOrdinal: -1)
        if let d = Calendar.current.date(from: c) {
            return Calendar.current.dateComponents([.year, .month, .day], from: d)
        }
        return c
    }
}

