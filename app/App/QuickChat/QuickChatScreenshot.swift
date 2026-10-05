import AppKit

/// Region capture for Quick Chat.
///
/// Shells out to `/usr/sbin/screencapture -i` rather than drawing an overlay or
/// calling ScreenCaptureKit. Two reasons, and the second is the important one:
///
/// - It *is* the macOS screenshot UI — the crosshair, Space to switch to window
///   mode, Esc to cancel. Nothing to learn and nothing to build; Cida's
///   hand-rolled equivalent is 373 lines of frozen-screen and paper-lift work.
/// - The capture happens inside Apple's own binary, so OakReader does not have
///   to hold Screen Recording permission itself. Asking for that on top of
///   Accessibility would be a second alarming prompt for one feature.
enum QuickChatScreenshot {

    /// Presents the system region picker and returns PNG data, or nil when the
    /// user cancelled with Esc or a bare click.
    static func captureRegion() async -> Data? {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("quickchat-\(UUID().uuidString).png")

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
        // -i interactive, -x no shutter sound, -o no window shadow when a window
        // is picked with Space (the shadow is wasted pixels and wasted tokens).
        process.arguments = ["-i", "-x", "-o", url.path]

        // The handler is installed before the process starts. Set afterwards it
        // is a race: `screencapture` can exit first — Esc, or a bare click —
        // and the handler then never fires, leaving the await hung forever and
        // the panel never opening.
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            process.terminationHandler = { _ in continuation.resume() }
            do {
                try process.run()
            } catch {
                Log.error(Log.ui, "screencapture failed to launch: \(error.localizedDescription)")
                process.terminationHandler = nil
                continuation.resume()
            }
        }

        defer { try? FileManager.default.removeItem(at: url) }
        // Cancelling writes no file at all, which is how cancellation is
        // detected — `screencapture` exits 0 either way.
        guard let data = try? Data(contentsOf: url), !data.isEmpty else { return nil }
        return downscaled(data) ?? data
    }

    /// Caps the long edge so a Retina grab of a full screen does not become a
    /// multi-megabyte upload. Vision models gain nothing from pixels beyond
    /// this, and the base64 round-trip is the slowest part of the request.
    private static let maxEdge: CGFloat = 1600

    private static func downscaled(_ data: Data) -> Data? {
        guard let image = NSBitmapImageRep(data: data) else { return nil }
        let width = CGFloat(image.pixelsWide)
        let height = CGFloat(image.pixelsHigh)
        let longest = max(width, height)
        guard longest > maxEdge else {
            return image.representation(using: .png, properties: [:])
        }

        let scale = maxEdge / longest
        let target = NSSize(width: floor(width * scale), height: floor(height * scale))
        guard let context = CGContext(
            data: nil,
            width: Int(target.width), height: Int(target.height),
            bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ), let cgImage = image.cgImage else { return nil }

        context.interpolationQuality = .high
        context.draw(cgImage, in: CGRect(origin: .zero, size: target))
        guard let scaled = context.makeImage() else { return nil }
        return NSBitmapImageRep(cgImage: scaled).representation(using: .png, properties: [:])
    }
}
