import SwiftUI
import SwiftData

struct TripsView: View {
    @Environment(\.modelContext) private var context
    @Query(sort: \Trip.startDate, order: .reverse) private var trips: [Trip]
    @State private var showEditor = false

    var body: some View {
        NavigationStack {
            Group {
                if trips.isEmpty {
                    ContentUnavailableView {
                        Label("No trips yet", systemImage: "suitcase")
                    } description: {
                        Text("A trip collects the payments made during its dates, "
                             + "so a claim is one export rather than an evening of digging.")
                    } actions: {
                        Button("New trip") { showEditor = true }
                    }
                } else {
                    List {
                        ForEach(trips) { trip in
                            NavigationLink(value: trip) { TripRow(trip: trip) }
                        }
                        .onDelete(perform: delete)
                    }
                }
            }
            .navigationTitle("Trips")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button { showEditor = true } label: { Label("New trip", systemImage: "plus") }
                }
            }
            .sheet(isPresented: $showEditor) { TripEditorView() }
            .navigationDestination(for: Trip.self) { TripDetailView(trip: $0) }
        }
    }

    private func delete(at offsets: IndexSet) {
        for index in offsets {
            // Expenses outlive the trip; they just stop being filed under it.
            for payment in trips[index].payments { payment.trip = nil }
            context.delete(trips[index])
        }
        try? context.save()
    }
}

struct TripRow: View {
    let trip: Trip

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(trip.name).font(.body.weight(.medium))
                if trip.isActive {
                    Text("Active")
                        .font(.caption2.weight(.medium))
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background(.green.opacity(0.15), in: .capsule)
                        .foregroundStyle(.green)
                }
                Spacer()
                Text(trip.formattedTotal).font(.body.weight(.semibold)).monospacedDigit()
            }
            HStack(spacing: 6) {
                if !trip.destination.isEmpty {
                    Text(trip.destination)
                    Text("·")
                }
                Text(trip.dateRangeText)
                Text("·")
                Text("\(trip.workPayments.count) expenses")
            }
            .font(.caption)
            .foregroundStyle(.secondary)

            if trip.missingReceiptCount > 0 {
                Label("\(trip.missingReceiptCount) without a receipt",
                      systemImage: "exclamationmark.triangle")
                    .font(.caption2)
                    .foregroundStyle(.orange)
            }
        }
        .padding(.vertical, 2)
    }
}

struct TripDetailView: View {
    @Environment(\.modelContext) private var context
    @Bindable var trip: Trip
    @State private var showEditor = false
    @State private var pack: ReportBuilder.Pack?
    @State private var buildingReport = false
    @State private var reportError: String?

    private var payments: [Payment] {
        trip.workPayments.sorted { $0.paidAt > $1.paidAt }
    }

    var body: some View {
        List {
            Section {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Total to claim").font(.caption).foregroundStyle(.secondary)
                        Text(trip.formattedTotal)
                            .font(.title.weight(.semibold))
                            .monospacedDigit()
                    }
                    Spacer()
                    if trip.missingReceiptCount > 0 {
                        VStack(alignment: .trailing, spacing: 2) {
                            Text("Missing receipts").font(.caption).foregroundStyle(.secondary)
                            Text("\(trip.missingReceiptCount)")
                                .font(.title.weight(.semibold))
                                .foregroundStyle(.orange)
                        }
                    }
                }
                if !trip.purpose.isEmpty {
                    LabeledContent("Purpose", value: trip.purpose)
                }
                if !trip.client.isEmpty {
                    LabeledContent("Client", value: trip.client)
                }
                if !trip.costCentre.isEmpty {
                    LabeledContent("Cost centre", value: trip.costCentre)
                }
                LabeledContent("Dates", value: trip.dateRangeText)
            }

            if !trip.totalsByCategory().isEmpty {
                Section("By category") {
                    ForEach(trip.totalsByCategory(), id: \.0) { category, amount in
                        LabeledContent {
                            Text(Money.string(amount, currency: trip.currency)).monospacedDigit()
                        } label: {
                            Label(category.title, systemImage: category.symbol)
                        }
                    }
                }
            }

            Section("Expenses") {
                if payments.isEmpty {
                    Text("Nothing filed here yet.").foregroundStyle(.secondary)
                }
                ForEach(payments) { payment in
                    NavigationLink(value: payment) {
                        PaymentRow(payment: payment, showStatus: true)
                    }
                }
            }

            Section {
                Button {
                    Task { await buildReport() }
                } label: {
                    if buildingReport {
                        HStack { ProgressView(); Text("Building the report…") }
                    } else {
                        Label("Export claim pack", systemImage: "square.and.arrow.up")
                    }
                }
                .disabled(payments.isEmpty || buildingReport)

                if let pack {
                    ShareLink(items: [pack.pdfURL, pack.csvURL]) {
                        Label("Share PDF and CSV", systemImage: "paperplane")
                    }
                }
            } footer: {
                Text("The pack has a summary, every line item, and a page per expense "
                     + "with the original bank message and the receipt.")
            }
        }
        .navigationTitle(trip.name)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button("Edit") { showEditor = true }
            }
        }
        .sheet(isPresented: $showEditor) { TripEditorView(trip: trip) }
        .navigationDestination(for: Payment.self) { PaymentDetailView(payment: $0) }
        .alert("Could not build the report",
               isPresented: Binding(get: { reportError != nil }, set: { if !$0 { reportError = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(reportError ?? "")
        }
    }

    private func buildReport() async {
        buildingReport = true
        defer { buildingReport = false }
        let subtitle = [trip.destination, trip.dateRangeText, trip.purpose]
            .filter { !$0.isEmpty }
            .joined(separator: " · ")
        do {
            pack = try ReportBuilder.build(title: trip.name, subtitle: subtitle, payments: payments)
        } catch {
            reportError = error.localizedDescription
        }
    }
}

struct TripEditorView: View {
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss

    var trip: Trip?

    @State private var name = ""
    @State private var destination = ""
    @State private var startDate = Date.now
    @State private var endDate = Date.now
    @State private var purpose = ""
    @State private var client = ""
    @State private var costCentre = ""
    @State private var loaded = false

    private var sweepCount: Int {
        guard trip == nil else { return 0 }
        return PaymentStore(context: context).sweepCandidates(start: startDate, end: endDate).count
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Name, e.g. Pune client visit", text: $name)
                    TextField("Destination", text: $destination)
                    DatePicker("Start", selection: $startDate, displayedComponents: .date)
                    DatePicker("End", selection: $endDate, in: startDate..., displayedComponents: .date)
                } footer: {
                    Text("Work payments made from the start date to the end date are filed here "
                         + "automatically. Nothing from before or after can be added.")
                }

                Section("For the claim") {
                    TextField("Purpose", text: $purpose)
                    TextField("Client", text: $client)
                    TextField("Cost centre", text: $costCentre)
                }

                if trip == nil && sweepCount > 0 {
                    Section {
                        Label("\(sweepCount) work expense\(sweepCount == 1 ? "" : "s") "
                              + "in these dates will be filed here",
                              systemImage: "tray.and.arrow.down")
                            .font(.callout)
                    }
                }
            }
            .navigationTitle(trip == nil ? "New trip" : "Edit trip")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save", action: save)
                        .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
            .onAppear(perform: load)
        }
    }

    private func load() {
        guard let trip, !loaded else { return }
        name = trip.name
        destination = trip.destination
        startDate = trip.startDate
        endDate = trip.endDate
        purpose = trip.purpose
        client = trip.client
        costCentre = trip.costCentre
        loaded = true
    }

    private func save() {
        let store = PaymentStore(context: context)
        if let trip {
            trip.name = name
            trip.destination = destination
            trip.startDate = startDate
            trip.endDate = endDate
            trip.purpose = purpose
            trip.client = client
            trip.costCentre = costCentre
            try? context.save()
            store.unfileOutsideTrips()
            store.sweepIntoTrip(trip)
        } else {
            let new = Trip(name: name, destination: destination, startDate: startDate,
                           endDate: endDate, purpose: purpose, client: client,
                           costCentre: costCentre)
            context.insert(new)
            try? context.save()
            store.sweepIntoTrip(new)
        }
        dismiss()
    }
}
