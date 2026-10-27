import BackgroundTasks
import UIKit
import UserNotifications
import SwiftData

/// Handles the answers. "Yes, work travel" and "Personal" are resolved here
/// without the app ever coming to the front; the other two open it.
final class AppDelegate: NSObject, UIApplicationDelegate, UNUserNotificationCenterDelegate {

    var router: Router?

    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        UNUserNotificationCenter.current().delegate = self
        NotificationManager.registerCategories()
        GitHubSync.shared.startObserving()
        // Wakes the app now and then to fetch payments added on the website.
        BGTaskScheduler.shared.register(forTaskWithIdentifier: GitHubSync.refreshTaskID, using: nil) { task in
            guard let task = task as? BGAppRefreshTask else { return }
            GitHubSync.handleRefresh(task)
        }
        return true
    }

    /// Show the question even while the app is open, so the flow is the same
    /// either way.
    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        [.banner, .sound, .list]
    }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse
    ) async {
        let userInfo = response.notification.request.content.userInfo
        guard let uid = userInfo[NotificationManager.UserInfoKey.paymentID] as? String else {
            if response.notification.request.content.categoryIdentifier == NotificationManager.Category.reminder {
                await MainActor.run { router?.tab = .inbox }
            }
            return
        }

        await MainActor.run {
            let context = ModelContext(ModelContainer.shared)
            let store = PaymentStore(context: context)
            guard let payment = store.payment(uid: uid) else { return }

            switch response.actionIdentifier {
            case NotificationManager.Action.work:
                store.markWork(payment)
                Task {
                    await NotificationManager.nudgeForReceipt(payment)
                    await NotificationManager.updatePendingReminder(count: store.pendingCount())
                }

            case NotificationManager.Action.personal:
                store.markPersonal(payment)
                Task { await NotificationManager.updatePendingReminder(count: store.pendingCount()) }

            case NotificationManager.Action.workWithReceipt:
                store.markWork(payment)
                router?.showPayment(uid: uid, withReceiptPicker: true)
                Task { await NotificationManager.updatePendingReminder(count: store.pendingCount()) }

            case NotificationManager.Action.addReceipt:
                router?.showPayment(uid: uid, withReceiptPicker: true)

            default:
                // Tapped the notification body rather than a button.
                router?.showPayment(uid: uid)
            }
        }
        await GitHubSync.shared.syncNow()
    }
}
