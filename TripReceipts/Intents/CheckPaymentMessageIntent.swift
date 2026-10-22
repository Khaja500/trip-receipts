import AppIntents
import SwiftData
import Foundation

/// The entry point for every SMS. A Shortcuts personal automation passes the
/// message text here; this runs in the background with no UI, parses it, and
/// asks the question only if it is a payment worth asking about.
struct CheckPaymentMessageIntent: AppIntent {
    static var title: LocalizedStringResource = "Check Payment Message"
    static var description = IntentDescription(
        """
        Reads a bank SMS, and if it is an outgoing payment, asks whether it was \
        for work travel. Nothing leaves your phone unless website sync is \
        turned on in Setup.
        """,
        categoryName: "Travel expenses"
    )

    /// Runs silently — the whole point is that no tap is needed.
    static var openAppWhenRun: Bool = false

    @Parameter(title: "Message")
    var message: String

    @Parameter(title: "Sender", default: "")
    var sender: String

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<String> {
        // The same container the app uses. The intent runs inside the app's
        // process, so a second container over the same store would leave the
        // open Inbox unaware of the payment and put two coordinators on one file.
        let context = ModelContext(ModelContainer.shared)
        let store = PaymentStore(context: context)

        let result = store.intake(message: message, sender: sender, receivedAt: .now)

        switch result {
        case .created(let payment):
            let hint = NotificationManager.hint(for: payment, store: store)
            await NotificationManager.askAbout(payment, hint: hint)
            await NotificationManager.updatePendingReminder(count: store.pendingCount())
            await GitHubSync.shared.syncNow()
            return .result(value: "Asked about \(payment.formattedAmount) to \(payment.merchant)")

        case .duplicate(let payment):
            // Already asked. The extra message was kept as more proof.
            await GitHubSync.shared.syncNow()
            return .result(value: "Already seen: \(payment.formattedAmount) to \(payment.merchant)")

        case .refunded(let payment, let amount):
            await NotificationManager.confirmRefund(on: payment, amount: amount)
            await GitHubSync.shared.syncNow()
            return .result(value: "Refund of \(Money.string(amount, currency: payment.currency)) matched")

        case .ignored(let reason):
            return .result(value: "Not a payment: \(reason.rawValue)")
        }
    }
}

/// Makes the action findable by voice and in the Shortcuts gallery. The
/// automation itself still has to be created by hand — iOS gives apps no way
/// to install one.
struct TripReceiptsShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: CheckPaymentMessageIntent(),
            phrases: [
                "Check payment message in \(.applicationName)",
                "Log a payment in \(.applicationName)"
            ],
            shortTitle: "Check Payment Message",
            systemImageName: "tray.and.arrow.down"
        )
    }
}
