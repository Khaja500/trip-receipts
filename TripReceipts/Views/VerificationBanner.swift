import SwiftUI

/// What a receipt check found, in words: on the payment, on the receipt, and
/// with the two ways forward when it doesn't match.
struct VerificationBanner: View {
    let verification: ReceiptVerification
    let result: VerificationResult
    let currency: String
    var onFix: (() -> Void)? = nil
    var onAddAnyway: (() -> Void)? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label {
                Text(VerificationText.title(verification)).font(.subheadline.weight(.semibold))
            } icon: {
                Image(systemName: VerificationText.symbol(verification))
                    .foregroundStyle(VerificationText.tint(verification))
            }

            let lines = VerificationText.details(verification, result, currency: currency)
            if !lines.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(lines, id: \.self) { Text($0) }
                }
                .font(.callout)
            }

            if verification.overriddenByUser {
                Text(verification.userNote.isEmpty
                     ? "You added it to the trip anyway."
                     : "You added it anyway: \u{201C}\(verification.userNote)\u{201D}")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if onFix != nil || onAddAnyway != nil {
                HStack(spacing: 10) {
                    if let onFix {
                        Button("Fix the receipt", action: onFix)
                            .buttonStyle(.bordered)
                    }
                    if let onAddAnyway {
                        Button("Add to trip anyway", action: onAddAnyway)
                            .buttonStyle(.borderedProminent)
                            .tint(.orange)
                    }
                }
                .font(.callout.weight(.medium))
            }
        }
        .padding(.vertical, 4)
    }
}

/// ✓ verified, ⚠ doesn't match, ○ unverified — on expense rows and receipts.
struct VerificationBadge: View {
    /// Nil for a receipt attached before checking existed.
    let verification: ReceiptVerification?

    var body: some View {
        Group {
            if let verification {
                Label(VerificationText.badge(verification), systemImage: VerificationText.symbol(verification))
                    .foregroundStyle(VerificationText.tint(verification))
            } else {
                Label("Receipt", systemImage: "paperclip").foregroundStyle(.secondary)
            }
        }
        .font(.caption2)
        .labelStyle(.titleAndIcon)
    }
}

/// Every field the parser read and how it compared — for the proof section.
struct ReceiptCheckDetails: View {
    let verification: ReceiptVerification
    let payment: Payment

    var body: some View {
        let invoice = verification.invoice
        let currency = invoice.currency ?? payment.currency
        VStack(alignment: .leading, spacing: 5) {
            Label {
                Text("Receipt check · \(verification.receipt?.filename ?? "receipt")")
                    .font(.caption.weight(.medium))
            } icon: {
                Image(systemName: VerificationText.symbol(verification))
                    .foregroundStyle(VerificationText.tint(verification))
            }
            row("Result", VerificationText.title(verification))
            row("Total read", invoice.total.map { Money.string($0, currency: currency) }, verification.amountResult)
            row("Date read", VerificationText.readDate(invoice), verification.timeResult)
            if let period = VerificationText.period(invoice) {
                row(invoice.isHotel ? "Stay" : "Travel", period)
            }
            row("Merchant read", invoice.merchant, verification.merchantResult)
            if let number = invoice.invoiceNumber { row("Invoice no.", number) }
            row("Read by", verification.source == .online ? "Online parser" : "This iPhone")
            if let reason = verification.fallbackReason, verification.source == .onDevice {
                row("Why", reason)
            }
            if verification.overriddenByUser {
                row("Added anyway", verification.userNote.isEmpty ? "Yes" : verification.userNote)
            }
        }
        .font(.caption)
    }

    private func row(_ label: String, _ value: String?, _ check: FieldCheck? = nil) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text(label).foregroundStyle(.secondary).frame(width: 96, alignment: .leading)
            Text(value ?? "not read").foregroundStyle(value == nil ? .secondary : .primary)
            if let check, value != nil {
                Image(systemName: VerificationText.symbol(check))
                    .foregroundStyle(VerificationText.tint(check))
                    .accessibilityLabel(check.rawValue)
            }
        }
    }
}

/// The words and marks for a receipt check, shared by the screens above.
enum VerificationText {

    static func title(_ v: ReceiptVerification) -> String {
        switch v.status {
        case .matched: "Matches the payment"
        case .warning: v.overriddenByUser ? "Added anyway — doesn't match" : "Doesn't match the payment"
        case .unverified: v.source == .onDevice ? "Not verified online" : "Couldn't verify"
        }
    }

    static func badge(_ v: ReceiptVerification) -> String {
        switch v.status {
        case .matched: "Verified"
        case .warning: v.overriddenByUser ? "Added anyway" : "Doesn't match"
        case .unverified: "Unverified"
        }
    }

    /// What differs, what was let through, or why it couldn't be checked.
    static func details(_ v: ReceiptVerification, _ result: VerificationResult, currency: String) -> [String] {
        switch v.status {
        case .warning:
            return result.differences.map(capitalised)
        case .matched:
            return result.notes.map(capitalised)
        case .unverified where v.source == .onDevice:
            var lines = [v.fallbackReason ?? "The parser wasn't used."]
            if let total = v.invoice.total {
                lines.append("Read on this phone: total \(Money.string(total, currency: currency))"
                             + (result.amount == .match ? ", the same as the payment." : "."))
            } else {
                lines.append("No total could be read on this phone either.")
            }
            return lines
        case .unverified:
            return result.notes.map(capitalised)
        }
    }

    static func symbol(_ v: ReceiptVerification) -> String {
        switch v.status {
        case .matched: "checkmark.circle.fill"
        case .warning: "exclamationmark.triangle.fill"
        case .unverified: "circle.dashed"
        }
    }

    static func tint(_ v: ReceiptVerification) -> Color {
        switch v.status {
        case .matched: .green
        case .warning: .orange
        case .unverified: .secondary
        }
    }

    static func symbol(_ check: FieldCheck) -> String {
        switch check {
        case .match: "checkmark.circle.fill"
        case .close, .weak: "checkmark.circle"
        case .mismatch: "xmark.circle.fill"
        case .unread: "minus.circle"
        }
    }

    static func tint(_ check: FieldCheck) -> Color {
        switch check {
        case .match: .green
        case .close, .weak: .secondary
        case .mismatch: .orange
        case .unread: .secondary
        }
    }

    static func capitalised(_ phrase: String) -> String {
        VerificationResult.sentence([phrase])
    }

    /// "12 Oct 2025, 09:41"
    static func readDate(_ invoice: ParsedInvoice) -> String? {
        guard let day = ReceiptVerifier.day(invoice.invoiceDate, calendar: .current) else { return nil }
        let date = day.formatted(.dateTime.day().month(.abbreviated).year())
        return invoice.invoiceTime.map { "\(date), \($0)" } ?? date
    }

    /// "12 Oct – 15 Oct 2025"
    static func period(_ invoice: ParsedInvoice) -> String? {
        guard let start = ReceiptVerifier.day(invoice.periodStart, calendar: .current) else { return nil }
        let end = ReceiptVerifier.day(invoice.periodEnd, calendar: .current) ?? start
        return (start..<max(end, start.addingTimeInterval(1)))
            .formatted(.interval.day().month(.abbreviated).year())
    }
}
