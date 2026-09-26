import Foundation
import WebKit

/// Owns file downloads started from the live-web browser viewer.
///
/// WebKit hands us a `WKDownload` whenever a navigation response can't be shown
/// inline (`.zip`, `.dmg`, `application/octet-stream`, …); the coordinator
/// converts that response to `.download` and routes it here instead of letting
/// WebKit render the raw bytes as on-screen mojibake.
///
/// `WKDownload.delegate` is weak and WebKit doesn't keep the download alive for
/// us, so each in-flight transfer is held in `active` until it finishes or fails
/// — otherwise it would be deallocated the instant `track` returns and cancel.
@MainActor
final class WebDownloadManager: NSObject {
    static let shared = WebDownloadManager()

    private var active: Set<WKDownload> = []

    /// Chosen destination per download, so completion can name the finished file
    /// (`WKDownload` has no public "final URL" before macOS 13).
    private var destinations: [WKDownload: URL] = [:]

    /// Destination paths already claimed by in-flight downloads. Two simultaneous
    /// downloads of the same file would otherwise pick the same not-yet-written
    /// name and collide — one writes, the other fails to save.
    private var reserved: Set<String> = []

    private override init() { super.init() }

    /// Adopt a download produced by a `.download` navigation-response policy.
    func track(_ download: WKDownload) {
        active.insert(download)
        download.delegate = self
    }

    private func finish(_ download: WKDownload) {
        if let path = destinations[download]?.path { reserved.remove(path) }
        active.remove(download)
        destinations[download] = nil
    }

    /// `filename` in `directory`, suffixed " (1)", " (2)", … before the extension
    /// if a file already exists there or the path is `taken` — Safari/Finder-style
    /// de-duping that also avoids colliding with other in-flight downloads.
    nonisolated static func uniqueURL(in directory: URL, filename: String, taken: Set<String>) -> URL {
        let fm = FileManager.default
        func isFree(_ url: URL) -> Bool { !fm.fileExists(atPath: url.path) && !taken.contains(url.path) }

        let candidate = directory.appendingPathComponent(filename)
        if isFree(candidate) { return candidate }

        let ext = candidate.pathExtension
        let base = candidate.deletingPathExtension().lastPathComponent
        var i = 1
        while true {
            let name = ext.isEmpty ? "\(base) (\(i))" : "\(base) (\(i)).\(ext)"
            let next = directory.appendingPathComponent(name)
            if isFree(next) { return next }
            i += 1
        }
    }
}

extension WebDownloadManager: WKDownloadDelegate {
    func download(
        _ download: WKDownload,
        decideDestinationUsing response: URLResponse,
        suggestedFilename: String,
        completionHandler: @escaping (URL?) -> Void
    ) {
        let downloads = FileManager.default
            .urls(for: .downloadsDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Downloads")
        let name = suggestedFilename.isEmpty ? "download" : suggestedFilename
        let url = Self.uniqueURL(in: downloads, filename: name, taken: reserved)
        reserved.insert(url.path)
        destinations[download] = url
        completionHandler(url)
    }

    func downloadDidFinish(_ download: WKDownload) {
        let url = destinations[download]
        finish(download)
        if let url { showDownloadToast(fileURL: url) }
    }

    func download(
        _ download: WKDownload,
        didFailWithError error: Error,
        resumeData: Data?
    ) {
        finish(download)
        showDownloadFailedToast(reason: error.localizedDescription)
    }
}
