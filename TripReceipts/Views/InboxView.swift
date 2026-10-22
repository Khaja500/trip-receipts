import SwiftUI
import SwiftData

/// The listening inbox: every payment caught from an SMS, waiting on one
/// question. Swipe right for work, left for personal.
struct InboxView: View {
    @Environment(\.modelContext) private var context
    @Environment(Router.self) private var router

    @Query(filter: #Predicate<Payment> { $0.statusRaw == "pending" },
           sort: \Payment.receivedAt, order: .reverse)
    private var pending: [Payment]

    @Query(filter: #Predicate<Payment> { $0.statusRaw == "personal" },
           sort: \Payment.reviewedAt, order: .reverse)
    private var personal: [Payment]

    @Query(sort: \Trip.startDate, order: .reverse) private var trips: [Trip]

    @State private var showAddPayment = false
    @State private var showPersonalHistory = false
    @State private var selection: Payment?

    private var store: PaymentStore { PaymentStore(context: context) }

    var body: some View {
        NavigationStack {
            Group {
                if pending.isEmpty {
                    emptyState
                } else {
                    list
                }
            }
            .navigationTitle("Inbox")
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    if !pending.isEmpty { bulkMenu }
                }
                ToolbarItemGroup(placement: .topBarTrailing) {
                    Button {
                        showPersonalHistory = true
                    } label: {
                        Label("Marked personal", systemImage: "clock.arrow.circlepath")
                    }
                    .disabled(personal.isEmpty)

                    Button {
                        showAddPayment = true
                    } label: {
                        Label("Add payment", systemImage: "plus")
                    }
                }
            }
            .sheet(isPresented: $showAddPayment) { AddPaymentView() }
            .sheet(isPresented: $showPersonalHistory) {
                PersonalHistoryView(payments: personal)
            }
            .navigationDestination(item: $selection) { payment in
                PaymentDetailView(payment: payment)
            }
            .onChange(of: router.openPaymentUID) { _, uid in
                guard let uid, let payment = store.payment(uid: uid) else { return }
                selection = payment
            }
            .onAppear {
                if let uid = router.openPaymentUID, let payment = store.payment(uid: uid) {
                    selection = payment
                }
            }
        }
    }

    private var list: some View {
        List {
            Section {
                ForEach(pending) { payment in
                    Button {
                        selection = payment
                    } label: {
                        PaymentRow(payment: payment, hint: hint(for: payment))
                    }
                    .buttonStyle(.plain)
                    .swipeActions(edge: .leading, allowsFullSwipe: true) {
                        Button {
                            markWork(payment)
                        } label: {
                            Label("Work", systemImage: "suitcase.fill")
                        }
                        .tint(.green)
                    }
                    .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                        Button(role: .destructive) {
                            store.markPersonal(payment)
                            refreshReminder()
                        } label: {
                            Label("Personal", systemImage: "person.fill")
                        }
                    }
                    .contextMenu {
                        Button {
                            markWork(payment)
                        } label: {
                            Label("Work travel", systemImage: "suitcase.fill")
                        }
                        if !trips.isEmpty {
                            Menu("File into trip") {
                                ForEach(trips) { trip in
                                    Button(trip.name) {
                                        store.markWork(payment, trip: trip)
                                        refreshReminder()
                                    }
                                }
                            }
                        }
                        Button(role: .destructive) {
                            store.markPersonal(payment)
                            refreshReminder()
                        } label: {
                            Label("Personal", systemImage: "person.fill")
                        }
                    }
                }
            } footer: {
                Text("Swipe right for work travel, left for personal. "
                     + "Long-press to file into a particular trip.")
            }
        }
        .listStyle(.insetGrouped)
    }

    private var bulkMenu: some View {
        Menu {
            Button {
                store.markAll(pending, as: .work)
                refreshReminder()
            } label: {
                Label("Mark all as work", systemImage: "suitcase.fill")
            }
            Button(role: .destructive) {
                store.markAll(pending, as: .personal)
                refreshReminder()
            } label: {
                Label("Mark all as personal", systemImage: "person.fill")
            }
        } label: {
            Label("Mark all", systemImage: "checklist")
        }
    }

    private var emptyState: some View {
        ContentUnavailableView {
            Label("Nothing waiting", systemImage: "tray")
        } description: {
            Text("Payments appear here the moment a bank message arrives. "
                 + "Set up the Shortcuts automations in Setup if you have not yet.")
        } actions: {
            Button("Add a payment") { showAddPayment = true }
        }
    }

    private func hint(for payment: Payment) -> String? {
        if let trip = store.tripCovering(payment.paidAt) { return "During \(trip.name)" }
        if payment.category.isTravel { return payment.category.title }
        if store.payeeSeenAsWorkBefore(payment.merchant) { return "Marked work before" }
        return nil
    }

    private func markWork(_ payment: Payment) {
        store.markWork(payment)
        refreshReminder()
    }

    private func refreshReminder() {
        let count = store.pendingCount()
        Task { await NotificationManager.updatePendingReminder(count: count) }
    }
}

struct PaymentRow: View {
    let payment: Payment
    var hint: String?
    var showStatus = false

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: payment.category.symbol)
                .font(.system(size: 15))
                .foregroundStyle(.tint)
                .frame(width: 32, height: 32)
                .background(.tint.opacity(0.12), in: .rect(cornerRadius: 8))

            VStack(alignment: .leading, spacing: 2) {
                Text(payment.merchant)
                    .font(.body.weight(.medium))
                    .lineLimit(1)

                HStack(spacing: 4) {
                    Text(payment.paidAt, format: .dateTime.day().month(.abbreviated))
                    if !payment.instrument.isEmpty {
                        Text("·")
                        Text(payment.instrument).lineLimit(1)
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)

                if let hint {
                    Text(hint)
                        .font(.caption2)
                        .foregroundStyle(.tint)
                }
            }

            Spacer(minLength: 8)

            VStack(alignment: .trailing, spacing: 2) {
                Text(payment.formattedAmount)
                    .font(.body.weight(.semibold))
                    .monospacedDigit()
                if payment.refundedAmount > 0 {
                    Text("−\(Money.string(payment.refundedAmount, currency: payment.currency))")
                        .font(.caption2)
                        .foregroundStyle(.orange)
                }
                if showStatus && payment.status == .work {
                    if payment.hasReceipt {
                        VerificationBadge(verification: payment.verification)
                    } else {
                        Label("No receipt", systemImage: "exclamationmark.triangle")
                            .font(.caption2)
                            .labelStyle(.titleAndIcon)
                            .foregroundStyle(.orange)
                    }
                }
            }
        }
        .padding(.vertical, 2)
        .contentShape(.rect)
    }
}

/// Kept 30 days so an accidental swipe can be undone.
struct PersonalHistoryView: View {
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    let payments: [Payment]

    var body: some View {
        NavigationStack {
            List {
                if payments.isEmpty {
                    ContentUnavailableView("Nothing here", systemImage: "person")
                } else {
                    Section {
                        ForEach(payments) { payment in
                            HStack {
                                PaymentRow(payment: payment)
                                Button("Undo") {
                                    PaymentStore(context: context).moveToInbox(payment)
                                }
                                .buttonStyle(.bordered)
                                .font(.caption)
                            }
                        }
                    } footer: {
                        Text("Personal payments are deleted 30 days after you mark them.")
                    }
                }
            }
            .navigationTitle("Marked personal")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }
}
