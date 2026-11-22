import XCTest
@testable import ClearpathService

let repository = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

/// A simulated Mac: network services with DNS settings, a launchd that runs the filter, and a
/// log of every command. Real files are written under a temp root; nothing touches this Mac.
final class FakeMac: SystemControl {
    var isRoot = true
    var services: [(name: String, disabled: Bool, servers: [String])] = [
        ("Wi-Fi", false, []), ("Ethernet", false, ["192.0.2.53", "2001:db8::53"]), ("Thunderbolt Bridge", true, []),
    ]
    var resolverState = """
    DNS configuration

    resolver #1
      nameserver[0] : 127.0.0.9
      nameserver[1] : 198.51.100.1
      if_index : 15 (en0)

    resolver #2
      domain   : local
      nameserver[0] : 203.0.113.7

    DNS configuration (for scoped queries)

    resolver #1
      nameserver[0] : 203.0.113.8
    """
    var loaded = false
    var filterStarts = true
    var portFree = true
    var ignoreSetFor: String?
    var calls: [String] = []
    /// Checked at the moment of bootstrap: the record must already be on disk.
    var onBootstrap: () -> Void = {}

    func run(_ tool: Tool, _ arguments: [String]) throws -> CommandResult {
        calls.append(([tool.rawValue] + arguments).joined(separator: " "))
        switch (tool, arguments.first) {
        case (.networksetup, "-listallnetworkservices"):
            let names = services.map { ($0.disabled ? "*" : "") + $0.name }
            return CommandResult(status: 0, output: (["An asterisk (*) denotes that a network service is disabled."] + names).joined(separator: "\n") + "\n")
        case (.networksetup, "-getdnsservers"):
            guard let service = services.first(where: { $0.name == arguments[1] }) else {
                return CommandResult(status: 4, output: "\(arguments[1]) is not a recognized network service.\n")
            }
            return CommandResult(status: 0, output: service.servers.isEmpty
                ? "There aren't any DNS Servers set on \(service.name).\n" : service.servers.joined(separator: "\n") + "\n")
        case (.networksetup, "-setdnsservers"):
            guard let index = services.firstIndex(where: { $0.name == arguments[1] }) else { return CommandResult(status: 4, output: "") }
            if ignoreSetFor != arguments[1] {
                let servers = Array(arguments.dropFirst(2))
                services[index].servers = servers == ["Empty"] ? [] : servers
            }
            return CommandResult(status: 0, output: "")
        case (.scutil, _):
            return CommandResult(status: 0, output: resolverState)
        case (.launchctl, "bootstrap"):
            onBootstrap()
            loaded = true
            return CommandResult(status: 0, output: "")
        case (.launchctl, "bootout"):
            guard loaded else { return CommandResult(status: 113, output: "Boot-out failed: 113: Could not find service") }
            loaded = false
            return CommandResult(status: 0, output: "")
        case (.launchctl, "print"):
            return loaded ? CommandResult(status: 0, output: "system/io.clearpath.filter = {\n\tstate = running\n\tpid = 4242\n}\n")
                          : CommandResult(status: 113, output: "Could not find service \"io.clearpath.filter\" in domain for system\n")
        default:
            return CommandResult(status: 1, output: "unexpected")
        }
    }

    func portIsFree(_ port: UInt16) -> Bool { portFree }
    func filterAnswers(port: UInt16) -> Bool { loaded && filterStarts }
    func pause(seconds: Double) {}

    var dns: [String: [String]] { Dictionary(uniqueKeysWithValues: services.map { ($0.name, $0.servers) }) }
    func index(of call: String) -> Int? { calls.firstIndex { $0.hasPrefix(call) } }
}

final class ServiceTests: XCTestCase {
    var root: URL!
    var mac: FakeMac!
    var manager: ServiceManager!
    var paths: ServicePaths!
    var filter: URL!
    var policy: URL!
    var messages: [String] = []
    var original: [String: [String]]!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("clearpath-service-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { [root] in try? FileManager.default.removeItem(at: root!) }
        paths = ServicePaths(root: root.appendingPathComponent("system"))
        mac = FakeMac()
        original = mac.dns
        manager = ServiceManager(paths: paths, system: mac) { [unowned self] in messages.append($0) }
        filter = root.appendingPathComponent("clearpath-filter")
        try Data("#!/bin/sh\nexit 0\n".utf8).write(to: filter)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: filter.path)
        policy = root.appendingPathComponent("policy.json")
        try FileManager.default.copyItem(at: repository.appendingPathComponent("policy.example.json"), to: policy)
    }

    func install(upstream: String? = "192.0.2.10", port: UInt16 = 53) throws {
        try manager.install(filter: filter, policy: policy, upstream: upstream, upstreamPort: port)
    }

    func record() throws -> RecoveryRecord {
        try JSONDecoder().decode(RecoveryRecord.self, from: Data(contentsOf: paths.recovery))
    }

    func mode(_ url: URL) throws -> Int {
        try (FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as! NSNumber).intValue
    }

    func assertNothingInstalled(file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(mac.dns, original, file: file, line: line)
        XCTAssertFalse(mac.loaded, file: file, line: line)
        for url in paths.owned { XCTAssertFalse(FileManager.default.fileExists(atPath: url.path), url.path, file: file, line: line) }
    }

    func assertRefused(_ body: () throws -> Void, containing text: String, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertThrowsError(try body(), file: file, line: line) { error in
            guard case ServiceError.refused(let message) = error else { return XCTFail("\(error)", file: file, line: line) }
            XCTAssertTrue(message.contains(text), message, file: file, line: line)
        }
    }

    func test_install_records_dhcp_and_explicit_dns_before_any_change_then_points_every_service_at_loopback() throws {
        mac.onBootstrap = { [unowned self] in
            XCTAssertTrue(FileManager.default.fileExists(atPath: paths.recovery.path))
            XCTAssertEqual(mac.dns, original)
        }
        try install()
        let saved = try record()
        XCTAssertEqual(saved.services, [ServiceDNS(name: "Wi-Fi", servers: []),
                                        ServiceDNS(name: "Ethernet", servers: ["192.0.2.53", "2001:db8::53"]),
                                        ServiceDNS(name: "Thunderbolt Bridge", servers: [])])
        XCTAssertEqual(saved.upstream, "192.0.2.10")
        XCTAssertTrue(saved.resolverState.contains("198.51.100.1"))
        XCTAssertEqual(Set(mac.dns.values), [["127.0.0.1"]])
        XCTAssertTrue(mac.loaded)
        let firstSet = try XCTUnwrap(mac.index(of: "/usr/sbin/networksetup -setdnsservers"))
        XCTAssertLessThan(try XCTUnwrap(mac.index(of: "/bin/launchctl bootstrap system")), firstSet, "the filter answers before DNS moves to it")
    }

    func test_install_writes_root_daemon_that_restarts_and_drops_to_nobody_on_port_53() throws {
        try install(upstream: "2001:db8::1", port: 5300)
        let plist = try XCTUnwrap(PropertyListSerialization.propertyList(from: Data(contentsOf: paths.daemonPlist), format: nil) as? [String: Any])
        XCTAssertEqual(plist["Label"] as? String, "io.clearpath.filter")
        XCTAssertEqual(plist["KeepAlive"] as? Bool, true)
        XCTAssertEqual(plist["RunAtLoad"] as? Bool, true)
        XCTAssertEqual(plist["ProgramArguments"] as? [String], [
            paths.filter.path, "--policy", paths.policy.path, "--upstream", "2001:db8::1", "--upstream-port", "5300",
            "--listen", "127.0.0.1", "--port", "53", "--user", "nobody"])
        XCTAssertEqual(try Data(contentsOf: paths.filter), try Data(contentsOf: filter))
        XCTAssertEqual(try Data(contentsOf: paths.policy), try Data(contentsOf: policy))
        XCTAssertEqual(try mode(paths.filter), 0o755)
        XCTAssertEqual(try mode(paths.policy), 0o644)
        XCTAssertEqual(try mode(paths.daemonPlist), 0o644)
        XCTAssertEqual(try mode(paths.recovery), 0o644)
        XCTAssertFalse(try FileManager.default.contentsOfDirectory(atPath: paths.supportDirectory.path).contains { $0.hasSuffix(".tmp") })
    }

    func test_upstream_defaults_to_first_non_loopback_primary_nameserver() throws {
        try install(upstream: nil)
        XCTAssertEqual(try record().upstream, "198.51.100.1")
        XCTAssertEqual(ServiceManager.primaryNameserver(in: "resolver #1\n  nameserver[0] : fe80::1%en0\n"), nil)
        XCTAssertEqual(ServiceManager.primaryNameserver(in: "No DNS configuration available\n"), nil)
        mac.resolverState = "DNS configuration\n\nresolver #1\n  nameserver[0] : 127.0.0.1\n"
        try manager.uninstall()
        assertRefused({ try install(upstream: nil) }, containing: "pass --upstream")
    }

    func test_uninstall_restores_dns_before_stopping_the_daemon_and_removes_only_clearpath_files() throws {
        try install()
        let other = paths.supportDirectory.appendingPathComponent("someone-else.txt")
        try Data("keep".utf8).write(to: other)
        mac.calls.removeAll()
        try manager.uninstall()
        XCTAssertEqual(mac.dns, original)
        XCTAssertTrue(mac.calls.contains("/usr/sbin/networksetup -setdnsservers Wi-Fi Empty"))
        XCTAssertTrue(mac.calls.contains("/usr/sbin/networksetup -setdnsservers Ethernet 192.0.2.53 2001:db8::53"))
        let lastSet = try XCTUnwrap(mac.calls.lastIndex { $0.hasPrefix("/usr/sbin/networksetup -setdnsservers") })
        XCTAssertLessThan(lastSet, try XCTUnwrap(mac.index(of: "/bin/launchctl bootout")))
        for url in paths.owned { XCTAssertFalse(FileManager.default.fileExists(atPath: url.path), url.path) }
        XCTAssertTrue(FileManager.default.fileExists(atPath: other.path), "an unrelated file and its folder stay")
        XCTAssertFalse(mac.loaded)

        try FileManager.default.removeItem(at: other)
        try manager.uninstall()  // a second run is harmless and removes the now-empty folder
        XCTAssertFalse(FileManager.default.fileExists(atPath: paths.supportDirectory.path))
        assertNothingInstalled()
    }

    func test_install_that_never_answers_rolls_back_completely() throws {
        mac.filterStarts = false
        XCTAssertThrowsError(try install()) { error in
            guard case ServiceError.failed(let message) = error else { return XCTFail("\(error)") }
            XCTAssertTrue(message.contains("rolled back"), message)
        }
        XCTAssertNil(mac.index(of: "/usr/sbin/networksetup -setdnsservers Wi-Fi 127.0.0.1"))
        assertNothingInstalled()
    }

    func test_uninstall_finishes_an_install_interrupted_after_dns_moved() throws {
        try install()
        mac.services[0].servers = ["127.0.0.1"]   // as if install died midway through the services
        mac.services[1].servers = original["Ethernet"]!
        try manager.uninstall()
        assertNothingInstalled()
    }

    func test_install_refuses_unsafe_starts_and_changes_nothing() throws {
        mac.isRoot = false
        assertRefused({ try install() }, containing: "root")
        mac.isRoot = true
        mac.portFree = false
        assertRefused({ try install() }, containing: "already listens")
        mac.portFree = true
        assertRefused({ try install(upstream: "127.0.0.1", port: 53) }, containing: "point back")
        assertRefused({ try install(upstream: "resolver.example") }, containing: "IP address")
        assertRefused({ try manager.install(filter: filter, policy: root.appendingPathComponent("absent.json"), upstream: "192.0.2.10", upstreamPort: 53) }, containing: "not a readable file")
        try Data(#"{"adult": ["*.bad"], "custom": [], "allow": [], "safesearch": {}}"#.utf8).write(to: policy)
        assertRefused({ try install() }, containing: "Policy rejected")
        try FileManager.default.copyItem(at: repository.appendingPathComponent("policy.example.json"), to: root.appendingPathComponent("good.json"))
        policy = root.appendingPathComponent("good.json")
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: filter.path)
        assertRefused({ try install() }, containing: "not executable")
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: filter.path)
        mac.services[1].servers = ["127.0.0.1"]
        assertRefused({ try install() }, containing: "Ethernet already uses 127.0.0.1")
        mac.services[1].servers = original["Ethernet"]!
        XCTAssertNil(mac.index(of: "/usr/sbin/networksetup -setdnsservers"))
        XCTAssertNil(mac.index(of: "/bin/launchctl bootstrap"))
        assertNothingInstalled()
    }

    func test_install_refuses_while_an_earlier_install_is_present() throws {
        try install()
        let before = try Data(contentsOf: paths.recovery)
        assertRefused({ try install() }, containing: "Run uninstall first")
        XCTAssertEqual(try Data(contentsOf: paths.recovery), before, "the original record is never overwritten")
        try FileManager.default.removeItem(at: paths.recovery)
        assertRefused({ try install() }, containing: "Run uninstall first")  // a daemon plist alone also blocks
    }

    func test_unrecognized_dns_output_fails_closed_without_recording() throws {
        mac.services[0].servers = ["not-an-address"]
        XCTAssertThrowsError(try install())
        XCTAssertFalse(FileManager.default.fileExists(atPath: paths.recovery.path))
        XCTAssertNil(mac.index(of: "/bin/launchctl bootstrap"))
    }

    func test_uninstall_keeps_the_daemon_when_dns_cannot_be_restored() throws {
        try install()
        mac.ignoreSetFor = "Ethernet"
        XCTAssertThrowsError(try manager.uninstall())
        XCTAssertTrue(mac.loaded, "the only DNS listener keeps running")
        XCTAssertTrue(FileManager.default.fileExists(atPath: paths.recovery.path))
    }

    func test_uninstall_without_a_record_refuses_while_dns_points_at_the_filter() throws {
        try install()
        try FileManager.default.removeItem(at: paths.recovery)
        assertRefused({ try manager.uninstall() }, containing: "recovery record is missing")
        XCTAssertTrue(mac.loaded)
        for name in original.keys { _ = try mac.run(.networksetup, ["-setdnsservers", name, "Empty"]) }
        try manager.uninstall()  // with DNS restored by hand, the rest is removed
        XCTAssertFalse(mac.loaded)
        XCTAssertFalse(FileManager.default.fileExists(atPath: paths.daemonPlist.path))
    }

    func test_unreadable_record_changes_nothing() throws {
        try install()
        try Data("{".utf8).write(to: paths.recovery)
        XCTAssertThrowsError(try manager.uninstall())
        XCTAssertTrue(mac.loaded)
        XCTAssertEqual(Set(mac.dns.values), [["127.0.0.1"]])
    }

    func test_uninstall_skips_a_service_removed_since_install() throws {
        try install()
        mac.services.removeLast()
        try manager.uninstall()
        XCTAssertEqual(mac.dns["Wi-Fi"], [])
        XCTAssertTrue(messages.contains("Thunderbolt Bridge no longer exists; nothing to restore."))
        XCTAssertFalse(mac.loaded)
    }

    func test_status_reports_install_daemon_and_dns() throws {
        XCTAssertEqual(try manager.status(), ServiceStatus(installed: false, daemonLoaded: false, pid: nil, answering: false,
                                                          dnsPointsToFilter: false, services: try manager.readServices()))
        try install()
        let status = try manager.status()
        XCTAssertTrue(status.installed && status.daemonLoaded && status.answering && status.dnsPointsToFilter)
        XCTAssertEqual(status.pid, 4242)
    }

    func test_install_refuses_to_write_through_a_symlinked_folder() throws {
        let elsewhere = root.appendingPathComponent("elsewhere")
        try FileManager.default.createDirectory(at: elsewhere, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: paths.supportDirectory.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: paths.supportDirectory, withDestinationURL: elsewhere)
        XCTAssertThrowsError(try install())
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: elsewhere.path), [])
        XCTAssertEqual(mac.dns, original)
    }
}
