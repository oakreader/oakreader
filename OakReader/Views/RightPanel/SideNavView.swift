import SwiftUI

struct SideNavView: View {
    @Binding var rightPanelMode: RightPanelMode?

    var body: some View {
        VStack(spacing: 2) {
            ForEach(RightPanelMode.allCases) { mode in
                Button {
                    if rightPanelMode == mode {
                        rightPanelMode = nil
                    } else {
                        rightPanelMode = mode
                    }
                } label: {
                    Image(systemName: mode.systemImage)
                        .font(.system(size: 12))
                        .frame(width: 24, height: 24)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .foregroundStyle(rightPanelMode == mode ? Color.accentColor : Color(nsColor: .labelColor))
                .help(mode.label)
            }
            Spacer()
        }
        .padding(.top, ZoteroStyle.Spacing.xs)
        .frame(width: ZoteroStyle.Size.sidenavWidth)
        .background(ZoteroStyle.Colors.sidebarBackground)
    }
}
