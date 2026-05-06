import SwiftUI
import AppKit

struct AnnotationColorDropdown: View {
    @Bindable var viewModel: DocumentViewModel

    @State private var showPopover = false

    var body: some View {
        Button {
            showPopover.toggle()
        } label: {
            HStack(spacing: 3) {
                Circle()
                    .fill(Color(nsColor: viewModel.annotation.strokeColor))
                    .frame(width: 14, height: 14)
                    .overlay(
                        Circle()
                            .strokeBorder(Color(nsColor: .separatorColor), lineWidth: 0.5)
                    )
                Image(systemName: "chevron.down")
                    .font(.system(size: 7, weight: .semibold))
            }
            .frame(height: OakStyle.Size.buttonStandard)
            .padding(.horizontal, 4)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .popover(isPresented: $showPopover) {
            colorPopoverContent
        }
    }

    @ViewBuilder
    private var colorPopoverContent: some View {
        VStack(alignment: .leading, spacing: 10) {
            // Color swatches
            HStack(spacing: 6) {
                ForEach(OakStyle.AnnotationColors.allColors, id: \.name) { entry in
                    colorSwatch(entry.color, nsColor: entry.nsColor, name: entry.name)
                }
            }

            Divider()

            // Line width slider
            sizeControls
        }
        .padding(12)
        .frame(width: 260)
    }

    private var sizeControls: some View {
        sliderRow(
            label: "Line Width",
            value: Binding(
                get: { viewModel.annotation.lineWidth },
                set: { viewModel.annotation.lineWidth = $0 }
            ),
            range: 0.5...8,
            step: 0.5,
            format: "%.1f"
        )
    }

    private func sliderRow(label: String, value: Binding<CGFloat>, range: ClosedRange<CGFloat>, step: CGFloat, format: String) -> some View {
        HStack {
            Text(label)
                .font(OakStyle.Font.styledCaption)
                .foregroundStyle(.secondary)
            Spacer()
            Slider(value: value, in: range, step: step)
                .frame(width: 120)
            Text(String(format: format, value.wrappedValue))
                .font(OakStyle.Font.styledCaption)
                .monospacedDigit()
                .frame(width: 30)
        }
    }

    private func colorSwatch(_ color: Color, nsColor: NSColor, name: String) -> some View {
        Button {
            viewModel.annotation.strokeColor = nsColor
        } label: {
            ZStack {
                Circle()
                    .fill(color)
                    .frame(width: 22, height: 22)
                    .overlay(
                        Circle()
                            .strokeBorder(Color(nsColor: .separatorColor), lineWidth: 0.5)
                    )
                if colorsMatch(viewModel.annotation.strokeColor, nsColor) {
                    Image(systemName: "checkmark")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(name == "Black" ? .white : .black.opacity(0.7))
                }
            }
        }
        .buttonStyle(.plain)
        .help(name)
    }

    private func colorsMatch(_ c1: NSColor, _ c2: NSColor) -> Bool {
        guard let a = c1.usingColorSpace(.sRGB),
              let b = c2.usingColorSpace(.sRGB) else { return false }
        let t: CGFloat = 0.1
        return abs(a.redComponent - b.redComponent) < t
            && abs(a.greenComponent - b.greenComponent) < t
            && abs(a.blueComponent - b.blueComponent) < t
    }
}
