import Foundation
import Network
import SystemConfiguration
import ClearpathCore
import ClearpathNetwork

/// The installed filter reads the resolver state for each forwarded question. Configd keeps
/// the negotiated DNS for each service even when Clearpath sets its configured DNS to loopback.
public final class NetworkDNS: DNSUpstream, @unchecked Sendable {
    private let readState: () -> [String: [String: Any]]?
    private let lock = NSLock()
    private let saved: [String: [String]]
    private let port: UInt16
    private let listenPort: UInt16
    private let timeout: TimeInterval

    public convenience init(record: RecoveryRecord, listenPort: UInt16, timeout: TimeInterval) throws {
        guard record.format == 1,
              let store = SCDynamicStoreCreate(nil, "Clearpath DNS" as CFString, nil, nil) else {
            throw DNSError.unsupported
        }
        self.init(record: record, listenPort: listenPort, timeout: timeout) {
            SCDynamicStoreCopyMultiple(store, [
                "State:/Network/Global/DNS", "State:/Network/Global/IPv4", "State:/Network/Global/IPv6",
            ] as CFArray, [
                "^State:/Network/Service/[^/]+/(DNS|IPv4|IPv6)$", "^Setup:/Network/Service/[^/]+/DNS$",
            ] as CFArray) as? [String: [String: Any]]
        }
    }

    init(record: RecoveryRecord, listenPort: UInt16, timeout: TimeInterval,
         readState: @escaping () -> [String: [String: Any]]?) {
        self.readState = readState
        self.saved = Dictionary(record.services.compactMap { service in
            service.id.map { ($0, service.servers) }
        }, uniquingKeysWith: { _, _ in [] })
        self.port = record.upstreamPort
        self.listenPort = listenPort
        self.timeout = timeout
    }

    public func exchange(_ packet: [UInt8], tcp: Bool) async throws -> [UInt8] {
        guard let name = try DNSMessage(packet).name.host, !name.isEmpty else { throw DNSError.unsupported }
        let destinations = destinations(for: name)
        guard !destinations.isEmpty else { throw DNSError.closed }
        for (endpoint, interface) in destinations {
            try Task.checkCancellation()
            let upstream = NetworkUpstream(endpoint: endpoint, interface: interface,
                                           timeout: timeout / Double(destinations.count))
            if let response = try? await upstream.exchange(packet, tcp: tcp) { return response }
        }
        throw DNSError.closed
    }

    private func destinations(for name: String) -> [(NWEndpoint, NWInterface?)] {
        lock.lock()
        defer { lock.unlock() }
        guard let state = readState(), let route = DNSRoutes(state: state, saved: saved, port: port).route(for: name),
              let port = NWEndpoint.Port(rawValue: route.port), route.port > 0 else { return [] }
        // An explicit scope has to stay on its interface even if a VPN changes the default route.
        let interface = route.interface.flatMap { IPv6Address("fe80::%\($0)")?.interface }
        if route.scoped && route.interface != nil && interface == nil { return [] }
        let requiredInterface = route.scoped ? interface : nil
        var seen = Set<NWEndpoint.Host>()
        return route.servers.compactMap { text -> (NWEndpoint, NWInterface?)? in
            guard let host = Self.resolverHost(text, interface: interface), seen.insert(host).inserted,
                  route.port != listenPort || !Self.isLoopback(host) else { return nil }
            return (.hostPort(host: host, port: port), requiredInterface)
        }
    }

    public static func resolverHost(_ text: String, interface: NWInterface? = nil) -> NWEndpoint.Host? {
        if let address = IPv4Address(text), address != .any, address != .broadcast, !address.isMulticast {
            return .ipv4(address)
        }
        guard let address = IPv6Address(text), !address.isAny, !address.isMulticast else { return nil }
        if address.isIPv4Mapped, let v4 = address.asIPv4 {
            guard v4 != .any, v4 != .broadcast, !v4.isMulticast else { return nil }
            return .ipv4(v4)
        }
        if let supplied = address.interface, let interface, supplied.index != interface.index { return nil }
        if address.isLinkLocal && address.interface == nil {
            guard let interface, let scoped = IPv6Address(address.rawValue, interface) else { return nil }
            return .ipv6(scoped)
        }
        return .ipv6(address)
    }

    public static func isLoopback(_ host: NWEndpoint.Host) -> Bool {
        switch host {
        case .ipv4(let address): return address.rawValue.first == 127
        case .ipv6(let address): return address.isLoopback || (address.isIPv4Mapped && address.asIPv4?.rawValue.first == 127)
        default: return false
        }
    }
}

struct DNSRoutes {
    struct Route: Equatable {
        let servers: [String]
        let interface: String?
        let port: UInt16
        var scoped = false
    }

    private let state: [String: [String: Any]]
    private let saved: [String: [String]]
    private let port: UInt16

    init(state: [String: [String: Any]], saved: [String: [String]], port: UInt16) {
        self.state = state
        self.saved = saved
        self.port = port
    }

    func route(for name: String) -> Route? {
        if Policy.matches(name, rules: ["local", "254.169.in-addr.arpa", "8.e.f.ip6.arpa", "9.e.f.ip6.arpa",
                                         "a.e.f.ip6.arpa", "b.e.f.ip6.arpa"]) { return nil }

        var matches: [(suffix: String, order: Int, route: Route)] = []
        let statePrefix = "State:/Network/Service/"
        let setupPrefix = "Setup:/Network/Service/"
        let serviceIDs = Set(state.keys.compactMap { key -> String? in
            guard key.hasPrefix(statePrefix) else { return nil }
            return key.dropFirst(statePrefix.count).split(separator: "/").first.map(String.init)
        })
        for id in serviceIDs {
            let key = statePrefix + id
            let active = state[key + "/DNS"] ?? [:]
            let setup = state[setupPrefix + id + "/DNS"] ?? [:]
            let interface = active["InterfaceName"] as? String ?? serviceInterface(key)
            let negotiated = active["ServerAddresses"] as? [String] ?? []
            let configured = setup["ServerAddresses"] as? [String] ?? []
            let original = saved[id].flatMap { $0.isEmpty ? nil : $0 } ?? negotiated
            // Saved servers describe the pre-Clearpath version of the setup record. State DNS
            // supplied by a VPN is still authoritative for any suffix it explicitly owns.
            let manual = saved[id] != nil && configured == [ServiceManager.listenAddress] ? original : configured
            var seen = Set<String>()
            for (configuration, servers) in [(active, negotiated), (setup, manual)] {
                guard let domains = configuration["SupplementalMatchDomains"] else { continue }
                guard let domains = domains as? [String] else { return nil }
                let orders = configuration["SupplementalMatchOrders"] as? [Int] ?? []
                let route = Route(servers: servers, interface: interface == "*" ? nil : interface,
                                  port: serverPort(configuration), scoped: true)
                for (index, domain) in domains.enumerated() {
                    guard let suffix = Self.suffix(domain) else { return nil }
                    if seen.insert(suffix).inserted && (suffix.isEmpty || name == suffix || name.hasSuffix("." + suffix)) {
                        let order = index < orders.count ? orders[index] : Int.max
                        matches.append((suffix, order, route))
                    }
                }
            }
        }
        if let best = matches.min(by: { lhs, rhs in
            if lhs.suffix.count != rhs.suffix.count { return lhs.suffix.count > rhs.suffix.count }
            return lhs.order < rhs.order
        }) {
            let equallyPreferred = matches.filter { $0.suffix == best.suffix && $0.order == best.order }
            // Ambiguous split DNS is safer to leave unresolved than to send to an unrelated resolver.
            guard equallyPreferred.allSatisfy({ $0.route == best.route }) else { return nil }
            return best.route
        }

        let global = state["State:/Network/Global/DNS"] ?? [:]
        let globalServers = global["ServerAddresses"] as? [String] ?? []
        if let first = globalServers.first, !NetworkDNS.isLoopback(NWEndpoint.Host(first)) {
            return Route(servers: globalServers, interface: nil, port: serverPort(global))
        }

        for family in ["IPv4", "IPv6"] {
            guard let primary = state["State:/Network/Global/" + family],
                  let id = primary["PrimaryService"] as? String else { continue }
            let key = statePrefix + id
            let config = state[key + "/DNS"] ?? [:]
            let servers = saved[id].flatMap { $0.isEmpty ? nil : $0 } ?? config["ServerAddresses"] as? [String] ?? []
            if !servers.isEmpty {
                return Route(servers: servers, interface: serviceInterface(key) ?? primary["PrimaryInterface"] as? String,
                             port: serverPort(config))
            }
        }
        return nil
    }

    private func serviceInterface(_ key: String) -> String? {
        state[key + "/IPv4"]?["InterfaceName"] as? String ?? state[key + "/IPv6"]?["InterfaceName"] as? String
    }

    private static func suffix(_ domain: String) -> String? {
        if domain.isEmpty || domain == "." { return "" }
        // Prefix a label so Policy's validation also accepts a single-label suffix like "corp".
        let prefix = "clearpath."
        return (try? Policy.domain(prefix + domain)).map { String($0.dropFirst(prefix.count)) }
    }

    private func serverPort(_ config: [String: Any]) -> UInt16 {
        guard let value = config["ServerPort"] as? Int else { return port }
        return UInt16(exactly: value) ?? 0
    }
}
