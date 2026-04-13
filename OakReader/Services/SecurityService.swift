import Foundation
import PDFKit
import CoreGraphics

struct SecurityService {

    func applyEncryption(
        to document: PDFDocument,
        settings: SecuritySettings,
        outputURL: URL
    ) throws {
        guard settings.needsEncryption else {
            throw OakReaderError.encryptionFailed("No passwords specified.")
        }

        try PDFRewriter.rewriteDocument(
            document,
            to: outputURL,
            options: settings.contextOptions
        )
    }

    func removePassword(
        from document: PDFDocument,
        password: String,
        outputURL: URL
    ) throws {
        if document.isLocked {
            guard document.unlock(withPassword: password) else {
                throw OakReaderError.incorrectPassword
            }
        }

        // Rewrite without any encryption options
        try PDFRewriter.rewriteDocument(document, to: outputURL, options: [:])
    }

    func changePassword(
        document: PDFDocument,
        currentPassword: String?,
        newSettings: SecuritySettings,
        outputURL: URL
    ) throws {
        if document.isLocked {
            guard let currentPassword, document.unlock(withPassword: currentPassword) else {
                throw OakReaderError.incorrectPassword
            }
        }

        if newSettings.needsEncryption {
            try applyEncryption(to: document, settings: newSettings, outputURL: outputURL)
        } else {
            try PDFRewriter.rewriteDocument(document, to: outputURL, options: [:])
        }
    }

    func isEncrypted(_ document: PDFDocument) -> Bool {
        document.isEncrypted
    }

    func isLocked(_ document: PDFDocument) -> Bool {
        document.isLocked
    }

    func permissionFlags(for document: PDFDocument) -> PDFDocumentPermissions {
        document.permissionsStatus
    }
}
