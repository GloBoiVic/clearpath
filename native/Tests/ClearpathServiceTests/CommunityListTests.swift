import ClearpathCore
import ClearpathNetwork
import Network
import XCTest
@testable import ClearpathService

final class CommunityListTests: XCTestCase {
    private let week: TimeInterval = 7 * 24 * 60 * 60
    private let firstVersion = "2026.1124.1200.00"
    private let nextVersion = "2026.1201.1200.00"
    private let common = (1...24).map { "adult-\($0).example" } + ["excepted.example"]

    private var root: URL!
    private var paths: ServicePaths!
    private var manager: ServiceManager!
    private var mac: FakeMac!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("clearpath-community-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { [root] in try FileManager.default.removeItem(at: root!) }
        paths = ServicePaths(root: root.appendingPathComponent("system"))
        mac = FakeMac()
        manager = ServiceManager(paths: paths, system: mac, log: { _ in })
    }

    private var filterBinary: URL {
        Bundle(for: Self.self).bundleURL.deletingLastPathComponent().appendingPathComponent("clearpath-filter")
    }

    private func install(upstreamPort: UInt16 = 1053) throws {
        let seed = root.appendingPathComponent("seed.json")
        try Data(#"{"adult":["seed.example"],"custom":["Personal.Example."],"allow":["Excepted.Example."],"safesearch":{"WWW.Google.COM.":"ForceSafeSearch.Google.COM."}}"#.utf8).write(to: seed)
        try manager.install(filter: filterBinary, policy: seed, upstream: "127.0.0.1", upstreamPort: upstreamPort,
                            controlTool: filterBinary.deletingLastPathComponent().appendingPathComponent("clearpath-service"))
    }

    private func list(_ domains: [String], version: String, count: Int? = nil) -> Data {
        Data(("# Version: \(version)\n# Number of entries: \(count ?? domains.count)\n" +
              domains.joined(separator: "\n") + "\n").utf8)
    }

    func test_installer_registers_catch_up_at_boot_and_wake_and_uninstall_removes_the_job_and_state() throws {
        mac.communityListJobStarts = false
        XCTAssertThrowsError(try install())
        XCTAssertFalse(mac.loaded)
        XCTAssertFalse(mac.siteBlockJobLoaded)
        XCTAssertFalse(FileManager.default.fileExists(atPath: paths.communityListPlist.path))

        mac.communityListJobStarts = true
        try install()
        let plist = try XCTUnwrap(PropertyListSerialization.propertyList(
            from: Data(contentsOf: paths.communityListPlist), format: nil
        ) as? [String: Any])
        XCTAssertEqual(plist["ProgramArguments"] as? [String], [paths.controlTool.path, "refresh-community-list"])
        XCTAssertEqual(plist["RunAtLoad"] as? Bool, true)
        XCTAssertEqual(plist["StartCalendarInterval"] as? [String: Int], ["Minute": 0])
        XCTAssertTrue(mac.communityListJobLoaded)
        let status = CommunityListStatus(lastSuccess: Date(), sourceVersion: firstVersion)
        try ServiceManager.encoder.encode(status).write(to: paths.communityListStatus)

        try manager.uninstall()
        XCTAssertFalse(mac.communityListJobLoaded)
        XCTAssertFalse(FileManager.default.fileExists(atPath: paths.communityListPlist.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: paths.communityListStatus.path))
    }

    func test_weekly_refresh_catches_up_once_and_updates_the_running_filter() async throws {
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
        let output = Pipe()
        filter.standardOutput = output
        try filter.run()
        defer { if filter.isRunning { filter.terminate() }; filter.waitUntilExit() }
        var descriptor = pollfd(fd: output.fileHandleForReading.fileDescriptor, events: Int16(POLLIN), revents: 0)
        XCTAssertEqual(poll(&descriptor, 1, 10_000), 1)
        guard descriptor.revents & Int16(POLLIN) != 0 else { return XCTFail("The filter did not start.") }
        let startup = String(decoding: output.fileHandleForReading.availableData, as: UTF8.self)
        let portText = startup.prefix { $0 != ";" }.split(separator: ":").last ?? ""
        let port = try XCTUnwrap(NWEndpoint.Port(String(portText)))
        let client = NetworkUpstream(endpoint: .hostPort(host: "127.0.0.1", port: port), timeout: 1)
        func answer(_ domain: String) async throws -> DNSMessage {
            try DNSMessage(await client.exchange(DNSMessage.query(domain, type: 1), tcp: false))
        }
        func waitFor(_ domain: String, code: UInt16) async throws {
            for _ in 0..<100 {
                if try await answer(domain).rcode == code { return }
                try await Task.sleep(nanoseconds: 50_000_000)
            }
            XCTFail("The running filter never returned rcode \(code) for \(domain).")
        }
        let initial = try await answer("seed.example")
        XCTAssertEqual(initial.rcode, 3)

        let excluded = ["reddit.com", "media.redd.it", "twitter.com", "x.com", "a.tumblr.com",
                        "google.com", "forcesafesearch.google.com"]
        let firstDomains = common + ["old-adult.example"] + excluded
        let newDomains = common + ["new-adult.example"] + excluded
        let http = try CommunityHTTP(list(firstDomains, version: firstVersion))
        defer { http.stop() }
        let source = http.source
        let firstCheck = Date(timeIntervalSince1970: 1_795_521_600)

        try manager.refreshCommunityList(from: source, now: { firstCheck })
        try await waitFor("old-adult.example", code: 3)
        try await waitFor("seed.example", code: 0)
        let beforeDue = firstCheck.addingTimeInterval(week - 1)
        http.respond(list(newDomains, version: nextVersion))
        try manager.refreshCommunityList(from: source, now: { beforeDue })
        XCTAssertEqual(http.requests.count, 1)
        try await waitFor("old-adult.example", code: 3)

        let afterMissedWeeks = firstCheck.addingTimeInterval(week * 3)
        let restarted = ServiceManager(paths: paths, system: mac, log: { _ in })
        // A personal write after the download starts must survive promotion.
        http.respond(list(newDomains, version: nextVersion)) { [writer = manager!] in
            do { _ = try writer.addSiteBlock("added-during-download.example") }
            catch { XCTFail("Concurrent custom block was rejected: \(error)") }
        }
        try restarted.refreshCommunityList(from: source, now: { afterMissedWeeks })
        try restarted.refreshCommunityList(from: source, now: { afterMissedWeeks })
        XCTAssertEqual(http.requests.count, 2)
        for request in http.requests {
            XCTAssertTrue(request.hasPrefix("GET /community HTTP/1.1\r\n"))
            XCTAssertFalse(request.lowercased().contains("cookie:"))
            XCTAssertFalse(request.lowercased().contains("authorization:"))
            XCTAssertTrue(request.hasSuffix("\r\n\r\n"))
        }

        try await waitFor("sub.new-adult.example", code: 3)
        try await waitFor("old-adult.example", code: 0)
        for domain in ["personal.example", "added-during-download.example"] {
            let blocked = try await answer(domain)
            XCTAssertEqual(blocked.rcode, 3)
        }
        for domain in ["excepted.example", "www.reddit.com", "media.redd.it", "www.twitter.com", "x.com", "a.tumblr.com"] {
            let allowed = try await answer(domain)
            XCTAssertEqual(allowed.answers.first?.data, [192, 0, 2, 42])
        }
        let search = try await answer("www.google.com")
        XCTAssertEqual(search.answers.first?.cname?.host, "forcesafesearch.google.com")
        XCTAssertEqual(search.answers.last?.data, [192, 0, 2, 42])

        let bytes = try Data(contentsOf: paths.policy)
        let fields = try XCTUnwrap(JSONSerialization.jsonObject(with: bytes) as? [String: Any])
        XCTAssertEqual(fields["custom"] as? [String], ["Personal.Example.", "added-during-download.example"])
        XCTAssertEqual(fields["allow"] as? [String], ["Excepted.Example."])
        XCTAssertEqual(fields["safesearch"] as? [String: String], ["WWW.Google.COM.": "ForceSafeSearch.Google.COM."])
        let inode = try XCTUnwrap(FileManager.default.attributesOfItem(atPath: paths.policy.path)[.systemFileNumber] as? NSNumber)
        let nextCheck = afterMissedWeeks.addingTimeInterval(week)
        http.respond(list(newDomains, version: nextVersion))
        try restarted.refreshCommunityList(from: source, now: { nextCheck })
        XCTAssertEqual(http.requests.count, 3)
        XCTAssertEqual(try FileManager.default.attributesOfItem(atPath: paths.policy.path)[.systemFileNumber] as? NSNumber, inode)
        XCTAssertEqual(try Data(contentsOf: paths.policy), bytes)
        XCTAssertEqual(try restarted.status().communityList, CommunityListStatus(lastSuccess: nextCheck, sourceVersion: nextVersion))
        XCTAssertTrue(filter.isRunning)
    }

    func test_invalid_unreachable_and_implausible_updates_leave_last_good_policy_and_retry_when_due() throws {
        try install()
        let http = try CommunityHTTP(Data())
        defer { http.stop() }
        let firstCheck = Date(timeIntervalSince1970: 1_795_521_600)
        let seed = try Data(contentsOf: paths.policy)
        XCTAssertThrowsError(try manager.refreshCommunityList(from: http.source, now: { firstCheck }))
        XCTAssertEqual(try Data(contentsOf: paths.policy), seed)
        XCTAssertNil(try manager.status().communityList)
        http.respond(list(common, version: firstVersion))
        try manager.refreshCommunityList(from: http.source, now: { firstCheck })
        let policy = try Data(contentsOf: paths.policy)
        let status = try Data(contentsOf: paths.communityListStatus)
        let due = firstCheck.addingTimeInterval(week)
        let good = Array(common.dropFirst()) + ["replacement.example"]
        let refused = [
            Data(), Data([0xff]), list(["junk / URL"] + common, version: nextVersion),
            list(common + [common[0]], version: nextVersion),
            list(common, version: nextVersion, count: common.count + 1),
            list(Array(common.prefix(18)), version: nextVersion),
            list(Array(common.prefix(10)), version: nextVersion),
            list(common + (1...7).map { "spike-\($0).example" }, version: nextVersion),
            list(good, version: firstVersion), list(common, version: "2026.1123.1200.00"),
        ]
        func expectUnchanged() throws {
            XCTAssertEqual(try Data(contentsOf: paths.policy), policy)
            XCTAssertEqual(try Data(contentsOf: paths.communityListStatus), status)
        }
        for body in refused {
            http.respond(body)
            XCTAssertThrowsError(try manager.refreshCommunityList(from: http.source, now: { due }))
            try expectUnchanged()
        }
        let oversized = Data(repeating: 65, count: CommunityListSource.maximumBytes + 1)
        http.respond(oversized)
        XCTAssertThrowsError(try manager.refreshCommunityList(from: http.source, now: { due }))
        try expectUnchanged()
        let chunked = "HTTP/1.1 200 OK\r\nContent-Type: text/plain\r\nTransfer-Encoding: chunked\r\nConnection: close\r\n\r\n"
        http.setResponse(Data((chunked + String(oversized.count, radix: 16) + "\r\n").utf8) +
                         oversized + Data("\r\n0\r\n\r\n".utf8))
        XCTAssertThrowsError(try manager.refreshCommunityList(from: http.source, now: { due }))
        try expectUnchanged()

        let redirectTarget = try CommunityHTTP(list(good, version: nextVersion))
        defer { redirectTarget.stop() }
        http.setResponse(Data("HTTP/1.1 302 Found\r\nLocation: \(redirectTarget.source.url)\r\nContent-Length: 0\r\n\r\n".utf8))
        XCTAssertThrowsError(try manager.refreshCommunityList(from: http.source, now: { due }))
        XCTAssertTrue(redirectTarget.requests.isEmpty)
        try expectUnchanged()
        http.stop()
        XCTAssertThrowsError(try manager.refreshCommunityList(from: http.source, now: { due }))
        try expectUnchanged()

        try manager.refreshCommunityList(from: redirectTarget.source, now: { due })
        XCTAssertEqual(try manager.siteBlocks().adult, good.sorted())
        XCTAssertEqual(try manager.status().communityList, CommunityListStatus(lastSuccess: due, sourceVersion: nextVersion))
    }
}

final class CommunityHTTP {
    private final class Replies {
        var requests: [String] = []
        var response = Data()
        var onRequest: () -> Void = {}
    }
    private let replies = Replies()
    private let server: CommunityLoopback

    init(_ body: Data) throws {
        server = try CommunityLoopback(tcp: true) { [replies] data in
            replies.requests.append(String(decoding: data, as: UTF8.self))
            replies.onRequest()
            return replies.response
        }
        respond(body)
    }

    var requests: [String] { server.queue.sync { replies.requests } }
    var source: CommunityListSource {
        CommunityListSource(url: URL(string: "http://127.0.0.1:\(server.port.rawValue)/community")!, minimumDomainCount: 18)
    }

    func respond(_ body: Data, onRequest: @escaping () -> Void = {}) {
        let header = "HTTP/1.1 200 OK\r\nContent-Type: text/plain\r\nContent-Length: \(body.count)\r\nConnection: close\r\n\r\n"
        setResponse(Data(header.utf8) + body, onRequest: onRequest)
    }

    func setResponse(_ response: Data, onRequest: @escaping () -> Void = {}) {
        server.queue.sync { replies.response = response; replies.onRequest = onRequest }
    }

    func stop() { server.stop() }
}

final class CommunityLoopback {
    let queue = DispatchQueue(label: "io.clearpath.tests.community-fixture")
    let port: NWEndpoint.Port
    private let listener: NWListener

    init(tcp: Bool, reply: @escaping (Data) -> Data) throws {
        let parameters: NWParameters = tcp ? .tcp : .udp
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        listener = try NWListener(using: parameters)
        let ready = DispatchSemaphore(value: 0)
        listener.stateUpdateHandler = { state in
            if case .ready = state { ready.signal() }
            if case .failed = state { ready.signal() }
        }
        listener.newConnectionHandler = { [queue] connection in
            connection.start(queue: queue)
            if !tcp {
                connection.receiveMessage { data, _, _, _ in
                    guard let data else { connection.cancel(); return }
                    connection.send(content: reply(data), completion: .contentProcessed { _ in connection.cancel() })
                }
            } else {
                Self.receiveHTTP(connection, reply: reply)
            }
        }
        listener.start(queue: queue)
        guard ready.wait(timeout: .now() + 3) == .success, let port = listener.port else {
            listener.cancel()
            throw ServiceError.failed("The loopback fixture could not listen.")
        }
        self.port = port
    }

    private static func receiveHTTP(_ connection: NWConnection, received: Data = Data(),
                                    reply: @escaping (Data) -> Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 8192) { data, _, ended, error in
            guard let data, error == nil else { connection.cancel(); return }
            let request = received + data
            if request.suffix(4).elementsEqual("\r\n\r\n".utf8) {
                connection.send(content: reply(request), completion: .contentProcessed { _ in connection.cancel() })
            } else if request.count < 8192 && !ended {
                receiveHTTP(connection, received: request, reply: reply)
            } else {
                connection.cancel()
            }
        }
    }

    func stop() { queue.sync { listener.cancel() } }
}
