import SwiftUI

// MARK: - Shared web-toolbar primitives
//
// Live browsing and snapshot viewing render through the **same** WKWebView
// (`HTMLViewerRepresentable`); only their chrome differs. These atoms are the
// shared pieces of that chrome so the live (`LiveWebToolbarContent`) and
// read-only (`SnapshotToolbarContent`) bars compose instead of copy-paste.

/// A capsule-backed cluster — the pill that wraps the nav buttons, the
/// save/open action, etc. Matches the live toolbar's existing pill styling.
struct ToolbarPill<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        content
            .padding(.horizontal, 2)
            .background(
                // Same neutral capsule fill as the prominent `OakToolButton`
                // (History close, panel pills) so every chrome pill shares one
                // token and reads as the same component.
                Capsule(style: .continuous)
                    .fill(OakStyle.Colors.buttonBackground)
            )
    }
}

/// Read-only URL display with the host emphasized and the path muted — the
/// non-editable counterpart to the live address `TextField`. Used by the
/// snapshot bar, where typing a URL would be meaningless (a frozen file has
/// nowhere to navigate); the user reaches the live page via "Open original".
struct URLLabel: View {
    let url: URL?

    var body: some View {
        let (emphasis, rest) = Self.split(url)
        (Text(emphasis).foregroundStyle(.primary)
            + Text(rest).foregroundStyle(.secondary))
            .font(.system(size: 13))
            .lineLimit(1)
            .truncationMode(.tail)
    }

    /// Splits a URL into (emphasized host, muted remainder). Falls back to the
    /// last path component for schemeless / file URLs that carry no host.
    private static func split(_ url: URL?) -> (String, String) {
        guard let url else { return ("", "") }
        if let host = url.host {
            let h = host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
            var rest = url.path
            if let query = url.query { rest += "?\(query)" }
            return (h, rest)
        }
        return (url.lastPathComponent, "")
    }
}
