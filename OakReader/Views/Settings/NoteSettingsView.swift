import SwiftUI

struct NoteSettingsView: View {
    @State private var fontFamily: String = Preferences.shared.noteEditorFontFamily
    @State private var fontSize: CGFloat = Preferences.shared.noteEditorFontSize
    @State private var codeFontFamily: String = Preferences.shared.noteEditorCodeFontFamily
    @State private var lineHeight: CGFloat = Preferences.shared.noteEditorLineHeight
    @State private var showLineNumbers: Bool = Preferences.shared.noteEditorShowLineNumbers
    @State private var renderMath: Bool = Preferences.shared.noteEditorRenderMath
    @State private var renderImages: Bool = Preferences.shared.noteEditorRenderImages
    @State private var hideSyntax: Bool = Preferences.shared.noteEditorHideSyntax

    private let fontOptions: [(label: String, value: String)] = [
        ("Georgia (Serif)", "'Georgia', 'Times New Roman', 'Iowan Old Style', serif"),
        ("Times New Roman (Serif)", "'Times New Roman', 'Georgia', serif"),
        ("Iowan Old Style (Serif)", "'Iowan Old Style', 'Georgia', serif"),
        ("System (Sans-serif)", "-apple-system, BlinkMacSystemFont, 'SF Pro Text', 'Helvetica Neue', sans-serif"),
    ]

    private let codeFontOptions: [(label: String, value: String)] = [
        ("Iosevka Mono", "'Iosevka Mono', 'SF Mono', Menlo, Monaco, monospace"),
        ("SF Mono", "'SF Mono', Menlo, Monaco, monospace"),
        ("Menlo", "'Menlo', Monaco, monospace"),
        ("Fira Code", "'Fira Code', 'SF Mono', Menlo, monospace"),
    ]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                // MARK: - Typography
                VStack(alignment: .leading, spacing: 12) {
                    Text("Typography")
                        .font(.headline)

                    HStack {
                        Text("Body Font")
                            .frame(width: 100, alignment: .leading)
                        Picker("", selection: $fontFamily) {
                            ForEach(fontOptions, id: \.value) { option in
                                Text(option.label).tag(option.value)
                            }
                        }
                        .labelsHidden()
                        .frame(maxWidth: 300)
                    }
                    .onChange(of: fontFamily) { _, val in Preferences.shared.noteEditorFontFamily = val }

                    HStack {
                        Text("Code Font")
                            .frame(width: 100, alignment: .leading)
                        Picker("", selection: $codeFontFamily) {
                            ForEach(codeFontOptions, id: \.value) { option in
                                Text(option.label).tag(option.value)
                            }
                        }
                        .labelsHidden()
                        .frame(maxWidth: 300)
                    }
                    .onChange(of: codeFontFamily) { _, val in Preferences.shared.noteEditorCodeFontFamily = val }

                    HStack {
                        Text("Font Size")
                            .frame(width: 100, alignment: .leading)
                        Slider(value: $fontSize, in: 13...24, step: 1) {
                            Text("Font Size")
                        }
                        .frame(maxWidth: 200)
                        Text("\(Int(fontSize)) px")
                            .foregroundStyle(.secondary)
                            .frame(width: 50)
                    }
                    .onChange(of: fontSize) { _, val in Preferences.shared.noteEditorFontSize = val }

                    HStack {
                        Text("Line Height")
                            .frame(width: 100, alignment: .leading)
                        Slider(value: $lineHeight, in: 1.2...2.2, step: 0.05) {
                            Text("Line Height")
                        }
                        .frame(maxWidth: 200)
                        Text(String(format: "%.2f", lineHeight))
                            .foregroundStyle(.secondary)
                            .frame(width: 50)
                    }
                    .onChange(of: lineHeight) { _, val in Preferences.shared.noteEditorLineHeight = val }
                }

                Divider()

                // MARK: - Editor Behavior
                VStack(alignment: .leading, spacing: 12) {
                    Text("Editor")
                        .font(.headline)

                    Toggle("Hide markdown syntax on inactive lines", isOn: $hideSyntax)
                        .onChange(of: hideSyntax) { _, val in Preferences.shared.noteEditorHideSyntax = val }

                    Toggle("Show line numbers", isOn: $showLineNumbers)
                        .onChange(of: showLineNumbers) { _, val in Preferences.shared.noteEditorShowLineNumbers = val }
                }

                Divider()

                // MARK: - Rendering
                VStack(alignment: .leading, spacing: 12) {
                    Text("Rendering")
                        .font(.headline)

                    Toggle("Render math formulas (KaTeX)", isOn: $renderMath)
                        .onChange(of: renderMath) { _, val in Preferences.shared.noteEditorRenderMath = val }

                    Toggle("Render inline images", isOn: $renderImages)
                        .onChange(of: renderImages) { _, val in Preferences.shared.noteEditorRenderImages = val }
                }

                Spacer()

                Text("Changes apply to newly opened notes.")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
            .padding(20)
        }
    }
}
