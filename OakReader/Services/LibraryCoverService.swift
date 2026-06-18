import Foundation
import PDFKit
import AppKit
import ObjectiveC
@preconcurrency import WebKit

actor LibraryCoverService {
    private let renderingService = PDFRenderingService()
    private let maxDimension: CGFloat = 320

    /// Safari-like UA so sites (incl. X/Cloudflare) serve real HTML + OG tags to the scrape.
    private static let browserUserAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) "
        + "AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Safari/605.1.15"

    func generateCover(for url: URL) async -> Data? {
        guard let pdfDoc = PDFDocument(url: url),
              let firstPage = pdfDoc.page(at: 0) else { return nil }

        let thumbnail = renderingService.renderThumbnail(firstPage, maxDimension: maxDimension)
        return thumbnail.tiffRepresentation.flatMap {
            NSBitmapImageRep(data: $0)?.representation(using: .jpeg, properties: [.compressionFactor: 0.8])
        }
    }

    /// Generate a cover for a saved HTML page.
    ///
    /// Prefers the page's own Open Graph / Twitter preview image — the canonical rich card
    /// (the same one Notion/Raindrop/mymind show), read straight from the saved archive's
    /// `<head>`. Only when no preview image is declared (or it fails to download) do we fall
    /// back to an offscreen screenshot of the page, then to a branded favicon card so the grid
    /// never shows a bare globe placeholder. `sourceURL` is the original page URL — used to
    /// resolve a relative `og:image` and to brand the favicon fallback.
    func generateHTMLCover(for htmlURL: URL, sourceURL: URL? = nil) async -> Data? {
        // 1. og:image / twitter:image from the saved page — the canonical preview image.
        if let html = htmlHead(of: htmlURL),
           let raw = HTMLMeta.content(html, property: "og:image")
                  ?? HTMLMeta.content(html, name: "twitter:image"),
           let imageURL = HTMLMeta.resolveURL(raw, relativeTo: sourceURL ?? htmlURL),
           let data = await downloadCoverImage(imageURL) {
            return data
        }
        // 2. The saved archive declared no usable preview image — SingleFile frequently strips the
        //    og:image meta or inlines it as a `data:` URI we can't download — so fetch it from the
        //    *live* source instead. YouTube always has a poster; Bilibili and most sites expose
        //    og:image on the live page even when the archive doesn't.
        if let sourceURL, let data = await remotePreviewImage(for: sourceURL) { return data }
        // 3. Still nothing reachable — snapshot the saved page itself.
        if let snapshot = await renderHTMLSnapshot(htmlURL) { return snapshot }
        // 4. Last resort — a branded favicon card (real site logo on a tinted card), matching how
        //    `.link` items degrade, instead of leaving a colorless globe placeholder forever.
        if let sourceURL { return await generateFaviconCover(for: sourceURL) }
        return nil
    }

    /// Read the head of a (possibly multi-MB SingleFile) archive as text for meta-tag scraping,
    /// without loading the whole file into memory — the og:image/twitter:image tags live near the
    /// top of `<head>`, well within the first chunk. Lossy UTF-8 decode tolerates a byte-boundary
    /// split and any stray non-UTF-8 bytes (only the ASCII meta tags need to survive).
    private func htmlHead(of url: URL, maxBytes: Int = 512 * 1024) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        guard let data = try? handle.read(upToCount: maxBytes), !data.isEmpty else { return nil }
        return String(decoding: data, as: UTF8.self)
    }

    /// Render a cover thumbnail from a local HTML document using an offscreen WKWebView.
    private func renderHTMLSnapshot(_ htmlURL: URL) async -> Data? {
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
    // MARK: - Link / web preview covers

    /// Generate a static preview cover for a `.link` item.
    ///
    /// Mirrors how WhatsApp/Telegram build link previews: crawl the URL once, read its
    /// Open Graph image, cache a static thumbnail — never a live embed. YouTube short-circuits
    /// to its poster CDN (no HTML fetch, no API). Returns a downscaled JPEG, or nil when no
    /// usable preview image is found (caller then shows an icon+title fallback card).
    func generateLinkCover(for sourceURL: URL) async -> Data? {
        // A real preview image (YouTube poster or the live page's og:image) when one exists, else a
        // branded favicon card (real site logo on a tinted card) instead of a generic link glyph.
        if let data = await remotePreviewImage(for: sourceURL) { return data }
        return await generateFaviconCover(for: sourceURL)
    }

    /// Fetch a real preview image for a URL, the way WhatsApp/Telegram build link previews: crawl
    /// once, read a static image, never embed live. YouTube short-circuits to its poster CDN (no
    /// page fetch, no API); everything else scrapes og:image / twitter:image from the *live* page.
    /// Returns nil when neither yields a usable image, so callers pick their own fallback (a saved-
    /// page snapshot for HTML archives, a favicon card for bare links).
    private func remotePreviewImage(for sourceURL: URL) async -> Data? {
        // 1. YouTube fast-path — derive the poster directly. A video always has one.
        if let id = Self.youTubeVideoID(sourceURL) {
            for variant in ["maxresdefault", "hqdefault"] { // maxres is absent on some videos → fall back
                if let url = URL(string: "https://img.youtube.com/vi/\(id)/\(variant).jpg"),
                   let data = await downloadCoverImage(url) {
                    return data
                }
            }
        }

        // 2. Generic / X / Bilibili / website — scrape og:image (or twitter:image) from the page head.
        if let html = await fetchHTML(sourceURL),
           let raw = HTMLMeta.content(html, property: "og:image")
                  ?? HTMLMeta.content(html, name: "twitter:image"),
           let imageURL = HTMLMeta.resolveURL(raw, relativeTo: sourceURL),
           let data = await downloadCoverImage(imageURL) {
            return data
        }
        return nil
    }

    private func fetchHTML(_ url: URL) async -> String? {
        var req = URLRequest(url: url)
        req.timeoutInterval = 12
        req.setValue(Self.browserUserAgent, forHTTPHeaderField: "User-Agent")
        guard let (data, response) = try? await URLSession.shared.data(for: req) else { return nil }
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) { return nil }
        return String(data: data, encoding: .utf8)
    }

    /// Download an image, downscale to `maxDimension`, re-encode as JPEG. The status-code
    /// guard avoids storing a 404 / error-page body (common for absent YouTube `maxresdefault`).
    private func downloadCoverImage(_ url: URL) async -> Data? {
        var req = URLRequest(url: url)
        req.timeoutInterval = 12
        req.setValue(Self.browserUserAgent, forHTTPHeaderField: "User-Agent")
        guard let (data, response) = try? await URLSession.shared.data(for: req),
              (response as? HTTPURLResponse)?.statusCode == 200,
              let image = NSImage(data: data), image.size.width > 1, image.size.height > 1 else {
            return nil
        }
        return image.resizedToFit(maxDimension: maxDimension).jpegData(quality: 0.8)
    }

    /// Cap dimension shared with `downloadCoverImage` so callers outside the actor can match it.
    static let coverMaxDimension: CGFloat = 320

    /// Re-encode an already-downloaded image as a capped JPEG cover. Use for thumbnails the
    /// importer fetched itself (e.g. a page's og:image) so they don't land on disk raw and
    /// full-size — an unbounded square og:image (YouTube channel avatars are 900×900) would
    /// otherwise blow out the card grid. Rejects 1×1 tracking pixels / blank images.
    nonisolated static func sanitizedCoverData(_ data: Data) -> Data? {
        guard let image = NSImage(data: data), image.size.width > 1, image.size.height > 1 else {
            return nil
        }
        return image.resizedToFit(maxDimension: coverMaxDimension).jpegData(quality: 0.8)
    }

    // MARK: - Synthetic covers (typographic paper cover + favicon card)

    /// Curated, muted hues — picking from a small harmonious set avoids the neon/magenta a raw
    /// hash-to-hue mapping produces, while still giving each source a stable, distinct color.
    private static let coverHues: [Double] = [0.58, 0.52, 0.42, 0.09, 0.95, 0.70, 0.13, 0.0]

    /// Deterministic, launch-stable hue for a seed string (djb2 → curated palette).
    private static func hue(for seed: String) -> Double {
        var hash: UInt64 = 5381
        for byte in seed.utf8 { hash = (hash &* 33) ^ UInt64(byte) }
        return coverHues[Int(hash % UInt64(coverHues.count))]
    }

    /// A clean typographic cover for a paper/PDF — colored top band with a source kicker, a large
    /// wrapped title, authors, and a year footer. Replaces the illegible shrunk-first-page render.
    func generatePaperCover(title: String, authors: String, kicker: String, footer: String) async -> Data? {
        await withCheckedContinuation { continuation in
            DispatchQueue.main.async {
                continuation.resume(returning: Self.renderPaperCover(
                    title: title, authors: authors, kicker: kicker, footer: footer))
            }
        }
    }

    /// A branded cover for a link with no usable OG image — the site's favicon centered on a
    /// muted tinted card with the host label. Far stronger identity than a generic link glyph.
    func generateFaviconCover(for sourceURL: URL) async -> Data? {
        guard let host = sourceURL.host, !host.isEmpty else { return nil }
        guard let favicon = await fetchFavicon(host: host) else { return nil }
        let label = host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
        return await withCheckedContinuation { continuation in
            DispatchQueue.main.async {
                continuation.resume(returning: Self.renderIconCover(favicon: favicon, label: label, seed: host))
            }
        }
    }

    /// Fetch a high-res favicon via Google's S2 service (returns a generic globe for unknown hosts,
    /// so this is reliably non-nil when the network is up).
    private func fetchFavicon(host: String) async -> NSImage? {
        guard let url = URL(string: "https://www.google.com/s2/favicons?domain=\(host)&sz=128") else { return nil }
        var req = URLRequest(url: url)
        req.timeoutInterval = 10
        req.setValue(Self.browserUserAgent, forHTTPHeaderField: "User-Agent")
        guard let (data, response) = try? await URLSession.shared.data(for: req),
              (response as? HTTPURLResponse)?.statusCode == 200,
              let image = NSImage(data: data), image.size.width > 8 else { return nil }
        return image
    }

    @MainActor
    private static func renderPaperCover(title: String, authors: String, kicker: String, footer: String) -> Data? {
        let size = NSSize(width: 600, height: 800)
        // Seed on the title so every paper gets a distinct color (kicker is often a shared "PDF").
        let hue = hue(for: title)
        let bg = NSColor(hue: hue, saturation: 0.08, brightness: 0.99, alpha: 1)
        let bandTop = NSColor(hue: hue, saturation: 0.46, brightness: 0.80, alpha: 1)
        let bandBottom = NSColor(hue: hue, saturation: 0.58, brightness: 0.62, alpha: 1)
        let titleColor = NSColor(hue: hue, saturation: 0.42, brightness: 0.20, alpha: 1)
        let metaColor = NSColor(hue: hue, saturation: 0.30, brightness: 0.42, alpha: 1)
        let margin: CGFloat = 46

        let image = NSImage(size: size, flipped: true) { _ in
            bg.setFill()
            NSRect(origin: .zero, size: size).fill()

            let bandRect = NSRect(x: 0, y: 0, width: size.width, height: 150)
            (NSGradient(starting: bandTop, ending: bandBottom) ?? NSGradient(colors: [bandTop]))?
                .draw(in: bandRect, angle: -90)

            if !kicker.isEmpty {
                let attrs: [NSAttributedString.Key: Any] = [
                    .font: NSFont.systemFont(ofSize: 26, weight: .heavy),
                    .foregroundColor: NSColor.white,
                ]
                (kicker as NSString).draw(
                    with: NSRect(x: margin, y: 54, width: size.width - margin * 2, height: 44),
                    options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine], attributes: attrs)
            }

            let titlePara = NSMutableParagraphStyle()
            // Word-wrap across lines (truncation happens at the rect bottom via the draw option);
            // .byTruncatingTail here would collapse the title to a single truncated line.
            titlePara.lineBreakMode = .byWordWrapping
            titlePara.lineHeightMultiple = 1.02
            let titleAttrs: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: 46, weight: .bold),
                .foregroundColor: titleColor, .paragraphStyle: titlePara,
            ]
            let titleBox = NSRect(x: margin, y: 200, width: size.width - margin * 2, height: 360)
            let used = (title as NSString).boundingRect(
                with: titleBox.size, options: [.usesLineFragmentOrigin], attributes: titleAttrs)
            (title as NSString).draw(with: titleBox,
                options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine], attributes: titleAttrs)

            if !authors.isEmpty {
                let attrs: [NSAttributedString.Key: Any] = [
                    .font: NSFont.systemFont(ofSize: 25, weight: .medium),
                    .foregroundColor: metaColor,
                ]
                let y = 200 + min(used.height, 360) + 26
                (authors as NSString).draw(
                    with: NSRect(x: margin, y: y, width: size.width - margin * 2, height: 80),
                    options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine], attributes: attrs)
            }

            if !footer.isEmpty {
                let attrs: [NSAttributedString.Key: Any] = [
                    .font: NSFont.systemFont(ofSize: 23, weight: .semibold),
                    .foregroundColor: metaColor,
                ]
                (footer as NSString).draw(
                    with: NSRect(x: margin, y: size.height - 74, width: size.width - margin * 2, height: 44),
                    options: [.usesLineFragmentOrigin], attributes: attrs)
            }
            return true
        }
        return Self.jpeg(image)
    }

    @MainActor
    private static func renderIconCover(favicon: NSImage, label: String, seed: String) -> Data? {
        let size = NSSize(width: 600, height: 440)
        let hue = hue(for: seed)
        let top = NSColor(hue: hue, saturation: 0.34, brightness: 0.97, alpha: 1)
        let bottom = NSColor(hue: hue, saturation: 0.46, brightness: 0.86, alpha: 1)
        let labelColor = NSColor(hue: hue, saturation: 0.55, brightness: 0.34, alpha: 1)

        let image = NSImage(size: size, flipped: true) { _ in
            (NSGradient(starting: top, ending: bottom) ?? NSGradient(colors: [top]))?
                .draw(in: NSRect(origin: .zero, size: size), angle: -90)

            let glyph: CGFloat = 150
            favicon.draw(
                in: NSRect(x: (size.width - glyph) / 2, y: 96, width: glyph, height: glyph),
                from: .zero, operation: .sourceOver, fraction: 1.0)

            let para = NSMutableParagraphStyle()
            para.alignment = .center
            para.lineBreakMode = .byTruncatingTail
            let attrs: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: 24, weight: .semibold),
                .foregroundColor: labelColor, .paragraphStyle: para,
            ]
            (label as NSString).draw(
                with: NSRect(x: 30, y: 286, width: size.width - 60, height: 36),
                options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine], attributes: attrs)
            return true
        }
        return Self.jpeg(image)
    }

    private static func jpeg(_ image: NSImage) -> Data? {
        image.tiffRepresentation
            .flatMap { NSBitmapImageRep(data: $0) }?
            .representation(using: .jpeg, properties: [.compressionFactor: 0.85])
    }

    /// Extract a YouTube video id from watch / youtu.be / shorts / embed URLs.
    static func youTubeVideoID(_ url: URL) -> String? {
        guard let host = url.host?.lowercased() else { return nil }
        if host.contains("youtu.be") {
            return url.pathComponents.dropFirst().first.flatMap { $0.isEmpty ? nil : $0 }
        }
        guard host.contains("youtube.com") else { return nil }
        if let v = URLComponents(url: url, resolvingAgainstBaseURL: false)?
            .queryItems?.first(where: { $0.name == "v" })?.value, !v.isEmpty {
            return v // /watch?v=ID
        }
        let parts = url.pathComponents
        if let i = parts.firstIndex(where: { $0 == "shorts" || $0 == "embed" }), i + 1 < parts.count {
            return parts[i + 1] // /shorts/ID, /embed/ID
        }
        return nil
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
