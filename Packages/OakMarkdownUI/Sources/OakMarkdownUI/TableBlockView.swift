import SwiftUI
import AppKit
import CMarkGFM

/// GFM pipe table rendered as a SwiftUI `Grid`. The raw block text is re-parsed
/// here with the `table` GFM extension attached, so we get cmark-gfm's
/// proper handling of alignment, escaped pipes, and inline formatting inside
/// cells. Wrapped in a horizontal `ScrollView` so wide tables don't blow out
/// the chat column.
struct TableBlockView: View {
    let source: String
    let theme: MarkdownTheme

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
            ScrollView(.horizontal, showsIndicators: false) {
                Grid(alignment: .topLeading, horizontalSpacing: 0, verticalSpacing: 0) {
                    ForEach(Array(parsed.rows.enumerated()), id: \.offset) { rowIndex, row in
                        GridRow {
                            ForEach(Array(row.enumerated()), id: \.offset) { columnIndex, cell in
                                let alignment = parsed.alignment(forColumn: columnIndex)
                                TableCellView(
                                    attributed: cell,
                                    isHeader: rowIndex == 0 && parsed.hasHeader,
                                    alignment: alignment,
                                    theme: theme
                                )
                                .gridColumnAlignment(alignment.horizontal)
                            }
                        }
                        if rowIndex == 0 && parsed.hasHeader {
                            Divider().gridCellColumns(max(parsed.columnCount, 1))
                        }
                    }
                }
                .background(Color(nsColor: theme.codeBlockBackground))
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .strokeBorder(Color(nsColor: theme.codeBlockBorder), lineWidth: 1)
                )
            }
        }
    }
}

/// One cell rendered as an attributed-string text view. Header cells render
/// in semibold; alignment is applied to the paragraph style.
private struct TableCellView: View {
    let attributed: NSAttributedString
    let isHeader: Bool
    let alignment: TableAlignment
    let theme: MarkdownTheme

    var body: some View {
        let styled = styledCell()
        Text(AttributedString(styled))
            .multilineTextAlignment(alignment.textAlignment)
            .frame(maxWidth: .infinity, alignment: alignment.frameAlignment)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
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
enum TableAlignment {
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
            if String(cString: cmark_node_get_type_string(row)) == "table_row" {
                if cmark_gfm_extensions_get_table_row_is_header(row) != 0 {
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
