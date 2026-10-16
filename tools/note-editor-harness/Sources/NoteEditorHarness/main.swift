import AppKit

/// Drives the real NoteEditorTextView offscreen, the way NativeNoteEditorView builds
/// it, and checks what the toolbar and typing actually produce.
/// The app's NSTextViewDelegate, as NativeNoteEditorView.Coordinator wires it.
final class Delegate: NSObject, NSTextViewDelegate {
    func textViewDidChangeSelection(_ notification: Notification) {
        (notification.object as? NoteEditorTextView)?.reportActiveFormats()
    }
}

@MainActor
final class Rig {
    let delegate = Delegate()
    let window: NSWindow
    let tv: NoteEditorTextView
    var formats: Set<String> = []

    init(_ markdown: String = "") {
        let storage = NSTextStorage()
        let layout = NoteTagLayoutManager()
        storage.addLayoutManager(layout)
        let container = NSTextContainer(size: NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude))
        container.widthTracksTextView = true
        container.lineFragmentPadding = 0
        layout.addTextContainer(container)
        tv = NoteEditorTextView(frame: NSRect(x: 0, y: 0, width: 360, height: 200), textContainer: container)
        tv.isRichText = true
        tv.isAutomaticQuoteSubstitutionEnabled = false
        tv.isAutomaticDashSubstitutionEnabled = false
        tv.isAutomaticTextReplacementEnabled = false
        tv.allowsUndo = true
        tv.textContainerInset = NSSize(width: 0, height: 5)
        tv.isVerticallyResizable = true
        tv.font = NoteEditorStyle.baseFont
        tv.typingAttributes = NoteEditorStyle.defaultTypingAttributes
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 300),
                          styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = tv
        window.makeFirstResponder(tv)
        tv.delegate = delegate
        tv.onActiveFormats = { [unowned self] in self.formats = $0 }
        tv.setMarkdown(markdown)
    }

    var md: String { NoteMarkdownCodec.markdown(from: tv.attributedString()) }

    func key(_ chars: String, code: UInt16 = 0, flags: NSEvent.ModifierFlags = []) {
        let e = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0,
                                 windowNumber: window.windowNumber, context: nil, characters: chars,
                                 charactersIgnoringModifiers: chars, isARepeat: false, keyCode: code)!
        tv.keyDown(with: e)
    }
    func type(_ s: String) { for c in s { key(String(c)) } }
    func ret() { key("\r", code: 36) }
    func backspace() { key("\u{7f}", code: 51) }
    func select(_ sub: String) {
        let r = (tv.string as NSString).range(of: sub)
        precondition(r.location != NSNotFound, "no \(sub) in \(tv.string)")
        tv.setSelectedRange(r)
    }
    func caretToEnd() { tv.setSelectedRange(NSRange(location: (tv.string as NSString).length, length: 0)) }
    func cmd(_ name: String) { tv.runCommand(name) }
}

var failures = 0
@MainActor func check(_ name: String, _ got: String, _ want: String) {
    if got == want { print("PASS  \(name)") } else {
        failures += 1
        print("FAIL  \(name)\n      want: \(want.debugDescription)\n      got:  \(got.debugDescription)")
    }
}
@MainActor func checkTrue(_ name: String, _ ok: Bool, _ detail: String = "") {
    if ok { print("PASS  \(name)") } else { failures += 1; print("FAIL  \(name)  \(detail)") }
}

@main struct Main {
    @MainActor static func main() {
        _ = NSApplication.shared

        do { let r = Rig("hello world"); r.select("world"); r.cmd("bold")
             check("S1 bold a selection", r.md, "hello **world**")
             r.select("world"); r.cmd("bold")
             check("S1b unbold it again", r.md, "hello world") }

        do { let r = Rig(""); r.cmd("bold"); r.type("abc")
             check("S2 bold at caret then type", r.md, "**abc**")
             r.cmd("bold"); r.type(" plain")
             check("S3 bold off at caret then type", r.md, "**abc** plain") }

        do { let r = Rig("one two"); r.select("two"); r.cmd("italic"); r.select("two"); r.cmd("bold")
             check("S4 italic + bold", r.md, "one ***two***")
             r.select("one"); r.cmd("strikethrough")
             check("S4b strikethrough", r.md, "~~one~~ ***two***") }

        do { let r = Rig("run ls now"); r.select("ls"); r.cmd("code")
             check("S5 inline code on selection", r.md, "run `ls` now")
             r.select("ls"); r.cmd("code")
             check("S5b inline code off", r.md, "run ls now") }

        do { let r = Rig("Title\n\nbody"); r.tv.setSelectedRange(NSRange(location: 2, length: 0)); r.cmd("heading")
             check("S6 heading on first line only", r.md, "## Title\n\nbody")
             checkTrue("S6b toolbar shows heading active", r.formats.contains("heading"), "\(r.formats)")
             r.tv.setSelectedRange(NSRange(location: 2, length: 0)); r.cmd("heading")
             check("S6c heading off", r.md, "Title\n\nbody") }

        do { let r = Rig("a\nb"); r.tv.selectAll(nil); r.cmd("bulletList")
             check("S7 bullet both lines", r.md, "- a\n- b")
             r.tv.selectAll(nil); r.cmd("bulletList")
             check("S7b bullet off (two paragraphs)", r.md, "a\n\nb") }

        do { let r = Rig(""); r.cmd("orderedList"); r.type("first"); r.ret(); r.type("second")
             check("S8 ordered list continues on Return", r.md, "1. first\n2. second")
             r.ret(); r.ret(); r.type("after")
             check("S8b Return on empty item exits list", r.md, "1. first\n2. second\n\nafter") }

        do { let r = Rig(""); r.cmd("quote"); r.type("hi")
             check("S9 quote on empty note then type", r.md, "> hi") }

        do { let r = Rig(""); r.cmd("codeBlock"); r.type("let x"); r.ret(); r.type("y")
             check("S10 code block, two lines", r.md, "```\nlet x\ny\n```") }

        do { let src = "**bold** and *it*\n\n- a\n- b"; let r = Rig(src)
             check("S11 load then save round trip", r.md, src) }

        do { let r = Rig("hello world"); r.select("world"); r.cmd("bold")
             r.tv.undoManager?.undo()
             check("S13 undo bold", r.md, "hello world")
             r.tv.undoManager?.redo()
             check("S13b redo bold", r.md, "hello **world**") }

        do { let r = Rig(""); r.cmd("bulletList"); r.type("item"); r.tv.setSelectedRange(NSRange(location: r.tv.selectedRange().location - 4, length: 0))
             r.backspace()
             check("S14 Backspace at item start leaves the list", r.md, "item") }

        do { let r = Rig("plain **strong** end"); r.select("tro"); r.tv.setSelectedRange(NSRange(location: r.tv.selectedRange().location, length: 0))
             r.tv.setSelectedRange(r.tv.selectedRange())
             checkTrue("S15 toolbar shows bold inside bold text", r.formats.contains("bold"), "\(r.formats)") }

        do { let r = Rig("one\ntwo\nthree"); r.select("two"); r.tv.setSelectedRange(NSRange(location: r.tv.selectedRange().location, length: 0)); r.cmd("heading")
             check("S16 heading on the middle line", r.md, "one\n\n## two\n\nthree") }

        do { let r = Rig("abc"); r.caretToEnd(); r.cmd("bold"); r.cmd("bold"); r.type("d")
             check("S17 bold on then off before typing", r.md, "abcd") }

        do { let r = Rig("x"); r.caretToEnd(); r.ret(); r.cmd("quote"); r.type("q"); r.ret(); r.ret(); r.ret(); r.type("z")
             check("S18 quote: a second blank line leaves it", r.md, "> xq\n\nz") }

        do { let r = Rig("> a"); r.caretToEnd(); r.ret(); r.ret(); r.type("b")
             check("S18b quote keeps one blank line", r.md, "> a\n>\n> b") }

        do { let r = Rig("## Head"); r.caretToEnd(); r.cmd("bulletList")
             check("S19 bullet on a heading line", r.md, "- Head") }

        do { let r = Rig("> a\n> b"); r.tv.selectAll(nil); r.cmd("quote")
             check("S20 quote off on two lines", r.md, "a\n\nb") }

        do { let r = Rig("```\ncode\n```"); r.caretToEnd(); r.cmd("codeBlock")
             check("S21 code block off", r.md, "code") }

        do { let r = Rig("text"); r.caretToEnd(); r.cmd("quote")
             r.tv.undoManager?.undo()
             check("S22 undo a block toggle", r.md, "text") }

        do { let r = Rig("aa **bb** cc"); r.select("aa bb"); r.cmd("bold")
             check("S23 bold a partly-bold selection makes it all bold", r.md, "**aa bb** cc") }

        do { let r = Rig("1. a\n2. b\n3. c"); r.select("b"); r.tv.setSelectedRange(NSRange(location: NSMaxRange(r.tv.selectedRange()), length: 0))
             r.backspace(); r.backspace(); r.backspace()
             check("S24 renumber after removing an item", r.md, "1. a\n2. c") }

        do { let r = Rig("abc"); r.tv.selectAll(nil); r.cmd("bold"); r.tv.setSelectedRange(NSRange(location: 1, length: 0))
             checkTrue("S25 caret in bold text shows bold", r.formats.contains("bold"), "\(r.formats)")
             r.cmd("heading")
             checkTrue("S25b heading active after toggle", r.formats.contains("heading"), "\(r.formats)") }

        do { let r = Rig("- a"); r.caretToEnd(); r.cmd("orderedList")
             check("S26 switch bullet to numbered", r.md, "1. a") }

        // The toolbar highlights a button when its name is in activeFormats.
        for (cmd, name, src) in [("bulletList", "bulletList", "- a"), ("orderedList", "orderedList", "1. a"),
                                 ("quote", "quote", "> a"), ("codeBlock", "codeBlock", "```\na\n```")] {
            let r = Rig(src); r.tv.setSelectedRange(NSRange(location: 0, length: 0)); r.caretToEnd()
            checkTrue("S27 \(cmd) button lights up inside it", r.formats.contains(name), "\(r.formats)")
        }
        for (src, name) in [("*it*", "italic"), ("~~st~~", "strikethrough"), ("`cd`", "code")] {
            let r = Rig("x \(src) y"); r.tv.setSelectedRange(NSRange(location: 4, length: 0))
            checkTrue("S28 \(name) button lights up inside it", r.formats.contains(name), "\(r.formats)")
        }

        do { let r = Rig("see docs"); r.select("docs"); r.tv.applyLink(url: "https://a.b")
             check("S29 link on a selection", r.md, "see [docs](https://a.b)") }

        do { let r = Rig("run "); r.caretToEnd(); r.cmd("code"); r.type("ls")
             check("S30 inline code at caret then type", r.md, "run `ls`") }

        do { let r = Rig("- a\n- b"); r.select("b"); r.tv.setSelectedRange(NSRange(location: NSMaxRange(r.tv.selectedRange()), length: 0)); r.ret(); r.type("c")
             check("S31 Return continues a bullet list", r.md, "- a\n- b\n- c") }

        do { let r = Rig("**bold**"); r.caretToEnd(); r.backspace(); r.backspace()
             check("S32 Backspace inside bold text", r.md, "**bo**") }

        // Paste from a web page, through a private pasteboard (the user's clipboard is untouched).
        do { let r = Rig("x "); r.caretToEnd()
             let pb = NSPasteboard(name: NSPasteboard.Name("oak-harness-\(UUID().uuidString)"))
             pb.clearContents()
             let html = #"<h1 style="color:red;font-size:30px;font-family:Georgia">Big</h1><p><b>bold</b> and <a href="https://a.b">link</a></p>"#
             pb.setString(html, forType: .html)
             pb.setString("Big\nbold and link", forType: .string)
             _ = r.tv.readSelection(from: pb)
             let ts = r.tv.textStorage!
             var fonts = Set<String>(), colors = Set<String>()
             ts.enumerateAttributes(in: NSRange(location: 0, length: ts.length)) { a, _, _ in
                 if let f = a[.font] as? NSFont { fonts.insert("\(f.familyName ?? "?") \(Int(f.pointSize))") }
                 if let c = a[.foregroundColor] as? NSColor { colors.insert(c.description.prefix(40).description) }
             }
             print("INFO  paste fonts: \(fonts.sorted())")
             print("INFO  paste colors: \(colors.count) distinct")
             print("INFO  paste markdown: \(r.md.debugDescription)")
             checkTrue("S33 pasted web text keeps the editor font", fonts.count == 1, "\(fonts)")
             check("S33b web paste keeps bold and link, drops the heading size", r.md, "x **Big**\n\n**bold** and [link](https://a.b/)")
             pb.releaseGlobally() }

        do { let r = Rig(""); 
             let pb = NSPasteboard(name: NSPasteboard.Name("oak-harness-\(UUID().uuidString)"))
             pb.clearContents(); pb.setString("- one\n- two\n\n**bold** text", forType: .string)
             _ = r.tv.readSelection(from: pb)
             print("INFO  markdown paste: \(r.md.debugDescription)")
             check("S34 pasted markdown becomes formatting", r.md, "- one\n- two\n\n**bold** text")
             pb.releaseGlobally() }

        do { let src = Rig("- a\n- **b** c"); src.tv.selectAll(nil)
             let pb = NSPasteboard(name: NSPasteboard.Name("oak-harness-\(UUID().uuidString)")); pb.clearContents()
             _ = src.tv.writeSelection(to: pb, types: src.tv.writablePasteboardTypes)
             let dst = Rig(""); _ = dst.tv.readSelection(from: pb)
             check("S35 copy between notes round-trips", dst.md, "- a\n- **b** c")
             pb.releaseGlobally() }

        do { let r = Rig("```\nx\n```"); r.caretToEnd()
             let pb = NSPasteboard(name: NSPasteboard.Name("oak-harness-\(UUID().uuidString)")); pb.clearContents()
             pb.setString("<b>y</b>", forType: .html); pb.setString("**y**", forType: .string)
             _ = r.tv.readSelection(from: pb)
             check("S36 paste into a code block is plain text", r.md, "```\nx**y**\n```")
             pb.releaseGlobally() }

        do { let r = Rig("")
             let pb = NSPasteboard(name: NSPasteboard.Name("oak-harness-\(UUID().uuidString)")); pb.clearContents()
             pb.setString("price is 2 * 3 and a_b_c", forType: .string)
             _ = r.tv.readSelection(from: pb)
             check("S37 plain prose is not converted", r.md, "price is 2 * 3 and a_b_c")
             pb.releaseGlobally() }

        do { let r = Rig("a "); r.caretToEnd(); r.type("*x*")
             check("S38 *x* becomes italic", r.md, "a *x*")
             r.tv.undoManager?.undo()
             check("S38b undo brings back the typed *x*", r.tv.string, "a *x*")
             checkTrue("S38c ... as plain text, not italic", !(r.tv.textStorage!.attribute(.font, at: 3, effectiveRange: nil) as! NSFont).fontDescriptor.symbolicTraits.contains(.italic)) }

        do { let r = Rig(""); r.cmd("codeBlock"); r.type("a"); r.ret(); r.ret(); r.type("b")
             check("S39 one empty line stays in the code block", r.md, "```\na\n\nb\n```")
             r.ret(); r.ret(); r.ret(); r.type("c")
             check("S39b a second empty line exits the code block", r.md, "```\na\n\nb\n```\n\nc") }

        do { let src = "```\na\n\nb\n```"; let r = Rig(src)
             check("S40 blank line inside a code block round-trips", r.md, src) }

        do { let src = "> a\n>\n> b"; let r = Rig(src)
             check("S18c a blank quote line round-trips", r.md, src) }

        do { let r = Rig("one two"); r.select("two")
             func shortcut(_ code: UInt16, _ flags: NSEvent.ModifierFlags) {
                 let e = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0,
                     windowNumber: r.window.windowNumber, context: nil, characters: "", charactersIgnoringModifiers: "",
                     isARepeat: false, keyCode: code)!
                 _ = r.tv.performKeyEquivalent(with: e) }
             shortcut(11, [.command]); check("S41 Cmd+B", r.md, "one **two**")
             r.select("one"); shortcut(7, [.command, .shift]); check("S41b Cmd+Shift+X", r.md, "~~one~~ **two**")
             r.caretToEnd(); shortcut(28, [.command, .shift]); check("S41c Cmd+Shift+8", r.md, "- ~~one~~ **two**") }

        print(failures == 0 ? "ALL PASS" : "\(failures) FAILED")
        exit(failures == 0 ? 0 : 1)
    }
}
