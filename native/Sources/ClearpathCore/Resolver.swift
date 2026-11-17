import Foundation

public protocol DNSUpstream: Sendable {
    func exchange(_ packet: [UInt8], tcp: Bool) async throws -> [UInt8]
}

public struct Resolver: Sendable {
    public let policy: Policy
    public init(policy: Policy) { self.policy = policy }

    public func resolve(_ packet: [UInt8], tcp: Bool, upstream: any DNSUpstream) async -> [UInt8] {
        guard let query = try? DNSMessage(packet) else { return DNSMessage.error(for: packet, code: 1) }
        do { try query.validateQuery() } catch { return query.response(code: 1) }
        guard query.klass == 1 else { return query.response(code: 5) }
        do {
            let response: [UInt8]
            switch query.name.host.map(policy.decide) ?? .allow {
            case .block: response = query.response(code: 3)
            case .safe(let target):
                guard [1,28,5].contains(query.type) else { return query.response() }
                var records = [DNSRecord(name: query.name, type: 5, cname: DNSName(target))]
                if query.type != 5 {
                    let safe = try DNSMessage(DNSMessage.query(target, type: query.type))
                    let result = try await fetch(safe, tcp: tcp, upstream: upstream)
                    guard result.rcode == 0 else { return query.response(code: 2) }
                    var relevant: Set<String> = [target]
                    for _ in 0..<16 {
                        let before = relevant.count
                        for rr in result.answers where rr.type == 5 && rr.klass == 1 {
                            if let owner = rr.name.host, relevant.contains(owner), let alias = rr.cname?.host { relevant.insert(alias) }
                        }
                        if relevant.count == before { break }
                    }
                    records += result.answers.filter { rr in
                        rr.klass == 1 && (rr.type == query.type || rr.type == 5) && rr.name.host.map(relevant.contains) == true
                    }
                }
                response = query.response(answers: records)
            case .allow:
                let result = try await fetch(query, tcp: tcp, upstream: upstream)
                for rr in result.answers where rr.type == 5 {
                    if let name = rr.cname?.host {
                        switch policy.decide(name) {
                        case .block: return query.response(code: 3)
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
        var response = try DNSMessage(await upstream.exchange(request, tcp: tcp))
        try response.validateResponse(to: sent)
        if response.truncated {
            guard !tcp else { throw DNSError.malformed }
            response = try DNSMessage(await upstream.exchange(request, tcp: true))
            try response.validateResponse(to: sent)
            guard !response.truncated else { throw DNSError.malformed }
        }
        var wire = response.wire
        wire[0] = UInt8(query.id >> 8); wire[1] = UInt8(query.id & 255)
        return try DNSMessage(wire)
    }
}
