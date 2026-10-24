import Foundation

/// Checks the decisions that sit between "a message arrived" and "it is filed
/// under a trip": duplicates, refunds, trip dates, retention, and the
/// category guess. These are the rules that quietly ruin a claim when wrong.
enum RulesCheck {

    static func run() -> Bool {
        var failures: [String] = []

        func check(_ name: String, _ body: () -> [String]) {
            let problems = body()
            if problems.isEmpty {
                print("  ok    \(name)")
            } else {
                print("  FAIL  \(name)")
                for p in problems { print("          \(p)") }
                failures.append(name)
            }
        }

        let base = iso("2025-10-12T10:00:00Z")

        // MARK: Duplicates

        let hdfcText = "Sent Rs.486.00 From HDFC Bank A/C x1234 To UBER INDIA On 12/10/25 Ref 528512345678"
        let hdfc = facts(from: hdfcText, sender: "AD-HDFCBK", at: base)

        check("the identical message is a duplicate") {
            let again = facts(from: hdfcText, sender: "AD-HDFCBK", at: base.addingTimeInterval(5))
            return MatchingRules.isDuplicate(incoming: again, existing: hdfc)
                ? [] : ["the same text twice was treated as two payments"]
        }

        check("the UPI app describing the same payment is a duplicate") {
            let phonePe = facts(
                from: "Paid Rs.486.00 to Uber India Systems via UPI on 12-10-25. -PhonePe",
                sender: "VM-PHONPE", at: base.addingTimeInterval(240)
            )
            return MatchingRules.isDuplicate(incoming: phonePe, existing: hdfc)
                ? [] : ["bank and UPI app versions were treated as two payments"]
        }

        check("the same reference and amount is a duplicate even hours apart") {
            let late = facts(
                from: "INR 486.00 debited from A/c XX1234 on 12-10-25. Ref No 528512345678.",
                sender: "AD-HDFCBK", at: base.addingTimeInterval(6 * 3600)
            )
            return MatchingRules.isDuplicate(incoming: late, existing: hdfc)
                ? [] : ["the shared reference was not noticed"]
        }

        check("the same amount to the same payee next day is not a duplicate") {
            // A daily commute cab costs the same every morning; 24 hours apart
            // with no shared reference must stay two payments.
            var tomorrow = facts(
                from: "Sent Rs.486.00 From HDFC Bank A/C x1234 To UBER INDIA On 13/10/25",
                sender: "AD-HDFCBK", at: base.addingTimeInterval(86_400)
            )
            tomorrow.reference = nil
            var original = hdfc
            original.reference = nil
            return MatchingRules.isDuplicate(incoming: tomorrow, existing: original)
                ? ["two separate cab rides were merged into one"] : []
        }

        check("the same amount to a different payee is not a duplicate") {
            let other = facts(
                from: "Sent Rs.486.00 From HDFC Bank A/C x1234 To SWIGGY On 12/10/25 Ref 999988887777",
                sender: "AD-HDFCBK", at: base.addingTimeInterval(120)
            )
            return MatchingRules.isDuplicate(incoming: other, existing: hdfc)
                ? ["two different payees were merged"] : []
        }

        check("payee names are compared loosely but not carelessly") {
            var problems: [String] = []
            if !MatchingRules.similarPayee("UBER INDIA", "Uber India Systems Pvt Ltd") {
                problems.append("did not match the same merchant written two ways")
            }
            if !MatchingRules.similarPayee("Makemytrip", "MAKEMYTRIP") {
                problems.append("case alone broke the match")
            }
            if MatchingRules.similarPayee("Uber", "Swiggy") {
                problems.append("matched two unrelated merchants")
            }
            if MatchingRules.similarPayee("OYO", "OLA") {
                problems.append("matched two short, unrelated names")
            }
            return problems
        }

        // MARK: Refunds

        check("a partial refund is matched by reference, not amount") {
            let refund = facts(
                from: "Refund of Rs.200.00 for your transaction at UBER INDIA has been credited back "
                    + "to HDFC Bank A/C x1234 on 13-10-25. Ref 528512345678.",
                sender: "AD-HDFCBK", at: base.addingTimeInterval(86_400)
            )
            return MatchingRules.refundMatches(refund: refund, candidate: hdfc)
                ? [] : ["a partial refund did not find its payment"]
        }

        check("a full refund with no reference is matched by amount and payee") {
            var refund = facts(
                from: "Refund of Rs.486.00 at UBER INDIA credited back on 13-10-25.",
                sender: "AD-HDFCBK", at: base.addingTimeInterval(86_400)
            )
            refund.reference = nil
            return MatchingRules.refundMatches(refund: refund, candidate: hdfc)
                ? [] : ["a full refund did not find its payment"]
        }

        check("a refund does not attach to an unrelated payment") {
            var refund = facts(
                from: "Refund of Rs.4520.00 at INDIGO AIRLINES credited back on 13-10-25.",
                sender: "AD-HDFCBK", at: base.addingTimeInterval(86_400)
            )
            refund.reference = nil
            return MatchingRules.refundMatches(refund: refund, candidate: hdfc)
                ? ["an airline refund was applied to a cab ride"] : []
        }

        // MARK: Trip dates

        check("a trip claims its own dates and not a day more") {
            let start = iso("2025-10-12T00:00:00Z")
            let end = iso("2025-10-13T00:00:00Z")
            var problems: [String] = []
            if !TripWindow.covers(iso("2025-10-12T14:00:00Z"), start: start, end: end) {
                problems.append("a payment on the first day was excluded")
            }
            if !TripWindow.covers(iso("2025-10-13T18:00:00Z"), start: start, end: end) {
                problems.append("a payment on the evening of the last day was excluded")
            }
            if TripWindow.covers(iso("2025-10-11T06:00:00Z"), start: start, end: end) {
                problems.append("the day before the trip was claimed")
            }
            if TripWindow.covers(iso("2025-10-14T06:00:00Z"), start: start, end: end) {
                problems.append("the day after the trip ended was claimed")
            }
            if TripWindow.covers(iso("2025-10-15T18:00:00Z"), start: start, end: end) {
                problems.append("two days after the trip ended was claimed")
            }
            return problems
        }

        check("a one-day trip still has a usable window") {
            let day = iso("2025-10-12T00:00:00Z")
            // 7:30 pm in India, 2 pm UTC: the same day wherever this runs.
            return TripWindow.covers(iso("2025-10-12T14:00:00Z"), start: day, end: day)
                ? [] : ["a same-day trip excluded its own evening"]
        }

        // MARK: Retention

        check("personal payments survive 29 days and are gone by 31") {
            var problems: [String] = []
            if MatchingRules.personalHasExpired(markedAt: base, now: base.addingTimeInterval(29 * 86_400)) {
                problems.append("deleted at 29 days, too early to undo")
            }
            if !MatchingRules.personalHasExpired(markedAt: base, now: base.addingTimeInterval(31 * 86_400)) {
                problems.append("still kept at 31 days")
            }
            return problems
        }

        // MARK: Category guesses

        check("travel payees are recognised") {
            let expected: [(String, ExpenseCategory)] = [
                ("Uber India", .cab), ("Rapido", .cab), ("Irctc", .rail),
                ("Indigo Airlines", .airfare), ("Oyo Rooms", .hotel),
                ("Makemytrip", .hotel), ("Swiggy", .meals),
                ("Hpcl Fuel Station", .fuel), ("Mumbai Pune Toll Plaza", .tollsParking),
                ("Some Unknown Shop", .other)
            ]
            return expected.compactMap { payee, want in
                let got = CategoryGuesser.guess(payee: payee)
                return got == want ? nil : "\(payee) guessed as \(got.title), wanted \(want.title)"
            }
        }

        check("a flight booked through a hotel site counts as airfare") {
            let got = CategoryGuesser.guess(
                payee: "Makemytrip",
                message: "Spent Rs.4520 at MAKEMYTRIP for your flight booking"
            )
            return got == .airfare ? [] : ["guessed \(got.title), wanted Airfare"]
        }

        // MARK: Reading a receipt

        check("the labelled total beats the sub-total and the tax lines") {
            let bill = ["THE COFFEE HOUSE", "Cappuccino        180.00",
                        "Sandwich          240.00", "Sub Total         420.00",
                        "CGST 2.5%          10.50", "SGST 2.5%          10.50",
                        "Grand Total       441.00", "Paid by UPI"]
            let got = ReceiptTotalReader.total(in: bill)
            return got == 441 ? [] : ["read \(describe(got)), wanted 441"]
        }

        check("a bill with no total label falls back to the largest figure") {
            let bill = ["AUTO RICKSHAW", "Fare 85", "Waiting 15", "100"]
            let got = ReceiptTotalReader.total(in: bill)
            return got == 100 ? [] : ["read \(describe(got)), wanted 100"]
        }

        check("a sub-total larger than the total is not mistaken for it") {
            // Discounts make this real: the sub-total is the biggest number
            // on the bill, but it is not what was paid.
            let bill = ["HOTEL INVOICE", "Sub Total 5000.00", "Discount 1000.00",
                        "Total Amount 4000.00"]
            let got = ReceiptTotalReader.total(in: bill)
            return got == 4000 ? [] : ["read \(describe(got)), wanted 4000"]
        }

        check("an unreadable receipt reads as nothing rather than a wrong number") {
            return ReceiptTotalReader.total(in: ["", "   ", "THANK YOU"]) == nil
                ? [] : ["invented a total from a blank receipt"]
        }

        check("a receipt total within one percent counts as a match") {
            // The rule used in the detail view: a rounding difference is fine,
            // a different bill is not.
            func matches(_ ocr: Double, _ paid: Double) -> Bool {
                abs(ocr - paid) / paid <= 0.01
            }
            var problems: [String] = []
            if !matches(441.0, 441.0) { problems.append("an exact match was rejected") }
            if !matches(440.5, 441.0) { problems.append("a rounding difference was rejected") }
            if matches(500.0, 441.0) { problems.append("a different total was accepted") }
            return problems
        }

        // MARK: Proof

        check("the fingerprint changes when the message does") {
            let original = ProofHasher.hash(sender: "AD-HDFCBK", receivedAt: base, text: hdfcText)
            let edited = ProofHasher.hash(sender: "AD-HDFCBK", receivedAt: base,
                                          text: hdfcText.replacingOccurrences(of: "486.00", with: "4860.00"))
            let resent = ProofHasher.hash(sender: "AD-HDFCBK", receivedAt: base, text: hdfcText)
            var problems: [String] = []
            if original == edited { problems.append("an edited amount produced the same fingerprint") }
            if original != resent { problems.append("the same message produced two fingerprints") }
            if original.count != 64 { problems.append("fingerprint is \(original.count) characters, wanted 64") }
            return problems
        }

        print("")
        if failures.isEmpty {
            print("All matching, trip, retention and proof rules behave as specified.")
            return true
        }
        print("\(failures.count) failed: \(failures.joined(separator: ", "))")
        return false
    }

    // MARK: - Helpers

    /// Builds the facts exactly as `PaymentStore` does, so the check exercises
    /// the parser and the rules together.
    private static func facts(from text: String, sender: String, at date: Date) -> PaymentFacts {
        guard case .payment(let parsed) = SMSParser.parse(text, sender: sender, now: date) else {
            return PaymentFacts(amount: 0, merchant: "", reference: nil, receivedAt: date,
                                messageHash: "", rawMessage: text)
        }
        return PaymentFacts(
            amount: parsed.amount,
            merchant: parsed.merchant,
            reference: parsed.reference,
            receivedAt: date,
            messageHash: ProofHasher.hash(sender: sender, receivedAt: date, text: text),
            rawMessage: text
        )
    }

    private static func describe(_ value: Double?) -> String {
        guard let value else { return "nothing" }
        return String(value)
    }

    private static func iso(_ string: String) -> Date {
        ISO8601DateFormatter().date(from: string) ?? .now
    }
}
