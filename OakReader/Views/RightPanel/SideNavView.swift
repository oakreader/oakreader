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
        VStack(spacing: 4) {
            ForEach(visibleModes) { mode in
                SideNavButtonView(mode: mode, rightPanelMode: $rightPanelMode)
            }

            Spacer()
        }
        .padding(.top, 6)
        .frame(width: OakStyle.Size.sidenavWidth)
        .background {
            if #available(macOS 26, *) {
                Color.clear.glassEffect(.regular, in: .rect)
            } else {
                Color.clear.background(.thinMaterial)
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: UserDefaults.didChangeNotification)) { _ in
            let modes = visibleModes
            if let current = rightPanelMode, !modes.contains(current) {
                rightPanelMode = nil
            }
            pluginRefresh.toggle()
        }
    }
}

// MARK: - Side Nav Button

private struct SideNavButtonView: View {
    let mode: RightPanelMode
    @Binding var rightPanelMode: RightPanelMode?

    @State private var isHovering = false

    private var isActive: Bool {
        rightPanelMode == mode
    }

    private var fillOpacity: Double {
        if isActive { return 0.12 }
        if isHovering { return 0.07 }
        return 0
    }

    var body: some View {
        Button {
            if rightPanelMode == mode {
                rightPanelMode = nil
            } else {
                rightPanelMode = mode
            }
        } label: {
            Image(systemName: mode.systemImage)
                .font(.system(size: 14, weight: .medium))
                .frame(width: 34, height: 26)
                .background(
                    Capsule()
                        .fill(Color.primary.opacity(fillOpacity))
                )
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .foregroundStyle(isActive ? Color(nsColor: .labelColor) : Color(nsColor: .secondaryLabelColor))
        .onHover { isHovering = $0 }
        .animation(.easeInOut(duration: 0.15), value: isActive)
        .animation(.easeInOut(duration: 0.12), value: isHovering)
        .help(mode.label)
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
