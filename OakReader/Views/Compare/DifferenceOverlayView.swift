import SwiftUI
import AppKit

struct DifferenceOverlayView: View {
    let differences: [ComparisonResult.Difference]
    let pageSize: CGSize
    let displaySize: CGSize

    var body: some View {
        ZStack(alignment: .topLeading) {
            Color.clear
                .frame(width: displaySize.width, height: displaySize.height)

            ForEach(differences) { diff in
                let scaledBounds = scaledRect(diff.bounds)
                Rectangle()
                    .fill(Color(nsColor: diff.type.color).opacity(0.25))
                    .overlay(
                        Rectangle()
                            .strokeBorder(Color(nsColor: diff.type.color), lineWidth: 2)
                    )
                    .frame(width: scaledBounds.width, height: scaledBounds.height)
                    .position(x: scaledBounds.midX, y: scaledBounds.midY)
                    .help("\(diff.type.label): \(diff.description)")
            }
        }
        .overlay(alignment: .bottomTrailing) {
            legend
                .padding(8)
        }
    }

    private var legend: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Legend")
                .font(.caption2)
                .fontWeight(.bold)

            ForEach(usedTypes, id: \.rawValue) { type in
                HStack(spacing: 4) {
                    Rectangle()
                        .fill(Color(nsColor: type.color).opacity(0.5))
                        .frame(width: 12, height: 12)
                    Text(type.label)
                        .font(.caption2)
                }
            }
        }
        .padding(6)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 6))
    }

    private var usedTypes: [ComparisonResult.DifferenceType] {
        Array(Set(differences.map(\.type))).sorted { $0.rawValue < $1.rawValue }
    }

    private func scaledRect(_ rect: CGRect) -> CGRect {
        guard pageSize.width > 0 && pageSize.height > 0 else { return rect }
        let scaleX = displaySize.width / pageSize.width
        let scaleY = displaySize.height / pageSize.height

        return CGRect(
            x: rect.origin.x * scaleX,
            y: (pageSize.height - rect.origin.y - rect.height) * scaleY,
            width: rect.width * scaleX,
            height: rect.height * scaleY
        )
    }
}
