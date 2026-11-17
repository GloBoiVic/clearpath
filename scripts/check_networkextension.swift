// Compile-only API check. This file activates no provider or configuration.
// swiftc -typecheck -module-cache-path /tmp/clearpath-swift-cache scripts/check_networkextension.swift
import NetworkExtension

final class DNSCapabilityProbe: NEDNSProxyProvider {
    override func handleNewFlow(_ flow: NEAppProxyFlow) -> Bool { false }
}

final class FilterCapabilityProbe: NEFilterDataProvider {
    override func handleNewFlow(_ flow: NEFilterFlow) -> NEFilterNewFlowVerdict {
        if let socket = flow as? NEFilterSocketFlow {
            _ = socket.remoteHostname
        }
        return .allow()
    }
}
