import SwiftUI

// MARK: - Shared Panel Helpers

@ViewBuilder
func panelHeader(_ title: String, subtitle: String) -> some View {
    HStack(alignment: .firstTextBaseline) {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.system(size: 16, weight: .semibold))
            Text(subtitle)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }

        Spacer()
    }
    .padding(.horizontal, 12)
    .padding(.vertical, 8)
}

@ViewBuilder
func emptyState(icon: String, title: String, subtitle: String) -> some View {
    VStack(spacing: 10) {
        Spacer()
        Image(systemName: icon)
            .font(.system(size: 36))
            .foregroundStyle(.tertiary)
        Text(title)
            .font(.system(size: 15, weight: .semibold))
            .foregroundStyle(.secondary)
        Text(subtitle)
            .font(.system(size: 13))
            .foregroundStyle(.tertiary)
            .multilineTextAlignment(.center)
            .padding(.horizontal, 24)
        Spacer()
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
}
