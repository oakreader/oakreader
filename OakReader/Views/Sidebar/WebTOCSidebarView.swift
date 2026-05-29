import SwiftUI

/// A heading extracted from a live web page's DOM.
struct WebHeading: Identifiable, Decodable, Equatable {
    let level: Int        // 1–6 (the heading tag level)
    let title: String
    let elementId: String // DOM id used to scroll the page to this heading

    var id: String { elementId }
}

/// Left-sidebar table of contents for a live `.link` browser tab. Renders the
/// page's heading outline as a flat, level-indented list; tapping a row scrolls
/// the underlying WKWebView to that heading.
struct WebTOCSidebarView: View {
    let viewModel: DocumentViewModel

    @State private var selectedId: String?

    private var headings: [WebHeading] { viewModel.state.tableOfContents }

    /// Normalize indentation against the shallowest heading present so pages that
    /// start at h2/h3 aren't pushed to the right.
    private var minLevel: Int { headings.map(\.level).min() ?? 1 }

    var body: some View {
        VStack(spacing: 0) {
            header

            if headings.isEmpty {
                emptyState
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 2) {
                        ForEach(headings) { heading in
                            row(heading)
                        }
                    }
                    .padding(.vertical, 6)
                    .padding(.horizontal, 4)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 6) {
            Image(systemName: "list.bullet.indent")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)

            Text("Contents")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.secondary)

            Spacer()

            if !headings.isEmpty {
                Text("\(headings.count)")
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    // MARK: - Row

    private func row(_ heading: WebHeading) -> some View {
        let depth = max(0, heading.level - minLevel)
        return Button {
            selectedId = heading.id
            NotificationCenter.default.post(
                name: .webViewScrollToTOC,
                object: viewModel,
                userInfo: ["id": heading.elementId]
            )
        } label: {
            HStack(spacing: 0) {
                Spacer()
                    .frame(width: CGFloat(depth) * 12)

                Text(heading.title)
                    .font(.system(size: depth == 0 ? 13 : 12,
                                  weight: depth == 0 ? .semibold : .regular))
                    .foregroundStyle(depth == 0 ? .primary : .secondary)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)

                Spacer()
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
            .background(
                RoundedRectangle(cornerRadius: 4)
                    .fill(selectedId == heading.id ? Color.accentColor.opacity(0.15) : .clear)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    // MARK: - Empty State

    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: "list.bullet.rectangle")
                .font(.system(size: 24))
                .foregroundStyle(Color.primary.opacity(0.15))

            Text("No Contents")
                .font(.system(size: 13))
                .foregroundStyle(.secondary)

            Text("This page has no headings\nto build a table of contents.")
                .font(.system(size: 11))
                .foregroundStyle(Color.primary.opacity(0.25))
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
