import Foundation
import SwiftData

/// The check of one receipt against its payment, kept with the receipt so
/// the badge, the proof section and the export all tell the same story.
@Model
final class ReceiptVerification {
    var statusRaw: String = VerificationStatus.unverified.rawValue
    var amountResultRaw: String = FieldCheck.unread.rawValue
    var timeResultRaw: String = FieldCheck.unread.rawValue
    var merchantResultRaw: String = FieldCheck.unread.rawValue
    var sourceRaw: String = VerificationSource.onDevice.rawValue
    /// Everything the reader returned, kept so the check can be run again
    /// when the payee or date is corrected.
    var invoiceJSON: Data = Data()
    /// Why the online parser wasn't used, when it wasn't.
    var fallbackReason: String?
    /// The user chose "Add to trip anyway" on a warning.
    var overriddenByUser: Bool = false
    /// Optional, typed in the Add-anyway sheet; goes into the export.
    var userNote: String = ""
    var checkedAt: Date = Date.now
    var receipt: ReceiptFile?

    init(invoice: ParsedInvoice, source: VerificationSource, fallbackReason: String? = nil) {
        self.invoiceJSON = (try? JSONEncoder().encode(invoice)) ?? Data()
        self.sourceRaw = source.rawValue
        self.fallbackReason = fallbackReason
        self.checkedAt = .now
    }

    var status: VerificationStatus { VerificationStatus(rawValue: statusRaw) ?? .unverified }
    var amountResult: FieldCheck { FieldCheck(rawValue: amountResultRaw) ?? .unread }
    var timeResult: FieldCheck { FieldCheck(rawValue: timeResultRaw) ?? .unread }
    var merchantResult: FieldCheck { FieldCheck(rawValue: merchantResultRaw) ?? .unread }
    var source: VerificationSource { VerificationSource(rawValue: sourceRaw) ?? .onDevice }

    var invoice: ParsedInvoice {
        (try? JSONDecoder().decode(ParsedInvoice.self, from: invoiceJSON)) ?? ParsedInvoice()
    }

    // What the parser read. Shown beside the payment, never written over it.
    var parsedTotal: Double? { invoice.total }
    var parsedDate: String? { invoice.invoiceDate }
    var parsedTime: String? { invoice.invoiceTime }
    var parsedMerchant: String? { invoice.merchant }

    /// The comparison as it stands for the payment now.
    func result(for payment: Payment) -> VerificationResult {
        ReceiptVerifier.verify(invoice, against: .init(payment), source: source)
    }

    /// Runs the comparison again and stores its outcome.
    func refresh(against payment: Payment) {
        let result = result(for: payment)
        statusRaw = result.status.rawValue
        amountResultRaw = result.amount.rawValue
        timeResultRaw = result.time.rawValue
        merchantResultRaw = result.merchant.rawValue
    }
}

extension ReceiptVerifier.PaymentSide {
    init(_ payment: Payment) {
        self.init(amount: payment.amount, currency: payment.currency,
                  merchant: payment.merchant, paidAt: payment.paidAt)
    }
}

extension Payment {
    /// The check that speaks for the payment: one matching receipt settles
    /// it; otherwise a warning outranks a receipt that couldn't be verified.
    var verification: ReceiptVerification? {
        let checks = receipts.sorted { $0.addedAt < $1.addedAt }.compactMap(\.verification)
        return checks.first { $0.status == .matched }
            ?? checks.first { $0.status == .warning }
            ?? checks.first
    }

    /// After the payee or date is corrected, every receipt is compared again.
    func reverifyReceipts() {
        for receipt in receipts {
            receipt.verification?.refresh(against: self)
        }
    }
}
