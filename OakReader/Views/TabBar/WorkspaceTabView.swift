import SwiftUI

struct WorkspaceTabView: View {
    let tab: WorkspaceTab
    let isActive: Bool
    let isFirst: Bool
    let onSelect: () -> Void
    let onClose: () -> Void

    @State private var isHovering = false
    @State private var isCloseHovering = false

    private let cr: CGFloat = 10  // concave radius

    var body: some View {
        HStack(spacing: 6) {
            // Workspace icon
            Image(systemName: "sparkles")
                .font(.system(size: 10))
                .foregroundStyle(.secondary)

            // Title
            Text(tab.title)
                .font(OakStyle.Font.styled(size: OakStyle.Font.body, weight: .regular))
                .lineLimit(1)
                .truncationMode(.middle)

            Spacer(minLength: 0)

            // Close button
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
            .accessibilityLabel("Close \(tab.title)")
        }
        .padding(.leading, 10 + cr)
        .padding(.trailing, 10 + cr)
        .frame(height: OakStyle.Size.tabHeight)
        .frame(minWidth: OakStyle.Size.tabMin + cr * 2,
               maxWidth: OakStyle.Size.tabMax + cr * 2)
        .foregroundStyle(isActive ? Color(nsColor: .labelColor) : Color(nsColor: .secondaryLabelColor))
        .background(tabShape)
        .padding(.leading, isFirst ? 0 : -cr + 3)
        .padding(.trailing, -cr + 3)
        .zIndex(isActive ? 2 : isHovering ? 1 : 0)
        .contentShape(Rectangle())
        .onTapGesture { onSelect() }
        .onHover { isHovering = $0 }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Workspace: \(tab.title)")
        .accessibilityAddTraits(isActive ? .isSelected : [])
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
    }
}
