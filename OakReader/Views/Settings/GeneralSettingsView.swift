import SwiftUI

struct GeneralSettingsView: View {
    @State private var dataDirectory: String = ""
    @State private var autoSave: Bool = Preferences.shared.autoSave
    @State private var showStatusBar: Bool = Preferences.shared.showStatusBar
    @State private var ytDlpPath: String = Preferences.shared.ytDlpPath
    @State private var ytDlpStatus: YtDlpStatus = .unknown

    private enum YtDlpStatus: Equatable {
        case unknown
        case checking
        case found(String) // version string
        case notFound
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                dataDirectorySection
                Divider()
                generalTogglesSection
                Divider()
                externalToolsSection
                Spacer()
            }
            .padding(20)
        }
        .onAppear {
            dataDirectory = dataDirectoryPath()
            if ytDlpPath.isEmpty {
                autoDetectYtDlp()
            } else {
                verifyYtDlp(at: ytDlpPath)
            }
        }
    }

    // MARK: - Sections

    private var dataDirectorySection: some View {
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
    }

    private var generalTogglesSection: some View {
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
    }

    // MARK: - Helpers

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

    // MARK: - External Tools

    private var externalToolsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("External Tools")
                .font(.system(size: 13, weight: .bold))

            Text("yt-dlp is used to fetch YouTube video transcripts. Install via `brew install yt-dlp`.")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)

            HStack(spacing: 8) {
                TextField("yt-dlp path", text: $ytDlpPath)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 12, design: .monospaced))
                    .frame(maxWidth: 360)
                    .onChange(of: ytDlpPath) { _, newValue in
                        Preferences.shared.ytDlpPath = newValue
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
            }
            .font(.system(size: 11))
        }
    }

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
            let candidates = [
                "/usr/local/bin/yt-dlp",
                "/opt/homebrew/bin/yt-dlp",
                "/usr/bin/yt-dlp",
            ]

            // Check known paths first
            for path in candidates {
                if FileManager.default.isExecutableFile(atPath: path) {
                    let version = Self.ytDlpVersion(at: path)
                    await MainActor.run {
                        ytDlpPath = path
                        Preferences.shared.ytDlpPath = path
                        ytDlpStatus = version.map { .found($0) } ?? .found("installed")
                    }
                    return
                }
            }

            // Try `which yt-dlp`
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

    private func verifyYtDlp(at path: String) {
        ytDlpStatus = .checking
        Task.detached {
            let version = Self.ytDlpVersion(at: path)
            await MainActor.run {
                ytDlpStatus = version.map { .found($0) } ?? .notFound
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
}
