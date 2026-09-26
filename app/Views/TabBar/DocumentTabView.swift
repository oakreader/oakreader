import SwiftUI

/// Browser-style tab shape: straight vertical sides, rounded top corners,
/// and concave (inverse) arcs at the bottom corners where the tab meets the bar.
///
///      ╭──────────────╮
///      │              │
///  ────╯              ╰────
///
/// The concave arcs extend `cr` points beyond each side of the tab body.
struct BrowserTabShape: Shape {
    let topRadius: CGFloat
    let concaveRadius: CGFloat
    let showLeftConcave: Bool
    let showRightConcave: Bool

    init(topRadius: CGFloat = 8,
         concaveRadius: CGFloat = 10,
         showLeftConcave: Bool = true,
         showRightConcave: Bool = true) {
        self.topRadius = topRadius
        self.concaveRadius = concaveRadius
        self.showLeftConcave = showLeftConcave
        self.showRightConcave = showRightConcave
    }

    func path(in rect: CGRect) -> Path {
        let w = rect.width
        let h = rect.height
        let r = topRadius
        let cr = concaveRadius

        var path = Path()

        if showLeftConcave {
            // Start at bottom-left outside
            path.move(to: CGPoint(x: 0, y: h))

            // Left concave arc (╯)
            path.addArc(
                center: CGPoint(x: 0, y: h - cr),
                radius: cr,
                startAngle: .degrees(90),
                endAngle: .degrees(0),
                clockwise: true
            )

            // Straight up the left side
            path.addLine(to: CGPoint(x: cr, y: r))

            // Top-left rounded corner
            path.addArc(
                center: CGPoint(x: cr + r, y: r),
                radius: r,
                startAngle: .degrees(180),
                endAngle: .degrees(270),
                clockwise: false
            )
        } else {
            // Start at bottom-left, straight up
            path.move(to: CGPoint(x: cr, y: h))
            path.addLine(to: CGPoint(x: cr, y: r))

            // Top-left rounded corner
            path.addArc(
                center: CGPoint(x: cr + r, y: r),
                radius: r,
                startAngle: .degrees(180),
                endAngle: .degrees(270),
                clockwise: false
            )
        }

        // Across the top
        path.addLine(to: CGPoint(x: w - cr - r, y: 0))

        if showRightConcave {
            // Top-right rounded corner
            path.addArc(
                center: CGPoint(x: w - cr - r, y: r),
                radius: r,
                startAngle: .degrees(270),
                endAngle: .degrees(0),
                clockwise: false
            )

            // Straight down the right side
            path.addLine(to: CGPoint(x: w - cr, y: h - cr))

            // Right concave arc (╰)
            path.addArc(
                center: CGPoint(x: w, y: h - cr),
                radius: cr,
                startAngle: .degrees(180),
                endAngle: .degrees(90),
                clockwise: true
            )

            // Bottom edge back to start
            path.addLine(to: CGPoint(x: 0, y: h))
        } else {
            // Top-right rounded corner
            path.addArc(
                center: CGPoint(x: w - cr - r, y: r),
                radius: r,
                startAngle: .degrees(270),
                endAngle: .degrees(0),
                clockwise: false
            )

            // Straight down the right side
            path.addLine(to: CGPoint(x: w - cr, y: h))
            path.addLine(to: CGPoint(x: cr, y: h))
        }

        return path
    }
}

struct DocumentTabView: View {
    let tab: DocumentTab
    let isActive: Bool
    let isFirst: Bool
    /// Chrome-style divider on the leading edge. The strip decides this: a seam's
    /// line shows only when neither adjacent tab is active or hovered (a highlighted
    /// tab carries its own shape and absorbs the dividers on both of its sides).
    let showLeadingSeparator: Bool
    let width: CGFloat
    let onSelect: () -> Void
    let onClose: () -> Void
    let onHoverChanged: (Bool) -> Void

    @State private var isHovering = false
    @State private var isCloseHovering = false

    private let cr: CGFloat = 10  // concave radius

    var body: some View {
        HStack(spacing: 6) {
            // Title — for web tabs this tracks the live page title across navigation
            Text(tab.displayTitle)
                .font(OakStyle.Font.styled(size: OakStyle.Font.body, weight: .regular))
                .lineLimit(1)
                .truncationMode(.middle)
                .help(tab.displayTitle)

            Spacer(minLength: 0)

            // Close button — always reserves space, visible on hover/active
            Button {
                onClose()
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(isCloseHovering ? Color(nsColor: .labelColor) : .secondary)
                    .frame(
                        width: OakStyle.Size.closeButton,
                        height: OakStyle.Size.closeButton
                    )
                    .background(
                        RoundedRectangle(cornerRadius: OakStyle.Radius.small)
                            .fill(isCloseHovering ? Color.primary.opacity(0.1) : Color.clear)
                    )
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .onHover { isCloseHovering = $0 }
            .opacity(isActive || isHovering ? 1 : 0)
            .accessibilityLabel("Close \(tab.displayTitle)")
        }
        .padding(.leading, 10 + cr)
        .padding(.trailing, 10 + cr)
        .frame(width: width, height: OakStyle.Size.tabHeight)
        .foregroundStyle(isActive ? Color(nsColor: .labelColor) : Color(nsColor: .secondaryLabelColor))
        .background(tabShape)
        .overlay(alignment: .leading) {
            // Sits in the seam: tabs overlap by `cr - 3`, so this frame's leading
            // edge lands at the shared boundary between this tab and the previous.
            Rectangle()
                .fill(Color(nsColor: .separatorColor))
                .frame(width: 1, height: 16)
                .opacity(showLeadingSeparator ? 1 : 0)
                .animation(.easeOut(duration: 0.12), value: showLeadingSeparator)
        }
        .padding(.leading, isFirst ? 0 : -cr + 3)
        .padding(.trailing, -cr + 3)
        .zIndex(isActive ? 2 : isHovering ? 1 : 0)
        .contentShape(Rectangle())
        .onTapGesture { onSelect() }
        .onHover { isHovering = $0; onHoverChanged($0) }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Tab: \(tab.displayTitle)")
        .accessibilityAddTraits(isActive ? .isSelected : [])
        .accessibilityHint("Double-click to switch to this tab")
    }

    @ViewBuilder
    private var tabShape: some View {
        if isActive {
            BrowserTabShape(concaveRadius: cr)
                .fill(OakStyle.Colors.activeTabBackground)
                .padding(.top, 6)
        } else if isHovering {
            RoundedRectangle(cornerRadius: OakStyle.Radius.standard)
                .fill(Color.primary.opacity(0.08))
                .padding(.horizontal, cr)
                .padding(.vertical, 5)
        }
        // Inactive + not hovering: transparent
    }
}
