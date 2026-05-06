import SwiftUI

/// Compact settings bar for EPUB reader: font size, font family, theme, margins.
struct EPUBReaderSettingsBar: View {
    let viewModel: DocumentViewModel

    private let fontFamilies = [
        "Palatino",
        "Georgia",
        "Iowan Old Style",
        "Athelas",
        "Charter",
        "Seravek",
        "Helvetica Neue",
        "Avenir Next",
        "SF Pro Text",
        "Menlo"
    ]

    var body: some View {
        HStack(spacing: 16) {
            // Font size
            HStack(spacing: 4) {
                Button {
                    viewModel.state.epubFontSize = max(12, viewModel.state.epubFontSize - 2)
                } label: {
                    Image(systemName: "textformat.size.smaller")
                        .font(.system(size: 11))
                        .frame(width: 22, height: 22)
                }
                .buttonStyle(.plain)
                .help("Decrease font size")

                Text("\(viewModel.state.epubFontSize)")
                    .font(.system(size: 11).monospacedDigit())
                    .frame(width: 22)

                Button {
                    viewModel.state.epubFontSize = min(32, viewModel.state.epubFontSize + 2)
                } label: {
                    Image(systemName: "textformat.size.larger")
                        .font(.system(size: 11))
                        .frame(width: 22, height: 22)
                }
                .buttonStyle(.plain)
                .help("Increase font size")
            }

            Divider().frame(height: 16)

            // Font family
            Picker("", selection: Binding(
                get: { viewModel.state.epubFontFamily },
                set: { viewModel.state.epubFontFamily = $0 }
            )) {
                ForEach(fontFamilies, id: \.self) { font in
                    Text(font).font(.system(size: 11)).tag(font)
                }
            }
            .pickerStyle(.menu)
            .frame(width: 130)
            .help("Font family")

            Divider().frame(height: 16)

            // Theme
            HStack(spacing: 4) {
                ForEach(EPUBTheme.allCases, id: \.self) { theme in
                    let isActive = viewModel.state.epubTheme == theme
                    Button {
                        viewModel.state.epubTheme = theme
                    } label: {
                        Circle()
                            .fill(Color(hex: theme.backgroundColor) ?? .white)
                            .stroke(isActive ? Color.accentColor : Color.gray.opacity(0.4), lineWidth: isActive ? 2 : 1)
                            .frame(width: 16, height: 16)
                    }
                    .buttonStyle(.plain)
                    .help(theme.label)
                }
            }

            Divider().frame(height: 16)

            // Margins
            HStack(spacing: 4) {
                Image(systemName: "arrow.left.and.right")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)

                Slider(
                    value: Binding(
                        get: { Double(viewModel.state.epubMargin) },
                        set: { viewModel.state.epubMargin = Int($0) }
                    ),
                    in: 20...120,
                    step: 10
                )
                .frame(width: 80)
                .help("Page margins")
            }

            Spacer()
        }
        .padding(.horizontal, 12)
        .frame(height: 30)
        .background(Color(nsColor: .windowBackgroundColor))
    }
}

