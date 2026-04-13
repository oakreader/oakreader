import SwiftUI

/// Chrome-style tab shape: subtle tapered sides, smooth rounded top corners,
/// and elegant concave bottom curves using cubic beziers for S-curve transitions.
struct ChromeTabShape: Shape {
    let topRadius: CGFloat
    let concaveRadius: CGFloat
    let taper: CGFloat

    init(topRadius: CGFloat = ZoteroStyle.Radius.standard,
         concaveRadius: CGFloat = ZoteroStyle.Radius.concave,
         taper: CGFloat = 2) {
        self.topRadius = topRadius
        self.concaveRadius = concaveRadius
        self.taper = taper
    }

    func path(in rect: CGRect) -> Path {
        let w = rect.width
        let h = rect.height
        let tr = topRadius
        let cr = concaveRadius

        let left = cr
        let right = w - cr

        var path = Path()

        // Bottom-left start
        path.move(to: CGPoint(x: 0, y: h))

        // Left concave S-curve
        path.addCurve(
            to: CGPoint(x: left, y: h - cr),
            control1: CGPoint(x: left * 0.72, y: h),
            control2: CGPoint(x: left, y: h - cr * 0.28)
        )

        // Up the left side with subtle inward taper
        path.addLine(to: CGPoint(x: left + taper, y: tr))

        // Top-left rounded corner
        path.addQuadCurve(
            to: CGPoint(x: left + taper + tr, y: 0),
            control: CGPoint(x: left + taper, y: 0)
        )

        // Across the top
        path.addLine(to: CGPoint(x: right - taper - tr, y: 0))

        // Top-right rounded corner
        path.addQuadCurve(
            to: CGPoint(x: right - taper, y: tr),
            control: CGPoint(x: right - taper, y: 0)
        )

        // Down the right side
        path.addLine(to: CGPoint(x: right, y: h - cr))

        // Right concave S-curve
        path.addCurve(
            to: CGPoint(x: w, y: h),
            control1: CGPoint(x: right, y: h - cr * 0.28),
            control2: CGPoint(x: right + cr * 0.28, y: h)
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

    private let cr: CGFloat = ZoteroStyle.Radius.concave

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
                .font(.system(size: ZoteroStyle.Font.body, weight: .regular))
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
                        width: ZoteroStyle.Size.closeButton,
                        height: ZoteroStyle.Size.closeButton
                    )
                    .background(
                        RoundedRectangle(cornerRadius: ZoteroStyle.Radius.small)
                            .fill(isCloseHovering ? Color.primary.opacity(0.1) : Color.clear)
                    )
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .onHover { isCloseHovering = $0 }
            .opacity(isActive || isHovering ? 1 : 0)
        }
        // Always use same padding (include concave space) so width never changes
        .padding(.leading, 12 + cr)
        .padding(.trailing, 12 + cr)
        .frame(height: ZoteroStyle.Size.tabHeight)
        .frame(minWidth: ZoteroStyle.Size.tabMin + cr * 2,
               maxWidth: ZoteroStyle.Size.tabMax + cr * 2)
        .foregroundStyle(isActive ? Color(nsColor: .labelColor) : Color(nsColor: .secondaryLabelColor))
        .background(tabShape)
        .contentShape(Rectangle())
        .onTapGesture { onSelect() }
        .onHover { isHovering = $0 }
        .zIndex(isActive ? 1 : 0)
    }

    @ViewBuilder
    private var tabShape: some View {
        if isActive {
            ChromeTabShape()
                .fill(Color(nsColor: .controlBackgroundColor))
        } else if isHovering {
            RoundedRectangle(cornerRadius: ZoteroStyle.Radius.standard)
                .fill(Color.primary.opacity(0.07))
                .padding(.horizontal, cr)
                .padding(.vertical, 5)
        }
        // Inactive + not hovering: no background
    }
}
