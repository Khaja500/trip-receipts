import Foundation

/// The facts a matching decision needs. Deliberately a plain value type: the
/// rules below are the part that is easy to get wrong, so they are kept
/// independent of SwiftData and checked on their own.
struct PaymentFacts: Equatable {
    var amount: Double
    var merchant: String
    var reference: String?
    var receivedAt: Date
    var messageHash: String
    var rawMessage: String
    /// Fingerprints of any extra messages already filed against this payment.
    var additionalHashes: [String] = []
}

/// When two messages are the same payment, when a refund belongs to a payment,
/// and how long a personal payment is kept.
enum MatchingRules {

    /// Bank and UPI app wording for the same merchant differs ("UBER INDIA" vs
    /// "Uber India Systems"); one containing the other is close enough.
    static func similarPayee(_ a: String, _ b: String) -> Bool {
        let x = a.lowercased().filter { $0.isLetter || $0.isNumber }
        let y = b.lowercased().filter { $0.isLetter || $0.isNumber }
        guard !x.isEmpty, !y.isEmpty else { return false }
        if x == y { return true }
        guard x.count >= 4, y.count >= 4 else { return false }
        return x.contains(y) || y.contains(x)
    }

    /// Three ways one payment shows up twice: the identical text, the same
    /// reference, or two apps describing it minutes apart.
    static func isDuplicate(
        incoming: PaymentFacts,
        existing: PaymentFacts,
        window: TimeInterval = 15 * 60
    ) -> Bool {
        if existing.messageHash == incoming.messageHash { return true }
        if existing.rawMessage == incoming.rawMessage { return true }
        if existing.additionalHashes.contains(incoming.messageHash) { return true }

        if let reference = incoming.reference, !reference.isEmpty,
           existing.reference == reference,
           sameAmount(existing.amount, incoming.amount) {
            return true
        }

        return sameAmount(existing.amount, incoming.amount)
            && abs(existing.receivedAt.timeIntervalSince(incoming.receivedAt)) <= window
            && similarPayee(existing.merchant, incoming.merchant)
    }

    /// A refund is tied to its payment by reference first, then by amount and
    /// payee — a partial refund will not share the amount, so reference wins.
    static func refundMatches(refund: PaymentFacts, candidate: PaymentFacts) -> Bool {
        if let reference = refund.reference, !reference.isEmpty, candidate.reference == reference {
            return true
        }
        return sameAmount(candidate.amount, refund.amount)
            && similarPayee(candidate.merchant, refund.merchant)
    }

    static func sameAmount(_ a: Double, _ b: Double) -> Bool {
        abs(a - b) < 0.01
    }

    /// Personal payments are kept 30 days: long enough to catch a duplicate and
    /// to undo a wrong swipe.
    static let personalRetention: TimeInterval = 30 * 24 * 60 * 60

    static func personalHasExpired(markedAt: Date, now: Date) -> Bool {
        now.timeIntervalSince(markedAt) >= personalRetention
    }
}

/// The dates a trip claims. A day before for the cab to the airport, two days
/// after for the hotel charge that lands once you are home.
enum TripWindow {
    static let daysBefore = 1
    static let daysAfter = 2

    static func range(start: Date, end: Date, calendar: Calendar = .current) -> ClosedRange<Date> {
        let from = calendar.startOfDay(
            for: calendar.date(byAdding: .day, value: -daysBefore, to: start) ?? start
        )
        let lastDay = calendar.date(byAdding: .day, value: daysAfter, to: end) ?? end
        let to = calendar.date(bySettingHour: 23, minute: 59, second: 59, of: lastDay) ?? lastDay
        return from...max(from, to)
    }

    static func covers(_ date: Date, start: Date, end: Date, calendar: Calendar = .current) -> Bool {
        range(start: start, end: end, calendar: calendar).contains(date)
    }
}
