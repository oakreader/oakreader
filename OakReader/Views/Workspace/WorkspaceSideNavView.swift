import SwiftUI

struct WorkspaceSideNavView: View {
    @Binding var studioTab: WorkspaceStudioTab?

    var body: some View {
        VStack(spacing: 2) {
            ForEach(WorkspaceStudioTab.allCases) { tab in
                Button {
                    if studioTab == tab {
                        studioTab = nil
                    } else {
                        studioTab = tab
                    }
                } label: {
                    Image(systemName: tab.systemImage)
                        .font(.system(size: OakStyle.Font.icon))
                        .frame(width: OakStyle.Size.buttonStandard, height: OakStyle.Size.buttonStandard)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .foregroundStyle(studioTab == tab ? Color.accentColor : Color(nsColor: .labelColor))
                .help(tab.label)
            }

            Spacer()
        }
        .padding(.top, 6)
        .frame(width: OakStyle.Size.sidenavWidth)
        .background(.thinMaterial)
    }
}
