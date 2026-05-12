import Foundation

// MARK: - Marketplace Manifest

/// Data model for the plugin marketplace registry (`marketplace.json`).
/// Defines the schema for future `oak plugins install <name>` from a registry.
struct MarketplaceManifest: Codable {
    let name: String
    let displayName: String
    let plugins: [MarketplaceEntry]

    struct MarketplaceEntry: Codable {
        let name: String
        let source: Source
        let policy: Policy
        let category: String?

        struct Source: Codable {
            /// Source type: "local", "git", or "url".
            let type: String
            /// Local filesystem path (when type == "local").
            let path: String?
            /// Remote URL (when type == "git" or "url").
            let url: String?
        }

        struct Policy: Codable {
            /// Installation policy: "NOT_AVAILABLE", "AVAILABLE", or "INSTALLED_BY_DEFAULT".
            let installation: String
        }
    }
}
