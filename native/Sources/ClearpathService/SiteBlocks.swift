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
            // Keep the spelling and order of the existing rules. Validate the complete
            // candidate before atomically replacing the policy from the same directory.
            guard var document = try JSONSerialization.jsonObject(with: policy.data) as? [String: Any],
                  var custom = document["custom"] as? [String] else { throw PolicyError.invalidSchema }
            custom.append(domain)
            document["custom"] = custom
            let data = try JSONSerialization.data(withJSONObject: document, options: [.prettyPrinted, .sortedKeys])
            _ = try Policy(data: data)
            try writeFile(data, to: paths.policy, mode: 0o644)
        }
        return domain
    }

    private func installedPolicy() throws -> Policy {
        guard try readRecord() != nil else { throw ServiceError.refused("The Clearpath filter service is not installed.") }
        do {
            return try Policy(file: paths.policy)
        } catch {
            throw ServiceError.refused("The installed policy could not be read or is invalid.")
        }
    }
}

@objc protocol SiteBlockRequest {
    func add(_ domain: String, reply: @escaping (String?, String?) -> Void)
}

/// The system Mach service grants the current console user one operation on the
/// installed policy. The caller supplies a domain, never a path or a policy document.
public final class SiteBlockControl: NSObject, NSXPCListenerDelegate {
    private let manager: ServiceManager
    private let consoleUser: () -> uid_t?

    init(manager: ServiceManager, consoleUser: @escaping () -> uid_t?) {
        self.manager = manager
        self.consoleUser = consoleUser
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
        withExtendedLifetime((delegate, listener)) { dispatchMain() }
    }

    public func listener(_ listener: NSXPCListener, shouldAcceptNewConnection connection: NSXPCConnection) -> Bool {
        let uid = connection.effectiveUserIdentifier
        guard consoleUser() == uid else { return false }
        connection.exportedInterface = NSXPCInterface(with: SiteBlockRequest.self)
        connection.exportedObject = Writer(manager: manager) { [consoleUser] in consoleUser() == uid }
        connection.resume()
        return true
    }

    private final class Writer: NSObject, SiteBlockRequest {
        let manager: ServiceManager
        let authorized: () -> Bool

        init(manager: ServiceManager, authorized: @escaping () -> Bool) {
            self.manager = manager
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
    }

    public static func add(_ domain: String) throws -> String {
        let connection = NSXPCConnection(machServiceName: ServicePaths.siteBlockLabel, options: .privileged)
        return try add(domain, over: connection)
    }

    static func add(_ domain: String, over connection: NSXPCConnection) throws -> String {
        guard domain.utf8.count <= 1024 else { throw ServiceError.refused("Enter a domain such as example.com.") }
        connection.remoteObjectInterface = NSXPCInterface(with: SiteBlockRequest.self)
        connection.resume()
        defer { connection.invalidate() }
        let finished = DispatchSemaphore(value: 0)
        var result: Result<String, ServiceError> = .failure(.failed("Clearpath did not confirm the change. Try again."))
        let proxy = connection.remoteObjectProxyWithErrorHandler { _ in
            result = .failure(.failed("The installed site-block service is unavailable. Check Set up protection."))
            finished.signal()
        } as! SiteBlockRequest
        proxy.add(domain) { saved, message in
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
