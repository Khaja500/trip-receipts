import Foundation
import SwiftData

extension ModelContainer {
    /// One container definition. `shared` is the only instance anything should
    /// open: the App Intent runs inside the app's process, so a second container
    /// over the same store would hide its writes from an open Inbox. The
    /// `inMemory` flag exists for tests, which want a throwaway store.
    static func tripReceipts(inMemory: Bool = false) throws -> ModelContainer {
        let schema = Schema([Payment.self, Trip.self, ReceiptFile.self])
        let configuration = ModelConfiguration(
            schema: schema,
            isStoredInMemoryOnly: inMemory,
            allowsSave: true
        )
        return try ModelContainer(for: schema, configurations: [configuration])
    }

    static let shared: ModelContainer = {
        do {
            return try ModelContainer.tripReceipts()
        } catch {
            fatalError("Could not open the local store: \(error)")
        }
    }()
}
