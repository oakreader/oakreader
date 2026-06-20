import SwiftUI
import OakMarkdownUI

/// flomo-style **Note Detail** popup. Opened from a card's "N references" row, it
/// shows the note itself on the left ("This note") and every note that quotes /
/// references it on the right ("Quoted by N notes") — each rendered in full
/// rather than as a truncated one-line backlink. Tapping a referencing card
/// focuses it back in the stream and dismisses the sheet.
struct NoteDetailSheet: View {
    let record: AnnotationRecord
    let model: CommentsViewModel
    let onDismiss: () -> Void

    private var backlinks: [AnnotationRecord] { model.backlinkRecords(to: record.id) }

    var body: some View {
        VStack(spacing: 0) {
            titleBar
            Divider()
            ScrollView {
                HStack(alignment: .top, spacing: 20) {
                    column(caption: "This note") {
                        NoteReadCard(record: record, model: model, onDismiss: onDismiss)
                    }

                    column(caption: backlinks.count == 1
                           ? "Quoted by 1 note" : "Quoted by \(backlinks.count) notes") {
                        if backlinks.isEmpty {
                            Text("No other notes reference this one yet.")
                                .font(.system(size: 13))
                                .foregroundStyle(.tertiary)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.vertical, 8)
                        } else {
                            VStack(spacing: 12) {
                                ForEach(backlinks, id: \.id) { ref in
                                    NoteReadCard(record: ref, model: model, onDismiss: onDismiss) {
                                        onDismiss()
                                        model.focusCard(id: ref.id)
                                    }
                                }
                            }
                        }
                    }
                }
                .padding(20)
            }
        }
        .frame(width: 760, height: 520)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private var titleBar: some View {
        ZStack {
            Text("Note Detail")
                .font(.system(size: 14, weight: .semibold))
            HStack {
                Spacer()
                Button(action: onDismiss) {
                    Image(systemName: "xmark")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .frame(width: 24, height: 24)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Close")
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    private func column<Content: View>(
        caption: String, @ViewBuilder _ content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(caption)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.tertiary)
            content()
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }
}

// MARK: - Read-only card

/// A read-only render of a note (timestamp · tags · body · images · anchored
/// source) used inside the detail popup — no menu, no edit, no hover chrome.
/// Optional `onTap` makes the whole card a button (used for backlinks).
private struct NoteReadCard: View {
    let record: AnnotationRecord
    let model: CommentsViewModel
    var onDismiss: (() -> Void)? = nil
    var onTap: (() -> Void)? = nil

    private var rawBody: String { record.comment ?? "" }
    private var tags: [String] { NoteTags.extract(rawBody) }
    private var images: [String] { NoteComposerBox.splitBody(rawBody).images }
    private var body0: String { NoteTags.strippedBody(NoteComposerBox.splitBody(rawBody).text) }
    private var anchored: Bool { model.isAnchored(record) }
    private var accent: Color { NoteColor.parse(record.color) }

    var body: some View {
        let card = VStack(alignment: .leading, spacing: 8) {
            Text(NoteTime.absolute(record.createdAt))
                .font(.system(size: 12))
                .foregroundStyle(.tertiary)

            if !tags.isEmpty {
                FlowLayout(spacing: 6) {
                    ForEach(tags, id: \.self) { NoteTagChip(tag: $0, isActive: false) {} }
                }
            }

            if !body0.isEmpty {
                MarkdownEngineReadOnlyView(
                    markdown: body0,
                    documentId: "note-detail-\(record.id)",
                    onOpenURL: openURL
                )
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            if !images.isEmpty {
                FlowLayout(spacing: 6) {
                    ForEach(images, id: \.self) { tile($0) }
                }
            }

            if anchored, let quoted = record.text, !quoted.isEmpty {
                sourceRow(quoted)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color(nsColor: .textBackgroundColor))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.12), lineWidth: 1)
        )

        if let onTap {
            Button(action: onTap) { card }
                .buttonStyle(.plain)
                .help("Jump to this note")
        } else {
            card
        }
    }

    /// Mirror `CommentsPanelView.openURL` so `oak://note/<id>` links inside the
    /// detail popup jump to the referenced note (dismissing the sheet first)
    /// instead of falling through to macOS, which has no handler for the scheme.
    private func openURL(_ url: URL) -> Bool {
        if let id = NoteLink.id(from: url) {
            onDismiss?()
            model.focusCard(id: id)
            return true
        }
        if let doc = model.parent, doc.liveURL != nil || doc.state.currentURL != nil,
           let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https" {
            NotificationCenter.default.post(name: .webViewLoadURL, object: doc, userInfo: ["url": url])
            return true
        }
        return false
    }

    private func tile(_ urlString: String) -> some View {
        Group {
            if let url = URL(string: urlString), let img = NSImage(contentsOf: url) {
                Image(nsImage: img)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .frame(width: 80, height: 80)
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .strokeBorder(Color.primary.opacity(0.06))
                    )
            }
        }
    }

    private func sourceRow(_ quoted: String) -> some View {
        HStack(spacing: 7) {
            ZStack {
                Circle().fill(accent.opacity(0.9)).frame(width: 18, height: 18)
                Image(systemName: "arrow.up.left")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(.white)
            }
            Text(quoted)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .lineLimit(2)
            Spacer(minLength: 0)
        }
        .padding(.top, 2)
    }
}
