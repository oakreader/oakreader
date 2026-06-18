import AppKit
import WebKit
import Security

/// Removes OakReader's footprint from the system — the implementation behind
/// Settings → General → Danger Zone ("Uninstall OakReader").
///
/// macOS apps installed by drag-to-Applications have no uninstaller, so residue
/// (Keychain credentials, `~/Library` caches, preferences, WebKit cookies)
/// lingers after the `.app` is trashed. This service clears that residue, then
/// — following the convention of Obsidian/Zotero and friends — *preserves* the
/// user's library (`~/OakReader/`) by default, since it holds irreplaceable
/// content (PDFs, notes, highlights). The user can opt to remove the library
/// too, in which case it is moved to the **Trash** (recoverable), never erased
/// in place. Finally the app bundle itself is moved to the Trash and the process
/// hard-exits.
@MainActor
enum UninstallService {

    /// The user's library directory (`~/OakReader` or `~/OakReader-Dev`).
    static var libraryDirectory: URL { CatalogDatabase.dataDirectory }

    /// Whether a library currently exists on disk.
    static var libraryExists: Bool {
        FileManager.default.fileExists(atPath: libraryDirectory.path)
    }

    private static var bundleID: String {
        Bundle.main.bundleIdentifier ?? "com.oakreader.OakReader"
    }

    /// Keychain access group shared by every OakReader credential (must match
    /// the `keychain-access-groups` entitlement and `OakAI.KeychainConfig`).
    private static let keychainAccessGroup = "5Y27G7B6D8.com.oakreader.keys"

    // MARK: - Orchestration

    /// Erase the app's system residue and (optionally) the user library, then
    /// move the app to the Trash and quit. **Does not return.**
    static func uninstall(deleteLibrary: Bool) async {
        await removeWebsiteData()
        removeKeychainItems()
        removeResidueFiles()

        // Things we send to the Trash (recoverable), not erase in place.
        var trashURLs: [URL] = []
        if deleteLibrary {
            if libraryExists { trashURLs.append(libraryDirectory) }
            trashURLs.append(contentsOf: preRestoreBackups())
        }
        trashURLs.append(Bundle.main.bundleURL)

        // Clear preferences last so AppKit can't re-read them, then hard-exit
        // (not `terminate`) so it can't re-flush UserDefaults / saved state.
        removePreferences()

        await moveToTrash(trashURLs)
        exit(0)
    }

    // MARK: - Steps

    /// Cookies, localStorage and other site data from the shared browsing store.
    private static func removeWebsiteData() async {
        let store = WKWebsiteDataStore.default()
        let types = WKWebsiteDataStore.allWebsiteDataTypes()
        await withCheckedContinuation { continuation in
            store.removeData(ofTypes: types, modifiedSince: .distantPast) {
                continuation.resume()
            }
        }
    }

    /// All OakReader credentials are generic passwords in one access group, so a
    /// single scoped delete removes API keys, OAuth tokens and skill secrets.
    private static func removeKeychainItems() {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccessGroup as String: keychainAccessGroup,
            kSecUseDataProtectionKeychain as String: true,
        ]
        SecItemDelete(query as CFDictionary)
    }

    /// Caches, saved window state and any per-bundle support folder. These are
    /// regenerable residue, so they are deleted in place rather than trashed.
    private static func removeResidueFiles() {
        let fm = FileManager.default
        let home = fm.homeDirectoryForCurrentUser
        let caches = home.appendingPathComponent("Library/Caches", isDirectory: true)
        let appSupport = home.appendingPathComponent("Library/Application Support", isDirectory: true)

        let residue: [URL] = [
            // TTS audio cache (`~/Library/Caches/tts`).
            caches.appendingPathComponent("tts", isDirectory: true),
            // Per-bundle caches (Sparkle downloads, URL cache, PostHog queue).
            caches.appendingPathComponent(bundleID, isDirectory: true),
            // Per-bundle Application Support (analytics SDK state, if any).
            appSupport.appendingPathComponent(bundleID, isDirectory: true),
            // Saved window/application state.
            home.appendingPathComponent(
                "Library/Saved Application State/\(bundleID).savedState",
                isDirectory: true
            ),
        ]
        for url in residue {
            try? fm.removeItem(at: url)
        }
    }

    /// App-generated safety copies left by a failed restore (`~/OakReader-pre-restore-*`).
    /// Only removed alongside the library itself.
    private static func preRestoreBackups() -> [URL] {
        let fm = FileManager.default
        let home = fm.homeDirectoryForCurrentUser
        let entries = (try? fm.contentsOfDirectory(
            at: home, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]
        )) ?? []
        return entries.filter { $0.lastPathComponent.hasPrefix("OakReader-pre-restore-") }
    }

    private static func removePreferences() {
        UserDefaults.standard.removePersistentDomain(forName: bundleID)
        UserDefaults.standard.synchronize()
    }

    private static func moveToTrash(_ urls: [URL]) async {
        guard !urls.isEmpty else { return }
        await withCheckedContinuation { continuation in
            NSWorkspace.shared.recycle(urls) { _, _ in
                continuation.resume()
            }
        }
    }
}
