import SwiftUI

struct AccessibilityCheckerView: View {
    let viewModel: DocumentViewModel
    @Environment(\.dismiss) private var dismiss

    @State private var issues: [AccessibilityIssue] = []
    @State private var isChecking = false
    @State private var hasChecked = false

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                Text("Accessibility Check")
                    .font(.title3)
                    .fontWeight(.semibold)

                Spacer()

                Button("Done") {
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)
            }
            .padding()

            Divider()

            if !hasChecked {
                // Pre-check state
                VStack(spacing: 16) {
                    Image(systemName: "accessibility")
                        .font(.system(size: 50))
                        .foregroundStyle(Color.accentColor)

                    Text("Check Document Accessibility")
                        .font(.headline)

                    Text("Run an accessibility check to identify potential issues that may affect users with disabilities.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: 350)

                    Button("Run Check") {
                        runCheck()
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if isChecking {
                VStack(spacing: 12) {
                    ProgressView()
                        .controlSize(.large)
                    Text("Checking document accessibility...")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if issues.isEmpty {
                VStack(spacing: 12) {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 50))
                        .foregroundStyle(.green)

                    Text("No Issues Found")
                        .font(.headline)

                    Text("The document passed all accessibility checks.")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    Button("Run Again") {
                        runCheck()
                    }
                    .buttonStyle(.bordered)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                // Results
                VStack(spacing: 0) {
                    // Summary bar
                    HStack(spacing: 16) {
                        issueSummary(
                            severity: .error,
                            count: issues.filter { $0.severity == .error }.count,
                            color: .red
                        )
                        issueSummary(
                            severity: .warning,
                            count: issues.filter { $0.severity == .warning }.count,
                            color: .orange
                        )
                        issueSummary(
                            severity: .info,
                            count: issues.filter { $0.severity == .info }.count,
                            color: .blue
                        )

                        Spacer()

                        Button("Re-check") {
                            runCheck()
                        }
                        .buttonStyle(.bordered)
                    }
                    .padding(8)
                    .background(Color(nsColor: .controlBackgroundColor))

                    Divider()

                    // Issue list
                    List {
                        ForEach(issues) { issue in
                            IssueRow(issue: issue)
                                .contentShape(Rectangle())
                                .onTapGesture {
                                    if let pageIndex = issue.pageIndex {
                                        viewModel.viewer.goToPage(pageIndex)
                                    }
                                }
                        }
                    }
                    .listStyle(.bordered)
                }
            }
        }
        .frame(width: 550, height: 500)
    }

    private func runCheck() {
        isChecking = true
        hasChecked = true

        Task {
            await viewModel.accessibility.runCheck()
            await MainActor.run {
                issues = viewModel.accessibility.issues
                isChecking = false
            }
        }
    }

    private func issueSummary(severity: AccessibilityIssue.Severity, count: Int, color: Color) -> some View {
        HStack(spacing: 4) {
            Image(systemName: iconForSeverity(severity))
                .foregroundStyle(color)
                .font(.caption)
            Text("\(count)")
                .font(.caption)
                .fontWeight(.bold)
            Text(severity.label)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private func iconForSeverity(_ severity: AccessibilityIssue.Severity) -> String {
        switch severity {
        case .error: return "xmark.circle.fill"
        case .warning: return "exclamationmark.triangle.fill"
        case .info: return "info.circle.fill"
        }
    }
}

private struct IssueRow: View {
    let issue: AccessibilityIssue

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            // Severity icon
            Image(systemName: severityIcon)
                .foregroundStyle(severityColor)
                .font(.body)
                .frame(width: 20)

            VStack(alignment: .leading, spacing: 4) {
                Text(issue.message)
                    .font(.caption)
                    .fontWeight(.medium)

                if let suggestion = issue.suggestion {
                    HStack(spacing: 4) {
                        Image(systemName: "lightbulb")
                            .font(.caption2)
                            .foregroundStyle(.orange)
                        Text(suggestion)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }

                if let pageIndex = issue.pageIndex {
                    Text("Page \(pageIndex + 1)")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }

            Spacer()
        }
        .padding(.vertical, 4)
    }

    private var severityIcon: String {
        switch issue.severity {
        case .error: return "xmark.circle.fill"
        case .warning: return "exclamationmark.triangle.fill"
        case .info: return "info.circle.fill"
        }
    }

    private var severityColor: Color {
        switch issue.severity {
        case .error: return .red
        case .warning: return .orange
        case .info: return .blue
        }
    }
}
