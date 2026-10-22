import Foundation
import SwiftData

/// Everything that happens to a payment between "an SMS arrived" and "it is
/// filed under a trip". Kept out of the views so the App Intent, which runs
/// with no UI at all, can use exactly the same path.
struct PaymentStore {
    let context: ModelContext

    init(context: ModelContext) {
        self.context = context
    }

    // MARK: - Intake

    enum Intake: Equatable {
        case created(Payment)
        /// Same payment seen again; the extra text was kept as more proof.
        case duplicate(Payment)
        /// A refund matched to an earlier payment.
        case refunded(Payment, amount: Double)
        case ignored(ParseRejection)
    }

    /// The one way a message becomes a payment. Safe to call twice with the
    /// same text — the second call is recognised as a duplicate.
    @discardableResult
    func intake(message: String, sender: String, receivedAt: Date = .now) -> Intake {
        let trimmed = message.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return .ignored(.noAmount) }

        switch SMSParser.parse(trimmed, sender: sender, now: receivedAt) {
        case .ignored(let reason):
            return .ignored(reason)

        case .payment(let parsed):
            let hash = ProofHasher.hash(sender: sender, receivedAt: receivedAt, text: trimmed)

            if parsed.direction == .refund {
                if let original = matchForRefund(parsed, receivedAt: receivedAt) {
                    original.refundedAmount += parsed.amount
                    original.additionalMessages.append(
                        StoredMessage(text: trimmed, sender: sender, receivedAt: receivedAt, fingerprint: hash)
                    )
                    try? context.save()
                    return .refunded(original, amount: parsed.amount)
                }
                // A refund with nothing to match is not a claim; drop it.
                return .ignored(.credit)
            }

            if let existing = duplicate(of: parsed, text: trimmed, hash: hash, receivedAt: receivedAt) {
                // Keep the second message — bank plus UPI app is stronger proof.
                if existing.rawMessage != trimmed,
                   !existing.additionalMessages.contains(where: { $0.fingerprint == hash }) {
                    existing.additionalMessages.append(
                        StoredMessage(text: trimmed, sender: sender, receivedAt: receivedAt, fingerprint: hash)
                    )
                    try? context.save()
                }
                return .duplicate(existing)
            }

            let payment = Payment(
                amount: parsed.amount,
                currency: parsed.currency,
                merchant: parsed.merchant,
                instrument: parsed.instrument,
                reference: parsed.reference,
                bank: parsed.bank,
                paidAt: parsed.paidAt ?? receivedAt,
                rawMessage: trimmed,
                sender: sender,
                receivedAt: receivedAt,
                messageHash: hash,
                category: CategoryGuesser.guess(payee: parsed.merchant, message: trimmed),
                parseConfidence: parsed.confidence
            )
            context.insert(payment)
            try? context.save()
            return .created(payment)
        }
    }

    /// A payment typed in by hand — cash, or anything that never sent an SMS.
    @discardableResult
    func addManual(
        amount: Double,
        currency: String = "INR",
        merchant: String,
        category: ExpenseCategory,
        paidAt: Date,
        instrument: String = "Cash",
        notes: String = "",
        status: PaymentStatus = .work
    ) -> Payment {
        let payment = Payment(
            amount: amount,
            currency: currency,
            merchant: merchant,
            instrument: instrument,
            paidAt: paidAt,
            category: category,
            isManual: true
        )
        payment.notes = notes
        context.insert(payment)
        if status == .work { markWork(payment) } else { payment.status = status }
        try? context.save()
        return payment
    }

    // MARK: - Duplicates

    /// Looks back three days — long enough for the bank and the UPI app to
    /// disagree about when they send, short enough to stay cheap.
    func duplicate(of parsed: ParsedPayment, text: String, hash: String, receivedAt: Date) -> Payment? {
        let incoming = PaymentFacts(
            amount: parsed.amount,
            merchant: parsed.merchant,
            reference: parsed.reference,
            receivedAt: receivedAt,
            messageHash: hash,
            rawMessage: text
        )
        return recentPayments(since: receivedAt.addingTimeInterval(-60 * 60 * 24 * 3))
            .first { MatchingRules.isDuplicate(incoming: incoming, existing: facts(for: $0)) }
    }

    private func matchForRefund(_ parsed: ParsedPayment, receivedAt: Date) -> Payment? {
        let candidates = recentPayments(since: receivedAt.addingTimeInterval(-60 * 60 * 24 * 120))
            .filter { $0.status != .personal && $0.refundedAmount < $0.amount }
        let refund = PaymentFacts(
            amount: parsed.amount,
            merchant: parsed.merchant,
            reference: parsed.reference,
            receivedAt: receivedAt,
            messageHash: "",
            rawMessage: ""
        )
        // Reference is the stronger signal, so try every candidate on it first;
        // a partial refund will not match on amount at all.
        if let reference = parsed.reference, !reference.isEmpty,
           let byReference = candidates.first(where: { $0.reference == reference }) {
            return byReference
        }
        return candidates.first { MatchingRules.refundMatches(refund: refund, candidate: facts(for: $0)) }
    }

    private func facts(for payment: Payment) -> PaymentFacts {
        PaymentFacts(
            amount: payment.amount,
            merchant: payment.merchant,
            reference: payment.reference,
            receivedAt: payment.receivedAt,
            messageHash: payment.messageHash,
            rawMessage: payment.rawMessage,
            additionalHashes: payment.additionalMessages.map(\.fingerprint)
        )
    }

    private func recentPayments(since: Date) -> [Payment] {
        let descriptor = FetchDescriptor<Payment>(
            predicate: #Predicate { $0.receivedAt >= since },
            sortBy: [SortDescriptor(\.receivedAt, order: .reverse)]
        )
        return (try? context.fetch(descriptor)) ?? []
    }

    // MARK: - Triage

    /// Marks a payment as work and files it to the trip covering its date.
    func markWork(_ payment: Payment, trip: Trip? = nil) {
        payment.status = .work
        if let trip {
            payment.trip = trip
        } else if payment.trip == nil {
            payment.trip = tripCovering(payment.paidAt)
        }
        try? context.save()
    }

    func markPersonal(_ payment: Payment) {
        payment.status = .personal
        payment.trip = nil
        try? context.save()
    }

    func moveToInbox(_ payment: Payment) {
        payment.status = .pending
        payment.trip = nil
        payment.reviewedAt = nil
        try? context.save()
    }

    func markAll(_ payments: [Payment], as status: PaymentStatus) {
        for payment in payments {
            switch status {
            case .work: markWork(payment)
            case .personal: markPersonal(payment)
            case .pending: moveToInbox(payment)
            }
        }
    }

    // MARK: - Receipts

    /// Files a receipt with its check. A receipt answers a waiting payment's
    /// question — unless it disagrees with the payment, and then the payment
    /// waits for "Add to trip anyway" or a better receipt.
    @discardableResult
    func attachReceipt(
        _ data: Data, isPDF: Bool, filename: String, check: ReceiptCheck.Outcome, to payment: Payment
    ) -> ReceiptVerification {
        let receipt = ReceiptFile(data: data, isPDF: isPDF, filename: filename,
                                  ocrText: check.reading.text, ocrTotal: check.reading.total)
        receipt.payment = payment
        context.insert(receipt)

        let verification = ReceiptVerification(invoice: check.invoice, source: check.source,
                                               fallbackReason: check.fallbackReason)
        context.insert(verification)
        receipt.verification = verification
        verification.refresh(against: payment)

        if payment.status == .pending && verification.status != .warning {
            markWork(payment)
        } else {
            try? context.save()
        }
        return verification
    }

    /// Sends receipts the server never saw — attached offline or before a
    /// parser was set up — and stores the new result. Filing is left alone:
    /// the payment has already been answered one way or the other.
    @MainActor
    func recheckOnline(_ payment: Payment) async {
        for receipt in payment.receipts where receipt.verification?.source != .online {
            let check = await ReceiptCheck.run(data: receipt.data, isPDF: receipt.isPDF,
                                               filename: receipt.filename, for: .init(payment))
            guard check.source == .online else { continue }
            if let verification = receipt.verification {
                verification.reread(check.invoice, source: .online, fallbackReason: nil, against: payment)
            } else {
                let verification = ReceiptVerification(invoice: check.invoice, source: .online)
                context.insert(verification)
                receipt.verification = verification
                verification.refresh(against: payment)
            }
        }
        try? context.save()
    }

    /// "Add to trip anyway": the receipt stays, the payment is filed, and the
    /// choice — with any note — travels into the proof and the export.
    func addAnyway(_ verification: ReceiptVerification, note: String, payment: Payment) {
        verification.overriddenByUser = true
        verification.userNote = note.trimmingCharacters(in: .whitespacesAndNewlines)
        if payment.status == .work {
            try? context.save()
        } else {
            markWork(payment)
        }
    }

    // MARK: - Trips

    func tripCovering(_ date: Date) -> Trip? {
        let trips = (try? context.fetch(FetchDescriptor<Trip>())) ?? []
        // Shortest matching trip wins, so a day-trip inside a longer one is used.
        return trips.filter { $0.covers(date) }
            .min { $0.endDate.timeIntervalSince($0.startDate) < $1.endDate.timeIntervalSince($1.startDate) }
    }

    /// When a trip is created after the fact, pull in work expenses already
    /// sitting in its dates and not yet filed anywhere.
    @discardableResult
    func sweepIntoTrip(_ trip: Trip) -> Int {
        let descriptor = FetchDescriptor<Payment>(
            predicate: #Predicate { $0.statusRaw == "work" }
        )
        let unfiled = ((try? context.fetch(descriptor)) ?? []).filter {
            $0.trip == nil && trip.covers($0.paidAt)
        }
        for payment in unfiled { payment.trip = trip }
        try? context.save()
        return unfiled.count
    }

    /// Payments that would be swept in, shown before the trip is saved.
    func sweepCandidates(start: Date, end: Date) -> [Payment] {
        let probe = Trip(name: "", startDate: start, endDate: end)
        let descriptor = FetchDescriptor<Payment>(
            predicate: #Predicate { $0.statusRaw == "work" }
        )
        return ((try? context.fetch(descriptor)) ?? []).filter {
            $0.trip == nil && probe.covers($0.paidAt)
        }
    }

    // MARK: - Housekeeping

    /// Personal payments are kept 30 days so duplicates can still be spotted
    /// and an accidental swipe undone, then deleted.
    func purgeOldPersonal(now: Date = .now) {
        let descriptor = FetchDescriptor<Payment>(
            predicate: #Predicate { $0.statusRaw == "personal" }
        )
        let stale = ((try? context.fetch(descriptor)) ?? []).filter {
            MatchingRules.personalHasExpired(markedAt: $0.personalSince ?? $0.receivedAt, now: now)
        }
        for payment in stale { context.delete(payment) }
        if !stale.isEmpty { try? context.save() }
    }

    func pendingCount() -> Int {
        let descriptor = FetchDescriptor<Payment>(predicate: #Predicate { $0.statusRaw == "pending" })
        return (try? context.fetchCount(descriptor)) ?? 0
    }

    func payment(uid: String) -> Payment? {
        var descriptor = FetchDescriptor<Payment>(predicate: #Predicate { $0.uid == uid })
        descriptor.fetchLimit = 1
        return (try? context.fetch(descriptor))?.first
    }

    /// Whether this payee has been marked work before — one of the hints the
    /// notification shows.
    func payeeSeenAsWorkBefore(_ merchant: String) -> Bool {
        let descriptor = FetchDescriptor<Payment>(
            predicate: #Predicate { $0.statusRaw == "work" && $0.merchant == merchant }
        )
        return ((try? context.fetchCount(descriptor)) ?? 0) > 0
    }
}
