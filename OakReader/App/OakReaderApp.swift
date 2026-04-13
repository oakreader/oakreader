import Foundation

// Shared types used across the app.
// Entry point is in main.swift.

enum DocumentAction: String {
    case toggleSidebar, toggleInspector
    case zoomIn, zoomOut, zoomToFit
    case displaySingle, displaySingleContinuous, displayTwoUp, displayTwoUpContinuous
    case find
    case runOCR
    case accessibilityCheck
    case rotateRight, rotateLeft
    case exportImages
    case snapshot
    case navigateBack
    case previousPage, nextPage
    case firstPage, lastPage
}

extension Notification.Name {
    static let documentAction = Notification.Name("OakReaderDocumentAction")
}
