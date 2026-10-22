import SwiftUI
import SwiftData

/// Every work expense, grouped by trip, with the two numbers that matter:
/// what it adds up to, and how many are still missing a receipt.
struct ExpensesView: View {
    @Environment(\.modelContext) private var context

    @Query(filter: #Predicate<Payment> { $0.statusRaw == "work" },
           sort: \Payment.paidAt, order: .reverse)
    private var work: [Payment]

    @Query(sort: \Trip.startDate, order: .reverse) private var trips: [Trip]

    @State private var filter: Filter = .all
    @State private var selectedTrip: Trip?

    enum Filter: String, CaseIterable, Identifiable {
        case all = "All"
        case missingReceipts = "Missing receipts"
        case notInTrip = "Not in a trip"
        var id: String { rawValue }
    }

    private var filtered: [Payment] {
        var items = work
        switch filter {
        case .all: break
        case .missingReceipts: items = items.filter { !$0.hasReceipt }
        case .notInTrip: items = items.filter { $0.trip == nil }
        }
        if let selectedTrip { items = items.filter { $0.trip == selectedTrip } }
        return items
    }

    private var grouped: [(trip: Trip?, payments: [Payment])] {
        let groups = Dictionary(grouping: filtered) { $0.trip }
        return groups
            .sorted { lhs, rhs in
                // Trips first, newest trip at the top; loose expenses last.
                switch (lhs.key, rhs.key) {
                case let (l?, r?): return l.startDate > r.startDate
                case (_?, nil): return true
                case (nil, _?): return false
                default: return false
                }
            }
            .map { (trip: $0.key, payments: $0.value) }
    }

    private var total: Double { filtered.reduce(0) { $0 + $1.netClaimable } }
    private var missing: Int { filtered.filter { !$0.hasReceipt }.count }

    private var filterLabel: String {
        if let selectedTrip { return selectedTrip.name }
        return filter == .all ? "Filter" : filter.rawValue
    }

    var body: some View {
        NavigationStack {
            Group {
                if work.isEmpty {
                    ContentUnavailableView(
                        "No work expenses yet",
                        systemImage: "indianrupeesign.circle",
                        description: Text("Answer a payment in the Inbox and it lands here.")
                    )
                } else {
                    list
                }
            }
            .navigationTitle("Work expenses")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Picker("Show", selection: $filter) {
                            ForEach(Filter.allCases) { Text($0.rawValue).tag($0) }
                        }
                        if !trips.isEmpty {
                            Picker("Trip", selection: $selectedTrip) {
                                Text("Every trip").tag(Trip?.none)
                                ForEach(trips) { trip in
                                    Text(trip.name).tag(Trip?.some(trip))
                                }
                            }
                        }
                    } label: {
                        Label(filterLabel, systemImage: "line.3.horizontal.decrease.circle")
                    }
                }
            }
            .navigationDestination(for: Payment.self) { PaymentDetailView(payment: $0) }
        }
    }

    private var list: some View {
        List {
            Section {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Total to claim").font(.caption).foregroundStyle(.secondary)
                        Text(Money.string(total, currency: filtered.first?.currency ?? "INR"))
                            .font(.title2.weight(.semibold))
                            .monospacedDigit()
                    }
                    Spacer()
                    if missing > 0 {
                        VStack(alignment: .trailing, spacing: 2) {
                            Text("Missing receipts").font(.caption).foregroundStyle(.secondary)
                            Text("\(missing)")
                                .font(.title2.weight(.semibold))
                                .foregroundStyle(.orange)
                        }
                    }
                }
                .padding(.vertical, 2)
            }

            ForEach(grouped, id: \.trip?.persistentModelID) { group in
                Section {
                    ForEach(group.payments) { payment in
                        NavigationLink(value: payment) {
                            PaymentRow(payment: payment, showStatus: true)
                        }
                    }
                    .onDelete { offsets in
                        for index in offsets {
                            PaymentStore(context: context).moveToInbox(group.payments[index])
                        }
                    }
                } header: {
                    HStack {
                        Text(group.trip?.name ?? "Not in a trip")
                        Spacer()
                        Text(Money.string(group.payments.reduce(0) { $0 + $1.netClaimable },
                                          currency: group.payments.first?.currency ?? "INR"))
                            .monospacedDigit()
                    }
                }
            }
        }
    }
}
