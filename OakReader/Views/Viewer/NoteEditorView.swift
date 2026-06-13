import SwiftUI
import AppKit
import OakMarkdownUI

/// The note/comment editor shown in an anchored popover when the user adds or
/// opens a note on a highlight. Design grounded in active-reading research:
///  - color + style live in the box (categorization — Marshall; PDF Expert),
///  - a Markdown comment with **live preview** as you type (the explicit end of
///    Marshall's telegraphic↔explicit annotation spectrum),
///  - keyboard-first save/dismiss (Readwise),
///  - anchored to the highlight so the note stays in context (LiquidText).
struct NoteEditorView: View {
    let initialComment: String
    let initialColorIndex: Int
    let initialKind: PDFMarkupKind

    let onColorChange: (Int) -> Void
    let onKindChange: (PDFMarkupKind) -> Void
    let onCommentChange: (String) -> Void
    let onDelete: () -> Void
    let onClose: () -> Void

    @State private var comment: String
    @State private var colorIndex: Int
    @State private var kind: PDFMarkupKind
    @FocusState private var editorFocused: Bool

    private let palette = OakStyle.AnnotationColors.highlightColors

    init(
        initialComment: String,
        initialColorIndex: Int,
        initialKind: PDFMarkupKind,
        onColorChange: @escaping (Int) -> Void,
        onKindChange: @escaping (PDFMarkupKind) -> Void,
        onCommentChange: @escaping (String) -> Void,
        onDelete: @escaping () -> Void,
        onClose: @escaping () -> Void
    ) {
        self.initialComment = initialComment
        self.initialColorIndex = initialColorIndex
        self.initialKind = initialKind
        self.onColorChange = onColorChange
        self.onKindChange = onKindChange
        self.onCommentChange = onCommentChange
        self.onDelete = onDelete
        self.onClose = onClose
        _comment = State(initialValue: initialComment)
        _colorIndex = State(initialValue: initialColorIndex)
        _kind = State(initialValue: initialKind)
    }

    /// Fixed panel size — the hosting NSPanel positions itself from this, so the
    /// content must NOT resize as the user types (that caused the popover to drift).
    static let panelWidth: CGFloat = 340
    static let panelHeight: CGFloat = 300

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            controlRow
            Divider()
            editor
            Divider()
            preview
            Divider()
            footer
        }
        .frame(width: Self.panelWidth, height: Self.panelHeight)
        .background(.ultraThinMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.08), lineWidth: 1)
        )
        .onAppear { editorFocused = true }
    }

    // MARK: - Color + style row

    private var controlRow: some View {
        HStack(spacing: 8) {
            ForEach(Array(palette.enumerated()), id: \.offset) { index, swatch in
                Button {
                    colorIndex = index
                    onColorChange(index)
                } label: {
                    Circle()
                        .fill(swatch.color)
                        .frame(width: 18, height: 18)
                        .overlay(
                            Circle().strokeBorder(Color.primary.opacity(colorIndex == index ? 0.7 : 0.0), lineWidth: 2)
                        )
                }
                .buttonStyle(.plain)
                .help(swatch.name)
            }

            Spacer(minLength: 8)

            styleToggle
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    private var styleToggle: some View {
        HStack(spacing: 2) {
            styleButton(.highlight, system: "highlighter")
            styleButton(.underline, system: "underline")
        }
        .padding(2)
        .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
    }

    private func styleButton(_ target: PDFMarkupKind, system: String) -> some View {
        Button {
            kind = target
            onKindChange(target)
        } label: {
            Image(systemName: system)
                .font(.system(size: 12, weight: .medium))
                .frame(width: 26, height: 22)
                .background(
                    RoundedRectangle(cornerRadius: 5, style: .continuous)
                        .fill(kind == target ? Color.primary.opacity(0.12) : .clear)
                )
        }
        .buttonStyle(.plain)
        .foregroundStyle(kind == target ? Color.primary : Color.secondary)
        .help(target == .highlight ? "Highlight" : "Underline")
    }

    // MARK: - Editor + live preview

    private var editor: some View {
        TextEditor(text: $comment)
            .font(.system(size: 13))
            .scrollContentBackground(.hidden)
            .frame(height: 88)
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .focused($editorFocused)
            .overlay(alignment: .topLeading) {
                if comment.isEmpty {
                    Text("Write a note… (Markdown)")
                        .font(.system(size: 13))
                        .foregroundStyle(.tertiary)
                        .padding(.horizontal, 13)
                        .padding(.vertical, 14)
                        .allowsHitTesting(false)
                }
            }
            .onChange(of: comment) { _, newValue in
                onCommentChange(newValue)
            }
    }

    private var preview: some View {
        ScrollView {
            if comment.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                HStack {
                    Text("Preview")
                        .font(.system(size: 11))
                        .foregroundStyle(.tertiary)
                    Spacer()
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
            } else {
                StreamingMarkdownView(markdown: comment, theme: .oak(fontSize: 13))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    // MARK: - Footer

    private var footer: some View {
        HStack {
            Button(role: .destructive) {
                onDelete()
            } label: {
                Image(systemName: "trash")
                    .font(.system(size: 12))
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .help("Delete note")

            Spacer()

            Button("Done") {
                onClose()
            }
            .keyboardShortcut(.return, modifiers: .command)
            .controlSize(.small)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }
}
