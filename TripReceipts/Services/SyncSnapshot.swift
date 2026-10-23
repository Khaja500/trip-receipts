import Foundation
import SwiftData
import CryptoKit

/// What the website sees: every payment and trip on the phone as plain
/// values, written to one JSON file. Receipt images stay on the phone — only
/// their names, the total read from them and the result of their check go up.
///
/// Dates encode as ISO 8601 to the second, the same stamp `ProofHasher`
/// signs, so the website can recompute each fingerprint from the text it is
/// shown.
struct SyncSnapshot: Codable, Equatable {
    static let schemaVersion = 1

    var schema = SyncSnapshot.schemaVersion
    var generatedAt: Date
    /// "work" on the copy written for someone else to read (see `workOnly`);
    /// absent on the full snapshot, so that file is unchanged.
    var scope: String?
    var payments: [PaymentRecord]
    var trips: [TripRecord]

    struct PaymentRecord: Codable, Equatable {
        var uid: String
        var status: String
        var amount: Double
        var currency: String
        var merchant: String
        var instrument: String
        var reference: String?
        var bank: String?
        var paidAt: Date
        var category: String
        var claimableAmount: Double
        var refundedAmount: Double
        var netClaimable: Double
        var notes: String
        var isManual: Bool
        var parseConfidence: Double
        var reviewedAt: Date?
        var tripID: String?
        var receipts: [ReceiptRecord]

        // Proof of payment, verbatim
        var rawMessage: String
        var sender: String
        var receivedAt: Date
        var messageHash: String
        var additionalMessages: [StoredMessage]
    }

    struct ReceiptRecord: Codable, Equatable {
        var filename: String
        var isPDF: Bool
        var addedAt: Date
        var ocrTotal: Double?
        /// Absent for receipts attached before checking existed.
        var verification: VerificationRecord?
    }

    /// The receipt check as the phone last ran it. The website shows it as
    /// is rather than comparing again, so both always agree.
    struct VerificationRecord: Codable, Equatable {
        var status: String
        var amount: String
        var time: String
        var merchant: String
        var source: String
        var parsedTotal: Double?
        var parsedCurrency: String?
        var parsedDate: String?
        var parsedTime: String?
        var parsedMerchant: String?
        var invoiceNumber: String?
        var overridden: Bool
        var note: String
        /// What differs, or what was let through — one sentence.
        var summary: String
        var fallbackReason: String?
    }

    struct TripRecord: Codable, Equatable {
        var id: String
        var name: String
        var destination: String
        var startDate: Date
        var endDate: Date
        var purpose: String
        var client: String
        var costCentre: String
    }
}

extension SyncSnapshot {
    static func build(context: ModelContext, at now: Date = .now) throws -> SyncSnapshot {
        let payments = try context.fetch(FetchDescriptor<Payment>(
            sortBy: [SortDescriptor(\.receivedAt, order: .reverse)]
        ))
        let trips = try context.fetch(FetchDescriptor<Trip>(
            sortBy: [SortDescriptor(\.startDate, order: .reverse)]
        ))
        return SyncSnapshot(
            generatedAt: now,
            payments: payments.map(PaymentRecord.init),
            trips: trips.map(TripRecord.init)
        )
    }

    /// What the shared repo gets: work expenses and the trips they're filed
    /// under, each with its original message as proof. Waiting and personal
    /// payments never leave in this copy.
    func workOnly() -> SyncSnapshot {
        var copy = self
        copy.scope = "work"
        copy.payments = payments.filter { $0.status == PaymentStatus.work.rawValue }
        return copy
    }

    /// Pretty-printed with sorted keys, so each sync is a readable diff in
    /// the repo's history.
    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return encoder
    }()

    func encoded() throws -> Data {
        try Self.encoder.encode(self)
    }

    /// Changes when the data does, not when the snapshot was taken — what
    /// decides whether there is anything to upload.
    func contentDigest() throws -> String {
        var undated = self
        undated.generatedAt = Date(timeIntervalSince1970: 0)
        let digest = SHA256.hash(data: try undated.encoded())
        return digest.map { String(format: "%02x", $0) }.joined()
    }
}

extension SyncSnapshot.PaymentRecord {
    init(_ p: Payment) {
        self.init(
            uid: p.uid,
            status: p.statusRaw,
            amount: p.amount,
            currency: p.currency,
            merchant: p.merchant,
            instrument: p.instrument,
            reference: p.reference,
            bank: p.bank,
            paidAt: p.paidAt,
            category: p.categoryRaw,
            claimableAmount: p.claimableAmount,
            refundedAmount: p.refundedAmount,
            netClaimable: p.netClaimable,
            notes: p.notes,
            isManual: p.isManual,
            parseConfidence: p.parseConfidence,
            reviewedAt: p.reviewedAt,
            tripID: p.trip?.syncID,
            receipts: p.receipts
                .sorted { $0.addedAt < $1.addedAt }
                .map { SyncSnapshot.ReceiptRecord(filename: $0.filename, isPDF: $0.isPDF,
                                                  addedAt: $0.addedAt, ocrTotal: $0.ocrTotal,
                                                  verification: $0.verification.map { .init($0, payment: p) }) },
            rawMessage: p.rawMessage,
            sender: p.sender,
            receivedAt: p.receivedAt,
            messageHash: p.messageHash,
            additionalMessages: p.additionalMessages
        )
    }
}

extension SyncSnapshot.VerificationRecord {
    init(_ v: ReceiptVerification, payment: Payment) {
        let invoice = v.invoice
        self.init(
            status: v.statusRaw,
            amount: v.amountResultRaw,
            time: v.timeResultRaw,
            merchant: v.merchantResultRaw,
            source: v.sourceRaw,
            parsedTotal: invoice.total,
            parsedCurrency: invoice.currency,
            parsedDate: invoice.invoiceDate,
            parsedTime: invoice.invoiceTime,
            parsedMerchant: invoice.merchant,
            invoiceNumber: invoice.invoiceNumber,
            overridden: v.overriddenByUser,
            note: v.userNote,
            summary: v.result(for: payment).summary,
            fallbackReason: v.fallbackReason
        )
    }
}

extension SyncSnapshot.TripRecord {
    init(_ t: Trip) {
        self.init(
            id: t.syncID,
            name: t.name,
            destination: t.destination,
            startDate: t.startDate,
            endDate: t.endDate,
            purpose: t.purpose,
            client: t.client,
            costCentre: t.costCentre
        )
    }
}

extension Trip {
    /// Stable id for the website. Trips have no uid, and adding one now would
    /// give every existing trip the same migrated default, so creation time —
    /// never edited — stands in.
    var syncID: String {
        String(Int64((createdAt.timeIntervalSince1970 * 1000).rounded()))
    }
}
