import SwiftUI

struct ZoteroImportProgressView: View {
    let dataDirectory: URL
    let store: LibraryStore
    let coverService: LibraryCoverService
    let referenceService: ReferenceService
    let onDismiss: () -> Void

    @State private var progress = ZoteroMigrationProgress()
    @State private var result: ZoteroMigrationResult?
    @State private var isRunning = false

    var body: some View {
        VStack(spacing: 20) {
            // Header
            Image(systemName: "square.and.arrow.down.on.square")
                .font(.system(size: 36))
                .foregroundStyle(.secondary)

            Text("Import from Zotero")
                .font(.headline)

            if let result {
                // Result summary
                resultView(result)
            } else {
                // Progress
                progressView
            }
        }
        .padding(32)
        .frame(width: 420)
        .task {
            guard !isRunning else { return }
            isRunning = true
            let service = ZoteroMigrationService(
                store: store,
                coverService: coverService,
                referenceService: referenceService
            )
            let r = await service.run(dataDirectory: dataDirectory) { prog in
                Task { @MainActor in
                    self.progress = prog
                }
            }
            await MainActor.run {
                self.result = r
            }
        }
    }

    // MARK: - Progress View

    private var progressView: some View {
        VStack(spacing: 12) {
            Text(progress.phase.rawValue)
                .font(.subheadline)
                .foregroundStyle(.secondary)

            if progress.total > 0 {
                ProgressView(value: Double(progress.current), total: Double(progress.total))
                    .progressViewStyle(.linear)

                Text("\(progress.current) / \(progress.total)")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .monospacedDigit()
            } else {
                ProgressView()
                    .controlSize(.small)
            }

            if !progress.currentItemTitle.isEmpty {
                Text(progress.currentItemTitle)
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
        }
    }

    // MARK: - Result View

    private func resultView(_ result: ZoteroMigrationResult) -> some View {
        VStack(spacing: 16) {
            let hasErrors = !result.errors.isEmpty

            Image(systemName: hasErrors ? "exclamationmark.triangle" : "checkmark.circle")
                .font(.system(size: 28))
                .foregroundStyle(hasErrors ? .orange : .green)

            // Stats grid
            VStack(spacing: 6) {
                statRow("Items", count: result.itemCount)
                statRow("PDFs copied", count: result.pdfCount)
                statRow("Collections", count: result.collectionCount)
                statRow("Tags", count: result.tagCount)
                statRow("Notes", count: result.noteCount)
                if hasErrors {
                    statRow("Errors", count: result.errors.count, isError: true)
                }
            }
            .padding(.horizontal, 8)

            if hasErrors {
                DisclosureGroup("Error details") {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 4) {
                            ForEach(result.errors.prefix(50), id: \.self) { error in
                                Text(error)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            if result.errors.count > 50 {
                                Text("... and \(result.errors.count - 50) more")
                                    .font(.caption)
                                    .foregroundStyle(.tertiary)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(maxHeight: 120)
                }
                .font(.caption)
            }

            Button("Done") {
                onDismiss()
            }
            .keyboardShortcut(.defaultAction)
            .buttonStyle(.borderedProminent)
        }
    }

    private func statRow(_ label: String, count: Int, isError: Bool = false) -> some View {
        HStack {
            Text(label)
                .font(.subheadline)
                .foregroundStyle(.secondary)
            Spacer()
            Text("\(count)")
                .font(.subheadline)
                .fontWeight(.medium)
                .foregroundStyle(isError ? .red : .primary)
                .monospacedDigit()
        }
    }
}
