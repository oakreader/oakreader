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
            // Panel mode icons — glass button group
            VStack(spacing: 2) {
                ForEach(visibleModes) { mode in
                    let isActive = rightPanelMode == mode
                    Button {
                        if rightPanelMode == mode {
                            rightPanelMode = nil
                        } else {
                            rightPanelMode = mode
                        }
                    } label: {
                        Image(systemName: mode.systemImage)
                            .font(.system(size: 12, weight: .medium))
                            .frame(width: 24, height: 24)
                            .background(
                                Circle()
                                    .fill(isActive ? Color.primary.opacity(0.12) : Color.clear)
                            )
                            .contentShape(Circle())
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(isActive ? Color(nsColor: .labelColor) : Color(nsColor: .secondaryLabelColor))
                    .help(mode.label)
                }
            }
            .padding(3)
            .modifier(SideNavGlassModifier())

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

// MARK: - Glass Group Modifier (vertical)

private struct SideNavGlassModifier: ViewModifier {
    func body(content: Content) -> some View {
        if #available(macOS 26, *) {
            content
                .glassEffect(.regular.interactive(), in: .capsule)
        } else {
            content
                .background(
                    .ultraThinMaterial,
                    in: Capsule()
                )
                .overlay(
                    Capsule()
                        .strokeBorder(Color.primary.opacity(0.1), lineWidth: 0.5)
                )
        }
    }
}
