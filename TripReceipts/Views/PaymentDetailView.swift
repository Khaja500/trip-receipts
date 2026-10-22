import SwiftUI
import SwiftData
import PhotosUI
import UniformTypeIdentifiers

struct PaymentDetailView: View {
    @Environment(\.modelContext) private var context
    @Environment(Router.self) private var router
    @Bindable var payment: Payment

    @Query(sort: \Trip.startDate, order: .reverse) private var trips: [Trip]

    @State private var showScanner = false
    @State private var showFileImporter = false
    @State private var photoItem: PhotosPickerItem?
    @State private var isReadingReceipt = false
    @State private var claimText = ""
    @State private var showProof = false

    private var store: PaymentStore { PaymentStore(context: context) }

    var body: some View {
        Form {
            amountSection
            detailsSection
            receiptsSection
            if !payment.isManual { proofSection }
            notesSection
            if payment.status != .pending { moveSection }
        }
        .navigationTitle(payment.merchant)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if payment.status == .pending {
                ToolbarItem(placement: .bottomBar) { triageBar }
            }
        }
        .onAppear {
            claimText = String(format: "%.2f", payment.claimableAmount)
            if router.openReceiptPicker {
                router.openReceiptPicker = false
                showScanner = true
            }
        }
        .onDisappear { router.clear() }
        .sheet(isPresented: $showScanner) {
            DocumentScannerView { images in
                Task { await attach(images: images) }
            }
            .ignoresSafeArea()
        }
        .fileImporter(isPresented: $showFileImporter,
                      allowedContentTypes: [.pdf, .image],
                      allowsMultipleSelection: true) { result in
            Task { await attach(files: result) }
        }
        .onChange(of: photoItem) { _, item in
            guard let item else { return }
            Task {
                if let data = try? await item.loadTransferable(type: Data.self) {
                    await attach(data: data, isPDF: false, filename: "photo.jpg")
                }
                photoItem = nil
            }
        }
    }

    // MARK: - Sections

    private var amountSection: some View {
        Section {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(payment.formattedAmount)
                        .font(.largeTitle.weight(.semibold))
                        .monospacedDigit()
                    if payment.refundedAmount > 0 {
                        Text("Refunded \(Money.string(payment.refundedAmount, currency: payment.currency))"
                             + " · claiming \(payment.formattedNetClaimable)")
                            .font(.caption)
                            .foregroundStyle(.orange)
                    }
                }
                Spacer()
                statusBadge
            }
            .padding(.vertical, 4)

            if payment.parseConfidence < 0.6 && !payment.isManual {
                Label("Some details were hard to read from the message. Check them below.",
                      systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
        }
    }

    @ViewBuilder
    private var statusBadge: some View {
        switch payment.status {
        case .pending:
            Text("Waiting").badgeStyle(.gray)
        case .work:
            Text("Work travel").badgeStyle(.green)
        case .personal:
            Text("Personal").badgeStyle(.secondary)
        }
    }

    private var detailsSection: some View {
        Section("Details") {
            LabeledContent("Payee") {
                TextField("Payee", text: $payment.merchant)
                    .multilineTextAlignment(.trailing)
            }

            Picker("Category", selection: Binding(
                get: { payment.category },
                set: { payment.category = $0 }
            )) {
                ForEach(ExpenseCategory.allCases) { category in
                    Label(category.title, systemImage: category.symbol).tag(category)
                }
            }

            DatePicker("Date", selection: $payment.paidAt, displayedComponents: [.date, .hourAndMinute])

            Picker("Trip", selection: Binding(
                get: { payment.trip },
                set: { payment.trip = $0 }
            )) {
                Text("Not in a trip").tag(Trip?.none)
                ForEach(trips) { trip in
                    Text(trip.name).tag(Trip?.some(trip))
                }
            }

            LabeledContent("Amount to claim") {
                HStack(spacing: 4) {
                    TextField("Amount", text: $claimText)
                        .keyboardType(.decimalPad)
                        .multilineTextAlignment(.trailing)
                        .onChange(of: claimText) { _, text in
                            if let value = Double(text.replacingOccurrences(of: ",", with: "")) {
                                payment.claimableAmount = min(value, payment.amount)
                            }
                        }
                    Text(payment.currency).foregroundStyle(.secondary)
                }
            }

            if !payment.instrument.isEmpty {
                LabeledContent("Paid by", value: payment.instrument)
            }
            if let bank = payment.bank {
                LabeledContent("Bank", value: bank)
            }
            if let reference = payment.reference {
                LabeledContent("Reference", value: reference)
                    .font(.callout)
            }
        }
    }

    private var receiptsSection: some View {
        Section {
            if payment.receipts.isEmpty && !isReadingReceipt {
                Text("No receipt yet. The claim is stronger with the bill attached.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            ForEach(payment.receipts.sorted(by: { $0.addedAt < $1.addedAt })) { receipt in
                ReceiptRow(receipt: receipt, payment: payment)
            }
            .onDelete(perform: deleteReceipts)

            if isReadingReceipt {
                HStack {
                    ProgressView()
                    Text("Reading the receipt…").foregroundStyle(.secondary)
                }
            }

            Button {
                showScanner = true
            } label: {
                Label("Scan a bill", systemImage: "doc.viewfinder")
            }

            PhotosPicker(selection: $photoItem, matching: .images) {
                Label("Choose from Photos", systemImage: "photo.on.rectangle")
            }

            Button {
                showFileImporter = true
            } label: {
                Label("Attach a PDF invoice", systemImage: "doc")
            }
        } header: {
            Text("Receipts")
        } footer: {
            Text("Attaching a receipt to a waiting payment files it as work travel.")
        }
    }

    private var proofSection: some View {
        Section {
            DisclosureGroup(isExpanded: $showProof) {
                VStack(alignment: .leading, spacing: 8) {
                    Text(payment.rawMessage)
                        .font(.system(.footnote, design: .monospaced))
                        .textSelection(.enabled)
                        .padding(10)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(.quaternary.opacity(0.4), in: .rect(cornerRadius: 8))

                    Text("From \(payment.sender) · "
                         + payment.receivedAt.formatted(date: .abbreviated, time: .shortened))
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    ForEach(payment.additionalMessages, id: \.fingerprint) { extra in
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Also received from \(extra.sender)")
                                .font(.caption.weight(.medium))
                            Text(extra.text)
                                .font(.system(.caption2, design: .monospaced))
                                .padding(8)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .background(.quaternary.opacity(0.3), in: .rect(cornerRadius: 6))
                        }
                    }

                    Divider()

                    let intact = payment.proofIsIntact
                    Label {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(intact ? "Message is unchanged since capture"
                                        : "Message no longer matches its fingerprint")
                                .font(.caption.weight(.medium))
                            Text(ProofHasher.short(payment.messageHash))
                                .font(.system(.caption2, design: .monospaced))
                                .foregroundStyle(.secondary)
                        }
                    } icon: {
                        Image(systemName: intact ? "checkmark.seal.fill" : "exclamationmark.triangle.fill")
                            .foregroundStyle(intact ? .green : .red)
                    }
                }
                .padding(.vertical, 4)
            } label: {
                Label("Proof of payment", systemImage: "checkmark.seal")
            }
        } footer: {
            Text("The original bank message, kept exactly as it arrived, with a "
                 + "SHA-256 fingerprint taken the moment it was captured.")
        }
    }

    private var notesSection: some View {
        Section("Notes") {
            TextField("What was this for?", text: $payment.notes, axis: .vertical)
                .lineLimit(2...6)
        }
    }

    private var moveSection: some View {
        Section {
            Button {
                store.moveToInbox(payment)
            } label: {
                Label("Move back to inbox", systemImage: "arrow.uturn.backward")
            }
            if payment.status == .work {
                Button(role: .destructive) {
                    store.markPersonal(payment)
                } label: {
                    Label("This was personal", systemImage: "person")
                }
            }
        }
    }

    private var triageBar: some View {
        HStack {
            Button {
                store.markPersonal(payment)
            } label: {
                Label("Personal", systemImage: "person")
            }
            .buttonStyle(.bordered)

            Spacer()

            Button {
                store.markWork(payment)
            } label: {
                Label("Work travel", systemImage: "suitcase.fill")
            }
            .buttonStyle(.borderedProminent)
        }
    }

    // MARK: - Receipts

    private func attach(images: [UIImage]) async {
        for image in images {
            guard let data = image.jpegData(compressionQuality: 0.8) else { continue }
            await attach(data: data, isPDF: false, filename: "scan.jpg")
        }
    }

    private func attach(files result: Result<[URL], Error>) async {
        guard case .success(let urls) = result else { return }
        for url in urls {
            guard url.startAccessingSecurityScopedResource() else { continue }
            defer { url.stopAccessingSecurityScopedResource() }
            guard let data = try? Data(contentsOf: url) else { continue }
            await attach(data: data,
                         isPDF: url.pathExtension.lowercased() == "pdf",
                         filename: url.lastPathComponent)
        }
    }

    private func attach(data: Data, isPDF: Bool, filename: String) async {
        isReadingReceipt = true
        defer { isReadingReceipt = false }

        let reading = await ReceiptOCR.read(data: data, isPDF: isPDF)
        let receipt = ReceiptFile(data: data, isPDF: isPDF, filename: filename,
                                  ocrText: reading.text, ocrTotal: reading.total)
        receipt.payment = payment
        context.insert(receipt)

        // A receipt is itself an answer to the question.
        if payment.status == .pending {
            store.markWork(payment)
            let count = store.pendingCount()
            Task { await NotificationManager.updatePendingReminder(count: count) }
        } else {
            try? context.save()
        }
    }

    private func deleteReceipts(at offsets: IndexSet) {
        let sorted = payment.receipts.sorted(by: { $0.addedAt < $1.addedAt })
        for index in offsets {
            context.delete(sorted[index])
        }
        try? context.save()
    }
}

private extension View {
    func badgeStyle(_ color: Color) -> some View {
        font(.caption.weight(.medium))
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(color.opacity(0.15), in: .capsule)
            .foregroundStyle(color == .secondary ? Color.secondary : color)
    }
}
