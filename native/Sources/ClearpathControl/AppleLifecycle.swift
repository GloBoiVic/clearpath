import Foundation
import NetworkExtension
import SystemExtensions
import ClearpathCore

final class ApplePreferences: ProxyPreferences {
    private let manager = NEDNSProxyManager.shared()
    func load() async throws -> DNSProxyConfiguration? {
        try await manager.loadFromPreferences()
        guard let proto = manager.providerProtocol else { return nil }
        guard let id = proto.providerBundleIdentifier else { throw LifecycleError.invalidConfiguration }
        return DNSProxyConfiguration(providerID: id, enabled: manager.isEnabled,
                                  policyData: proto.providerConfiguration?["policy"] as? Data ?? Data())
    }
    func save(_ config: DNSProxyConfiguration) async throws {
        // Disabling/removing a corrupt owned config must remain possible.
        guard config.providerID == DNSProxyConfiguration.providerID else { throw LifecycleError.foreignConfiguration }
        if config.enabled { try config.validate() }
        let proto = NEDNSProxyProviderProtocol()
        proto.providerBundleIdentifier = config.providerID
        proto.providerConfiguration = ["schema": 1, "policy": config.policyData,
                                       "policySHA256": (try? Policy(data: config.policyData).digest) ?? "invalid"]
        manager.providerProtocol = proto
        manager.localizedDescription = "Clearpath DNS filtering"
        manager.isEnabled = config.enabled
        try await manager.saveToPreferences()
    }
    func remove() async throws { try await manager.removeFromPreferences() }
}

// Request state and all delegate callbacks are confined to DispatchQueue.main.
final class AppleExtensions: NSObject, ExtensionRequests, OSSystemExtensionRequestDelegate, @unchecked Sendable {
    private var pending: CheckedContinuation<ExtensionResult, Error>?
    private var request: OSSystemExtensionRequest?
    func activate() async throws -> ExtensionResult { try await submit(activate: true) }
    func deactivate() async throws -> ExtensionResult { try await submit(activate: false) }
    private func submit(activate: Bool) async throws -> ExtensionResult {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.main.async {
                guard self.pending == nil else { continuation.resume(throwing: LifecycleError.invalidConfiguration); return }
                self.pending = continuation
                let request = activate
                    ? OSSystemExtensionRequest.activationRequest(forExtensionWithIdentifier: DNSProxyConfiguration.providerID, queue: .main)
                    : OSSystemExtensionRequest.deactivationRequest(forExtensionWithIdentifier: DNSProxyConfiguration.providerID, queue: .main)
                request.delegate = self
                self.request = request
                OSSystemExtensionManager.shared.submitRequest(request)
            }
        }
    }
    func requestNeedsUserApproval(_ request: OSSystemExtensionRequest) {
        print("macOS approval required in System Settings; this command is waiting.")
    }
    func request(_ request: OSSystemExtensionRequest, didFinishWithResult result: OSSystemExtensionRequest.Result) {
        let continuation = pending; pending = nil; self.request = nil
        continuation?.resume(returning: result == .completed ? .completed : .rebootRequired)
    }
    func request(_ request: OSSystemExtensionRequest, didFailWithError error: Error) {
        let continuation = pending; pending = nil; self.request = nil
        continuation?.resume(throwing: error)
    }
    func request(_ request: OSSystemExtensionRequest, actionForReplacingExtension existing: OSSystemExtensionProperties,
                 withExtension ext: OSSystemExtensionProperties) -> OSSystemExtensionRequest.ReplacementAction {
        ext.bundleVersion.compare(existing.bundleVersion, options: .numeric) == .orderedAscending ? .cancel : .replace
    }
}
