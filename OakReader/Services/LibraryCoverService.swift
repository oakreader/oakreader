import Foundation
import PDFKit
import AppKit
import ObjectiveC
@preconcurrency import WebKit

actor LibraryCoverService {
    private let renderingService = PDFRenderingService()
    private let maxDimension: CGFloat = 320

    func generateCover(for url: URL) async -> Data? {
        guard let pdfDoc = PDFDocument(url: url),
              let firstPage = pdfDoc.page(at: 0) else { return nil }

        let thumbnail = renderingService.renderThumbnail(firstPage, maxDimension: maxDimension)
        return thumbnail.tiffRepresentation.flatMap {
            NSBitmapImageRep(data: $0)?.representation(using: .jpeg, properties: [.compressionFactor: 0.8])
        }
    }

    /// Generate a cover thumbnail from an HTML document using an offscreen WKWebView.
    func generateHTMLCover(for htmlURL: URL) async -> Data? {
        return await withCheckedContinuation { continuation in
            DispatchQueue.main.async {
                let config = WKWebViewConfiguration()
                let webView = WKWebView(frame: NSRect(x: 0, y: 0, width: 1024, height: 768), configuration: config)
                let delegate = SnapshotNavDelegate { webView in
                    let snapshotConfig = WKSnapshotConfiguration()
                    snapshotConfig.rect = NSRect(x: 0, y: 0, width: 1024, height: 768)
                    webView.takeSnapshot(with: snapshotConfig) { image, error in
                        guard let image else {
                            Log.error(Log.cover, "HTML cover failed: \(error?.localizedDescription ?? "unknown")")
                            continuation.resume(returning: nil)
                            return
                        }
                        // Scale down and convert to JPEG
                        let targetSize = NSSize(width: 320, height: 240)
                        let scaled = NSImage(size: targetSize)
                        scaled.lockFocus()
                        image.draw(in: NSRect(origin: .zero, size: targetSize),
                                   from: NSRect(origin: .zero, size: image.size),
                                   operation: .copy,
                                   fraction: 1.0)
                        scaled.unlockFocus()

                        let data = scaled.tiffRepresentation.flatMap {
                            NSBitmapImageRep(data: $0)?.representation(using: .jpeg, properties: [.compressionFactor: 0.8])
                        }
                        continuation.resume(returning: data)
                    }
                }
                // Store delegate to prevent deallocation (WKWebView.navigationDelegate is weak)
                objc_setAssociatedObject(webView, "snapshotDelegate", delegate, .OBJC_ASSOCIATION_RETAIN)
                webView.navigationDelegate = delegate
                let storageDir = htmlURL.deletingLastPathComponent()
                webView.loadFileURL(htmlURL, allowingReadAccessTo: storageDir)
            }
        }
    }
}

/// Helper delegate that takes a snapshot once the page finishes loading.
private final class SnapshotNavDelegate: NSObject, WKNavigationDelegate {
    private let onFinish: (WKWebView) -> Void

    init(onFinish: @escaping (WKWebView) -> Void) {
        self.onFinish = onFinish
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        // Brief delay for rendering to complete
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [self] in
            onFinish(webView)
        }
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        onFinish(webView) // Try to snapshot whatever loaded
    }
}
