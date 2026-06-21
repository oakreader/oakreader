import AppKit
import SwiftUI
import OakMarkdownUI

/// A full-screen, PPT-style review mode for the document's notes — one note per
/// "slide", centered on a softly-blurred backdrop, with arrow-key / click
/// navigation, a directional slide transition, shuffle, a top progress bar, and a
/// closing card. Opened from the Notes panel header (the `play.rectangle` button) so
/// you can step through your notes like a deck instead of scrolling the side panel.
/// Mirrors `ImageLightbox`: a borderless window over the whole app, dismissed with
/// Esc or the close button.
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
            case 53:                       dismiss();       return nil   // Esc
            case 123, 126, 116:            ctrl.prev();     return nil   // ←, ↑, PageUp
            case 124, 125, 121, 49:        ctrl.next();     return nil   // →, ↓, PageDown, Space
            case 1:                        ctrl.shuffle();  return nil   // S
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

/// Drives the deck — the slide order (shuffleable), the current position, and the
/// navigation direction (so the transition knows which way to slide). Positions
/// `0..<records.count` are notes; the final position `records.count` is the closing
/// card.
@MainActor
final class NotePresentationController: ObservableObject {
    let records: [AnnotationRecord]
    let model: CommentsViewModel
    /// Slide order — indices into `records`. Shuffling reorders this, not `records`.
    @Published var order: [Int]
    @Published var index: Int
    /// +1 when moving forward, -1 when moving back — read by the slide transition.
    @Published var direction: Int = 1

    init(records: [AnnotationRecord], model: CommentsViewModel, startIndex: Int) {
        self.records = records
        self.model = model
        self.order = Array(records.indices)
        self.index = startIndex
    }

    /// The closing card lives one past the last note.
    var lastIndex: Int { records.count }
    var isFirst: Bool { index <= 0 }
    var isLast: Bool { index >= lastIndex }
    var isClosing: Bool { index >= records.count }
    var current: AnnotationRecord { records[order[min(index, records.count - 1)]] }

    /// 0…1 fill for the top progress bar; full on the closing card.
    var progressFraction: Double {
        guard !records.isEmpty else { return 0 }
        return Double(min(index + 1, records.count)) / Double(records.count)
    }

    func go(to newIndex: Int) {
        let clamped = max(0, min(newIndex, lastIndex))
        guard clamped != index else { return }
        direction = clamped > index ? 1 : -1
        withAnimation(.spring(response: 0.42, dampingFraction: 0.86)) { index = clamped }
    }

    func next() { go(to: index + 1) }
    func prev() { go(to: index - 1) }

    /// Reshuffle the deck and restart from the first card (flomo 漫游 rediscovery).
    func shuffle() {
        guard records.count > 1 else { go(to: 0); return }
        direction = 1
        withAnimation(.spring(response: 0.42, dampingFraction: 0.86)) {
            order.shuffle()
            index = 0
        }
    }
}

private struct NotePresentationView: View {
    @ObservedObject var controller: NotePresentationController
    let onClose: () -> Void

    /// The keyboard-hint pill shows on entry then fades, teaching the shortcuts
    /// without permanent chrome (Mochi's on-screen-shortcut idea).
    @State private var showHints = true

    var body: some View {
        ZStack {
            backdrop

            GeometryReader { geo in
                HStack(spacing: 0) {
                    navGutter(forward: false)
                    Spacer(minLength: 24)
                    slide(maxCardHeight: geo.size.height * 0.84)
                    Spacer(minLength: 24)
                    navGutter(forward: true)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .padding(.vertical, 56)

            progressBar
            closeButton
            bottomChrome
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear {
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
                withAnimation(.easeOut(duration: 0.5)) { showHints = false }
            }
        }
    }

    // MARK: Slide

    private func slide(maxCardHeight: CGFloat) -> some View {
        Group {
            if controller.isClosing {
                SlideCard(maxHeight: maxCardHeight) {
                    ClosingContent(count: controller.records.count,
                                   onShuffle: { controller.shuffle() },
                                   onClose: onClose)
                }
            } else {
                SlideCard(maxHeight: maxCardHeight) {
                    NoteContent(record: controller.current, model: controller.model)
                }
            }
        }
        // Re-identify per position so SwiftUI treats each slide as a distinct view and
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

    /// A softly-blurred backdrop (the page behind, defocused) rather than flat black —
    /// reads as "focus mode" and is gentler on the eyes for a long reading session,
    /// adapting to light/dark automatically. The card's shadow does the separation.
    private var backdrop: some View {
        BlurBackdrop().ignoresSafeArea()
    }

    /// A thin accent progress bar pinned to the very top edge (Quizlet/Mochi) — it
    /// fills as you advance and is full on the closing card.
    private var progressBar: some View {
        VStack(spacing: 0) {
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Rectangle().fill(Color.primary.opacity(0.08))
                    Rectangle()
                        .fill(Color.accentColor)
                        .frame(width: max(0, geo.size.width * controller.progressFraction))
                }
            }
            .frame(height: 3)
            Spacer()
        }
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
                .foregroundStyle(.primary.opacity(disabled ? 0.12 : 0.45))
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
                        .foregroundStyle(.secondary)
                        .padding(20)
                }
                .buttonStyle(.plain)
                .keyboardShortcut(.cancelAction)
                .accessibilityLabel(Text("Close"))
            }
            Spacer()
        }
    }

    /// Bottom-center: the keyboard-hint pill (fades after entry) over the persistent
    /// position counter.
    private var bottomChrome: some View {
        VStack {
            Spacer()
            VStack(spacing: 10) {
                if showHints {
                    Text("←  →   Space   ·   S Shuffle   ·   Esc")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 7)
                        .background(Capsule().fill(.regularMaterial))
                        .transition(.opacity)
                }
                if !controller.isClosing {
                    Text("\(controller.index + 1) / \(controller.records.count)")
                        .font(.system(size: 13, weight: .medium).monospacedDigit())
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 6)
                        .background(Capsule().fill(.regularMaterial))
                }
            }
            .padding(.bottom, 22)
        }
    }
}

/// The shared slide chrome — a fixed-width card whose HEIGHT hugs its content
/// (flomo/Mochi flashcard feel), clamped to a min so tiny notes still read as a card
/// and to a max so long notes scroll inside instead of overflowing the screen. A
/// short note becomes a tidy small card rather than floating in a giant PPT canvas.
/// textBackgroundColor adapts to light/dark; a hairline border and soft shadow lift
/// it off the blurred backdrop. Both the note and the closing card render inside this.
private struct SlideCard<Content: View>: View {
    let maxHeight: CGFloat
    @ViewBuilder var content: Content

    @State private var contentHeight: CGFloat = 0

    /// Card height = the content's natural height, clamped to `[240, maxHeight]`.
    /// Falls back to a sensible default before the first measurement lands.
    private var cardHeight: CGFloat {
        let measured = contentHeight > 0 ? contentHeight : 280
        return min(max(measured, 240), maxHeight)
    }

    var body: some View {
        ScrollView {
            content
                .background(
                    GeometryReader { geo in
                        Color.clear.preference(key: SlideHeightKey.self, value: geo.size.height)
                    }
                )
        }
        .scrollIndicators(.never)
        .onPreferenceChange(SlideHeightKey.self) { contentHeight = $0 }
        .frame(width: 640, height: cardHeight)
        .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
        .background(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .fill(Color(nsColor: .textBackgroundColor))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.08))
        )
        .shadow(color: .black.opacity(0.35), radius: 34, y: 14)
    }
}

/// Reports the natural height of a slide's content so `SlideCard` can hug it.
private struct SlideHeightKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

/// One note rendered as a presentation slide — a large, clean, left-aligned reading
/// column carrying the timestamp, the markdown body (rendered big), any images,
/// `#tag` chips, and the anchored source quote. Reuses the same body/image/tag split
/// as the panel cards.
private struct NoteContent: View {
    let record: AnnotationRecord
    let model: CommentsViewModel

    private var rawBody: String { record.comment ?? "" }
    private var tags: [String] { NoteTags.extract(rawBody) }
    private var images: [String] { NoteComposerBox.splitBody(rawBody).images }
    private var body0: String { NoteTags.strippedBody(NoteComposerBox.splitBody(rawBody).text) }
    private var anchored: Bool { model.isAnchored(record) }

    var body: some View {
        // A LEFT-aligned reading column (prose reads best left-aligned — the
        // timestamp, body, and tags all share one left edge). The card hugs this
        // column's natural height, so there's no forced fill: a short note stays
        // compact and a long one grows until the card's max, then scrolls.
        VStack(alignment: .leading, spacing: 20) {
            Text(NoteTime.absolute(record.createdAt))
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.tertiary)

            if !body0.isEmpty {
                StreamingMarkdownView(markdown: body0, theme: .oak(fontSize: 20))
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
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 44)
        .padding(.vertical, 40)
    }

    @ViewBuilder
    private func slideImage(_ urlString: String) -> some View {
        if let img = OakNoteImageURL.image(urlString) {
            Image(nsImage: img)
                .resizable()
                .scaledToFit()
                .frame(maxWidth: .infinity, maxHeight: 340, alignment: .leading)
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

/// The closing card after the last note — softens the finish (Readwise's bonus card)
/// and offers a one-tap shuffle-again or done.
private struct ClosingContent: View {
    let count: Int
    let onShuffle: () -> Void
    let onClose: () -> Void

    var body: some View {
        VStack(spacing: 18) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 50))
                .foregroundStyle(.green.opacity(0.85))
            Text("That's all")
                .font(.system(size: 28, weight: .semibold))
            Text("\(count) \(count == 1 ? "note" : "notes") reviewed")
                .font(.system(size: 15))
                .foregroundStyle(.secondary)
            HStack(spacing: 12) {
                Button(action: onShuffle) {
                    Label("Shuffle again", systemImage: "shuffle")
                }
                .buttonStyle(.borderedProminent)
                Button("Done", action: onClose)
                    .buttonStyle(.bordered)
            }
            .controlSize(.large)
            .padding(.top, 8)
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 40)
        .padding(.vertical, 52)
    }
}

/// A full-screen blurred backdrop — the page behind, softly defocused. Reads as
/// "focus mode" and adapts to light/dark on its own.
private struct BlurBackdrop: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let v = NSVisualEffectView()
        v.material = .fullScreenUI
        v.blendingMode = .behindWindow
        v.state = .active
        return v
    }

    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {}
}
