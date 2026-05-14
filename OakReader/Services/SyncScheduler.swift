import Foundation

/// Schedules background sync for X Bookmarks and GitHub Stars.
/// Runs once at launch (after a short delay) and then hourly.
@Observable
final class SyncScheduler {
    private let importService: ImportService
    private var timer: Timer?

    var isSyncingX = false
    var isSyncingGitHub = false
    var lastXError: String?
    var lastGitHubError: String?

    init(importService: ImportService) {
        self.importService = importService
    }

    /// Start the scheduler: sync after 5 seconds, then check every 15 minutes.
    func start() {
        // Initial sync after a short delay to let the UI settle
        DispatchQueue.main.asyncAfter(deadline: .now() + 5) { [weak self] in
            self?.syncAllIfNeeded()
        }

        // Check periodically whether a sync is due
        timer = Timer.scheduledTimer(withTimeInterval: 900, repeats: true) { [weak self] _ in
            self?.syncAllIfNeeded()
        }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    /// Sync all enabled extensions if their configured interval has elapsed.
    private func syncAllIfNeeded() {
        if Preferences.shared.isExtensionEnabled(.xBookmarks),
           Preferences.shared.xSyncEnabled,
           Preferences.shared.xBearerToken != nil {
            Task { await syncXBookmarksNow() }
        }

        if Preferences.shared.isExtensionEnabled(.githubStars),
           Preferences.shared.githubSyncEnabled,
           Preferences.shared.githubToken != nil,
           isGitHubSyncDue() {
            Task { await syncGitHubStarsNow() }
        }
    }

    private func isGitHubSyncDue() -> Bool {
        guard let lastSync = Preferences.shared.githubLastSyncDate else { return true }
        let interval = Preferences.shared.githubSyncInterval
        return Date().timeIntervalSince(lastSync) >= interval
    }

    // MARK: - Manual Triggers

    /// Manually trigger X Bookmarks sync. Called from settings view.
    @MainActor
    func syncXBookmarksNow() async {
        guard !isSyncingX else { return }
        guard let token = Preferences.shared.xBearerToken, !token.isEmpty else {
            lastXError = SyncError.tokenNotConfigured.localizedDescription
            return
        }

        isSyncingX = true
        lastXError = nil

        do {
            let result = try await importService.syncXBookmarks(bearerToken: token)
            Preferences.shared.xLastSyncDate = Date()
            Log.info(Log.importer, "X Bookmarks sync: \(result.imported) imported, \(result.skipped) skipped, \(result.total) total")
        } catch {
            lastXError = error.localizedDescription
            Log.error(Log.importer, "X Bookmarks sync failed: \(error)")
        }

        isSyncingX = false
    }

    /// Manually trigger GitHub Stars sync. Called from settings view.
    @MainActor
    func syncGitHubStarsNow() async {
        guard !isSyncingGitHub else { return }
        guard let token = Preferences.shared.githubToken, !token.isEmpty else {
            lastGitHubError = SyncError.tokenNotConfigured.localizedDescription
            return
        }

        isSyncingGitHub = true
        lastGitHubError = nil

        do {
            // Phase 1: fast import
            let result = try await importService.syncGitHubStars(token: token)
            Preferences.shared.githubLastSyncDate = Date()
            Log.info(Log.importer, "GitHub Stars sync: \(result.imported) imported, \(result.skipped) skipped, \(result.total) total")

            // Phase 2: backfill READMEs (background, non-blocking for UI)
            let svc = importService
            Task.detached {
                let backfill = await svc.resyncGitHubStars(token: token, forceAll: false)
                Log.info(Log.importer, "GitHub Stars backfill: \(backfill.imported) READMEs fetched")
            }
        } catch {
            lastGitHubError = error.localizedDescription
            Log.error(Log.importer, "GitHub Stars sync failed: \(error)")
        }

        isSyncingGitHub = false
    }

    deinit {
        timer?.invalidate()
    }
}
