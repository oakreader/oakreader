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
        buildEntireMainMenu()
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
        let tabBarHeight: CGFloat = 38.0 // ZoteroStyle.Size.tabBarHeight

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

    @objc private func menuAction(_ sender: NSMenuItem) {
        guard let actionName = sender.representedObject as? String,
              let action = DocumentAction(rawValue: actionName) else { return }
        appState.dispatchAction(action)
        // Also post notification for ContentView sheet handling
        NotificationCenter.default.post(name: .documentAction, object: action)
    }

    // MARK: - Complete Menu Bar

    private func buildEntireMainMenu() {
        let mainMenu = NSMenu()

        // ── App menu ──
        let appMenu = NSMenu()
        appMenu.addItem(NSMenuItem(title: "About OakReader", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: ""))
        appMenu.addItem(.separator())
        appMenu.addItem(NSMenuItem(title: "Settings...", action: Selector(("showSettingsWindow:")), keyEquivalent: ","))
        appMenu.addItem(.separator())
        let servicesMenu = NSMenu(title: "Services")
        let servicesItem = NSMenuItem(title: "Services", action: nil, keyEquivalent: "")
        servicesItem.submenu = servicesMenu
        appMenu.addItem(servicesItem)
        NSApp.servicesMenu = servicesMenu
        appMenu.addItem(.separator())
        appMenu.addItem(NSMenuItem(title: "Hide OakReader", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h"))
        let hideOthersItem = NSMenuItem(title: "Hide Others", action: #selector(NSApplication.hideOtherApplications(_:)), keyEquivalent: "h")
        hideOthersItem.keyEquivalentModifierMask = [.command, .option]
        appMenu.addItem(hideOthersItem)
        appMenu.addItem(NSMenuItem(title: "Show All", action: #selector(NSApplication.unhideAllApplications(_:)), keyEquivalent: ""))
        appMenu.addItem(.separator())
        appMenu.addItem(NSMenuItem(title: "Quit OakReader", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))

        let appMenuItem = NSMenuItem()
        appMenuItem.submenu = appMenu
        mainMenu.addItem(appMenuItem)

        // ── File menu ──
        let fileMenu = NSMenu(title: "File")

        let newItem = NSMenuItem(title: "New Blank PDF", action: #selector(newBlankDocument(_:)), keyEquivalent: "n")
        newItem.target = self
        fileMenu.addItem(newItem)

        let createFromImagesItem = NSMenuItem(title: "New from Images...", action: #selector(createFromImages(_:)), keyEquivalent: "")
        createFromImagesItem.target = self
        fileMenu.addItem(createFromImagesItem)

        fileMenu.addItem(.separator())

        let openItem = NSMenuItem(title: "Open...", action: #selector(openDocument(_:)), keyEquivalent: "o")
        openItem.target = self
        fileMenu.addItem(openItem)

        // Open Recent
        let openRecentMenu = NSMenu(title: "Open Recent")
        let clearRecentItem = NSMenuItem(title: "Clear Menu", action: #selector(NSDocumentController.clearRecentDocuments(_:)), keyEquivalent: "")
        openRecentMenu.addItem(clearRecentItem)
        let openRecentItem = NSMenuItem(title: "Open Recent", action: nil, keyEquivalent: "")
        openRecentItem.submenu = openRecentMenu
        fileMenu.addItem(openRecentItem)

        fileMenu.addItem(.separator())

        let closeItem = NSMenuItem(title: "Close Tab", action: #selector(closeTab(_:)), keyEquivalent: "w")
        closeItem.target = self
        fileMenu.addItem(closeItem)

        let saveItem = NSMenuItem(title: "Save", action: #selector(saveDocument(_:)), keyEquivalent: "s")
        saveItem.target = self
        fileMenu.addItem(saveItem)

        let saveAsItem = NSMenuItem(title: "Save As...", action: #selector(saveDocumentAs(_:)), keyEquivalent: "S")
        saveAsItem.target = self
        fileMenu.addItem(saveAsItem)

        let revertItem = NSMenuItem(title: "Revert to Saved", action: #selector(revertDocument(_:)), keyEquivalent: "")
        revertItem.target = self
        fileMenu.addItem(revertItem)

        fileMenu.addItem(.separator())

        // Export As submenu
        let exportMenu = NSMenu(title: "Export As")
        let expImgItem = NSMenuItem(title: "Images (JPEG, PNG, TIFF)...", action: #selector(exportAsImages(_:)), keyEquivalent: "e")
        expImgItem.keyEquivalentModifierMask = [.command, .shift]
        expImgItem.target = self
        exportMenu.addItem(expImgItem)
        let expTxtItem = NSMenuItem(title: "Plain Text...", action: #selector(exportAsText(_:)), keyEquivalent: "")
        expTxtItem.target = self
        exportMenu.addItem(expTxtItem)
        let exportSubItem = NSMenuItem(title: "Export As", action: nil, keyEquivalent: "")
        exportSubItem.submenu = exportMenu
        fileMenu.addItem(exportSubItem)

        fileMenu.addItem(.separator())

        let printItem = NSMenuItem(title: "Print...", action: #selector(printDocument(_:)), keyEquivalent: "p")
        printItem.target = self
        fileMenu.addItem(printItem)

        let fileMenuItem = NSMenuItem(title: "File", action: nil, keyEquivalent: "")
        fileMenuItem.submenu = fileMenu
        mainMenu.addItem(fileMenuItem)

        // ── Edit menu ──
        let editMenu = NSMenu(title: "Edit")
        editMenu.addItem(NSMenuItem(title: "Undo", action: Selector(("undo:")), keyEquivalent: "z"))
        editMenu.addItem(NSMenuItem(title: "Redo", action: Selector(("redo:")), keyEquivalent: "Z"))
        editMenu.addItem(.separator())
        editMenu.addItem(NSMenuItem(title: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x"))
        editMenu.addItem(NSMenuItem(title: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c"))
        editMenu.addItem(NSMenuItem(title: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v"))
        editMenu.addItem(NSMenuItem(title: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a"))
        editMenu.addItem(.separator())
        let findItem = actionMenuItem("Find in Document...", action: .find, key: "f")
        editMenu.addItem(findItem)

        let editMenuItem = NSMenuItem(title: "Edit", action: nil, keyEquivalent: "")
        editMenuItem.submenu = editMenu
        mainMenu.addItem(editMenuItem)

        // ── View menu ──
        let viewMenu = NSMenu(title: "View")

        let libraryItem = NSMenuItem(title: "Show Library", action: #selector(showLibrary(_:)), keyEquivalent: "L")
        libraryItem.keyEquivalentModifierMask = [.command, .shift]
        libraryItem.target = self
        viewMenu.addItem(libraryItem)

        viewMenu.addItem(.separator())
        viewMenu.addItem(actionMenuItem("Toggle Sidebar", action: .toggleSidebar, key: "s", modifiers: [.command, .option]))
        viewMenu.addItem(actionMenuItem("Toggle Inspector", action: .toggleInspector, key: "i", modifiers: [.command, .option]))
        viewMenu.addItem(.separator())
        viewMenu.addItem(actionMenuItem("Zoom In", action: .zoomIn, key: "=", modifiers: [.command]))
        viewMenu.addItem(actionMenuItem("Zoom Out", action: .zoomOut, key: "-", modifiers: [.command]))
        viewMenu.addItem(actionMenuItem("Zoom to Fit", action: .zoomToFit, key: "0", modifiers: [.command]))
        viewMenu.addItem(.separator())
        viewMenu.addItem(actionMenuItem("Single Page", action: .displaySingle))
        viewMenu.addItem(actionMenuItem("Single Page Continuous", action: .displaySingleContinuous))
        viewMenu.addItem(actionMenuItem("Two Pages", action: .displayTwoUp))
        viewMenu.addItem(actionMenuItem("Two Pages Continuous", action: .displayTwoUpContinuous))

        let viewMenuItem = NSMenuItem(title: "View", action: nil, keyEquivalent: "")
        viewMenuItem.submenu = viewMenu
        mainMenu.addItem(viewMenuItem)

        // ── Go menu ──
        let goMenu = NSMenu(title: "Go")
        goMenu.addItem(actionMenuItem("Back", action: .navigateBack, key: "[", modifiers: [.command, .option]))
        goMenu.addItem(.separator())
        goMenu.addItem(actionMenuItem("Previous Page", action: .previousPage, key: String(UnicodeScalar(NSUpArrowFunctionKey)!), modifiers: [.command]))
        goMenu.addItem(actionMenuItem("Next Page", action: .nextPage, key: String(UnicodeScalar(NSDownArrowFunctionKey)!), modifiers: [.command]))
        goMenu.addItem(.separator())
        goMenu.addItem(actionMenuItem("First Page", action: .firstPage, key: String(UnicodeScalar(NSHomeFunctionKey)!), modifiers: [.command]))
        goMenu.addItem(actionMenuItem("Last Page", action: .lastPage, key: String(UnicodeScalar(NSEndFunctionKey)!), modifiers: [.command]))

        let goMenuItem = NSMenuItem(title: "Go", action: nil, keyEquivalent: "")
        goMenuItem.submenu = goMenu
        mainMenu.addItem(goMenuItem)

        // ── Tools menu ──
        let toolsMenu = NSMenu(title: "Tools")
        toolsMenu.addItem(actionMenuItem("Run OCR", action: .runOCR, key: "r", modifiers: [.command, .shift]))
        toolsMenu.addItem(.separator())
        toolsMenu.addItem(actionMenuItem("Rotate Clockwise", action: .rotateRight, key: "]", modifiers: [.command]))
        toolsMenu.addItem(actionMenuItem("Rotate Counter-Clockwise", action: .rotateLeft, key: "[", modifiers: [.command]))
        toolsMenu.addItem(.separator())
        toolsMenu.addItem(actionMenuItem("Accessibility Check...", action: .accessibilityCheck))

        let toolsMenuItem = NSMenuItem(title: "Tools", action: nil, keyEquivalent: "")
        toolsMenuItem.submenu = toolsMenu
        mainMenu.addItem(toolsMenuItem)

        // ── Window menu ──
        let windowMenu = NSMenu(title: "Window")
        windowMenu.addItem(NSMenuItem(title: "Minimize", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m"))
        windowMenu.addItem(NSMenuItem(title: "Zoom", action: #selector(NSWindow.performZoom(_:)), keyEquivalent: ""))
        windowMenu.addItem(.separator())

        let nextTabItem = NSMenuItem(title: "Show Next Tab", action: #selector(nextTab(_:)), keyEquivalent: "\t")
        nextTabItem.keyEquivalentModifierMask = [.control]
        nextTabItem.target = self
        windowMenu.addItem(nextTabItem)

        let prevTabItem = NSMenuItem(title: "Show Previous Tab", action: #selector(previousTab(_:)), keyEquivalent: "\t")
        prevTabItem.keyEquivalentModifierMask = [.control, .shift]
        prevTabItem.target = self
        windowMenu.addItem(prevTabItem)

        windowMenu.addItem(.separator())
        windowMenu.addItem(NSMenuItem(title: "Bring All to Front", action: #selector(NSApplication.arrangeInFront(_:)), keyEquivalent: ""))

        let windowMenuItem = NSMenuItem(title: "Window", action: nil, keyEquivalent: "")
        windowMenuItem.submenu = windowMenu
        mainMenu.addItem(windowMenuItem)
        NSApp.windowsMenu = windowMenu

        // ── Help menu ──
        let helpMenu = NSMenu(title: "Help")
        let helpMenuItem = NSMenuItem(title: "Help", action: nil, keyEquivalent: "")
        helpMenuItem.submenu = helpMenu
        mainMenu.addItem(helpMenuItem)
        NSApp.helpMenu = helpMenu

        // Replace the entire menu bar
        NSApp.mainMenu = mainMenu
    }

    private func actionMenuItem(_ title: String, action: DocumentAction, key: String = "", modifiers: NSEvent.ModifierFlags = []) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: #selector(menuAction(_:)), keyEquivalent: key)
        item.keyEquivalentModifierMask = modifiers
        item.representedObject = action.rawValue
        item.target = self
        return item
    }
}
