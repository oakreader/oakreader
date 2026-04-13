import SwiftUI

struct BatchFileListView: View {
    @Binding var jobs: [BatchJob]

    var body: some View {
        if jobs.isEmpty {
            VStack(spacing: 12) {
                Image(systemName: "doc.on.doc")
                    .font(.largeTitle)
                    .foregroundStyle(.secondary)
                Text("No Files Added")
                    .font(.headline)
                    .foregroundStyle(.secondary)
                Text("Click \"Add Files\" to select PDF files for batch processing.")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .multilineTextAlignment(.center)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding()
        } else {
            List {
                ForEach(Array(jobs.enumerated()), id: \.element.id) { index, job in
                    BatchFileRow(job: job) {
                        jobs.remove(at: index)
                    }
                }
                .onMove { source, destination in
                    jobs.move(fromOffsets: source, toOffset: destination)
                }
            }
            .listStyle(.bordered)
        }
    }
}

private struct BatchFileRow: View {
    let job: BatchJob
    let onRemove: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            // Status icon
            statusIcon

            // File info
            VStack(alignment: .leading, spacing: 2) {
                Text(job.fileURL.lastPathComponent)
                    .font(.caption)
                    .lineLimit(1)

                HStack(spacing: 4) {
                    Text(job.status.label)
                        .font(.caption2)
                        .foregroundStyle(statusColor)

                    if let error = job.error {
                        Text("- \(error)")
                            .font(.caption2)
                            .foregroundStyle(.red)
                            .lineLimit(1)
                    }
                }
            }

            Spacer()

            // Progress
            if case .processing(let progress) = job.status {
                ProgressView(value: progress)
                    .frame(width: 50)
            }

            // Remove button
            if case .pending = job.status {
                Button {
                    onRemove()
                } label: {
                    Image(systemName: "xmark.circle")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.vertical, 2)
    }

    @ViewBuilder
    private var statusIcon: some View {
        switch job.status {
        case .pending:
            Image(systemName: "clock")
                .foregroundStyle(.secondary)
                .font(.caption)
        case .processing:
            ProgressView()
                .controlSize(.small)
        case .completed:
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(.green)
                .font(.caption)
        case .failed:
            Image(systemName: "xmark.circle.fill")
                .foregroundStyle(.red)
                .font(.caption)
        }
    }

    private var statusColor: Color {
        switch job.status {
        case .pending: return .secondary
        case .processing: return .blue
        case .completed: return .green
        case .failed: return .red
        }
    }
}
