import Cocoa

enum SharingService {
    /// Present a system sharing picker anchored near the mouse location in the key window.
    static func share(items: [Any]) {
        guard !items.isEmpty else { return }

        let picker = NSSharingServicePicker(items: items)

        guard let window = NSApp.keyWindow,
              let contentView = window.contentView else {
            // Fallback: try to show at the mouse location in the main window
            if let mainWindow = NSApp.mainWindow, let view = mainWindow.contentView {
                let mouseInWindow = view.convert(NSEvent.mouseLocation, from: nil)
                let rect = NSRect(origin: mouseInWindow, size: .zero)
                picker.show(relativeTo: rect, of: view, preferredEdge: .minY)
            }
            return
        }

        let mouseInScreen = NSEvent.mouseLocation
        let mouseInWindow = window.convertPoint(fromScreen: mouseInScreen)
        let mouseInView = contentView.convert(mouseInWindow, from: nil)
        let rect = NSRect(origin: mouseInView, size: .zero)
        picker.show(relativeTo: rect, of: contentView, preferredEdge: .minY)
    }
}
