import Foundation

public enum LifecycleError: Error, Equatable { case foreignConfiguration, verificationFailed, rollbackFailed, policyTooLarge, invalidConfiguration }

public struct DNSProxyConfiguration: Equatable, Sendable {
    public static let providerID = "io.clearpath.Clearpath.DNSProxy"
    // Preference payload limits are not a public size contract. Bound the first
    // implementation and validate larger production datasets in a separate gate.
    public static let maximumInlinePolicy = 512 * 1024
    public let providerID: String
    public let enabled: Bool
    public let policyData: Data
    public init(providerID: String = Self.providerID, enabled: Bool, policyData: Data) {
        self.providerID = providerID; self.enabled = enabled; self.policyData = policyData
    }
    public func validate() throws {
        guard providerID == Self.providerID else { throw LifecycleError.foreignConfiguration }
        guard policyData.count <= Self.maximumInlinePolicy else { throw LifecycleError.policyTooLarge }
        _ = try Policy(data: policyData)
    }
    public func disabled() -> Self { .init(providerID: providerID, enabled: false, policyData: policyData) }
}

public protocol ProxyPreferences {
    func load() async throws -> DNSProxyConfiguration?
    func save(_ config: DNSProxyConfiguration) async throws
    func remove() async throws
}
public enum ExtensionResult: Equatable { case completed, rebootRequired }
public protocol ExtensionRequests {
    func activate() async throws -> ExtensionResult
    func deactivate() async throws -> ExtensionResult
}

/// No routes, network services, Screen Time, other providers or browser preferences
/// are changed. Serialized by the control process; macOS preference staleness errors
/// are surfaced instead of retrying and overwriting a concurrently changed setting.
public struct Lifecycle {
    let preferences: any ProxyPreferences
    let extensions: any ExtensionRequests
    public init(preferences: any ProxyPreferences, extensions: any ExtensionRequests) {
        self.preferences = preferences; self.extensions = extensions
    }
    public func activate(policy: Policy) async throws -> ExtensionResult {
        let desired = DNSProxyConfiguration(enabled: true, policyData: policy.data)
        try desired.validate()
        let original = try await preferences.load()
        try owned(original)
        // Avoid a live policy-replacement gap or claiming that an OS preference save
        // hot-reloads already open flows. Deactivate before a different policy.
        if let original, original.enabled {
            guard original == desired else { throw LifecycleError.invalidConfiguration }
            return .completed
        }
        let result = try await extensions.activate()
        guard result == .completed else { return result }
        do {
            try await preferences.save(desired)
            guard try await preferences.load() == desired else { throw LifecycleError.verificationFailed }
            return .completed
        } catch {
            do {
                let current = try await preferences.load()
                if current != original {
                    // A different process may have changed preferences during macOS
                    // approval. Never erase/overwrite an unfamiliar configuration.
                    guard current == desired else { throw LifecycleError.rollbackFailed }
                    if let original { try await preferences.save(original) } else { try await preferences.remove() }
                    guard try await preferences.load() == original else { throw LifecycleError.rollbackFailed }
                }
            } catch { throw LifecycleError.rollbackFailed }
            throw error
        }
    }
    public func deactivate() async throws {
        guard let config = try await preferences.load() else { return }
        try owned(config)
        if config.enabled { try await preferences.save(config.disabled()) }
        guard let saved = try await preferences.load(), !saved.enabled, saved.providerID == config.providerID
        else { throw LifecycleError.verificationFailed }
    }
    public func uninstall() async throws -> ExtensionResult {
        try await deactivate()
        if let config = try await preferences.load() {
            try owned(config)
            try await preferences.remove()
            guard try await preferences.load() == nil else { throw LifecycleError.verificationFailed }
        }
        // Never deactivate the extension before removing the enabled DNS config.
        return try await extensions.deactivate()
    }
    private func owned(_ config: DNSProxyConfiguration?) throws {
        if let config, config.providerID != DNSProxyConfiguration.providerID { throw LifecycleError.foreignConfiguration }
    }
}
