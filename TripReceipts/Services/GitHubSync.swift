import BackgroundTasks
import Foundation
import Observation
import SwiftData
import UIKit

/// Mirrors the store to `transactions.json` in a GitHub repo, which the
/// website reads — with no token when the repo is public. Off until a repo and
/// token are saved in Setup; the token is only for writing. With a shared repo
/// set as well, a work-only copy goes there too, for someone else to read.
///
/// Each sync first files any payments added on the website (`WebInbox`), so
/// they go back up in the same snapshot.
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
        /// Optional, same owner and token. Gets `SyncSnapshot.workOnly()`.
        var shareRepo = ""
        /// Fixed rather than configurable; the website reads the same path.
        var path = "transactions.json"

        var isComplete: Bool { !owner.isEmpty && !repo.isEmpty }
        var isSharing: Bool { !shareRepo.isEmpty }
        var fullName: String { "\(owner)/\(repo)" }
        var shareFullName: String { "\(owner)/\(shareRepo)" }
    }

    private(set) var settings: Settings
    private(set) var hasToken: Bool
    private(set) var isSyncing = false
    private(set) var lastSyncedAt: Date?
    private(set) var lastError: String?
    /// The shared copy fails on its own — usually a token that can't see that repo.
    private(set) var shareError: String?
    /// Fetching website additions fails on its own too; the upload still runs.
    private(set) var webInboxError: String?

    /// Must match BGTaskSchedulerPermittedIdentifiers in TripReceipts-Info.plist.
    static let refreshTaskID = "com.Khaja-Aflal.tripreceipts.web-inbox"

    @ObservationIgnored private var debounce: Task<Void, Never>?
    @ObservationIgnored private var inFlight: Task<Void, Never>?
    @ObservationIgnored private var observer: NSObjectProtocol?
    @ObservationIgnored private let defaults = UserDefaults.standard

    private static let keychain = KeychainItem(service: "TripReceipts.GitHubSync", account: "token")

    private enum Key {
        static let enabled = "sync.enabled"
        static let owner = "sync.owner"
        static let repo = "sync.repo"
        static let shareRepo = "sync.shareRepo"
        static let lastSyncedAt = "sync.lastSyncedAt"
        /// Digest of the last snapshot that went up, and the blob SHA GitHub
        /// gave it — both forgotten when the repo changes.
        static let pushedDigest = "sync.pushedDigest"
        static let remoteSHA = "sync.remoteSHA"
        static let sharePushedDigest = "sync.share.pushedDigest"
        static let shareRemoteSHA = "sync.share.remoteSHA"
    }

    private init() {
        let defaults = UserDefaults.standard
        settings = Settings(
            enabled: defaults.bool(forKey: Key.enabled),
            owner: defaults.string(forKey: Key.owner) ?? "",
            repo: defaults.string(forKey: Key.repo) ?? "",
            shareRepo: defaults.string(forKey: Key.shareRepo) ?? ""
        )
        hasToken = Self.keychain.read() != nil
        lastSyncedAt = defaults.object(forKey: Key.lastSyncedAt) as? Date
    }

    var isActive: Bool { settings.enabled && settings.isComplete && hasToken }

    var websiteLink: URL { Self.websiteLink(repo: settings.fullName) }

    /// What to send whoever reads the shared repo.
    var shareWebsiteLink: URL { Self.websiteLink(repo: settings.shareFullName) }

    private static func websiteLink(repo: String) -> URL {
        var components = URLComponents(string: websiteURL)!
        components.fragment = "repo=\(repo)"
        return components.url!
    }

    // MARK: - Settings

    /// Saves what Setup collected. An empty token keeps the saved one.
    func configure(_ new: Settings, token: String?) {
        var new = new
        new.owner = new.owner.trimmingCharacters(in: .whitespacesAndNewlines)
        new.repo = new.repo.trimmingCharacters(in: .whitespacesAndNewlines)
        new.shareRepo = new.shareRepo.trimmingCharacters(in: .whitespacesAndNewlines)

        if let token = token?.trimmingCharacters(in: .whitespacesAndNewlines), !token.isEmpty {
            Self.keychain.save(token)
            hasToken = true
        }
        if new.fullName != settings.fullName {
            defaults.removeObject(forKey: Key.pushedDigest)
            defaults.removeObject(forKey: Key.remoteSHA)
            lastSyncedAt = nil
            defaults.removeObject(forKey: Key.lastSyncedAt)
        }
        if new.shareFullName != settings.shareFullName {
            defaults.removeObject(forKey: Key.sharePushedDigest)
            defaults.removeObject(forKey: Key.shareRemoteSHA)
        }
        settings = new
        defaults.set(new.enabled, forKey: Key.enabled)
        defaults.set(new.owner, forKey: Key.owner)
        defaults.set(new.repo, forKey: Key.repo)
        defaults.set(new.shareRepo, forKey: Key.shareRepo)
        lastError = nil
        shareError = nil
        webInboxError = nil
    }

    func forgetToken() {
        Self.keychain.delete()
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
        scheduleRefresh()
        Task {
            await syncNow()
            finish()
        }
    }

    // MARK: - Background refresh

    /// Asks iOS to wake the app in about a quarter of an hour. iOS picks the
    /// actual time, often later, and less often for an app rarely opened.
    func scheduleRefresh() {
        guard isActive else { return }
        let request = BGAppRefreshTaskRequest(identifier: Self.refreshTaskID)
        request.earliestBeginDate = .now.addingTimeInterval(15 * 60)
        try? BGTaskScheduler.shared.submit(request)
    }

    static func handleRefresh(_ task: BGAppRefreshTask) {
        let work = Task { @MainActor in
            GitHubSync.shared.scheduleRefresh()
            await GitHubSync.shared.syncNow()
            task.setTaskCompleted(success: !Task.isCancelled)
        }
        task.expirationHandler = { work.cancel() }
    }

    // MARK: - Website additions

    /// Files payments added on the website before the snapshot is taken, so
    /// they go straight back up with everything else.
    private func pullFromWebsite(token: String, target: Settings) async {
        let inbox = WebInbox(token: token, owner: target.owner, repo: target.repo)
        let store = PaymentStore(context: ModelContext(ModelContainer.shared))
        do {
            let created = try await inbox.pull(into: store)
            for payment in created {
                await NotificationManager.arrivedFromWebsite(payment, store: store)
            }
            if !created.isEmpty {
                await NotificationManager.updatePendingReminder(count: store.pendingCount())
            }
            webInboxError = nil
        } catch {
            webInboxError = "Couldn't fetch payments added on the website: \(error.localizedDescription)"
        }
    }

    // MARK: - Upload

    /// The full snapshot first, then the work-only copy; one failing doesn't
    /// stop the other.
    private func push(force: Bool) async {
        guard isActive, let token = Self.keychain.read() else { return }
        let target = settings

        await pullFromWebsite(token: token, target: target)

        let snapshot: SyncSnapshot
        do {
            snapshot = try SyncSnapshot.build(context: ModelContext(ModelContainer.shared))
        } catch {
            lastError = error.localizedDescription
            return
        }

        do {
            if try await upload(snapshot, to: \.repo, of: target, token: token, force: force,
                                digestKey: Key.pushedDigest, shaKey: Key.remoteSHA) {
                lastSyncedAt = .now
                defaults.set(lastSyncedAt, forKey: Key.lastSyncedAt)
            }
            lastError = nil
        } catch {
            lastError = error.localizedDescription
        }

        guard target.isSharing else { return }
        do {
            try await upload(snapshot.workOnly(), to: \.shareRepo, of: target, token: token, force: force,
                             digestKey: Key.sharePushedDigest, shaKey: Key.shareRemoteSHA)
            shareError = nil
        } catch {
            shareError = error.localizedDescription
        }
    }

    /// Writes the snapshot to one repo unless that repo already has this
    /// content. True when it uploaded.
    @discardableResult
    private func upload(_ snapshot: SyncSnapshot, to repo: KeyPath<Settings, String>, of target: Settings,
                        token: String, force: Bool, digestKey: String, shaKey: String) async throws -> Bool {
        let digest = try snapshot.contentDigest()
        if !force, digest == defaults.string(forKey: digestKey) { return false }

        isSyncing = true
        defer { isSyncing = false }

        let file = GitHubFile(token: token, owner: target.owner, repo: target[keyPath: repo], path: target.path)
        let sha = try await file.write(
            try snapshot.encoded(),
            message: Self.commitMessage(for: snapshot),
            knownSHA: defaults.string(forKey: shaKey)
        )

        // The repo was changed while this was in the air; its state is not ours.
        guard settings.owner == target.owner, settings[keyPath: repo] == target[keyPath: repo] else { return false }
        defaults.set(digest, forKey: digestKey)
        defaults.set(sha, forKey: shaKey)
        return true
    }

    private static func commitMessage(for snapshot: SyncSnapshot) -> String {
        if snapshot.scope != nil {
            return "Sync from iPhone: \(snapshot.payments.count) work expenses, \(snapshot.trips.count) trips"
        }
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
