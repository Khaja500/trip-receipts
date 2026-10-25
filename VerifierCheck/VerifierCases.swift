import Foundation

/// The verifier's test suite: a payment and the invoice attached to it, with
/// what the check should conclude. Every receipt that was wrongly flagged —
/// or wrongly passed — goes in here before a tolerance is touched.
struct VerifierCase {
    var label: String
    var payment: ReceiptVerifier.PaymentSide
    var invoice: ParsedInvoice
    var source: VerificationSource = .online
    var expect: Expectation

    struct Expectation {
        var status: VerificationStatus
        var amount: FieldCheck? = nil
        var time: FieldCheck? = nil
        var merchant: FieldCheck? = nil
        /// Text the summary must contain, or equal when `exactSummary` is set.
        var summary: String? = nil
        var exactSummary = false
    }
}

enum VerifierCases {
    /// Indian time, so "12 Oct, 9:41 am" means what an Indian invoice means.
    static let calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Kolkata")!
        return calendar
    }()

    static func at(_ string: String) -> Date {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.calendar = calendar
        f.timeZone = calendar.timeZone
        f.dateFormat = "yyyy-MM-dd HH:mm"
        return f.date(from: string)!
    }

    static func paid(_ amount: Double, to merchant: String, at time: String, currency: String = "INR")
        -> ReceiptVerifier.PaymentSide {
        .init(amount: amount, currency: currency, merchant: merchant, paidAt: at(time))
    }

    static func invoice(
        _ total: Double?, from merchant: String?, legalName: String? = nil,
        dated date: String?, time: String? = nil, currency: String? = "INR",
        type: String? = nil, period: (String, String)? = nil,
        confidence: ParsedInvoice.Confidence? = nil
    ) -> ParsedInvoice {
        ParsedInvoice(
            merchant: merchant, legalName: legalName, total: total, currency: currency,
            invoiceDate: date, invoiceTime: time, documentType: type,
            periodStart: period?.0, periodEnd: period?.1, confidence: confidence
        )
    }

    static let uber = paid(486, to: "UBER INDIA", at: "2025-10-12 09:41")

    static let all: [VerifierCase] = [

        // MARK: Matches

        VerifierCase(
            label: "Uber invoice with the same total, date and time",
            payment: uber,
            invoice: invoice(486, from: "Uber", legalName: "Uber India Systems Private Limited",
                             dated: "2025-10-12", time: "09:38", type: "ride"),
            expect: .init(status: .matched, amount: .match, time: .match, merchant: .match)
        ),
        VerifierCase(
            label: "round-off within ₹1 still matches",
            payment: paid(486, to: "UBER INDIA", at: "2025-10-12 09:41"),
            invoice: invoice(485.6, from: "Uber India Systems Pvt Ltd", dated: "2025-10-12"),
            expect: .init(status: .matched, amount: .match)
        ),
        VerifierCase(
            label: "an invoice with only a date matches a payment that day",
            payment: paid(1250, to: "MAKEMYTRIP", at: "2025-10-11 22:15"),
            invoice: invoice(1250, from: "MakeMyTrip (India) Pvt Ltd", dated: "2025-10-11"),
            expect: .init(status: .matched, time: .match, merchant: .match)
        ),
        VerifierCase(
            label: "a UPI handle is compared by the name before the @",
            payment: paid(486, to: "uberindia@axisbank", at: "2025-10-12 09:41"),
            invoice: invoice(486, from: "Uber India Systems Private Limited", dated: "2025-10-12"),
            expect: .init(status: .matched, merchant: .match)
        ),
        VerifierCase(
            label: "an acronym payee matches the full registered name",
            payment: paid(1645.5, to: "IRCTC", at: "2025-10-01 20:05"),
            invoice: invoice(1645.5, from: "Indian Railway Catering and Tourism Corporation Ltd",
                             dated: "2025-10-01", type: "rail"),
            expect: .init(status: .matched, merchant: .match)
        ),
        VerifierCase(
            label: "a train ticket booked now for later travel matches on the booking date",
            payment: paid(1645.5, to: "IRCTC", at: "2025-10-01 20:05"),
            invoice: invoice(1645.5, from: "IRCTC", dated: "2025-10-01", type: "rail",
                             period: ("2025-10-12", "2025-10-13")),
            expect: .init(status: .matched, time: .match)
        ),

        // MARK: Close — matched, with a note

        VerifierCase(
            label: "tip on a restaurant bill is close, not wrong",
            payment: paid(1300, to: "BARBEQUE NATION", at: "2025-10-12 21:30"),
            invoice: invoice(1210, from: "Barbeque Nation Hospitality Ltd", dated: "2025-10-12",
                             time: "21:12", type: "restaurant"),
            expect: .init(status: .matched, amount: .close,
                          summary: "Payment is ₹90 (7%) more than the invoice")
        ),
        VerifierCase(
            label: "a bill printed before midnight and paid after it is close",
            payment: paid(2140, to: "SOCIAL", at: "2025-10-10 00:20"),
            invoice: invoice(2140, from: "Social", dated: "2025-10-09", time: "23:10",
                             type: "restaurant"),
            expect: .init(status: .matched, time: .close, summary: "across midnight")
        ),
        VerifierCase(
            label: "the same day at a different time is close",
            payment: paid(320, to: "CHAAYOS", at: "2025-10-12 14:45"),
            invoice: invoice(320, from: "Chaayos", dated: "2025-10-12", time: "09:10"),
            expect: .init(status: .matched, time: .close,
                          summary: "Invoice printed at 9:10 AM, payment at 2:45 PM the same day")
        ),
        VerifierCase(
            label: "a hotel paid mid-stay is close to its checkout invoice",
            payment: paid(9870, to: "SEA PRINCESS HOTEL", at: "2025-10-13 11:00"),
            invoice: invoice(9870, from: "Hotel Sea Princess", dated: "2025-10-15", type: "hotel",
                             period: ("2025-10-12", "2025-10-15")),
            expect: .init(status: .matched, time: .close, merchant: .weak,
                          summary: "falls within the stay, 12–15 Oct")
        ),
        VerifierCase(
            label: "a misspelt payee is weak, not a mismatch",
            payment: paid(4520, to: "MAKEMYTRP", at: "2025-10-10 10:00"),
            invoice: invoice(4520, from: "MakeMyTrip", dated: "2025-10-10"),
            expect: .init(status: .matched, merchant: .weak, summary: "looks like MakeMyTrip")
        ),
        VerifierCase(
            label: "a missing date doesn't block a matching total and payee",
            payment: uber,
            invoice: invoice(486, from: "Uber", dated: nil),
            expect: .init(status: .matched, time: .unread, summary: "No date found on the invoice")
        ),

        // MARK: Warnings

        VerifierCase(
            label: "a different total is a warning",
            payment: paid(1250, to: "UBER INDIA", at: "2025-10-09 18:00"),
            invoice: invoice(842, from: "Uber", dated: "2025-10-09", time: "17:52"),
            expect: .init(status: .warning, amount: .mismatch, time: .match, merchant: .match,
                          summary: "Invoice total ₹842 vs payment ₹1,250", exactSummary: true)
        ),
        VerifierCase(
            label: "the plan's example: wrong total and an old date, both named",
            payment: paid(1250, to: "UBER INDIA", at: "2025-10-09 18:00"),
            invoice: invoice(842, from: "Uber", dated: "2025-10-03"),
            expect: .init(status: .warning, amount: .mismatch, time: .mismatch,
                          summary: "Invoice total ₹842 vs payment ₹1,250; invoice dated 3 Oct vs payment 9 Oct",
                          exactSummary: true)
        ),
        VerifierCase(
            label: "an invoice from another day is a warning",
            payment: uber,
            invoice: invoice(486, from: "Uber", dated: "2025-10-03", time: "09:41"),
            expect: .init(status: .warning, amount: .match, time: .mismatch,
                          summary: "Invoice dated 3 Oct vs payment 12 Oct", exactSummary: true)
        ),
        VerifierCase(
            label: "an invoice from another business is a warning",
            payment: uber,
            invoice: invoice(486, from: "Barbeque Nation", dated: "2025-10-12"),
            expect: .init(status: .warning, merchant: .mismatch,
                          summary: "Invoice from Barbeque Nation vs payment to UBER INDIA", exactSummary: true)
        ),
        VerifierCase(
            label: "Air India and Air Asia are not the same airline",
            payment: paid(5400, to: "AIR INDIA", at: "2025-10-08 12:00"),
            invoice: invoice(5400, from: "AirAsia", dated: "2025-10-08", type: "airline"),
            expect: .init(status: .warning, merchant: .mismatch)
        ),
        VerifierCase(
            label: "a payment below the invoice is never close",
            payment: paid(400, to: "UBER INDIA", at: "2025-10-12 09:41"),
            invoice: invoice(486, from: "Uber", dated: "2025-10-12"),
            expect: .init(status: .warning, amount: .mismatch)
        ),
        VerifierCase(
            label: "a 'tip' of 30% is too much to wave through",
            payment: paid(1573, to: "BARBEQUE NATION", at: "2025-10-12 21:30"),
            invoice: invoice(1210, from: "Barbeque Nation", dated: "2025-10-12"),
            expect: .init(status: .warning, amount: .mismatch)
        ),
        VerifierCase(
            label: "a hotel payment outside the stay is a warning",
            payment: paid(9870, to: "HOTEL SEA PRINCESS", at: "2025-10-20 11:00"),
            invoice: invoice(9870, from: "Hotel Sea Princess", dated: nil, type: "hotel",
                             period: ("2025-10-12", "2025-10-15")),
            expect: .init(status: .warning, time: .mismatch,
                          summary: "Stay 12–15 Oct vs payment 20 Oct", exactSummary: true)
        ),

        // MARK: Unverified

        VerifierCase(
            label: "a parser that read nothing leaves the receipt unverified",
            payment: uber,
            invoice: ParsedInvoice(),
            expect: .init(status: .unverified, amount: .unread, time: .unread, merchant: .unread)
        ),
        VerifierCase(
            label: "a total the parser isn't sure of counts as unread",
            payment: uber,
            invoice: invoice(842, from: "Uber", dated: "2025-10-12",
                             confidence: .init(merchant: 0.9, total: 0.4, invoiceDate: 0.95)),
            expect: .init(status: .unverified, amount: .unread)
        ),
        VerifierCase(
            label: "the phone's own reading is unverified, never a warning",
            payment: paid(1250, to: "UBER INDIA", at: "2025-10-09 18:00"),
            invoice: invoice(842, from: nil, dated: nil, currency: nil),
            source: .onDevice,
            expect: .init(status: .unverified, amount: .mismatch,
                          summary: "Invoice total ₹842 vs payment ₹1,250")
        ),
        VerifierCase(
            label: "an invoice in another currency is not compared",
            payment: paid(10_150, to: "MARRIOTT", at: "2025-10-12 09:00"),
            invoice: invoice(120, from: "Marriott", dated: "2025-10-12", currency: "USD"),
            expect: .init(status: .unverified, amount: .unread,
                          summary: "Invoice is in USD, payment in INR")
        ),
        VerifierCase(
            label: "only a total, with no date or name, is not enough",
            payment: uber,
            invoice: invoice(486, from: nil, dated: nil),
            expect: .init(status: .unverified, amount: .match, time: .unread, merchant: .unread)
        )
    ]
}
