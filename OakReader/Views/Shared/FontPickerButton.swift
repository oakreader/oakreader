import SwiftUI
import AppKit

struct FontPickerButton: View {
    @Binding var fontName: String
    @Binding var fontSize: CGFloat

    @State private var showPopover = false

    var body: some View {
        Button {
            showPopover.toggle()
        } label: {
            HStack(spacing: 4) {
                Image(systemName: "textformat")
                    .font(.caption)
                Text("\(fontName), \(Int(fontSize))pt")
                    .font(.caption)
                    .lineLimit(1)
            }
        }
        .buttonStyle(.bordered)
        .popover(isPresented: $showPopover) {
            FontPickerPopover(fontName: $fontName, fontSize: $fontSize)
                .padding()
                .frame(width: 260, height: 340)
        }
    }
}

private struct FontPickerPopover: View {
    @Binding var fontName: String
    @Binding var fontSize: CGFloat

    @State private var searchText = ""

    private var availableFonts: [String] {
        let families = NSFontManager.shared.availableFontFamilies
        if searchText.isEmpty { return families }
        return families.filter { $0.localizedCaseInsensitiveContains(searchText) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Font")
                .font(.headline)

            HStack {
                Text("Size:")
                TextField("Size", value: $fontSize, formatter: NumberFormatter())
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 60)
                Stepper("", value: $fontSize, in: 4...200, step: 1)
                    .labelsHidden()
            }

            TextField("Search fonts...", text: $searchText)
                .textFieldStyle(.roundedBorder)

            List(availableFonts, id: \.self, selection: $fontName) { family in
                HStack {
                    Text(family)
                        .font(.system(size: 13))
                    Spacer()
                    if family == fontName {
                        Image(systemName: "checkmark")
                            .foregroundStyle(Color.accentColor)
                            .font(.caption)
                    }
                }
                .contentShape(Rectangle())
                .onTapGesture {
                    fontName = family
                }
            }
            .listStyle(.bordered)
        }
    }
}
