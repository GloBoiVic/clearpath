import Foundation

public protocol DNSUpstream: Sendable {
    /// Select an upstream once so transport retries stay on the same route.
    func forQuestion(named name: DNSName) -> any DNSUpstream
    func exchange(_ packet: [UInt8], tcp: Bool) async throws -> [UInt8]
}

public extension DNSUpstream {
    func forQuestion(named name: DNSName) -> any DNSUpstream { self }
}

/// Names only Clearpath answers (#76). The status check asks the Mac's default resolver for a
/// fresh one: if this TXT marker comes back, that resolver sends lookups through Clearpath.
public enum FilterCheck {
    public static let suffix = "clearpath-check.example"
    /// One TXT string, "clearpath".
    public static let marker: [UInt8] = [9] + Array("clearpath".utf8)
}

public struct Resolver: Sendable {
    public let policy: Policy
    private let onBlocked: @Sendable () -> Void
    public init(policy: Policy, onBlocked: @escaping @Sendable () -> Void = {}) {
        self.policy = policy
        self.onBlocked = onBlocked
    }

    public func resolve(_ packet: [UInt8], tcp: Bool, upstream: any DNSUpstream) async -> [UInt8] {
        guard let query = try? DNSMessage(packet) else { return DNSMessage.error(for: packet, code: 1) }
        do { try query.validateQuery() } catch { return query.response(code: 1) }
        guard query.klass == 1 else { return query.response(code: 5) }
        if let host = query.name.host, Policy.matches(host, rules: [FilterCheck.suffix]) {
            // Answered here, never forwarded or counted as a blocked lookup; TTL 0 so no cache keeps it.
            return query.type == 16 ? query.response(answers: [DNSRecord(name: query.name, type: 16, ttl: 0, data: FilterCheck.marker)])
                                    : query.response()
        }
        do {
            let response: [UInt8]
            switch query.name.host.map(policy.decide) ?? .allow {
            case .block:
                onBlocked()
                response = query.response(code: 3)
            case .safe(let target):
                guard [1,28,5].contains(query.type) else { return query.response() }
                var records = [DNSRecord(name: query.name, type: 5, cname: DNSName(target))]
                if query.type != 5 {
                    let safe = try DNSMessage(DNSMessage.query(target, type: query.type))
                    let result = try await fetch(safe, tcp: tcp, upstream: upstream)
                    guard result.rcode == 0 else { return query.response(code: 2) }
                    // Follow exactly one CNAME chain from the safe target. A fork, a loop, an
                    // unreadable alias, or a redirect to a blocked or protected search name could
                    // lead back to an ordinary endpoint, so each fails closed.
                    let aliases = result.answers.filter { $0.type == 5 && $0.klass == 1 }
                    var chain = [target]
                    while let last = chain.last {
                        let next = aliases.filter { $0.name.host == last }
                        if next.isEmpty { break }
                        guard next.count == 1, let alias = next[0].cname?.host, !chain.contains(alias), chain.count < 16,
                              policy.decide(alias) == .allow else { return query.response(code: 2) }
                        chain.append(alias)
                    }
                    let owners = Set(chain.dropLast()), final = chain.last!
                    records += result.answers.filter { rr in
                        guard rr.klass == 1, let owner = rr.name.host else { return false }
                        return rr.type == 5 ? owners.contains(owner) : rr.type == query.type && owner == final
                    }
                }
                response = query.response(answers: records)
            case .allow:
                let result = try await fetch(query, tcp: tcp, upstream: upstream)
                for rr in result.answers where rr.type == 5 {
                    if let name = rr.cname?.host {
                        switch policy.decide(name) {
                        case .block:
                            onBlocked()
                            return query.response(code: 3)
                        case .safe: return query.response(code: 2)
                        case .allow: break
                        }
                    }
                }
                response = result.wire  // lossless: don't re-encode opaque DNS/DNSSEC records
            }
            guard response.count <= 65535 else { return query.response(code: 2) }
            return !tcp && response.count > query.udpLimit ? query.response(truncated: true) : response
        } catch { return query.response(code: 2) }
    }

    private func fetch(_ query: DNSMessage, tcp: Bool, upstream: any DNSUpstream) async throws -> DNSMessage {
        var request = query.wire
        let id = UInt16.random(in: .min ... .max)
        request[0] = UInt8(id >> 8); request[1] = UInt8(id & 255)
        let sent = try DNSMessage(request)
        let route = upstream.forQuestion(named: sent.name)
        var response = try DNSMessage(await route.exchange(request, tcp: tcp))
        try response.validateResponse(to: sent)
        if response.truncated {
            guard !tcp else { throw DNSError.malformed }
            response = try DNSMessage(await route.exchange(request, tcp: true))
            try response.validateResponse(to: sent)
            guard !response.truncated else { throw DNSError.malformed }
        }
        var wire = response.wire
        wire[0] = UInt8(query.id >> 8); wire[1] = UInt8(query.id & 255)
        return try DNSMessage(wire)
    }
}
