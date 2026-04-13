import Foundation
import CoreGraphics

struct SecuritySettings: Equatable {
    var openPassword: String?
    var permissionsPassword: String?
    var allowPrinting: Bool
    var allowCopying: Bool
    var allowEditing: Bool
    var allowAnnotations: Bool
    var encryptionKeyLength: EncryptionKeyLength
    var isEncrypted: Bool

    // RC4 intentionally excluded — cryptographically broken (RFC 7465)
    enum EncryptionKeyLength: Int, CaseIterable, Identifiable {
        case aes_128 = 128
        case aes_256 = 256

        var id: Int { rawValue }

        var label: String {
            switch self {
            case .aes_128: return "128-bit AES"
            case .aes_256: return "256-bit AES (Recommended)"
            }
        }

        var keyLength: Int { rawValue }
    }

    init() {
        self.openPassword = nil
        self.permissionsPassword = nil
        self.allowPrinting = true
        self.allowCopying = true
        self.allowEditing = true
        self.allowAnnotations = true
        self.encryptionKeyLength = .aes_256
        self.isEncrypted = false
    }

    var hasOpenPassword: Bool { openPassword != nil && !(openPassword?.isEmpty ?? true) }
    var hasPermissionsPassword: Bool { permissionsPassword != nil && !(permissionsPassword?.isEmpty ?? true) }
    var needsEncryption: Bool { hasOpenPassword || hasPermissionsPassword }

    var contextOptions: [String: Any] {
        var options: [String: Any] = [:]
        if let openPassword {
            options[String(kCGPDFContextUserPassword)] = openPassword
        }
        if let permissionsPassword {
            options[String(kCGPDFContextOwnerPassword)] = permissionsPassword
        }
        options[String(kCGPDFContextAllowsPrinting)] = allowPrinting
        options[String(kCGPDFContextAllowsCopying)] = allowCopying
        options[String(kCGPDFContextEncryptionKeyLength)] = encryptionKeyLength.keyLength
        return options
    }

    mutating func clearPasswords() {
        openPassword = nil
        permissionsPassword = nil
    }
}
