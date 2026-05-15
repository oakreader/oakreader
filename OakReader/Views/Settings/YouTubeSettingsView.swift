import SwiftUI
import OakAgent

struct YouTubeSettingsView: View {
    // yt-dlp state
    @State private var ytDlpPath: String = Preferences.shared.ytDlpPath
    @State private var ytDlpStatus: YtDlpStatus = .unknown
    @State private var isInstalling = false
    @State private var installMessage: String?
    @State private var latestVersion: String?

    // YouTube Highlights LLM
    @State private var youtubeUseChatDefault: Bool
    @State private var youtubeProviderId: String
    @State private var youtubeModel: String

    // Prompt file state
    @State private var promptPreview: String = ""

    private let store = ConfiguredProviderStore.shared

    init() {
        let prefs = Preferences.shared
        let defaults = UserDefaults.standard

        // YouTube LLM – nil raw key means "use chat default"
        let youtubeRaw = defaults.string(forKey: "youtubeAIProvider")
        _youtubeUseChatDefault = State(initialValue: youtubeRaw == nil)
        _youtubeProviderId = State(initialValue: prefs.youtubeAIProviderId)
        let ym = prefs.youtubeAIModel
        _youtubeModel = State(initialValue: ym.isEmpty
            ? (ProviderRegistry.shared.provider(for: prefs.youtubeAIProviderId)?.defaultModelId ?? "") : ym)
    }

    private enum YtDlpStatus: Equatable {
        case unknown
        case checking
        case found(String)
        case notFound
    }

    var body: some View {
        Form {
            ytDlpSection
            llmSection
            chapterPromptSection
        }
        .formStyle(.grouped)
        .onDisappear { saveLLM() }
        .onAppear {
            if ytDlpPath.isEmpty {
                autoDetectYtDlp()
            } else {
                restoreOrVerifyYtDlp(at: ytDlpPath)
            }
            loadPromptPreview()
        }
    }

    // MARK: - Section 1: yt-dlp

    private var ytDlpSection: some View {
        Section {
            LabeledContent("Path") {
                HStack(spacing: 8) {
                    TextField("yt-dlp path", text: $ytDlpPath)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(size: 12, design: .monospaced))
                        .onChange(of: ytDlpPath) { _, newValue in
                            Preferences.shared.ytDlpPath = newValue
                            Preferences.shared.ytDlpCachedVersion = nil
                            if !newValue.isEmpty {
                                verifyYtDlp(at: newValue)
                            } else {
                                ytDlpStatus = .unknown
                            }
                        }

                    Button("Browse...") { chooseYtDlp() }
                    Button("Auto-detect") { autoDetectYtDlp() }
                }
            }

            LabeledContent("Status") {
                HStack(spacing: 10) {
                    statusLabel
                    Spacer()
                    ytDlpActionButton
                }
            }

            if let installMessage {
                LabeledContent("Last Action") {
                    Text(installMessage)
                        .foregroundStyle(installMessage.contains("Error") ? .red : .secondary)
                }
            }
        } header: {
            Text("yt-dlp")
        } footer: {
            Text("Used to fetch YouTube transcripts and extract native video chapters.")
        }
    }

    // MARK: - Section 2: Highlight Prompt

    private var chapterPromptSection: some View {
        Section {
            LabeledContent("Preview") {
                promptPreviewBox
            }

            LabeledContent("Actions") {
                HStack(spacing: 8) {
                    Button("Open in Editor") { openPromptInEditor() }
                    Button("Reset to Default") { resetPromptToDefault() }
                }
            }
        } header: {
            Text("Highlight Generation Prompt")
        } footer: {
            Text("System prompt sent to the AI model when generating highlight output.")
        }
    }

    @ViewBuilder
    private var statusLabel: some View {
        switch ytDlpStatus {
        case .unknown:
            Label("Not configured", systemImage: "minus.circle")
                .foregroundStyle(.secondary)
        case .checking:
            HStack(spacing: 6) {
                ProgressView()
                    .controlSize(.small)
                Text("Checking...")
                    .foregroundStyle(.secondary)
            }
        case .found(let version):
            Label("yt-dlp \(version)", systemImage: "checkmark.circle.fill")
                .foregroundStyle(.secondary, .green)
        case .notFound:
            Label("Not found at this path", systemImage: "xmark.circle.fill")
                .foregroundStyle(.secondary, .red)
        }
    }

    @ViewBuilder
    private var ytDlpActionButton: some View {
        if isInstalling {
            HStack(spacing: 6) {
                ProgressView()
                    .controlSize(.small)
                Text("Installing...")
                    .foregroundStyle(.secondary)
            }
        } else if case .found(let current) = ytDlpStatus {
            if let latest = latestVersion, latest != current {
                Button("Update to \(latest)") {
                    installOrUpdateYtDlp()
                }
            } else {
                Button("Check for Updates") {
                    checkForUpdates()
                }
            }
        } else {
            Button("Install") {
                installOrUpdateYtDlp()
            }
        }
    }

    private var promptPreviewBox: some View {
        Text(promptPreview.isEmpty ? "(default prompt)" : promptPreview)
            .font(.system(size: 12, design: .monospaced))
            .foregroundStyle(promptPreview.isEmpty ? .tertiary : .secondary)
            .lineLimit(promptPreview.isEmpty ? 1 : 4)
            .padding(8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background {
                RoundedRectangle(cornerRadius: 6)
                    .fill(Color.primary.opacity(0.03))
            }
    }

    // MARK: - LLM Section

    private var llmSection: some View {
        Section("Highlights LLM") {
            Toggle("Use Chat default", isOn: $youtubeUseChatDefault)

            if youtubeUseChatDefault {
                chatDefaultLabel
            } else {
                llmPickers
            }
        }
    }

    @ViewBuilder
    private var llmPickers: some View {
        if store.configuredLLMProviders.isEmpty {
            Text("Configure a provider in AI Providers first.")
                .foregroundStyle(.secondary)
        } else {
            Picker("Provider", selection: $youtubeProviderId) {
                ForEach(store.configuredLLMProviders) { p in
                    Text(p.displayName).tag(p.id)
                }
            }
            .onChange(of: youtubeProviderId) { _, newValue in
                youtubeModel = ProviderRegistry.shared.provider(for: newValue)?.defaultModelId ?? ""
            }

            if let provider = ProviderRegistry.shared.provider(for: youtubeProviderId) {
                Picker("Model", selection: $youtubeModel) {
                    ForEach(provider.models) { m in
                        Text(m.name).tag(m.id)
                    }
                }
            }
        }
    }

    private var chatDefaultLabel: some View {
        let prefs = Preferences.shared
        let pid = prefs.aiProviderId
        let model = prefs.aiModel
        let providerName = ProviderRegistry.shared.provider(for: pid)?.displayName ?? pid
        let modelName = ProviderRegistry.shared.provider(for: pid)?.models.first(where: { $0.id == model })?.name ?? model
        return LabeledContent("Using", value: "\(providerName) / \(modelName)")
            .foregroundStyle(.secondary)
    }

    private func saveLLM() {
        let prefs = Preferences.shared
        let defaults = UserDefaults.standard

        if youtubeUseChatDefault {
            defaults.removeObject(forKey: "youtubeAIProvider")
            defaults.removeObject(forKey: "youtubeAIModel")
        } else {
            prefs.youtubeAIProviderId = youtubeProviderId
            prefs.youtubeAIModel = youtubeModel
        }
    }

    // MARK: - yt-dlp Helpers

    private func chooseYtDlp() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Select"
        panel.message = "Locate the yt-dlp executable"
        if panel.runModal() == .OK, let url = panel.url {
            ytDlpPath = url.path
            Preferences.shared.ytDlpPath = url.path
            verifyYtDlp(at: url.path)
        }
    }

    private func autoDetectYtDlp() {
        ytDlpStatus = .checking
        Task.detached {
            let appSupportBin = FileManager.default.urls(
                for: .applicationSupportDirectory, in: .userDomainMask
            ).first?.appendingPathComponent("OakReader/bin/yt-dlp").path

            let homeDir = FileManager.default.homeDirectoryForCurrentUser.path
            let candidates = [
                appSupportBin,
                "/opt/homebrew/bin/yt-dlp",
                "/usr/local/bin/yt-dlp",
                "/usr/bin/yt-dlp",
                "\(homeDir)/Library/Python/3.13/bin/yt-dlp",
                "\(homeDir)/Library/Python/3.12/bin/yt-dlp",
                "\(homeDir)/Library/Python/3.11/bin/yt-dlp",
                "\(homeDir)/Library/Python/3.10/bin/yt-dlp",
            ].compactMap { $0 }

            for path in candidates where FileManager.default.isExecutableFile(atPath: path) {
                let version = Self.ytDlpVersion(at: path)
                Preferences.shared.ytDlpCachedVersion = version
                await MainActor.run {
                    ytDlpPath = path
                    Preferences.shared.ytDlpPath = path
                    ytDlpStatus = version.map { .found($0) } ?? .found("installed")
                }
                return
            }

            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
            process.arguments = ["which", "yt-dlp"]
            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = Pipe()
            try? process.run()
            process.waitUntilExit()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            let output = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

            if process.terminationStatus == 0, !output.isEmpty,
               FileManager.default.isExecutableFile(atPath: output) {
                let version = Self.ytDlpVersion(at: output)
                Preferences.shared.ytDlpCachedVersion = version
                await MainActor.run {
                    ytDlpPath = output
                    Preferences.shared.ytDlpPath = output
                    ytDlpStatus = version.map { .found($0) } ?? .found("installed")
                }
            } else {
                await MainActor.run {
                    ytDlpStatus = .notFound
                }
            }
        }
    }

    /// Restore from cache if available, otherwise run the binary to verify.
    private func restoreOrVerifyYtDlp(at path: String) {
        let prefs = Preferences.shared
        if let cached = prefs.ytDlpCachedVersion, !cached.isEmpty {
            ytDlpStatus = .found(cached)
            latestVersion = prefs.ytDlpCachedLatestVersion
        } else {
            verifyYtDlp(at: path)
        }
    }

    /// Run the yt-dlp binary to get its version and check for updates. Caches the results.
    private func verifyYtDlp(at path: String) {
        ytDlpStatus = .checking
        Task.detached {
            let version = Self.ytDlpVersion(at: path)

            // Cache the local version
            let prefs = Preferences.shared
            prefs.ytDlpCachedVersion = version

            // Use cached latest version if checked within 7 days
            let cached = prefs.ytDlpCachedLatestVersion
            let lastCheck = prefs.ytDlpLastVersionCheck
            let cacheValid = lastCheck.map { Date().timeIntervalSince($0) < 7 * 24 * 3600 } ?? false
            let latest = (cacheValid && cached != nil) ? cached : await Self.fetchAndCacheLatestVersion()

            await MainActor.run {
                ytDlpStatus = version.map { .found($0) } ?? .notFound
                latestVersion = latest
            }
        }
    }

    private func checkForUpdates() {
        Task.detached {
            let latest = await Self.fetchAndCacheLatestVersion()
            await MainActor.run {
                latestVersion = latest
            }
        }
    }

    private static func fetchAndCacheLatestVersion() async -> String? {
        let version = await fetchLatestYtDlpVersion()
        if let version {
            Preferences.shared.ytDlpCachedLatestVersion = version
            Preferences.shared.ytDlpLastVersionCheck = Date()
        }
        return version
    }

    private static func fetchLatestYtDlpVersion() async -> String? {
        guard let url = URL(string: "https://api.github.com/repos/yt-dlp/yt-dlp/releases/latest") else {
            return nil
        }
        var request = URLRequest(url: url)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.timeoutInterval = 10
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              let httpResponse = response as? HTTPURLResponse,
              httpResponse.statusCode == 200,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let tagName = json["tag_name"] as? String else {
            return nil
        }
        return tagName
    }

    private func installOrUpdateYtDlp() {
        isInstalling = true
        installMessage = nil
        Task.detached {
            do {
                let appSupport = FileManager.default.urls(
                    for: .applicationSupportDirectory, in: .userDomainMask
                ).first!.appendingPathComponent("OakReader/bin")
                try FileManager.default.createDirectory(at: appSupport, withIntermediateDirectories: true)
                let destURL = appSupport.appendingPathComponent("yt-dlp")

                let downloadURL = URL(string: "https://github.com/yt-dlp/yt-dlp/releases/latest/download/yt-dlp_macos")!
                let (tempURL, response) = try await URLSession.shared.download(from: downloadURL)

                guard let httpResponse = response as? HTTPURLResponse,
                      httpResponse.statusCode == 200 else {
                    throw URLError(.badServerResponse)
                }

                try? FileManager.default.removeItem(at: destURL)
                try FileManager.default.moveItem(at: tempURL, to: destURL)

                try FileManager.default.setAttributes(
                    [.posixPermissions: 0o755],
                    ofItemAtPath: destURL.path
                )

                let version = Self.ytDlpVersion(at: destURL.path)
                Preferences.shared.ytDlpCachedVersion = version
                await MainActor.run {
                    ytDlpPath = destURL.path
                    Preferences.shared.ytDlpPath = destURL.path
                    ytDlpStatus = version.map { .found($0) } ?? .found("installed")
                    latestVersion = version
                    installMessage = "Installed successfully."
                    isInstalling = false
                }
            } catch {
                await MainActor.run {
                    installMessage = "Error: \(error.localizedDescription)"
                    isInstalling = false
                }
            }
        }
    }

    private static func ytDlpVersion(at path: String) -> String? {
        guard FileManager.default.isExecutableFile(atPath: path) else { return nil }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = ["--version"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()
        do {
            try process.run()
            process.waitUntilExit()
            guard process.terminationStatus == 0 else { return nil }
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            return String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
        } catch {
            return nil
        }
    }

    // MARK: - Prompt Helpers

    private func loadPromptPreview() {
        let url = Preferences.chapterPromptURL
        if FileManager.default.fileExists(atPath: url.path),
           let content = try? String(contentsOf: url, encoding: .utf8) {
            promptPreview = content
        } else {
            promptPreview = ""
        }
    }

    private func openPromptInEditor() {
        let url = Preferences.chapterPromptURL
        let fm = FileManager.default

        // Ensure file exists before opening
        if !fm.fileExists(atPath: url.path) {
            let dir = url.deletingLastPathComponent()
            try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
            try? ChapterGenerationService.defaultHighlightPrompt.write(to: url, atomically: true, encoding: .utf8)
            loadPromptPreview()
        }

        NSWorkspace.shared.open(url)
    }

    private func resetPromptToDefault() {
        let url = Preferences.chapterPromptURL
        try? FileManager.default.removeItem(at: url)
        promptPreview = ""
    }
}
