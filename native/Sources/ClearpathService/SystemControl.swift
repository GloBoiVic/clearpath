import Foundation
import SystemConfiguration
import ClearpathCore

/// The macOS tools the service manager drives, by absolute path so `PATH` cannot swap them.
public enum Tool: String, Sendable {
    case networksetup = "/usr/sbin/networksetup"
    case launchctl = "/bin/launchctl"
    case scutil = "/usr/sbin/scutil"
    case profiles = "/usr/bin/profiles"
    case codesign = "/usr/bin/codesign"
}

public struct CommandResult: Sendable {
    public let status: Int32
    public let output: String
    public init(status: Int32, output: String) { self.status = status; self.output = output }
}

public struct NetworkLocation: Sendable {
    public let id: String?
    public let serviceIDs: [String: String]
    public init(id: String?, serviceIDs: [String: String]) { self.id = id; self.serviceIDs = serviceIDs }
}

/// Everything that touches the running system. Tests substitute a fake; `MacSystem` is real.
public protocol SystemControl {
    var isRoot: Bool { get }
    var consoleUserID: uid_t? { get }
    func run(_ tool: Tool, _ arguments: [String]) throws -> CommandResult
    func networkLocation() throws -> NetworkLocation
    /// True when nothing holds the loopback UDP or TCP port.
    func portIsFree(_ port: UInt16) -> Bool
    /// True when a DNS server on loopback answers a header-only probe with FORMERR. The probe
    /// carries no name, so the filter answers it locally and nothing goes upstream.
    func filterAnswers(port: UInt16) -> Bool
    /// True when the DNS server on loopback resolves a real lookup within two seconds. The
    /// question is the `com` name servers, which every working resolver answers.
    func filterResolves(port: UInt16) -> Bool
    /// True when the network's own resolver, the one the filter forwards ordinary names to,
    /// answers the same lookup directly within two seconds.
    func networkResolves(_ record: RecoveryRecord) -> Bool
    func pause(seconds: Double)
}

public struct MacSystem: SystemControl {
    public init() {}

    public var isRoot: Bool { geteuid() == 0 }

    public var consoleUserID: uid_t? {
        var uid: uid_t = 0
        guard let name = SCDynamicStoreCopyConsoleUser(nil, &uid, nil) as String?,
              name != "loginwindow", uid != 0 else { return nil }
        return uid
    }

    public func networkLocation() throws -> NetworkLocation {
        guard let preferences = SCPreferencesCreate(nil, "Clearpath" as CFString, nil),
              let location = SCNetworkSetCopyCurrent(preferences),
              let locationID = SCNetworkSetGetSetID(location) as String?,
              let services = SCNetworkSetCopyServices(location) as? [SCNetworkService] else {
            throw ServiceError.failed("Could not read macOS network service identifiers.")
        }
        var identifiers: [String: String] = [:]
        for service in services {
            guard let name = SCNetworkServiceGetName(service) as String?,
                  let id = SCNetworkServiceGetServiceID(service) as String?,
                  identifiers.updateValue(id, forKey: name) == nil else {
                throw ServiceError.failed("Could not identify each macOS network service uniquely.")
            }
        }
        return NetworkLocation(id: locationID, serviceIDs: identifiers)
    }

    public func run(_ tool: Tool, _ arguments: [String]) throws -> CommandResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: tool.rawValue)
        process.arguments = arguments
        process.environment = ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "LANG": "C", "LC_ALL": "C"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        process.standardInput = FileHandle.nullDevice
        try process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return CommandResult(status: process.terminationStatus, output: String(decoding: data, as: UTF8.self))
    }

    public func portIsFree(_ port: UInt16) -> Bool {
        canBind(SOCK_DGRAM, port: port) && canBind(SOCK_STREAM, port: port)
    }

    public func filterAnswers(port: UInt16) -> Bool {
        let fd = socket(AF_INET, SOCK_DGRAM, 0)
        guard fd >= 0 else { return false }
        defer { close(fd) }
        var timeout = timeval(tv_sec: 0, tv_usec: 500_000)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        var address = loopback(port: port)
        let connected = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        guard connected == 0 else { return false }
        let id = UInt16.random(in: 0...UInt16.max)
        let probe: [UInt8] = [UInt8(id >> 8), UInt8(id & 0xFF), 0x01, 0x00] + Array(repeating: 0, count: 8)
        guard send(fd, probe, probe.count, 0) == probe.count else { return false }
        var reply = [UInt8](repeating: 0, count: 512)
        let count = recv(fd, &reply, reply.count, 0)
        // Same ID, a response (QR set) and FORMERR (rcode 1): a DNS server, not just an open port.
        return count >= 12 && reply[0] == probe[0] && reply[1] == probe[1] && reply[2] & 0x80 != 0 && reply[3] & 0x0F == 1
    }

    public func filterResolves(port: UInt16) -> Bool {
        let fd = socket(AF_INET, SOCK_DGRAM, 0)
        guard fd >= 0 else { return false }
        defer { close(fd) }
        var timeout = timeval(tv_sec: 2, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        var address = loopback(port: port)
        let connected = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        guard connected == 0, let query = try? DNSMessage(DNSMessage.query("com", type: 2)),
              send(fd, query.wire, query.wire.count, 0) == query.wire.count else { return false }
        var reply = [UInt8](repeating: 0, count: 1232)
        let count = recv(fd, &reply, reply.count, 0)
        guard count > 0, let response = try? DNSMessage(Array(reply.prefix(count))),
              (try? response.validateResponse(to: query)) != nil else { return false }
        return response.rcode == 0
    }

    public func networkResolves(_ record: RecoveryRecord) -> Bool {
        guard let network = try? NetworkDNS(record: record, listenPort: ServiceManager.listenPort, timeout: 2) else { return false }
        return Self.resolves(through: network)
    }

    /// The `com` name servers answered with NOERROR within three seconds.
    static func resolves(through upstream: any DNSUpstream) -> Bool {
        guard let query = try? DNSMessage(DNSMessage.query("com", type: 2)) else { return false }
        let answered = Answered()
        let done = DispatchSemaphore(value: 0)
        Task {
            if let wire = try? await upstream.exchange(query.wire, tcp: false), let response = try? DNSMessage(wire),
               (try? response.validateResponse(to: query)) != nil, response.rcode == 0 { answered.set() }
            done.signal()
        }
        return done.wait(timeout: .now() + 3) == .success && answered.value
    }

    public func pause(seconds: Double) { Thread.sleep(forTimeInterval: seconds) }

    private func canBind(_ type: Int32, port: UInt16) -> Bool {
        let fd = socket(AF_INET, type, 0)
        guard fd >= 0 else { return false }
        defer { close(fd) }
        var address = loopback(port: port)
        return withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        } == 0
    }

    private func loopback(port: UInt16) -> sockaddr_in {
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = port.bigEndian
        address.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1"))
        return address
    }
}

private final class Answered: @unchecked Sendable {
    private let lock = NSLock()
    private var answered = false
    var value: Bool { lock.lock(); defer { lock.unlock() }; return answered }
    func set() { lock.lock(); answered = true; lock.unlock() }
}
