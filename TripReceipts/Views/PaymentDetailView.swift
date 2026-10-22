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
    @State private var addAnywayFor: ReceiptVerification?
    /// The receipt "Fix the receipt" will replace — removed only once the
    /// new one is attached, so a cancelled picker loses nothing.
    @State private var replacing: ReceiptFile?
    @State private var showFixOptions = false
    @State private var showPhotoPicker = false

    private var store: PaymentStore { PaymentStore(context: context) }

    var body: some View {
        Form {
            amountSection
            verificationSection
            detailsSection
            receiptsSection
            if !payment.isManual || payment.verification != nil { proofSection }
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
        // A corrected payee or date may settle — or raise — a receipt warning.
        .onChange(of: payment.merchant) { _, _ in payment.reverifyReceipts() }
        .onChange(of: payment.paidAt) { _, _ in payment.reverifyReceipts() }
        .sheet(isPresented: $showScanner, onDismiss: { replacing = nil }) {
            DocumentScannerView { images in
                let old = takeReplacing()
                Task { await attach(images: images, replacing: old) }
            }
            .ignoresSafeArea()
        }
        .fileImporter(isPresented: $showFileImporter,
                      allowedContentTypes: [.pdf, .image],
                      allowsMultipleSelection: true) { result in
            let old = takeReplacing()
            Task { await attach(files: result, replacing: old) }
        }
        .photosPicker(isPresented: $showPhotoPicker, selection: $photoItem, matching: .images)
        .onChange(of: showPhotoPicker) { _, shown in
            if !shown && photoItem == nil { replacing = nil }
        }
        .onChange(of: photoItem) { _, item in
            guard let item else { return }
            let old = takeReplacing()
            Task {
                if let data = try? await item.loadTransferable(type: Data.self) {
                    await attach(data: data, isPDF: false, filename: "photo.jpg", replacing: old)
                }
                photoItem = nil
            }
        }
        .confirmationDialog("Replace the receipt", isPresented: $showFixOptions, titleVisibility: .visible) {
            Button("Scan a bill") { showScanner = true }
            Button("Choose from Photos") { showPhotoPicker = true }
            Button("Choose a file") { showFileImporter = true }
            Button("Cancel", role: .cancel) { replacing = nil }
        } message: {
            Text("The receipt that doesn't match is removed once the new one is attached.")
        }
        .onChange(of: showFixOptions) { _, shown in
            // Dismissed without choosing: nothing will be replaced.
            if !shown && !showScanner && !showPhotoPicker && !showFileImporter { replacing = nil }
        }
        .sheet(item: $addAnywayFor) { verification in
            AddAnywaySheet(
                result: verification.result(for: payment),
                tripName: (payment.trip ?? store.tripCovering(payment.paidAt))?.name
            ) { note in
                let wasPending = payment.status == .pending
                store.addAnyway(verification, note: note, payment: payment)
                if wasPending { refreshPendingReminder() }
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

    /// The warning, top of the page, when the receipt that speaks for this
    /// payment doesn't match it.
    @ViewBuilder
    private var verificationSection: some View {
        if let verification = payment.verification, verification.status == .warning {
            let open = !verification.overriddenByUser
            Section {
                VerificationBanner(
                    verification: verification,
                    result: verification.result(for: payment),
                    currency: payment.currency,
                    onFix: open ? { fix(verification) } : nil,
                    onAddAnyway: open ? { addAnywayFor = verification } : nil
                )
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
                    Text("Reading and checking the receipt…").foregroundStyle(.secondary)
                }
            }

            Button {
                replacing = nil
                showScanner = true
            } label: {
                Label("Scan a bill", systemImage: "doc.viewfinder")
            }

            PhotosPicker(selection: $photoItem, matching: .images) {
                Label("Choose from Photos", systemImage: "photo.on.rectangle")
            }

            Button {
                replacing = nil
                showFileImporter = true
            } label: {
                Label("Attach a PDF invoice", systemImage: "doc")
            }
        } header: {
            Text("Receipts")
        } footer: {
            Text("Each receipt is checked against the payment's amount, date and payee. "
                 + "Attaching one to a waiting payment files it as work travel — unless it "
                 + "doesn't match, and then you choose.")
        }
    }

    private var proofSection: some View {
        Section {
            DisclosureGroup(isExpanded: $showProof) {
                VStack(alignment: .leading, spacing: 8) {
                    if !payment.isManual {
                        messageProof
                    }
                    ForEach(payment.receipts.sorted(by: { $0.addedAt < $1.addedAt })) { receipt in
                        if let verification = receipt.verification {
                            Divider()
                            ReceiptCheckDetails(verification: verification, payment: payment)
                        }
                    }
                }
                .padding(.vertical, 4)
            } label: {
                Label("Proof of payment", systemImage: "checkmark.seal")
            }
        } footer: {
            Text(payment.isManual
                 ? "What the parser read off each receipt, and how it compared with the payment."
                 : "The original bank message, kept exactly as it arrived, with a SHA-256 "
                   + "fingerprint taken the moment it was captured — and what each receipt says.")
        }
    }

    @ViewBuilder
    private var messageProof: some View {
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

    private func attach(images: [UIImage], replacing old: ReceiptFile?) async {
        for (index, image) in images.enumerated() {
            guard let data = image.jpegData(compressionQuality: 0.8) else { continue }
            await attach(data: data, isPDF: false, filename: "scan.jpg", replacing: index == 0 ? old : nil)
        }
    }

    private func attach(files result: Result<[URL], Error>, replacing old: ReceiptFile?) async {
        guard case .success(let urls) = result else { return }
        for (index, url) in urls.enumerated() {
            guard url.startAccessingSecurityScopedResource() else { continue }
            defer { url.stopAccessingSecurityScopedResource() }
            guard let data = try? Data(contentsOf: url) else { continue }
            await attach(data: data,
                         isPDF: url.pathExtension.lowercased() == "pdf",
                         filename: url.lastPathComponent,
                         replacing: index == 0 ? old : nil)
        }
    }

    private func attach(data: Data, isPDF: Bool, filename: String, replacing old: ReceiptFile? = nil) async {
        isReadingReceipt = true
        defer { isReadingReceipt = false }

        let check = await ReceiptCheck.run(data: data, isPDF: isPDF, filename: filename, for: .init(payment))
        if let old { context.delete(old) }

        // A receipt is itself an answer to the question — unless it doesn't
        // match, and then the banner asks.
        let wasPending = payment.status == .pending
        store.attachReceipt(data, isPDF: isPDF, filename: filename, check: check, to: payment)
        if wasPending && payment.status != .pending { refreshPendingReminder() }
    }

    /// "Fix the receipt": choose the replacement; the old one goes when it lands.
    private func fix(_ verification: ReceiptVerification) {
        replacing = verification.receipt
        showFixOptions = true
    }

    /// Hands the pending replacement to one attach, so no later one takes it.
    private func takeReplacing() -> ReceiptFile? {
        defer { replacing = nil }
        return replacing
    }

    private func refreshPendingReminder() {
        let count = store.pendingCount()
        Task { await NotificationManager.updatePendingReminder(count: count) }
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
