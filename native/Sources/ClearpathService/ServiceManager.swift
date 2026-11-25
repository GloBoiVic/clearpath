import Foundation
import Network
import ClearpathCore

/// Where Clearpath's own files live. `root` is `/` on a Mac and a temp folder in tests.
public struct ServicePaths: Sendable {
    public static let label = "io.clearpath.filter"
    static let siteBlockLabel = "io.clearpath.site-blocks"
    static let communityListLabel = "io.clearpath.community-list"
    public let root: URL
    public init(root: URL = URL(fileURLWithPath: "/")) { self.root = root }
    public var supportDirectory: URL { root.appendingPathComponent("Library/Application Support/Clearpath") }
    public var filter: URL { supportDirectory.appendingPathComponent("clearpath-filter") }
    public var controlTool: URL { supportDirectory.appendingPathComponent("clearpath-service") }
    public var policy: URL { supportDirectory.appendingPathComponent("policy.json") }
    public var recovery: URL { supportDirectory.appendingPathComponent("recovery.json") }
    var internetRecovery: URL { supportDirectory.appendingPathComponent("internet-recovery.json") }
    var communityListStatus: URL { supportDirectory.appendingPathComponent("community-list.json") }
    var partnerConfig: URL { supportDirectory.appendingPathComponent("partner-service.json") }
    var siteRemovals: URL { supportDirectory.appendingPathComponent("site-removals.json") }
    public var daemonPlist: URL { root.appendingPathComponent("Library/LaunchDaemons/\(Self.label).plist") }
    var siteBlockPlist: URL { daemonPlist.deletingLastPathComponent().appendingPathComponent("\(Self.siteBlockLabel).plist") }
    var communityListPlist: URL { daemonPlist.deletingLastPathComponent().appendingPathComponent("\(Self.communityListLabel).plist") }
    /// Clearpath's files only, in removal order: the recovery record goes last.
    var owned: [URL] {
        [communityListPlist, siteBlockPlist, daemonPlist, filter, controlTool, policy, communityListStatus,
         partnerConfig, siteRemovals, internetRecovery, recovery]
    }
}

/// One network service's DNS setting. No servers means automatic (DHCP) DNS.
public struct ServiceDNS: Codable, Equatable, Sendable {
    public let name: String
    public let servers: [String]
    public let id: String?
    public init(name: String, servers: [String], id: String? = nil) {
        self.name = name; self.servers = servers; self.id = id
    }
}

/// Written, and flushed to disk, before Clearpath changes anything. Uninstall restores from it.
public struct RecoveryRecord: Codable, Equatable, Sendable {
    public var format = 1
    public var locationID: String? = nil
    public let createdAt: String
    public let services: [ServiceDNS]
    public let upstream: String
    public let upstreamPort: UInt16
    /// `scutil --dns` before install, kept as evidence of the resolvers in use.
    public let resolverState: String
}

public struct ServiceStatus: Codable, Equatable, Sendable {
    public let installed: Bool
    public let daemonLoaded: Bool
    public let pid: Int?
    public let answering: Bool
    public let dnsPointsToFilter: Bool
    public let services: [ServiceDNS]
    public internal(set) var recovery: InternetRecoveryStatus?
    public internal(set) var restoreEvent: InternetRestoreEvent?
    public internal(set) var restoreAvailable: Bool? = nil
    public internal(set) var defaultResolverUsesFilter: Bool? = nil
    public internal(set) var communityList: CommunityListStatus? = nil
}

public enum ServiceError: Error, Equatable, CustomStringConvertible {
    /// Refused before changing anything.
    case refused(String)
    /// Something went wrong after changes began.
    case failed(String)
    public var description: String {
        switch self { case .refused(let text), .failed(let text): return text }
    }
}

/// Installs the filter as a root LaunchDaemon on 127.0.0.1:53, points every network service's
/// DNS at it, and rolls all of that back. Every step that changes the system is preceded by a
/// recovery record, and uninstall restores DNS before it stops the only listener.
public final class ServiceManager {
    public static let listenAddress = "127.0.0.1"
    public static let listenPort: UInt16 = 53
    /// The filter binds port 53 as root, then runs as this user.
    public static let runAsUser = "nobody"
    static let readyTimeout = 10.0

    let paths: ServicePaths
    let system: SystemControl
    let log: (String) -> Void

    public init(paths: ServicePaths = ServicePaths(), system: SystemControl = MacSystem(), log: @escaping (String) -> Void = { print($0) }) {
        self.paths = paths; self.system = system; self.log = log
    }

    // MARK: Install

    public func install(filter: URL, policy: URL, upstream: String?, upstreamPort: UInt16,
                        controlTool: URL? = nil, partnerConfig: URL? = nil) throws {
        guard system.isRoot else { throw ServiceError.refused("Install must run as root (sudo).") }
        let fm = FileManager.default
        guard !fm.fileExists(atPath: paths.recovery.path), !fm.fileExists(atPath: paths.daemonPlist.path),
              !fm.fileExists(atPath: paths.siteBlockPlist.path), !fm.fileExists(atPath: paths.communityListPlist.path) else {
            throw ServiceError.refused("Clearpath is already installed, or an earlier install stopped partway. Run uninstall first.")
        }
        let filterData = try readRegularFile(filter, what: "filter")
        guard fm.isExecutableFile(atPath: filter.path) else { throw ServiceError.refused("The filter at \(filter.path) is not executable.") }
        let policyData = try readRegularFile(policy, what: "policy")
        let controlData = try controlTool.map { try readRegularFile($0, what: "service tool") }
        let configData = try partnerConfig.map { try readRegularFile($0, what: "pairing configuration") }
        if let configData { _ = try decodePairingConfiguration(configData).client() }
        do { _ = try Policy(data: policyData) } catch { throw ServiceError.refused("Policy rejected: \(error).") }
        guard upstreamPort > 0 else { throw ServiceError.refused("--upstream-port must be 1-65535.") }
        guard system.portIsFree(Self.listenPort) else {
            throw ServiceError.refused("Something already listens on \(Self.listenAddress):\(Self.listenPort).")
        }

        let location = try system.networkLocation()
        let services = try readServices(ids: location.serviceIDs)
        guard !services.isEmpty else { throw ServiceError.refused("No network services found.") }
        if location.id != nil && services.contains(where: { $0.id == nil }) {
            throw ServiceError.refused("Could not identify each network service in the current location.")
        }
        if let taken = services.first(where: { $0.servers.contains(Self.listenAddress) }) {
            throw ServiceError.refused("\(taken.name) already uses \(Self.listenAddress) for DNS; restore it before installing.")
        }
        let resolver = try system.run(.scutil, ["--dns"])
        guard resolver.status == 0 else { throw ServiceError.refused("scutil --dns failed: \(resolver.output)") }
        guard let chosen = upstream ?? Self.primaryNameserver(in: resolver.output) else {
            throw ServiceError.refused("No usable upstream DNS server found; pass --upstream.")
        }
        guard let host = NetworkDNS.resolverHost(chosen) else {
            throw ServiceError.refused("--upstream must be an IP address usable as a unicast resolver.")
        }
        if NetworkDNS.isLoopback(host) && upstreamPort == Self.listenPort {
            throw ServiceError.refused("The upstream must not point back at the filter.")
        }

        let record = RecoveryRecord(locationID: location.id, createdAt: ISO8601DateFormatter().string(from: Date()), services: services,
                                    upstream: chosen, upstreamPort: upstreamPort, resolverState: resolver.output)
        try makeDirectory(paths.supportDirectory)
        try withServiceLock {
            guard !fm.fileExists(atPath: paths.daemonPlist.path), !fm.fileExists(atPath: paths.siteBlockPlist.path),
                  !fm.fileExists(atPath: paths.communityListPlist.path), !fm.fileExists(atPath: paths.communityListStatus.path),
                  !fm.fileExists(atPath: paths.internetRecovery.path), !fm.fileExists(atPath: paths.partnerConfig.path),
                  !fm.fileExists(atPath: paths.siteRemovals.path) else {
                throw ServiceError.refused("An earlier Clearpath install is present. Run uninstall first.")
            }
            try writeFile(try Self.encoder.encode(record), to: paths.recovery, mode: 0o644, exclusive: true)
            log("Recorded DNS for \(services.count) network service(s) in \(paths.recovery.path).")

            // From here on, any failure is rolled back from the record.
            do {
                try writeFile(filterData, to: paths.filter, mode: 0o755)
                if let controlData { try writeFile(controlData, to: paths.controlTool, mode: 0o755) }
                try writeFile(policyData, to: paths.policy, mode: 0o644)
                if let configData { try writeFile(configData, to: paths.partnerConfig, mode: 0o600, exclusive: true) }
                try makeDirectory(paths.daemonPlist.deletingLastPathComponent())
                try writeFile(try daemonPlist(upstream: upstream, upstreamPort: upstreamPort), to: paths.daemonPlist, mode: 0o644)
                try check(system.run(.launchctl, ["bootstrap", "system", paths.daemonPlist.path]), "launchctl bootstrap")
                guard waitForFilter() else {
                    throw ServiceError.failed("The filter did not answer on \(Self.listenAddress):\(Self.listenPort) within \(Int(Self.readyTimeout)) seconds.")
                }
                if controlData != nil {
                    try writeFile(try siteBlockPlist(reconcileRemovals: configData != nil), to: paths.siteBlockPlist, mode: 0o644)
                    try check(system.run(.launchctl, ["bootstrap", "system", paths.siteBlockPlist.path]), "launchctl bootstrap site-block service")
                }
                log("Filter answering on \(Self.listenAddress):\(Self.listenPort).")
                for service in services {
                    try setDNS(service.name, to: [Self.listenAddress])
                }
                if controlData != nil {
                    try writeFile(try communityListPlist(), to: paths.communityListPlist, mode: 0o644)
                    try check(system.run(.launchctl, ["bootstrap", "system", paths.communityListPlist.path]), "launchctl bootstrap community-list job")
                }
                log("DNS for every network service now points at the filter.")
            } catch {
                log("Install failed: \(error) Rolling back.")
                do { try uninstallLocked() } catch let rollback {
                    throw ServiceError.failed("Install failed (\(error)) and rollback failed (\(rollback)). The recovery record is kept at \(paths.recovery.path).")
                }
                throw ServiceError.failed("Install failed and was rolled back: \(error)")
            }
        }
    }

    // MARK: Uninstall

    /// Restores DNS from the record and confirms it, then stops the daemon, then removes only
    /// Clearpath's files. Safe to run after a partial install and to run twice.
    public func uninstall() throws {
        guard system.isRoot else { throw ServiceError.refused("Uninstall must run as root (sudo).") }
        try makeDirectory(paths.supportDirectory)
        try withServiceLock { try uninstallLocked() }
    }

    private func uninstallLocked() throws {
        if let record = try readRecord() {
            try restoreOriginalDNS(record)
        } else if let stuck = try readServices().first(where: { $0.servers.contains(Self.listenAddress) }),
                  FileManager.default.fileExists(atPath: paths.daemonPlist.path) || daemonLoaded() {
            // Without the record the original setting is unknown, and stopping the daemon would cut DNS.
            throw ServiceError.refused("The recovery record is missing and \(stuck.name) still uses \(Self.listenAddress). Set its DNS back by hand first (networksetup -setdnsservers \"\(stuck.name)\" Empty for automatic).")
        }
        for label in [ServicePaths.communityListLabel, ServicePaths.siteBlockLabel, ServicePaths.label] where daemonLoaded(label: label) {
            let result = try system.run(.launchctl, ["bootout", "system/\(label)"])
            if result.status != 0 && daemonLoaded(label: label) {
                throw ServiceError.failed("launchctl bootout failed: \(result.output)")
            }
            log("Stopped \(label).")
        }
        for url in paths.owned where (try? url.checkResourceIsReachable()) == true || isSymlink(url) {
            do { try FileManager.default.removeItem(at: url) } catch { throw ServiceError.failed("Could not remove \(url.path): \(error)") }
        }
        // Only an empty folder goes; anything else in it isn't Clearpath's to delete.
        rmdir(paths.supportDirectory.path)
        log("Removed Clearpath's files.")
    }

    // MARK: Status

    public func status() throws -> ServiceStatus {
        let services = try readServices()
        let pid = daemonPID()
        var status = ServiceStatus(installed: FileManager.default.fileExists(atPath: paths.recovery.path),
                             daemonLoaded: pid != nil || daemonLoaded(), pid: pid,
                             answering: system.filterAnswers(port: Self.listenPort),
                             dnsPointsToFilter: !services.isEmpty && services.allSatisfy { $0.servers == [Self.listenAddress] },
                             services: services)
        if status.installed {
            status.restoreAvailable = FileManager.default.isExecutableFile(atPath: paths.controlTool.path)
            status.communityList = try? readCommunityListStatus()
            try applyRecoveryStatus(to: &status)
            if status.dnsPointsToFilter && status.answering {
                let resolver = try system.run(.scutil, ["--dns"])
                try check(resolver, "scutil --dns")
                status.defaultResolverUsesFilter = Self.primaryNameservers(in: resolver.output) == [Self.listenAddress]
            }
        }
        return status
    }

    // MARK: DNS settings

    func readServices(ids: [String: String] = [:]) throws -> [ServiceDNS] {
        let list = try system.run(.networksetup, ["-listallnetworkservices"])
        guard list.status == 0 else { throw ServiceError.failed("networksetup -listallnetworkservices failed: \(list.output)") }
        var lines = list.output.split(separator: "\n", omittingEmptySubsequences: true).map(String.init)
        guard let note = lines.first, note.contains("asterisk") else {
            throw ServiceError.failed("Unexpected networksetup output; refusing to guess the network services.")
        }
        lines.removeFirst()
        // A disabled service (marked *) is included: enabling it later must not skip the filter.
        return try lines.map { line in
            let name = line.hasPrefix("*") ? String(line.dropFirst()) : line
            return ServiceDNS(name: name, servers: try readDNS(name), id: ids[name])
        }
    }

    func readDNS(_ service: String) throws -> [String] {
        let result = try system.run(.networksetup, ["-getdnsservers", service])
        let lines = result.output.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        guard result.status == 0 else { throw ServiceError.failed("Could not read DNS for \(service): \(result.output)") }
        if lines.count == 1 && lines[0].hasPrefix("There aren't any DNS Servers set on ") { return [] }
        // Anything but IP addresses is an unknown state: stop rather than record it wrongly.
        guard !lines.isEmpty, lines.allSatisfy({ Self.ipFamily($0) != nil }) else {
            throw ServiceError.failed("Unrecognized DNS setting for \(service): \(result.output)")
        }
        return lines
    }

    func setDNS(_ service: String, to servers: [String]) throws {
        try check(system.run(.networksetup, ["-setdnsservers", service] + (servers.isEmpty ? ["Empty"] : servers)),
                  "networksetup -setdnsservers \(service)")
        let now = try readDNS(service)
        guard now == servers else {
            throw ServiceError.failed("DNS for \(service) reads \(now) after setting \(servers).")
        }
    }

    func restoreDNS(_ recorded: [ServiceDNS], ids: [String: String]) throws {
        let present = try readServices(ids: ids)
        for service in recorded {
            guard let current = matchingService(service, in: present) else {
                log("\(service.name) no longer exists; nothing to restore.")
                continue
            }
            guard current.servers != service.servers else { continue }
            try setDNS(current.name, to: service.servers)
            log("Restored DNS for \(current.name): \(service.servers.isEmpty ? "automatic" : service.servers.joined(separator: " ")).")
        }
    }

    func matchingService(_ recorded: ServiceDNS, in current: [ServiceDNS]) -> ServiceDNS? {
        current.first { entry in
            if let id = recorded.id { return entry.id == id }
            return entry.name == recorded.name
        }
    }

    func restoreOriginalDNS(_ record: RecoveryRecord) throws {
        let location = try recoveryLocation(record)
        try restoreDNS(record.services, ids: location.serviceIDs)
        if let stuck = try readServices().first(where: { $0.servers.contains(Self.listenAddress) }) {
            throw ServiceError.failed("\(stuck.name) still uses the filter. Restore its DNS before stopping Clearpath.")
        }
    }

    func recoveryLocation(_ record: RecoveryRecord) throws -> NetworkLocation {
        let location = try system.networkLocation()
        if let original = record.locationID, location.id != original {
            throw ServiceError.refused("Switch back to the macOS network location where Clearpath was installed, then try again.")
        }
        return location
    }

    /// The first usable nameserver of the default resolver in `scutil --dns` output.
    static func primaryNameserver(in output: String) -> String? {
        primaryNameservers(in: output).first { address in
            guard let host = NetworkDNS.resolverHost(address) else { return false }
            return !NetworkDNS.isLoopback(host)
        }
    }

    static func primaryNameservers(in output: String) -> [String] {
        var inFirst = false
        var addresses: [String] = []
        for raw in output.split(separator: "\n") {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("DNS configuration (for scoped") { break }
            if line.hasPrefix("resolver #") { if inFirst { break }; inFirst = line == "resolver #1"; continue }
            guard inFirst, line.hasPrefix("nameserver["), let colon = line.range(of: " : ") else { continue }
            addresses.append(String(line[colon.upperBound...]))
        }
        return addresses
    }

    /// AF_INET or AF_INET6 for an IP literal, else nil.
    static func ipFamily(_ text: String) -> Int32? {
        if IPv4Address(text) != nil { return AF_INET }
        if let address = IPv6Address(text), !address.isLinkLocal || address.interface != nil { return AF_INET6 }
        return nil
    }

    // MARK: Daemon

    func daemonPlist(upstream: String?, upstreamPort: UInt16) throws -> Data {
        let routing = upstream.map { ["--upstream", $0] } ?? ["--network-dns", paths.recovery.path]
        let plist: [String: Any] = [
            "Label": ServicePaths.label,
            "ProgramArguments": [paths.filter.path, "--policy", paths.policy.path] + routing + [
                "--upstream-port", String(upstreamPort), "--listen", Self.listenAddress,
                "--port", String(Self.listenPort), "--user", Self.runAsUser],
            "RunAtLoad": true,
            "KeepAlive": true,
            "ThrottleInterval": 2,
        ]
        return try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
    }

    private func siteBlockPlist(reconcileRemovals: Bool) throws -> Data {
        let plist: [String: Any] = [
            "Label": ServicePaths.siteBlockLabel,
            "ProgramArguments": [paths.controlTool.path, "serve-site-blocks"],
            "MachServices": [ServicePaths.siteBlockLabel: true],
            "RunAtLoad": reconcileRemovals,
            "KeepAlive": reconcileRemovals,
        ]
        return try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
    }

    func waitForFilter() -> Bool {
        var waited = 0.0
        while waited < Self.readyTimeout {
            if system.filterAnswers(port: Self.listenPort) { return true }
            system.pause(seconds: 0.25); waited += 0.25
        }
        return system.filterAnswers(port: Self.listenPort)
    }

    func daemonLoaded(label: String = ServicePaths.label) -> Bool {
        (try? system.run(.launchctl, ["print", "system/\(label)"]).status) == 0
    }

    func daemonPID() -> Int? {
        guard let result = try? system.run(.launchctl, ["print", "system/\(ServicePaths.label)"]), result.status == 0 else { return nil }
        for line in result.output.split(separator: "\n") {
            let parts = line.trimmingCharacters(in: .whitespaces).components(separatedBy: " = ")
            if parts.count == 2, parts[0] == "pid", let pid = Int(parts[1]) { return pid }
        }
        return nil
    }

    // MARK: Files

    static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }()

    func readRecord() throws -> RecoveryRecord? {
        guard FileManager.default.fileExists(atPath: paths.recovery.path) else { return nil }
        guard let data = try? Data(contentsOf: paths.recovery),
              let record = try? JSONDecoder().decode(RecoveryRecord.self, from: data), record.format == 1 else {
            throw ServiceError.failed("The recovery record at \(paths.recovery.path) is unreadable; nothing was changed.")
        }
        return record
    }

    func readRegularFile(_ url: URL, what: String) throws -> Data {
        let values = try? url.resourceValues(forKeys: [.isRegularFileKey])
        guard values?.isRegularFile == true, let data = try? Data(contentsOf: url) else {
            throw ServiceError.refused("The \(what) at \(url.path) is not a readable file.")
        }
        return data
    }

    func makeDirectory(_ url: URL) throws {
        if isSymlink(url) { throw ServiceError.failed("\(url.path) is a symbolic link; refusing to write through it.") }
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o755])
    }

    // Keep install, recovery and uninstall from interleaving. The directory itself is the
    // lock so uninstall needn't retain a file. Check its identity after acquiring the lock.
    func withServiceLock(_ operation: () throws -> Void) throws {
        let directory = paths.supportDirectory.path
        let fd = open(directory, O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
        guard fd >= 0 else { throw ServiceError.failed("Could not open the Clearpath service directory.") }
        defer { close(fd) }
        guard flock(fd, LOCK_EX | LOCK_NB) == 0 else {
            throw ServiceError.refused("A Clearpath service change is already in progress. Try again.")
        }
        var opened = stat()
        var current = stat()
        guard fstat(fd, &opened) == 0, lstat(directory, &current) == 0,
              opened.st_dev == current.st_dev, opened.st_ino == current.st_ino,
              opened.st_uid == geteuid(), opened.st_mode & 0o022 == 0 else {
            throw ServiceError.failed("The Clearpath service directory is not owned and controlled by the installer.")
        }
        try operation()
    }

    func isSymlink(_ url: URL) -> Bool {
        (try? url.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == true
    }

    /// Writes beside the target, flushes to disk, then renames into place (or, when `exclusive`,
    /// links into place so an existing file is never replaced). Never follows a symlink.
    func writeFile(_ data: Data, to url: URL, mode: mode_t, exclusive: Bool = false) throws {
        let temp = url.deletingLastPathComponent().appendingPathComponent(".\(url.lastPathComponent).\(getpid()).tmp")
        unlink(temp.path)
        let fd = open(temp.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, mode)
        guard fd >= 0 else { throw ServiceError.failed("Could not create \(temp.path): errno \(errno).") }
        let written = data.withUnsafeBytes { write(fd, $0.baseAddress, data.count) }
        let flushed = fchmod(fd, mode) == 0 && fsync(fd) == 0
        close(fd)
        defer { unlink(temp.path) }
        guard written == data.count, flushed else { throw ServiceError.failed("Could not write \(url.path).") }
        if exclusive {
            guard link(temp.path, url.path) == 0 else { throw ServiceError.failed("Could not create \(url.path): errno \(errno).") }
        } else {
            guard !isSymlink(url), rename(temp.path, url.path) == 0 else { throw ServiceError.failed("Could not replace \(url.path).") }
        }
    }

    func check(_ result: CommandResult, _ what: String) throws {
        guard result.status == 0 else { throw ServiceError.failed("\(what) failed (\(result.status)): \(result.output)") }
    }
}
