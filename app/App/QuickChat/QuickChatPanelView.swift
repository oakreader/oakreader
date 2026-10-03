import AppKit
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
    private var sourceRow: some View {
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
        // A quote rule, the way Mail and Notes mark text from somewhere else.
        // As an overlay rather than an HStack sibling: a Shape fills every
        // dimension it is not given, so as a sibling it stretched the row to
        // whatever height was going spare and left a tall empty block.
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
        // Read here rather than through a computed property: an @Observable
        // read inside a Button's label closure is not reliably tracked, so the
        // button kept the colour it was first drawn with.
        let hasText = !model.query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        return HStack(alignment: .center, spacing: 10) {
            QuickChatInputField(
                text: $model.query,
                model: model,
                placeholder: model.turns.isEmpty
                    ? "Ask anything, or / for a skill\u{2026}"
                    : "Reply, or \u{23CE} to \(model.primaryDestination.title.lowercased())"
            )

            if model.phase == .streaming {
                Button { model.onStop?() } label: {
                    ZStack {
                        Circle()
                            .fill(Color.primary)
                            .frame(width: 28, height: 28)
                        RoundedRectangle(cornerRadius: 2.5)
                            .fill(Color(nsColor: .windowBackgroundColor))
                            .frame(width: 10, height: 10)
                    }
                }
                .buttonStyle(.plain)
                .help("Stop generating")
            } else {
                Button { model.activateSelection() } label: {
                    ZStack {
                        Circle()
                            .fill(hasText ? Color.primary : Color.gray.opacity(0.3))
                            .frame(width: 28, height: 28)
                        Image(systemName: "arrow.up")
                            .font(.system(size: 14, weight: .bold))
                            .foregroundStyle(Color(nsColor: .windowBackgroundColor))
                    }
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
                .padding(.horizontal, Self.gutter)
                .padding(.top, 14)
                .padding(.bottom, 16)
            }
            .frame(height: transcriptHeight)
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
                    Text(turn.text)
                        .font(.system(size: Self.bodySize))
                        .lineSpacing(4)
                        .foregroundStyle(.primary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)
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

    /// How tall the transcript should be.
    ///
    /// Measured with TextKit rather than from inside the scroll view: a
    /// ScrollView claims whatever it is offered, so sizing it from its own
    /// content makes the two define each other, and under the card's
    /// `fixedSize` that loop settles on a collapsed pane.
    private var transcriptHeight: CGFloat {
        let userWidth = Self.cardWidth - Self.gutter * 2 - 48 - 24
        let assistantWidth = Self.cardWidth - Self.gutter * 2

        var total: CGFloat = 14 + 16
        for (index, turn) in model.turns.enumerated() {
            if index > 0 { total += 12 }
            let isUser = turn.role == .user
            let text = turn.text.isEmpty ? " " : turn.text
            total += Self.textHeight(text, width: isUser ? userWidth : assistantWidth)
            total += isUser ? 16 : 22
        }
        if model.phase != .done && model.phase != .choosing { total += 22 }
        return min(max(total, 48), Self.maxResultHeight)
    }

    private static func textHeight(_ text: String, width: CGFloat) -> CGFloat {
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineSpacing = 4
        let bounds = (text as NSString).boundingRect(
            with: NSSize(width: width, height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading],
            attributes: [
                .font: NSFont.systemFont(ofSize: bodySize),
                .paragraphStyle: paragraph,
            ]
        )
        return ceil(bounds.height)
    }

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

    @Binding var text: String
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
        if field.stringValue != text {
            field.stringValue = text
        }
        if field.placeholderString != placeholder {
            field.placeholderString = placeholder
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    final class Coordinator: NSObject, NSTextFieldDelegate {
        private let parent: QuickChatInputField
        init(_ parent: QuickChatInputField) { self.parent = parent }

        func controlTextDidChange(_ obj: Notification) {
            guard let field = obj.object as? NSTextField else { return }
            parent.text = field.stringValue
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
