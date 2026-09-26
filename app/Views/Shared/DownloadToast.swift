import AppKit
import SwiftUI

/// A larger, longer-lived toast for finished/failed browser downloads — distinct
/// from the brief `showHUDToast` used for clipboard feedback. Anchored bottom-
/// centre of the key window as a glass card; success toasts reveal the file in
/// Finder when clicked.
@MainActor
func showDownloadToast(fileURL: URL) {
    DownloadToast(kind: .success(fileURL)).show()
}

@MainActor
func showDownloadFailedToast(reason: String) {
    DownloadToast(kind: .failure(reason)).show()
}

/// Handles the toast click in AppKit instead of via a SwiftUI button. On a
/// borderless floating panel a real click never reaches SwiftUI's inner hit view,
/// so the whole card claims hit-testing here and reveals on `mouseDown`, with
/// `acceptsFirstMouse` so even the first click counts. The panel is deliberately
/// left non-key: if it became key, dismissing it would reshuffle window focus and
/// clear the selection Finder just made on reveal.
private final class FirstMouseHostingView<Content: View>: NSHostingView<Content> {
    var onClick: (() -> Void)?
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { frame.contains(point) ? self : nil }
    override func mouseDown(with event: NSEvent) { onClick?() }
}

/// Owns one toast panel for its on-screen lifetime. Kept alive in `live` until it
/// fades out (the auto-dismiss timer and the reveal click both route through
/// `dismiss`), then released.
@MainActor
private final class DownloadToast: NSObject {
    enum Kind { case success(URL), failure(String) }

    private static var live: Set<DownloadToast> = []

    /// Visible duration for an actionable toast — the 5s design-system default
    /// (toasts with an action lean to the longer end of the 2–6s range).
    private static let duration: TimeInterval = 5.0

    private let kind: Kind
    private let panel: NSPanel
    private var dismissed = false
    private var dismissWork: DispatchWorkItem?

    init(kind: Kind) {
        self.kind = kind
        panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 100, height: 100),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: true
        )
        super.init()

        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.level = .floating

        let host = FirstMouseHostingView(
            rootView: DownloadToastView(
                kind: kind,
                onHover: { [weak self] hovering in self?.setPaused(hovering) }
            )
        )
        host.onClick = { [weak self] in self?.reveal() }
        host.setFrameSize(host.fittingSize)
        panel.setContentSize(host.fittingSize)
        host.autoresizingMask = [.width, .height]
        panel.contentView?.addSubview(host)
    }

    func show() {
        guard let window = NSApp.keyWindow else { return }
        Self.live.insert(self)

        let win = window.frame
        let size = panel.frame.size
        panel.setFrameOrigin(NSPoint(x: win.midX - size.width / 2, y: win.minY + 24))
        panel.alphaValue = 0
        panel.orderFront(nil)

        NSAnimationContext.runAnimationGroup { $0.duration = 0.25; panel.animator().alphaValue = 1 }
        scheduleDismiss(after: Self.duration)
    }

    /// Pause the auto-dismiss while the pointer rests on the toast, so the user
    /// controls reading time; restart a shorter countdown once they leave.
    private func setPaused(_ paused: Bool) {
        guard !dismissed else { return }
        if paused {
            dismissWork?.cancel()
        } else {
            scheduleDismiss(after: 2.0)
        }
    }

    private func scheduleDismiss(after delay: TimeInterval) {
        dismissWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.dismiss() }
        dismissWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    private func reveal() {
        // Canonical Finder reveal — opens the parent folder and selects the file.
        // Not sandbox-restricted; a no-op if the path no longer exists.
        if case let .success(url) = kind {
            NSWorkspace.shared.activateFileViewerSelecting([url])
        }
        dismiss()
    }

    private func dismiss() {
        guard !dismissed else { return }
        dismissed = true
        NSAnimationContext.runAnimationGroup {
            $0.duration = 0.35
            panel.animator().alphaValue = 0
        } completionHandler: { [self] in
            panel.orderOut(nil)
            Self.live.remove(self)
        }
    }
}

private struct DownloadToastView: View {
    let kind: DownloadToast.Kind
    let onHover: (Bool) -> Void
    @State private var hovering = false

    private var isSuccess: Bool { if case .success = kind { return true } else { return false } }

    private var subtitle: String {
        switch kind {
        case let .success(url):
            return "\(url.deletingLastPathComponent().lastPathComponent)/\(url.lastPathComponent)"
        case let .failure(reason):
            return reason
        }
    }

    var body: some View {
        HStack(spacing: 10) {
            ZStack {
                Circle().fill(isSuccess ? Color.green : Color.red)
                Image(systemName: isSuccess ? "arrow.down" : "exclamationmark")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(.white)
            }
            .frame(width: 26, height: 26)

            VStack(alignment: .leading, spacing: 1) {
                Text(isSuccess ? "Download complete" : "Download failed")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.primary)
                Text(subtitle)
                    .font(.system(size: 10.5))
                    .foregroundStyle(.primary.opacity(0.6))
                    .lineLimit(2)
                    .truncationMode(.middle)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .frame(width: 280, alignment: .leading)
        // Opaque material + a backing fill so the text keeps full contrast no
        // matter how dark the page behind the floating panel is.
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(.background))
        .background(.thickMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color.primary.opacity(hovering && isSuccess ? 0.05 : 0))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.08))
        )
        .scaleEffect(hovering && isSuccess ? 1.02 : 1)
        .animation(.easeOut(duration: 0.12), value: hovering)
        .contentShape(Rectangle())
        .onHover { hovering = $0; onHover($0) }
        .help(isSuccess ? "Show in Finder" : "")
        .padding(6) // small inset so the rounded card isn't flush to the panel edge
    }
}
