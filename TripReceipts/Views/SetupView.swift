import SwiftUI
import SwiftData
import UserNotifications

/// The one-time manual setup. iOS gives apps no way to install a personal
/// automation, so this screen's job is to make the five of them quick to
/// create and easy to test.
struct SetupView: View {
    @Environment(\.modelContext) private var context

    @State private var notificationsOn = false
    @State private var testResult: String?
    @State private var showAllSamples = false
    @State private var syncForm = GitHubSync.shared.settings
    @State private var syncToken = ""
    @AppStorage(InvoiceParseClient.serverKey) private var parserServer = ""
    @State private var parserStatus: (ok: Bool, text: String)?
    @State private var checkingParser = false
    @FocusState private var editingParser: Bool

    /// One automation per keyword — between them they catch the wording every
    /// Indian bank uses for an outgoing payment.
    private let keywords = ["debited", "spent", "sent", "paid", "withdrawn"]

    var body: some View {
        NavigationStack {
            List {
                notificationSection
                automationSection
                testSection
                parserSection
                websiteSection
                privacySection
                aboutSection
            }
            .navigationTitle("Setup")
            .scrollDismissesKeyboard(.interactively)
            .task { await refreshNotificationStatus() }
        }
    }

    private var notificationSection: some View {
        Section {
            HStack {
                Label("Notifications", systemImage: notificationsOn ? "bell.fill" : "bell.slash")
                Spacer()
                if notificationsOn {
                    Text("On").foregroundStyle(.green)
                } else {
                    Button("Turn on") {
                        Task {
                            await NotificationManager.requestAuthorization()
                            await refreshNotificationStatus()
                        }
                    }
                }
            }
        } footer: {
            Text("The question arrives as a notification you can answer from the lock screen. "
                 + "Without it, payments still land in the Inbox but nothing prompts you.")
        }
    }

    private var automationSection: some View {
        Section {
            ForEach(Array(keywords.enumerated()), id: \.offset) { index, keyword in
                HStack {
                    Text("\(index + 1)")
                        .font(.caption.weight(.semibold))
                        .frame(width: 20, height: 20)
                        .background(.tint.opacity(0.15), in: .circle)
                    Text("Message contains ")
                        + Text("\u{201C}\(keyword)\u{201D}").bold()
                }
                .font(.callout)
            }

            Link(destination: URL(string: "shortcuts://")!) {
                Label("Open Shortcuts", systemImage: "arrow.up.forward.app")
            }
        } header: {
            Text("Shortcuts automations")
        } footer: {
            VStack(alignment: .leading, spacing: 8) {
                Text("Create one personal automation per keyword, each the same shape:")
                Text("""
                1. Shortcuts → Automation → New → Message
                2. Message Contains → the keyword above. Leave the sender empty.
                3. Run Immediately, and turn Notify When Run off.
                4. Add action → Trip Receipts → Check Payment Message
                5. Set Message to Shortcut Input, then Done.
                """)
                Text("A message caught by two automations is recognised as the same payment "
                     + "and only asked about once.")
            }
            .font(.caption)
        }
    }

    private var testSection: some View {
        Section {
            Button {
                Task { await sendTestPayment() }
            } label: {
                Label("Send a test payment", systemImage: "paperplane")
            }

            Button {
                showAllSamples = true
            } label: {
                Label("Check the parser on sample messages", systemImage: "checklist")
            }

            if let testResult {
                Text(testResult)
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        } header: {
            Text("Check it works")
        } footer: {
            Text("The test runs the same path a real SMS takes: parse, store, ask. "
                 + "Lock the phone first to answer it from the lock screen.")
        }
        .sheet(isPresented: $showAllSamples) { ParserSampleView() }
    }

    private var parserSection: some View {
        Section {
            VStack(alignment: .leading, spacing: 6) {
                Text("Parser server address")
                    .font(.subheadline.weight(.medium))
                TextField("e.g. 192.168.1.20:8787", text: $parserServer)
                    .textFieldStyle(.roundedBorder)
                    .keyboardType(.URL)
                    .textContentType(.URL)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .submitLabel(.done)
                    .onSubmit { Task { await checkParser() } }
                    .onChange(of: parserServer) { _, _ in parserStatus = nil }
                    .focused($editingParser)
                    .accessibilityIdentifier("parserServerField")
            }
            .padding(.vertical, 4)

            Button {
                Task { await checkParser() }
            } label: {
                if checkingParser {
                    HStack(spacing: 8) { ProgressView(); Text("Checking…") }
                } else {
                    Label("Check connection", systemImage: "antenna.radiowaves.left.and.right")
                }
            }
            .disabled(InvoiceParseClient.serverURL(from: parserServer) == nil || checkingParser)
            .accessibilityIdentifier("checkParserButton")

            if !parserServer.trimmingCharacters(in: .whitespaces).isEmpty
                && InvoiceParseClient.serverURL(from: parserServer) == nil {
                Label("That isn't an address the app can use — try 192.168.1.20:8787 "
                      + "or https://parser.example.com", systemImage: "exclamationmark.triangle.fill")
                    .font(.callout)
                    .foregroundStyle(.orange)
                    .accessibilityIdentifier("parserAddressHint")
            }

            if let parserStatus {
                Label(parserStatus.text,
                      systemImage: parserStatus.ok ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                    .font(.callout)
                    .foregroundStyle(parserStatus.ok ? .green : .orange)
                    .accessibilityIdentifier("parserStatus")
            }
        } header: {
            Text("Receipt check")
        } footer: {
            Text("Each receipt you attach is sent to this server, which reads its total, date and "
                 + "merchant so they can be checked against the payment. The server reads the file "
                 + "in memory and keeps nothing. With no server, or one that takes over 10 seconds, "
                 + "this iPhone reads the total itself and the receipt is marked Unverified.")
        }
    }

    private var websiteSection: some View {
        let sync = GitHubSync.shared
        return Section {
            Toggle(isOn: $syncForm.enabled) {
                Label("Sync to the website", systemImage: "arrow.triangle.2.circlepath")
            }
            .onChange(of: syncForm.enabled) { _, _ in
                // On and off take effect at once; field edits wait for Save.
                sync.configure(syncForm, token: nil)
                sync.scheduleSync()
            }

            if syncForm.enabled {
                LabeledContent("Owner") {
                    TextField("GitHub user", text: $syncForm.owner)
                        .multilineTextAlignment(.trailing)
                }
                LabeledContent("Private repo") {
                    TextField("trip-receipts-data", text: $syncForm.repo)
                        .multilineTextAlignment(.trailing)
                }
                LabeledContent("Token") {
                    SecureField(sync.hasToken ? "Saved · paste to replace" : "github_pat_…", text: $syncToken)
                        .multilineTextAlignment(.trailing)
                }
                LabeledContent("Shared repo") {
                    TextField("optional · work only", text: $syncForm.shareRepo)
                        .multilineTextAlignment(.trailing)
                }

                Button {
                    sync.configure(syncForm, token: syncToken)
                    syncToken = ""
                    Task { await sync.syncNow(force: true) }
                } label: {
                    Label("Save and sync now", systemImage: "icloud.and.arrow.up")
                }
                .disabled(syncForm.owner.isEmpty || syncForm.repo.isEmpty || (!sync.hasToken && syncToken.isEmpty))

                syncStatus

                if sync.isActive {
                    Link(destination: sync.websiteLink) {
                        Label("Open the website", systemImage: "safari")
                    }
                }

                if sync.isActive && sync.settings.isSharing {
                    if let error = sync.shareError {
                        Label("Shared repo: \(error)", systemImage: "exclamationmark.triangle.fill")
                            .font(.callout)
                            .foregroundStyle(.orange)
                    }
                    ShareLink(item: sync.shareWebsiteLink,
                              message: Text("My work-travel expenses, live. Paste the read-only token I send separately.")) {
                        Label("Send the work-only link", systemImage: "square.and.arrow.up")
                    }
                }
            }
        } header: {
            Text("Website")
        } footer: {
            Text("After every change, all payments and trips are written to transactions.json in "
                 + "a private GitHub repo, and the website reads them from there. Receipt images "
                 + "stay on this iPhone. Use a fine-grained token that can see only that repo, "
                 + "with Contents set to Read and write.\n\n"
                 + "A shared repo gets only work expenses and trips, with their bank messages — "
                 + "never waiting or personal payments. Give the same token access to it, and the "
                 + "reader their own read-only token for that repo alone.")
        }
        .textInputAutocapitalization(.never)
        .autocorrectionDisabled()
    }

    @ViewBuilder
    private var syncStatus: some View {
        let sync = GitHubSync.shared
        if sync.isSyncing {
            HStack(spacing: 8) {
                ProgressView()
                Text("Syncing…").foregroundStyle(.secondary)
            }
            .font(.callout)
        } else if let error = sync.lastError {
            Label(error, systemImage: "exclamationmark.triangle.fill")
                .font(.callout)
                .foregroundStyle(.orange)
        } else if let last = sync.lastSyncedAt {
            Label {
                Text("Synced \(last, style: .relative) ago")
            } icon: {
                Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
            }
            .font(.callout)
        }
    }

    private var privacySection: some View {
        let sync = GitHubSync.shared
        let parserHost = InvoiceParseClient.serverURL(from: parserServer)?.host
        let uploads = sync.isActive || parserHost != nil
        return Section("Privacy") {
            if uploads {
                Label("Payment messages are parsed on this iPhone", systemImage: "iphone")
                if sync.isActive {
                    Label("Payments and trips sync to your private repo \(sync.settings.fullName)",
                          systemImage: "arrow.triangle.2.circlepath")
                    if sync.settings.isSharing {
                        Label("Work expenses only are copied to \(sync.settings.shareFullName)",
                              systemImage: "person.2")
                    }
                }
                if let parserHost {
                    Label("Receipts you attach are read by \(parserHost), which keeps nothing",
                          systemImage: "doc.text.magnifyingglass")
                } else {
                    Label("Receipt images never leave the phone", systemImage: "photo")
                }
            } else {
                Label("Everything stays on this iPhone", systemImage: "iphone")
                Label("No account, no server, no upload", systemImage: "wifi.slash")
            }
            Label("Only messages that parse as payments are saved", systemImage: "line.3.horizontal.decrease")
            Label("Personal payments are deleted after 30 days", systemImage: "trash")
            if !uploads {
                Label("Data leaves only when you share an export", systemImage: "square.and.arrow.up")
            }
        }
    }

    private var aboutSection: some View {
        Section {
            LabeledContent("Version", value: Self.version)
        } footer: {
            Text("Trip Receipts catches work-travel payments as they happen, so a claim "
                 + "is an export rather than an archaeology project.")
        }
    }

    /// "1.0 (2)" — the build number tells which install is actually running.
    private static var version: String {
        let info = Bundle.main.infoDictionary
        let version = info?["CFBundleShortVersionString"] as? String ?? "?"
        let build = info?["CFBundleVersion"] as? String ?? "?"
        return "\(version) (\(build))"
    }

    // MARK: - Actions

    private func checkParser() async {
        editingParser = false  // so the result isn't hidden under the keyboard
        guard let client = InvoiceParseClient.configured() else {
            parserStatus = (false, "Enter the parser's address first.")
            return
        }
        parserStatus = nil
        checkingParser = true
        defer { checkingParser = false }
        do {
            parserStatus = (true, "Connected · \(try await client.check())")
        } catch {
            parserStatus = (false, error.localizedDescription)
        }
    }

    private func refreshNotificationStatus() async {
        let status = await NotificationManager.authorizationStatus()
        notificationsOn = status == .authorized || status == .provisional
    }

    /// Uses a real-shaped message so the test exercises the parser too.
    private func sendTestPayment() async {
        let store = PaymentStore(context: context)
        let amount = Int.random(in: 120...1800)
        let reference = String(Int.random(in: 100_000_000_000...999_999_999_999))
        let message = "Sent Rs.\(amount).00 From HDFC Bank A/C x1234 To UBER INDIA "
            + "On \(testDateString()) Ref \(reference) Not You? Call 18002586161"

        switch store.intake(message: message, sender: "AD-HDFCBK") {
        case .created(let payment):
            let hint = NotificationManager.hint(for: payment, store: store)
            await NotificationManager.askAbout(payment, hint: hint)
            await NotificationManager.updatePendingReminder(count: store.pendingCount())
            testResult = "Asked about \(payment.formattedAmount) to \(payment.merchant)."
        case .duplicate:
            testResult = "That test payment is already in the inbox."
        case .refunded:
            testResult = "Matched as a refund."
        case .ignored(let reason):
            testResult = "Not stored: \(reason.rawValue)"
        }
    }

    private func testDateString() -> String {
        let f = DateFormatter()
        f.dateFormat = "dd/MM/yy"
        return f.string(from: .now)
    }
}

/// Runs the parser over a set of real-shaped messages and shows what it made
/// of each — the quickest way to see whether a bank's new wording still works.
struct ParserSampleView: View {
    @Environment(\.dismiss) private var dismiss

    private let samples: [(String, String)] = [
        ("AD-HDFCBK", "Sent Rs.486.00 From HDFC Bank A/C x1234 To UBER INDIA On 12/10/25 Ref 528512345678"),
        ("AD-ICICIB", "ICICI Bank Acct XX678 debited for Rs 1250.00 on 11-Oct-25; MAKEMYTRIP credited. UPI:528498765432."),
        ("AX-AxisBk", "INR 240.00 debited from A/c no. XX9012 on 12-10-25. Info: UPI/P2M/528512349999/RAPIDO. Avl Bal INR 15,320.44"),
        ("AD-SBIUPI", "Dear UPI user A/C X3456 debited by 150.0 on date 12Oct25 trf to IRCTC Refno 528587654321"),
        ("AD-HDFCBK", "Spent Rs.4520.00 On HDFC Bank Card 4455 At INDIGO AIRLINES On 2025-10-10. Avl Lmt INR 95,480."),
        ("AD-HDFCBK", "123456 is the OTP for your transaction of Rs.4520.00 at INDIGO. Do not share with anyone.")
    ]

    var body: some View {
        NavigationStack {
            List {
                ForEach(Array(samples.enumerated()), id: \.offset) { _, sample in
                    VStack(alignment: .leading, spacing: 6) {
                        Text(sample.1)
                            .font(.system(.caption2, design: .monospaced))
                            .foregroundStyle(.secondary)
                        result(for: sample)
                    }
                    .padding(.vertical, 2)
                }
            }
            .navigationTitle("Parser check")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            }
        }
    }

    @ViewBuilder
    private func result(for sample: (String, String)) -> some View {
        switch SMSParser.parse(sample.1, sender: sample.0) {
        case .payment(let parsed):
            Label(
                "\(Money.string(parsed.amount, currency: parsed.currency)) · \(parsed.merchant)"
                + (parsed.instrument.isEmpty ? "" : " · \(parsed.instrument)"),
                systemImage: "checkmark.circle.fill"
            )
            .font(.caption)
            .foregroundStyle(.green)
        case .ignored(let reason):
            Label("Ignored — \(reason.rawValue)", systemImage: "minus.circle")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}
