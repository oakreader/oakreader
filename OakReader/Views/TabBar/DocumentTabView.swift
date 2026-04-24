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

    init(topRadius: CGFloat = 10,
         concaveRadius: CGFloat = 10) {
        self.topRadius = topRadius
        self.concaveRadius = concaveRadius
    }

    func path(in rect: CGRect) -> Path {
        let w = rect.width
        let h = rect.height
        let r = topRadius
        let cr = concaveRadius

        var path = Path()

        // Start at bottom-left outside
        path.move(to: CGPoint(x: 0, y: h))

        // Left concave arc (╯): bows outward, from bottom bar up to tab edge
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

        // Across the top
        path.addLine(to: CGPoint(x: w - cr - r, y: 0))

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

        // Right concave arc (╰): bows outward, from tab edge down to bottom bar
        path.addArc(
            center: CGPoint(x: w, y: h - cr),
            radius: cr,
            startAngle: .degrees(180),
            endAngle: .degrees(90),
            clockwise: true
        )

        // Bottom edge back to start
        path.addLine(to: CGPoint(x: 0, y: h))

        return path
    }
}

struct DocumentTabView: View {
    let tab: DocumentTab
    let isActive: Bool
    let onSelect: () -> Void
    let onClose: () -> Void

    @State private var isHovering = false
    @State private var isCloseHovering = false

    private let cr: CGFloat = 10  // concave radius

    var body: some View {
        HStack(spacing: 6) {
            // Dirty indicator
            if tab.isDirty {
                Circle()
                    .fill(Color(hex: "FF8C19"))
                    .frame(width: 6, height: 6)
            }

            // Title
            Text(tab.title)
                .font(.system(size: OakStyle.Font.body, weight: .regular))
                .lineLimit(1)
                .truncationMode(.middle)

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
        }
        .padding(.leading, 12 + cr)
        .padding(.trailing, 12 + cr)
        .frame(height: OakStyle.Size.tabHeight)
        .frame(minWidth: OakStyle.Size.tabMin + cr * 2,
               maxWidth: OakStyle.Size.tabMax + cr * 2)
        .foregroundStyle(isActive ? Color(nsColor: .labelColor) : Color(nsColor: .secondaryLabelColor))
        .background(tabShape)
        .contentShape(Rectangle())
        .onTapGesture { onSelect() }
        .onHover { isHovering = $0 }
    }

    @ViewBuilder
    private var tabShape: some View {
        if isActive {
            BrowserTabShape(concaveRadius: cr)
                .fill(OakStyle.Colors.activeTabBackground)
        } else if isHovering {
            RoundedRectangle(cornerRadius: OakStyle.Radius.standard)
                .fill(Color.primary.opacity(0.08))
                .padding(.horizontal, cr)
                .padding(.vertical, 5)
        }
        // Inactive + not hovering: transparent
    }
}
