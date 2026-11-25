import ClearpathCore
import Foundation

enum RemovalRule: String, Codable {
    case custom, adult
}

enum RemovalOutcome: String, Codable {
    case pending, approved, denied, timedOut = "timed_out"
}

struct SiteRemoval: Codable {
    let id: UUID
    let domain: String
    let rule: RemovalRule
    var submitted = false
    var outcome = RemovalOutcome.pending
    var applied = false

    var finished: Bool { applied || outcome == .denied }
}

extension PairingClient {
    func outcome(for removal: SiteRemoval) async throws -> RemovalOutcome {
        struct Reply: Decodable {
            let id: UUID
            let domain: String
            let outcome: RemovalOutcome
        }

        let id = removal.id.uuidString.lowercased()
        let endpoint = origin.appendingPathComponent("requests").appendingPathComponent("site-removal")
        var request = authorizedRequest(to: removal.submitted ? endpoint.appendingPathComponent(id) : endpoint)
        if !removal.submitted {
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONEncoder().encode(["id": id, "domain": removal.domain])
        }
        let (data, response) = try await Self.session.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200, data.count <= 1024,
              let reply = try? JSONDecoder().decode(Reply.self, from: data),
              reply.id == removal.id, reply.domain == removal.domain else {
            throw ServiceError.failed("The pairing service did not confirm the request.")
        }
        return reply.outcome
    }
}

extension ServiceManager {
    func requestSiteRemoval(_ input: String, rule: RemovalRule) throws {
        guard system.isRoot else { throw ServiceError.refused("The installed policy writer must run as root.") }
        guard input.utf8.count <= 1024, let domain = try? Policy.domain(input) else {
            throw ServiceError.refused("Enter a domain such as example.com.")
        }
        try withServiceLock {
            let policy = try installedPolicy()
            var requests = try readSiteRemovals()
            if requests.contains(where: { !$0.finished && $0.rule == rule && $0.domain == domain }) { return }
            switch rule {
            case .custom:
                guard policy.custom.contains(domain) else {
                    throw ServiceError.refused("This custom block is no longer active.")
                }
            case .adult:
                guard policy.adult.contains(domain), !Policy.matches(domain, rules: policy.allow) else {
                    throw ServiceError.refused("This adult list block is no longer active.")
                }
                guard !policy.safeSearch.keys.contains(where: { Policy.matches($0, rules: [domain]) }) else {
                    throw ServiceError.refused("This exception would conflict with SafeSearch.")
                }
            }
            guard requests.filter({ !$0.finished }).count < 32 else {
                throw ServiceError.refused("The pending request list is full.")
            }
            let recent = Set(requests.filter(\.finished).suffix(50).map(\.id))
            requests.removeAll { $0.finished && !recent.contains($0.id) }
            requests.append(SiteRemoval(id: UUID(), domain: domain, rule: rule))
            try saveSiteRemovals(requests)
        }
    }

    func readSiteRemovals() throws -> [SiteRemoval] {
        guard try readRecord() != nil else {
            throw ServiceError.refused("The Clearpath filter service is not installed.")
        }
        guard FileManager.default.fileExists(atPath: paths.siteRemovals.path) else { return [] }
        let data = try readRegularFile(paths.siteRemovals, what: "removal requests")
        return try JSONDecoder().decode([SiteRemoval].self, from: data)
    }

    private func saveSiteRemovals(_ requests: [SiteRemoval]) throws {
        try writeFile(try JSONEncoder().encode(requests), to: paths.siteRemovals, mode: 0o600)
    }

    /// The add path calls this before reinstating a removed custom rule. If a
    /// crash left the old authorization awaiting acknowledgement, retire it
    /// before writing the new rule so a retry cannot remove the new block.
    func retireRemovedCustomRule(_ domain: String) throws {
        var requests = try readSiteRemovals()
        guard let index = requests.firstIndex(where: {
            !$0.finished && $0.rule == .custom && $0.domain == domain
        }) else { return }
        if requests[index].outcome == .pending {
            requests.remove(at: index)
        } else {
            requests[index].applied = true
        }
        try saveSiteRemovals(requests)
    }

    /// The client never supplies a verdict to the privileged service. Cache an
    /// authenticated terminal decision before touching DNS policy so it can be
    /// applied safely after an interruption, even while the service is offline.
    func reconcileSiteRemovals(client: PairingClient) async {
        guard system.isRoot, let pending = try? readSiteRemovals().filter({ !$0.finished }) else { return }
        for removal in pending {
            do {
                let outcome = removal.outcome == .pending ? try await client.outcome(for: removal) : removal.outcome
                try finishSiteRemoval(removal.id, outcome: outcome)
            } catch {
                // Keep pending work durable and avoid logging site or credential data.
                continue
            }
        }
    }

    func finishSiteRemoval(_ id: UUID, outcome: RemovalOutcome) throws {
        try withServiceLock {
            var requests = try readSiteRemovals()
            guard let index = requests.firstIndex(where: { $0.id == id && !$0.finished }) else { return }
            if requests[index].outcome == .pending && (!requests[index].submitted || outcome != .pending) {
                requests[index].submitted = true
                requests[index].outcome = outcome
                try saveSiteRemovals(requests)
            }
            let request = requests[index]
            guard request.outcome == .approved || request.outcome == .timedOut else { return }
            try applySiteRemoval(request)
            requests[index].applied = true
            try saveSiteRemovals(requests)
        }
    }

    private func applySiteRemoval(_ request: SiteRemoval) throws {
        let policy = try installedPolicy()
        switch request.rule {
        case .custom:
            guard policy.custom.contains(request.domain) else { return }
            try updateInstalledPolicy(policy) { document in
                guard let rules = document["custom"] as? [String] else { throw PolicyError.invalidSchema }
                document["custom"] = try rules.filter { try Policy.domain($0) != request.domain }
            }
        case .adult:
            guard !policy.allow.contains(request.domain) else { return }
            try updateInstalledPolicy(policy) { document in
                guard var rules = document["allow"] as? [String] else { throw PolicyError.invalidSchema }
                rules.append(request.domain)
                document["allow"] = rules
            }
        }
    }
}
