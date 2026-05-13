import SwiftUI

struct SideNavView: View {
    @Binding var rightPanelMode: RightPanelMode?

    /// Bumped by UserDefaults observer to force SwiftUI to re-evaluate visibleModes.
    @State private var pluginRefresh = false

    private var visibleModes: [RightPanelMode] {
        _ = pluginRefresh // read to establish dependency
        let disabledModes = AppExtension.allCases
            .filter { !Preferences.shared.isExtensionEnabled($0) }
            .flatMap(\.rightPanelModes)
        return RightPanelMode.allCases.filter { !disabledModes.contains($0) }
    }

    var body: some View {
        VStack(spacing: 2) {
            // Panel mode icons — right below settings button in tab bar
            ForEach(visibleModes) { mode in
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
        .onReceive(NotificationCenter.default.publisher(for: UserDefaults.didChangeNotification)) { _ in
            let modes = visibleModes
            if let current = rightPanelMode, !modes.contains(current) {
                rightPanelMode = nil
            }
            pluginRefresh.toggle()
        }
    }
}
