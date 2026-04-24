import SwiftUI

// OakReader-style tag: colored square (not circle), 12px swatch, semibold when colored
struct TagChip: View {
    let name: String
    let colorHex: String
    var isSelected: Bool = false
    var showRemove: Bool = false
    var onTap: (() -> Void)? = nil
    var onRemove: (() -> Void)? = nil

    var body: some View {
        HStack(spacing: 4) {
            // OakReader uses colored squares for tag swatches
            RoundedRectangle(cornerRadius: 2)
                .fill(Color(hex: colorHex))
                .frame(width: 10, height: 10)

            Text(name)
                .font(.system(size: 12))
                .fontWeight(.semibold)
                .lineLimit(1)

            if showRemove {
                Button {
                    onRemove?()
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 8, weight: .bold))
                        .foregroundStyle(.secondary)
                        .frame(width: 16, height: 16)
                        .background(
                            RoundedRectangle(cornerRadius: 3)
                                .fill(Color.primary.opacity(0.06))
                        )
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 3)
        .background(
            RoundedRectangle(cornerRadius: 5)
                .fill(isSelected ? Color.accentColor.opacity(0.15) : Color.primary.opacity(0.05))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 5)
                .strokeBorder(isSelected ? Color.accentColor.opacity(0.4) : Color.clear, lineWidth: 1)
        )
        .contentShape(RoundedRectangle(cornerRadius: 5))
        .onTapGesture {
            onTap?()
        }
    }
}
