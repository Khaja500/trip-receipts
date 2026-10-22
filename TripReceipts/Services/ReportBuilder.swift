import Foundation
import UIKit
import PDFKit

/// Builds the reimbursement pack: a PDF a finance team can read end to end,
/// and a CSV they can paste into a sheet.
enum ReportBuilder {

    struct Pack {
        var pdfURL: URL
        var csvURL: URL
    }

    // Page geometry, A4 at 72dpi.
    private static let pageSize = CGSize(width: 595, height: 842)
    private static let margin: CGFloat = 40

    static func build(title: String, subtitle: String, payments: [Payment]) throws -> Pack {
        let sorted = payments.sorted { $0.paidAt < $1.paidAt }
        let safeName = title.replacingOccurrences(of: "[^A-Za-z0-9-_ ]", with: "",
                                                  options: .regularExpression)
            .trimmingCharacters(in: .whitespaces)
        let base = safeName.isEmpty ? "Expenses" : safeName
        let directory = FileManager.default.temporaryDirectory

        let pdfURL = directory.appendingPathComponent("\(base).pdf")
        try pdf(title: title, subtitle: subtitle, payments: sorted).write(to: pdfURL)

        let csvURL = directory.appendingPathComponent("\(base).csv")
        try Data(csv(payments: sorted).utf8).write(to: csvURL)

        return Pack(pdfURL: pdfURL, csvURL: csvURL)
    }

    // MARK: - PDF

    static func pdf(title: String, subtitle: String, payments: [Payment]) -> Data {
        let renderer = UIGraphicsPDFRenderer(bounds: CGRect(origin: .zero, size: pageSize))
        return renderer.pdfData { ctx in
            var cursor = Cursor(ctx: ctx, pageSize: pageSize, margin: margin)
            cursor.newPage()

            // Summary
            cursor.draw(title, font: .boldSystemFont(ofSize: 22))
            cursor.draw(subtitle, font: .systemFont(ofSize: 12), color: .darkGray)
            cursor.space(10)

            let currency = payments.first?.currency ?? "INR"
            let total = payments.reduce(0) { $0 + $1.netClaimable }
            let missing = payments.filter { !$0.hasReceipt }.count

            cursor.draw("Total claimed: \(Money.string(total, currency: currency))",
                        font: .boldSystemFont(ofSize: 16))
            cursor.draw("\(payments.count) expenses · \(missing) without a receipt",
                        font: .systemFont(ofSize: 11), color: .darkGray)
            let statuses = payments.compactMap { $0.verification?.status }
            if !statuses.isEmpty {
                let count = { (status: VerificationStatus) in statuses.filter { $0 == status }.count }
                cursor.draw("Receipts: \(count(.matched)) verified · \(count(.warning)) with a warning · "
                            + "\(count(.unverified)) unverified",
                            font: .systemFont(ofSize: 11), color: .darkGray)
            }
            cursor.space(14)

            // Every receipt that doesn't match, said plainly, before anything else.
            let warnings = payments.filter { $0.verification?.status == .warning }
            if !warnings.isEmpty {
                cursor.draw("Receipt warnings", font: .boldSystemFont(ofSize: 13), color: .systemRed)
                cursor.space(4)
                for payment in warnings {
                    guard let check = payment.verification else { continue }
                    cursor.draw("⚠ \(shortDate(payment.paidAt))  \(payment.merchant) — "
                                + check.result(for: payment).summary,
                                font: .systemFont(ofSize: 10))
                    cursor.draw(check.overriddenByUser
                                ? "Added to the trip anyway"
                                  + (check.userNote.isEmpty ? "." : ": \u{201C}\(check.userNote)\u{201D}")
                                : "Not resolved: no matching receipt yet.",
                                font: .italicSystemFont(ofSize: 9), color: .darkGray)
                    cursor.space(3)
                }
                cursor.space(11)
            }

            // By category
            var byCategory: [ExpenseCategory: Double] = [:]
            for p in payments { byCategory[p.category, default: 0] += p.netClaimable }
            if !byCategory.isEmpty {
                cursor.draw("By category", font: .boldSystemFont(ofSize: 13))
                cursor.space(4)
                for (category, amount) in byCategory.sorted(by: { $0.value > $1.value }) {
                    cursor.drawRow(left: category.title,
                                   right: Money.string(amount, currency: currency))
                }
                cursor.space(14)
            }

            // Line items
            cursor.draw("Expenses", font: .boldSystemFont(ofSize: 13))
            cursor.space(4)
            cursor.drawRow(left: "Date    Payee", right: "Amount", bold: true)
            cursor.rule()
            for payment in payments {
                cursor.drawRow(
                    left: "\(shortDate(payment.paidAt))  \(payment.merchant)\(mark(payment))",
                    right: Money.string(payment.netClaimable, currency: payment.currency)
                )
            }
            cursor.rule()
            cursor.drawRow(left: "Total", right: Money.string(total, currency: currency), bold: true)
            if !statuses.isEmpty {
                cursor.space(4)
                cursor.draw("✓ receipt matches the payment · ⚠ receipt doesn't match · ○ receipt not verified",
                            font: .systemFont(ofSize: 8), color: .gray)
            }

            // One page per expense: the detail, the proof, the receipts.
            for (index, payment) in payments.enumerated() {
                cursor.newPage()
                cursor.draw("Expense \(index + 1) of \(payments.count)",
                            font: .systemFont(ofSize: 10), color: .gray)
                cursor.space(2)
                cursor.draw(payment.merchant, font: .boldSystemFont(ofSize: 18))
                cursor.draw(Money.string(payment.netClaimable, currency: payment.currency),
                            font: .boldSystemFont(ofSize: 16))
                cursor.space(8)

                cursor.drawField("Date", longDate(payment.paidAt))
                cursor.drawField("Category", payment.category.title)
                if !payment.instrument.isEmpty { cursor.drawField("Paid by", payment.instrument) }
                if let bank = payment.bank { cursor.drawField("Bank", bank) }
                if let reference = payment.reference { cursor.drawField("Reference", reference) }
                if payment.refundedAmount > 0 {
                    cursor.drawField("Refunded",
                                     Money.string(payment.refundedAmount, currency: payment.currency))
                    cursor.drawField("Billed",
                                     Money.string(payment.amount, currency: payment.currency))
                }
                if payment.claimableAmount != payment.amount {
                    cursor.drawField("Claimed portion",
                                     "\(Money.string(payment.claimableAmount, currency: payment.currency)) "
                                     + "of \(Money.string(payment.amount, currency: payment.currency))")
                }
                if !payment.notes.isEmpty { cursor.drawField("Notes", payment.notes) }
                cursor.space(10)

                // Proof of payment
                if payment.isManual {
                    cursor.draw("Entered manually — no bank message.",
                                font: .italicSystemFont(ofSize: 10), color: .darkGray)
                } else {
                    cursor.draw("Proof of payment — original message", font: .boldSystemFont(ofSize: 12))
                    cursor.space(3)
                    cursor.draw("From \(payment.sender) · \(longDate(payment.receivedAt))",
                                font: .systemFont(ofSize: 9), color: .gray)
                    cursor.space(3)
                    cursor.drawQuote(payment.rawMessage)
                    cursor.space(4)
                    let intact = payment.proofIsIntact
                    cursor.draw("SHA-256 \(payment.messageHash)",
                                font: .monospacedSystemFont(ofSize: 7, weight: .regular), color: .gray)
                    cursor.draw(intact ? "Message matches the fingerprint taken at capture."
                                       : "Warning: message no longer matches its fingerprint.",
                                font: .systemFont(ofSize: 9),
                                color: intact ? .darkGray : .red)

                    for extra in payment.additionalMessages {
                        cursor.space(6)
                        cursor.draw("Additional message — \(extra.sender)",
                                    font: .boldSystemFont(ofSize: 10))
                        cursor.drawQuote(extra.text)
                    }
                }

                // What each receipt was checked against, and how it came out.
                for receipt in payment.receipts.sorted(by: { $0.addedAt < $1.addedAt }) {
                    if let check = receipt.verification {
                        cursor.space(10)
                        drawCheck(check, receipt: receipt, payment: payment, on: &cursor)
                    }
                }

                // Receipts
                if payment.receipts.isEmpty {
                    cursor.space(10)
                    cursor.draw("No receipt attached.", font: .italicSystemFont(ofSize: 11), color: .red)
                } else {
                    for receipt in payment.receipts.sorted(by: { $0.addedAt < $1.addedAt }) {
                        for image in images(for: receipt) {
                            cursor.newPage()
                            cursor.draw("Receipt — \(payment.merchant)", font: .boldSystemFont(ofSize: 12))
                            if let check = receipt.verification {
                                let summary = check.result(for: payment).summary
                                cursor.draw("Receipt check: \(VerificationText.title(check))"
                                            + (summary.isEmpty ? "." : " — \(summary)."),
                                            font: .systemFont(ofSize: 9),
                                            color: check.status == .warning ? .red : .darkGray)
                            } else if let ocrTotal = receipt.ocrTotal {
                                let match = receipt.matchesPaymentTotal == true
                                cursor.draw(
                                    "Total read from the receipt: "
                                    + "\(Money.string(ocrTotal, currency: payment.currency))"
                                    + (match ? " — matches the payment." : " — differs from the payment."),
                                    font: .systemFont(ofSize: 9),
                                    color: match ? .darkGray : .red
                                )
                            }
                            cursor.space(6)
                            cursor.drawImage(image)
                        }
                    }
                }
            }
        }
    }

    private static func mark(_ payment: Payment) -> String {
        guard payment.hasReceipt else { return "  (no receipt)" }
        switch payment.verification?.status {
        case .matched: return "  ✓"
        case .warning: return "  ⚠"
        case .unverified: return "  ○"
        case nil: return ""
        }
    }

    private static func drawCheck(
        _ check: ReceiptVerification, receipt: ReceiptFile, payment: Payment, on cursor: inout Cursor
    ) {
        let invoice = check.invoice
        let currency = invoice.currency ?? payment.currency
        let symbol = switch check.status {
        case .matched: "✓"
        case .warning: "⚠"
        case .unverified: "○"
        }
        cursor.draw("Receipt check — \(receipt.filename)", font: .boldSystemFont(ofSize: 12))
        cursor.draw("\(symbol) \(VerificationText.title(check))", font: .boldSystemFont(ofSize: 10),
                    color: check.status == .warning ? .systemRed : .darkGray)
        for line in VerificationText.details(check, check.result(for: payment), currency: payment.currency) {
            cursor.draw(line, font: .systemFont(ofSize: 9), color: .darkGray)
        }
        cursor.space(2)
        cursor.drawField("Total read", invoice.total.map { Money.string($0, currency: currency) } ?? "not read")
        cursor.drawField("Date read", VerificationText.readDate(invoice) ?? "not read")
        if let period = VerificationText.period(invoice) {
            cursor.drawField(invoice.isHotel ? "Stay" : "Travel", period)
        }
        cursor.drawField("Merchant read", invoice.merchant ?? "not read")
        if let number = invoice.invoiceNumber { cursor.drawField("Invoice no.", number) }
        cursor.drawField("Read by", check.source == .online ? "Online parser" : "This iPhone only")
        if check.overriddenByUser {
            cursor.drawField("Added anyway", check.userNote.isEmpty ? "Yes, without a note" : check.userNote)
        }
    }

    private static func images(for receipt: ReceiptFile) -> [UIImage] {
        if receipt.isPDF {
            return ReceiptOCR.pageImages(fromPDF: receipt.data, limit: 10).map { UIImage(cgImage: $0) }
        }
        return [UIImage(data: receipt.data)].compactMap { $0 }
    }

    // MARK: - CSV

    static func csv(payments: [Payment]) -> String {
        let headers = ["Date", "Payee", "Category", "Trip", "Currency", "Amount",
                       "Claimed", "Refunded", "Net claimed", "Paid by", "Bank",
                       "Reference", "Receipts", "Notes", "Original message", "Proof SHA-256",
                       "verification_status", "parsed_total", "parsed_date", "overridden", "note"]
        var rows = [headers.map(escape).joined(separator: ",")]

        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"

        for p in payments {
            let fields = [
                formatter.string(from: p.paidAt),
                p.merchant,
                p.category.title,
                p.trip?.name ?? "",
                p.currency,
                String(format: "%.2f", p.amount),
                String(format: "%.2f", p.claimableAmount),
                String(format: "%.2f", p.refundedAmount),
                String(format: "%.2f", p.netClaimable),
                p.instrument,
                p.bank ?? "",
                p.reference ?? "",
                String(p.receipts.count),
                p.notes,
                p.isManual ? "(entered manually)" : p.rawMessage,
                p.messageHash
            ] + verificationFields(p.verification)
            rows.append(fields.map(escape).joined(separator: ","))
        }
        return rows.joined(separator: "\r\n")
    }

    /// The receipt check that speaks for the payment; blank without a receipt.
    private static func verificationFields(_ check: ReceiptVerification?) -> [String] {
        guard let check else { return ["", "", "", "", ""] }
        let date = [check.parsedDate, check.parsedTime].compactMap { $0 }.joined(separator: " ")
        return [
            check.statusRaw,
            check.parsedTotal.map { String(format: "%.2f", $0) } ?? "",
            date,
            check.overriddenByUser ? "yes" : "no",
            check.userNote
        ]
    }

    private static func escape(_ field: String) -> String {
        let cleaned = field.replacingOccurrences(of: "\"", with: "\"\"")
        return "\"\(cleaned)\""
    }

    // MARK: - Dates

    private static func shortDate(_ date: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = "dd MMM"
        return f.string(from: date)
    }

    private static func longDate(_ date: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = "d MMM yyyy, h:mm a"
        return f.string(from: date)
    }
}

/// Walks down a PDF page, starting a new one when it runs out of room, so the
/// drawing code above never has to think about pagination.
private struct Cursor {
    let ctx: UIGraphicsPDFRendererContext
    let pageSize: CGSize
    let margin: CGFloat
    var y: CGFloat = 0

    var width: CGFloat { pageSize.width - margin * 2 }
    var bottom: CGFloat { pageSize.height - margin }

    mutating func newPage() {
        ctx.beginPage()
        y = margin
    }

    mutating func space(_ amount: CGFloat) { y += amount }

    mutating func ensure(_ height: CGFloat) {
        if y + height > bottom { newPage() }
    }

    mutating func draw(_ text: String, font: UIFont, color: UIColor = .black) {
        let attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: color]
        let bounding = (text as NSString).boundingRect(
            with: CGSize(width: width, height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading],
            attributes: attributes, context: nil
        )
        ensure(bounding.height + 4)
        (text as NSString).draw(
            with: CGRect(x: margin, y: y, width: width, height: bounding.height),
            options: [.usesLineFragmentOrigin, .usesFontLeading],
            attributes: attributes, context: nil
        )
        y += bounding.height + 4
    }

    mutating func drawRow(left: String, right: String, bold: Bool = false) {
        let font = bold ? UIFont.boldSystemFont(ofSize: 11) : UIFont.systemFont(ofSize: 11)
        ensure(18)
        let attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: UIColor.black]
        let rightWidth: CGFloat = 110
        (left as NSString).draw(
            with: CGRect(x: margin, y: y, width: width - rightWidth - 8, height: 14),
            options: [.usesLineFragmentOrigin], attributes: attributes, context: nil
        )
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .right
        var rightAttributes = attributes
        rightAttributes[.paragraphStyle] = paragraph
        (right as NSString).draw(
            with: CGRect(x: margin + width - rightWidth, y: y, width: rightWidth, height: 14),
            options: [.usesLineFragmentOrigin], attributes: rightAttributes, context: nil
        )
        y += 16
    }

    mutating func drawField(_ label: String, _ value: String) {
        ensure(16)
        let labelAttributes: [NSAttributedString.Key: Any] = [
            .font: UIFont.systemFont(ofSize: 10), .foregroundColor: UIColor.gray
        ]
        (label as NSString).draw(at: CGPoint(x: margin, y: y), withAttributes: labelAttributes)
        let valueAttributes: [NSAttributedString.Key: Any] = [
            .font: UIFont.systemFont(ofSize: 11), .foregroundColor: UIColor.black
        ]
        (value as NSString).draw(
            with: CGRect(x: margin + 100, y: y - 1, width: width - 100, height: 30),
            options: [.usesLineFragmentOrigin], attributes: valueAttributes, context: nil
        )
        y += 16
    }

    mutating func drawQuote(_ text: String) {
        let font = UIFont.monospacedSystemFont(ofSize: 8.5, weight: .regular)
        let attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: UIColor.black]
        let inset: CGFloat = 10
        let bounding = (text as NSString).boundingRect(
            with: CGSize(width: width - inset * 2, height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading],
            attributes: attributes, context: nil
        )
        ensure(bounding.height + 14)
        let box = CGRect(x: margin, y: y, width: width, height: bounding.height + 12)
        UIColor(white: 0.95, alpha: 1).setFill()
        UIBezierPath(roundedRect: box, cornerRadius: 4).fill()
        (text as NSString).draw(
            with: CGRect(x: margin + inset, y: y + 6, width: width - inset * 2, height: bounding.height),
            options: [.usesLineFragmentOrigin, .usesFontLeading],
            attributes: attributes, context: nil
        )
        y += bounding.height + 16
    }

    mutating func rule() {
        ensure(8)
        let path = UIBezierPath()
        path.move(to: CGPoint(x: margin, y: y))
        path.addLine(to: CGPoint(x: margin + width, y: y))
        UIColor.lightGray.setStroke()
        path.lineWidth = 0.5
        path.stroke()
        y += 6
    }

    mutating func drawImage(_ image: UIImage) {
        let available = CGSize(width: width, height: bottom - y)
        guard available.height > 80 else {
            newPage()
            return drawImage(image)
        }
        let scale = min(available.width / image.size.width, available.height / image.size.height, 1)
        let size = CGSize(width: image.size.width * scale, height: image.size.height * scale)
        image.draw(in: CGRect(x: margin, y: y, width: size.width, height: size.height))
        y += size.height + 8
    }
}
