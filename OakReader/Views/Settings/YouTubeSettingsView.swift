import SwiftUI

struct YouTubeSettingsView: View {
    // yt-dlp state
    @State private var ytDlpPath: String = Preferences.shared.ytDlpPath
    @State private var ytDlpStatus: YtDlpStatus = .unknown
    @State private var isInstalling = false
    @State private var installMessage: String?
    @State private var latestVersion: String?

    // Prompt file state
    @State private var promptPreview: String = ""

    private enum YtDlpStatus: Equatable {
        case unknown
        case checking
        case found(String)
        case notFound
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                ytDlpSection
                Divider()
                chapterPromptSection
                Spacer()
            }
            .padding(20)
        }
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
        VStack(alignment: .leading, spacing: 8) {
            Text("yt-dlp")
                .font(.system(size: 13, weight: .bold))

            Text("yt-dlp is used to fetch YouTube transcripts and extract native video chapters.")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)

            HStack(spacing: 8) {
                TextField("yt-dlp path", text: $ytDlpPath)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 12, design: .monospaced))
                    .frame(maxWidth: 360)
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
            .controlSize(.regular)

            HStack(spacing: 6) {
                switch ytDlpStatus {
                case .unknown:
                    Image(systemName: "minus.circle")
                        .foregroundStyle(.secondary)
                    Text("Not configured")
                        .foregroundStyle(.secondary)
                case .checking:
                    ProgressView()
                        .controlSize(.small)
                    Text("Checking...")
                        .foregroundStyle(.secondary)
                case .found(let version):
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                    Text("yt-dlp \(version)")
                        .foregroundStyle(.secondary)
                case .notFound:
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.red)
                    Text("Not found at this path")
                        .foregroundStyle(.secondary)
                }

                Spacer().frame(width: 4)

                if isInstalling {
                    ProgressView()
                        .controlSize(.small)
                    Text("Installing…")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                } else if case .found(let current) = ytDlpStatus {
                    if let latest = latestVersion, latest != current {
                        Button("Update to \(latest)") {
                            installOrUpdateYtDlp()
                        }
                        .controlSize(.small)
                    } else {
                        Button("Check for Updates") {
                            checkForUpdates()
                        }
                        .controlSize(.small)
                    }
                } else {
                    Button("Install") {
                        installOrUpdateYtDlp()
                    }
                    .controlSize(.small)
                }
            }
            .font(.system(size: 11))

            if let installMessage {
                Text(installMessage)
                    .font(.system(size: 11))
                    .foregroundStyle(installMessage.contains("Error") ? .red : .green)
            }
        }
    }

    // MARK: - Section 2: Highlight Prompt

    private var chapterPromptSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Highlight Generation Prompt")
                .font(.system(size: 13, weight: .bold))

            Text("The system prompt sent to the AI model. Edit to customize highlight output.")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)

            if promptPreview.isEmpty {
                Text("(default prompt)")
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundStyle(.tertiary)
                    .padding(8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(RoundedRectangle(cornerRadius: 6).fill(Color.primary.opacity(0.03)))
            } else {
                Text(promptPreview)
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(4)
                    .padding(8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(RoundedRectangle(cornerRadius: 6).fill(Color.primary.opacity(0.03)))
            }

            HStack(spacing: 8) {
                Button("Open in Editor") { openPromptInEditor() }
                Button("Reset to Default") { resetPromptToDefault() }
            }
            .controlSize(.regular)
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

            for path in candidates {
                if FileManager.default.isExecutableFile(atPath: path) {
                    let version = Self.ytDlpVersion(at: path)
                    Preferences.shared.ytDlpCachedVersion = version
                    await MainActor.run {
                        ytDlpPath = path
                        Preferences.shared.ytDlpPath = path
                        ytDlpStatus = version.map { .found($0) } ?? .found("installed")
                    }
                    return
                }
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
