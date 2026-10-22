import Foundation
import SwiftData

enum PaymentStatus: String, Codable, CaseIterable {
    case pending, work, personal
}

/// One outgoing payment, caught from a bank SMS or entered by hand.
@Model
final class Payment {
    /// Stable id that survives a round-trip through a notification's userInfo,
    /// which cannot carry a SwiftData PersistentIdentifier.
    var uid: String = UUID().uuidString

    // What was paid
    var amount: Double = 0
    var currency: String = "INR"
    var merchant: String = ""
    /// Human-readable instrument, e.g. "UPI · A/c ••1234" or "Card ••4455".
    var instrument: String = ""
    var reference: String?
    var bank: String?
    var paidAt: Date = Date.now

    // Proof of payment — kept verbatim, never edited
    var rawMessage: String = ""
    var sender: String = ""
    var receivedAt: Date = Date.now
    /// SHA-256 of sender + receivedAt + text, taken at capture.
    var messageHash: String = ""
    /// Extra SMS for the same payment (bank + UPI app), newest last.
    var additionalMessages: [StoredMessage] = []

    // Triage
    var statusRaw: String = PaymentStatus.pending.rawValue
    var categoryRaw: String = ExpenseCategory.other.rawValue
    /// What you will claim. Starts at `amount`; lower it for partly personal bills.
    var claimableAmount: Double = 0
    var refundedAmount: Double = 0

    var notes: String = ""
    var isManual: Bool = false
    /// 0...1, how much of the message the parser understood.
    var parseConfidence: Double = 1
    var reviewedAt: Date?
    /// Set when moved to personal, so the 30-day sweep can find it.
    var personalSince: Date?

    var trip: Trip?
    @Relationship(deleteRule: .cascade, inverse: \ReceiptFile.payment)
    var receipts: [ReceiptFile] = []

    init(
        amount: Double,
        currency: String = "INR",
        merchant: String,
        instrument: String = "",
        reference: String? = nil,
        bank: String? = nil,
        paidAt: Date = .now,
        rawMessage: String = "",
        sender: String = "",
        receivedAt: Date = .now,
        messageHash: String = "",
        category: ExpenseCategory = .other,
        isManual: Bool = false,
        parseConfidence: Double = 1
    ) {
        self.amount = amount
        self.currency = currency
        self.merchant = merchant
        self.instrument = instrument
        self.reference = reference
        self.bank = bank
        self.paidAt = paidAt
        self.rawMessage = rawMessage
        self.sender = sender
        self.receivedAt = receivedAt
        self.messageHash = messageHash
        self.categoryRaw = category.rawValue
        self.claimableAmount = amount
        self.isManual = isManual
        self.parseConfidence = parseConfidence
    }

    var status: PaymentStatus {
        get { PaymentStatus(rawValue: statusRaw) ?? .pending }
        set {
            statusRaw = newValue.rawValue
            personalSince = newValue == .personal ? .now : nil
            if newValue != .pending { reviewedAt = .now }
        }
    }

    var category: ExpenseCategory {
        get { ExpenseCategory(rawValue: categoryRaw) ?? .other }
        set { categoryRaw = newValue.rawValue }
    }

    /// What actually goes on the claim, after any refund.
    var netClaimable: Double {
        max(0, claimableAmount - refundedAmount)
    }

    var hasReceipt: Bool { !receipts.isEmpty }

    /// Whether the stored message still matches the fingerprint taken when it
    /// arrived — the thing that makes it proof rather than a note.
    var proofIsIntact: Bool {
        guard !messageHash.isEmpty else { return false }
        return ProofHasher.hash(sender: sender, receivedAt: receivedAt, text: rawMessage) == messageHash
    }

    var formattedAmount: String { Money.string(amount, currency: currency) }
    var formattedNetClaimable: String { Money.string(netClaimable, currency: currency) }
}

/// An extra SMS kept as supporting proof for a payment.
struct StoredMessage: Codable, Hashable {
    var text: String
    var sender: String
    var receivedAt: Date
    /// The same SHA-256 fingerprint taken for this extra message at capture.
    var fingerprint: String
}
