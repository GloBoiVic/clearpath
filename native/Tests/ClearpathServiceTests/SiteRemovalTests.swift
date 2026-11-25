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
        let attributes = try FileManager.default.attributesOfItem(atPath: paths.removalConfig.path)
        XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o600)
        XCTAssertEqual(try manager.removalClient().origin.host, "pairing.example.test")
        try manager.uninstall()
        XCTAssertFalse(FileManager.default.fileExists(atPath: paths.removalConfig.path))
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

private final class PairingFixture {
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

    var client: RemovalClient {
        get throws { try RemovalConfiguration(origin: origin, ownerKey: key).client(allowFixtureHTTP: true) }
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

    private func request(_ path: String, body: String? = nil,
                         contentType: String? = nil, owner: Bool = false) async throws -> Int {
        var request = URLRequest(url: try XCTUnwrap(URL(string: origin + path)), timeoutInterval: 3)
        if owner { request.setValue("Bearer " + (try key), forHTTPHeaderField: "Authorization") }
        if let body {
            request.httpMethod = "POST"
            request.httpBody = Data(body.utf8)
            request.setValue(contentType, forHTTPHeaderField: "Content-Type")
        }
        let (_, response) = try await URLSession.shared.data(for: request)
        return try XCTUnwrap((response as? HTTPURLResponse)?.statusCode)
    }
}
