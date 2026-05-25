import Foundation

public final class ProviderRegistry: @unchecked Sendable {
    public static let shared = ProviderRegistry()

    private let lock = NSLock()
    private var providers: [String: ProviderInfo] = [:]

    private init() {
        BuiltInProviders.registerAll(in: self)
    }

    // MARK: - Registration

    public func register(_ provider: ProviderInfo) {
        lock.lock()
        defer { lock.unlock() }
        providers[provider.id] = provider
    }

    // MARK: - Lookup

    public func provider(for id: String) -> ProviderInfo? {
        lock.lock()
        defer { lock.unlock() }
        return providers[id]
    }

    public var allProviders: [ProviderInfo] {
        lock.lock()
        defer { lock.unlock() }
        return providers.values.sorted {
            if $0.displayOrder != $1.displayOrder {
                return $0.displayOrder < $1.displayOrder
            }
            return $0.displayName < $1.displayName
        }
    }

    /// Look up model info by model ID across all providers.
    public func model(for modelId: String) -> ModelInfo? {
        lock.lock()
        defer { lock.unlock() }
        for provider in providers.values {
            if let model = provider.models.first(where: { $0.id == modelId }) {
                return model
            }
        }
        return nil
    }
}
