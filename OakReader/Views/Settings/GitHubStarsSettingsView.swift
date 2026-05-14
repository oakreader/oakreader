import SwiftUI
import OakAI

struct GitHubStarsSettingsView: View {
    let store: LibraryStore

    @State private var token: String = ""
    @State private var verifyStatus: VerifyStatus = .idle
    @State private var isSyncing = false
    @State private var syncMessage: String?
    @State private var autoSync: Bool = Preferences.shared.githubSyncEnabled
    @State private var syncInterval: TimeInterval = Preferences.shared.githubSyncInterval
    @State private var remoteStarCount: Int?
    @State private var localSyncCount: Int = 0

    private enum VerifyStatus: Equatable {
        case idle
        case checking
        case verified(String) // username
        case failed(String)
    }

    var body: some View {
        Form {
            authenticationSection
            statsSection
            syncSection
        }
        .formStyle(.grouped)
        .onAppear {
            if let savedToken = Preferences.shared.githubToken, !savedToken.isEmpty {
                token = savedToken
                if let username = Preferences.shared.githubUsername {
                    verifyStatus = .verified(username)
                }
            }
            refreshCounts()
        }
    }

    // MARK: - Authentication

    private var authenticationSection: some View {
        Section {
            LabeledContent("Personal Access Token") {
                HStack(spacing: 8) {
                    SecureField("Enter PAT", text: $token)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(size: 12, design: .monospaced))

                    Button("Verify") { verifyToken() }
                        .disabled(token.isEmpty)
                }
            }

            LabeledContent("Status") {
                statusLabel
            }
        } header: {
            Text("Authentication")
        } footer: {
            Text("Requires a GitHub Personal Access Token. [Create a token in GitHub Settings](https://github.com/settings/tokens)")
        }
    }

    @ViewBuilder
    private var statusLabel: some View {
        switch verifyStatus {
        case .idle:
            Label("Not configured", systemImage: "minus.circle")
                .foregroundStyle(.secondary)
        case .checking:
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text("Verifying...").foregroundStyle(.secondary)
            }
        case .verified(let username):
            Label("Authenticated as \(username)", systemImage: "checkmark.circle.fill")
                .foregroundStyle(.secondary, .green)
        case .failed(let message):
            Label(message, systemImage: "xmark.circle.fill")
                .foregroundStyle(.secondary, .red)
        }
    }

    // MARK: - Stats

    private var statsSection: some View {
        Section {
            if let remote = remoteStarCount {
                LabeledContent("Starred on GitHub") {
                    Text("\(remote)")
                        .foregroundStyle(.secondary)
                }
            }

            LabeledContent("Synced Locally") {
                Text("\(localSyncCount)")
                    .foregroundStyle(.secondary)
            }
        } header: {
            Text("Statistics")
        }
    }

    // MARK: - Sync

    private var syncSection: some View {
        Section {
            Toggle("Auto-sync", isOn: $autoSync)
                .onChange(of: autoSync) { _, newValue in
                    Preferences.shared.githubSyncEnabled = newValue
                }

            Picker("Sync Interval", selection: $syncInterval) {
                Text("Every Hour").tag(TimeInterval(3600))
                Text("Every 6 Hours").tag(TimeInterval(21600))
                Text("Every 12 Hours").tag(TimeInterval(43200))
                Text("Every Day").tag(TimeInterval(86400))
                Text("Every Week").tag(TimeInterval(604800))
            }
            .disabled(!autoSync)
            .onChange(of: syncInterval) { _, newValue in
                Preferences.shared.githubSyncInterval = newValue
            }

            if let lastSync = Preferences.shared.githubLastSyncDate {
                LabeledContent("Last Sync") {
                    Text(lastSync, style: .relative)
                        .foregroundStyle(.secondary)
                }
            }

            LabeledContent("Actions") {
                HStack(spacing: 8) {
                    if isSyncing {
                        HStack(spacing: 6) {
                            ProgressView().controlSize(.small)
                            Text("Syncing...").foregroundStyle(.secondary)
                        }
                    } else {
                        Button("Sync Now") { syncNow() }
                            .disabled(token.isEmpty)
                    }
                }
            }

            if let syncMessage {
                LabeledContent("Result") {
                    Text(syncMessage)
                        .foregroundStyle(syncMessage.contains("Error") ? .red : .secondary)
                }
            }
        } header: {
            Text("Sync")
        } footer: {
            Text("GitHub API is free with 5,000 requests per hour. All starred repositories will be synced.")
        }
    }

    // MARK: - Actions

    private func refreshCounts() {
        localSyncCount = store.items.filter { $0.source == "github_stars" }.count
        let currentToken = token
        guard !currentToken.isEmpty else { return }
        Task {
            if let count = try? await GitHubStarsAPIClient.fetchStarredCount(token: currentToken) {
                await MainActor.run { remoteStarCount = count }
            }
        }
    }

    private func verifyToken() {
        verifyStatus = .checking
        let currentToken = token
        Task {
            do {
                let user = try await GitHubStarsAPIClient.verifyToken(currentToken)
                await MainActor.run {
                    Preferences.shared.githubToken = currentToken
                    Preferences.shared.githubUsername = user.login
                    verifyStatus = .verified(user.login)
                }
            } catch {
                await MainActor.run {
                    verifyStatus = .failed(error.localizedDescription)
                }
            }
        }
    }

    private func syncNow() {
        isSyncing = true
        syncMessage = nil
        let currentToken = token
        Task {
            do {
                let importService = makeImportService()
                let storeRef = store
                let result = try await importService.syncGitHubStars(token: currentToken) { progress in
                    let count = storeRef.items.filter { $0.source == "github_stars" }.count
                    await MainActor.run {
                        localSyncCount = count
                        syncMessage = "Imported \(progress.imported), skipped \(progress.skipped) (total \(progress.total))"
                    }
                }
                await MainActor.run {
                    Preferences.shared.githubLastSyncDate = Date()
                    syncMessage = "Imported \(result.imported), skipped \(result.skipped) (total \(result.total))"
                    isSyncing = false
                    refreshCounts()
                }
            } catch {
                await MainActor.run {
                    syncMessage = "Error: \(error.localizedDescription)"
                    isSyncing = false
                }
            }
        }
    }

    private func makeImportService() -> ImportService {
        ImportService(
            store: store,
            coverService: LibraryCoverService(),
            referenceService: ReferenceService(database: store.database)
        )
    }
}
