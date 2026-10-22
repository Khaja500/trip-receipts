import SwiftUI
import SwiftData

/// The two fallback paths from the spec: paste an SMS the automation missed,
/// or enter a payment that never produced one (cash, mostly).
struct AddPaymentView: View {
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss

    enum Mode: String, CaseIterable, Identifiable {
        case paste = "Paste a message"
        case manual = "Enter by hand"
        var id: String { rawValue }
    }

    @State private var mode: Mode = .paste

    // Paste
    @State private var messageText = ""
    @State private var senderText = ""
    @State private var pasteResult: String?
    @State private var pasteFailed = false

    // Manual
    @State private var amountText = ""
    @State private var currency = "INR"
    @State private var merchant = ""
    @State private var category: ExpenseCategory = .other
    @State private var paidAt = Date.now
    @State private var instrument = "Cash"
    @State private var notes = ""

    var body: some View {
        NavigationStack {
            Form {
                Picker("How", selection: $mode) {
                    ForEach(Mode.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .listRowInsets(EdgeInsets())
                .listRowBackground(Color.clear)

                switch mode {
                case .paste: pasteSection
                case .manual: manualSection
                }
            }
            .navigationTitle("Add payment")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Add", action: add).disabled(!canAdd)
                }
            }
        }
    }

    @ViewBuilder
    private var pasteSection: some View {
        Section {
            TextField("Paste the bank message here", text: $messageText, axis: .vertical)
                .lineLimit(4...10)
                .font(.system(.footnote, design: .monospaced))
            TextField("Sender (optional), e.g. AD-HDFCBK", text: $senderText)
                .textInputAutocapitalization(.characters)
        } header: {
            Text("Message")
        } footer: {
            Text("The text is kept exactly as pasted and becomes the proof of payment.")
        }

        if let pasteResult {
            Section {
                Label(pasteResult, systemImage: pasteFailed ? "exclamationmark.triangle" : "checkmark.circle")
                    .foregroundStyle(pasteFailed ? .orange : .green)
                    .font(.callout)
                if pasteFailed {
                    Button("Enter it by hand instead") {
                        mode = .manual
                        pasteResultCleared()
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var manualSection: some View {
        Section("Payment") {
            LabeledContent("Amount") {
                HStack(spacing: 6) {
                    TextField("0", text: $amountText)
                        .keyboardType(.decimalPad)
                        .multilineTextAlignment(.trailing)
                    TextField("INR", text: $currency)
                        .frame(width: 52)
                        .textInputAutocapitalization(.characters)
                }
            }
            TextField("Paid to", text: $merchant)
            Picker("Category", selection: $category) {
                ForEach(ExpenseCategory.allCases) { category in
                    Label(category.title, systemImage: category.symbol).tag(category)
                }
            }
            DatePicker("Date", selection: $paidAt, displayedComponents: [.date, .hourAndMinute])
            TextField("Paid by, e.g. Cash", text: $instrument)
        }

        Section("Notes") {
            TextField("What was this for?", text: $notes, axis: .vertical)
                .lineLimit(2...5)
        }

        Section {
            Text("Entered by hand, so there is no bank message to attach as proof. "
                 + "The receipt carries the claim — add one on the next screen.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var canAdd: Bool {
        switch mode {
        case .paste:
            return !messageText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        case .manual:
            return Double(amountText) ?? 0 > 0
                && !merchant.trimmingCharacters(in: .whitespaces).isEmpty
        }
    }

    private func pasteResultCleared() {
        pasteResult = nil
        pasteFailed = false
    }

    private func add() {
        let store = PaymentStore(context: context)

        switch mode {
        case .paste:
            let sender = senderText.isEmpty ? "Pasted" : senderText
            switch store.intake(message: messageText, sender: sender) {
            case .created(let payment):
                Task { await NotificationManager.updatePendingReminder(count: store.pendingCount()) }
                _ = payment
                dismiss()

            case .duplicate(let payment):
                pasteFailed = true
                pasteResult = "Already in the inbox: \(payment.formattedAmount) to \(payment.merchant). "
                    + "The text was kept as extra proof."

            case .refunded(let payment, let amount):
                pasteFailed = false
                pasteResult = "Matched as a refund of "
                    + "\(Money.string(amount, currency: payment.currency)) on \(payment.merchant)."

            case .ignored(let reason):
                pasteFailed = true
                pasteResult = "\(reason.rawValue). Nothing was saved."
            }

        case .manual:
            guard let amount = Double(amountText) else { return }
            store.addManual(
                amount: amount,
                currency: currency.isEmpty ? "INR" : currency.uppercased(),
                merchant: merchant,
                category: category,
                paidAt: paidAt,
                instrument: instrument,
                notes: notes
            )
            dismiss()
        }
    }
}
