import AppKit
import SwiftUI
import OakMarkdownUI

/// A full-screen, PPT-style review mode for the document's notes — one note per
/// "slide", centered on a dimmed backdrop, with arrow-key / click navigation and a
/// slide cross-fade between cards. Opened from the Notes panel header (the
/// `play.rectangle` button) so you can step through your notes like a deck instead
/// of scrolling the side panel. Mirrors `ImageLightbox`: a borderless window over
/// the whole app, dismissed with Esc or the close button.
@MainActor
enum NotePresentation {
    private static var window: NSWindow?
    private static var keyMonitor: Any?
    private static var controller: NotePresentationController?

    static func show(records: [AnnotationRecord], model: CommentsViewModel, startIndex: Int = 0) {
        guard !records.isEmpty, let screen = NSScreen.main else { return }
        dismiss()

        let start = max(0, min(startIndex, records.count - 1))
        let ctrl = NotePresentationController(records: records, model: model, startIndex: start)
        controller = ctrl

        let win = NSWindow(contentRect: screen.frame,
                           styleMask: .borderless,
                           backing: .buffered,
                           defer: false)
        win.isOpaque = false
        win.backgroundColor = .clear
        win.level = .modalPanel
        win.isReleasedWhenClosed = false
        win.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        win.contentView = NSHostingView(rootView: NotePresentationView(controller: ctrl, onClose: dismiss))
        win.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        window = win

        // A borderless window won't reliably receive SwiftUI keyboard shortcuts, so
        // drive navigation from a local key monitor (same approach as ImageLightbox).
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            switch event.keyCode {
            case 53:                       dismiss();    return nil   // Esc
            case 123, 126, 116:            ctrl.prev();  return nil   // ←, ↑, PageUp
            case 124, 125, 121, 49:        ctrl.next();  return nil   // →, ↓, PageDown, Space
            default:                       return event
            }
        }
    }

    static func dismiss() {
        if let monitor = keyMonitor { NSEvent.removeMonitor(monitor); keyMonitor = nil }
        window?.orderOut(nil)
        window = nil
        controller = nil
    }
}

/// Drives the deck — the current slide index and the navigation direction (so the
/// slide transition knows whether to come in from the left or the right).
@MainActor
final class NotePresentationController: ObservableObject {
    let records: [AnnotationRecord]
    let model: CommentsViewModel
    @Published var index: Int
    /// +1 when moving forward, -1 when moving back — read by the slide transition.
    @Published var direction: Int = 1

    init(records: [AnnotationRecord], model: CommentsViewModel, startIndex: Int) {
        self.records = records
        self.model = model
        self.index = startIndex
    }

    var isFirst: Bool { index <= 0 }
    var isLast: Bool { index >= records.count - 1 }

    func go(to newIndex: Int) {
        guard newIndex >= 0, newIndex < records.count, newIndex != index else { return }
        direction = newIndex > index ? 1 : -1
        withAnimation(.spring(response: 0.42, dampingFraction: 0.86)) { index = newIndex }
    }

    func next() { go(to: index + 1) }
    func prev() { go(to: index - 1) }
}

private struct NotePresentationView: View {
    @ObservedObject var controller: NotePresentationController
    let onClose: () -> Void

    var body: some View {
        ZStack {
            backdrop

            HStack(spacing: 0) {
                navGutter(forward: false)
                Spacer(minLength: 24)
                slide
                Spacer(minLength: 24)
                navGutter(forward: true)
            }
            .padding(.vertical, 48)

            closeButton
            progress
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: Slide

    private var slide: some View {
        NoteSlide(record: controller.records[controller.index], model: controller.model)
            // Re-identify per index so SwiftUI treats each note as a distinct view and
            // runs the insertion/removal transition on the swap.
            .id(controller.index)
            .transition(slideTransition)
    }

    /// A direction-aware cross-slide: the outgoing card leaves toward one edge while
    /// the incoming card enters from the opposite edge — the classic deck advance.
    private var slideTransition: AnyTransition {
        let forward = controller.direction >= 0
        return .asymmetric(
            insertion: .move(edge: forward ? .trailing : .leading).combined(with: .opacity),
            removal: .move(edge: forward ? .leading : .trailing).combined(with: .opacity)
        )
    }

    // MARK: Chrome

    private var backdrop: some View {
        // A dark slide backdrop so the card reads as a floating "slide". Not tappable —
        // dismiss is the explicit close button / Esc, so a stray click never drops the
        // deck (navigation lives on the side gutters and the arrow keys).
        LinearGradient(
            colors: [Color.black.opacity(0.95), Color.black.opacity(0.86)],
            startPoint: .top, endPoint: .bottom
        )
        .ignoresSafeArea()
    }

    /// A side tap region with a chevron — left advances back, right advances forward.
    /// The center card stays fully interactive (text selection, links) because the
    /// gutters sit outside it.
    private func navGutter(forward: Bool) -> some View {
        let disabled = forward ? controller.isLast : controller.isFirst
        return Button {
            forward ? controller.next() : controller.prev()
        } label: {
            Image(systemName: forward ? "chevron.right" : "chevron.left")
                .font(.system(size: 22, weight: .medium))
                .foregroundStyle(.white.opacity(disabled ? 0.12 : 0.55))
                .frame(width: 72)
                .frame(maxHeight: .infinity)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(disabled)
        .accessibilityLabel(Text(forward ? "Next note" : "Previous note"))
    }

    private var closeButton: some View {
        VStack {
            HStack {
                Spacer()
                Button(action: onClose) {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 26))
                        .foregroundStyle(.white.opacity(0.85))
                        .padding(20)
                }
                .buttonStyle(.plain)
                .keyboardShortcut(.cancelAction)
                .accessibilityLabel(Text("Close"))
            }
            Spacer()
        }
    }

    private var progress: some View {
        VStack {
            Spacer()
            Text("\(controller.index + 1) / \(controller.records.count)")
                .font(.system(size: 13, weight: .medium).monospacedDigit())
                .foregroundStyle(.white.opacity(0.55))
                .padding(.horizontal, 14)
                .padding(.vertical, 6)
                .background(Capsule().fill(Color.white.opacity(0.10)))
                .padding(.bottom, 22)
        }
    }
}

/// One note rendered as a presentation slide — a large, clean card carrying the
/// timestamp, the markdown body (rendered big), any images, `#tag` chips, and the
/// anchored source quote. Reuses the same body/image/tag split as the panel cards.
private struct NoteSlide: View {
    let record: AnnotationRecord
    let model: CommentsViewModel

    private var rawBody: String { record.comment ?? "" }
    private var tags: [String] { NoteTags.extract(rawBody) }
    private var images: [String] { NoteComposerBox.splitBody(rawBody).images }
    private var body0: String { NoteTags.strippedBody(NoteComposerBox.splitBody(rawBody).text) }
    private var anchored: Bool { model.isAnchored(record) }

    var body: some View {
        GeometryReader { geo in
            ScrollView {
                // A LEFT-aligned reading column (prose reads best left-aligned — the
                // timestamp, body, and tags all share one left edge). The column is a
                // bounded width, centered in the card; the `minHeight` frame forces it
                // to at least the card height so a short note sits centered vertically
                // too (PPT-style), while a long note grows and scrolls.
                VStack(alignment: .leading, spacing: 24) {
                    Text(NoteTime.absolute(record.createdAt))
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(.tertiary)

                    if !body0.isEmpty {
                        StreamingMarkdownView(markdown: body0, theme: .oak(fontSize: 26))
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }

                    if !images.isEmpty {
                        ForEach(images, id: \.self) { slideImage($0) }
                    }

                    if !tags.isEmpty {
                        HStack(spacing: 8) {
                            ForEach(tags, id: \.self) { NoteTagChip(tag: $0) }
                        }
                    }

                    if anchored, let quoted = record.text?.trimmingCharacters(in: .whitespacesAndNewlines), !quoted.isEmpty {
                        sourceQuote(quoted)
                    }
                }
                .frame(maxWidth: 720, alignment: .leading)
                .padding(.horizontal, 64)
                .padding(.vertical, 56)
                .frame(maxWidth: .infinity, minHeight: geo.size.height, alignment: .center)
            }
            .scrollIndicators(.never)
        }
        // A fixed slide proportion (16:10) so each note reads as a real "slide",
        // capped at a comfortable reading width and fit within the available area.
        .frame(maxWidth: 1040)
        .aspectRatio(16.0 / 10.0, contentMode: .fit)
        .background(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .fill(Color(nsColor: .textBackgroundColor))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.08))
        )
        .shadow(color: .black.opacity(0.45), radius: 34, y: 14)
    }

    @ViewBuilder
    private func slideImage(_ urlString: String) -> some View {
        if let url = URL(string: urlString), let img = NSImage(contentsOf: url) {
            Image(nsImage: img)
                .resizable()
                .scaledToFit()
                .frame(maxWidth: .infinity, maxHeight: 420, alignment: .leading)
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .strokeBorder(Color.primary.opacity(0.06))
                )
        }
    }

    /// The anchored highlight this note points at — a quoted caption with a left
    /// accent bar (read-only here; jump-to-source navigation lives in the panel).
    private func sourceQuote(_ quoted: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            RoundedRectangle(cornerRadius: 2)
                .fill(OakStyle.Colors.noteAccent.opacity(0.5))
                .frame(width: 3)
            Text(quoted)
                .font(.system(size: 15).italic())
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.top, 4)
    }
}
