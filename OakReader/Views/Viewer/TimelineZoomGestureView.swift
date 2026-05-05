import AppKit
import SwiftUI

/// NSViewRepresentable that captures Cmd+scroll-wheel and trackpad-pinch events
/// to drive timeline zoom without interfering with the parent ScrollView.
struct TimelineZoomGestureView: NSViewRepresentable {
    @Binding var zoomLevel: CGFloat

    func makeNSView(context: Context) -> ZoomGestureNSView {
        let view = ZoomGestureNSView()
        view.onZoomDelta = { delta in
            let newZoom = zoomLevel * (1.0 + delta)
            zoomLevel = min(max(newZoom, 1.0), 20.0)
        }
        return view
    }

    func updateNSView(_ nsView: ZoomGestureNSView, context: Context) {
        nsView.onZoomDelta = { delta in
            let newZoom = zoomLevel * (1.0 + delta)
            zoomLevel = min(max(newZoom, 1.0), 20.0)
        }
    }
}

final class ZoomGestureNSView: NSView {
    var onZoomDelta: ((CGFloat) -> Void)?

    private var scrollMonitor: Any?
    private var magnifyMonitor: Any?

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window != nil {
            installMonitors()
        } else {
            removeMonitors()
        }
    }

    private func installMonitors() {
        removeMonitors()

        scrollMonitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
            guard let self,
                  event.modifierFlags.contains(.command) else { return event }

            let locationInView = self.convert(event.locationInWindow, from: nil)
            guard self.bounds.contains(locationInView) else { return event }

            let delta = event.scrollingDeltaY
            guard abs(delta) > 0.01 else { return nil }

            let zoomDelta = delta * 0.015
            self.onZoomDelta?(zoomDelta)
            return nil
        }

        magnifyMonitor = NSEvent.addLocalMonitorForEvents(matching: .magnify) { [weak self] event in
            guard let self else { return event }

            let locationInView = self.convert(event.locationInWindow, from: nil)
            guard self.bounds.contains(locationInView) else { return event }

            self.onZoomDelta?(event.magnification)
            return nil
        }
    }

    private func removeMonitors() {
        if let monitor = scrollMonitor {
            NSEvent.removeMonitor(monitor)
            scrollMonitor = nil
        }
        if let monitor = magnifyMonitor {
            NSEvent.removeMonitor(monitor)
            magnifyMonitor = nil
        }
    }

    deinit {
        removeMonitors()
    }
}
