import SwiftUI

struct SideNavView: View {
    @Binding var rightPanelMode: RightPanelMode?

    var body: some View {
        VStack(spacing: 2) {
            // Panel mode icons — right below settings button in tab bar
            ForEach(RightPanelMode.allCases) { mode in
                Button {
                    if rightPanelMode == mode {
                        rightPanelMode = nil
                    } else {
                        rightPanelMode = mode
                    }
                } label: {
                    Image(systemName: mode.systemImage)
                        .font(.system(size: 14))
                        .frame(width: 28, height: 28)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .foregroundStyle(rightPanelMode == mode ? Color.accentColor : Color(nsColor: .labelColor))
                .help(mode.label)
            }

            Spacer()
        }
        .padding(.top, 6)
        .frame(width: ZoteroStyle.Size.sidenavWidth)
        .background(ZoteroStyle.Colors.sidebarBackground)
    }
}
