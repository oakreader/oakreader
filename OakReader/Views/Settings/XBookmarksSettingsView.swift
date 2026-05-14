import SwiftUI
import OakAI

struct XBookmarksSettingsView: View {
    let store: LibraryStore

    @State private var bearerToken: String = ""
    @State private var verifyStatus: VerifyStatus = .idle
    @State private var isSyncing = false
    @State private var syncMessage: String?
    @State private var autoSync: Bool = Preferences.shared.xSyncEnabled

    private enum VerifyStatus: Equatable {
        case idle
        case checking
        case verified(String) // username
        case failed(String)
    }

    var body: some View {
        Form {
            authenticationSection
            syncSection
        }
        .formStyle(.grouped)
        .onAppear {
            // Load cached username if token exists
            if let token = Preferences.shared.xBearerToken, !token.isEmpty {
                bearerToken = token
                if let userId = Preferences.shared.xUserId {
                    verifyStatus = .verified(userId)
                }
            }
        }
    }

    // MARK: - Authentication

    private var authenticationSection: some View {
        Section {
            LabeledContent("Bearer Token") {
                HStack(spacing: 8) {
                    SecureField("Enter Bearer Token", text: $bearerToken)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(size: 12, design: .monospaced))

                    Button("Verify") { verifyToken() }
                        .disabled(bearerToken.isEmpty)
                }
            }

            LabeledContent("Status") {
                statusLabel
            }
        } header: {
            Text("Authentication")
        } footer: {
            Text("Requires an X API Bearer Token with bookmark read access. [Get a token from the X Developer Portal](https://developer.x.com/en/portal/dashboard)")
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
        case .verified(let userId):
            Label("Authenticated (ID: \(userId))", systemImage: "checkmark.circle.fill")
                .foregroundStyle(.secondary, .green)
        case .failed(let message):
            Label(message, systemImage: "xmark.circle.fill")
                .foregroundStyle(.secondary, .red)
        }
    }

    // MARK: - Sync

    private var syncSection: some View {
        Section {
            Toggle("Auto-sync", isOn: $autoSync)
                .onChange(of: autoSync) { _, newValue in
                    Preferences.shared.xSyncEnabled = newValue
                }

            if let lastSync = Preferences.shared.xLastSyncDate {
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
                            .disabled(bearerToken.isEmpty)
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
            Text("X API charges $0.001 per bookmark read. Maximum 800 bookmarks per sync.")
        }
    }

    // MARK: - Actions

    private func verifyToken() {
        verifyStatus = .checking
        let token = bearerToken
        Task {
            do {
                let user = try await XBookmarksAPIClient.lookupUser(bearerToken: token)
                await MainActor.run {
                    Preferences.shared.xBearerToken = token
                    Preferences.shared.xUserId = user.id
                    verifyStatus = .verified("@\(user.username)")
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
        let token = bearerToken
        Task {
            do {
                let importService = makeImportService()
                let result = try await importService.syncXBookmarks(bearerToken: token)
                await MainActor.run {
                    Preferences.shared.xLastSyncDate = Date()
                    syncMessage = "Imported \(result.imported), skipped \(result.skipped) (total \(result.total))"
                    isSyncing = false
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
