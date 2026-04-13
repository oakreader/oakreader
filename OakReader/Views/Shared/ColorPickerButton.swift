import SwiftUI
import AppKit

struct ColorPickerButton: View {
    let title: String
    @Binding var color: NSColor

    @State private var showPopover = false

    var body: some View {
        Button {
            showPopover.toggle()
        } label: {
            HStack(spacing: 6) {
                RoundedRectangle(cornerRadius: 3)
                    .fill(Color(nsColor: color))
                    .frame(width: 20, height: 20)
                    .overlay(
                        RoundedRectangle(cornerRadius: 3)
                            .strokeBorder(Color.primary.opacity(0.3), lineWidth: 1)
                    )
                Text(title)
                    .font(.caption)
            }
        }
        .buttonStyle(.plain)
        .popover(isPresented: $showPopover) {
            ColorPickerPopover(color: $color)
                .padding()
                .frame(width: 220)
        }
    }
}

private struct ColorPickerPopover: View {
    @Binding var color: NSColor

    private let presetColors: [NSColor] = [
        .systemRed, .systemOrange, .systemYellow, .systemGreen,
        .systemBlue, .systemPurple, .systemPink, .systemTeal,
        .black, .darkGray, .gray, .lightGray,
        .white, .brown, .systemIndigo, .systemCyan
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Color")
                .font(.headline)

            LazyVGrid(columns: Array(repeating: GridItem(.fixed(28), spacing: 6), count: 4), spacing: 6) {
                ForEach(presetColors, id: \.self) { preset in
                    Button {
                        color = preset
                    } label: {
                        RoundedRectangle(cornerRadius: 4)
                            .fill(Color(nsColor: preset))
                            .frame(width: 28, height: 28)
                            .overlay(
                                RoundedRectangle(cornerRadius: 4)
                                    .strokeBorder(
                                        color == preset ? Color.accentColor : Color.primary.opacity(0.2),
                                        lineWidth: color == preset ? 2 : 1
                                    )
                            )
                    }
                    .buttonStyle(.plain)
                }
            }

            Divider()

            ColorPicker("Custom Color", selection: Binding(
                get: { Color(nsColor: color) },
                set: { color = NSColor($0) }
            ))
        }
    }
}
