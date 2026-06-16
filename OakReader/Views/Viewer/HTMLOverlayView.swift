import SwiftUI
import WebKit

struct HTMLOverlayView: View {
    let viewModel: DocumentViewModel

    @State private var isDragging = false
    @State private var showSelection = false
    @State private var dragStart = CGPoint.zero
    @State private var dragEnd = CGPoint.zero

    var body: some View {
        ZStack {
            // Transparent hit-test area that only captures drags, passes scroll events through
            HTMLHitTestView(
                isActive: viewModel.state.editorMode == .snapshot,
                onDragChanged: { start, current in
                    if !isDragging {
                        isDragging = true
                        showSelection = false
                        dragStart = start
                    }
                    dragEnd = current
                },
                onDragEnded: { start, end in
                    dragEnd = end
                    isDragging = false
                    showSelection = true
                    finishSelection()
                },
                onCancel: { viewModel.setEditorMode(.viewer) }
            )

            // Selection rectangle (dashed border while dragging or popup is open)
            if isDragging || showSelection {
                let rect = normalizedRect(from: dragStart, to: dragEnd)
                Rectangle()
                    .strokeBorder(
                        Color.secondary,
                        style: StrokeStyle(lineWidth: 1.5, dash: [6, 3])
                    )
                    .frame(width: rect.width, height: rect.height)
                    .position(x: rect.midX, y: rect.midY)
                    .allowsHitTesting(false)
            }
        }
    }

    private func normalizedRect(from start: CGPoint, to end: CGPoint) -> CGRect {
        CGRect(
            x: min(start.x, end.x),
            y: min(start.y, end.y),
            width: abs(end.x - start.x),
            height: abs(end.y - start.y)
        )
    }

    private func finishSelection() {
        let selectionRect = normalizedRect(from: dragStart, to: dragEnd)
        guard selectionRect.width > 10, selectionRect.height > 10 else {
            showSelection = false
            return
        }

        guard let window = NSApp.keyWindow,
              let webView = findWebView(in: window.contentView),
              let hitTestView = findHTMLHitTestView(in: window.contentView) else {
            showSelection = false
            return
        }

        // Convert from flipped overlay coords (SwiftUI, Y-down) to NSView coords (AppKit, Y-up)
        let overlayHeight = hitTestView.bounds.height
        let nsPoint1 = NSPoint(x: selectionRect.minX, y: overlayHeight - selectionRect.minY)
        let nsPoint2 = NSPoint(x: selectionRect.maxX, y: overlayHeight - selectionRect.maxY)

        // Convert from overlay NSView coords → WKWebView coords
        let webViewPoint1 = hitTestView.convert(nsPoint1, to: webView)
        let webViewPoint2 = hitTestView.convert(nsPoint2, to: webView)

        // Build the capture rect in WKWebView coordinates (Y-up AppKit)
        let captureRect = CGRect(
            x: min(webViewPoint1.x, webViewPoint2.x),
            y: min(webViewPoint1.y, webViewPoint2.y),
            width: abs(webViewPoint2.x - webViewPoint1.x),
            height: abs(webViewPoint2.y - webViewPoint1.y)
        )

        guard captureRect.width > 1, captureRect.height > 1 else {
            showSelection = false
            return
        }

        // WKSnapshotConfiguration uses flipped coords (Y-down from top of webView)
        let webViewHeight = webView.bounds.height
        let snapshotRect = CGRect(
            x: captureRect.origin.x,
            y: webViewHeight - captureRect.origin.y - captureRect.height,
            width: captureRect.width,
            height: captureRect.height
        )

        // Get screen position for popup (bottom-center of selection in screen coords)
        let bottomCenterNS = NSPoint(
            x: (nsPoint1.x + nsPoint2.x) / 2,
            y: min(nsPoint1.y, nsPoint2.y)
        )
        let windowPoint = hitTestView.convert(bottomCenterNS, to: nil)
        let screenPoint = window.convertPoint(toScreen: windowPoint)

        // Capture the region via WKWebView snapshot
        let config = WKSnapshotConfiguration()
        config.rect = snapshotRect

        // Use device pixel ratio for sharp captures
        if let backingScale = webView.window?.backingScaleFactor {
            config.snapshotWidth = NSNumber(value: Double(snapshotRect.width) * Double(backingScale))
        }

        webView.takeSnapshot(with: config) { [viewModel, self] image, error in
            guard let image, error == nil,
                  let tiffData = image.tiffRepresentation,
                  let bitmap = NSBitmapImageRep(data: tiffData),
                  let pngData = bitmap.representation(using: .png, properties: [:]) else {
                DispatchQueue.main.async { self.showSelection = false }
                return
            }

            DispatchQueue.main.async {
                self.showSelection = false
                if viewModel.state.snapshotForNote {
                    viewModel.deliverAreaCaptureToNote(pngData, pageIndex: 0)
                } else if viewModel.state.snapshotForChat {
                    viewModel.deliverAreaCaptureToChat(pngData, pageIndex: 0)
                } else {
                    WebAreaPopupPanel.show(
                        at: screenPoint,
                        imageData: pngData,
                        viewModel: viewModel,
                        onDismiss: {}
                    )
                }
            }
        }
    }

    private func findWebView(in view: NSView?) -> WKWebView? {
        guard let view else { return nil }
        if let webView = view as? WKWebView { return webView }
        for subview in view.subviews {
            if let found = findWebView(in: subview) { return found }
        }
        return nil
    }

    private func findHTMLHitTestView(in view: NSView?) -> HTMLHitTestNSView? {
        guard let view else { return nil }
        if let hitView = view as? HTMLHitTestNSView { return hitView }
        for subview in view.subviews {
            if let found = findHTMLHitTestView(in: subview) { return found }
        }
        return nil
    }
}

// MARK: - SwiftUI wrapper

private struct HTMLHitTestView: NSViewRepresentable {
    let isActive: Bool
    let onDragChanged: (_ start: CGPoint, _ current: CGPoint) -> Void
    let onDragEnded: (_ start: CGPoint, _ end: CGPoint) -> Void
    let onCancel: () -> Void

    func makeNSView(context: Context) -> HTMLHitTestNSView {
        let view = HTMLHitTestNSView()
        view.onDragChanged = onDragChanged
        view.onDragEnded = onDragEnded
        view.onCancel = onCancel
        view.isActive = isActive
        return view
    }

    func updateNSView(_ nsView: HTMLHitTestNSView, context: Context) {
        nsView.onDragChanged = onDragChanged
        nsView.onDragEnded = onDragEnded
        nsView.onCancel = onCancel
        nsView.updateActive(isActive)
    }
}

// MARK: - Hit-test NSView for WKWebView area selection

/// Transparent overlay that uses an NSEvent monitor to capture mouse drags
/// for area selection, while letting ALL other events (scroll, etc.) pass through
/// to the WKWebView naturally.
class HTMLHitTestNSView: NSView {
    var isActive = false
    var onDragChanged: ((_ start: CGPoint, _ current: CGPoint) -> Void)?
    var onDragEnded: ((_ start: CGPoint, _ end: CGPoint) -> Void)?
    var onCancel: (() -> Void)?

    private var mouseMonitor: Any?
    private var dragStartPoint: CGPoint?  // in flipped (SwiftUI) coords
    private var isDragging = false

    // Always transparent to hit-testing — never blocks scroll events
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    func updateActive(_ active: Bool) {
        let wasActive = isActive
        isActive = active
        if active && !wasActive {
            installMonitor()
        } else if !active && wasActive {
            removeMonitor()
        }
        window?.invalidateCursorRects(for: self)
        updateTrackingAreas()
    }

    private func installMonitor() {
        removeMonitor()
        mouseMonitor = NSEvent.addLocalMonitorForEvents(
            matching: [.leftMouseDown, .leftMouseDragged, .leftMouseUp, .keyDown]
        ) { [weak self] event in
            guard let self, self.isActive else { return event }
            if event.type == .keyDown {
                if event.keyCode == 53 {  // Escape cancels the capture
                    self.onCancel?()
                    return nil
                }
                return event
            }
            return self.handleMouseEvent(event)
        }
        setCaptureCursor(true)
    }

    private func removeMonitor() {
        if let monitor = mouseMonitor {
            NSEvent.removeMonitor(monitor)
            mouseMonitor = nil
        }
        setCaptureCursor(false)
        dragStartPoint = nil
        isDragging = false
    }

    /// The WKWebView owns its cursor via CSS, so a native crosshair set on this
    /// transparent overlay is overridden. Force a `cursor: crosshair` on the page
    /// itself while capture is armed.
    private weak var capturedWebView: WKWebView?
    private func setCaptureCursor(_ on: Bool) {
        if on {
            let webView = capturedWebView ?? findWebView(in: window?.contentView)
            capturedWebView = webView
            Log.debug(Log.ui, "[capture-cursor] HTML on — webView found: \(webView != nil)")
            webView?.evaluateJavaScript(WebCaptureCursor.js(on: true)) { _, error in
                if let error { Log.debug(Log.ui, "[capture-cursor] HTML on JS error: \(error)") }
            }
        } else {
            capturedWebView?.evaluateJavaScript(WebCaptureCursor.js(on: false), completionHandler: nil)
            capturedWebView = nil
        }
    }

    private func findWebView(in view: NSView?) -> WKWebView? {
        guard let view else { return nil }
        if let webView = view as? WKWebView { return webView }
        for subview in view.subviews {
            if let found = findWebView(in: subview) { return found }
        }
        return nil
    }

    private func handleMouseEvent(_ event: NSEvent) -> NSEvent? {
        // Only intercept events targeting our own window
        guard event.window === self.window else { return event }

        let localPoint = convert(event.locationInWindow, from: nil)
        let flipped = CGPoint(x: localPoint.x, y: bounds.height - localPoint.y)

        switch event.type {
        case .leftMouseDown:
            guard bounds.contains(localPoint) else { return event }
            dragStartPoint = flipped
            isDragging = false
            return nil

        case .leftMouseDragged:
            guard dragStartPoint != nil else { return event }
            onDragChanged?(dragStartPoint!, flipped)
            isDragging = true
            return nil

        case .leftMouseUp:
            guard let start = dragStartPoint else { return event }
            dragStartPoint = nil
            if isDragging {
                isDragging = false
                let distance = hypot(flipped.x - start.x, flipped.y - start.y)
                if distance >= 5 {
                    onDragEnded?(start, flipped)
                }
            }
            return nil

        default:
            return event
        }
    }

    override func resetCursorRects() {
        if isActive {
            addCursorRect(bounds, cursor: .crosshair)
        }
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        for area in trackingAreas { removeTrackingArea(area) }
        if isActive {
            let area = NSTrackingArea(
                rect: bounds,
                options: [.activeInKeyWindow, .cursorUpdate, .inVisibleRect],
                owner: self
            )
            addTrackingArea(area)
        }
    }

    override func cursorUpdate(with event: NSEvent) {
        if isActive {
            NSCursor.crosshair.set()
        } else {
            super.cursorUpdate(with: event)
        }
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if isActive && window != nil {
            installMonitor()
        } else if window == nil {
            removeMonitor()
        }
    }

    deinit {
        removeMonitor()
    }
}

// MARK: - Web capture cursor

/// JS that forces the capture cursor on a WKWebView page while area capture is
/// armed. Uses CSSOM `style.setProperty(..., 'important')` — which works even
/// under a strict Content-Security-Policy that would block an injected
/// `<style>` element — and *also* injects a `*{cursor}` stylesheet so links and
/// buttons (which carry their own cursor) are covered when CSP permits it.
enum WebCaptureCursor {
    static func js(on: Bool) -> String {
        on ? onJS : offJS
    }

    private static var onJS: String {
        // The value is `url("data:…") x y, crosshair` — JSON-encode it so the
        // embedded quotes are safe inside the JS string literal.
        let cssValue = jsStringLiteral(CaptureCursor.cssCursorValue)
        return """
        (function(){try{
          var c=\(cssValue);
          document.documentElement.style.setProperty('cursor', c, 'important');
          if(document.body){document.body.style.setProperty('cursor', c, 'important');}
          var id='oak-capture-cursor';
          if(!document.getElementById(id)){
            var s=document.createElement('style');
            s.id=id;
            s.textContent='*{cursor:'+c+' !important;}';
            (document.head||document.documentElement).appendChild(s);
          }
        }catch(e){}})();
        """
    }

    private static let offJS = """
    (function(){try{
      document.documentElement.style.removeProperty('cursor');
      if(document.body){document.body.style.removeProperty('cursor');}
      var e=document.getElementById('oak-capture-cursor');
      if(e){e.remove();}
    }catch(e){}})();
    """

    /// Encode a Swift string as a safe double-quoted JS string literal.
    private static func jsStringLiteral(_ s: String) -> String {
        var out = "\""
        for ch in s {
            switch ch {
            case "\\": out += "\\\\"
            case "\"": out += "\\\""
            case "\n": out += "\\n"
            case "\r": out += "\\r"
            default: out.append(ch)
            }
        }
        out += "\""
        return out
    }
}

// MARK: - Capture cursor

/// Area-capture cursor — the native macOS crosshair (the thin, precise `+` the
/// system screenshot tool uses). Exposed as both an `NSCursor` (for the PDF
/// overlay) and a CSS `cursor` keyword (injected into web pages) so the PDF and
/// web capture paths show the exact same clean cursor.
enum CaptureCursor {
    static let nsCursor: NSCursor = .crosshair
    static let cssCursorValue = "crosshair"
}
