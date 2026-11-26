import ClearpathCore
import ClearpathNetwork
import Network
import XCTest
@testable import ClearpathService

final class SiteRemovalTests: XCTestCase {
    private let week = 7 * 24 * 60 * 60
    private let startTime = 2_000_000_000
    private let policy = Data(#"{"adult":["adult.example","other.example"],"custom":["Custom.Example.","keep.example","deny.example","solo.example"],"allow":["previous.example"],"safesearch":{"www.google.com":"forcesafesearch.google.com"}}"#.utf8)
    private var root: URL!
    private var paths: ServicePaths!
    private var manager: ServiceManager!
    private let mac = FakeMac()

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("clearpath-removals-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        addTeardownBlock { [root] in try FileManager.default.removeItem(at: root!) }
        paths = ServicePaths(root: root.appendingPathComponent("system"))
        manager = ServiceManager(paths: paths, system: mac, log: { _ in })
    }

    private var filterBinary: URL {
        Bundle(for: Self.self).bundleURL.deletingLastPathComponent().appendingPathComponent("clearpath-filter")
    }

    private func install(upstreamPort: UInt16, config: URL? = nil) throws {
        let seed = root.appendingPathComponent("seed.json")
        try policy.write(to: seed)
        try manager.install(filter: filterBinary, policy: seed, upstream: "127.0.0.1", upstreamPort: upstreamPort,
                            controlTool: filterBinary.deletingLastPathComponent().appendingPathComponent("clearpath-service"),
                            partnerConfig: config)
    }

    func test_installer_accepts_only_https_and_keeps_configuration_private() throws {
        let config = root.appendingPathComponent("config.json")
        let key = String(repeating: "a", count: 43)
        func configure(_ origin: String) throws {
            try JSONEncoder().encode(["origin": origin, "ownerKey": key]).write(to: config)
        }
        try configure("http://127.0.0.1:8765")
        XCTAssertThrowsError(try install(upstreamPort: 1053, config: config))
        XCTAssertFalse(FileManager.default.fileExists(atPath: paths.recovery.path))
        try configure("https://pairing.example.test")
        try install(upstreamPort: 1053, config: config)
        let attributes = try FileManager.default.attributesOfItem(atPath: paths.partnerConfig.path)
        XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o600)
        XCTAssertEqual(try manager.pairingClient().origin.host, "pairing.example.test")
        let job = try XCTUnwrap(PropertyListSerialization.propertyList(
            from: Data(contentsOf: paths.siteBlockPlist), options: [], format: nil) as? [String: Any])
        XCTAssertEqual(job["RunAtLoad"] as? Bool, true)
        XCTAssertEqual(job["KeepAlive"] as? Bool, true)
        try manager.uninstall()
        XCTAssertFalse(FileManager.default.fileExists(atPath: paths.partnerConfig.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: paths.siteBlockPlist.path))
    }

    /// The listener holds its delegate weakly, so the test keeps it.
    private var siteBlockControl: SiteBlockControl?

    private func serveSiteBlocks(now: @escaping () -> Date) -> NSXPCListener {
        let control = SiteBlockControl(manager: manager, consoleUser: { geteuid() }, now: now)
        siteBlockControl = control
        let listener = NSXPCListener.anonymous()
        listener.delegate = control
        listener.resume()
        return listener
    }

    private func listedRemovals(_ listener: NSXPCListener) throws -> [SiteRemoval] {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let text = try SiteBlockControl.listRemovals(over: NSXPCConnection(listenerEndpoint: listener.endpoint))
        return try decoder.decode([SiteRemoval].self, from: Data(text.utf8))
    }

    func test_solo_install_without_pairing_configuration_removes_a_block_after_seven_days() async throws {
        let upstream = try CommunityLoopback(tcp: false) { packet in
            guard let query = try? DNSMessage(Array(packet)) else { return Data() }
            return Data(query.response(answers: [DNSRecord(name: query.name, type: 1, data: [192, 0, 2, 42])]))
        }
        defer { upstream.stop() }
        try install(upstreamPort: upstream.port.rawValue)
        XCTAssertFalse(FileManager.default.fileExists(atPath: paths.partnerConfig.path))
        let job = try XCTUnwrap(PropertyListSerialization.propertyList(
            from: Data(contentsOf: paths.siteBlockPlist), options: [], format: nil) as? [String: Any])
        XCTAssertEqual(job["RunAtLoad"] as? Bool, true)
        XCTAssertEqual(job["KeepAlive"] as? Bool, true)

        let filter = Process()
        filter.executableURL = filterBinary
        filter.arguments = ["--policy", paths.policy.path, "--upstream", "127.0.0.1",
                            "--upstream-port", String(upstream.port.rawValue), "--port", "0"]
        let startup = try start(filter)
        defer { stopProcess(filter) }
        let portText = startup.prefix { $0 != ";" }.split(separator: ":").last ?? ""
        let port = try XCTUnwrap(NWEndpoint.Port(String(portText)))
        let dns = NetworkUpstream(endpoint: .hostPort(host: "127.0.0.1", port: port), timeout: 1)
        func assertDNS(_ domain: String, _ expected: UInt16) async throws {
            for _ in 0..<60 {
                let reply = try DNSMessage(await dns.exchange(DNSMessage.query(domain, type: 1), tcp: false))
                if reply.rcode == expected { return }
                try await Task.sleep(nanoseconds: 50_000_000)
            }
            XCTFail("The running filter did not return rcode \(expected) for \(domain).")
        }

        let requested = Date(timeIntervalSince1970: TimeInterval(startTime))
        let deadline = requested.addingTimeInterval(TimeInterval(week))
        let listener = serveSiteBlocks { requested }
        defer { listener.invalidate() }
        func connection() -> NSXPCConnection { NSXPCConnection(listenerEndpoint: listener.endpoint) }
        try await assertDNS("solo.example", 3)
        try await assertDNS("sub.adult.example", 3)
        try SiteBlockControl.requestRemoval("Solo.Example.", rule: "custom", over: connection())
        try SiteBlockControl.requestRemoval("adult.example", rule: "adult", over: connection())
        try SiteBlockControl.requestRemoval("solo.example", rule: "custom", over: connection())
        var listed = try listedRemovals(listener)
        XCTAssertEqual(listed.map(\.domain), ["solo.example", "adult.example"])
        XCTAssertEqual(listed.map(\.deadline), [deadline, deadline])
        XCTAssertEqual(listed.map(\.outcome), [.pending, .pending])

        await manager.reconcileSiteRemovals(now: deadline.addingTimeInterval(-1))
        try await assertDNS("solo.example", 3)
        try await assertDNS("sub.adult.example", 3)
        XCTAssertEqual(try listedRemovals(listener).map(\.outcome), [.pending, .pending])

        // A restarted daemon applies the requests from disk once the deadline passes.
        manager = ServiceManager(paths: paths, system: mac, log: { _ in })
        await manager.reconcileSiteRemovals(now: deadline)
        try await assertDNS("solo.example", 0)
        try await assertDNS("sub.adult.example", 0)
        try await assertDNS("keep.example", 3)
        try await assertDNS("other.example", 3)
        listed = try listedRemovals(listener)
        XCTAssertEqual(listed.map(\.outcome), [.timedOut, .timedOut])
        XCTAssertEqual(listed.map(\.applied), [true, true])
        XCTAssertEqual(try manager.siteBlocks().allow, ["adult.example", "previous.example"])
        XCTAssertFalse(try manager.siteBlocks().custom.contains("solo.example"))
    }

    func test_a_partner_added_after_a_solo_install_stops_solo_removals() async throws {
        let requested = Date(timeIntervalSince1970: TimeInterval(startTime))
        let deadline = requested.addingTimeInterval(TimeInterval(week))
        let listener = serveSiteBlocks { requested }
        defer { listener.invalidate() }
        func connection() -> NSXPCConnection { NSXPCConnection(listenerEndpoint: listener.endpoint) }
        func assertNeedsPairing(_ domain: String, line: UInt = #line) {
            XCTAssertThrowsError(try SiteBlockControl.requestRemoval(domain, rule: "custom", over: connection()), line: line) {
                XCTAssertTrue("\($0)".contains("configured pairing service"), "\($0)", line: line)
            }
        }
        try install(upstreamPort: 1053)
        try SiteBlockControl.requestRemoval("solo.example", rule: "custom", over: connection())
        XCTAssertEqual(try listedRemovals(listener).map(\.deadline), [deadline])

        // Partner settings reports the pairing service it uses for this Mac.
        try SiteBlockControl.recordPartnerPairing(over: connection())
        try SiteBlockControl.recordPartnerPairing(over: connection())
        XCTAssertEqual(try FileManager.default.attributesOfItem(atPath: paths.partnerPairing.path)[.posixPermissions] as? Int, 0o644)
        var listed = try listedRemovals(listener)
        XCTAssertEqual(listed.map(\.outcome), [.cancelled])
        await manager.reconcileSiteRemovals(now: deadline)
        XCTAssertTrue(try manager.siteBlocks().custom.contains("solo.example"))
        XCTAssertEqual(try manager.readSiteRemovals().map(\.applied), [false])
        assertNeedsPairing("solo.example")
        assertNeedsPairing("keep.example")
        // A writer that chose a solo deadline before the partner was recorded is refused under the lock.
        XCTAssertThrowsError(try manager.requestSiteRemoval("keep.example", rule: .custom, deadline: deadline))
        XCTAssertEqual(try manager.readSiteRemovals().count, 1)

        // If the marker appears without the cancellation (an interrupted write), the daemon
        // cancels the open solo request instead of applying it at the deadline.
        try FileManager.default.removeItem(at: paths.partnerPairing)
        try SiteBlockControl.requestRemoval("keep.example", rule: "custom", over: connection())
        try Data("{}".utf8).write(to: paths.partnerPairing)
        await manager.reconcileSiteRemovals(now: deadline)
        listed = try listedRemovals(listener)
        XCTAssertEqual(listed.map(\.domain), ["solo.example", "keep.example"])
        XCTAssertEqual(listed.map(\.outcome), [.cancelled, .cancelled])
        XCTAssertEqual(try manager.siteBlocks().custom.filter { ["solo.example", "keep.example"].contains($0) }.count, 2)
        try manager.uninstall()
        XCTAssertFalse(FileManager.default.fileExists(atPath: paths.partnerPairing.path))
    }

    func test_removal_requests_keep_blocks_when_the_install_state_is_unknown_or_contradictory() async throws {
        let later = Date(timeIntervalSince1970: TimeInterval(startTime + 2 * week))
        let listener = serveSiteBlocks { Date(timeIntervalSince1970: TimeInterval(self.startTime)) }
        defer { listener.invalidate() }
        func request(_ domain: String) throws {
            try SiteBlockControl.requestRemoval(domain, rule: "custom", over: NSXPCConnection(listenerEndpoint: listener.endpoint))
        }
        func assertRefused(_ containing: String, line: UInt = #line) {
            XCTAssertThrowsError(try request("solo.example"), line: line) {
                XCTAssertTrue("\($0)".contains(containing), "\($0)", line: line)
            }
            // Listing stays available read-only and shows that nothing was recorded.
            XCTAssertEqual(try listedRemovals(listener).count, 0, line: line)
            XCTAssertEqual(try manager.readSiteRemovals().count, 0, line: line)
        }

        // Solo install, but an uninstall event says it is being removed.
        try install(upstreamPort: 1053)
        try Data("{}".utf8).write(to: paths.uninstallEvent)
        assertRefused("could not confirm")
        try FileManager.default.removeItem(at: paths.uninstallEvent)

        // Solo install, but a pairing configuration appeared.
        try Data("{}".utf8).write(to: paths.partnerConfig)
        assertRefused("could not confirm")
        try FileManager.default.removeItem(at: paths.partnerConfig)

        // A request saved without a deadline waits for a partner even on a solo install.
        try manager.requestSiteRemoval("solo.example", rule: .custom)
        await manager.reconcileSiteRemovals(now: later)
        XCTAssertEqual(try manager.readSiteRemovals().map(\.outcome), [.pending])
        XCTAssertTrue(try manager.siteBlocks().custom.contains("solo.example"))
        try manager.uninstall()

        // A record from before this change says nothing: it still needs a pairing service.
        try install(upstreamPort: 1053)
        var record = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: paths.recovery)) as? [String: Any])
        XCTAssertEqual(record.removeValue(forKey: "pairingService") as? Bool, false)
        try JSONSerialization.data(withJSONObject: record).write(to: paths.recovery)
        assertRefused("configured pairing service")
        try manager.uninstall()

        // A partner install whose pairing configuration is gone.
        let config = root.appendingPathComponent("config.json")
        try JSONEncoder().encode(["origin": "https://pairing.example.test",
                                  "ownerKey": String(repeating: "a", count: 43)]).write(to: config)
        try install(upstreamPort: 1053, config: config)
        let installed = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: paths.recovery)) as? [String: Any])
        XCTAssertEqual(installed["pairingService"] as? Bool, true)
        try FileManager.default.removeItem(at: paths.partnerConfig)
        assertRefused("configured pairing service")
        try manager.uninstall()
    }

    func test_real_partner_decisions_reach_the_running_filter_after_restart_and_refresh() async throws {
        let upstream = try CommunityLoopback(tcp: false) { packet in
            guard let query = try? DNSMessage(Array(packet)) else { return Data() }
            return Data(query.response(answers: [DNSRecord(name: query.name, type: 1, data: [192, 0, 2, 42])]))
        }
        defer { upstream.stop() }
        try install(upstreamPort: upstream.port.rawValue)

        let filter = Process()
        filter.executableURL = filterBinary
        filter.arguments = ["--policy", paths.policy.path, "--upstream", "127.0.0.1",
                            "--upstream-port", String(upstream.port.rawValue), "--port", "0"]
        let startup = try start(filter)
        defer { stopProcess(filter) }
        let portText = startup.prefix { $0 != ";" }.split(separator: ":").last ?? ""
        let port = try XCTUnwrap(NWEndpoint.Port(String(portText)))
        let dns = NetworkUpstream(endpoint: .hostPort(host: "127.0.0.1", port: port), timeout: 1)
        func assertDNS(_ domain: String, _ expected: UInt16) async throws {
            for _ in 0..<60 {
                let reply = try DNSMessage(await dns.exchange(DNSMessage.query(domain, type: 1), tcp: false))
                if reply.rcode == expected { return }
                try await Task.sleep(nanoseconds: 50_000_000)
            }
            XCTFail("The running filter did not return rcode \(expected) for \(domain).")
        }

        let pairing = try PairingFixture(root: root, now: startTime)
        defer { pairing.stop() }
        let client = try pairing.client
        func reconcile() async { await manager.reconcileSiteRemovals(client: client) }
        func request(_ domain: String, _ rule: RemovalRule) async throws -> UUID {
            try manager.requestSiteRemoval(domain, rule: rule)
            await reconcile()
            return try XCTUnwrap(manager.readSiteRemovals().last?.id)
        }
        func vote(_ id: UUID, _ role: String, _ choice: String, status: Int = 200) async throws {
            let token = try pairing.token(request: id, role: role)
            let actual = try await pairing.post("/decision/confirm", form: "token=\(token)&choice=\(choice)")
            XCTAssertEqual(actual, status)
        }
        try await assertDNS("solo.example", 3)
        let solo = try await request("solo.example", .custom)
        XCTAssertFalse(FileManager.default.fileExists(atPath: pairing.batch(solo).path))
        try await pairing.acceptBothPartners()

        try await assertDNS("custom.example", 3)
        let first = try await request("custom.example", .custom)
        try manager.requestSiteRemoval("CUSTOM.example.", rule: .custom)
        XCTAssertEqual(try manager.readSiteRemovals().count, 2)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: pairing.batch(first).path).count, 2)
        let preview = try await pairing.get("/decision")
        XCTAssertEqual(preview, 200)
        await reconcile()
        try await assertDNS("custom.example", 3)
        try await vote(first, "backup", "approve")
        try await vote(first, "primary", "deny", status: 403)
        await reconcile()
        try await assertDNS("custom.example", 0)
        try await assertDNS("keep.example", 3)

        _ = try manager.addSiteBlock("custom.example")
        try await assertDNS("custom.example", 3)
        let later = try await request("custom.example", .custom)
        XCTAssertNotEqual(first, later)
        try await vote(first, "backup", "approve", status: 403)
        await reconcile()
        try await assertDNS("custom.example", 3)

        let denied = try await request("deny.example", .custom)
        try await vote(denied, "primary", "deny")
        try await vote(denied, "backup", "approve", status: 403)
        await reconcile()
        try await assertDNS("deny.example", 3)

        let adult = try await request("adult.example", .adult)
        try await assertDNS("sub.adult.example", 3)
        try pairing.setClock(startTime + week - 1)
        await reconcile()
        try await assertDNS("solo.example", 3)
        try await assertDNS("sub.adult.example", 3)

        pairing.stop()
        try pairing.setClock(startTime + week)
        manager = ServiceManager(paths: paths, system: mac, log: { _ in })
        await reconcile()
        try await assertDNS("sub.adult.example", 3)
        try pairing.restart()
        try await vote(adult, "primary", "deny", status: 403)
        await reconcile()
        try await assertDNS("solo.example", 0)
        try await assertDNS("sub.adult.example", 0)
        try await assertDNS("other.example", 3)
        try await assertDNS("deny.example", 3)
        XCTAssertEqual(try manager.siteBlocks().allow, ["adult.example", "previous.example"])
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: pairing.batch(adult, expired: true).path).count, 2)
        XCTAssertFalse(FileManager.default.fileExists(atPath: pairing.batch(solo, expired: true).path))

        let names = ["adult.example", "other.example"] + (1...18).map { "fixture-\($0).example" }
        let body = "# Version: 2026.1201.1200.00\n# Number of entries: \(names.count)\n" + names.joined(separator: "\n")
        let refresh = try CommunityHTTP(Data(body.utf8))
        defer { refresh.stop() }
        try manager.refreshCommunityList(from: refresh.source, now: { Date(timeIntervalSince1970: TimeInterval(startTime)) })
        try await assertDNS("sub.adult.example", 0)
        try await assertDNS("fixture-1.example", 3)
        try await assertDNS("deny.example", 3)
        XCTAssertEqual(try manager.siteBlocks().allow, ["adult.example", "previous.example"])
        XCTAssertTrue(filter.isRunning)
    }
}

@discardableResult
private func start(_ process: Process) throws -> String {
    let pipe = Pipe()
    process.standardOutput = pipe
    try process.run()
    var descriptor = pollfd(fd: pipe.fileHandleForReading.fileDescriptor, events: Int16(POLLIN), revents: 0)
    guard poll(&descriptor, 1, 10_000) == 1, descriptor.revents & Int16(POLLIN) != 0 else {
        stopProcess(process)
        throw ServiceError.failed("The loopback fixture did not start.")
    }
    return String(decoding: pipe.fileHandleForReading.availableData, as: UTF8.self).trimmingCharacters(in: .newlines)
}

private func stopProcess(_ process: Process) {
    if process.isRunning { process.terminate() }
    process.waitUntilExit()
}

final class PairingFixture {
    private var process: Process?
    private let state: URL
    private let clock: URL
    private var port: UInt16 = 0
    private var origin: String { "http://127.0.0.1:\(port)" }
    private var key: String {
        get throws { try String(contentsOf: state.appendingPathComponent("owner-key"), encoding: .ascii) }
    }

    init(root: URL, now: Int) throws {
        state = root.appendingPathComponent("pairing")
        clock = root.appendingPathComponent("clock")
        try setClock(now)
        try restart()
    }

    var client: PairingClient {
        get throws { try PairingConfiguration(origin: origin, ownerKey: key).client(allowFixtureHTTP: true) }
    }

    func setClock(_ now: Int) throws {
        try String(now).write(to: clock, atomically: true, encoding: .ascii)
    }

    func restart() throws {
        let server = Process()
        server.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        server.currentDirectoryURL = repository
        var environment = ProcessInfo.processInfo.environment
        environment["PYTHONPATH"] = repository.path
        server.environment = environment
        server.arguments = ["python3", "tests/fixtures/pairing_clock.py", state.path, clock.path, String(port)]
        let started = try start(server)
        process = server
        port = try XCTUnwrap(UInt16(started))
    }

    func stop() {
        if let process { stopProcess(process) }
        process = nil
    }

    func batch(_ id: UUID, expired: Bool = false) -> URL {
        state.appendingPathComponent("mail").appendingPathComponent(id.uuidString.lowercased() + (expired ? "-expired" : ""))
    }

    func token(request id: UUID, role: String) throws -> String {
        let message = try String(contentsOf: batch(id).appendingPathComponent(role + ".eml"), encoding: .utf8)
        return try XCTUnwrap(message.split(whereSeparator: \.isNewline).last?.split(separator: "#").last.map(String.init))
    }

    func acceptBothPartners() async throws {
        for role in ["primary", "backup"] {
            let body = try JSONSerialization.data(withJSONObject: ["email": role + "@example.test", "revision": 0])
            let payload = String(decoding: body, as: UTF8.self)
            let status = try await request("/partners/" + role, body: payload, contentType: "application/json", owner: true)
            XCTAssertEqual(status, 201)
        }
        let mail = state.appendingPathComponent("mail")
        let messages = try FileManager.default.contentsOfDirectory(at: mail, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "eml" }
        XCTAssertEqual(messages.count, 2)
        for file in messages {
            let message = try String(contentsOf: file, encoding: .utf8)
            let link = try XCTUnwrap(message.split(whereSeparator: \.isNewline).last.map(String.init).flatMap(URL.init(string:)))
            let token = try XCTUnwrap(link.fragment)
            let status = try await post(link.path, form: "token=" + token)
            XCTAssertEqual(status, 200)
        }
    }

    func get(_ path: String) async throws -> Int { try await request(path) }
    func post(_ path: String, form: String) async throws -> Int {
        try await request(path, body: form, contentType: "application/x-www-form-urlencoded")
    }

    func checkInRevision() async throws -> UUID {
        let (status, data) = try await response("/check-in", owner: true)
        XCTAssertEqual(status, 200)
        let json = try JSONDecoder().decode([String: UUID].self, from: data)
        return try XCTUnwrap(json["revision"])
    }

    func advance() async throws {
        let status = try await request("/partners", owner: true)
        XCTAssertEqual(status, 200)
    }

    func missedCheckInMail() throws -> [URL] {
        let mail = state.appendingPathComponent("mail")
        let batches = try FileManager.default.contentsOfDirectory(at: mail, includingPropertiesForKeys: nil)
        return try batches.filter { $0.lastPathComponent.hasPrefix("check-in-") }.flatMap {
            try FileManager.default.contentsOfDirectory(at: $0, includingPropertiesForKeys: nil)
        }
    }

    private func request(_ path: String, body: String? = nil,
                         contentType: String? = nil, owner: Bool = false) async throws -> Int {
        try await response(path, body: body, contentType: contentType, owner: owner).0
    }

    private func response(_ path: String, body: String? = nil,
                          contentType: String? = nil, owner: Bool) async throws -> (Int, Data) {
        var request = URLRequest(url: try XCTUnwrap(URL(string: origin + path)), timeoutInterval: 3)
        if owner { request.setValue("Bearer " + (try key), forHTTPHeaderField: "Authorization") }
        if let body {
            request.httpMethod = "POST"
            request.httpBody = Data(body.utf8)
            request.setValue(contentType, forHTTPHeaderField: "Content-Type")
        }
        let (data, response) = try await URLSession.shared.data(for: request)
        return (try XCTUnwrap((response as? HTTPURLResponse)?.statusCode), data)
    }
}
