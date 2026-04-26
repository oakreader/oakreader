import SwiftUI

/// Unified settings view with left sidebar list navigation.
struct SettingsView: View {
    @Environment(\.dismiss) private var dismiss

    enum Tab: String, CaseIterable, Identifiable {
        case general
        case ai

        var id: String { rawValue }

        var label: String {
            switch self {
            case .general: return "General"
            case .ai: return "AI"
            }
        }

        var icon: String {
            switch self {
            case .general: return "gearshape"
            case .ai: return "brain"
            }
        }
    }

    @State private var selectedTab: Tab = .general

    var body: some View {
        HStack(spacing: 0) {
            sidebar
            Divider()
            detailPanel
        }
        .frame(width: 600, height: 480)
    }

    // MARK: - Sidebar

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("Settings")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
                .textCase(.uppercase)
                .padding(.horizontal, 12)
                .padding(.top, 12)
                .padding(.bottom, 6)

            ForEach(Tab.allCases) { tab in
                Button {
                    selectedTab = tab
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: tab.icon)
                            .font(.system(size: 13))
                            .frame(width: 18)
                        Text(tab.label)
                            .font(.system(size: 13))
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 5)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(
                        RoundedRectangle(cornerRadius: 5)
                            .fill(selectedTab == tab ? Color.accentColor.opacity(0.15) : .clear)
                    )
                }
                .buttonStyle(.plain)
                .foregroundStyle(selectedTab == tab ? Color.accentColor : .primary)
            }

            Spacer()
        }
        .padding(.horizontal, 8)
        .frame(width: 150)
        .background(Color(nsColor: .controlBackgroundColor))
    }

    // MARK: - Detail Panel

    private var detailPanel: some View {
        VStack(spacing: 0) {
            settingsHeader
            Divider()
            settingsContent
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var settingsHeader: some View {
        HStack {
            Text(selectedTab.label)
                .font(.headline)
            Spacer()
            Button("Done") { dismiss() }
                .keyboardShortcut(.defaultAction)
        }
        .padding()
    }

    @ViewBuilder
    private var settingsContent: some View {
        switch selectedTab {
        case .general:
            GeneralSettingsView()
        case .ai:
            AISettingsView()
        }
    }
}
