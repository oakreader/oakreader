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
        NavigationSplitView {
            List(Tab.allCases, selection: $selectedTab) { tab in
                Label(tab.label, systemImage: tab.icon)
                    .tag(tab)
            }
            .listStyle(.sidebar)
            .navigationSplitViewColumnWidth(min: 140, ideal: 160, max: 200)
        } detail: {
            settingsContent
                .navigationTitle(selectedTab.label)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Done") { dismiss() }
                            .keyboardShortcut(.defaultAction)
                    }
                }
        }
        .frame(width: 780, height: 580)
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
