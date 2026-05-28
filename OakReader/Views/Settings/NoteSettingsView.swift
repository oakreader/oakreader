import SwiftUI

struct NoteSettingsView: View {
    @State private var editorMode: String = Preferences.shared.noteEditorMode
    @State private var fontFamily: String = NoteSettingsView.normalizedFont(Preferences.shared.noteEditorFontFamily)
    @State private var codeFontFamily: String = Preferences.shared.noteEditorCodeFontFamily
    @State private var lineHeight: CGFloat = Preferences.shared.noteEditorLineHeight
    @State private var lineSpacing: CGFloat = Preferences.shared.noteEditorLineSpacing
    @State private var letterSpacing: CGFloat = Preferences.shared.noteEditorLetterSpacing
    @State private var renderMath: Bool = Preferences.shared.noteEditorRenderMath
    @State private var accentColorHex: String = Preferences.shared.noteEditorAccentColor

    /// Map legacy stored values onto current picker options so the selection shows.
    static func normalizedFont(_ value: String) -> String {
        switch value {
        case "", ".AppleSystemUIFont": return value.isEmpty ? "default" : "system"
        default: return value
        }
    }

    private static let presetColors: [(label: String, hex: String)] = [
        ("Teal", "#0CA69A"),
        ("Blue", "#4A90D9"),
        ("Purple", "#7B5DC2"),
        ("Rose", "#C95D8A"),
        ("Orange", "#D4873A"),
        ("Green", "#5DAA68"),
    ]

    private let fontOptions: [(label: String, value: String)] = [
        ("Default (Serif)", "default"),
        ("System (Sans-serif)", "system"),
        ("PingFang SC", "PingFang SC"),
        ("LXGW WenKai", "LXGW WenKai"),
        ("Songti SC", "Songti SC"),
        ("Kaiti SC", "STKaiti"),
        ("TsangerJinKai", "TsangerJinKai02-W04"),
        ("Georgia", "Georgia"),
        ("Iowan Old Style", "Iowan Old Style"),
        ("Helvetica Neue", "Helvetica Neue"),
        ("Palatino", "Palatino"),
        ("Monospace (PT Mono)", "mono"),
    ]

    private let codeFontOptions: [(label: String, value: String)] = [
        ("Iosevka", "Iosevka"),
        ("Iosevka Fixed", "Iosevka Fixed"),
        ("Menlo", "Menlo"),
        ("Courier New", "Courier New"),
    ]

    private let modeOptions: [(label: String, value: String)] = [
        ("Edit", "edit"),
        ("Preview", "preview"),
    ]

    var body: some View {
        Form {
            Section("Editor") {
                Picker("Default Mode", selection: $editorMode) {
                    ForEach(modeOptions, id: \.value) { option in
                        Text(option.label).tag(option.value)
                    }
                }
                .onChange(of: editorMode) { _, val in Preferences.shared.noteEditorMode = val }
            }

            Section("Typography") {
                Picker("Body Font", selection: $fontFamily) {
                    ForEach(fontOptions, id: \.value) { option in
                        Text(option.label).tag(option.value)
                    }
                }
                .onChange(of: fontFamily) { _, val in Preferences.shared.noteEditorFontFamily = val }

                Picker("Code Font", selection: $codeFontFamily) {
                    ForEach(codeFontOptions, id: \.value) { option in
                        Text(option.label).tag(option.value)
                    }
                }
                .onChange(of: codeFontFamily) { _, val in Preferences.shared.noteEditorCodeFontFamily = val }

                LabeledContent("Line Height") {
                    HStack {
                        Slider(value: $lineHeight, in: 1.0...1.8, step: 0.05)
                        Text(String(format: "%.2f", lineHeight))
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                            .frame(width: 56, alignment: .trailing)
                    }
                }
                .onChange(of: lineHeight) { _, val in Preferences.shared.noteEditorLineHeight = val }

                LabeledContent("Line Spacing") {
                    HStack {
                        Slider(value: $lineSpacing, in: 0...8, step: 0.5)
                        Text(String(format: "%.1f pt", lineSpacing))
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                            .frame(width: 56, alignment: .trailing)
                    }
                }
                .onChange(of: lineSpacing) { _, val in Preferences.shared.noteEditorLineSpacing = val }

                LabeledContent("Letter Spacing") {
                    HStack {
                        Slider(value: $letterSpacing, in: 0...1.0, step: 0.1)
                        Text(String(format: "%.1f", letterSpacing))
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                            .frame(width: 56, alignment: .trailing)
                    }
                }
                .onChange(of: letterSpacing) { _, val in Preferences.shared.noteEditorLetterSpacing = val }
            }

            Section("Appearance") {
                LabeledContent("Accent Color") {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack(spacing: 8) {
                            ForEach(Self.presetColors, id: \.hex) { preset in
                                Button {
                                    accentColorHex = preset.hex
                                    Preferences.shared.noteEditorAccentColor = preset.hex
                                } label: {
                                    Circle()
                                        .fill(Color(hex: preset.hex))
                                        .frame(width: 20, height: 20)
                                        .overlay(
                                            Circle()
                                                .strokeBorder(Color.primary, lineWidth: accentColorHex == preset.hex ? 2 : 0)
                                        )
                                }
                                .buttonStyle(.plain)
                                .help(preset.label)
                            }
                        }
                        HStack(spacing: 8) {
                            Circle()
                                .fill(Color(hex: accentColorHex))
                                .frame(width: 20, height: 20)
                            TextField("Hex", text: $accentColorHex)
                                .textFieldStyle(.roundedBorder)
                                .frame(width: 90)
                                .onSubmit {
                                    let hex = accentColorHex.hasPrefix("#") ? accentColorHex : "#\(accentColorHex)"
                                    if NSColor(hex: hex) != nil {
                                        accentColorHex = hex
                                        Preferences.shared.noteEditorAccentColor = hex
                                    }
                                }
                        }
                    }
                }
            }

            Section("Preview") {
                Toggle("Render math formulas (KaTeX)", isOn: $renderMath)
                    .onChange(of: renderMath) { _, val in Preferences.shared.noteEditorRenderMath = val }
            }

            Text("Changes apply to newly opened notes.")
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
        .formStyle(.grouped)
    }
}
