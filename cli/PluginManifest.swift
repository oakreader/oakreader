import Foundation

// MARK: - Plugin Manifest

/// Data model matching the `plugin.json` schema.
/// Used for bundled plugins (constructed in Swift) and future workspace plugins (decoded from JSON).
struct PluginManifest: Codable {
    let name: String
    let version: String
    let description: String
    let tools: [ToolDeclaration]
    let skills: [String]
    let credentials: [CredentialDeclaration]
    let commands: [String]

    // MARK: - Tool Declaration

    struct ToolDeclaration: Codable {
        let name: String
        let description: String
        let required: Bool
        let searchPaths: [String]
        let install: InstallMethod
        let versionArgs: [String]

        struct InstallMethod: Codable {
            let brew: String?
            let download: DownloadSource?

            struct DownloadSource: Codable {
                let url: String
                let toDir: String
            }

            static let none = InstallMethod(brew: nil, download: nil)
        }
    }

    // MARK: - Credential Declaration

    struct CredentialDeclaration: Codable {
        let providerId: String
        let displayName: String
        let envVar: String?
    }
}
