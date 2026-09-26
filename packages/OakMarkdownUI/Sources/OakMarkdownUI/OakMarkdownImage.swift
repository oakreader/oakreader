import Foundation

/// Hook for resolving custom (non-`file://`) image URLs in rendered markdown to a
/// local file URL.
///
/// OakMarkdownUI is a standalone package and can't see app types, but the host app
/// stores note images under app-specific, relocatable URLs (e.g. `oak://image/...`).
/// The app sets `urlResolver` once at launch so the renderer can turn those URLs
/// into on-disk files without the package knowing anything about the scheme.
/// Returns `nil` for URLs it doesn't recognise, leaving the renderer's built-in
/// `file://`/absolute-path handling untouched.
public enum OakMarkdownImage {
    nonisolated(unsafe) public static var urlResolver: ((String) -> URL?)?
}
