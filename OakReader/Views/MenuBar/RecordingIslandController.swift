import Cocoa
import SwiftUI

final class RecordingIslandController {
    let model = RecordingIslandModel()

    private var panel: NSPanel?
    private var clickMonitor: Any?
    private var moveMonitor: Any?
    private var screenObserver: NSObjectProtocol?

    // MARK: - Public

    func show(on screen: NSScreen? = NSScreen.main) {
        guard let screen else { return }
        detectNotch(screen: screen)

        if panel == nil {
            createPanel(screen: screen)
        }
        updatePosition(screen: screen)

        model.state = .collapsed
        panel?.orderFrontRegardless()

        installEventMonitors()
        observeScreenChanges()
    }

    func hide() {
        model.state = .hidden
        // Delay removal so the SwiftUI view can animate out if desired
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { [weak self] in
            self?.panel?.orderOut(nil)
        }
        removeEventMonitors()
        removeScreenObserver()
    }

    func updatePosition() {
        guard let screen = NSScreen.main else { return }
        detectNotch(screen: screen)
        updatePosition(screen: screen)
    }

    deinit {
        removeEventMonitors()
        removeScreenObserver()
        panel?.orderOut(nil)
        panel = nil
    }

    // MARK: - Panel Creation

    private func createPanel(screen: NSScreen) {
        // Use a large frame so SwiftUI handles visual sizing via the view
        let maxWidth: CGFloat = 360
        let maxHeight: CGFloat = 200

        let panel = IslandPanel(
            contentRect: NSRect(x: 0, y: 0, width: maxWidth, height: maxHeight),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.level = .statusBar
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = false
        panel.ignoresMouseEvents = false
        panel.collectionBehavior = [
            .canJoinAllSpaces,
            .stationary,
            .fullScreenAuxiliary,
            .ignoresCycle
        ]
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = false
        panel.animationBehavior = .none

        let hostingView = NSHostingView(
            rootView: RecordingIslandView(
                model: model,
                onStop: { [weak self] in
                    self?.onStopRequested?()
                }
            )
        )
        hostingView.frame = panel.contentView?.bounds ?? .zero
        hostingView.autoresizingMask = [.width, .height]
        panel.contentView?.addSubview(hostingView)

        self.panel = panel
    }

    /// Called by MenuBarRecorder to wire up the stop action.
    var onStopRequested: (() -> Void)?

    // MARK: - Notch Detection

    private func detectNotch(screen: NSScreen) {
        let safeTop = screen.safeAreaInsets.top
        if safeTop > 0 {
            model.isNotchedDisplay = true
            // Calculate notch width from auxiliary areas
            let auxLeft = screen.auxiliaryTopLeftArea?.width ?? 0
            let auxRight = screen.auxiliaryTopRightArea?.width ?? 0
            let screenWidth = screen.frame.width
            let notchWidth = screenWidth - auxLeft - auxRight
            model.notchWidth = max(notchWidth, 180)
            model.notchHeight = safeTop
        } else {
            model.isNotchedDisplay = false
            model.notchWidth = 180
            model.notchHeight = 32
        }
    }

    // MARK: - Positioning

    private func updatePosition(screen: NSScreen) {
        guard let panel else { return }

        let panelWidth = panel.frame.width
        let panelHeight = panel.frame.height
        let screenFrame = screen.frame

        // Center horizontally on screen
        let x = screenFrame.midX - panelWidth / 2

        // Position at the very top of the screen
        let y: CGFloat
        if model.isNotchedDisplay {
            // Flush with top of screen (notch area)
            y = screenFrame.maxY - panelHeight
        } else {
            // 8pt below the menu bar top (menu bar is ~24pt)
            let menuBarHeight: CGFloat = NSStatusBar.system.thickness
            y = screenFrame.maxY - menuBarHeight - 8 - panelHeight
        }

        panel.setFrameOrigin(NSPoint(x: x, y: y))
    }

    // MARK: - Event Monitors

    private func installEventMonitors() {
        removeEventMonitors()

        // Global click monitor — collapse when clicking outside the panel
        clickMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] event in
            guard let self, let panel = self.panel else { return }
            let locationInScreen = event.locationInWindow
            // Global events have location in screen coords
            if !panel.frame.contains(locationInScreen) {
                self.model.collapse()
            }
        }

        // Local click monitor — toggle expand/collapse on click
        moveMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown]) { [weak self] event in
            guard let self, let panel = self.panel, event.window === panel else { return event }
            self.model.toggle()
            return event
        }
    }

    private func removeEventMonitors() {
        if let clickMonitor {
            NSEvent.removeMonitor(clickMonitor)
            self.clickMonitor = nil
        }
        if let moveMonitor {
            NSEvent.removeMonitor(moveMonitor)
            self.moveMonitor = nil
        }
    }

    // MARK: - Screen Change Observation

    private func observeScreenChanges() {
        removeScreenObserver()
        screenObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.updatePosition()
        }
    }

    private func removeScreenObserver() {
        if let screenObserver {
            NotificationCenter.default.removeObserver(screenObserver)
            self.screenObserver = nil
        }
    }
}

// MARK: - Island Panel

/// Custom NSPanel subclass that can become key (for click handling)
/// but never becomes main window.
private final class IslandPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}
