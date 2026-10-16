// swift-tools-version:5.9
import PackageDescription

// Drives the real note editor (app/Views/RightPanel/Comments/NoteEditor, linked in
// by symlink) offscreen and checks what typing, the toolbar, shortcuts and paste
// produce. Run: `swift run --package-path tools/note-editor-harness`.
let package = Package(
    name: "NoteEditorHarness",
    platforms: [.macOS(.v14)],
    dependencies: [.package(path: "../../packages/OakMarkdownUI")],
    targets: [.executableTarget(name: "NoteEditorHarness", dependencies: ["OakMarkdownUI"],
                                swiftSettings: [.unsafeFlags(["-parse-as-library"])])]
)
