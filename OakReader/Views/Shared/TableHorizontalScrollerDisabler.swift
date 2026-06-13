import SwiftUI
import AppKit

/// Hides the horizontal scroller on the nearest enclosing `Table`'s scroll view.
///
/// SwiftUI's `Table` (NSTableView-backed) sometimes lays out its columns against the
/// scroll view's full width without subtracting a legacy vertical scroller, leaving a
/// few points of horizontal overflow and a spurious horizontal scroll bar. Columns can
/// always compress to their `min` widths, so horizontal scrolling is never needed.
///
/// Usage: `Table { ... }.background(TableHorizontalScrollerDisabler())`
struct TableHorizontalScrollerDisabler: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        let probe = ProbeView()
        probe.onMoveToWindow = { [weak probe] in
            guard let probe else { return }
            context.coordinator.attach(from: probe)
        }
        return probe
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        context.coordinator.attach(from: nsView)
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    /// Reports when it lands in a window, which is when the sibling Table's
    /// AppKit hierarchy is guaranteed to exist.
    final class ProbeView: NSView {
        var onMoveToWindow: (() -> Void)?
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if window != nil { onMoveToWindow?() }
        }
    }

    @MainActor
    final class Coordinator {
        private weak var scrollView: NSScrollView?
        private var observers: [NSObjectProtocol] = []

        func attach(from probe: NSView) {
            guard let target = Self.findTableScrollView(from: probe) else {
                // The table's AppKit hierarchy can lag the probe's; retry shortly.
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self, weak probe] in
                    guard let self, let probe, self.scrollView == nil else { return }
                    self.attach(from: probe)
                }
                return
            }
            if target !== scrollView {
                for observer in observers { NotificationCenter.default.removeObserver(observer) }
                observers.removeAll()
                scrollView = target
                target.postsFrameChangedNotifications = true
                target.contentView.postsBoundsChangedNotifications = true
                // SwiftUI re-enables the scroller on its own layout/content passes;
                // re-apply whenever the scroll view resizes or its content shifts.
                for name in [NSView.frameDidChangeNotification, NSView.boundsDidChangeNotification] {
                    let object: NSView = name == NSView.boundsDidChangeNotification
                        ? target.contentView : target
                    observers.append(NotificationCenter.default.addObserver(
                        forName: name, object: object, queue: .main
                    ) { [weak self] _ in
                        MainActor.assumeIsolated { self?.apply() }
                    })
                }
            }
            apply()
        }

        private func apply() {
            guard let scrollView else { return }
            if scrollView.hasHorizontalScroller {
                scrollView.hasHorizontalScroller = false
            }
            if scrollView.horizontalScrollElasticity != .none {
                scrollView.horizontalScrollElasticity = .none
            }
            // Also remove the underlying overflow so content can't pan sideways:
            // compress the last column until the table fits the clip view.
            if let tableView = scrollView.documentView as? NSTableView {
                let clipWidth = scrollView.contentView.bounds.width
                if tableView.frame.width > clipWidth {
                    tableView.sizeLastColumnToFit()
                }
            }
        }

        /// Walks up from the probe (placed in the table's `.background`) and searches each
        /// ancestor subtree for the table's scroll view. The header-view check excludes
        /// `List`-backed table views (e.g. the sidebar), which have no column header.
        private static func findTableScrollView(from probe: NSView) -> NSScrollView? {
            var ancestor = probe.superview
            while let current = ancestor {
                if let found = searchTableScrollView(in: current) { return found }
                ancestor = current.superview
            }
            return nil
        }

        private static func searchTableScrollView(in view: NSView) -> NSScrollView? {
            if let scrollView = view as? NSScrollView,
               let tableView = scrollView.documentView as? NSTableView,
               tableView.headerView != nil {
                return scrollView
            }
            for subview in view.subviews {
                if let found = searchTableScrollView(in: subview) { return found }
            }
            return nil
        }

        deinit {
            for observer in observers { NotificationCenter.default.removeObserver(observer) }
        }
    }
}
