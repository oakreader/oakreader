import Cocoa
import PDFKit
import UniformTypeIdentifiers
import SwiftUI

class AppDelegate: NSObject, NSApplicationDelegate {
    let documentController = PDFDocumentController()
    let appState = AppState()
    private var mainWindow: NSWindow?

    func applicationWillFinishLaunching(_ notification: Notification) {
        documentController.appState = appState
        NSApp.mainMenu = MainMenuBuilder.build(target: self)
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Run one-time migration from old SwiftData storage
        let migration = MigrationService(store: appState.libraryStore, coverService: appState.coverService)
        migration.migrateIfNeeded()

        createMainWindow()
    }

    func applicationShouldOpenUntitledFile(_ sender: NSApplication) -> Bool {
        false
    }

    func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool {
        true
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag {
            mainWindow?.makeKeyAndOrderFront(nil)
        }
        return true
    }

    // MARK: - Window Creation

    private func createMainWindow() {
        let rootView = RootView(appState: appState)
        let hostingController = NSHostingController(rootView: rootView)
        // Prevent hosting controller from shrinking the window to fit content
        hostingController.sizingOptions = []

        let screen = NSScreen.main ?? NSScreen.screens.first
        let screenFrame = screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let windowWidth = screenFrame.width * 0.85
        let windowHeight = screenFrame.height * 0.9

        let window = NSWindow(
            contentRect: NSRect(
                x: screenFrame.origin.x + (screenFrame.width - windowWidth) / 2,
                y: screenFrame.origin.y + (screenFrame.height - windowHeight) / 2,
                width: windowWidth,
                height: windowHeight
            ),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.contentViewController = hostingController
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.titlebarSeparatorStyle = .none
        window.backgroundColor = NSColor(srgbRed: 242/255, green: 242/255, blue: 242/255, alpha: 1)
        window.styleMask.insert(.fullSizeContentView)
        window.minSize = NSSize(width: 800, height: 500)
        window.title = ""

        window.makeKeyAndOrderFront(nil)

        // Restore saved frame if available, otherwise use the computed large frame
        if !window.setFrameUsingName("OakReaderMainWindow") {
            // No saved frame — set explicit frame and center
            window.setFrame(NSRect(
                x: screenFrame.origin.x + (screenFrame.width - windowWidth) / 2,
                y: screenFrame.origin.y + (screenFrame.height - windowHeight) / 2,
                width: windowWidth,
                height: windowHeight
            ), display: true)
        }
        window.setFrameAutosaveName("OakReaderMainWindow")

        self.mainWindow = window
        appState.window = window

        // Center traffic lights vertically with the tab bar
        centerTrafficLights()
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(windowDidResize(_:)),
            name: NSWindow.didResizeNotification,
            object: window
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(windowDidResize(_:)),
            name: NSWindow.didEndLiveResizeNotification,
            object: window
        )
    }

    // MARK: - Traffic Light Positioning

    @objc private func windowDidResize(_ notification: Notification) {
        centerTrafficLights()
    }

    private func centerTrafficLights() {
        guard let window = mainWindow else { return }
        let tabBarHeight: CGFloat = 38.0 // OakStyle.Size.tabBarHeight

        for buttonType: NSWindow.ButtonType in [.closeButton, .miniaturizeButton, .zoomButton] {
            guard let button = window.standardWindowButton(buttonType) else { continue }
            guard let titleBarView = button.superview else { continue }
            let titleBarHeight = titleBarView.frame.height
            let buttonHeight = button.frame.height
            // Center button in tab bar: convert from tab bar top-down to NSView bottom-up
            let desiredCenterFromTop = tabBarHeight / 2
            let centerFromBottom = titleBarHeight - desiredCenterFromTop
            let buttonY = centerFromBottom - buttonHeight / 2
            button.setFrameOrigin(NSPoint(x: button.frame.origin.x, y: buttonY))
        }
    }

    // MARK: - File Actions

    @objc func newBlankDocument(_ sender: Any?) {
        appState.openBlankDocument()
    }

    @objc func openDocument(_ sender: Any?) {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.pdf]
        panel.allowsMultipleSelection = true
        panel.begin { [weak self] response in
            guard response == .OK else { return }
            for url in panel.urls {
                self?.appState.openDocument(url: url)
            }
        }
    }

    @objc func saveDocument(_ sender: Any?) {
        appState.activeTab?.document.save(sender)
    }

    @objc func saveDocumentAs(_ sender: Any?) {
        appState.activeTab?.document.saveAs(sender)
    }

    @objc func revertDocument(_ sender: Any?) {
        appState.activeTab?.document.revertToSaved(sender)
    }

    @objc func printDocument(_ sender: Any?) {
        appState.activeTab?.document.printDocument(sender)
    }

    @objc func closeTab(_ sender: Any?) {
        if !appState.isLibraryActive {
            appState.closeActiveTab()
        }
    }

    @objc func showLibrary(_ sender: Any?) {
        appState.switchToLibrary()
    }

    @objc func nextTab(_ sender: Any?) {
        appState.nextTab()
    }

    @objc func previousTab(_ sender: Any?) {
        appState.previousTab()
    }

    @objc func exportAsImages(_ sender: Any?) {
        appState.dispatchAction(.exportImages)
    }

    @objc func exportAsText(_ sender: Any?) {
        guard let doc = appState.activeTab?.document,
              let pdfDoc = doc.pdfDocument else { return }
        let text = pdfDoc.allPages.compactMap { $0.string }.joined(separator: "\n\n")

        let panel = NSSavePanel()
        panel.allowedContentTypes = [.plainText]
        panel.nameFieldStringValue = (doc.fileURL?.deletingPathExtension().lastPathComponent ?? "document") + ".txt"
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            try? text.write(to: url, atomically: true, encoding: .utf8)
        }
    }

    @objc func createFromImages(_ sender: Any?) {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.allowedContentTypes = [.jpeg, .png, .tiff, .bmp, .heic]
        panel.message = "Select images to combine into a PDF"
        panel.begin { [weak self] response in
            guard let self, response == .OK, !panel.urls.isEmpty else { return }

            let doc = OakReaderDocument()
            let newPDF = PDFDocument()

            for url in panel.urls {
                guard let image = NSImage(contentsOf: url),
                      let page = image.toPDFPage() else { continue }
                newPDF.insert(page, at: newPDF.pageCount)
            }

            guard newPDF.pageCount > 0 else { return }

            doc.pdfDocument = newPDF
            doc.documentViewModel = DocumentViewModel(document: doc)
            NSDocumentController.shared.addDocument(doc)

            let tab = DocumentTab(document: doc)
            self.appState.openTabs.append(tab)
            self.appState.activeTabID = tab.id
            self.appState.updateWindowTitle()
        }
    }

    // MARK: - Menu Action Dispatch

    @objc func menuAction(_ sender: NSMenuItem) {
        guard let actionName = sender.representedObject as? String,
              let action = DocumentAction(rawValue: actionName) else { return }
        appState.dispatchAction(action)
        // Also post notification for ContentView sheet handling
        NotificationCenter.default.post(name: .documentAction, object: action)
    }

}
