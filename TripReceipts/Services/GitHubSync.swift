import Foundation
import Observation
import Security
import SwiftData
import UIKit

/// Mirrors the store to `transactions.json` in a private GitHub repo, which
/// the website reads. Off until a repo and token are saved in Setup.
///
/// The whole snapshot is rewritten after each change rather than patched: the
/// phone is the only writer, so the latest file is always the truth and a
/// deleted payment needs no bookkeeping. An upload is skipped when the data
/// hasn't changed since the last one went up.
@MainActor
@Observable
final class GitHubSync {
    static let shared = GitHubSync()

    /// Where the website is published. The link from Setup carries the repo
    /// name (never the token) so the site can fill it in.
    static let websiteURL = "https://khaja500.github.io/trip-receipts/"

    struct Settings: Equatable {
        var enabled = false
        var owner = ""
        var repo = ""
        /// Fixed rather than configurable; the website reads the same path.
        var path = "transactions.json"

        var isComplete: Bool { !owner.isEmpty && !repo.isEmpty }
        var fullName: String { "\(owner)/\(repo)" }
    }

    private(set) var settings: Settings
    private(set) var hasToken: Bool
    private(set) var isSyncing = false
    private(set) var lastSyncedAt: Date?
    private(set) var lastError: String?

    @ObservationIgnored private var debounce: Task<Void, Never>?
    @ObservationIgnored private var inFlight: Task<Void, Never>?
    @ObservationIgnored private var observer: NSObjectProtocol?
    @ObservationIgnored private let defaults = UserDefaults.standard

    private enum Key {
        static let enabled = "sync.enabled"
        static let owner = "sync.owner"
        static let repo = "sync.repo"
        static let lastSyncedAt = "sync.lastSyncedAt"
        /// Digest of the last snapshot that went up, and the blob SHA GitHub
        /// gave it — both forgotten when the repo changes.
        static let pushedDigest = "sync.pushedDigest"
        static let remoteSHA = "sync.remoteSHA"
    }

    private init() {
        let defaults = UserDefaults.standard
        settings = Settings(
            enabled: defaults.bool(forKey: Key.enabled),
            owner: defaults.string(forKey: Key.owner) ?? "",
            repo: defaults.string(forKey: Key.repo) ?? ""
        )
        hasToken = Keychain.read() != nil
        lastSyncedAt = defaults.object(forKey: Key.lastSyncedAt) as? Date
    }

    var isActive: Bool { settings.enabled && settings.isComplete && hasToken }

    var websiteLink: URL {
        var components = URLComponents(string: Self.websiteURL)!
        components.fragment = "repo=\(settings.fullName)"
        return components.url!
    }

    // MARK: - Settings

    /// Saves what Setup collected. An empty token keeps the saved one.
    func configure(_ new: Settings, token: String?) {
        var new = new
        new.owner = new.owner.trimmingCharacters(in: .whitespacesAndNewlines)
        new.repo = new.repo.trimmingCharacters(in: .whitespacesAndNewlines)

        if let token = token?.trimmingCharacters(in: .whitespacesAndNewlines), !token.isEmpty {
            Keychain.save(token)
            hasToken = true
        }
        if new.fullName != settings.fullName {
            defaults.removeObject(forKey: Key.pushedDigest)
            defaults.removeObject(forKey: Key.remoteSHA)
            lastSyncedAt = nil
            defaults.removeObject(forKey: Key.lastSyncedAt)
        }
        settings = new
        defaults.set(new.enabled, forKey: Key.enabled)
        defaults.set(new.owner, forKey: Key.owner)
        defaults.set(new.repo, forKey: Key.repo)
        lastError = nil
    }

    func forgetToken() {
        Keychain.delete()
        hasToken = false
    }

    // MARK: - When to sync

    /// Every save anywhere — Inbox swipes, detail edits, the intent — asks for
    /// a sync. Called once at launch, background launches included.
    func startObserving() {
        guard observer == nil else { return }
        observer = NotificationCenter.default.addObserver(
            forName: ModelContext.didSave, object: nil, queue: .main
        ) { _ in
            Task { @MainActor in GitHubSync.shared.scheduleSync() }
        }
    }

    /// Coalesces a burst of saves (a bulk "mark all") into one upload.
    func scheduleSync() {
        guard isActive else { return }
        debounce?.cancel()
        debounce = Task {
            try? await Task.sleep(for: .seconds(2))
            guard !Task.isCancelled else { return }
            await self.syncNow()
        }
    }

    /// Uploads now if anything changed, after any upload already under way.
    /// The intent and the notification handler await this so the upload
    /// finishes before iOS suspends the app again.
    func syncNow(force: Bool = false) async {
        guard isActive else { return }
        let previous = inFlight
        let run = Task {
            await previous?.value
            await self.push(force: force)
        }
        inFlight = run
        await run.value
    }

    /// For leaving the foreground: asks iOS for the few seconds an upload needs.
    func syncBeforeSuspending() {
        guard isActive else { return }
        var task = UIBackgroundTaskIdentifier.invalid
        let finish = {
            guard task != .invalid else { return }
            UIApplication.shared.endBackgroundTask(task)
            task = .invalid
        }
        task = UIApplication.shared.beginBackgroundTask(withName: "GitHubSync") { finish() }
        Task {
            await syncNow()
            finish()
        }
    }

    // MARK: - Upload

    private func push(force: Bool) async {
        guard isActive, let token = Keychain.read() else { return }
        let target = settings

        do {
            let snapshot = try SyncSnapshot.build(context: ModelContext(ModelContainer.shared))
            let digest = try snapshot.contentDigest()
            if !force, digest == defaults.string(forKey: Key.pushedDigest) { return }

            isSyncing = true
            defer { isSyncing = false }

            let file = GitHubFile(token: token, owner: target.owner, repo: target.repo, path: target.path)
            let sha = try await file.write(
                try snapshot.encoded(),
                message: Self.commitMessage(for: snapshot),
                knownSHA: defaults.string(forKey: Key.remoteSHA)
            )

            // The repo was changed while this was in the air; its state is not ours.
            guard target == settings else { return }
            defaults.set(digest, forKey: Key.pushedDigest)
            defaults.set(sha, forKey: Key.remoteSHA)
            lastSyncedAt = .now
            defaults.set(lastSyncedAt, forKey: Key.lastSyncedAt)
            lastError = nil
        } catch {
            lastError = error.localizedDescription
        }
    }

    private static func commitMessage(for snapshot: SyncSnapshot) -> String {
        let count = { (status: PaymentStatus) in
            snapshot.payments.filter { $0.status == status.rawValue }.count
        }
        return "Sync from iPhone: \(count(.pending)) waiting, \(count(.work)) work, "
            + "\(count(.personal)) personal, \(snapshot.trips.count) trips"
    }
}

// MARK: - GitHub

/// The two calls the sync needs from GitHub's contents API.
private struct GitHubFile {
    let token: String
    let owner: String
    let repo: String
    let path: String

    /// Writes the file on the default branch and returns its new blob SHA. A
    /// stale or missing SHA — the file was changed or created elsewhere — is
    /// looked up and the write retried once.
    func write(_ content: Data, message: String, knownSHA: String?) async throws -> String {
        var sha = knownSHA
        for attempt in 0..<2 {
            var body: [String: Any] = ["message": message, "content": content.base64EncodedString()]
            if let sha { body["sha"] = sha }
            var request = try request(method: "PUT")
            request.httpBody = try JSONSerialization.data(withJSONObject: body)

            let (data, status) = try await send(request)
            switch status {
            case 200, 201:
                let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
                guard let newSHA = (json?["content"] as? [String: Any])?["sha"] as? String else {
                    throw SyncError(status: status, data: data)
                }
                return newSHA
            case 409, 422:
                guard attempt == 0 else { throw SyncError(status: status, data: data) }
                sha = try await currentSHA()
            default:
                throw SyncError(status: status, data: data)
            }
        }
        throw SyncError(status: 409, data: Data())
    }

    /// Nil when the file doesn't exist yet.
    private func currentSHA() async throws -> String? {
        let (data, status) = try await send(try request(method: "GET"))
        switch status {
        case 200:
            return (try JSONSerialization.jsonObject(with: data) as? [String: Any])?["sha"] as? String
        case 404:
            return nil
        default:
            throw SyncError(status: status, data: data)
        }
    }

    private func request(method: String) throws -> URLRequest {
        var components = URLComponents()
        components.scheme = "https"
        components.host = "api.github.com"
        components.path = "/repos/\(owner)/\(repo)/contents/\(path)"
        guard let url = components.url else { throw SyncError(status: 0, data: Data()) }

        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 20)
        request.httpMethod = method
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")
        return request
    }

    private func send(_ request: URLRequest) async throws -> (Data, Int) {
        let (data, response) = try await URLSession.shared.data(for: request)
        return (data, (response as? HTTPURLResponse)?.statusCode ?? 0)
    }
}

struct SyncError: LocalizedError {
    var status: Int
    /// GitHub's own explanation, when it gave one.
    var message: String?

    init(status: Int, data: Data) {
        self.status = status
        let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        self.message = json?["message"] as? String
    }

    var errorDescription: String? {
        switch status {
        case 401:
            "GitHub didn't accept the token. Paste a new one."
        case 403:
            "The token can't write to this repo — it needs Contents: Read and write."
                + (message.map { " (\($0))" } ?? "")
        case 404:
            "Repo not found, or the token can't see it."
        case 0:
            "Couldn't reach GitHub."
        default:
            "GitHub answered \(status)" + (message.map { ": \($0)" } ?? ".")
        }
    }
}

// MARK: - Keychain

/// The token lives in the Keychain, never in UserDefaults. Readable after the
/// first unlock so a payment SMS arriving on a locked phone still syncs.
private enum Keychain {
    private static var base: [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "TripReceipts.GitHubSync",
            kSecAttrAccount as String: "token"
        ]
    }

    static func read() -> String? {
        var query = base
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func save(_ token: String) {
        delete()
        var query = base
        query[kSecValueData as String] = Data(token.utf8)
        query[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        SecItemAdd(query as CFDictionary, nil)
    }

    static func delete() {
        SecItemDelete(base as CFDictionary)
    }
}
