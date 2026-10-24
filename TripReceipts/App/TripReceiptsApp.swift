import SwiftUI
import SwiftData

@main
struct TripReceiptsApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @Environment(\.scenePhase) private var scenePhase
    @State private var router = Router()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(router)
                .task {
                    appDelegate.router = router
                    await NotificationManager.requestAuthorization()
                    let store = PaymentStore(context: ModelContext(ModelContainer.shared))
                    store.purgeOldPersonal()
                    store.unfileOutsideTrips()
                    await NotificationManager.updatePendingReminder(count: store.pendingCount())
                    GitHubSync.shared.scheduleSync()
                }
        }
        .modelContainer(ModelContainer.shared)
        .onChange(of: scenePhase) { _, phase in
            // Edits on the payment screen autosave on their own schedule;
            // leaving the app is the moment to make sure they went up.
            if phase == .background { GitHubSync.shared.syncBeforeSuspending() }
        }
    }
}
