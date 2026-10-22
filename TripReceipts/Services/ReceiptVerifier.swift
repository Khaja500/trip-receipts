import Foundation

/// What the parser read off an invoice, online or on this phone. It is shown
/// beside the payment and compared with it, and never written over it.
struct ParsedInvoice: Codable, Equatable {
    var merchant: String?
    /// The registered name when it differs from the brand, e.g. "ANI
    /// Technologies Pvt Ltd" on an Ola invoice.
    var legalName: String?
    var total: Double?
    var currency: String?
    var tax: Double?
    /// The date printed on the invoice, `yyyy-MM-dd`. A calendar day, not an
    /// instant: the invoice says "12 Oct", not a moment in UTC.
    var invoiceDate: String?
    /// `HH:mm`, 24-hour, when the invoice prints a time.
    var invoiceTime: String?
    var invoiceNumber: String?
    /// ride, airline, rail, hotel, restaurant, fuel, gst_invoice or unknown.
    var documentType: String?
    /// The stay or travel window, `yyyy-MM-dd`, for hotels and multi-day tickets.
    var periodStart: String?
    var periodEnd: String?
    var lineItems: [LineItem]?
    var confidence: Confidence?

    struct LineItem: Codable, Equatable {
        var description: String
        var amount: Double
    }

    /// 0...1 per field. A reader that doesn't say is trusted.
    struct Confidence: Codable, Equatable {
        var merchant: Double?
        var total: Double?
        var invoiceDate: Double?
        var invoiceTime: Double?
    }
}

extension ParsedInvoice {
    // The fields read confidently enough to compare. The rest are still shown,
    // but count as not read.

    var readTotal: Double? { Self.trusted(confidence?.total) ? total : nil }

    var readDate: String? { Self.trusted(confidence?.invoiceDate) ? invoiceDate?.nonEmpty : nil }

    var readTime: String? {
        readDate != nil && Self.trusted(confidence?.invoiceTime) ? invoiceTime?.nonEmpty : nil
    }

    var readMerchantNames: [String] {
        guard Self.trusted(confidence?.merchant) else { return [] }
        return [merchant, legalName].compactMap { $0?.nonEmpty }
    }

    var isHotel: Bool { documentType == "hotel" }

    private static func trusted(_ confidence: Double?) -> Bool {
        (confidence ?? 1) >= VerifierRules.minimumConfidence
    }
}

enum VerificationStatus: String, Codable, CaseIterable {
    case matched, warning, unverified
}

/// How one field compares. Amount and time use `close`, the merchant `weak`.
enum FieldCheck: String, Codable {
    case match, close, weak, mismatch, unread
}

enum VerificationSource: String, Codable {
    case online
    case onDevice = "on-device"
}

struct VerificationResult: Equatable {
    var status: VerificationStatus
    var amount: FieldCheck
    var time: FieldCheck
    var merchant: FieldCheck
    var source: VerificationSource
    /// One phrase per field that disagrees, e.g. "invoice total ₹842 vs payment ₹1,250".
    var differences: [String] = []
    /// Differences that were let through (a tip, a bill near midnight, a name
    /// written differently) and fields that couldn't be read.
    var notes: [String] = []

    /// "Invoice total ₹842 vs payment ₹1,250; invoice dated 3 Oct vs payment 9 Oct"
    var summary: String {
        Self.sentence(differences.isEmpty ? notes : differences)
    }

    static func sentence(_ phrases: [String]) -> String {
        let joined = phrases.joined(separator: "; ")
        return joined.prefix(1).uppercased() + joined.dropFirst()
    }
}

/// Compares an invoice with the payment it is attached to, field by field,
/// using `VerifierRules`. Plain values in and out — no SwiftData — so the
/// rules can be checked on their own by `Tools/verifier-check.sh`.
enum ReceiptVerifier {

    /// The payment side of the comparison: what the bank says was paid.
    struct PaymentSide: Equatable {
        var amount: Double
        var currency: String
        var merchant: String
        var paidAt: Date
    }

    static func verify(
        _ invoice: ParsedInvoice,
        against payment: PaymentSide,
        source: VerificationSource,
        calendar: Calendar = .current
    ) -> VerificationResult {
        let amount = checkAmount(invoice, payment)
        let time = checkTime(invoice, payment, calendar: calendar)
        let merchant = checkMerchant(invoice, payment)

        var result = VerificationResult(
            status: status(amount: amount.result, time: time.result, merchant: merchant.result, source: source),
            amount: amount.result,
            time: time.result,
            merchant: merchant.result,
            source: source
        )
        for check in [amount, time, merchant] {
            guard let phrase = check.phrase else { continue }
            if check.result == .mismatch {
                result.differences.append(phrase)
            } else {
                result.notes.append(phrase)
            }
        }
        return result
    }

    /// A mismatch anywhere is a warning — unless the reading came from the
    /// phone alone, which is never trusted enough to accuse a receipt.
    static func status(
        amount: FieldCheck, time: FieldCheck, merchant: FieldCheck, source: VerificationSource
    ) -> VerificationStatus {
        if source == .onDevice { return .unverified }
        if amount == .unread { return .unverified }
        if time == .unread && merchant == .unread { return .unverified }
        if [amount, time, merchant].contains(.mismatch) { return .warning }
        return .matched
    }

    private struct Check {
        var result: FieldCheck
        var phrase: String?

        init(_ result: FieldCheck, _ phrase: String? = nil) {
            self.result = result
            self.phrase = phrase
        }
    }

    // MARK: - Amount

    private static func checkAmount(_ invoice: ParsedInvoice, _ payment: PaymentSide) -> Check {
        guard let total = invoice.readTotal else {
            return Check(.unread, "couldn't read the invoice total")
        }
        if let currency = invoice.currency?.uppercased().nonEmpty, currency != payment.currency.uppercased() {
            // No exchange rate to hand; comparing across currencies would only guess.
            return Check(.unread, "invoice is in \(currency), payment in \(payment.currency)")
        }
        let money = { Money.string($0, currency: payment.currency) }
        let over = payment.amount - total

        if abs(over) <= VerifierRules.amountMatchTolerance {
            return Check(.match)
        }
        if over > 0, over <= total * VerifierRules.amountCloseShare {
            let share = over / total * 100
            let percent = share < 1 ? "under 1%" : "\(Int(share.rounded()))%"
            return Check(.close, "payment is \(money(over)) (\(percent)) more than the invoice — "
                         + "tip, round-off or a fee")
        }
        return Check(.mismatch, "invoice total \(money(total)) vs payment \(money(payment.amount))")
    }

    // MARK: - Date and time

    private static func checkTime(_ invoice: ParsedInvoice, _ payment: PaymentSide, calendar: Calendar) -> Check {
        let invoiceDay = day(invoice.readDate, calendar: calendar)
        let periodStart = day(invoice.periodStart, calendar: calendar)
        let periodEnd = day(invoice.periodEnd, calendar: calendar) ?? periodStart
        guard invoiceDay != nil || periodStart != nil else {
            return Check(.unread, "no date found on the invoice")
        }
        let paidDay = calendar.startOfDay(for: payment.paidAt)
        let format = DayFormat(calendar: calendar, reference: payment.paidAt)

        if let invoiceDay {
            if let time = invoice.readTime, let printed = instant(on: invoiceDay, at: time, calendar: calendar) {
                if abs(payment.paidAt.timeIntervalSince(printed)) <= VerifierRules.timeMatchWindow {
                    return Check(.match)
                }
                if invoiceDay == paidDay {
                    return Check(.close, "invoice printed at \(format.time(printed)), "
                                 + "payment at \(format.time(payment.paidAt)) the same day")
                }
            } else if invoiceDay == paidDay {
                return Check(.match)
            }

            if acrossMidnight(invoiceDay: invoiceDay, paidAt: payment.paidAt, calendar: calendar) {
                return Check(.close, "invoice dated \(format.day(invoiceDay)), payment "
                             + "\(format.time(payment.paidAt)) on \(format.day(paidDay)) — across midnight")
            }
        }

        let window = invoice.isHotel ? "stay" : "travel dates"
        if let periodStart, let periodEnd, paidDay >= periodStart, paidDay <= periodEnd {
            return Check(.close, "payment on \(format.day(paidDay)) falls within the \(window), "
                         + format.range(periodStart, periodEnd))
        }

        if let invoiceDay {
            return Check(.mismatch, "invoice dated \(format.day(invoiceDay)) vs payment \(format.day(paidDay))")
        }
        return Check(.mismatch, "\(window) \(format.range(periodStart!, periodEnd!)) "
                     + "vs payment \(format.day(paidDay))")
    }

    /// The invoice is dated the day before or after the payment, and the
    /// payment is within the grace of the midnight between them.
    private static func acrossMidnight(invoiceDay: Date, paidAt: Date, calendar: Calendar) -> Bool {
        let paidDay = calendar.startOfDay(for: paidAt)
        if let next = calendar.date(byAdding: .day, value: 1, to: invoiceDay), next == paidDay {
            return paidAt.timeIntervalSince(paidDay) <= VerifierRules.midnightGrace
        }
        if let previous = calendar.date(byAdding: .day, value: -1, to: invoiceDay), previous == paidDay {
            return invoiceDay.timeIntervalSince(paidAt) <= VerifierRules.midnightGrace
        }
        return false
    }

    /// Start of the day `yyyy-MM-dd` names, in the calendar's time zone.
    static func day(_ string: String?, calendar: Calendar) -> Date? {
        guard let parts = string?.split(separator: "-").compactMap({ Int($0) }), parts.count == 3 else {
            return nil
        }
        return calendar.date(from: DateComponents(year: parts[0], month: parts[1], day: parts[2]))
    }

    private static func instant(on day: Date, at time: String, calendar: Calendar) -> Date? {
        let parts = time.split(separator: ":").compactMap { Int($0) }
        guard parts.count >= 2 else { return nil }
        return calendar.date(bySettingHour: parts[0], minute: parts[1], second: 0, of: day)
    }

    /// "3 Oct", or "3 Oct 2024" when the year isn't the payment's.
    private struct DayFormat {
        let calendar: Calendar
        let reference: Date

        func day(_ date: Date) -> String {
            let sameYear = calendar.component(.year, from: date) == calendar.component(.year, from: reference)
            return formatter(sameYear ? "d MMM" : "d MMM yyyy").string(from: date)
        }

        func time(_ date: Date) -> String {
            formatter("h:mm a").string(from: date)
        }

        /// "12–15 Oct", "30 Sep–2 Oct".
        func range(_ start: Date, _ end: Date) -> String {
            guard start != end else { return day(start) }
            let sameMonth = calendar.isDate(start, equalTo: end, toGranularity: .month)
            return "\(formatter(sameMonth ? "d" : "d MMM").string(from: start))–\(day(end))"
        }

        private func formatter(_ format: String) -> DateFormatter {
            let f = DateFormatter()
            f.locale = Locale(identifier: "en_US_POSIX")
            f.calendar = calendar
            f.timeZone = calendar.timeZone
            f.dateFormat = format
            return f
        }
    }

    // MARK: - Merchant

    private static func checkMerchant(_ invoice: ParsedInvoice, _ payment: PaymentSide) -> Check {
        let names = invoice.readMerchantNames
        guard let shown = names.first else {
            return Check(.unread, "no merchant name found on the invoice")
        }
        guard !payment.merchant.isEmpty else {
            return Check(.unread, "the payment has no payee to compare")
        }

        let results = names.map { (name: $0, result: compareNames(payment.merchant, $0)) }
        if results.contains(where: { $0.result == .match }) {
            return Check(.match)
        }
        if let weak = results.first(where: { $0.result == .weak }) {
            return Check(.weak, "payee \(payment.merchant) looks like \(weak.name) on the invoice")
        }
        return Check(.mismatch, "invoice from \(shown) vs payment to \(payment.merchant)")
    }

    /// Same business, probably the same, or not. Bank SMS shorten and
    /// shout ("UBER INDIA"); invoices carry the registered name ("Uber India
    /// Systems Private Limited"); either may be an acronym ("IRCTC").
    static func compareNames(_ a: String, _ b: String) -> FieldCheck {
        if MatchingRules.similarPayee(a, b) { return .match }

        let x = words(a), y = words(b)
        let xs = x.significant.joined(), ys = y.significant.joined()
        guard !xs.isEmpty, !ys.isEmpty else { return .mismatch }
        if MatchingRules.similarPayee(xs, ys) { return .match }
        if isAcronym(xs, of: y) || isAcronym(ys, of: x) { return .match }
        return similarity(xs, ys) >= VerifierRules.merchantWeakThreshold ? .weak : .mismatch
    }

    private static func words(_ name: String) -> (all: [String], significant: [String]) {
        // A UPI handle names the business before the "@".
        let handle = name.split(separator: "@").first.map(String.init) ?? name
        let all = handle.lowercased()
            .split(whereSeparator: { !$0.isLetter && !$0.isNumber })
            .map(String.init)
        return (all, all.filter { !VerifierRules.merchantNoise.contains($0) })
    }

    private static func isAcronym(_ short: String, of name: (all: [String], significant: [String])) -> Bool {
        guard short.count >= 3, name.all.count >= 3 else { return false }
        let initials = { (words: [String]) in String(words.compactMap(\.first)) }
        return short == initials(name.all) || short == initials(name.significant)
    }

    /// Dice coefficient on character pairs: 1 for the same string, 0 for
    /// nothing in common.
    static func similarity(_ a: String, _ b: String) -> Double {
        let x = Array(a), y = Array(b)
        guard x.count >= 2, y.count >= 2 else { return a == b ? 1 : 0 }
        var pairs: [String: Int] = [:]
        for i in 0..<(x.count - 1) { pairs[String(x[i...i + 1]), default: 0] += 1 }
        var shared = 0
        for i in 0..<(y.count - 1) {
            let pair = String(y[i...i + 1])
            if let count = pairs[pair], count > 0 {
                shared += 1
                pairs[pair] = count - 1
            }
        }
        return 2 * Double(shared) / Double(x.count + y.count - 2)
    }
}

private extension String {
    var nonEmpty: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
