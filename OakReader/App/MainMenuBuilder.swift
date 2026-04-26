import Cocoa

enum MainMenuBuilder {
    static func build(target: AppDelegate) -> NSMenu {
        let mainMenu = NSMenu()

        // App menu
        mainMenu.addItem(buildAppMenu())

        // File menu
        mainMenu.addItem(buildFileMenu(target: target))

        // Edit menu
        mainMenu.addItem(buildEditMenu(target: target))

        // View menu
        mainMenu.addItem(buildViewMenu(target: target))

        // Go menu
        mainMenu.addItem(buildGoMenu(target: target))

        // Tools menu
        mainMenu.addItem(buildToolsMenu(target: target))

        // Window menu
        let (windowMenuItem, windowMenu) = buildWindowMenu(target: target)
        mainMenu.addItem(windowMenuItem)
        NSApp.windowsMenu = windowMenu

        // Help menu
        let (helpMenuItem, helpMenu) = buildHelpMenu()
        mainMenu.addItem(helpMenuItem)
        NSApp.helpMenu = helpMenu

        return mainMenu
    }

    // MARK: - App Menu

    private static func buildAppMenu() -> NSMenuItem {
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
        return appMenuItem
    }

    // MARK: - File Menu

    private static func buildFileMenu(target: AppDelegate) -> NSMenuItem {
        let fileMenu = NSMenu(title: "File")

        let newItem = NSMenuItem(title: "New Blank PDF", action: #selector(AppDelegate.newBlankDocument(_:)), keyEquivalent: "n")
        newItem.target = target
        fileMenu.addItem(newItem)

        let createFromImagesItem = NSMenuItem(title: "New from Images...", action: #selector(AppDelegate.createFromImages(_:)), keyEquivalent: "")
        createFromImagesItem.target = target
        fileMenu.addItem(createFromImagesItem)

        fileMenu.addItem(.separator())

        let openItem = NSMenuItem(title: "Open...", action: #selector(AppDelegate.openDocument(_:)), keyEquivalent: "o")
        openItem.target = target
        fileMenu.addItem(openItem)

        // Open Recent
        let openRecentMenu = NSMenu(title: "Open Recent")
        let clearRecentItem = NSMenuItem(title: "Clear Menu", action: #selector(NSDocumentController.clearRecentDocuments(_:)), keyEquivalent: "")
        openRecentMenu.addItem(clearRecentItem)
        let openRecentItem = NSMenuItem(title: "Open Recent", action: nil, keyEquivalent: "")
        openRecentItem.submenu = openRecentMenu
        fileMenu.addItem(openRecentItem)

        fileMenu.addItem(.separator())

        let closeItem = NSMenuItem(title: "Close Tab", action: #selector(AppDelegate.closeTab(_:)), keyEquivalent: "w")
        closeItem.target = target
        fileMenu.addItem(closeItem)

        let saveItem = NSMenuItem(title: "Save", action: #selector(AppDelegate.saveDocument(_:)), keyEquivalent: "s")
        saveItem.target = target
        fileMenu.addItem(saveItem)

        let saveAsItem = NSMenuItem(title: "Save As...", action: #selector(AppDelegate.saveDocumentAs(_:)), keyEquivalent: "S")
        saveAsItem.target = target
        fileMenu.addItem(saveAsItem)

        let revertItem = NSMenuItem(title: "Revert to Saved", action: #selector(AppDelegate.revertDocument(_:)), keyEquivalent: "")
        revertItem.target = target
        fileMenu.addItem(revertItem)

        fileMenu.addItem(.separator())

        // Export As submenu
        let exportMenu = NSMenu(title: "Export As")
        let expImgItem = NSMenuItem(title: "Images (JPEG, PNG, TIFF)...", action: #selector(AppDelegate.exportAsImages(_:)), keyEquivalent: "e")
        expImgItem.keyEquivalentModifierMask = [.command, .shift]
        expImgItem.target = target
        exportMenu.addItem(expImgItem)
        let expTxtItem = NSMenuItem(title: "Plain Text...", action: #selector(AppDelegate.exportAsText(_:)), keyEquivalent: "")
        expTxtItem.target = target
        exportMenu.addItem(expTxtItem)
        let exportSubItem = NSMenuItem(title: "Export As", action: nil, keyEquivalent: "")
        exportSubItem.submenu = exportMenu
        fileMenu.addItem(exportSubItem)

        fileMenu.addItem(.separator())

        let printItem = NSMenuItem(title: "Print...", action: #selector(AppDelegate.printDocument(_:)), keyEquivalent: "p")
        printItem.target = target
        fileMenu.addItem(printItem)

        let fileMenuItem = NSMenuItem(title: "File", action: nil, keyEquivalent: "")
        fileMenuItem.submenu = fileMenu
        return fileMenuItem
    }

    // MARK: - Edit Menu

    private static func buildEditMenu(target: AppDelegate) -> NSMenuItem {
        let editMenu = NSMenu(title: "Edit")
        editMenu.addItem(NSMenuItem(title: "Undo", action: Selector(("undo:")), keyEquivalent: "z"))
        editMenu.addItem(NSMenuItem(title: "Redo", action: Selector(("redo:")), keyEquivalent: "Z"))
        editMenu.addItem(.separator())
        editMenu.addItem(NSMenuItem(title: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x"))
        editMenu.addItem(NSMenuItem(title: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c"))
        editMenu.addItem(NSMenuItem(title: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v"))
        editMenu.addItem(NSMenuItem(title: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a"))
        editMenu.addItem(.separator())
        let findItem = actionMenuItem("Find in Document...", action: .find, key: "f", target: target)
        editMenu.addItem(findItem)

        let editMenuItem = NSMenuItem(title: "Edit", action: nil, keyEquivalent: "")
        editMenuItem.submenu = editMenu
        return editMenuItem
    }

    // MARK: - View Menu

    private static func buildViewMenu(target: AppDelegate) -> NSMenuItem {
        let viewMenu = NSMenu(title: "View")

        let libraryItem = NSMenuItem(title: "Show Library", action: #selector(AppDelegate.showLibrary(_:)), keyEquivalent: "L")
        libraryItem.keyEquivalentModifierMask = [.command, .shift]
        libraryItem.target = target
        viewMenu.addItem(libraryItem)

        viewMenu.addItem(.separator())
        viewMenu.addItem(actionMenuItem("Toggle Sidebar", action: .toggleSidebar, key: "s", modifiers: [.command, .option], target: target))
        viewMenu.addItem(actionMenuItem("Toggle Inspector", action: .toggleInspector, key: "i", modifiers: [.command, .option], target: target))
        viewMenu.addItem(.separator())
        viewMenu.addItem(actionMenuItem("Zoom In", action: .zoomIn, key: "=", modifiers: [.command], target: target))
        viewMenu.addItem(actionMenuItem("Zoom Out", action: .zoomOut, key: "-", modifiers: [.command], target: target))
        viewMenu.addItem(actionMenuItem("Zoom to Fit", action: .zoomToFit, key: "0", modifiers: [.command], target: target))
        viewMenu.addItem(.separator())
        viewMenu.addItem(actionMenuItem("Single Page", action: .displaySingle, target: target))
        viewMenu.addItem(actionMenuItem("Single Page Continuous", action: .displaySingleContinuous, target: target))
        viewMenu.addItem(actionMenuItem("Two Pages", action: .displayTwoUp, target: target))
        viewMenu.addItem(actionMenuItem("Two Pages Continuous", action: .displayTwoUpContinuous, target: target))

        let viewMenuItem = NSMenuItem(title: "View", action: nil, keyEquivalent: "")
        viewMenuItem.submenu = viewMenu
        return viewMenuItem
    }

    // MARK: - Go Menu

    private static func buildGoMenu(target: AppDelegate) -> NSMenuItem {
        let goMenu = NSMenu(title: "Go")
        goMenu.addItem(actionMenuItem("Back", action: .navigateBack, key: "[", modifiers: [.command, .option], target: target))
        goMenu.addItem(.separator())
        goMenu.addItem(actionMenuItem("Previous Page", action: .previousPage, key: String(UnicodeScalar(NSUpArrowFunctionKey)!), modifiers: [.command], target: target))
        goMenu.addItem(actionMenuItem("Next Page", action: .nextPage, key: String(UnicodeScalar(NSDownArrowFunctionKey)!), modifiers: [.command], target: target))
        goMenu.addItem(.separator())
        goMenu.addItem(actionMenuItem("First Page", action: .firstPage, key: String(UnicodeScalar(NSHomeFunctionKey)!), modifiers: [.command], target: target))
        goMenu.addItem(actionMenuItem("Last Page", action: .lastPage, key: String(UnicodeScalar(NSEndFunctionKey)!), modifiers: [.command], target: target))

        let goMenuItem = NSMenuItem(title: "Go", action: nil, keyEquivalent: "")
        goMenuItem.submenu = goMenu
        return goMenuItem
    }

    // MARK: - Tools Menu

    private static func buildToolsMenu(target: AppDelegate) -> NSMenuItem {
        let toolsMenu = NSMenu(title: "Tools")
        toolsMenu.addItem(actionMenuItem("Run OCR", action: .runOCR, key: "r", modifiers: [.command, .shift], target: target))
        toolsMenu.addItem(.separator())
        toolsMenu.addItem(actionMenuItem("Rotate Clockwise", action: .rotateRight, key: "]", modifiers: [.command], target: target))
        toolsMenu.addItem(actionMenuItem("Rotate Counter-Clockwise", action: .rotateLeft, key: "[", modifiers: [.command], target: target))
        toolsMenu.addItem(.separator())
        toolsMenu.addItem(actionMenuItem("Accessibility Check...", action: .accessibilityCheck, target: target))

        let toolsMenuItem = NSMenuItem(title: "Tools", action: nil, keyEquivalent: "")
        toolsMenuItem.submenu = toolsMenu
        return toolsMenuItem
    }

    // MARK: - Window Menu

    private static func buildWindowMenu(target: AppDelegate) -> (NSMenuItem, NSMenu) {
        let windowMenu = NSMenu(title: "Window")
        windowMenu.addItem(NSMenuItem(title: "Minimize", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m"))
        windowMenu.addItem(NSMenuItem(title: "Zoom", action: #selector(NSWindow.performZoom(_:)), keyEquivalent: ""))
        windowMenu.addItem(.separator())

        let nextTabItem = NSMenuItem(title: "Show Next Tab", action: #selector(AppDelegate.nextTab(_:)), keyEquivalent: "\t")
        nextTabItem.keyEquivalentModifierMask = [.control]
        nextTabItem.target = target
        windowMenu.addItem(nextTabItem)

        let prevTabItem = NSMenuItem(title: "Show Previous Tab", action: #selector(AppDelegate.previousTab(_:)), keyEquivalent: "\t")
        prevTabItem.keyEquivalentModifierMask = [.control, .shift]
        prevTabItem.target = target
        windowMenu.addItem(prevTabItem)

        windowMenu.addItem(.separator())
        windowMenu.addItem(NSMenuItem(title: "Bring All to Front", action: #selector(NSApplication.arrangeInFront(_:)), keyEquivalent: ""))

        let windowMenuItem = NSMenuItem(title: "Window", action: nil, keyEquivalent: "")
        windowMenuItem.submenu = windowMenu
        return (windowMenuItem, windowMenu)
    }

    // MARK: - Help Menu

    private static func buildHelpMenu() -> (NSMenuItem, NSMenu) {
        let helpMenu = NSMenu(title: "Help")
        let helpMenuItem = NSMenuItem(title: "Help", action: nil, keyEquivalent: "")
        helpMenuItem.submenu = helpMenu
        return (helpMenuItem, helpMenu)
    }

    // MARK: - Action Menu Item Helper

    static func actionMenuItem(_ title: String, action: DocumentAction, key: String = "", modifiers: NSEvent.ModifierFlags = [], target: AppDelegate) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: #selector(AppDelegate.menuAction(_:)), keyEquivalent: key)
        item.keyEquivalentModifierMask = modifiers
        item.representedObject = action.rawValue
        item.target = target
        return item
    }
}
