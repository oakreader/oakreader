import SwiftUI

struct EPUBSettingsView: View {
    @State private var fontSize: Int
    @State private var fontFamily: String
    @State private var theme: EPUBTheme
    @State private var margin: Int
    @State private var lineHeight: Double

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

    init() {
        let prefs = Preferences.shared
        _fontSize = State(initialValue: prefs.epubFontSize)
        _fontFamily = State(initialValue: prefs.epubFontFamily)
        _theme = State(initialValue: prefs.epubTheme)
        _margin = State(initialValue: prefs.epubMargin)
        _lineHeight = State(initialValue: prefs.epubLineHeight)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                typographySection
                Divider()
                themeSection
                Divider()
                layoutSection
                Divider()
                previewSection
                Spacer()
            }
            .padding(20)
        }
    }

    // MARK: - Typography

    private var typographySection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("Typography", systemImage: "textformat")
                .font(.headline)

            HStack(alignment: .top, spacing: 40) {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Font Family")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)

                    Picker("", selection: $fontFamily) {
                        ForEach(fontFamilies, id: \.self) { font in
                            Text(font).font(.custom(font, size: 13)).tag(font)
                        }
                    }
                    .pickerStyle(.menu)
                    .frame(width: 200)
                    .onChange(of: fontFamily) { _, val in
                        Preferences.shared.epubFontFamily = val
                    }
                }

                VStack(alignment: .leading, spacing: 8) {
                    Text("Font Size")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)

                    HStack(spacing: 8) {
                        Button {
                            fontSize = max(12, fontSize - 1)
                            Preferences.shared.epubFontSize = fontSize
                        } label: {
                            Image(systemName: "minus")
                                .frame(width: 24, height: 24)
                        }
                        .buttonStyle(.bordered)

                        Text("\(fontSize) px")
                            .font(.system(.body).monospacedDigit())
                            .frame(width: 50)

                        Button {
                            fontSize = min(36, fontSize + 1)
                            Preferences.shared.epubFontSize = fontSize
                        } label: {
                            Image(systemName: "plus")
                                .frame(width: 24, height: 24)
                        }
                        .buttonStyle(.bordered)
                    }
                }

                VStack(alignment: .leading, spacing: 8) {
                    Text("Line Height")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)

                    HStack(spacing: 8) {
                        Slider(value: $lineHeight, in: 1.2...2.4, step: 0.1)
                            .frame(width: 120)
                            .onChange(of: lineHeight) { _, val in
                                Preferences.shared.epubLineHeight = val
                            }

                        Text(String(format: "%.1f", lineHeight))
                            .font(.system(.body).monospacedDigit())
                            .frame(width: 30)
                    }
                }
            }
        }
    }

    // MARK: - Theme

    private var themeSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("Theme", systemImage: "paintpalette")
                .font(.headline)

            HStack(spacing: 12) {
                ForEach(EPUBTheme.allCases, id: \.self) { t in
                    let isActive = theme == t
                    Button {
                        theme = t
                        Preferences.shared.epubTheme = t
                    } label: {
                        VStack(spacing: 6) {
                            RoundedRectangle(cornerRadius: 8)
                                .fill(Color(hex: t.backgroundColor))
                                .overlay(
                                    VStack(spacing: 4) {
                                        RoundedRectangle(cornerRadius: 2)
                                            .fill(Color(hex: t.textColor))
                                            .frame(height: 3)
                                        RoundedRectangle(cornerRadius: 2)
                                            .fill(Color(hex: t.textColor).opacity(0.6))
                                            .frame(height: 3)
                                        RoundedRectangle(cornerRadius: 2)
                                            .fill(Color(hex: t.textColor).opacity(0.3))
                                            .frame(height: 3)
                                            .frame(maxWidth: 40, alignment: .leading)
                                    }
                                    .padding(12)
                                )
                                .overlay(
                                    RoundedRectangle(cornerRadius: 8)
                                        .stroke(isActive ? Color.accentColor : Color.gray.opacity(0.3), lineWidth: isActive ? 2 : 1)
                                )
                                .frame(width: 75, height: 55)

                            Text(t.label)
                                .font(.caption)
                                .foregroundStyle(isActive ? .primary : .secondary)
                        }
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    // MARK: - Layout

    private var layoutSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("Layout", systemImage: "rectangle.leadinghalf.inset.filled")
                .font(.headline)

            HStack(spacing: 40) {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Page Margins")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)

                    HStack(spacing: 8) {
                        Image(systemName: "arrow.left.and.right")
                            .font(.system(size: 11))
                            .foregroundStyle(.tertiary)

                        Slider(value: Binding(
                            get: { Double(margin) },
                            set: {
                                margin = Int($0)
                                Preferences.shared.epubMargin = margin
                            }
                        ), in: 20...120, step: 10)
                            .frame(width: 160)

                        Text("\(margin) px")
                            .font(.system(.body).monospacedDigit())
                            .frame(width: 50)
                    }
                }
            }
        }
    }

    // MARK: - Preview

    private var previewSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("Preview", systemImage: "eye")
                .font(.headline)

            RoundedRectangle(cornerRadius: 10)
                .fill(Color(hex: theme.backgroundColor))
                .overlay(
                    VStack(alignment: .leading, spacing: CGFloat(lineHeight * 4)) {
                        Text("The Mom Test")
                            .font(.custom(fontFamily, size: CGFloat(fontSize) * 1.2))
                            .fontWeight(.bold)
                            .foregroundColor(Color(hex: theme.textColor))

                        Text("How to talk to customers & learn if your business is a good idea when everyone is lying to you.")
                            .font(.custom(fontFamily, size: CGFloat(fontSize) * 0.8))
                            .foregroundColor(Color(hex: theme.textColor))
                            .lineSpacing(CGFloat(lineHeight * 3))
                    }
                    .padding(CGFloat(margin) * 0.5)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 10)
                        .stroke(Color.gray.opacity(0.3), lineWidth: 1)
                )
                .frame(height: 160)
        }
    }
}
