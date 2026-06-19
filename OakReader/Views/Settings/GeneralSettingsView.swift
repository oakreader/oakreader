import SwiftUI

struct GeneralSettingsView: View {
    @State private var dataDirectory: String = ""
    @State private var autoSave: Bool = Preferences.shared.autoSave
    @State private var showStatusBar: Bool = Preferences.shared.showStatusBar
    @State private var searchEngine: BrowserSearchEngine = Preferences.shared.browserSearchEngine
    @State private var showUninstall = false
    @AppStorage("appearanceMode") private var appearanceMode: String = "system"

    private let permissionStatus = SystemPermissionStatus.shared

    var body: some View {
        Form {
            // MARK: - Permissions
            Section("Permissions") {
                // Microphone
                LabeledContent("Microphone") {
                    if permissionStatus.micAuthorized {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                    } else {
                        Button("Grant Access") {
                            if permissionStatus.micNotDetermined {
                                permissionStatus.requestMicAccess()
                            } else {
                                SystemSettingsLauncher.microphone.open()
                                permissionStatus.startPolling()
                            }
                        }
                    }
                }

                if permissionStatus.micAuthorized {
                    Text("All permissions granted")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Section("Appearance") {
                Picker("Mode", selection: $appearanceMode) {
                    ForEach(AppearanceMode.allCases) { mode in
                        Text(mode.displayName).tag(mode.rawValue)
                    }
                }
                .pickerStyle(.segmented)
            }

            Section {
                LabeledContent("Language") {
                    Button("Change in System Settings…") {
                        SystemSettingsLauncher.language.open()
                    }
                }
            } header: {
                Text("Language")
            } footer: {
                Text("OakReader follows your system language. To use a different language just for OakReader, set a preferred language for it in System Settings.")
            }

            Section {
                Picker("Search Engine", selection: $searchEngine) {
                    ForEach(BrowserSearchEngine.allCases) { engine in
                        Text(engine.displayName).tag(engine)
                    }
                }
                .onChange(of: searchEngine) { _, val in
                    Preferences.shared.browserSearchEngine = val
                }
            } header: {
                Text("Search Engine")
            } footer: {
                Text("Used for searches typed into a new tab or the web address bar.")
            }

            Section("Data Directory") {
                LabeledContent("Location") {
                    HStack(spacing: 4) {
                        Image(systemName: "folder.fill")
                            .foregroundStyle(.blue)
                        Text(dataDirectory)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                }

                HStack(spacing: 8) {
                    Button("Show in Finder") {
                        NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: dataDirectory)
                    }
                    Button("Use Custom Location...") { chooseDirectory() }
                }
            }

            Section("General") {
                Toggle("Auto-save documents", isOn: $autoSave)
                    .onChange(of: autoSave) { _, val in Preferences.shared.autoSave = val }

                Toggle("Show status bar", isOn: $showStatusBar)
                    .onChange(of: showStatusBar) { _, val in Preferences.shared.showStatusBar = val }
            }

            Section("About") {
                LabeledContent("Version") {
                    Text(appVersionString)
                        .foregroundStyle(.secondary)
                }
            }

            Section {
                Button(role: .destructive) {
                    showUninstall = true
                } label: {
                    Label("Uninstall OakReader…", systemImage: "trash")
                        .foregroundStyle(.red)
                }
            } header: {
                Text("Danger Zone")
            } footer: {
                Text("Removes the app and clears its system data (preferences, saved API keys, caches). Your library is kept unless you choose otherwise.")
            }
        }
        .formStyle(.grouped)
        .onAppear {
            dataDirectory = dataDirectoryPath()
            permissionStatus.refresh()
        }
        .onDisappear {
            permissionStatus.stopPolling()
        }
        .sheet(isPresented: $showUninstall) {
            UninstallConfirmationView()
        }
    }

    // MARK: - Helpers

    private var appVersionString: String {
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "—"
        let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "—"
        return "\(version) (\(build))"
    }

    private func dataDirectoryPath() -> String {
        CatalogDatabase.dataDirectory.path
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

// MARK: - Uninstall confirmation

/// Two-step confirmation for the destructive uninstall. Defaults to preserving
/// the user's library; deleting it is opt-in and moves it to the Trash (with an
/// "export a backup first" escape hatch). The final action only enables once the
/// user acknowledges it can't be undone.
private struct UninstallConfirmationView: View {
    @Environment(\.dismiss) private var dismiss

    @State private var deleteLibrary = false
    @State private var confirmed = false
    @State private var isExporting = false
    @State private var exportStatus: String?
    @State private var isUninstalling = false

    private var libraryPath: String { UninstallService.libraryDirectory.path }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Label("Uninstall OakReader", systemImage: "trash")
                .font(.title2.weight(.semibold))
                .foregroundStyle(.red)

            Text("This will move OakReader to the Trash and clear its system data — preferences, saved API keys, caches and browsing cookies. This cannot be undone.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Divider()

            VStack(alignment: .leading, spacing: 10) {
                Toggle(isOn: $deleteLibrary) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Also delete my library")
                        Text("PDFs, notes, highlights and chats in \(libraryPath)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                }

                if deleteLibrary {
                    HStack(spacing: 10) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                        Text("Your library will be moved to the Trash. Export a backup first if you might want it back.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    HStack(spacing: 8) {
                        Button {
                            exportBackup()
                        } label: {
                            if isExporting {
                                ProgressView().controlSize(.small)
                            } else {
                                Label("Export Backup First…", systemImage: "square.and.arrow.up")
                            }
                        }
                        .disabled(isExporting)

                        if let status = exportStatus {
                            Text(status)
                                .font(.caption)
                                .foregroundStyle(status.hasPrefix("Failed") ? .red : .green)
                        }
                    }
                }
            }

            Toggle("I understand this can't be undone.", isOn: $confirmed)
                .toggleStyle(.checkbox)

            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button(role: .destructive) {
                    isUninstalling = true
                    Task { await UninstallService.uninstall(deleteLibrary: deleteLibrary) }
                } label: {
                    if isUninstalling {
                        ProgressView().controlSize(.small)
                    } else {
                        Text(deleteLibrary ? "Delete Everything & Quit" : "Uninstall & Quit")
                    }
                }
                .disabled(!confirmed || isUninstalling || isExporting)
            }
        }
        .padding(20)
        .frame(width: 460)
        .interactiveDismissDisabled(isUninstalling)
    }

    private func exportBackup() {
        let panel = NSSavePanel()
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        panel.nameFieldStringValue = "OakReader-Backup-\(formatter.string(from: Date())).oakreader"
        panel.allowedContentTypes = [.init(filenameExtension: "oakreader") ?? .zip]
        guard panel.runModal() == .OK, let url = panel.url else { return }

        isExporting = true
        exportStatus = nil
        Task {
            let result = await BackupService().export(to: url, progress: { _ in })
            await MainActor.run {
                isExporting = false
                exportStatus = result.errors.isEmpty ? "Backup exported" : "Failed to export"
            }
        }
    }
}
