import AppKit
import SwiftUI

/// A full-screen image lightbox shown in a borderless window over the whole app —
/// click anywhere (or press Esc) to dismiss. Used by Notes cards to preview an
/// attached image at full size, the way flomo opens an image.
@MainActor
enum ImageLightbox {
    private static var window: NSWindow?
    private static var escMonitor: Any?

    static func show(url urlString: String) {
        guard let url = URL(string: urlString),
              let image = NSImage(contentsOf: url),
              let screen = NSScreen.main else { return }
        dismiss()

        let win = NSWindow(contentRect: screen.frame,
                           styleMask: .borderless,
                           backing: .buffered,
                           defer: false)
        win.isOpaque = false
        win.backgroundColor = NSColor.black.withAlphaComponent(0.92)
        win.level = .modalPanel
        win.isReleasedWhenClosed = false
        win.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        win.contentView = NSHostingView(rootView: ImageLightboxView(image: image, onClose: dismiss))
        win.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        window = win

        // A borderless window won't reliably receive SwiftUI keyboard shortcuts,
        // so catch Esc with a local monitor.
        escMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            if event.keyCode == 53 { dismiss(); return nil }   // Esc
            return event
        }
    }

    static func dismiss() {
        if let monitor = escMonitor { NSEvent.removeMonitor(monitor); escMonitor = nil }
        window?.orderOut(nil)
        window = nil
    }
}

private struct ImageLightboxView: View {
    let image: NSImage
    let onClose: () -> Void

    var body: some View {
        ZStack(alignment: .topTrailing) {
            Color.clear
                .contentShape(Rectangle())
                .onTapGesture(perform: onClose)

            Image(nsImage: image)
                .resizable()
                .scaledToFit()
                .padding(48)
                .onTapGesture(perform: onClose)

            Button(action: onClose) {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 26))
                    .foregroundStyle(.white.opacity(0.85))
                    .padding(20)
            }
            .buttonStyle(.plain)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
