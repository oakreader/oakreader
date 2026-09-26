import Foundation
import PostHog

/// Thin wrapper around the PostHog SDK.
///
/// Configured for the PostHog **EU** cloud region (matches `--region eu`). The
/// project API key below is a *public* client write key — safe to ship in the
/// app binary. Analytics is opt-out via `Preferences.analyticsEnabled`.
enum Analytics {
    /// PostHog project API key (public client write key). Replace with the
    /// `phc_…` value from PostHog → Project Settings → Project API Key.
    private static let apiKey = "phc_AwEeUsXZ2N85zBJ4JP8wPuYJDEDgULwxYWHFKD8LW4So"

    /// EU cloud ingestion host.
    private static let host = "https://eu.i.posthog.com"

    private static var isConfigured = false

    /// Initialize PostHog. Call once, early in app launch. No-op when the user
    /// has opted out or the API key hasn't been filled in.
    static func start() {
        guard Preferences.shared.analyticsEnabled else {
            Log.info(Log.analytics, "Analytics disabled by preference")
            return
        }
        guard apiKey.hasPrefix("phc_"), apiKey != "phc_REPLACE_ME" else {
            Log.info(Log.analytics, "Analytics disabled: no PostHog API key configured")
            return
        }

        let config = PostHogConfig(apiKey: apiKey, host: host)
        PostHogSDK.shared.setup(config)
        isConfigured = true
        Log.info(Log.analytics, "PostHog initialized (EU)")
    }

    /// Capture a product event. No-op when analytics isn't configured.
    static func capture(_ event: String, properties: [String: Any]? = nil) {
        guard isConfigured else { return }
        PostHogSDK.shared.capture(event, properties: properties)
    }

    /// Stop sending events and clear local queues (e.g. when the user opts out
    /// at runtime).
    static func optOut() {
        guard isConfigured else { return }
        PostHogSDK.shared.optOut()
    }

    /// Resume sending events after a prior opt-out.
    static func optIn() {
        guard isConfigured else { return }
        PostHogSDK.shared.optIn()
    }
}
