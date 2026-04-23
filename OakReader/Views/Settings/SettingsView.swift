import SwiftUI
import OakReaderAI

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
            // Left sidebar list
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

            Divider()

            // Right content — both tabs always exist, toggle visibility to avoid re-creation lag
            ZStack {
                VStack(spacing: 0) {
                    settingsHeader("General")
                    Divider()
                    GeneralSettingsTab()
                }
                .opacity(selectedTab == .general ? 1 : 0)
                .allowsHitTesting(selectedTab == .general)

                VStack(spacing: 0) {
                    settingsHeader("AI")
                    Divider()
                    AISettingsTab()
                }
                .opacity(selectedTab == .ai ? 1 : 0)
                .allowsHitTesting(selectedTab == .ai)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(width: 600, height: 480)
    }

    private func settingsHeader(_ title: String) -> some View {
        HStack {
            Text(title)
                .font(.headline)
            Spacer()
            Button("Done") { dismiss() }
                .keyboardShortcut(.defaultAction)
        }
        .padding()
    }
}

// MARK: - General Settings

private struct GeneralSettingsTab: View {
    @State private var dataDirectory: String = ""
    @State private var autoSave: Bool = Preferences.shared.autoSave
    @State private var showStatusBar: Bool = Preferences.shared.showStatusBar

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                // Data Directory Location
                VStack(alignment: .leading, spacing: 8) {
                    Text("Data Directory Location")
                        .font(.system(size: 13, weight: .bold))

                    Text("OakReader stores your library, PDFs, and metadata in this directory.")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)

                    HStack(spacing: 8) {
                        Text("Data directory:")
                            .font(.system(size: 12))
                        Image(systemName: "folder.fill")
                            .foregroundStyle(.blue)
                            .font(.system(size: 12))
                        Text(dataDirectory)
                            .font(.system(size: 12))
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                    .padding(.top, 2)

                    HStack(spacing: 8) {
                        Button("Show Data Directory") {
                            NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: dataDirectory)
                        }
                        Button("Use Custom Location...") { chooseDirectory() }
                    }
                    .controlSize(.regular)
                }

                Divider()

                // General
                VStack(alignment: .leading, spacing: 8) {
                    Text("General")
                        .font(.system(size: 13, weight: .bold))

                    Toggle("Auto-save documents", isOn: $autoSave)
                        .font(.system(size: 12))
                        .onChange(of: autoSave) { _, val in Preferences.shared.autoSave = val }

                    Toggle("Show status bar", isOn: $showStatusBar)
                        .font(.system(size: 12))
                        .onChange(of: showStatusBar) { _, val in Preferences.shared.showStatusBar = val }
                }

                Spacer()
            }
            .padding(20)
        }
        .onAppear {
            dataDirectory = dataDirectoryPath()
        }
    }

    private func dataDirectoryPath() -> String {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
        return appSupport?.appendingPathComponent("OakReader").path ?? "~/Library/Application Support/OakReader"
    }

    private func chooseDirectory() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "Select"
        panel.message = "Choose a directory for OakReader data storage"
        if panel.runModal() == .OK, let url = panel.url {
            dataDirectory = url.path
        }
    }
}

// MARK: - AI Settings

private struct AISettingsTab: View {
    @State private var provider: AIProvider
    @State private var model: String
    @State private var apiKey: String = ""
    @State private var testResult: String?
    @State private var isTesting: Bool = false

    private var selectedModelInfo: ModelInfo? {
        provider.models.first { $0.id == model }
    }

    init() {
        let prefs = Preferences.shared
        _provider = State(initialValue: prefs.aiProvider)
        _model = State(initialValue: prefs.aiModel.isEmpty ? prefs.aiProvider.defaultModel : prefs.aiModel)
    }

    var body: some View {
        Form {
            Section("Provider") {
                Picker("Provider", selection: $provider) {
                    ForEach(AIProvider.allCases) { p in
                        Text(p.displayName).tag(p)
                    }
                }
                .onChange(of: provider) { _, newValue in
                    model = newValue.defaultModel
                    loadAPIKey()
                }

                Picker("Model", selection: $model) {
                    ForEach(provider.models) { m in
                        Text(m.name).tag(m.id)
                    }
                }
            }

            if let info = selectedModelInfo {
                Section("Model Info") {
                    LabeledContent("Context Window", value: formatTokens(info.contextWindow))
                    LabeledContent("Max Output", value: formatTokens(info.maxTokens))
                    LabeledContent("Vision", value: info.supportsVision ? "Yes" : "No")
                    LabeledContent("Reasoning", value: info.reasoning ? "Yes" : "No")
                }
            }

            Section("API Key") {
                SecureField("API Key for \(provider.displayName)", text: $apiKey)
                    .textFieldStyle(.roundedBorder)

                HStack {
                    Button("Test Connection") { testConnection() }
                        .disabled(apiKey.isEmpty || isTesting)

                    if isTesting {
                        ProgressView()
                            .controlSize(.small)
                    }

                    if let result = testResult {
                        Text(result)
                            .font(.caption)
                            .foregroundStyle(result.contains("Success") ? .green : .red)
                    }
                }
            }
        }
        .formStyle(.grouped)
        .onAppear { loadAPIKey() }
        .onDisappear { save() }
    }

    private func formatTokens(_ count: Int) -> String {
        if count >= 1_000_000 { return "\(count / 1_000_000)M" }
        if count >= 1_000 { return "\(count / 1_000)K" }
        return "\(count)"
    }

    private func loadAPIKey() {
        apiKey = KeychainService.apiKey(for: provider) ?? ""
        testResult = nil
    }

    private func save() {
        let prefs = Preferences.shared
        prefs.aiProvider = provider
        prefs.aiModel = model
        KeychainService.setAPIKey(apiKey, for: provider)
    }

    private func testConnection() {
        save()
        isTesting = true
        testResult = nil

        Task {
            do {
                let router = ProviderRouter()
                let config = ProviderConfig(provider: provider, model: model)
                let svc = try router.provider(for: config)
                let messages = [LLMMessage(role: .user, text: "Say 'OK' and nothing else.")]
                let stream = svc.sendMessage(
                    messages: messages, model: model,
                    systemPrompt: nil, maxTokens: 50
                )
                var gotDelta = false
                for try await chunk in stream {
                    if case .delta = chunk { gotDelta = true; break }
                }
                await MainActor.run {
                    testResult = gotDelta ? "Success!" : "No response received"
                    isTesting = false
                }
            } catch {
                await MainActor.run {
                    testResult = "Error: \(error.localizedDescription)"
                    isTesting = false
                }
            }
        }
    }
}
