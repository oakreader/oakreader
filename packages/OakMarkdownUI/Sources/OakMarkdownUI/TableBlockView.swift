import SwiftUI
import AppKit
import CMarkGFM

/// GFM pipe table rendered as a SwiftUI `Grid`. The raw block text is re-parsed
/// here with the `table` GFM extension attached, so we get cmark-gfm's proper
/// handling of alignment, escaped pipes, and inline formatting inside cells.
///
/// Cells WRAP to fit the available chat width (no horizontal scroll inline — a
/// horizontal `ScrollView` proposes unbounded width, which defeats wrapping and
/// lets long cells run off the edge). For genuinely wide tables, a hover-revealed
/// expand button opens a full-window sheet where the table scrolls un-wrapped.
struct TableBlockView: View {
    let source: String
    let theme: MarkdownTheme

    @State private var isHovering = false

    var body: some View {
        let parsed = TableParser.parse(source: source, theme: theme)
        if parsed.rows.isEmpty {
            // Fall back to plain prose so the user sees *something* readable
            // when the table is malformed (e.g. truncated mid-stream).
            ProseBlockView(
                attributed: MarkdownAttributedBuilder.attributedString(for: source, theme: theme),
                selectable: true,
                animatesAppendedText: false,
                onOpenURL: nil,
                linkPreview: nil
            )
        } else {
            TableGridView(parsed: parsed, theme: theme, wrapsCells: true)
                .background(Color(nsColor: theme.codeBlockBackground))
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .strokeBorder(Color(nsColor: theme.codeBlockBorder), lineWidth: 1)
                )
                .overlay(alignment: .topTrailing) { expandButton(parsed: parsed) }
                .onHover { isHovering = $0 }
        }
    }

    private func expandButton(parsed: TableParser.Parsed) -> some View {
        Button { TableLightbox.show(parsed: parsed, theme: theme) } label: {
            Image(systemName: "arrow.up.left.and.arrow.down.right")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Color(nsColor: theme.textColor))
                .padding(5)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 6))
                .overlay(
                    RoundedRectangle(cornerRadius: 6)
                        .strokeBorder(Color(nsColor: theme.codeBlockBorder), lineWidth: 0.5)
                )
        }
        .buttonStyle(.plain)
        .help("Open table in full screen")
        // Explicit label so SF Symbol a11y lookups don't walk the localized
        // description table on every hover re-render (see SF-symbol-a11y-hang note).
        .accessibilityLabel("Expand table")
        .padding(6)
        .opacity(isHovering ? 1 : 0)
        .animation(.easeInOut(duration: 0.12), value: isHovering)
    }
}

/// The bordered grid itself, shared by the inline view and the fullscreen sheet.
/// `wrapsCells` controls cell sizing: inline tables wrap to the proposed width;
/// the fullscreen sheet lays cells out un-wrapped so a wide table scrolls.
private struct TableGridView: View {
    let parsed: TableParser.Parsed
    let theme: MarkdownTheme
    let wrapsCells: Bool

    var body: some View {
        Grid(alignment: .topLeading, horizontalSpacing: 0, verticalSpacing: 0) {
            ForEach(Array(parsed.rows.enumerated()), id: \.offset) { rowIndex, row in
                GridRow {
                    ForEach(Array(row.enumerated()), id: \.offset) { columnIndex, cell in
                        let alignment = parsed.alignment(forColumn: columnIndex)
                        TableCellView(
                            attributed: cell,
                            isHeader: rowIndex == 0 && parsed.hasHeader,
                            alignment: alignment,
                            theme: theme,
                            wraps: wrapsCells
                        )
                        .gridColumnAlignment(alignment.horizontal)
                    }
                }
                // Full-width hairline between rows. Spanning all columns (rather
                // than per-cell bottom edges) keeps the line straight when cells
                // in a row have different heights.
                if rowIndex != parsed.rows.count - 1 {
                    Rectangle()
                        .fill(Color(nsColor: theme.codeBlockBorder))
                        .frame(height: 1)
                        .gridCellColumns(max(parsed.columnCount, 1))
                }
            }
        }
    }
}

/// Full-screen table preview shown in a borderless window over the whole app with
/// a dimmed scrim — click the scrim (or press Esc / the close button) to dismiss.
/// Mirrors the Notes image lightbox so tables and images feel the same when
/// expanded. Lives here (not the app) so the package stays app-agnostic.
@MainActor
private enum TableLightbox {
    private static var window: NSWindow?
    private static var escMonitor: Any?

    static func show(parsed: TableParser.Parsed, theme: MarkdownTheme) {
        guard let screen = NSScreen.main else { return }
        dismiss()

        let win = NSWindow(contentRect: screen.frame,
                           styleMask: .borderless,
                           backing: .buffered,
                           defer: false)
        win.isOpaque = false
        win.backgroundColor = NSColor.black.withAlphaComponent(0.7)
        win.level = .modalPanel
        win.isReleasedWhenClosed = false
        win.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        win.contentView = NSHostingView(
            rootView: TableLightboxView(parsed: parsed, theme: theme, onClose: dismiss)
        )
        win.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        window = win

        // A borderless window won't reliably receive SwiftUI keyboard shortcuts,
        // so catch Esc with a local monitor.
        escMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            if event.keyCode == 53 { dismiss(); return nil }   // Esc
            return event
        }
    }

    static func dismiss() {
        if let monitor = escMonitor { NSEvent.removeMonitor(monitor); escMonitor = nil }
        window?.orderOut(nil)
        window = nil
    }
}

/// Centered, solid card holding the table. Cells WRAP to a comfortable card width
/// (much wider than inline, so the table is easier to read) and the card hugs the
/// table's height, capped to the screen so a tall table scrolls vertically.
private struct TableLightboxView: View {
    let parsed: TableParser.Parsed
    let theme: MarkdownTheme
    let onClose: () -> Void

    @State private var contentHeight: CGFloat = 0

    var body: some View {
        GeometryReader { geo in
            // Comfortable reading width, capped so it never spans the whole screen.
            let cardWidth = min(geo.size.width - 220, 920)
            let maxH = geo.size.height - 140
            ZStack {
                // Scrim — tap anywhere outside the card to dismiss.
                Color.clear
                    .contentShape(Rectangle())
                    .onTapGesture(perform: onClose)

                ScrollView(.vertical) {
                    TableGridView(parsed: parsed, theme: theme, wrapsCells: true)
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                        .overlay(
                            RoundedRectangle(cornerRadius: 8)
                                .strokeBorder(Color(nsColor: theme.codeBlockBorder), lineWidth: 1)
                        )
                        .frame(width: cardWidth - 48)
                        .padding(24)
                        .background(
                            GeometryReader { proxy in
                                Color.clear.preference(key: TableHeightKey.self, value: proxy.size.height)
                            }
                        )
                }
                .frame(width: cardWidth, height: min(max(contentHeight, 1), maxH))
                // Opaque base first, then the table tint on top, so an alpha-bearing
                // code-block tint can't let the app behind show through the card.
                .background(Color(nsColor: .windowBackgroundColor))
                .background(Color(nsColor: theme.codeBlockBackground))
                .clipShape(RoundedRectangle(cornerRadius: 12))
                .overlay(
                    RoundedRectangle(cornerRadius: 12)
                        .strokeBorder(Color(nsColor: theme.codeBlockBorder), lineWidth: 1)
                )
                .shadow(color: .black.opacity(0.45), radius: 32, y: 10)
                .onPreferenceChange(TableHeightKey.self) { contentHeight = $0 }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .overlay(alignment: .topTrailing) {
                Button(action: onClose) {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 26))
                        .foregroundStyle(.white.opacity(0.85))
                        .padding(20)
                }
                .buttonStyle(.plain)
                .keyboardShortcut(.cancelAction)
                .accessibilityLabel("Close table")
            }
        }
    }
}

private struct TableHeightKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        let next = nextValue()
        if next != 0 { value = next }
    }
}

/// One cell rendered as an attributed-string text view. Header cells render in
/// semibold; alignment is applied to the paragraph style. When `wraps` is true the
/// text wraps within its column; when false it keeps its natural single-line width
/// (the fullscreen sheet scrolls instead of wrapping).
private struct TableCellView: View {
    let attributed: NSAttributedString
    let isHeader: Bool
    let alignment: TableAlignment
    let theme: MarkdownTheme
    let wraps: Bool

    var body: some View {
        let text = Text(AttributedString(styledCell()))
            .multilineTextAlignment(alignment.textAlignment)
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
        if wraps {
            // Allow horizontal shrink + vertical growth so long cells wrap to fit
            // the column the Grid hands them, then fill the column for alignment.
            text
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: alignment.frameAlignment)
        } else {
            // Natural single-line width; the enclosing 2-axis ScrollView scrolls.
            text.fixedSize(horizontal: true, vertical: true)
        }
    }

    private func styledCell() -> NSAttributedString {
        let result = NSMutableAttributedString(attributedString: attributed)
        let range = NSRange(location: 0, length: result.length)
        if isHeader {
            // Semibold, not full bold: the rest of the renderer deliberately maps
            // `**strong**` to a medium weight because SF's bold reads too heavy at
            // body size (see MarkdownAttributedBuilder CMARK_NODE_STRONG). Headers
            // want a touch more emphasis than strong, so semibold — but still not
            // the heavy `.boldFontMask`.
            result.enumerateAttribute(.font, in: range, options: []) { value, sub, _ in
                let base = (value as? NSFont) ?? theme.bodyFont
                let semibold = NSFont.systemFont(ofSize: base.pointSize, weight: .semibold)
                result.addAttribute(.font, value: semibold, range: sub)
            }
        }
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = alignment.nsTextAlignment
        result.addAttribute(.paragraphStyle, value: paragraph, range: range)
        return result
    }
}

/// Column alignment as set by the table separator row (`:---`, `---:`, `:---:`).
enum TableAlignment: Equatable {
    case leading, center, trailing

    init(cmarkByte: UInt8) {
        // cmark-gfm encodes alignment as ASCII 'l', 'c', 'r'; 0 == default (leading).
        switch cmarkByte {
        case UInt8(ascii: "c"): self = .center
        case UInt8(ascii: "r"): self = .trailing
        default: self = .leading
        }
    }

    var horizontal: HorizontalAlignment {
        switch self {
        case .leading: return .leading
        case .center: return .center
        case .trailing: return .trailing
        }
    }

    var frameAlignment: Alignment {
        switch self {
        case .leading: return .leading
        case .center: return .center
        case .trailing: return .trailing
        }
    }

    var textAlignment: TextAlignment {
        switch self {
        case .leading: return .leading
        case .center: return .center
        case .trailing: return .trailing
        }
    }

    var nsTextAlignment: NSTextAlignment {
        switch self {
        case .leading: return .left
        case .center: return .center
        case .trailing: return .right
        }
    }
}

/// Drives cmark-gfm with the `table` extension attached and walks the
/// resulting AST into a row/cell grid of attributed strings.
@MainActor
enum TableParser {
    struct Parsed {
        var rows: [[NSAttributedString]]
        var alignments: [TableAlignment]
        var columnCount: Int
        var hasHeader: Bool

        func alignment(forColumn column: Int) -> TableAlignment {
            column < alignments.count ? alignments[column] : .leading
        }
    }

    static func parse(source: String, theme: MarkdownTheme) -> Parsed {
        let empty = Parsed(rows: [], alignments: [], columnCount: 0, hasHeader: false)
        guard let parser = cmark_parser_new(CMARK_OPT_DEFAULT) else { return empty }
        defer { cmark_parser_free(parser) }
        cmark_gfm_core_extensions_ensure_registered()
        if let tableExt = cmark_find_syntax_extension("table") {
            cmark_parser_attach_syntax_extension(parser, tableExt)
        }
        if let strikethrough = cmark_find_syntax_extension("strikethrough") {
            cmark_parser_attach_syntax_extension(parser, strikethrough)
        }
        let bytes = Array(source.utf8)
        cmark_parser_feed(parser, bytes, bytes.count)
        guard let document = cmark_parser_finish(parser) else { return empty }
        defer { cmark_node_free(document) }

        // Find the first table node in the document.
        var tableNode: UnsafeMutablePointer<cmark_node>?
        var child = cmark_node_first_child(document)
        while let node = child {
            if String(cString: cmark_node_get_type_string(node)) == "table" {
                tableNode = node
                break
            }
            child = cmark_node_next(node)
        }
        guard let table = tableNode else { return empty }

        let columnCount = Int(cmark_gfm_extensions_get_table_columns(table))
        var alignments: [TableAlignment] = []
        if let raw = cmark_gfm_extensions_get_table_alignments(table) {
            alignments = (0..<columnCount).map { TableAlignment(cmarkByte: raw[$0]) }
        } else {
            alignments = Array(repeating: .leading, count: columnCount)
        }

        var rows: [[NSAttributedString]] = []
        var hasHeader = false
        var rowNode = cmark_node_first_child(table)
        while let row = rowNode {
            // cmark-gfm names the header row `table_header` (NOT a `table_row` with the
            // is-header flag), so matching only "table_row" silently drops the header.
            let rowType = String(cString: cmark_node_get_type_string(row))
            if rowType == "table_header" || rowType == "table_row" {
                if rowType == "table_header" || cmark_gfm_extensions_get_table_row_is_header(row) != 0 {
                    hasHeader = true
                }
                var cells: [NSAttributedString] = []
                var cellNode = cmark_node_first_child(row)
                while let cell = cellNode {
                    if String(cString: cmark_node_get_type_string(cell)) == "table_cell" {
                        cells.append(MarkdownAttributedBuilder.renderTableCell(cell, theme: theme))
                    }
                    cellNode = cmark_node_next(cell)
                }
                // Pad/truncate to match column count so the Grid stays rectangular.
                while cells.count < columnCount { cells.append(NSAttributedString()) }
                if cells.count > columnCount { cells = Array(cells.prefix(columnCount)) }
                rows.append(cells)
            }
            rowNode = cmark_node_next(row)
        }

        return Parsed(rows: rows, alignments: alignments, columnCount: columnCount, hasHeader: hasHeader)
    }
}
