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
                        .font(.system(size: mode == .aiChat ? 14 : OakStyle.Font.icon))
                        .frame(width: OakStyle.Size.buttonStandard, height: OakStyle.Size.buttonStandard)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .foregroundStyle(rightPanelMode == mode ? Color.accentColor : Color(nsColor: .labelColor))
                .help(mode.label)
            }

            Spacer()
        }
        .padding(.top, 6)
        .frame(width: OakStyle.Size.sidenavWidth)
        .background(.thinMaterial)
    }
}
