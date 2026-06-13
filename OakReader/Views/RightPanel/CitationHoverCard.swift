import SwiftUI

/// Rich hover card shown when the cursor dwells on an `oak://cite/...` citation link in
/// the chat. It replaces the raw-URL tooltip (`oak://cite/…?page=1&text=…`) with the cited
/// source itself, the way OpenAI's research/annotation UI surfaces a passage: a small
/// location chip (page / heading / timestamp) above the verbatim quoted text.
struct CitationHoverCard: View {
    let citeKey: String
    let anchor: CitationAnchor

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            locationChip

            if let quote = anchor.text, !quote.isEmpty {
                HStack(alignment: .top, spacing: 8) {
                    RoundedRectangle(cornerRadius: 1.5)
                        .fill(Color.accentColor.opacity(0.55))
                        .frame(width: 3)
                    Text(quote)
                        .font(.system(size: 13))
                        .foregroundStyle(.primary)
                        .lineSpacing(2)
                        .lineLimit(10)
                        .fixedSize(horizontal: false, vertical: true)
                }
            } else if anchor.heading == nil {
                Text("Jump to source")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }
        }
        .padding(12)
        .frame(width: 300, alignment: .leading)
    }

    private var locationChip: some View {
        HStack(spacing: 5) {
            Image(systemName: locationIcon)
                .font(.system(size: 10, weight: .semibold))
            Text(locationLabel)
                .font(.system(size: 11, weight: .semibold))
                .lineLimit(1)
        }
        .foregroundStyle(.secondary)
    }

    private var locationLabel: String {
        if let page = anchor.page { return "Page \(page + 1)" }       // page is 0-based
        if let heading = anchor.heading, !heading.isEmpty { return heading }
        if let time = anchor.time { return Self.timestamp(time) }
        return "Source"
    }

    private var locationIcon: String {
        if anchor.page != nil { return "doc.text" }
        if anchor.heading != nil { return "number" }
        if anchor.time != nil { return "clock" }
        return "quote.opening"
    }

    private static func timestamp(_ seconds: Double) -> String {
        let total = Int(seconds.rounded())
        let h = total / 3600, m = (total % 3600) / 60, s = total % 60
        return h > 0
            ? String(format: "%d:%02d:%02d", h, m, s)
            : String(format: "%d:%02d", m, s)
    }
}
