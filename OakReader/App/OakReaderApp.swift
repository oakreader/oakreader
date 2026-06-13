import Foundation

// Shared types used across the app.
// Entry point is in main.swift.

enum DocumentAction: String {
    case toggleSidebar, toggleInspector
    case zoomIn, zoomOut, zoomToFit
    case displaySingle, displaySingleContinuous, displayTwoUp, displayTwoUpContinuous
    case find
    case accessibilityCheck
    case rotateRight, rotateLeft
    case exportImages
    case snapshot
    case navigateBack
    case previousPage, nextPage
    case firstPage, lastPage
    case toggleZenMode
    case togglePresentationMode

    // Selection-anchored "instruments" — one per Marshall lifecycle bucket.
    // The popup, the toolbar tool, and these keyboard handles all converge on
    // the SAME application code (Beaudouin-Lafon polymorphism): the popup
    // bypasses these and calls AnnotationViewModel directly because it already
    // has a PDFSelection in hand; the keyboard path fires these so the active
    // coordinator can resolve the current selection on the fly.
    case highlightSelection
    case underlineSelection
    case attachSelectionToChat
    case translateSelection
    case askAISelection
    case exitAnnotateMode
}

extension Notification.Name {
    static let documentAction = Notification.Name("OakReaderDocumentAction")
    static let searchIndexRebuildRequested = Notification.Name("OakReaderSearchIndexRebuildRequested")
    static let settingsNavigateToTab = Notification.Name("OakReaderSettingsNavigateToTab")

    // Per-coordinator selection-action signals (one tab fires; both coordinators
    // filter by `notification.object === viewModel`). Coordinators that own the
    // active view resolve the current selection and apply.
    static let selectionApplyHighlight  = Notification.Name("OakReaderSelectionApplyHighlight")
    static let selectionApplyUnderline  = Notification.Name("OakReaderSelectionApplyUnderline")
    static let selectionAttachToChat    = Notification.Name("OakReaderSelectionAttachToChat")
    static let selectionTranslate       = Notification.Name("OakReaderSelectionTranslate")
    static let selectionAskAI           = Notification.Name("OakReaderSelectionAskAI")
    static let selectionAddNote         = Notification.Name("OakReaderSelectionAddNote")

    /// Open the note/comment editor for an existing overlay markup.
    /// `object` is the DocumentViewModel; userInfo["id"] is the markup's DB id.
    static let openNoteEditor           = Notification.Name("OakReaderOpenNoteEditor")
}
