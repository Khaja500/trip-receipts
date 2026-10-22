import Foundation
import SwiftData

@Model
final class ReceiptFile {
    @Attribute(.externalStorage) var data: Data = Data()
    var isPDF: Bool = false
    var filename: String = ""
    var addedAt: Date = Date.now
    /// Text read on-device by Vision, kept so the report can show what was matched.
    var ocrText: String?
    /// Best guess at the bill total, used only as a hint.
    var ocrTotal: Double?
    var payment: Payment?
    /// The check against the payment. Nil on receipts attached before
    /// checking existed; they keep the older total-only hint.
    @Relationship(deleteRule: .cascade, inverse: \ReceiptVerification.receipt)
    var verification: ReceiptVerification?

    init(data: Data, isPDF: Bool, filename: String = "", ocrText: String? = nil, ocrTotal: Double? = nil) {
        self.data = data
        self.isPDF = isPDF
        self.filename = filename.isEmpty ? (isPDF ? "receipt.pdf" : "receipt.jpg") : filename
        self.addedAt = .now
        self.ocrText = ocrText
        self.ocrTotal = ocrTotal
    }

    /// Whether the read total agrees with the payment, within 1%. Only for
    /// receipts without a `verification`.
    var matchesPaymentTotal: Bool? {
        guard let ocrTotal, let amount = payment?.amount, amount > 0 else { return nil }
        return abs(ocrTotal - amount) / amount <= 0.01
    }
}
