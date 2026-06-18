import SwiftUI

struct GeneralSettingsView: View {
    @State private var dataDirectory: String = ""
    @State private var autoSave: Bool = Preferences.shared.autoSave
    @State private var showStatusBar: Bool = Preferences.shared.showStatusBar
    @State private var searchEngine: BrowserSearchEngine = Preferences.shared.browserSearchEngine
    @AppStorage("appearanceMode") private var appearanceMode: String = "system"
    @AppStorage("globalFontFamily") private var fontFamily: String = "system"
    @AppStorage("globalFontSize") private var fontSize: Double = 14.0

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

            Section("Font") {
                Picker("Family", selection: $fontFamily) {
                    ForEach(FontFamily.allCases) { family in
                        Text(family.displayName).tag(family.rawValue)
                    }
                }

                LabeledContent("Size") {
                    HStack {
                        Slider(value: $fontSize, in: 12...18, step: 1)
                        Text("\(Int(fontSize)) pt")
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                            .frame(width: 36, alignment: .trailing)
                    }
                }

                let previewFamily = FontFamily(rawValue: fontFamily) ?? .system
                LabeledContent("Preview") {
                    Text("The quick brown fox jumps over the lazy dog")
                        .font(.system(size: CGFloat(fontSize), design: previewFamily.swiftUIDesign))
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
        }
        .formStyle(.grouped)
        .onAppear {
            dataDirectory = dataDirectoryPath()
            permissionStatus.refresh()
        }
        .onDisappear {
            permissionStatus.stopPolling()
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
