import AppKit
import Foundation

/// Owns the QuickChatSkill panel: resolves the capture, runs the skill against the
/// sidecar, and delivers the result to the chosen destination.
///
/// Phase 1 (spec §11) captures from OakReader's own viewer, so there is no
/// Accessibility permission, no synthetic keystrokes and no global hotkey here.
/// Phase 2 replaces `capture()` with the AX pipeline of §3; nothing else in
/// this file changes.
final class QuickChatController: NSObject, QuickChatPanelDelegate {

    private lazy var panel: QuickChatPanel = {
        let p = QuickChatPanel()
        p.quickChatDelegate = self
        return p
    }()

    private weak var appDelegate: AppDelegate?
    private var streamTask: Task<Void, Never>?
    /// The document the panel was opened from, so a result can be filed back
    /// onto it even after the panel takes key focus.
    private weak var sourceViewModel: DocumentViewModel?
    /// A focused, editable text view is a writable source: the result can be
    /// written straight back over the selection. Resolved before the panel takes
    /// key focus, because presenting it changes the first responder.
    private weak var writeBackView: NSTextView?
    private var writeBackRange = NSRange(location: 0, length: 0)
    /// Write-back target in another application, when the capture came from one.
    private var externalTarget: QuickChatSelectedText.Target?

    private let trigger = QuickChatTrigger()
    private(set) lazy var statusItem = QuickChatStatusItem(controller: self)
    /// What the last global summon captured. Re-summoning on the same selection
    /// reopens the panel without billing a new request (spec §2).
    private var lastGlobalCapture: String?
    /// False when another app already holds the combination; the status menu
    /// says so rather than leaving a dead key.
    private(set) var isGlobalShortcutClaimed = true
    /// What that selection last produced, so re-summoning shows it again.
    private var lastGlobalResult: (skill: QuickChatSkill, text: String)?

    init(appDelegate: AppDelegate) {
        self.appDelegate = appDelegate
        super.init()
    }

    // MARK: - Present

    /// `skillId` nil opens the skill list; a bound key passes one, and that
    /// skill runs immediately — the bound key only preselects a row and
    /// auto-submits (spec §2).
    @MainActor
    func show(skillId: String? = nil) {
        guard let window = appDelegate?.appState.window else { return }

        if panel.isVisible {
            panel.dismiss()
            return
        }

        guard let capture = capture(), !capture.isEmpty else {
            // Say why nothing happened, rather than beeping into the void.
            presentNoSelectionHint(relativeTo: window)
            return
        }

        let prefs = Preferences.shared
        panel.model.loadSkills(targetLabel: prefs.translationTargetLang.nativeName)
        panel.present(relativeTo: window, capture: capture)

        if let skillId, let skill = panel.model.skill(id: skillId) {
            panel.model.run(skill)
        }
    }

    /// A brief, self-dismissing note anchored to the window, for the case the
    /// shortcut fires with nothing selected.
    private func presentNoSelectionHint(relativeTo window: NSWindow) {
        let label = NSTextField(labelWithString: "Select some text first")
        label.font = .systemFont(ofSize: 13, weight: .medium)
        label.textColor = .secondaryLabelColor
        label.sizeToFit()

        let padding = NSSize(width: 28, height: 16)
        let box = NSVisualEffectView(frame: NSRect(
            x: 0, y: 0,
            width: label.frame.width + padding.width * 2,
            height: label.frame.height + padding.height * 2
        ))
        box.material = .hudWindow
        box.state = .active
        box.wantsLayer = true
        box.layer?.cornerRadius = 12
        label.setFrameOrigin(NSPoint(x: padding.width, y: padding.height))
        box.addSubview(label)

        let hint = NSPanel(
            contentRect: box.frame,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered, defer: false
        )
        hint.isOpaque = false
        hint.backgroundColor = .clear
        hint.level = .floating
        hint.hasShadow = true
        hint.contentView = box

        let frame = window.frame
        hint.setFrameOrigin(NSPoint(
            x: frame.midX - box.frame.width / 2,
            y: frame.minY + frame.height * 0.18
        ))
        hint.orderFront(nil)

        DispatchQueue.main.asyncAfter(deadline: .now() + 1.4) {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.2
                hint.animator().alphaValue = 0
            } completionHandler: {
                hint.orderOut(nil)
            }
        }
    }

    /// True when there is a selection to act on — menu validation uses this so
    /// the key equivalent is a silent no-op rather than ringing the bell.
    var hasSelection: Bool {
        if let textView = NSApp.keyWindow?.firstResponder as? NSTextView,
           textView.selectedRange().length > 0 {
            return true
        }
        guard let text = appDelegate?.appState.activeTab?.viewModel.state.selectedText else {
            return false
        }
        return !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    // MARK: - Global entry

    /// Brings the Carbon hotkey and the menu bar item in line with settings.
    /// Safe to call repeatedly; it is the single place that reconciles them.
    func syncGlobalShortcut() {
        guard QuickChatBindings.isGlobalEnabled else {
            trigger.stop()
            statusItem.remove()
            return
        }
        statusItem.install()

        trigger.onFire = { [weak self] in
            MainActor.assumeIsolated { self?.showFromGlobalHotKey() }
        }
        let claimed = trigger.start(QuickChatBindings.trigger)
        isGlobalShortcutClaimed = claimed
        if !claimed {
            // Only a key combination can be refused, and Carbon refuses rather
            // than steals, so the holder keeps it and we say so.
            NotificationCenter.default.post(
                name: .quickChatTriggerRejected, object: QuickChatBindings.trigger.display
            )
        }
    }

    /// Summoned over whatever application is frontmost.
    @MainActor
    func showFromGlobalHotKey() {
        if panel.isVisible {
            panel.dismiss()
            return
        }
        // Carbon fires regardless of which app is in front, OakReader included.
        // The AX read skips our own process by design, so inside the reader the
        // same key uses the in-app capture — one key, every surface.
        let isSelf = NSWorkspace.shared.frontmostApplication?.processIdentifier
            == ProcessInfo.processInfo.processIdentifier
        if isSelf {
            show()
            return
        }
        guard QuickChatAccessibility.isTrusted else {
            QuickChatAccessibility.requestPermission()
            return
        }
        guard let capture = captureFromFrontmostApp() else {
            NSSound.beep()
            return
        }

        panel.model.loadSkills(targetLabel: Preferences.shared.translationTargetLang.nativeName)
        panel.presentStandalone(capture: capture)
    }

    /// Tier 1 + 2 context from another app: which app, what kind of element,
    /// and whether the result can be written back into it.
    private func captureFromFrontmostApp() -> QuickChatCapture? {
        writeBackView = nil
        externalTarget = nil
        sourceViewModel = nil

        guard let read = QuickChatSelectedText.read() else { return nil }
        externalTarget = read.target

        let text = Self.normalize(read.text)
        guard !text.isEmpty else { return nil }
        let detected = QuickChatCapture.detectLanguage(text)
        let myLanguage = Preferences.shared.translationTargetLang.bcp47

        return QuickChatCapture(
            text: text,
            isWritable: read.target?.isWritable ?? false,
            sourceKind: .external,
            documentTitle: read.appName,
            documentAuthor: nil,
            detectedLanguage: detected,
            isMyLanguage: detected.map { QuickChatCapture.isSameLanguage($0, myLanguage) } ?? false,
            externalAppName: read.appName,
            externalBundleID: read.appBundleID,
            externalRole: read.role
        )
    }

    // MARK: - Capture

    /// Tiers 1–3 of §4, all in-process: what kind of surface the text came
    /// from, the text itself, and which document it belongs to.
    private func capture() -> QuickChatCapture? {
        writeBackView = nil
        let tab = appDelegate?.appState.activeTab
        sourceViewModel = tab?.viewModel

        // A focused editable text view wins over the viewer's selection: it is
        // where the user is actually working, and it is writable. This covers
        // the chat composer and the note editor, both native NSTextViews.
        let raw: String
        let writable: Bool
        let kind: QuickChatSourceKind

        if let textView = NSApp.keyWindow?.firstResponder as? NSTextView,
           textView.selectedRange().length > 0,
           let selected = (textView.string as NSString?)?.substring(with: textView.selectedRange()),
           !selected.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            raw = selected
            writable = textView.isEditable
            kind = .composer
            if textView.isEditable {
                writeBackView = textView
                writeBackRange = textView.selectedRange()
            }
        } else if let viewerSelection = tab?.viewModel.state.selectedText {
            raw = viewerSelection
            // The viewer is read-only; Phase 2 resolves writability from the
            // focused AX element in other apps.
            writable = false
            kind = tab.map(Self.sourceKind) ?? .unknown
        } else {
            return nil
        }

        let text = Self.normalize(raw)
        let detected = QuickChatCapture.detectLanguage(text)
        let myLanguage = Preferences.shared.translationTargetLang.bcp47

        let item = tab?.viewModel.libraryItem
        return QuickChatCapture(
            text: text,
            isWritable: writable,
            sourceKind: kind,
            documentTitle: item?.title,
            documentAuthor: item?.author,
            detectedLanguage: detected,
            isMyLanguage: detected.map { QuickChatCapture.isSameLanguage($0, myLanguage) } ?? false
        )
    }

    private static func sourceKind(for tab: DocumentTab) -> QuickChatSourceKind {
        switch tab.content {
        case .pdf: return .pdf
        case .html, .web: return .web
        case .markdown: return .markdown
        case .media: return .media
        case .newTab: return .unknown
        }
    }

    /// PDF extraction carries hard line breaks and hyphenated splits mid-
    /// sentence. Same normalization the translation panel applies, so the same
    /// selection reads identically in both.
    private static func normalize(_ text: String) -> String {
        var t = text.replacingOccurrences(of: "-\n", with: "")
        t = t.replacingOccurrences(
            of: "(?<=\\p{Han})\\n(?=\\p{Han})", with: "", options: .regularExpression
        )
        t = t.replacingOccurrences(
            of: "(?<!\\n)\\n(?!\\n)", with: " ", options: .regularExpression
        )
        t = t.replacingOccurrences(of: "[ \\t]{2,}", with: " ", options: .regularExpression)
        return t.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - Run

    func quickChatPanel(_ panel: QuickChatPanel, run skill: QuickChatSkill) {
        streamTask?.cancel()

        let capture = panel.model.capture
        let prefs = Preferences.shared
        let catalog = AIProviderCatalog.shared
        let storedPid = prefs.translationAIProviderId
        let pid = catalog.resolvedProviderId(preferred: storedPid)
        let model = catalog.resolvedModelId(
            providerId: pid, stored: pid == storedPid ? prefs.translationAIModel : ""
        )

        Analytics.capture("quick_chat_skill_run")

        streamTask = Task { @MainActor in
            // The instructions are the skill's own SKILL.md, read from the core
            // on use — the bodies are long prose and only the chosen skill's is
            // ever needed, which is why they are not in the listing.
            let policy: String
            if let inline = skill.inlinePolicy {
                policy = inline
            } else {
                policy = await SkillCatalog.body(of: skill.id)
            }
            guard !Task.isCancelled else { return }

            let prompts = QuickChatPromptBuilder.build(
                skill: skill,
                policy: policy,
                capture: capture,
                targetLanguage: prefs.translationTargetLang.displayName
            )
            let request = CompletionRequest(
                providerId: pid, model: model, system: prompts.system, user: prompts.user
            )

            do {
                for try await delta in AIBackend.completions.stream(request) {
                    guard !Task.isCancelled else { return }
                    panel.model.streamDelta(delta)
                }
                if panel.model.phase == .streaming {
                    panel.model.phase = .done
                }
            } catch {
                if !(error is CancellationError) {
                    panel.model.phase = .failed(error.localizedDescription)
                }
            }
        }
    }

    /// Applies an instruction to the result already showing.
    ///
    /// The previous answer replaces itself rather than stacking up as another
    /// turn: you are always looking at the current best version, and the one
    /// action at the bottom still applies to it. That is the line between this
    /// and a chat — a stack of one, not a transcript.
    func quickChatPanel(_ panel: QuickChatPanel, refine instruction: String) {
        guard let previous = panel.model.ranSkill else { return }
        let earlier = panel.model.result
        panel.model.query = ""

        let refined = QuickChatPromptBuilder.refinement(
            of: previous, instruction: instruction, previousResult: earlier,
            isWritable: panel.model.capture.isWritable
        )
        Analytics.capture("quick_chat_refine")
        // Through the model, not straight to the delegate: `run` is what appends
        // the turns and then calls back here. Calling the delegate directly ran
        // the request and rendered nothing.
        panel.model.run(refined)
    }

    func quickChatPanelStopRequested(_ panel: QuickChatPanel) {
        streamTask?.cancel()
        streamTask = nil
        if panel.model.phase == .streaming {
            panel.model.phase = panel.model.result.isEmpty ? .choosing : .stopped
        }
    }

    // MARK: - Deliver

    func quickChatPanel(
        _ panel: QuickChatPanel, deliver destination: QuickChatDestination, text rawText: String
    ) {
        let text = rawText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }

        switch destination {
        case .replace:
            if let target = externalTarget {
                // Accessibility first: in a native text view it replaces the
                // selection exactly, with no pasteboard involved and no focus
                // moved. Web content reports the attribute settable and then
                // declines, which is why the paste path exists rather than an
                // error — a contenteditable in Chrome is the common case, not
                // the edge one.
                if QuickChatSelectedText.write(text, to: target) {
                    Analytics.capture("quick_chat_deliver_replace_ax")
                    panel.dismiss()
                    return
                }
                Analytics.capture("quick_chat_deliver_replace_paste")
                QuickChatSelectedText.paste(text, into: target.pid) { [weak panel] in
                    panel?.dismiss()
                }
                return
            }
            guard let textView = writeBackView,
                  textView.shouldChangeText(in: writeBackRange, replacementString: text) else {
                NSSound.beep()
                return
            }
            textView.textStorage?.replaceCharacters(in: writeBackRange, with: text)
            textView.didChangeText()
            // Leave the new text selected, so the edit is visible and undoable
            // as one step.
            textView.setSelectedRange(NSRange(location: writeBackRange.location, length: (text as NSString).length))
            Analytics.capture("quick_chat_deliver_replace")
            panel.dismiss()

        case .copy:
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
            panel.model.confirm("Copied")
            Analytics.capture("quick_chat_deliver_copy")

        }
    }

    // MARK: - Dismiss

    func quickChatPanelDidDismiss(_ panel: QuickChatPanel) {
        // A request keeps running while the panel is hidden in Cida; here the
        // panel is the only place a result can land, so dismissing cancels.
        streamTask?.cancel()
        streamTask = nil
    }
}
