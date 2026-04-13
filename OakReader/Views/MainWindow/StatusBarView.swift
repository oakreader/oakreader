import SwiftUI

struct StatusBarView: View {
    let viewModel: DocumentViewModel

    var body: some View {
        HStack(spacing: 16) {
            // Zoom percentage
            Text(viewModel.viewer.zoomPercentage)
                .foregroundStyle(.secondary)
                .frame(width: 50)

            Divider()
                .frame(height: 14)

            // File size
            if let url = viewModel.document?.fileURL,
               let size = FileCoordination.fileSizeString(for: url) {
                HStack(spacing: 4) {
                    Image(systemName: "doc")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    Text(size)
                        .foregroundStyle(.secondary)
                }
            }

            Spacer()
        }
        .font(.caption)
        .padding(.horizontal, 12)
        .padding(.vertical, 3)
        .background(Color(nsColor: .windowBackgroundColor))
    }
}
