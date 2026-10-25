import Foundation

/// Every tolerance the receipt check uses, in one place, so a false warning
/// can be tuned without reading the comparison code. `Tools/verifier-check.sh`
/// pins down what each one means.
enum VerifierRules {

    // MARK: Amount

    /// Invoice and payment this close are the same total: paise and round-off.
    static let amountMatchTolerance = 1.0

    /// A payment above the invoice by up to this share is a tip, round-off or
    /// convenience fee: close, not wrong. A payment *below* the invoice is
    /// never close — something on the bill wasn't paid by this payment.
    static let amountCloseShare = 0.15

    // MARK: Date and time

    /// When the invoice prints a time, a payment this near it matches. An
    /// invoice with only a date matches a payment on that day.
    static let timeMatchWindow: TimeInterval = 30 * 60

    /// A payment this near midnight may carry the neighbouring day's date —
    /// the dinner bill printed at 11:50 pm and paid at 12:10 am.
    static let midnightGrace: TimeInterval = 3 * 60 * 60

    // MARK: Merchant

    /// Character-bigram similarity above which two differently written names
    /// are probably the same business ("MAKEMYTRP" and "MakeMyTrip").
    static let merchantWeakThreshold = 0.5

    /// Words dropped before names are compared. "India" is deliberately not
    /// here: without it "Air India" and "Air Asia" would both be "air".
    static let merchantNoise: Set<String> = [
        "pvt", "private", "ltd", "limited", "llp", "inc", "co", "company", "corp",
        "the", "and", "of", "m/s", "ms"
    ]

    // MARK: Parser

    /// A field the parser is less sure of than this counts as not read.
    static let minimumConfidence = 0.6

    /// Longer than this and the phone's own reading is used instead. Room
    /// for Gemini, which can take several seconds over a photo.
    static let parserTimeout: TimeInterval = 30
}
