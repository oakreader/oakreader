import Cocoa
import Sparkle

// swiftlint:disable function_body_length

enum MainMenuBuilder {
    static func build(target: AppDelegate) -> NSMenu {
        let mainMenu = NSMenu()

        // App menu
        mainMenu.addItem(buildAppMenu(target: target, updaterController: target.updaterController))

        // File menu
        mainMenu.addItem(buildFileMenu(target: target))

        // Edit menu
        mainMenu.addItem(buildEditMenu(target: target))

        // View menu
        mainMenu.addItem(buildViewMenu(target: target))

        // Go menu
        mainMenu.addItem(buildGoMenu(target: target))

        // Window menu
        let (windowMenuItem, windowMenu) = buildWindowMenu(target: target)
        mainMenu.addItem(windowMenuItem)
        NSApp.windowsMenu = windowMenu

        // Help menu
        let (helpMenuItem, helpMenu) = buildHelpMenu(target: target)
        mainMenu.addItem(helpMenuItem)
        NSApp.helpMenu = helpMenu

        return mainMenu
    }

    // MARK: - App Menu

    private static func buildAppMenu(
        target: AppDelegate,
        updaterController: SPUStandardUpdaterController
    ) -> NSMenuItem {
        let appMenu = NSMenu()
        appMenu.addItem(NSMenuItem(
            title: "About OakReader",
            action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)),
            keyEquivalent: ""
        ))
        appMenu.addItem(.separator())
        let checkForUpdatesItem = NSMenuItem(
            title: "Check for Updates...",
            action: #selector(SPUStandardUpdaterController.checkForUpdates(_:)),
            keyEquivalent: ""
        )
        checkForUpdatesItem.target = updaterController
        appMenu.addItem(checkForUpdatesItem)
        let installCLIItem = NSMenuItem(
            title: "Install Command Line Tools...",
            action: #selector(AppDelegate.installCommandLineTools(_:)),
            keyEquivalent: ""
        )
        installCLIItem.target = target
        installCLIItem.image = icon("terminal")
        appMenu.addItem(installCLIItem)
        appMenu.addItem(.separator())
        appMenu.addItem(NSMenuItem(
            title: "Settings...",
            action: Selector(("showSettingsWindow:")),
            keyEquivalent: ","
        ))
        appMenu.addItem(.separator())
        let servicesMenu = NSMenu(title: "Services")
        let servicesItem = NSMenuItem(title: "Services", action: nil, keyEquivalent: "")
        servicesItem.submenu = servicesMenu
        appMenu.addItem(servicesItem)
        NSApp.servicesMenu = servicesMenu
        appMenu.addItem(.separator())
        appMenu.addItem(NSMenuItem(
            title: "Hide OakReader",
            action: #selector(NSApplication.hide(_:)),
            keyEquivalent: "h"
        ))
        let hideOthersItem = NSMenuItem(
            title: "Hide Others",
            action: #selector(NSApplication.hideOtherApplications(_:)),
            keyEquivalent: "h"
        )
        hideOthersItem.keyEquivalentModifierMask = [.command, .option]
        appMenu.addItem(hideOthersItem)
        appMenu.addItem(NSMenuItem(
            title: "Show All",
            action: #selector(NSApplication.unhideAllApplications(_:)),
            keyEquivalent: ""
        ))
        appMenu.addItem(.separator())
        appMenu.addItem(NSMenuItem(
            title: "Quit OakReader",
            action: #selector(NSApplication.terminate(_:)),
            keyEquivalent: "q"
        ))

        let appMenuItem = NSMenuItem()
        appMenuItem.submenu = appMenu
        return appMenuItem
    }

    // MARK: - File Menu

    private static func buildFileMenu(target: AppDelegate) -> NSMenuItem {
        let fileMenu = NSMenu(title: "File")

        let openItem = NSMenuItem(
            title: "Open...",
            action: #selector(AppDelegate.openDocument(_:)),
            keyEquivalent: "o"
        )
        openItem.target = target
        openItem.image = icon("folder")
        fileMenu.addItem(openItem)

        // Open Recent
        let openRecentMenu = NSMenu(title: "Open Recent")
        openRecentMenu.addItem(NSMenuItem(
            title: "Clear Menu",
            action: #selector(NSDocumentController.clearRecentDocuments(_:)),
            keyEquivalent: ""
        ))
        let openRecentItem = NSMenuItem(title: "Open Recent", action: nil, keyEquivalent: "")
        openRecentItem.submenu = openRecentMenu
        openRecentItem.image = icon("clock.arrow.circlepath")
        fileMenu.addItem(openRecentItem)

        fileMenu.addItem(.separator())

        let zoteroItem = NSMenuItem(
            title: "Import from Zotero...",
            action: #selector(AppDelegate.importFromZotero(_:)),
            keyEquivalent: ""
        )
        zoteroItem.target = target
        zoteroItem.image = icon("tray.and.arrow.down")
        fileMenu.addItem(zoteroItem)

        let importFolderItem = NSMenuItem(
            title: "Import Folder...",
            action: #selector(AppDelegate.importFolder(_:)),
            keyEquivalent: ""
        )
        importFolderItem.target = target
        importFolderItem.image = icon("folder.badge.plus")
        fileMenu.addItem(importFolderItem)

        fileMenu.addItem(.separator())

        let closeItem = NSMenuItem(
            title: "Close Tab",
            action: #selector(AppDelegate.closeTab(_:)),
            keyEquivalent: "w"
        )
        closeItem.target = target
        closeItem.image = icon("xmark")
        fileMenu.addItem(closeItem)

        let saveItem = NSMenuItem(
            title: "Save",
            action: #selector(AppDelegate.saveDocument(_:)),
            keyEquivalent: "s"
        )
        saveItem.target = target
        saveItem.image = icon("square.and.arrow.down")
        fileMenu.addItem(saveItem)

        let saveAsItem = NSMenuItem(
            title: "Save As...",
            action: #selector(AppDelegate.saveDocumentAs(_:)),
            keyEquivalent: "S"
        )
        saveAsItem.target = target
        saveAsItem.image = icon("square.and.arrow.down.on.square")
        fileMenu.addItem(saveAsItem)

        let revertItem = NSMenuItem(
            title: "Revert to Saved",
            action: #selector(AppDelegate.revertDocument(_:)),
            keyEquivalent: ""
        )
        revertItem.target = target
        revertItem.image = icon("arrow.counterclockwise")
        fileMenu.addItem(revertItem)

        fileMenu.addItem(.separator())

        // Export As submenu
        let exportMenu = NSMenu(title: "Export As")
        let expImgItem = NSMenuItem(
            title: "Images (JPEG, PNG, TIFF)...",
            action: #selector(AppDelegate.exportAsImages(_:)),
            keyEquivalent: "e"
        )
        expImgItem.keyEquivalentModifierMask = [.command, .shift]
        expImgItem.target = target
        expImgItem.image = icon("photo")
        exportMenu.addItem(expImgItem)

        let expTxtItem = NSMenuItem(
            title: "Plain Text...",
            action: #selector(AppDelegate.exportAsText(_:)),
            keyEquivalent: ""
        )
        expTxtItem.target = target
        expTxtItem.image = icon("doc.plaintext")
        exportMenu.addItem(expTxtItem)

        let exportSubItem = NSMenuItem(title: "Export As", action: nil, keyEquivalent: "")
        exportSubItem.submenu = exportMenu
        exportSubItem.image = icon("square.and.arrow.up")
        fileMenu.addItem(exportSubItem)

        fileMenu.addItem(.separator())

        let shareItem = NSMenuItem(
            title: "Share...",
            action: #selector(AppDelegate.shareCurrentItem(_:)),
            keyEquivalent: ""
        )
        shareItem.target = target
        shareItem.image = icon("square.and.arrow.up")
        fileMenu.addItem(shareItem)

        fileMenu.addItem(.separator())

        let printItem = NSMenuItem(
            title: "Print...",
            action: #selector(AppDelegate.printDocument(_:)),
            keyEquivalent: "p"
        )
        printItem.target = target
        printItem.image = icon("printer")
        fileMenu.addItem(printItem)

        let fileMenuItem = NSMenuItem(title: "File", action: nil, keyEquivalent: "")
        fileMenuItem.submenu = fileMenu
        return fileMenuItem
    }

    // MARK: - Edit Menu

    private static func buildEditMenu(target: AppDelegate) -> NSMenuItem {
        let editMenu = NSMenu(title: "Edit")

        let undoItem = NSMenuItem(title: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        undoItem.image = icon("arrow.uturn.backward")
        editMenu.addItem(undoItem)

        let redoItem = NSMenuItem(title: "Redo", action: Selector(("redo:")), keyEquivalent: "Z")
        redoItem.image = icon("arrow.uturn.forward")
        editMenu.addItem(redoItem)

        editMenu.addItem(.separator())

        let cutItem = NSMenuItem(title: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        cutItem.image = icon("scissors")
        editMenu.addItem(cutItem)

        let copyItem = NSMenuItem(
            title: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c"
        )
        copyItem.image = icon("doc.on.doc")
        editMenu.addItem(copyItem)

        let pasteItem = NSMenuItem(
            title: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v"
        )
        pasteItem.image = icon("doc.on.clipboard")
        editMenu.addItem(pasteItem)

        let selectAllItem = NSMenuItem(
            title: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a"
        )
        selectAllItem.image = icon("checkmark.circle")
        editMenu.addItem(selectAllItem)

        editMenu.addItem(.separator())
        editMenu.addItem(actionItem(
            "Find in Document...", action: .find,
            key: "f", icon: "magnifyingglass", target: target
        ))

        let editMenuItem = NSMenuItem(title: "Edit", action: nil, keyEquivalent: "")
        editMenuItem.submenu = editMenu
        return editMenuItem
    }

    // MARK: - View Menu

    private static func buildViewMenu(target: AppDelegate) -> NSMenuItem {
        let viewMenu = NSMenu(title: "View")

        let libraryItem = NSMenuItem(
            title: "Show Library",
            action: #selector(AppDelegate.showLibrary(_:)),
            keyEquivalent: "L"
        )
        libraryItem.keyEquivalentModifierMask = [.command, .shift]
        libraryItem.target = target
        libraryItem.image = icon("books.vertical")
        viewMenu.addItem(libraryItem)

        viewMenu.addItem(.separator())
        viewMenu.addItem(actionItem(
            "Toggle Sidebar", action: .toggleSidebar,
            key: "s", modifiers: [.command, .option], icon: "sidebar.left", target: target
        ))
        viewMenu.addItem(actionItem(
            "Toggle Inspector", action: .toggleInspector,
            key: "i", modifiers: [.command, .option], icon: "sidebar.right", target: target
        ))
        viewMenu.addItem(actionItem(
            "Zen Mode", action: .toggleZenMode,
            key: ".", modifiers: [.command, .shift], icon: "eye", target: target
        ))
        viewMenu.addItem(.separator())
        viewMenu.addItem(actionItem(
            "Zoom In", action: .zoomIn,
            key: "=", icon: "plus.magnifyingglass", target: target
        ))
        viewMenu.addItem(actionItem(
            "Zoom Out", action: .zoomOut,
            key: "-", icon: "minus.magnifyingglass", target: target
        ))
        viewMenu.addItem(actionItem(
            "Zoom to Fit", action: .zoomToFit,
            key: "0", icon: "arrow.up.left.and.arrow.down.right", target: target
        ))
        viewMenu.addItem(.separator())
        viewMenu.addItem(actionItem(
            "Single Page", action: .displaySingle, icon: "doc", target: target
        ))
        viewMenu.addItem(actionItem(
            "Single Page Continuous", action: .displaySingleContinuous,
            icon: "doc.text", target: target
        ))
        viewMenu.addItem(actionItem(
            "Two Pages", action: .displayTwoUp, icon: "book.closed", target: target
        ))
        viewMenu.addItem(actionItem(
            "Two Pages Continuous", action: .displayTwoUpContinuous,
            icon: "book", target: target
        ))
        viewMenu.addItem(.separator())
        viewMenu.addItem(actionItem(
            "Rotate Clockwise", action: .rotateRight,
            key: "]", icon: "rotate.right", target: target
        ))
        viewMenu.addItem(actionItem(
            "Rotate Counter-Clockwise", action: .rotateLeft,
            key: "[", icon: "rotate.left", target: target
        ))

        let viewMenuItem = NSMenuItem(title: "View", action: nil, keyEquivalent: "")
        viewMenuItem.submenu = viewMenu
        return viewMenuItem
    }

    // MARK: - Go Menu

    private static func buildGoMenu(target: AppDelegate) -> NSMenuItem {
        let goMenu = NSMenu(title: "Go")

        let upKey = String(UnicodeScalar(NSUpArrowFunctionKey)!)
        let downKey = String(UnicodeScalar(NSDownArrowFunctionKey)!)
        let homeKey = String(UnicodeScalar(NSHomeFunctionKey)!)
        let endKey = String(UnicodeScalar(NSEndFunctionKey)!)

        goMenu.addItem(actionItem(
            "Back", action: .navigateBack,
            key: "[", modifiers: [.command, .option], icon: "chevron.backward", target: target
        ))
        goMenu.addItem(.separator())
        goMenu.addItem(actionItem(
            "Previous Page", action: .previousPage,
            key: upKey, icon: "chevron.up", target: target
        ))
        goMenu.addItem(actionItem(
            "Next Page", action: .nextPage,
            key: downKey, icon: "chevron.down", target: target
        ))
        goMenu.addItem(.separator())
        goMenu.addItem(actionItem(
            "First Page", action: .firstPage,
            key: homeKey, icon: "arrow.up.to.line", target: target
        ))
        goMenu.addItem(actionItem(
            "Last Page", action: .lastPage,
            key: endKey, icon: "arrow.down.to.line", target: target
        ))

        let goMenuItem = NSMenuItem(title: "Go", action: nil, keyEquivalent: "")
        goMenuItem.submenu = goMenu
        return goMenuItem
    }

    // MARK: - Window Menu

    private static func buildWindowMenu(target: AppDelegate) -> (NSMenuItem, NSMenu) {
        let windowMenu = NSMenu(title: "Window")

        let minimizeItem = NSMenuItem(
            title: "Minimize",
            action: #selector(NSWindow.performMiniaturize(_:)),
            keyEquivalent: "m"
        )
        minimizeItem.image = icon("minus.square")
        windowMenu.addItem(minimizeItem)

        let zoomItem = NSMenuItem(
            title: "Zoom",
            action: #selector(NSWindow.performZoom(_:)),
            keyEquivalent: ""
        )
        zoomItem.image = icon("macwindow")
        windowMenu.addItem(zoomItem)

        windowMenu.addItem(.separator())

        let nextTabItem = NSMenuItem(
            title: "Show Next Tab",
            action: #selector(AppDelegate.nextTab(_:)),
            keyEquivalent: "\t"
        )
        nextTabItem.keyEquivalentModifierMask = [.control]
        nextTabItem.target = target
        nextTabItem.image = icon("chevron.right")
        windowMenu.addItem(nextTabItem)

        let prevTabItem = NSMenuItem(
            title: "Show Previous Tab",
            action: #selector(AppDelegate.previousTab(_:)),
            keyEquivalent: "\t"
        )
        prevTabItem.keyEquivalentModifierMask = [.control, .shift]
        prevTabItem.target = target
        prevTabItem.image = icon("chevron.left")
        windowMenu.addItem(prevTabItem)

        windowMenu.addItem(.separator())

        let bringAllItem = NSMenuItem(
            title: "Bring All to Front",
            action: #selector(NSApplication.arrangeInFront(_:)),
            keyEquivalent: ""
        )
        bringAllItem.image = icon("rectangle.stack")
        windowMenu.addItem(bringAllItem)

        let windowMenuItem = NSMenuItem(title: "Window", action: nil, keyEquivalent: "")
        windowMenuItem.submenu = windowMenu
        return (windowMenuItem, windowMenu)
    }

    // MARK: - Help Menu

    private static func buildHelpMenu(target: AppDelegate) -> (NSMenuItem, NSMenu) {
        let helpMenu = NSMenu(title: "Help")

        helpMenu.addItem(actionItem(
            "Accessibility Check...", action: .accessibilityCheck,
            icon: "accessibility", target: target
        ))
        helpMenu.addItem(.separator())

        let exportLogsItem = NSMenuItem(
            title: "Export Logs...",
            action: #selector(AppDelegate.exportLogs(_:)),
            keyEquivalent: ""
        )
        exportLogsItem.target = target
        exportLogsItem.image = icon("doc.text")
        helpMenu.addItem(exportLogsItem)

        let helpMenuItem = NSMenuItem(title: "Help", action: nil, keyEquivalent: "")
        helpMenuItem.submenu = helpMenu
        return (helpMenuItem, helpMenu)
    }

    // MARK: - Helpers

    private static func icon(_ name: String) -> NSImage? {
        NSImage(systemSymbolName: name, accessibilityDescription: nil)
    }

    static func actionItem(
        _ title: String, action: DocumentAction,
        key: String = "", modifiers: NSEvent.ModifierFlags = [],
        icon symbolName: String = "", target: AppDelegate
    ) -> NSMenuItem {
        let item = NSMenuItem(
            title: title,
            action: #selector(AppDelegate.menuAction(_:)),
            keyEquivalent: key
        )
        item.keyEquivalentModifierMask = modifiers
        item.representedObject = action.rawValue
        item.target = target
        if !symbolName.isEmpty {
            item.image = icon(symbolName)
        }
        return item
    }
}

// swiftlint:enable function_body_length
