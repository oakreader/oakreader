import AppKit
import OakMarkdownUI
import SwiftUI

/// The QuickChatSkill panel's UI, hosted inside a borderless `NSPanel`.
///
/// Material choices follow the spec's §8: the card body is `.regularMaterial`
/// with a whitening gradient — the same recipe as `CommandPaletteView`, so the
/// two panels read as the same object — and NOT `NSGlassEffectView`, which
/// bleeds across a borderless transparent window and dims what is behind it
/// (see the `command-palette-swiftui-rewrite` notes). The result pane is the
/// one deliberate departure from Raycast: warm paper and a serif body, so
/// model output reads as prose rather than as UI text.
struct QuickChatPanelView: View {
    @Bindable var model: QuickChatModel

    /// Width of the window when summoned over another application.
    static var standaloneWidth: CGFloat { cardWidth + shadowInset * 2 }

    private let reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion

    /// Which answer the pointer is over, so only its actions show.
    @State private var hoveredTurn: Int?

    /// Height of the rendered transcript. Measured rather than computed: the
    /// TextKit estimate that sized the old plain-text pane cannot account for
    /// headings, lists and code blocks. The content is `fixedSize` vertically,
    /// so this reads its natural height rather than the scroll view's offer.
    @State private var measuredTranscript: CGFloat = 0


    private static let cardWidth: CGFloat = 640
    private static let rowHeight: CGFloat = 40
    private static let maxListHeight: CGFloat = 320
    private static let maxResultHeight: CGFloat = 340
    private static let cornerRadius: CGFloat = 16
    private static let gutter: CGFloat = 18
    /// Room for the window shadow, so it is not clipped at the window edge.
    private static let shadowInset: CGFloat = 26

    // Spotlight's proportions: a prominent query, comfortable rows, a quiet
    // caption. The query is the one place that gets display size.
    private static let bodySize: CGFloat = 14.5
    private static let uiSize: CGFloat = 14

    /// Explicit rather than `Color.primary` / `windowBackgroundColor`: semantic
    /// colours resolve through the effective appearance and vibrancy, which is
    /// what a floating glass panel changes out from under them.
    private static let buttonInk = Color(nsColor: NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor(white: 0.96, alpha: 1)
            : NSColor(white: 0.10, alpha: 1)
    })
    private static let buttonGlyph = Color(nsColor: NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor(white: 0.10, alpha: 1)
            : NSColor(white: 1.0, alpha: 1)
    })
    private static let captionSize: CGFloat = 12
    /// The captured text is the subject of the panel, not a caption about it.
    private static let sourceSize: CGFloat = 14
    private static let topFraction: CGFloat = 0.16
    private static let easePop = SwiftUI.Animation.timingCurve(0.2, 0.8, 0.2, 1, duration: 0.18)

    var body: some View {
        if model.onCardHeight != nil && model.isStandalonePresentation {
            standaloneBody
        } else {
            windowedBody
        }
    }

    /// Over another app the card reports its height and the window follows it.
    ///
    /// `fixedSize` vertically is what makes that terminate. `NSHostingView`
    /// offers the root the whole window height; without it the card accepts the
    /// offer, the GeometryReader measures the stretched height, and the window
    /// is resized to the size it already was — a loop whose fixed point is
    /// whatever height the window happened to start at, padded out with empty
    /// space. Pinned to the top for the same reason: so the card grows downward
    /// rather than centring in a window sized to itself.
    private var standaloneBody: some View {
        VStack(spacing: 0) {
            card
                .frame(width: Self.cardWidth)
                .fixedSize(horizontal: false, vertical: true)
                .padding(Self.shadowInset)
                .background(
                    GeometryReader { geo in
                        Color.clear
                            .onChange(of: geo.size.height, initial: true) { _, height in
                                model.onCardHeight?(height)
                            }
                    }
                )
            Spacer(minLength: 0)
        }
        .opacity(model.isVisible ? 1 : 0)
        .animation(reduceMotion ? nil : Self.easePop, value: model.isVisible)
    }

    /// Inside OakReader: a full-size transparent backdrop that dismisses on an
    /// outside click, as the command palette does.
    private var windowedBody: some View {
        GeometryReader { geo in
            ZStack(alignment: .top) {
                Color.clear
                    .contentShape(Rectangle())
                    .onTapGesture { model.onDismiss?() }

                card
                    .frame(width: Self.cardWidth)
                    .padding(.top, geo.size.height * Self.topFraction)
                    .scaleEffect(model.isVisible ? 1 : 0.985, anchor: .top)
                    .offset(y: model.isVisible ? 0 : -6)
                    .opacity(model.isVisible ? 1 : 0)
                    .animation(reduceMotion ? nil : Self.easePop, value: model.isVisible)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    // MARK: - Card

    private var card: some View {
        VStack(spacing: 0) {
            sourceRow
            if !model.turns.isEmpty {
                transcript
            }
            if model.isPickingSkill {
                skillList
            }
            composer
        }
        .quickChatGlass(cornerRadius: Self.cornerRadius)
        .contentShape(RoundedRectangle(cornerRadius: Self.cornerRadius, style: .continuous))
        .animation(reduceMotion ? nil : .easeOut(duration: 0.15), value: model.phase)
    }

    // MARK: - Source

    /// The captured text, plus a line naming what was captured. Sending context
    /// is never invisible (§4).
    @ViewBuilder
    private var sourceRow: some View {
        if let png = model.capture.imageData, let image = NSImage(data: png) {
            captureRow(image)
        } else {
            quotedTextRow
        }
    }

    /// A screenshot needs no quoting. The rule, the tint and the camera glyph
    /// all exist to say "this came from somewhere else", which a picture says
    /// by being a picture — so it gets the width instead, because the one thing
    /// you actually need from it is to see whether you framed the right region.
    private func captureRow(_ image: NSImage) -> some View {
        let size = Self.displaySize(for: image)
        return HStack(spacing: 0) {
            Image(nsImage: image)
                .resizable()
                // An exact size, not `maxWidth`. A max-width frame is greedy: it
                // takes the whole row, centres the image inside itself, and then
                // the clip shape rounds the frame rather than the picture — which
                // is why neither the alignment nor the corners appeared to work.
                .frame(width: size.width, height: size.height)
                .clipShape(RoundedRectangle(cornerRadius: 13, style: .continuous))
            Spacer(minLength: 0)
        }
        .padding(.horizontal, Self.gutter - 4)
        .padding(.top, 12)
        .padding(.bottom, 10)
    }

    /// The capture scaled to fit the card, keeping its aspect ratio.
    private static func displaySize(for image: NSImage) -> CGSize {
        let available = cardWidth - (gutter - 4) * 2
        let natural = image.size
        guard natural.width > 0, natural.height > 0 else {
            return CGSize(width: available, height: 160)
        }
        let scale = min(available / natural.width, 210 / natural.height)
        return CGSize(
            width: floor(natural.width * scale),
            height: floor(natural.height * scale)
        )
    }

    private var quotedTextRow: some View {
        HStack(alignment: .top, spacing: 10) {
            Text(model.capture.text)
                .font(.system(size: Self.sourceSize))
                .foregroundStyle(.secondary)
                .italic()
                .lineLimit(2)
                .truncationMode(.middle)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)

            Spacer(minLength: 12)

            if let icon = sourceAppIcon {
                Image(nsImage: icon)
                    .resizable()
                    .frame(width: 18, height: 18)
                    .padding(.top, 1)
                    .help(model.capture.externalAppName ?? "")
            }
        }
        .padding(.leading, 25)
        .padding(.trailing, 12)
        .padding(.vertical, 11)
        .background(
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .fill(Color.primary.opacity(0.045))
        )
        .overlay(alignment: .leading) {
            RoundedRectangle(cornerRadius: 1.5, style: .continuous)
                .fill(Color.secondary.opacity(0.45))
                .frame(width: 3)
                .padding(.vertical, 10)
                .padding(.leading, 12)
        }
        .padding(.horizontal, Self.gutter - 4)
        .padding(.top, 12)
        .padding(.bottom, 10)
    }

    /// The icon of the app the selection came from. Nil for OakReader's own
    /// surfaces, where naming the app would be noise.
    private var sourceAppIcon: NSImage? {
        guard let bundleID = model.capture.externalBundleID,
              let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID)
        else { return nil }
        return NSWorkspace.shared.icon(forFile: url.path)
    }

    // MARK: - Filter

    /// A composer, not a search field. The magnifying glass said "filter this
    /// list"; what the field actually does is take an instruction, so it is
    /// shaped like the thing it is — a bordered capsule with a send button, the
    /// shape every chat input on the machine already uses.
    private var composer: some View {
        let hasText = !model.query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        return HStack(alignment: .center, spacing: 10) {
            QuickChatInputField(
                model: model,
                placeholder: model.turns.isEmpty
                    ? (model.capture.imageData != nil
                        ? "Ask about this screenshot\u{2026}"
                        : "Ask anything, or / for a skill\u{2026}")
                    : "Reply, or \u{23CE} to \(model.primaryDestination.title.lowercased())"
            )

            if model.phase == .streaming {
                Button { model.onStop?() } label: {
                    ZStack {
                        Circle()
                            .fill(Self.buttonInk)
                            .frame(width: 28, height: 28)
                        RoundedRectangle(cornerRadius: 2.5)
                            .fill(Self.buttonGlyph)
                            .frame(width: 10, height: 10)
                    }
                    .compositingGroup()
                }
                .buttonStyle(.plain)
                .help("Stop generating")
            } else {
                Button { model.activateSelection() } label: {
                    ZStack {
                        Circle()
                            .fill(hasText ? Self.buttonInk : Color.gray.opacity(0.3))
                            .frame(width: 28, height: 28)
                        Image(systemName: "arrow.up")
                            .font(.system(size: 14, weight: .bold))
                            .foregroundStyle(Self.buttonGlyph)
                    }
                    // Its own buffer, so the fill is composited before anything
                    // layered above it gets a say: glass applies vibrancy to what
                    // sits on it, and a non-activating panel can read as inactive
                    // and dim control content. Either turns a solid fill into a
                    // pale wash.
                    .compositingGroup()
                }
                .buttonStyle(.plain)
                .disabled(!hasText)
                .help("Send (\u{23CE})")
            }
        }
        .padding(.leading, 14)
        .padding(.trailing, 8)
        .padding(.vertical, 7)
        // The right panel's composer, not a second invention: same radius,
        // border and surface as `ChatComposerStyle`, same 28pt circular button.
        .background(Capsule(style: .continuous).fill(OakStyle.Colors.diaSurface))
        .overlay(
            Capsule(style: .continuous)
                .stroke(
                    Color.primary.opacity(ChatComposerStyle.borderOpacity),
                    lineWidth: ChatComposerStyle.borderWidth
                )
        )
        .padding(.horizontal, Self.gutter - 4)
        .padding(.top, model.turns.isEmpty ? 2 : 6)
        .padding(.bottom, 10)
    }


    // MARK: - Skill list

    private var skillList: some View {
        let rows = model.rankedSkills
        return ScrollViewReader { proxy in
            ScrollView {
                VStack(spacing: 1) {
                    ForEach(Array(rows.enumerated()), id: \.element.id) { index, row in
                        skillRow(row, isSelected: index == model.selectedIndex, position: index)
                            .id("skill:\(row.id)")
                            .onTapGesture { model.run(row.skill) }
                    }
                }
                .padding(.vertical, 6)
            }
            .frame(height: min(Self.maxListHeight, CGFloat(rows.count) * (Self.rowHeight + 1) + 12))
            .onChange(of: model.selectedIndex) { _, index in
                guard index >= 0, index < rows.count else { return }
                proxy.scrollTo("skill:\(rows[index].id)", anchor: .center)
            }
        }
    }

    /// Row geometry is where Raycast's quality lives (§8): fixed height, icon at
    /// a constant x, title at a constant x, accessory right-aligned, and the
    /// selection an inset filled rect rather than a full-bleed row.
    private func skillRow(_ row: QuickChatRow, isSelected: Bool, position: Int) -> some View {
        HStack(spacing: 10) {
            Image(systemName: row.skill.icon)
                .font(.system(size: 15, weight: .regular))
                .foregroundStyle(isSelected ? .primary : .secondary)
                .frame(width: 20, height: 20)
            Text(row.isAdHoc ? "Run: \(row.skill.name)" : row.skill.name)
                .font(.system(size: Self.uiSize))
                .foregroundStyle(.primary)
                .lineLimit(1)
            Spacer(minLength: 10)
            if model.query.isEmpty, position < 3, !row.isDemoted {
                KeycapHint(text: "⌘\(position + 1)", size: 10.5)
                    .opacity(isSelected ? 1 : 0.55)
            }
            if let accessory = accessory(for: row) {
                Text(accessory)
                    .font(.system(size: 11.5))
                    .foregroundStyle(isSelected ? .secondary : Color(nsColor: .tertiaryLabelColor))
            }
        }
        .padding(.horizontal, Self.gutter)
        .frame(height: Self.rowHeight)
        .background(
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .fill(isSelected ? Color(nsColor: .quaternaryLabelColor) : .clear)
                .padding(.horizontal, 8)
        )
        .opacity(row.isDemoted ? 0.38 : 1)
        .contentShape(Rectangle())
    }

    private func accessory(for row: QuickChatRow) -> String? {
        if row.isAdHoc { return "⏎" }
        if row.isDemoted { return demotionReason(row.skill) }
        if row.skill.id == "translate" { return "→ \(model.targetLanguageLabel)" }
        return nil
    }

    /// Naming *why* a skill is demoted is the whole point of demoting rather
    /// than hiding it.
    private func demotionReason(_ skill: QuickChatSkill) -> String? {
        if skill.requiresWritable && !model.capture.isWritable { return "read-only" }
        if skill.requiresOwnSource && !model.capture.isMyLanguage { return "not your language" }
        if skill.requiresForeignSource && model.capture.isMyLanguage { return "already yours" }
        return nil
    }

    // MARK: - Result

    /// Warm paper, serif body. Material rather than a divider line separates
    /// input from output, and the serif marks this text as model output.
    private var transcript: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    ForEach(model.turns) { turn in
                        turnView(turn).id(turn.id)
                    }
                    if case .failed(let message) = model.phase {
                        Text("Request failed: \(message)")
                            .font(.system(size: Self.captionSize))
                            .foregroundStyle(Color(nsColor: .systemRed))
                    } else if model.phase == .stopped {
                        Text("Stopped · \u{23CE} to run again")
                            .font(.system(size: Self.captionSize))
                            .foregroundStyle(.tertiary)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, Self.gutter)
                .padding(.top, 14)
                .padding(.bottom, 16)
                .background(
                    GeometryReader { geo in
                        Color.clear.onChange(of: geo.size.height, initial: true) { _, height in
                            measuredTranscript = height
                        }
                    }
                )
            }
            .frame(height: min(max(measuredTranscript, 48), Self.maxResultHeight))
            .onChange(of: model.result) { _, _ in
                guard let last = model.turns.last else { return }
                withAnimation(reduceMotion ? nil : .easeOut(duration: 0.12)) {
                    proxy.scrollTo(last.id, anchor: .bottom)
                }
            }
        }
    }

    @ViewBuilder
    private func turnView(_ turn: QuickChatTurn) -> some View {
        switch turn.role {
        case .user:
            HStack {
                Spacer(minLength: 48)
                Text(turn.text)
                    .font(.system(size: Self.bodySize))
                    .foregroundStyle(.primary)
                    .multilineTextAlignment(.leading)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .fill(Color.primary.opacity(0.07))
                    )
                    .textSelection(.enabled)
            }
        case .assistant:
            VStack(alignment: .leading, spacing: 6) {
                if turn.text.isEmpty && model.phase == .streaming {
                    StreamingCursor()
                } else {
                    // The app has one markdown renderer and this is it. Plain
                    // Text left every heading and list marker on screen as
                    // literal asterisks.
                    StreamingMarkdownView(
                        markdown: turn.text,
                        isStreaming: model.phase == .streaming && turn.id == model.turns.last?.id,
                        fadesAppendedText: !reduceMotion
                    )
                    .frame(maxWidth: .infinity, alignment: .leading)
                }

                // Attached to the answer rather than to the window: in a
                // transcript "copy the result" is ambiguous, and the one you
                // mean is the one under the pointer.
                if !turn.text.isEmpty, model.phase != .streaming {
                    HStack(spacing: 2) {
                        ForEach(model.availableDestinations) { destination in
                            turnAction(destination, for: turn)
                        }
                    }
                    .opacity(hoveredTurn == turn.id ? 1 : 0)
                    .animation(reduceMotion ? nil : .easeOut(duration: 0.12), value: hoveredTurn)
                }
            }
            // One hit area for the whole turn. Without `contentShape` the
            // hoverable region is only the union of the children's shapes, and
            // each plain Button installs its own tracking area — entering one
            // made the parent report "outside", so the icons faded out exactly
            // as the pointer reached them.
            .contentShape(Rectangle())
            .onHover { inside in
                if inside {
                    hoveredTurn = turn.id
                } else if hoveredTurn == turn.id {
                    hoveredTurn = nil
                }
            }
        }
    }

    private func turnAction(_ destination: QuickChatDestination, for turn: QuickChatTurn) -> some View {
        let isConfirmed = model.confirmation != nil && hoveredTurn == turn.id
        return Button {
            model.onDeliver?(destination, turn.text)
        } label: {
            Image(systemName: isConfirmed && destination == model.primaryDestination
                  ? "checkmark" : destination.icon)
                .font(.system(size: 11.5))
                .foregroundStyle(.secondary)
                .frame(width: 24, height: 22)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        // Re-asserts the hover the parent is about to lose to this button's own
        // tracking area.
        .onHover { inside in
            if inside { hoveredTurn = turn.id }
        }
        .help(destination.title)
    }

    /// Measured with TextKit rather than from inside the scroll view: a
    /// ScrollView claims whatever it is offered, so sizing it from its own
    /// content makes the two define each other, and under the card's
    /// `fixedSize` that loop settles on a collapsed pane.
}

// MARK: - Keycap

private struct KeycapHint: View {
    let text: String
    var size: CGFloat = 11

    var body: some View {
        Text(text)
            .font(.system(size: size, design: .monospaced))
            .foregroundStyle(.tertiary)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(
                RoundedRectangle(cornerRadius: 4)
                    .fill(Color.primary.opacity(0.06))
                    .overlay(
                        RoundedRectangle(cornerRadius: 4)
                            .strokeBorder(Color(nsColor: .separatorColor).opacity(0.5), lineWidth: 0.5)
                    )
            )
    }
}

// MARK: - Filter field

/// `NSTextField` bridged into SwiftUI, for the same reason the palette does it:
/// AppKit's `doCommandBy` handles ↑/↓/⏎/Esc reliably while a field holds focus.
private struct QuickChatInputField: NSViewRepresentable {
    static let querySizeStatic: CGFloat = 14

    /// The model is the text's home. There was a `@Binding` here, written from
    /// the coordinator's captured `parent` — a struct snapshot taken once at
    /// `makeCoordinator()` and never refreshed, so the write went through a
    /// binding from first layout. The model is a class and already in hand, so
    /// the indirection bought nothing and could silently drop a keystroke.
    let model: QuickChatModel

    /// Matches the chat's framing — ask in words, `/` when you mean a skill
    /// specifically — so one grammar covers both surfaces.
    let placeholder: String

    func makeNSView(context: Context) -> NSTextField {
        let field = NSTextField()
        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.font = .systemFont(ofSize: Self.querySizeStatic, weight: .regular)
        field.textColor = .labelColor
        field.placeholderString = placeholder
        field.lineBreakMode = .byTruncatingTail
        field.usesSingleLineMode = true
        field.cell?.isScrollable = true
        field.delegate = context.coordinator

        model.requestFocus = { [weak field] in
            guard let field, let window = field.window else { return }
            window.makeFirstResponder(field)
        }
        return field
    }

    func updateNSView(_ field: NSTextField, context: Context) {
        // Keep the coordinator's snapshot current regardless; a stale parent is
        // the trap this type is famous for.
        context.coordinator.parent = self
        if field.stringValue != model.query {
            field.stringValue = model.query
        }
        if field.placeholderString != placeholder {
            field.placeholderString = placeholder
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    final class Coordinator: NSObject, NSTextFieldDelegate {
        var parent: QuickChatInputField
        init(_ parent: QuickChatInputField) { self.parent = parent }

        func controlTextDidChange(_ obj: Notification) {
            guard let field = obj.object as? NSTextField else { return }
            parent.model.query = field.stringValue
            parent.model.selectedIndex = 0
        }

        func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
            switch selector {
            case #selector(NSResponder.moveDown(_:)):
                parent.model.moveSelection(down: true); return true
            case #selector(NSResponder.moveUp(_:)):
                parent.model.moveSelection(down: false); return true
            case #selector(NSResponder.insertNewline(_:)):
                parent.model.activateSelection(); return true
            case #selector(NSResponder.insertTab(_:)):
                parent.model.completeSelection(); return true
            case #selector(NSResponder.cancelOperation(_:)):
                parent.model.escape(); return true
            default:
                return false
            }
        }
    }
}


// MARK: - Vibrancy

/// The ground Spotlight and the system's own panels use: an
/// `NSVisualEffectView` sampling what is behind the window. Deliberately not
/// `NSGlassEffectView` — inside a borderless transparent panel it bleeds across
/// the whole window and dims what is behind it (see the
/// `command-palette-swiftui-rewrite` notes) — and deliberately not a material
/// with a gradient painted over it, which is what made this read flat grey.
private struct QuickChatVibrancy: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = .hudWindow
        view.blendingMode = .behindWindow
        view.state = .active
        return view
    }

    func updateNSView(_ view: NSVisualEffectView, context: Context) {}
}


// MARK: - Glass

private extension View {
    /// Liquid Glass on macOS 26, `NSVisualEffectView` vibrancy below it.
    ///
    /// The earlier objection was to `NSGlassEffectView` inside a borderless
    /// panel that covered the whole parent window — there it bled across the
    /// full window and dimmed everything behind. This panel is sized to the
    /// card, and SwiftUI's `glassEffect(_:in:)` applies the material to a
    /// shape rather than to a layer-backed view filling a transparent window,
    /// which is the case the API is built for.
    @ViewBuilder
    func quickChatGlass(cornerRadius: CGFloat) -> some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        if #available(macOS 26.0, *) {
            self.glassEffect(.regular, in: shape)
        } else {
            self.background(QuickChatVibrancy())
                .clipShape(shape)
                .overlay(
                    shape.inset(by: 0.5)
                        .stroke(Color.white.opacity(0.10), lineWidth: 1)
                        .blendMode(.plusLighter)
                )
                .shadow(color: .black.opacity(0.22), radius: 18, y: 8)
        }
    }
}
