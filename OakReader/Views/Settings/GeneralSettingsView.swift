import SwiftUI

struct GeneralSettingsView: View {
    @State private var dataDirectory: String = ""
    @State private var autoSave: Bool = Preferences.shared.autoSave
    @State private var showStatusBar: Bool = Preferences.shared.showStatusBar

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                dataDirectorySection
                Divider()
                generalTogglesSection
                Spacer()
            }
            .padding(20)
        }
        .onAppear {
            dataDirectory = dataDirectoryPath()
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
}
