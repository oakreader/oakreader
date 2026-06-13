import AppKit

enum CommandRegistry {
    static let commands: [PaletteCommand] = navigation + view + file + settings + search + theme

    // MARK: - Navigation (3)

    private static let navigation: [PaletteCommand] = [
        PaletteCommand(
            id: "nav.library",
            title: "Show Library",
            category: .navigation,
            icon: "books.vertical",
            shortcut: "\u{21E7}\u{2318}L",
            action: .selector(#selector(AppDelegate.showLibrary(_:)))
        ),
        PaletteCommand(
            id: "nav.nextTab",
            title: "Next Tab",
            category: .navigation,
            icon: "chevron.right",
            shortcut: "\u{2303}\u{21E5}",
            action: .selector(#selector(AppDelegate.nextTab(_:)))
        ),
        PaletteCommand(
            id: "nav.previousTab",
            title: "Previous Tab",
            category: .navigation,
            icon: "chevron.left",
            shortcut: "\u{2303}\u{21E7}\u{21E5}",
            action: .selector(#selector(AppDelegate.previousTab(_:)))
        ),
    ]

    // MARK: - View (11)

    private static let view: [PaletteCommand] = [
        PaletteCommand(
            id: "view.toggleSidebar",
            title: "Toggle Sidebar",
            category: .view,
            icon: "sidebar.left",
            shortcut: "\u{2325}\u{2318}S",
            context: .anyDocument,
            action: .documentAction(.toggleSidebar)
        ),
        PaletteCommand(
            id: "view.toggleInspector",
            title: "Toggle Inspector",
            category: .view,
            icon: "sidebar.right",
            shortcut: "\u{2325}\u{2318}I",
            context: .anyDocument,
            action: .documentAction(.toggleInspector)
        ),
        PaletteCommand(
            id: "view.zenMode",
            title: "Zen Mode",
            category: .view,
            icon: "eye",
            shortcut: "\u{21E7}\u{2318}.",
            context: .anyDocument,
            action: .documentAction(.toggleZenMode)
        ),
        PaletteCommand(
            id: "view.presentationMode",
            title: "Presentation Mode",
            category: .view,
            icon: "play.rectangle",
            shortcut: "\u{21E7}\u{2318}\u{23CE}",
            context: [.pdf],
            action: .documentAction(.togglePresentationMode)
        ),
        PaletteCommand(
            id: "view.zoomIn",
            title: "Zoom In",
            category: .view,
            icon: "plus.magnifyingglass",
            shortcut: "\u{2318}=",
            context: .anyDocument,
            action: .documentAction(.zoomIn)
        ),
        PaletteCommand(
            id: "view.zoomOut",
            title: "Zoom Out",
            category: .view,
            icon: "minus.magnifyingglass",
            shortcut: "\u{2318}-",
            context: .anyDocument,
            action: .documentAction(.zoomOut)
        ),
        PaletteCommand(
            id: "view.zoomToFit",
            title: "Zoom to Fit",
            category: .view,
            icon: "arrow.up.left.and.arrow.down.right",
            shortcut: "\u{2318}0",
            context: .anyDocument,
            action: .documentAction(.zoomToFit)
        ),
        PaletteCommand(
            id: "view.captureArea",
            title: "Capture Area",
            category: .view,
            icon: "rectangle.dashed",
            shortcut: "\u{21E7}\u{2318}A",
            context: [.pdf, .html],
            action: .documentAction(.snapshot)
        ),
        PaletteCommand(
            id: "view.displaySingle",
            title: "Single Page",
            category: .view,
            icon: "doc",
            context: [.pdf],
            action: .documentAction(.displaySingle)
        ),
        PaletteCommand(
            id: "view.displaySingleContinuous",
            title: "Single Page Continuous",
            category: .view,
            icon: "doc.text",
            context: [.pdf],
            action: .documentAction(.displaySingleContinuous)
        ),
        PaletteCommand(
            id: "view.displayTwoUp",
            title: "Two Pages",
            category: .view,
            icon: "book.closed",
            context: [.pdf],
            action: .documentAction(.displayTwoUp)
        ),
        PaletteCommand(
            id: "view.displayTwoUpContinuous",
            title: "Two Pages Continuous",
            category: .view,
            icon: "book",
            context: [.pdf],
            action: .documentAction(.displayTwoUpContinuous)
        ),
    ]

    // MARK: - File (9)

    private static let file: [PaletteCommand] = [
        PaletteCommand(
            id: "file.open",
            title: "Open...",
            category: .file,
            icon: "folder",
            shortcut: "\u{2318}O",
            action: .selector(#selector(AppDelegate.openDocument(_:)))
        ),
        PaletteCommand(
            id: "file.closeTab",
            title: "Close Tab",
            category: .file,
            icon: "xmark",
            shortcut: "\u{2318}W",
            context: .anyDocument,
            action: .selector(#selector(AppDelegate.closeTab(_:)))
        ),
        PaletteCommand(
            id: "file.save",
            title: "Save",
            category: .file,
            icon: "square.and.arrow.down",
            shortcut: "\u{2318}S",
            context: .anyDocument,
            action: .selector(#selector(AppDelegate.saveDocument(_:)))
        ),
        PaletteCommand(
            id: "file.saveAs",
            title: "Save As...",
            category: .file,
            icon: "square.and.arrow.down.on.square",
            shortcut: "\u{21E7}\u{2318}S",
            context: .anyDocument,
            action: .selector(#selector(AppDelegate.saveDocumentAs(_:)))
        ),
        PaletteCommand(
            id: "file.importZotero",
            title: "Import from Zotero...",
            category: .file,
            icon: "tray.and.arrow.down",
            action: .selector(#selector(AppDelegate.importFromZotero(_:)))
        ),
        PaletteCommand(
            id: "file.importFolder",
            title: "Import Folder...",
            category: .file,
            icon: "folder.badge.plus",
            action: .selector(#selector(AppDelegate.importFolder(_:)))
        ),
        PaletteCommand(
            id: "file.exportImages",
            title: "Export as Images...",
            category: .file,
            icon: "photo",
            shortcut: "\u{21E7}\u{2318}E",
            context: [.pdf],
            action: .selector(#selector(AppDelegate.exportAsImages(_:)))
        ),
        PaletteCommand(
            id: "file.exportText",
            title: "Export as Plain Text...",
            category: .file,
            icon: "doc.plaintext",
            context: [.pdf],
            action: .selector(#selector(AppDelegate.exportAsText(_:)))
        ),
        PaletteCommand(
            id: "file.print",
            title: "Print...",
            category: .file,
            icon: "printer",
            shortcut: "\u{2318}P",
            context: [.pdf],
            action: .selector(#selector(AppDelegate.printDocument(_:)))
        ),
        PaletteCommand(
            id: "file.exportBackup",
            title: "Export Library Backup...",
            category: .file,
            icon: "archivebox",
            action: .selector(#selector(AppDelegate.exportLibraryBackup(_:)))
        ),
        PaletteCommand(
            id: "file.restoreBackup",
            title: "Restore from Backup...",
            category: .file,
            icon: "arrow.down.doc",
            action: .selector(#selector(AppDelegate.restoreLibraryBackup(_:)))
        ),
    ]

    // MARK: - Settings

    private static let settings: [PaletteCommand] = [
        PaletteCommand(
            id: "settings.open",
            title: "Open Settings",
            category: .settings,
            icon: "gearshape",
            shortcut: "\u{2318},",
            action: .selector(#selector(AppDelegate.showSettingsWindow(_:)))
        ),
    ] + settingsDeepLinks

    private static let settingsDeepLinks: [PaletteCommand] = SettingsView.Tab.paletteTabs.map { tab in
        PaletteCommand(
            id: "settings.\(tab.rawValue)",
            title: "Settings: \(tab.label)",
            category: .settings,
            icon: tab.icon,
            action: .settingsTab(tab.rawValue)
        )
    }

    // MARK: - Search (1)

    private static let search: [PaletteCommand] = [
        PaletteCommand(
            id: "search.rebuildIndex",
            title: "Rebuild Search Index",
            category: .search,
            icon: "arrow.triangle.2.circlepath",
            action: .rebuildSearchIndex
        ),
    ]

    // MARK: - Theme (3)

    private static let theme: [PaletteCommand] = [
        PaletteCommand(
            id: "theme.light",
            title: "Switch to Light Mode",
            category: .theme,
            icon: "sun.max",
            action: .appearanceMode("light")
        ),
        PaletteCommand(
            id: "theme.dark",
            title: "Switch to Dark Mode",
            category: .theme,
            icon: "moon",
            action: .appearanceMode("dark")
        ),
        PaletteCommand(
            id: "theme.system",
            title: "Switch to System Mode",
            category: .theme,
            icon: "circle.lefthalf.filled",
            action: .appearanceMode("system")
        ),
    ]

}
