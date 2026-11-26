import XCTest
@testable import ClearpathService

let repository = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

/// A simulated Mac: network services with DNS settings, a launchd that runs the filter, and a
/// log of every command. Real files are written under a temp root; nothing touches this Mac.
final class FakeMac: SystemControl {
    var isRoot = true
    var consoleUserID: uid_t? = 501
    var applicationSignatureValid = true
    var loginItemRegistered = true
    var loginItemRemovable = true
    var installedProfiles: [[String: String]] = []
    var profileListingValid = true
    var profileRemovable = true
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
    var resolverTracksFilterDNS = false
    var loaded = false
    var siteBlockJobLoaded = false
    var siteBlockJobStarts = true
    var communityListJobLoaded = false
    var communityListJobStarts = true
    var filterStarts = true
    var filterResolvesLookups = true
    var networkResolvesLookups = true
    var portFree = true
    var ignoreSetFor: String?
    var onPause: () -> Void = {}
    var calls: [String] = []
    var identifiers: [String: String] = [:]
    var locationID: String?
    /// Checked at the moment of bootstrap: the record must already be on disk.
    var onBootstrap: () -> Void = {}

    func run(_ tool: Tool, _ arguments: [String]) throws -> CommandResult {
        calls.append(([tool.rawValue] + arguments).joined(separator: " "))
        switch (tool, arguments.first) {
        case (.codesign, _):
            return CommandResult(status: applicationSignatureValid ? 0 : 1, output: "")
        case (.profiles, "show"):
            guard profileListingValid else { return CommandResult(status: 0, output: "unrecognized output") }
            let data = try PropertyListSerialization.data(fromPropertyList: ["_computerlevel": installedProfiles], format: .xml, options: 0)
            return CommandResult(status: 0, output: String(decoding: data, as: UTF8.self))
        case (.profiles, "remove"):
            guard profileRemovable, let identifier = arguments.last else { return CommandResult(status: 1, output: "") }
            installedProfiles.removeAll { $0["ProfileIdentifier"] == identifier }
            return CommandResult(status: 0, output: "")
        case (.launchctl, "asuser"):
            guard loginItemRemovable else { return CommandResult(status: 1, output: "") }
            loginItemRegistered = false
            return CommandResult(status: 0, output: "unregistered\n")
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
            if resolverTracksFilterDNS && services.allSatisfy({ $0.servers == [ServiceManager.listenAddress] }) {
                return CommandResult(status: 0, output: "resolver #1\n  nameserver[0] : 127.0.0.1\n")
            }
            return CommandResult(status: 0, output: resolverState)
        case (.launchctl, "bootstrap"):
            if arguments[2].hasSuffix("/\(ServicePaths.communityListLabel).plist") {
                guard communityListJobStarts else { return CommandResult(status: 1, output: "bootstrap failed") }
                communityListJobLoaded = true
                return CommandResult(status: 0, output: "")
            }
            if arguments[2].hasSuffix("/\(ServicePaths.siteBlockLabel).plist") {
                guard siteBlockJobStarts else { return CommandResult(status: 1, output: "bootstrap failed") }
                siteBlockJobLoaded = true
                return CommandResult(status: 0, output: "")
            }
            onBootstrap()
            loaded = true
            return CommandResult(status: 0, output: "")
        case (.launchctl, "bootout"):
            if arguments[1] == "system/\(ServicePaths.communityListLabel)" {
                communityListJobLoaded = false
                return CommandResult(status: 0, output: "")
            }
            if arguments[1] == "system/\(ServicePaths.siteBlockLabel)" {
                siteBlockJobLoaded = false
                return CommandResult(status: 0, output: "")
            }
            guard loaded else { return CommandResult(status: 113, output: "Boot-out failed: 113: Could not find service") }
            loaded = false
            return CommandResult(status: 0, output: "")
        case (.launchctl, "print"):
            if arguments[1] == "system/\(ServicePaths.communityListLabel)" {
                return CommandResult(status: communityListJobLoaded ? 0 : 113, output: "")
            }
            if arguments[1] == "system/\(ServicePaths.siteBlockLabel)" {
                return CommandResult(status: siteBlockJobLoaded ? 0 : 113, output: "")
            }
            return loaded ? CommandResult(status: 0, output: "system/io.clearpath.filter = {\n\tstate = running\n\tpid = 4242\n}\n")
                          : CommandResult(status: 113, output: "Could not find service \"io.clearpath.filter\" in domain for system\n")
        default:
            return CommandResult(status: 1, output: "unexpected")
        }
    }

    func portIsFree(_ port: UInt16) -> Bool { portFree }
    func networkLocation() throws -> NetworkLocation { NetworkLocation(id: locationID, serviceIDs: identifiers) }
    func filterAnswers(port: UInt16) -> Bool { loaded && filterStarts }
    func filterResolves(port: UInt16) -> Bool { filterAnswers(port: port) && filterResolvesLookups }
    func networkResolves(_ record: RecoveryRecord) -> Bool { networkResolvesLookups }
    func pause(seconds: Double) { onPause() }

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
        XCTAssertFalse(mac.siteBlockJobLoaded, file: file, line: line)
        XCTAssertFalse(mac.communityListJobLoaded, file: file, line: line)
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
        let plist = try XCTUnwrap(PropertyListSerialization.propertyList(from: Data(contentsOf: paths.daemonPlist), format: nil) as? [String: Any])
        let args = try XCTUnwrap(plist["ProgramArguments"] as? [String])
        XCTAssertTrue(args.contains("--network-dns"))
        XCTAssertTrue(args.contains(paths.recovery.path))
        XCTAssertFalse(args.contains("--upstream"), "the installed filter must select its upstream from the current network")
        XCTAssertEqual(ServiceManager.primaryNameserver(in: "resolver #1\n  nameserver[0] : fe80::1\n"), nil)
        XCTAssertEqual(ServiceManager.primaryNameserver(in: "resolver #1\n  nameserver[0] : fe80::1%lo0\n"), "fe80::1%lo0")
        XCTAssertEqual(ServiceManager.primaryNameserver(in: "No DNS configuration available\n"), nil)
        try manager.uninstall()
        mac.resolverState = "DNS configuration\n\nresolver #1\n  nameserver[0] : 127.0.0.1\n"
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

    private func stageApplication() throws -> URL {
        let stage = root.appendingPathComponent("stage")
        try FileManager.default.createDirectory(at: stage, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        try FileManager.default.createDirectory(at: paths.application, withIntermediateDirectories: true)
        return stage
    }

    private func uninstallApplication(_ stage: URL) throws -> ApplicationUninstallOutcome {
        try manager.uninstallApplication(codeHash: String(repeating: "a", count: 40), consoleUID: 501,
                                         stagingDirectory: stage, reason: .withoutApproval)
    }

    func test_application_uninstall_restores_dns_and_removes_only_the_matching_profile_login_item_and_app() throws {
        try manager.install(filter: filter, policy: policy, upstream: "192.0.2.10", upstreamPort: 53, controlTool: filter)
        let stage = try stageApplication()
        let other = ["ProfileIdentifier": "example.unrelated", "ProfileUUID": UUID().uuidString]
        mac.installedProfiles = [other, ["ProfileIdentifier": BrowserProfile.identifier, "ProfileUUID": BrowserProfile.uuid]]
        mac.calls.removeAll()

        XCTAssertEqual(try uninstallApplication(stage), .removed)

        let restore = try XCTUnwrap(mac.calls.lastIndex { $0.hasPrefix("/usr/sbin/networksetup -setdnsservers") })
        let stop = try XCTUnwrap(mac.index(of: "/bin/launchctl bootout"))
        let removeProfile = try XCTUnwrap(mac.index(of: "/usr/bin/profiles remove -type configuration -forced -identifier \(BrowserProfile.identifier)"))
        XCTAssertLessThan(restore, stop)
        XCTAssertLessThan(stop, removeProfile)
        XCTAssertEqual(mac.installedProfiles, [other])
        XCTAssertFalse(mac.loginItemRegistered)
        XCTAssertFalse(FileManager.default.fileExists(atPath: paths.application.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: paths.supportDirectory.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: paths.pendingUninstallEvents.path))
        assertNothingInstalled()
    }

    func test_application_uninstall_keeps_the_app_until_manual_profile_removal_is_verified() throws {
        try install()
        let stage = try stageApplication()
        mac.installedProfiles = [["ProfileIdentifier": BrowserProfile.identifier, "ProfileUUID": BrowserProfile.uuid]]
        mac.profileRemovable = false

        XCTAssertEqual(try uninstallApplication(stage), .removeBrowserProfile)
        XCTAssertEqual(try uninstallApplication(stage), .removeBrowserProfile)
        XCTAssertTrue(FileManager.default.fileExists(atPath: paths.application.path))
        XCTAssertTrue(mac.loginItemRegistered)
        XCTAssertEqual(mac.dns, original)

        mac.installedProfiles = []
        mac.profileListingValid = false
        XCTAssertThrowsError(try uninstallApplication(stage))
        XCTAssertTrue(FileManager.default.fileExists(atPath: paths.application.path))

        mac.profileListingValid = true
        XCTAssertEqual(try uninstallApplication(stage), .removed)
        XCTAssertFalse(FileManager.default.fileExists(atPath: paths.application.path))
        assertNothingInstalled()
    }

    func test_application_uninstall_preserves_a_different_profile_with_the_same_identifier() throws {
        try install()
        let stage = try stageApplication()
        mac.installedProfiles = [["ProfileIdentifier": BrowserProfile.identifier, "ProfileUUID": UUID().uuidString]]
        let previous = mac.installedProfiles

        XCTAssertEqual(try uninstallApplication(stage), .removed)
        XCTAssertEqual(mac.installedProfiles, previous)
        XCTAssertNil(mac.index(of: "/usr/bin/profiles remove"))
    }

    func test_application_uninstall_keeps_the_filter_until_the_effective_resolver_moves_away() throws {
        try install()
        let stage = try stageApplication()
        let originalResolver = mac.resolverState
        mac.resolverState = "DNS configuration\n\nresolver #1\n  nameserver[0] : 127.0.0.1\n"

        XCTAssertThrowsError(try uninstallApplication(stage))
        XCTAssertEqual(mac.dns, original)
        XCTAssertTrue(mac.loaded)
        XCTAssertTrue(FileManager.default.fileExists(atPath: paths.recovery.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: paths.application.path))
        XCTAssertNil(mac.index(of: "/bin/launchctl bootout"))

        mac.resolverState = originalResolver
        XCTAssertEqual(try uninstallApplication(stage), .removed)
        assertNothingInstalled()
    }

    func test_application_uninstall_refuses_a_replaced_app_and_a_non_console_user_before_dns_changes() throws {
        try install()
        let stage = try stageApplication()
        let installedDNS = mac.dns
        mac.calls.removeAll()
        mac.applicationSignatureValid = false
        XCTAssertThrowsError(try uninstallApplication(stage))
        mac.applicationSignatureValid = true
        mac.consoleUserID = 502
        XCTAssertThrowsError(try uninstallApplication(stage))
        XCTAssertEqual(mac.dns, installedDNS)
        XCTAssertTrue(mac.loaded)
        XCTAssertTrue(mac.loginItemRegistered)
        XCTAssertNil(mac.index(of: "/usr/sbin/networksetup -setdnsservers"))
        XCTAssertTrue(FileManager.default.fileExists(atPath: paths.application.path))
    }

    func test_application_uninstall_retries_without_duplicate_partner_events_or_credentials() throws {
        let config = root.appendingPathComponent("pairing.json")
        let key = String(repeating: "a", count: 43)
        try Data("{\"origin\":\"https://example.test\",\"ownerKey\":\"\(key)\"}".utf8).write(to: config)
        try manager.install(filter: filter, policy: policy, upstream: "192.0.2.10", upstreamPort: 53, partnerConfig: config)
        let stage = try stageApplication()
        XCTAssertEqual(try manager.pairingClient().origin.host, "example.test")
        mac.installedProfiles = [["ProfileIdentifier": BrowserProfile.identifier, "ProfileUUID": BrowserProfile.uuid]]
        mac.profileRemovable = false

        XCTAssertEqual(try uninstallApplication(stage), .removeBrowserProfile)
        XCTAssertEqual(mac.dns, original)
        XCTAssertTrue(FileManager.default.fileExists(atPath: paths.application.path))
        let pending = try FileManager.default.contentsOfDirectory(at: paths.pendingUninstallEvents, includingPropertiesForKeys: nil)
        let eventFile = try XCTUnwrap(pending.first)
        let event = try Data(contentsOf: eventFile)
        XCTAssertEqual(pending.count, 1)
        XCTAssertEqual(try mode(eventFile), 0o600)
        XCTAssertFalse(String(decoding: event, as: UTF8.self).contains(key))
        XCTAssertFalse(String(decoding: event, as: UTF8.self).contains("example.test"))
        XCTAssertTrue(String(decoding: event, as: UTF8.self).contains("uninstalledWithoutApproval"))
        let restarted = ServiceManager(paths: paths, system: mac, log: { _ in })
        XCTAssertThrowsError(try restarted.pairingClient(), "a restarted job must not resume partner check-ins")

        mac.installedProfiles = []
        mac.loginItemRemovable = false
        XCTAssertThrowsError(try uninstallApplication(stage))
        XCTAssertTrue(FileManager.default.fileExists(atPath: paths.application.path))
        XCTAssertEqual(try Data(contentsOf: eventFile), event)
        mac.loginItemRemovable = true

        let collision = stage.appendingPathComponent("RemovedClearpath.app")
        try FileManager.default.createDirectory(at: collision, withIntermediateDirectories: false)
        XCTAssertThrowsError(try uninstallApplication(stage))
        try FileManager.default.removeItem(at: collision)
        XCTAssertEqual(try uninstallApplication(stage), .removed)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: paths.pendingUninstallEvents.path), [eventFile.lastPathComponent])
        XCTAssertEqual(try Data(contentsOf: eventFile), event)
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

    func test_uninstall_restores_a_renamed_service_by_its_identifier() throws {
        mac.identifiers["Ethernet"] = "ethernet"
        try install()
        XCTAssertEqual(try record().services.first { $0.name == "Ethernet" }?.id, "ethernet")
        mac.services[1].name = "Lab Ethernet"
        mac.identifiers = ["Lab Ethernet": "ethernet"]

        try manager.uninstall()
        XCTAssertEqual(mac.dns["Lab Ethernet"], original["Ethernet"])
        XCTAssertFalse(mac.loaded)
    }

    func test_uninstall_keeps_the_original_record_when_a_different_network_location_is_active() throws {
        mac.locationID = "original"
        mac.identifiers = ["Ethernet": "ethernet", "Wi-Fi": "wifi", "Thunderbolt Bridge": "bridge"]
        try install()
        mac.locationID = "other"
        mac.calls.removeAll()
        assertRefused({ try manager.uninstall() }, containing: "Switch back")
        XCTAssertTrue(mac.loaded)
        XCTAssertTrue(FileManager.default.fileExists(atPath: paths.recovery.path))
        XCTAssertNil(mac.index(of: "/usr/sbin/networksetup -setdnsservers"))

        mac.locationID = "original"
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
        assertRefused({ try install(upstream: "::ffff:127.0.0.1", port: 53) }, containing: "point back")
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

    func test_uninstall_without_record_or_plist_keeps_a_loaded_daemon_that_dns_still_uses() throws {
        try install()
        try FileManager.default.removeItem(at: paths.recovery)
        try FileManager.default.removeItem(at: paths.daemonPlist)
        assertRefused({ try manager.uninstall() }, containing: "recovery record is missing")
        XCTAssertTrue(mac.loaded, "the only DNS listener keeps running")
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
                                                          dnsPointsToFilter: false, services: try manager.readServices(),
                                                          setupInstallAvailable: true))
        try install()
        let status = try manager.status()
        XCTAssertTrue(status.installed && status.daemonLoaded && status.answering && status.dnsPointsToFilter)
        XCTAssertEqual(status.pid, 4242)
        XCTAssertEqual(status.defaultResolverUsesFilter, false)
        mac.resolverState = "DNS configuration\n\nresolver #1\n  nameserver[0] : 127.0.0.1\n\nresolver #2\n  nameserver[0] : 192.0.2.53\n"
        XCTAssertEqual(try manager.status().defaultResolverUsesFilter, true)
    }

    func test_status_flags_lookups_that_fail_only_through_the_filter_while_a_vpn_is_the_default_resolver() throws {
        try install()
        mac.resolverState = "DNS configuration\n\nresolver #1\n  nameserver[0] : 100.100.100.100\n\nresolver #2\n  nameserver[0] : 127.0.0.1\n"
        XCTAssertNil(try manager.status().lookupsFailThroughFilter)

        // A DNS loop (#73): the filter answers the probe but resolves nothing; the network's resolver works.
        mac.filterResolvesLookups = false
        let looping = try manager.status()
        XCTAssertTrue(looping.answering)
        XCTAssertEqual(looping.lookupsFailThroughFilter, true)

        // The network itself is down: going around Clearpath would not help.
        mac.networkResolvesLookups = false
        XCTAssertEqual(try manager.status().lookupsFailThroughFilter, false)

        // With the filter as the default resolver no lookup is spent.
        mac.resolverState = "DNS configuration\n\nresolver #1\n  nameserver[0] : 127.0.0.1\n"
        XCTAssertNil(try manager.status().lookupsFailThroughFilter)
    }

    func test_install_copies_the_control_tool_and_reports_when_it_is_available() throws {
        let tool = root.appendingPathComponent("clearpath-service")
        let contents = Data("synthetic service executable".utf8)
        try contents.write(to: tool)
        try manager.install(filter: filter, policy: policy, upstream: "192.0.2.10", upstreamPort: 53, controlTool: tool)
        XCTAssertEqual(try Data(contentsOf: paths.controlTool), contents)
        XCTAssertEqual(try mode(paths.controlTool), 0o755)
        XCTAssertEqual(try manager.status().restoreAvailable, true)
        XCTAssertTrue(mac.siteBlockJobLoaded)
        let plist = try PropertyListSerialization.propertyList(from: Data(contentsOf: paths.siteBlockPlist), format: nil) as? [String: Any]
        XCTAssertEqual(plist?["MachServices"] as? [String: Bool], [ServicePaths.siteBlockLabel: true])
        XCTAssertEqual(plist?["ProgramArguments"] as? [String], [paths.controlTool.path, "serve-site-blocks"])
        try manager.uninstall()
        assertNothingInstalled()
    }

    func test_site_additions_preserve_policy_and_survive_a_new_manager() throws {
        try install()
        let original = try JSONSerialization.jsonObject(with: Data(contentsOf: paths.policy)) as! [String: Any]
        XCTAssertEqual(try manager.addSiteBlock("New.Example."), "new.example")
        let updated = try Data(contentsOf: paths.policy)
        XCTAssertEqual(try manager.addSiteBlock("new.example"), "new.example")
        XCTAssertEqual(try Data(contentsOf: paths.policy), updated)
        assertRefused({ _ = try manager.addSiteBlock("https://new.example") }, containing: "domain")
        XCTAssertEqual(try Data(contentsOf: paths.policy), updated)
        let restarted = ServiceManager(paths: paths, system: mac)
        XCTAssertTrue(try restarted.siteBlocks().custom.contains("new.example"))
        var object = try JSONSerialization.jsonObject(with: updated) as! [String: Any]
        XCTAssertEqual((object.removeValue(forKey: "custom") as! [String]).sorted(),
                       (original["custom"] as! [String] + ["new.example"]).sorted())
        var otherOriginal = original
        otherOriginal.removeValue(forKey: "custom")
        XCTAssertEqual(object as NSDictionary, otherOriginal as NSDictionary)
        XCTAssertEqual(try mode(paths.policy), 0o644)
    }

    func test_install_rolls_back_when_the_policy_writer_cannot_be_registered() throws {
        mac.siteBlockJobStarts = false
        XCTAssertThrowsError(try manager.install(filter: filter, policy: policy, upstream: "192.0.2.10",
                                                 upstreamPort: 53, controlTool: filter))
        assertNothingInstalled()
        XCTAssertNil(mac.index(of: "/usr/sbin/networksetup -setdnsservers Wi-Fi 127.0.0.1"))
    }

    func test_site_addition_cannot_replace_an_invalid_policy_or_a_symbolic_link() throws {
        try install()
        let corrupt = Data("invalid JSON".utf8)
        try corrupt.write(to: paths.policy)
        assertRefused({ _ = try manager.addSiteBlock("new.example") }, containing: "invalid")
        XCTAssertEqual(try Data(contentsOf: paths.policy), corrupt)
        try FileManager.default.removeItem(at: paths.policy)
        try FileManager.default.createSymbolicLink(at: paths.policy, withDestinationURL: policy)
        let before = try Data(contentsOf: policy)
        assertRefused({ _ = try manager.addSiteBlock("new.example") }, containing: "invalid")
        XCTAssertEqual(try Data(contentsOf: policy), before)
        XCTAssertTrue(manager.isSymlink(paths.policy))
    }

    func test_site_block_connection_checks_the_peer_and_only_adds_valid_domains() throws {
        try install()
        let authorized = SiteBlockControl(manager: manager) { geteuid() }
        let denied = SiteBlockControl(manager: manager) { nil }
        let listener = NSXPCListener.anonymous()
        listener.resume()
        defer { listener.invalidate() }
        func add(_ input: String) throws -> String {
            try SiteBlockControl.add(input, over: NSXPCConnection(listenerEndpoint: listener.endpoint))
        }
        listener.delegate = denied
        XCTAssertThrowsError(try add("denied.example"))
        listener.delegate = authorized
        XCTAssertEqual(try add("Added.Example."), "added.example")
        assertRefused({ _ = try add("added.example/path") }, containing: "domain")
        let custom = try manager.siteBlocks().custom
        XCTAssertTrue(custom.contains("added.example"))
        XCTAssertFalse(custom.contains("denied.example"))
    }

    func test_restore_waits_for_restart_and_leaves_protection_on_if_the_filter_answers() throws {
        try install()
        mac.filterStarts = false
        mac.onPause = { [unowned self] in mac.filterStarts = true }
        mac.calls.removeAll()

        assertRefused({ try manager.restoreInternet() }, containing: "Clearpath is filtering again")
        XCTAssertEqual(Set(mac.dns.values), [["127.0.0.1"]])
        XCTAssertNil(mac.index(of: "/usr/sbin/networksetup -setdnsservers"))
        XCTAssertNil(try manager.status().restoreEvent)
    }

    func test_restore_recovers_dns_while_the_filter_runs_but_resolves_nothing() throws {
        // A filter forwarding into a DNS loop (#73) or to a dead upstream still answers the
        // nameless probe, but every lookup fails (#74).
        try install()
        mac.filterResolvesLookups = false

        try manager.restoreInternet()

        XCTAssertEqual(mac.dns, original)
        XCTAssertEqual(try manager.status().recovery, .restored)
        XCTAssertNotNil(try manager.status().restoreEvent)
    }

    func test_restore_recovers_original_dns_and_records_one_event_without_uninstalling() throws {
        try install()
        mac.filterStarts = false
        let recovery = try Data(contentsOf: paths.recovery)
        mac.calls.removeAll()

        try manager.restoreInternet()

        XCTAssertEqual(mac.dns, original)
        XCTAssertTrue(mac.loaded)
        XCTAssertEqual(try Data(contentsOf: paths.recovery), recovery)
        let status = try manager.status()
        XCTAssertEqual(status.recovery, .restored)
        let event = try XCTUnwrap(status.restoreEvent)
        XCTAssertNil(mac.index(of: "/bin/launchctl bootout"))

        mac.calls.removeAll()
        try manager.restoreInternet()
        XCTAssertEqual(try manager.status().restoreEvent, event)
        XCTAssertNil(mac.index(of: "/usr/sbin/networksetup -setdnsservers"))

        mac.services[1].servers = ["198.51.100.53"]
        XCTAssertEqual(try manager.status().recovery, .unknown)
        XCTAssertEqual(try manager.status().restoreEvent, event)
        assertRefused({ try manager.restoreInternet() }, containing: "DNS has changed")
        try manager.uninstall()
        assertNothingInstalled()
    }

    func test_restore_resumes_partial_dns_changes_without_publishing_a_success_early() throws {
        try install()
        mac.filterStarts = false
        mac.ignoreSetFor = "Ethernet"

        XCTAssertThrowsError(try manager.restoreInternet())
        XCTAssertEqual(mac.dns["Wi-Fi"], [])
        XCTAssertEqual(mac.dns["Ethernet"], ["127.0.0.1"])
        XCTAssertEqual(try manager.status().recovery, .restoring)
        XCTAssertNil(try manager.status().restoreEvent)

        mac.ignoreSetFor = nil
        mac.filterStarts = true
        let restartedTool = ServiceManager(paths: paths, system: mac, log: { _ in })
        try restartedTool.restoreInternet()
        XCTAssertEqual(mac.dns, original)
        XCTAssertEqual(try restartedTool.status().recovery, .restored)
        XCTAssertNotNil(try restartedTool.status().restoreEvent)
    }

    func test_restore_refuses_unprivileged_calls_and_a_different_network_location() throws {
        mac.locationID = "original"
        mac.identifiers = ["Ethernet": "ethernet", "Wi-Fi": "wifi", "Thunderbolt Bridge": "bridge"]
        try install()
        mac.filterStarts = false
        mac.calls.removeAll()
        mac.isRoot = false
        assertRefused({ try manager.restoreInternet() }, containing: "root")
        mac.isRoot = true
        mac.locationID = "other"
        assertRefused({ try manager.restoreInternet() }, containing: "Switch back")
        XCTAssertNil(mac.index(of: "/usr/sbin/networksetup -setdnsservers"))
        XCTAssertNil(try manager.status().restoreEvent)
    }

    func test_uninstall_cannot_interleave_with_an_ongoing_restore() throws {
        try install()
        mac.filterStarts = false
        mac.onPause = { [unowned self] in
            assertRefused({ try manager.uninstall() }, containing: "already in progress")
            mac.onPause = {}
        }
        try manager.restoreInternet()
        XCTAssertEqual(mac.dns, original)
        XCTAssertTrue(mac.loaded)
        XCTAssertNotNil(try manager.status().restoreEvent)
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
