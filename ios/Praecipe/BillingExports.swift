import Foundation
import UIKit

enum BillingExports {
    static func csv(entries: [TimeEntry]) throws -> URL {
        var rows = [["When", "Matter", "Activity", "Description", "Minutes", "Rate", "Fee", "Billed", "LawPay invoice", "LawPay status"]]
        rows += entries.map { entry in
            [
                entry.createdAt.ISO8601Format(),
                entry.matter?.label ?? "",
                entry.activity,
                entry.entryDescription,
                String(format: "%.2f", entry.minutes),
                String(format: "%.2f", entry.rate),
                String(format: "%.2f", entry.fee),
                entry.billed ? "Yes" : "No",
                entry.lawPayInvoiceNumber ?? entry.lawPayInvoiceID ?? "",
                entry.lawPayStatus ?? "",
            ]
        }
        let text = rows.map { $0.map(csvField).joined(separator: ",") }.joined(separator: "\r\n") + "\r\n"
        let url = uniqueTemporaryURL(name: "Praecipe-Time", extension: "csv")
        // UTF-8 BOM makes client names and legal descriptions open correctly in Excel.
        var data = Data([0xEF, 0xBB, 0xBF])
        data.append(Data(text.utf8))
        try data.write(to: url, options: [.atomic, .completeFileProtection])
        return url
    }

    @MainActor
    static func pdf(entries: [TimeEntry]) throws -> URL {
        let url = uniqueTemporaryURL(name: "Praecipe-Billing-Report", extension: "pdf")
        let page = CGRect(x: 0, y: 0, width: 612, height: 792)
        let renderer = UIGraphicsPDFRenderer(bounds: page)
        let totalMinutes = entries.reduce(0) { $0 + $1.minutes }
        let totalFees = entries.reduce(0) { $0 + $1.fee }
        let currency = NumberFormatter()
        currency.numberStyle = .currency
        currency.currencyCode = "USD"
        let totalText = currency.string(from: NSNumber(value: totalFees)) ?? String(format: "$%.2f", totalFees)

        try renderer.writePDF(to: url) { context in
            MainActor.assumeIsolated { @MainActor in
                var y: CGFloat = 0
                @MainActor func beginPage() {
                    context.beginPage()
                    y = 44
                    draw("Praecipe Billing Report", at: CGPoint(x: 44, y: y), font: .boldSystemFont(ofSize: 20))
                    y += 28
                    draw(Date().formatted(date: .long, time: .shortened), at: CGPoint(x: 44, y: y), font: .systemFont(ofSize: 10), color: .darkGray)
                    y += 28
                    draw("Date", at: CGPoint(x: 44, y: y), font: .boldSystemFont(ofSize: 9))
                    draw("Matter / Description", at: CGPoint(x: 110, y: y), font: .boldSystemFont(ofSize: 9))
                    draw("Minutes", at: CGPoint(x: 470, y: y), font: .boldSystemFont(ofSize: 9))
                    draw("Fee", at: CGPoint(x: 530, y: y), font: .boldSystemFont(ofSize: 9))
                    y += 16
                    UIColor.lightGray.setStroke()
                    context.cgContext.move(to: CGPoint(x: 44, y: y))
                    context.cgContext.addLine(to: CGPoint(x: 568, y: y))
                    context.cgContext.strokePath()
                    y += 10
                }

                beginPage()
                for entry in entries {
                    let description = [entry.matter?.label, entry.activity, entry.entryDescription]
                        .compactMap { value in value?.isEmpty == false ? value : nil }
                        .joined(separator: " — ")
                    let itemHeight = max(30, textHeight(description, width: 342, font: .systemFont(ofSize: 9)) + 10)
                    if y + itemHeight > 730 { beginPage() }
                    draw(entry.createdAt.formatted(date: .numeric, time: .omitted), at: CGPoint(x: 44, y: y), font: .systemFont(ofSize: 9))
                    draw(description, in: CGRect(x: 110, y: y, width: 342, height: itemHeight), font: .systemFont(ofSize: 9))
                    draw(String(format: "%.1f", entry.minutes), at: CGPoint(x: 470, y: y), font: .systemFont(ofSize: 9))
                    draw(String(format: "$%.2f", entry.fee), at: CGPoint(x: 530, y: y), font: .systemFont(ofSize: 9))
                    y += itemHeight
                }
                if y + 52 > 730 { beginPage() }
                UIColor.lightGray.setStroke()
                context.cgContext.move(to: CGPoint(x: 44, y: y))
                context.cgContext.addLine(to: CGPoint(x: 568, y: y))
                context.cgContext.strokePath()
                y += 12
                draw("Total: \(String(format: "%.1f", totalMinutes)) minutes", at: CGPoint(x: 380, y: y), font: .boldSystemFont(ofSize: 10))
                draw(totalText, at: CGPoint(x: 530, y: y), font: .boldSystemFont(ofSize: 10))
            }
        }
        try FileManager.default.setAttributes([.protectionKey: FileProtectionType.complete], ofItemAtPath: url.path)
        return url
    }

    private static func csvField(_ value: String) -> String {
        "\"" + value.replacingOccurrences(of: "\"", with: "\"\"") + "\""
    }

    private static func uniqueTemporaryURL(name: String, extension ext: String) -> URL {
        let stamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-")
        return FileManager.default.temporaryDirectory.appendingPathComponent("\(name)-\(stamp).\(ext)")
    }

    @MainActor
    private static func draw(_ text: String, at point: CGPoint, font: UIFont, color: UIColor = .black) {
        text.draw(at: point, withAttributes: [.font: font, .foregroundColor: color])
    }

    @MainActor
    private static func draw(_ text: String, in rect: CGRect, font: UIFont, color: UIColor = .black) {
        text.draw(in: rect, withAttributes: [.font: font, .foregroundColor: color])
    }

    @MainActor
    private static func textHeight(_ text: String, width: CGFloat, font: UIFont) -> CGFloat {
        text.boundingRect(
            with: CGSize(width: width, height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading],
            attributes: [.font: font],
            context: nil
        ).height
    }
}
