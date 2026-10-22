import SwiftUI
import SwiftData

struct RootView: View {
    @Environment(Router.self) private var router
    @Query(filter: #Predicate<Payment> { $0.statusRaw == "pending" })
    private var pending: [Payment]

    var body: some View {
        @Bindable var router = router
        TabView(selection: $router.tab) {
            InboxView()
                .tabItem { Label("Inbox", systemImage: "tray.full") }
                .badge(pending.count)
                .tag(Router.Tab.inbox)

            ExpensesView()
                .tabItem { Label("Expenses", systemImage: "indianrupeesign.circle") }
                .tag(Router.Tab.expenses)

            TripsView()
                .tabItem { Label("Trips", systemImage: "suitcase") }
                .tag(Router.Tab.trips)

            SetupView()
                .tabItem { Label("Setup", systemImage: "gearshape") }
                .tag(Router.Tab.setup)
        }
    }
}
