import ClearpathCore
import Foundation
import SystemConfiguration

public struct SiteBlocks: Encodable {
    public let custom: [String]
    public let adult: [String]
    public let allow: [String]
}

extension ServiceManager {
    public func siteBlocks() throws -> SiteBlocks {
        let policy = try installedPolicy()
        return SiteBlocks(custom: policy.custom.sorted(), adult: policy.adult.sorted(), allow: policy.allow.sorted())
    }

    func addSiteBlock(_ input: String) throws -> String {
        guard system.isRoot else { throw ServiceError.refused("The installed policy writer must run as root.") }
        guard input.utf8.count <= 1024, let domain = try? Policy.domain(input) else {
            throw ServiceError.refused("Enter a domain such as example.com.")
        }
        try withServiceLock {
            let policy = try installedPolicy()
            guard !policy.custom.contains(domain) else { return }
            try retireRemovedCustomRule(domain)
            // Keep the spelling and order of the existing rules. Validate the complete
            // candidate before atomically replacing the policy from the same directory.
            do {
                try updateInstalledPolicy(policy) { document in
                    guard var custom = document["custom"] as? [String] else { throw PolicyError.invalidSchema }
                    custom.append(domain)
                    document["custom"] = custom
                }
            } catch PolicyError.tooLarge {
                throw ServiceError.refused("The installed policy is too large to add another site.")
            }
        }
        return domain
    }

    func installedPolicy() throws -> Policy {
        guard try readRecord() != nil else { throw ServiceError.refused("The Clearpath filter service is not installed.") }
        do {
            return try Policy(file: paths.policy)
        } catch {
            throw ServiceError.refused("The installed policy could not be read or is invalid.")
        }
    }

    /// Call with the service lock held. Every writer validates the entire staged policy.
    func updateInstalledPolicy(_ policy: Policy, editing: (inout [String: Any]) throws -> Void) throws {
        guard var document = try JSONSerialization.jsonObject(with: policy.data) as? [String: Any] else {
            throw PolicyError.invalidSchema
        }
        try editing(&document)
        let data = try JSONSerialization.data(withJSONObject: document, options: [.sortedKeys])
        _ = try Policy(data: data)
        try writeFile(data, to: paths.policy, mode: 0o644)
    }
}

@objc protocol SiteBlockRequest {
    func add(_ domain: String, reply: @escaping (String?, String?) -> Void)
    func requestRemoval(_ domain: String, rule: String, reply: @escaping (String?, String?) -> Void)
    func listRemovals(reply: @escaping (String?, String?) -> Void)
}

/// The current console user can add blocks and ask for removals. Only an
/// independently verified decision can relax installed policy.
public final class SiteBlockControl: NSObject, NSXPCListenerDelegate {
    private let manager: ServiceManager
    private let consoleUser: () -> uid_t?
    private let now: () -> Date

    init(manager: ServiceManager, consoleUser: @escaping () -> uid_t?, now: @escaping () -> Date = Date.init) {
        self.manager = manager
        self.consoleUser = consoleUser
        self.now = now
    }

    public static func serve(manager: ServiceManager) throws {
        guard manager.system.isRoot else { throw ServiceError.refused("The installed policy writer must run as root.") }
        let delegate = SiteBlockControl(manager: manager) {
            var uid: uid_t = 0
            guard SCDynamicStoreCopyConsoleUser(nil, &uid, nil) != nil, uid != 0 else { return nil }
            return uid
        }
        let listener = NSXPCListener(machServiceName: ServicePaths.siteBlockLabel)
        listener.delegate = delegate
        listener.resume()
        Task { await PairingClient.sendCheckIns(client: manager.pairingClient) }
        Task {
            while !Task.isCancelled {
                await manager.reconcileSiteRemovals(now: Date())
                try? await Task.sleep(nanoseconds: 5_000_000_000)
            }
        }
        withExtendedLifetime((delegate, listener)) { dispatchMain() }
    }

    public func listener(_ listener: NSXPCListener, shouldAcceptNewConnection connection: NSXPCConnection) -> Bool {
        let uid = connection.effectiveUserIdentifier
        guard consoleUser() == uid else { return false }
        connection.exportedInterface = NSXPCInterface(with: SiteBlockRequest.self)
        connection.exportedObject = Writer(manager: manager, now: now) { [consoleUser] in consoleUser() == uid }
        connection.resume()
        return true
    }

    private final class Writer: NSObject, SiteBlockRequest {
        let manager: ServiceManager
        let now: () -> Date
        let authorized: () -> Bool

        init(manager: ServiceManager, now: @escaping () -> Date, authorized: @escaping () -> Bool) {
            self.manager = manager
            self.now = now
            self.authorized = authorized
        }

        func add(_ domain: String, reply: @escaping (String?, String?) -> Void) {
            guard authorized() else { reply(nil, "Sign in to this Mac to add a site block."); return }
            do {
                reply(try manager.addSiteBlock(domain), nil)
            } catch ServiceError.refused(let message) {
                reply(nil, message)
            } catch {
                reply(nil, "Clearpath could not save the site block.")
            }
        }

        func requestRemoval(_ domain: String, rule: String, reply: @escaping (String?, String?) -> Void) {
            guard authorized(), let rule = RemovalRule(rawValue: rule) else {
                reply(nil, "Clearpath could not accept the site removal request.")
                return
            }
            do {
                let deadline: Date?
                switch try manager.removalAuthority() {
                case .partner: deadline = nil
                case .solo: deadline = now().addingTimeInterval(ServiceManager.soloRemovalDelay)
                }
                try manager.requestSiteRemoval(domain, rule: rule, deadline: deadline)
                reply("", nil)
            } catch ServiceError.refused(let message) {
                reply(nil, message)
            } catch {
                reply(nil, "Clearpath could not save the site removal request.")
            }
        }

        func listRemovals(reply: @escaping (String?, String?) -> Void) {
            guard authorized() else { reply(nil, "Sign in to this Mac to see requests."); return }
            do {
                _ = try manager.removalAuthority()
                let data = try ServiceManager.removalEncoder.encode(manager.readSiteRemovals())
                reply(String(decoding: data, as: UTF8.self), nil)
            } catch ServiceError.refused(let message) {
                reply(nil, message)
            } catch {
                reply(nil, "Clearpath could not load site removal requests.")
            }
        }
    }

    public static func add(_ domain: String) throws -> String {
        let connection = NSXPCConnection(machServiceName: ServicePaths.siteBlockLabel, options: .privileged)
        return try add(domain, over: connection)
    }

    static func add(_ domain: String, over connection: NSXPCConnection) throws -> String {
        guard domain.utf8.count <= 1024 else { throw ServiceError.refused("Enter a domain such as example.com.") }
        return try call(over: connection) { $0.add(domain, reply: $1) }
    }

    public static func requestRemoval(_ domain: String, rule: String) throws {
        guard domain.utf8.count <= 1024, RemovalRule(rawValue: rule) != nil else {
            throw ServiceError.refused("Select a site block to remove.")
        }
        try requestRemoval(domain, rule: rule, over: NSXPCConnection(machServiceName: ServicePaths.siteBlockLabel, options: .privileged))
    }

    static func requestRemoval(_ domain: String, rule: String, over connection: NSXPCConnection) throws {
        _ = try call(over: connection) { $0.requestRemoval(domain, rule: rule, reply: $1) }
    }

    public static func listRemovals() throws -> String {
        try listRemovals(over: NSXPCConnection(machServiceName: ServicePaths.siteBlockLabel, options: .privileged))
    }

    static func listRemovals(over connection: NSXPCConnection) throws -> String {
        try call(over: connection) { $0.listRemovals(reply: $1) }
    }

    private static func call(over connection: NSXPCConnection,
                             _ invoke: (SiteBlockRequest, @escaping (String?, String?) -> Void) -> Void) throws -> String {
        connection.remoteObjectInterface = NSXPCInterface(with: SiteBlockRequest.self)
        connection.resume()
        defer { connection.invalidate() }
        let finished = DispatchSemaphore(value: 0)
        var result: Result<String, ServiceError> = .failure(.failed("Clearpath did not confirm the change. Try again."))
        let proxy = connection.remoteObjectProxyWithErrorHandler { _ in
            result = .failure(.failed("The installed site-block service is unavailable. Check Set up protection."))
            finished.signal()
        } as! SiteBlockRequest
        invoke(proxy) { saved, message in
            if let saved {
                result = .success(saved)
            } else {
                result = .failure(.refused(message ?? "Clearpath could not save the site block."))
            }
            finished.signal()
        }
        guard finished.wait(timeout: .now() + 5) == .success else {
            throw ServiceError.failed("Clearpath did not confirm the change. Try again.")
        }
        return try result.get()
    }
}
