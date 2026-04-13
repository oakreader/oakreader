import SwiftUI

struct BatchProgressView: View {
    let progress: Double
    let jobs: [BatchJob]

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Progress")
                .font(.caption)
                .fontWeight(.medium)

            // Overall progress
            VStack(alignment: .leading, spacing: 4) {
                ProgressView(value: progress)
                    .progressViewStyle(.linear)

                HStack {
                    Text("\(completedCount) of \(jobs.count) completed")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    Spacer()

                    Text("\(Int(progress * 100))%")
                        .font(.caption)
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
            }

            // Per-file status summary
            HStack(spacing: 16) {
                statusCount(icon: "clock", count: pendingCount, label: "Pending", color: .secondary)
                statusCount(icon: "arrow.triangle.2.circlepath", count: processingCount, label: "Processing", color: .blue)
                statusCount(icon: "checkmark.circle.fill", count: completedCount, label: "Done", color: .green)
                statusCount(icon: "xmark.circle.fill", count: failedCount, label: "Failed", color: .red)
            }

            // Failed jobs detail
            if failedCount > 0 {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Errors:")
                        .font(.caption)
                        .fontWeight(.medium)
                        .foregroundStyle(.red)

                    ForEach(failedJobs) { job in
                        HStack(spacing: 4) {
                            Image(systemName: "xmark.circle")
                                .font(.caption2)
                                .foregroundStyle(.red)
                            Text(job.fileURL.lastPathComponent)
                                .font(.caption2)
                                .fontWeight(.medium)
                            if let error = job.error {
                                Text("- \(error)")
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                            }
                        }
                    }
                }
                .padding(8)
                .background(
                    RoundedRectangle(cornerRadius: 6)
                        .fill(Color.red.opacity(0.05))
                )
            }
        }
    }

    private func statusCount(icon: String, count: Int, label: String, color: Color) -> some View {
        HStack(spacing: 4) {
            Image(systemName: icon)
                .font(.caption2)
                .foregroundStyle(color)
            Text("\(count)")
                .font(.caption)
                .fontWeight(.medium)
            Text(label)
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }

    private var pendingCount: Int {
        jobs.filter { if case .pending = $0.status { return true }; return false }.count
    }

    private var processingCount: Int {
        jobs.filter { if case .processing = $0.status { return true }; return false }.count
    }

    private var completedCount: Int {
        jobs.filter { if case .completed = $0.status { return true }; return false }.count
    }

    private var failedCount: Int {
        jobs.filter { if case .failed = $0.status { return true }; return false }.count
    }

    private var failedJobs: [BatchJob] {
        jobs.filter { if case .failed = $0.status { return true }; return false }
    }
}
