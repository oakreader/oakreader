import SwiftUI

// MARK: - Export Progress View

struct BackupExportProgressView: View {
    let destinationURL: URL
    let onDismiss: () -> Void

    @State private var progress = BackupProgress()
    @State private var result: BackupResult?
    @State private var isRunning = false

    var body: some View {
        VStack(spacing: 0) {
            if let result {
                exportResultContent(result)
            } else {
                exportProgressContent
            }
        }
        .frame(width: 420)
        .task {
            guard !isRunning else { return }
            isRunning = true
            let service = BackupService()
            let r = await service.export(to: destinationURL) { prog in
                Task { @MainActor in
                    self.progress = prog
                }
            }
            await MainActor.run {
                self.result = r
            }
        }
    }

    // MARK: - Progress

    private var exportProgressContent: some View {
        VStack(spacing: 16) {
            Text("Exporting Library Backup")
                .font(.title3)
                .fontWeight(.semibold)

            VStack(spacing: 8) {
                Text(progress.phase.rawValue)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)

                if progress.total > 0 {
                    ProgressView(value: Double(progress.current), total: Double(progress.total))

                    HStack {
                        if !progress.currentFileName.isEmpty {
                            Text(progress.currentFileName)
                                .lineLimit(1)
                                .truncationMode(.middle)
                        }
                        Spacer()
                        Text("\(progress.current) of \(progress.total)")
                            .monospacedDigit()
                    }
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                } else {
                    ProgressView()
                        .controlSize(.small)
                }
            }
        }
        .padding()
    }

    // MARK: - Result

    private func exportResultContent(_ result: BackupResult) -> some View {
        let hasErrors = !result.errors.isEmpty

        return VStack(spacing: 0) {
            VStack(spacing: 12) {
                Image(systemName: hasErrors ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                    .font(.system(size: 32))
                    .foregroundStyle(hasErrors ? .orange : .green)

                Text(hasErrors ? "Export Completed with Errors" : "Export Completed")
                    .font(.title3)
                    .fontWeight(.semibold)
            }
            .padding(.top, 20)
            .padding(.bottom, 16)

            // Stats in a grouped form style
            VStack(spacing: 1) {
                statRow("Files", value: "\(result.fileCount)")
                statRow("Library size", value: ByteCountFormatter.string(fromByteCount: result.totalSize, countStyle: .file))
                statRow("Archive size", value: ByteCountFormatter.string(fromByteCount: result.archiveSize, countStyle: .file))
                if hasErrors {
                    statRow("Errors", value: "\(result.errors.count)", isError: true)
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .padding(.horizontal, 20)

            if hasErrors {
                DisclosureGroup("Show error details") {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 4) {
                            ForEach(result.errors.prefix(50), id: \.self) { error in
                                Text(error)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .textSelection(.enabled)
                            }
                            if result.errors.count > 50 {
                                Text("... and \(result.errors.count - 50) more")
                                    .font(.caption)
                                    .foregroundStyle(.tertiary)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(maxHeight: 100)
                }
                .font(.caption)
                .padding(.horizontal, 20)
                .padding(.top, 8)
            }

            Divider()
                .padding(.top, 16)

            // Buttons — macOS standard: secondary left, primary right
            HStack {
                if let outputURL = result.outputURL {
                    Button("Show in Finder") {
                        NSWorkspace.shared.activateFileViewerSelecting([outputURL])
                    }
                }
                Spacer()
                Button("Done") {
                    onDismiss()
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
            }
            .padding(20)
        }
    }

    private func statRow(_ label: String, value: String, isError: Bool = false) -> some View {
        HStack {
            Text(label)
                .foregroundStyle(.secondary)
            Spacer()
            Text(value)
                .fontWeight(.medium)
                .foregroundStyle(isError ? .red : .primary)
                .monospacedDigit()
        }
        .font(.system(size: 13))
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .background(Color(nsColor: .quaternarySystemFill))
    }
}

// MARK: - Restore Progress View

struct BackupRestoreProgressView: View {
    let archiveURL: URL
    let onDismiss: () -> Void

    @State private var progress = RestoreProgress()
    @State private var result: RestoreResult?
    @State private var isRunning = false

    var body: some View {
        VStack(spacing: 0) {
            if let result {
                restoreResultContent(result)
            } else {
                restoreProgressContent
            }
        }
        .frame(width: 420)
        .task {
            guard !isRunning else { return }
            isRunning = true
            let service = BackupService()
            let r = await service.restore(from: archiveURL) { prog in
                Task { @MainActor in
                    self.progress = prog
                }
            }
            await MainActor.run {
                self.result = r
            }
        }
    }

    // MARK: - Progress

    private var restoreProgressContent: some View {
        VStack(spacing: 16) {
            Text("Restoring from Backup")
                .font(.title3)
                .fontWeight(.semibold)

            VStack(spacing: 8) {
                Text(progress.phase.rawValue)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)

                if progress.total > 0 {
                    ProgressView(value: Double(progress.current), total: Double(progress.total))

                    HStack {
                        if !progress.currentFileName.isEmpty {
                            Text(progress.currentFileName)
                                .lineLimit(1)
                                .truncationMode(.middle)
                        }
                        Spacer()
                        Text("\(progress.current) of \(progress.total)")
                            .monospacedDigit()
                    }
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                } else {
                    ProgressView()
                        .controlSize(.small)
                }
            }
        }
        .padding()
    }

    // MARK: - Result

    private func restoreResultContent(_ result: RestoreResult) -> some View {
        VStack(spacing: 0) {
            if result.success {
                VStack(spacing: 12) {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 32))
                        .foregroundStyle(.green)

                    Text("Restore Complete")
                        .font(.title3)
                        .fontWeight(.semibold)

                    Text("OakReader needs to restart to load the restored library. Your previous data has been preserved in a separate folder.")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(20)

                Divider()

                HStack {
                    Spacer()
                    Button("Restart Now") {
                        BackupService.relaunchApp()
                    }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
                }
                .padding(20)
            } else {
                VStack(spacing: 12) {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 32))
                        .foregroundStyle(.red)

                    Text("Restore Failed")
                        .font(.title3)
                        .fontWeight(.semibold)

                    if let error = result.errors.first {
                        Text(error)
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                            .fixedSize(horizontal: false, vertical: true)
                            .textSelection(.enabled)
                    }
                }
                .padding(20)

                Divider()

                HStack {
                    Spacer()
                    Button("Done") {
                        onDismiss()
                    }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
                }
                .padding(20)
            }
        }
    }
}
