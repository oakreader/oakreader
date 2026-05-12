import Cocoa
import PDFKit
import Sparkle
import UniformTypeIdentifiers
import SwiftUI
import OakVoiceAI

class AppDelegate: NSObject, NSApplicationDelegate {
    let documentController = PDFDocumentController()
    let appState = AppState()
    let updaterController = SPUStandardUpdaterController(startingUpdater: true, updaterDelegate: nil, userDriverDelegate: nil)
    private var mainWindow: NSWindow?
    private var snapshotServer: SnapshotServer?
    private var appearanceObserver: NSObjectProtocol?
    private var menuBarRecorder: MenuBarRecorder?

    func applicationWillFinishLaunching(_ notification: Notification) {
        documentController.appState = appState
        NSApp.mainMenu = MainMenuBuilder.build(target: self)
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Forward OakVoiceAI logs to the shared log file
        VoiceAgentLog.sink = { level, category, message in
            LogFileWriter.shared.write(level: level, category: category, message: message)
        }

        // Run one-time migration from old SwiftData storage
        let migration = MigrationService(store: appState.libraryStore, coverService: appState.coverService)
        migration.migrateIfNeeded()

        // Start the snapshot server for Chrome extension
        snapshotServer = SnapshotServer(importService: appState.importService)
        snapshotServer?.start()

        // Menu bar audio recorder
        menuBarRecorder = MenuBarRecorder(importService: appState.importService)

        createMainWindow()
    }

    func applicationWillTerminate(_ notification: Notification) {
        snapshotServer?.stop()
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
        window.backgroundColor = .windowBackgroundColor
        window.styleMask.insert(.fullSizeContentView)
        window.collectionBehavior.insert(.fullScreenPrimary)
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

        // Apply saved appearance mode
        applyAppearanceMode()

        // Observe appearance preference changes
        appearanceObserver = NotificationCenter.default.addObserver(
            forName: UserDefaults.didChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.applyAppearanceMode()
        }

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

    // MARK: - Appearance

    private func applyAppearanceMode() {
        guard let window = mainWindow else { return }
        let mode = Preferences.shared.appearanceMode
        switch mode {
        case "light":
            window.appearance = NSAppearance(named: .aqua)
        case "dark":
            window.appearance = NSAppearance(named: .darkAqua)
        default:
            window.appearance = nil
        }
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

    @objc func openDocument(_ sender: Any?) {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.pdf, .html]
        panel.allowsMultipleSelection = true
        panel.begin { [weak self] response in
            guard response == .OK else { return }
            for url in panel.urls {
                self?.appState.openDocument(url: url)
            }
        }
    }

    @objc func saveDocument(_ sender: Any?) {
        appState.activeTab?.document?.save(sender)
    }

    @objc func saveDocumentAs(_ sender: Any?) {
        appState.activeTab?.document?.saveAs(sender)
    }

    @objc func revertDocument(_ sender: Any?) {
        appState.activeTab?.document?.revertToSaved(sender)
    }

    @objc func printDocument(_ sender: Any?) {
        appState.activeTab?.document?.printDocument(sender)
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

    // MARK: - Log Export

    @objc func exportLogs(_ sender: Any?) {
        let logURL = Log.logFileURL
        guard FileManager.default.fileExists(atPath: logURL.path) else {
            let alert = NSAlert()
            alert.messageText = "No Logs Available"
            alert.informativeText = "The log file has not been created yet."
            alert.alertStyle = .informational
            alert.addButton(withTitle: "OK")
            alert.runModal()
            return
        }

        let panel = NSSavePanel()
        panel.nameFieldStringValue = logURL.lastPathComponent
        panel.allowedContentTypes = [.plainText]
        panel.begin { response in
            guard response == .OK, let destURL = panel.url else { return }
            try? FileManager.default.copyItem(at: logURL, to: destURL)
        }
    }

    // MARK: - Zotero Import

    @objc func importFromZotero(_ sender: Any?) {
        let migrationService = ZoteroMigrationService(
            store: appState.libraryStore,
            coverService: appState.coverService,
            referenceService: appState.referenceService
        )

        var dataDir = migrationService.detectZoteroDataDirectory()

        if dataDir == nil {
            // No auto-detected directory — ask user to select
            let panel = NSOpenPanel()
            panel.message = "Select your Zotero data directory (contains zotero.sqlite)"
            panel.prompt = "Select"
            panel.canChooseFiles = false
            panel.canChooseDirectories = true
            panel.allowsMultipleSelection = false
            let response = panel.runModal()
            guard response == .OK, let selectedURL = panel.url else { return }
            dataDir = selectedURL
        }

        guard let dir = dataDir else { return }

        let dbFile = dir.appendingPathComponent("zotero.sqlite")
        guard FileManager.default.fileExists(atPath: dbFile.path) else {
            let alert = NSAlert()
            alert.messageText = "Zotero Database Not Found"
            alert.informativeText = "No zotero.sqlite file was found in the selected directory."
            alert.alertStyle = .warning
            alert.addButton(withTitle: "OK")
            alert.runModal()
            return
        }

        // Confirmation alert
        let alert = NSAlert()
        alert.messageText = "Import from Zotero"
        alert.informativeText = "This will import your Zotero library into OakReader.\n\nZotero data directory:\n\(dir.path)\n\nYour Zotero library will not be modified."
        alert.alertStyle = .informational
        alert.addButton(withTitle: "Import")
        alert.addButton(withTitle: "Cancel")
        let spacer = NSView(frame: NSRect(x: 0, y: 0, width: 400, height: 0))
        alert.accessoryView = spacer

        let response = alert.runModal()
        guard response == .alertFirstButtonReturn else { return }

        appState.zoteroImportDataDir = dir
        appState.showZoteroImport = true
    }

    // MARK: - Command Line Tools

    @objc func installCommandLineTools(_ sender: Any?) {
        let destPath = "/usr/local/bin/oak"

        guard let bundleBinary = Bundle.main.resourceURL?.appendingPathComponent("oak") else {
            showAlert(
                title: "CLI Binary Not Found",
                message: "The oak command-line tool was not found inside the application bundle.",
                style: .critical
            )
            return
        }

        let bundlePath = bundleBinary.path

        guard FileManager.default.fileExists(atPath: bundlePath) else {
            showAlert(
                title: "CLI Binary Not Found",
                message: "The oak command-line tool was not found at:\n\(bundlePath)",
                style: .critical
            )
            return
        }

        // Check if already installed and pointing to the correct location
        if let existing = try? FileManager.default.destinationOfSymbolicLink(atPath: destPath),
           existing == bundlePath {
            showAlert(
                title: "Already Installed",
                message: "The oak command-line tool is already installed at \(destPath).",
                style: .informational
            )
            return
        }

        // Confirmation dialog
        let alert = NSAlert()
        alert.messageText = "Install Command Line Tools"
        alert.informativeText = "This will create a symlink at \(destPath) pointing to the oak binary inside OakReader.app.\n\nAdministrator privileges are required."
        alert.alertStyle = .informational
        alert.addButton(withTitle: "Install")
        alert.addButton(withTitle: "Cancel")
        let response = alert.runModal()
        guard response == .alertFirstButtonReturn else { return }

        // Use AppleScript to create symlink with admin privileges
        let script = """
            do shell script "mkdir -p /usr/local/bin && ln -sf '\(bundlePath)' '\(destPath)'" \
            with administrator privileges
            """

        var error: NSDictionary?
        if let appleScript = NSAppleScript(source: script) {
            appleScript.executeAndReturnError(&error)
        }

        if let error = error {
            let message = error[NSAppleScript.errorMessage] as? String ?? "Unknown error"
            showAlert(
                title: "Installation Failed",
                message: message,
                style: .critical
            )
        } else {
            showAlert(
                title: "Installation Successful",
                message: "The oak command-line tool has been installed at \(destPath).\n\nYou can now use 'oak' from your terminal.",
                style: .informational
            )
        }
    }

    private func showAlert(title: String, message: String, style: NSAlert.Style) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.alertStyle = style
        alert.addButton(withTitle: "OK")
        alert.runModal()
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
