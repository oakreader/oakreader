import SwiftUI
import AppKit

struct OakToolButton: View {
    let systemImage: String
    var isSelected: Bool = false
    /// Renders like the title-bar panel pills (`PillTabButton`): a neutral
    /// capsule fill that's always visible, never the blue accent tint. Used for
    /// the History close button so it matches the Metadata tab's look.
    var prominent: Bool = false
    var tooltip: String = ""
    var action: () -> Void

    @State private var isHovering = false
    // Inactive (kept-alive, opacity-0) tabs keep their AppKit tracking areas
    // live, so without this gate a background tab's tooltip fires when you hover
    // the *active* tab's overlapping content — e.g. the save button leaking
    // "Save to Reading List" over the Notes panel's close button.
    @Environment(\.isTabActive) private var isTabActive

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: OakStyle.Font.icon))
                .frame(width: 28, height: 28)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(foreground)
        .background {
            if prominent {
                Capsule().fill(backgroundColor)
            } else {
                RoundedRectangle(cornerRadius: OakStyle.Radius.standard).fill(backgroundColor)
            }
        }
        .onHover { isHovering = $0 }
        .accessibilityLabel(tooltip)
        .background(
            // Only the active tab arms the tooltip's tracking area; background
            // tabs would otherwise show their tooltip over the visible tab.
            TooltipTrigger(tooltip: isTabActive ? tooltip : "")
        )
    }

    private var foreground: Color {
        // Prominent buttons stay neutral (no accent tint) like the panel pills.
        if !prominent && isSelected { return Color.accentColor }
        return Color(nsColor: .labelColor)
    }

    private var backgroundColor: Color {
        if prominent {
            // Neutral capsule fill that appears only on hover (no persistent bg).
            return isHovering ? Color.primary.opacity(0.10) : .clear
        }
        if isSelected {
            return OakStyle.Colors.activeBackground
        } else if isHovering {
            return OakStyle.Colors.hoverBackground
        }
        return .clear
    }
}

// MARK: - NSView-based tooltip (renders in its own window, never clipped)

struct TooltipTrigger: NSViewRepresentable {
    let tooltip: String

    func makeNSView(context: Context) -> TooltipNSView {
        let view = TooltipNSView()
        view.toolTip = tooltip
        return view
    }

    func updateNSView(_ nsView: TooltipNSView, context: Context) {
        nsView.toolTip = tooltip
    }
}

class TooltipNSView: NSView {
    private var tooltipWindow: NSPanel?
    private var showTimer: Timer?
    private var trackingArea: NSTrackingArea?

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let existing = trackingArea {
            removeTrackingArea(existing)
        }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
            owner: self
        )
        addTrackingArea(area)
        trackingArea = area
    }

    override func mouseEntered(with event: NSEvent) {
        showTimer?.invalidate()
        showTimer = Timer.scheduledTimer(withTimeInterval: 0.6, repeats: false) { [weak self] _ in
            self?.showTooltip()
        }
    }

    override func mouseExited(with event: NSEvent) {
        showTimer?.invalidate()
        showTimer = nil
        hideTooltip()
    }

    override func removeFromSuperview() {
        showTimer?.invalidate()
        hideTooltip()
        super.removeFromSuperview()
    }

    private func showTooltip() {
        guard let tip = toolTip, !tip.isEmpty, let window = self.window else { return }

        let panel = NSPanel(
            contentRect: .zero,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: true
        )
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.level = .floating
        panel.hasShadow = true
        panel.ignoresMouseEvents = true

        let label = NSTextField(labelWithString: tip)
        label.font = OakStyle.Font.nsFont(size: OakStyle.Font.caption)
        label.textColor = .white
        label.alignment = .center
        label.sizeToFit()

        let padding = NSEdgeInsets(top: 3, left: 6, bottom: 3, right: 6)
        let bgWidth = label.frame.width + padding.left + padding.right
        let bgHeight = label.frame.height + padding.top + padding.bottom

        let container = NSView(frame: NSRect(x: 0, y: 0, width: bgWidth, height: bgHeight))
        container.wantsLayer = true
        container.layer?.backgroundColor = NSColor.darkGray.cgColor
        container.layer?.cornerRadius = 4

        label.frame.origin = NSPoint(x: padding.left, y: padding.bottom)
        container.addSubview(label)

        panel.contentView = container
        panel.setContentSize(NSSize(width: bgWidth, height: bgHeight))

        // Position below the button, centered
        let screenOrigin = window.convertPoint(toScreen: convert(NSPoint(x: bounds.midX, y: bounds.maxY), to: nil))
        let x = screenOrigin.x - bgWidth / 2
        let y = screenOrigin.y - bgHeight - bounds.height - 4
        panel.setFrameOrigin(NSPoint(x: x, y: y))

        panel.orderFront(nil)
        tooltipWindow = panel

        // Fade in
        panel.alphaValue = 0
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.12
            panel.animator().alphaValue = 1
        }
    }

    private func hideTooltip() {
        guard let panel = tooltipWindow else { return }
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.08
            panel.animator().alphaValue = 0
        }, completionHandler: {
            panel.orderOut(nil)
        })
        tooltipWindow = nil
    }
}
