import Cocoa
import CoreText
import PDFKit
import Sparkle
import UniformTypeIdentifiers
import SwiftUI
import OakVoice

class AppDelegate: NSObject, NSApplicationDelegate {
    let documentController = PDFDocumentController()
    let appState = AppState()
    let updaterController = SPUStandardUpdaterController(startingUpdater: true, updaterDelegate: nil, userDriverDelegate: nil)
    private var mainWindow: NSWindow?
    private var settingsWindow: NSWindow?
    private var settingsCloseObserver: NSObjectProtocol?
    private var snapshotServer: SnapshotServer?
    private var appearanceObserver: NSObjectProtocol?
    private let externalLibraryChangeNotificationName = Notification.Name("com.oakreader.library.didChange")
    private let externalLibraryChangeSource = "oak-cli"
    private(set) lazy var commandPalette = CommandPaletteController(appDelegate: self)
    func applicationWillFinishLaunching(_ notification: Notification) {
        documentController.appState = appState
        NSApp.mainMenu = MainMenuBuilder.build(target: self)
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.servicesProvider = self

        // Prewarm the emoji font so WebKit doesn't stall on first emoji render
        _ = CTFontCreateWithName("Apple Color Emoji" as CFString, 12, nil)

        // Forward OakVoice logs to the shared log file
        VoiceAgentLog.sink = { level, category, message in
            LogFileWriter.shared.write(level: level, category: category, message: message)
        }

        // Run one-time migration from old SwiftData storage
        let migration = MigrationService(store: appState.libraryStore, coverService: appState.coverService)
        migration.migrateIfNeeded()

        // Migrate AppStorage keys: flashcard_ → quizCard_
        UserDefaultsKeyMigration.migrateQuizCardKeys()

        installExternalLibraryChangeObserver()

        // Start the snapshot server for Chrome extension
        snapshotServer = SnapshotServer(importService: appState.importService)
        snapshotServer?.start()

        createMainWindow()
    }

    func applicationWillTerminate(_ notification: Notification) {
        DistributedNotificationCenter.default().removeObserver(
            self,
            name: externalLibraryChangeNotificationName,
            object: nil
        )
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
        showMainWindow()
        return true
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        for url in urls {
            guard url.scheme?.lowercased() == "oakreader" else { continue }
            handleOakReaderURL(url)
        }
    }

    private func handleOakReaderURL(_ url: URL) {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            showMainWindow()
            return
        }

        let queryItems = components.queryItems ?? []

        switch components.host {
        case "add":
            guard let urlString = queryItems.first(where: { $0.name == "url" })?.value,
                  let sourceURL = URL(string: urlString) else {
                showMainWindow()
                return
            }
            showMainWindow()
            let collectionId = queryItems.first(where: { $0.name == "collection" })?.value
                .flatMap { UUID(uuidString: $0) }
            Task {
                do {
                    if sourceURL.isFileURL, sourceURL.hasDirectoryPath {
                        let count = await appState.libraryStore.importFolder(
                            sourceURL,
                            importService: appState.importService
                        )
                        await MainActor.run {
                            withAnimation {
                                appState.importNotification = "Imported \(count) item\(count == 1 ? "" : "s") from \"\(sourceURL.lastPathComponent)\""
                            }
                            appState.switchToLibrary()
                        }
                    } else {
                        let item: LibraryItem?
                        if sourceURL.isFileURL {
                            item = await appState.importService.importFileAsync(from: sourceURL)
                        } else {
                            item = try await appState.importService.importURL(sourceURL)
                        }
                        if let item {
                            await MainActor.run {
                                if let collectionId,
                                   let collection = appState.libraryStore.collections.first(where: { $0.id == collectionId }) {
                                    appState.libraryStore.addItem(item, to: collection)
                                }
                                withAnimation {
                                    appState.importNotification = "Added \"\(item.title)\""
                                }
                            }
                        }
                    }
                } catch {
                    Log.error(Log.importer, "URL scheme import failed: \(error)")
                }
            }

        case "library":
            showMainWindow()
            if let collectionId = queryItems.first(where: { $0.name == "collection" })?.value
                .flatMap({ UUID(uuidString: $0) }) {
                appState.libraryStore.selectedCollectionId = collectionId
            }
            appState.switchToLibrary()

        default:
            showMainWindow()
        }
    }

    private func installExternalLibraryChangeObserver() {
        DistributedNotificationCenter.default().addObserver(
            self,
            selector: #selector(handleExternalLibraryChange(_:)),
            name: externalLibraryChangeNotificationName,
            object: nil
        )
    }

    @objc private func handleExternalLibraryChange(_ notification: Notification) {
        DispatchQueue.main.async { [weak self] in
            guard let self,
                  notification.userInfo?["source"] as? String == self.externalLibraryChangeSource else {
                return
            }

            self.appState.libraryStore.invalidate()
            let message = notification.userInfo?["message"] as? String ?? "Library updated from oak"
            withAnimation {
                self.appState.importNotification = message
            }

            let operation = notification.userInfo?["operation"] as? String ?? "unknown"
            Log.info(Log.store, "Applied external library change from oak CLI: \(operation)")
        }
    }

    private func showMainWindow() {
        if mainWindow == nil {
            createMainWindow()
        }
        mainWindow?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
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

    // MARK: - Command Palette

    @objc func showCommandPalette(_ sender: Any?) {
        commandPalette.show()
    }

    // MARK: - Settings Window

    @objc func showSettingsWindow(_ sender: Any?) {
        if let existing = settingsWindow {
            existing.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let settingsView = SettingsView(store: appState.libraryStore)
        let hostingController = NSHostingController(rootView: settingsView)

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 900, height: 620),
            styleMask: [.titled, .closable, .miniaturizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.contentViewController = hostingController
        window.title = "Settings"
        window.titlebarSeparatorStyle = .none
        window.toolbarStyle = .unified
        window.isReleasedWhenClosed = false
        settingsCloseObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification,
            object: window,
            queue: .main
        ) { [weak self] _ in
            self?.appState.showSettings = false
            self?.settingsWindow = nil
            if let obs = self?.settingsCloseObserver {
                NotificationCenter.default.removeObserver(obs)
                self?.settingsCloseObserver = nil
            }
        }

        settingsWindow = window
        appState.showSettings = true
        window.makeKeyAndOrderFront(nil)
        // Center after first layout pass so NavigationSplitView sizing is settled.
        DispatchQueue.main.async {
            window.center()
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

    @objc func importFolder(_ sender: Any?) {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.message = "Select a folder to import as a collection"
        panel.prompt = "Import"
        panel.begin { [weak self] response in
            guard response == .OK, let folderURL = panel.url, let self else { return }
            Task {
                let count = await self.appState.libraryStore.importFolder(
                    folderURL,
                    importService: self.appState.importService
                )
                await MainActor.run {
                    withAnimation {
                        self.appState.importNotification = "Imported \(count) item\(count == 1 ? "" : "s") from \"\(folderURL.lastPathComponent)\""
                    }
                    self.appState.switchToLibrary()
                }
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

    // MARK: - Library Backup

    @objc func exportLibraryBackup(_ sender: Any?) {
        let panel = NSSavePanel()
        let dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "yyyy-MM-dd"
        let dateString = dateFormatter.string(from: Date())
        panel.nameFieldStringValue = "OakReader-Backup-\(dateString).oakreader"
        panel.allowedContentTypes = [.init(filenameExtension: "oakreader") ?? .zip]
        panel.begin { [weak self] response in
            guard response == .OK, let url = panel.url, let self else { return }
            self.appState.backupExportURL = url
            self.appState.showBackupExport = true
        }
    }

    @objc func restoreLibraryBackup(_ sender: Any?) {
        let alert = NSAlert()
        alert.messageText = "Restore from Backup"
        alert.informativeText = """
            This will replace your entire library with the contents of the backup. \
            Your current library will be preserved in a separate folder as a safety net.

            The app will need to restart after restoring.
            """
        alert.alertStyle = .critical
        alert.addButton(withTitle: "Choose Backup File...")
        alert.addButton(withTitle: "Cancel")

        let response = alert.runModal()
        guard response == .alertFirstButtonReturn else { return }

        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.init(filenameExtension: "oakreader") ?? .zip]
        panel.allowsMultipleSelection = false
        panel.message = "Select an OakReader backup file to restore"
        let openResponse = panel.runModal()
        guard openResponse == .OK, let url = panel.url else { return }

        appState.backupRestoreURL = url
        appState.showBackupRestore = true
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

    // MARK: - Services Menu

    @objc func addToOakReader(_ pboard: NSPasteboard, userData: String, error: AutoreleasingUnsafeMutablePointer<NSString?>) {
        // Try file paths first, then URL objects, then plain strings
        var sourceURL: URL?
        if let filenames = pboard.propertyList(forType: .init("NSFilenamesPboardType")) as? [String],
           let first = filenames.first {
            sourceURL = URL(fileURLWithPath: first)
        } else if let urls = pboard.readObjects(forClasses: [NSURL.self]) as? [URL], let first = urls.first {
            sourceURL = first
        } else if let string = pboard.string(forType: .string)?.trimmingCharacters(in: .whitespacesAndNewlines) {
            sourceURL = URL(string: string)
        }

        guard let sourceURL else {
            error.pointee = "No valid URL found in the selection." as NSString
            return
        }

        showMainWindow()
        Task {
            if sourceURL.isFileURL, sourceURL.hasDirectoryPath {
                let count = await appState.libraryStore.importFolder(
                    sourceURL,
                    importService: appState.importService
                )
                await MainActor.run {
                    withAnimation {
                        appState.importNotification = "Imported \(count) item\(count == 1 ? "" : "s") from \"\(sourceURL.lastPathComponent)\""
                    }
                    appState.switchToLibrary()
                }
            } else {
                let item: LibraryItem?
                if sourceURL.isFileURL {
                    item = await appState.importService.importFileAsync(from: sourceURL)
                } else {
                    item = try? await appState.importService.importURL(sourceURL)
                }
                if let item {
                    await MainActor.run {
                        withAnimation {
                            appState.importNotification = "Added \"\(item.title)\""
                        }
                    }
                } else {
                    Log.error(Log.importer, "Services import failed for \(sourceURL)")
                }
            }
        }
    }

    // MARK: - Share

    @objc func shareCurrentItem(_ sender: Any?) {
        var shareItems: [Any] = []
        if let tab = appState.activeTab {
            switch tab.content {
            case .pdf(let doc):
                if let fileURL = doc.fileURL { shareItems.append(fileURL) }
            case .html(let doc):
                if let sourceURL = doc.sourceURL {
                    shareItems.append(sourceURL)
                } else {
                    shareItems.append(doc.htmlURL)
                }
            case .media(let doc):
                shareItems.append(doc.sourceURL)
            case .markdown(let doc):
                shareItems.append(doc.fileURL)
            }
        } else if let item = appState.selectedLibraryItem {
            if let sourceURL = item.sourceURL {
                shareItems.append(sourceURL)
            } else {
                shareItems.append(item.fileURL)
            }
        }
        guard !shareItems.isEmpty else { return }
        SharingService.share(items: shareItems)
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
