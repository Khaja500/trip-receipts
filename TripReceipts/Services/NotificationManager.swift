import Foundation
import UserNotifications
import SwiftData

/// The question — "was this for work travel?" — and the two follow-ups: the
/// nudge to attach a receipt, and the 9 pm reminder for anything still waiting.
enum NotificationManager {

    enum Category {
        static let question = "PAYMENT_QUESTION"
        static let receiptNudge = "RECEIPT_NUDGE"
        static let reminder = "PENDING_REMINDER"
    }

    enum Action {
        static let work = "MARK_WORK"
        static let workWithReceipt = "MARK_WORK_RECEIPT"
        static let personal = "MARK_PERSONAL"
        static let addReceipt = "ADD_RECEIPT"
    }

    enum UserInfoKey {
        static let paymentID = "paymentID"
    }

    private static let reminderID = "pending-reminder-9pm"

    // MARK: - Setup

    static func registerCategories() {
        let question = UNNotificationCategory(
            identifier: Category.question,
            actions: [
                UNNotificationAction(identifier: Action.work,
                                     title: "Yes, work travel",
                                     options: []),
                UNNotificationAction(identifier: Action.workWithReceipt,
                                     title: "Work – add receipt now",
                                     options: [.foreground]),
                UNNotificationAction(identifier: Action.personal,
                                     title: "Personal",
                                     options: [.destructive])
            ],
            intentIdentifiers: [],
            options: []
        )
        let nudge = UNNotificationCategory(
            identifier: Category.receiptNudge,
            actions: [
                UNNotificationAction(identifier: Action.addReceipt,
                                     title: "Add receipt",
                                     options: [.foreground])
            ],
            intentIdentifiers: [],
            options: []
        )
        let reminder = UNNotificationCategory(
            identifier: Category.reminder, actions: [], intentIdentifiers: [], options: []
        )
        UNUserNotificationCenter.current()
            .setNotificationCategories([question, nudge, reminder])
    }

    @discardableResult
    static func requestAuthorization() async -> Bool {
        (try? await UNUserNotificationCenter.current()
            .requestAuthorization(options: [.alert, .sound, .badge])) ?? false
    }

    static func authorizationStatus() async -> UNAuthorizationStatus {
        await UNUserNotificationCenter.current().notificationSettings().authorizationStatus
    }

    // MARK: - The question

    /// Fires straight away, so the question lands while the payment is still
    /// in mind. Answerable from the lock screen.
    static func askAbout(_ payment: Payment, hint: String?) async {
        let content = UNMutableNotificationContent()
        content.title = "\(payment.formattedAmount) paid to \(payment.merchant)"
        content.body = "Was this for work travel?"
        if let hint, !hint.isEmpty { content.subtitle = hint }
        content.categoryIdentifier = Category.question
        content.userInfo = [UserInfoKey.paymentID: payment.uid]
        content.sound = .default
        content.interruptionLevel = .timeSensitive
        content.threadIdentifier = "payments"

        await add(content, identifier: "ask-\(payment.uid)", trigger: nil)
    }

    /// The line under the question explaining why it might be work.
    static func hint(for payment: Payment, store: PaymentStore) -> String {
        var parts: [String] = []
        if payment.category != .other { parts.append(payment.category.title) }
        if let trip = store.tripCovering(payment.paidAt) {
            parts.append("during \(trip.name)")
        } else if store.payeeSeenAsWorkBefore(payment.merchant) {
            parts.append("marked work before")
        }
        if !payment.instrument.isEmpty { parts.append("Via \(payment.instrument)") }
        return parts.joined(separator: " · ")
    }

    /// After a lock-screen "yes", offer the receipt without making it a chore.
    static func nudgeForReceipt(_ payment: Payment) async {
        let content = UNMutableNotificationContent()
        content.title = "Filed as work travel"
        content.body = "\(payment.formattedAmount) · \(payment.merchant). Add the bill while you have it?"
        content.categoryIdentifier = Category.receiptNudge
        content.userInfo = [UserInfoKey.paymentID: payment.uid]
        content.threadIdentifier = "payments"

        let trigger = UNTimeIntervalNotificationTrigger(timeInterval: 2, repeats: false)
        await add(content, identifier: "receipt-\(payment.uid)", trigger: trigger)
    }

    static func confirmRefund(on payment: Payment, amount: Double) async {
        let content = UNMutableNotificationContent()
        content.title = "Refund matched"
        content.body = "\(Money.string(amount, currency: payment.currency)) back from "
            + "\(payment.merchant). Claim is now \(payment.formattedNetClaimable)."
        content.threadIdentifier = "payments"
        await add(content, identifier: "refund-\(UUID().uuidString)", trigger: nil)
    }

    /// A payment added on the website has landed. One still waiting gets the
    /// usual question; one already marked work just says it arrived.
    static func arrivedFromWebsite(_ payment: Payment, store: PaymentStore) async {
        guard payment.status == .work else {
            await askAbout(payment, hint: "Added on the website")
            return
        }
        let content = UNMutableNotificationContent()
        content.title = "Added from the website"
        let receipts = payment.receipts.count
        content.body = "\(payment.formattedAmount) · \(payment.merchant)"
            + (receipts == 0 ? "" : receipts == 1 ? " · 1 receipt" : " · \(receipts) receipts")
            + (payment.trip.map { ". Filed under \($0.name)." } ?? ".")
        content.userInfo = [UserInfoKey.paymentID: payment.uid]
        content.threadIdentifier = "payments"
        await add(content, identifier: "web-\(payment.uid)", trigger: nil)
    }

    // MARK: - 9 pm reminder

    /// Rescheduled whenever the inbox changes, and cancelled when it empties.
    static func updatePendingReminder(count: Int) async {
        let center = UNUserNotificationCenter.current()
        center.removePendingNotificationRequests(withIdentifiers: [reminderID])
        guard count > 0 else { return }

        let content = UNMutableNotificationContent()
        content.title = count == 1 ? "1 payment still waiting" : "\(count) payments still waiting"
        content.body = "Work travel or personal? A few taps now saves digging later."
        content.categoryIdentifier = Category.reminder
        content.threadIdentifier = "payments"

        var when = DateComponents()
        when.hour = 21
        when.minute = 0
        let trigger = UNCalendarNotificationTrigger(dateMatching: when, repeats: true)
        await add(content, identifier: reminderID, trigger: trigger)
    }

    private static func add(
        _ content: UNMutableNotificationContent,
        identifier: String,
        trigger: UNNotificationTrigger?
    ) async {
        let request = UNNotificationRequest(identifier: identifier, content: content, trigger: trigger)
        try? await UNUserNotificationCenter.current().add(request)
    }
}
