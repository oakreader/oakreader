import Foundation
import PDFKit
import AppKit
import Security

/// SECURITY NOTICE: This service provides VISUAL signature annotations only.
/// It does NOT implement cryptographic PKCS#7/CMS digital signatures.
/// The "digital signature" is a visual indicator with certificate metadata —
/// it does NOT provide document integrity, authenticity, or non-repudiation.
///
/// For true digital signatures, a full PKCS#7 implementation using CMSEncoder
/// and embedded PDF signature dictionaries (/Type /Sig) per ISO 32000 is required.
struct DigitalSignatureService {

    // MARK: - List Signing Identities

    func listCertificates() throws -> [SecIdentity] {
        let query: [String: Any] = [
            kSecClass as String: kSecClassIdentity,
            kSecReturnRef as String: true,
            kSecMatchLimit as String: kSecMatchLimitAll,
            kSecAttrCanSign as String: true
        ]

        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)

        guard status == errSecSuccess else {
            if status == errSecItemNotFound {
                return []
            }
            throw OakReaderError.certificateNotFound
        }

        guard let identities = result as? [SecIdentity] else {
            return []
        }

        // Validate each identity's trust chain before presenting
        return identities.filter { identity in
            var certificate: SecCertificate?
            guard SecIdentityCopyCertificate(identity, &certificate) == errSecSuccess,
                  let cert = certificate else { return false }

            let policy = SecPolicyCreateBasicX509()
            var trust: SecTrust?
            guard SecTrustCreateWithCertificates(cert, policy, &trust) == errSecSuccess,
                  let trustRef = trust else { return false }

            var error: CFError?
            return SecTrustEvaluateWithError(trustRef, &error)
        }
    }

    // MARK: - Get Certificate Info

    func certificateInfo(for identity: SecIdentity) -> (name: String, email: String?)? {
        var certificate: SecCertificate?
        let status = SecIdentityCopyCertificate(identity, &certificate)
        guard status == errSecSuccess, let cert = certificate else { return nil }

        let commonName: String
        var cfName: CFString?
        let nameStatus = SecCertificateCopyCommonName(cert, &cfName)
        if nameStatus == errSecSuccess, let name = cfName as String? {
            commonName = name
        } else {
            commonName = "Unknown"
        }

        var email: String?
        var emailAddresses: CFArray?
        if SecCertificateCopyEmailAddresses(cert, &emailAddresses) == errSecSuccess,
           let emails = emailAddresses as? [String],
           let firstEmail = emails.first {
            email = firstEmail
        }

        return (name: commonName, email: email)
    }

    // MARK: - Visual Signature (NOT cryptographic)

    /// Adds a VISUAL signature annotation to the document.
    /// WARNING: This is NOT a cryptographic digital signature.
    /// It provides no integrity protection or non-repudiation.
    func addVisualSignature(
        document: PDFDocument,
        identity: SecIdentity
    ) throws {
        guard let info = certificateInfo(for: identity) else {
            throw OakReaderError.signatureFailed("Could not read certificate information.")
        }

        guard document.pageCount > 0, let firstPage = document.page(at: 0) else {
            throw OakReaderError.signatureFailed("Document has no pages.")
        }

        let pageRect = firstPage.bounds(for: .mediaBox)
        let sigWidth: CGFloat = 200
        let sigHeight: CGFloat = 60
        let sigX = pageRect.maxX - sigWidth - 36
        let sigY = pageRect.minY + 36
        let sigBounds = CGRect(x: sigX, y: sigY, width: sigWidth, height: sigHeight)

        let annotation = PDFAnnotation(bounds: sigBounds, forType: .freeText, withProperties: nil)

        let dateFormatter = DateFormatter()
        dateFormatter.dateStyle = .medium
        dateFormatter.timeStyle = .short
        let dateString = dateFormatter.string(from: Date())

        var signatureText = "Signed by \(info.name)"
        if let email = info.email {
            signatureText += "\n\(email)"
        }
        signatureText += "\nDate: \(dateString)"
        signatureText += "\n⚠️ Visual signature only — not cryptographically verified"

        annotation.contents = signatureText
        annotation.font = NSFont(name: "Helvetica", size: 8)
        annotation.fontColor = NSColor.darkGray
        annotation.color = NSColor(white: 0.95, alpha: 1.0)

        let border = PDFBorder()
        border.lineWidth = 1.0
        annotation.border = border

        firstPage.addAnnotation(annotation)

        var attributes = document.documentAttributes ?? [:]
        attributes[PDFDocumentAttribute.subjectAttribute] = "Visual signature by \(info.name) (not cryptographic)"
        document.documentAttributes = attributes
    }

    /// Adds a visual signature with custom appearance.
    /// WARNING: This is NOT a cryptographic digital signature.
    func addVisualSignature(
        document: PDFDocument,
        identity: SecIdentity,
        signatureModel: SignatureModel,
        on pageIndex: Int,
        at bounds: CGRect
    ) throws {
        guard let info = certificateInfo(for: identity) else {
            throw OakReaderError.signatureFailed("Could not read certificate information.")
        }
        guard let page = document.page(at: pageIndex) else {
            throw OakReaderError.pageOutOfRange(index: pageIndex, count: document.pageCount)
        }

        let annotation = PDFAnnotation(bounds: bounds, forType: .stamp, withProperties: nil)

        let dateFormatter = DateFormatter()
        dateFormatter.dateStyle = .medium
        dateFormatter.timeStyle = .short

        annotation.contents = "Signed by \(info.name) on \(dateFormatter.string(from: Date())) (visual only)"
        annotation.stampName = "SignatureStamp"

        page.addAnnotation(annotation)
    }
}
