import XCTest
import Network
import ClearpathCore
import ClearpathNetwork
@testable import ClearpathService

/// Real Network.framework sockets, bound exclusively to IPv4/IPv6 loopback.
/// This bypasses the unactivated NE flow adapter and never changes system DNS.
private final class LocalDNSServer: @unchecked Sendable {
    let listener: NWListener
    let tcp: Bool
    let queue = DispatchQueue(label: "io.clearpath.tests.listener")
    var connections: [NWConnection] = []
    let silent: Bool
    let answerAddress: [UInt8]
    let truncate: Bool
    init(tcp: Bool, ipv6: Bool = false, silent: Bool = false, answerAddress: [UInt8] = [192, 0, 2, 42],
         port: NWEndpoint.Port = .any, truncate: Bool = false) throws {
        self.tcp = tcp; self.silent = silent
        self.answerAddress = answerAddress
        self.truncate = truncate
        let parameters: NWParameters = tcp ? .tcp : .udp
        parameters.requiredLocalEndpoint = .hostPort(host: NWEndpoint.Host(ipv6 ? "::1" : "127.0.0.1"), port: port)
        listener = try NWListener(using: parameters)
        let ready = DispatchSemaphore(value: 0)
        listener.stateUpdateHandler = { state in
            if case .ready = state { ready.signal() }
            if case .failed = state { ready.signal() }
        }
        listener.newConnectionHandler = { [weak self] connection in
            guard let self else { connection.cancel(); return }
            self.connections.append(connection)
            connection.start(queue: self.queue)
            if self.silent { return }
            if tcp { self.receiveTCP(connection, stream: DNSStream()) }
            else {
                connection.receiveMessage { data, _, _, _ in
                    guard let data, let query = try? DNSMessage(Array(data)) else { return }
                    connection.send(content: Data(self.answer(query)), completion: .contentProcessed { _ in })
                }
            }
        }
        listener.start(queue: queue)
        guard ready.wait(timeout: .now() + 3) == .success, listener.port != nil else {
            listener.cancel(); throw DNSError.timeout
        }
    }
    func answer(_ query: DNSMessage) -> [UInt8] {
        if truncate { return query.response(truncated: true) }
        return query.response(answers: [DNSRecord(name: query.name, type: 1, data: answerAddress)])
    }
    func receiveTCP(_ connection: NWConnection, stream: DNSStream) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65537) { data, _, _, _ in
            guard let data else { return }
            var stream = stream
            guard let messages = try? stream.append(Array(data)) else { return }
            guard let packet = messages.first, let query = try? DNSMessage(packet), let response = try? DNSStream.frame(self.answer(query)) else {
                self.receiveTCP(connection, stream: stream); return
            }
            // Deliberately split the length prefix from the rest of the frame.
            connection.send(content: Data(response.prefix(1)), completion: .contentProcessed { _ in
                connection.send(content: Data(response.dropFirst()), completion: .contentProcessed { _ in })
            })
        }
    }
    var port: NWEndpoint.Port { listener.port! }
    func stop() {
        queue.sync { listener.cancel(); connections.forEach { $0.cancel() }; connections.removeAll() }
    }
}

final class TransportTests: XCTestCase {
    func testRealUDPAndTCPAndIPv6() async throws {
        for tcp in [false,true] {
            for ipv6 in [false,true] {
                let server = try LocalDNSServer(tcp: tcp, ipv6: ipv6)
                defer { server.stop() }
                let remote = NetworkUpstream(endpoint: .hostPort(host: NWEndpoint.Host(ipv6 ? "::1" : "127.0.0.1"), port: server.port))
                let request = DNSMessage.query("github.com", type: 1)
                let response = try DNSMessage(await remote.exchange(request, tcp: tcp))
                try response.validateResponse(to: DNSMessage(request))
                XCTAssertEqual(response.answers[0].data, [192,0,2,42])
            }
        }
    }
    func testTransactionDeadlineAndCancellation() async throws {
        let server = try LocalDNSServer(tcp: false, silent: true)
        defer { server.stop() }
        let endpoint = NWEndpoint.hostPort(host: "127.0.0.1", port: server.port)
        let query = DNSMessage.query("example.com", type: 1)
        do {
            _ = try await NetworkUpstream(endpoint: endpoint, timeout: 0.05).exchange(query, tcp: false)
            XCTFail("silent server must time out")
        } catch { XCTAssertTrue(error is DNSError) }
        let task = Task { try await NetworkUpstream(endpoint: endpoint).exchange(query, tcp: false) }
        task.cancel()
        do { _ = try await task.value; XCTFail("cancelled transaction must complete") }
        catch { XCTAssertTrue(error is CancellationError) }
    }
    func testFilterResolvesOnlyWhenTheLoopbackServerAnswersALookup() throws {
        let answering = try LocalDNSServer(tcp: false)
        defer { answering.stop() }
        XCTAssertTrue(MacSystem().filterResolves(port: answering.port.rawValue))
        let silent = try LocalDNSServer(tcp: false, silent: true)
        defer { silent.stop() }
        XCTAssertFalse(MacSystem().filterResolves(port: silent.port.rawValue))
    }
    func testHostnameUpstreamRejectedToPreventRecursion() async throws {
        do {
            _ = try await NetworkUpstream(endpoint: .hostPort(host: "resolver.example", port: 53)).exchange(DNSMessage.query("example.com", type: 1), tcp: false)
            XCTFail()
        } catch { XCTAssertTrue(error is DNSError) }
    }

    func testNetworkDNSRoutesPublicAndPrivateQueriesToDifferentLoopbackFixtures() async throws {
        for tcp in [false, true] {
            let standard = try LocalDNSServer(tcp: tcp)
            defer { standard.stop() }
            let privateDNS = try LocalDNSServer(tcp: tcp, ipv6: true, answerAddress: [192, 0, 2, 43])
            defer { privateDNS.stop() }
            let record = RecoveryRecord(createdAt: "", services: [], upstream: "192.0.2.1",
                                        upstreamPort: standard.port.rawValue, resolverState: "")
            let upstream = NetworkDNS(record: record, listenPort: 53, timeout: 0.5) {
                ["State:/Network/Global/DNS": ["ServerAddresses": ["127.0.0.1", "::ffff:127.0.0.1"]],
                 "State:/Network/Global/IPv4": ["PrimaryService": "ethernet"],
                 "State:/Network/Service/ethernet/DNS": ["ServerAddresses": ["127.0.0.1"]],
                 "State:/Network/Service/tunnel/DNS": ["SupplementalMatchDomains": ["vpn.example"],
                                                      "ServerAddresses": ["::1"], "ServerPort": Int(privateDNS.port.rawValue)],
                 "State:/Network/Service/broken/DNS": ["SupplementalMatchDomains": ["broken.example"],
                                                      "ServerAddresses": ["::ffff:127.0.0.1"], "ServerPort": 53]]
            }
            let standardQuery = DNSMessage.query("public.example", type: 1)
            let publicResponse = try DNSMessage(await upstream.exchange(standardQuery, tcp: tcp))
            XCTAssertEqual(publicResponse.answers.first?.data, [192, 0, 2, 42])
            let privateQuery = DNSMessage.query("app.vpn.example", type: 1)
            let privateResponse = try DNSMessage(await upstream.exchange(privateQuery, tcp: tcp))
            XCTAssertEqual(privateResponse.answers.first?.data, [192, 0, 2, 43])
            do {
                _ = try await upstream.exchange(DNSMessage.query("app.broken.example", type: 1), tcp: tcp)
                XCTFail("a scope pointing back to the listener must not use the default")
            } catch DNSError.closed {}
        }
    }

    func testAVPNDefaultResolverIsSkippedForOrdinaryNamesSoTheyReachTheNetworkResolver() async throws {
        // #73: the VPN would send these names straight back to the filter.
        let router = try LocalDNSServer(tcp: false)
        defer { router.stop() }
        let vpn = try LocalDNSServer(tcp: false, ipv6: true, answerAddress: [100, 64, 0, 7])
        defer { vpn.stop() }
        let record = RecoveryRecord(createdAt: "", services: [], upstream: "192.0.2.1",
                                    upstreamPort: router.port.rawValue, resolverState: "")
        let vpnScope: [String: Any] = ["ServerAddresses": ["::1"], "ServerPort": Int(vpn.port.rawValue)]
        let upstream = NetworkDNS(record: record, listenPort: 53, timeout: 0.5) {
            ["State:/Network/Global/DNS": vpnScope,
             "State:/Network/Global/IPv4": ["PrimaryService": "ethernet"],
             "State:/Network/Service/ethernet/DNS": ["ServerAddresses": ["127.0.0.1"]],
             "State:/Network/Service/tunnel/DNS": vpnScope.merging(["SupplementalMatchDomains": ["", "tailnet.example"]]) { $1 }]
        }
        let ordinary = try DNSMessage(await upstream.exchange(DNSMessage.query("public.example", type: 1), tcp: false))
        XCTAssertEqual(ordinary.answers.first?.data, [192, 0, 2, 42])
        let vpnName = try DNSMessage(await upstream.exchange(DNSMessage.query("host.tailnet.example", type: 1), tcp: false))
        XCTAssertEqual(vpnName.answers.first?.data, [100, 64, 0, 7])
    }

    func testTheNetworkResolverCheckAsksTheRecordedServiceNotAVPNRoute() throws {
        let router = try LocalDNSServer(tcp: false)
        defer { router.stop() }
        let silent = try LocalDNSServer(tcp: false, silent: true)
        defer { silent.stop() }
        // The VPN is the primary service and swallows everything; Ethernet is what Clearpath recorded.
        func network(_ port: NWEndpoint.Port, ethernetActive: Bool = true) -> NetworkDNS {
            let record = RecoveryRecord(createdAt: "", services: [ServiceDNS(name: "Ethernet", servers: [], id: "ethernet")],
                                        upstream: "192.0.2.1", upstreamPort: port.rawValue, resolverState: "")
            return NetworkDNS(record: record, listenPort: 53, timeout: 0.5) {
                var state: [String: [String: Any]] = [
                    "State:/Network/Global/DNS": ["ServerAddresses": ["::1"], "ServerPort": Int(silent.port.rawValue)],
                    "State:/Network/Global/IPv4": ["PrimaryService": "vpn"],
                    "State:/Network/Service/vpn/IPv4": ["InterfaceName": "lo0"],
                    "State:/Network/Service/vpn/DNS": ["ServerAddresses": ["::1"], "SupplementalMatchDomains": [""]],
                    "State:/Network/Service/ethernet/DNS": ["ServerAddresses": ["127.0.0.1"]],
                ]
                if ethernetActive { state["State:/Network/Service/ethernet/IPv4"] = ["InterfaceName": "lo0"] }
                return state
            }
        }
        XCTAssertTrue(MacSystem.resolves(through: network(router.port).networkResolver()))
        XCTAssertFalse(MacSystem.resolves(through: network(silent.port).networkResolver()))
        XCTAssertFalse(MacSystem.resolves(through: network(router.port, ethernetActive: false).networkResolver()))
    }

    func testPrivateTCPRetryUsesTheSameScopeWhenTheNetworkChanges() async throws {
        let standard = try LocalDNSServer(tcp: true)
        defer { standard.stop() }
        let privateUDP = try LocalDNSServer(tcp: false, ipv6: true, truncate: true)
        defer { privateUDP.stop() }
        let privateTCP = try LocalDNSServer(tcp: true, ipv6: true, answerAddress: [192, 0, 2, 43], port: privateUDP.port)
        defer { privateTCP.stop() }
        let record = RecoveryRecord(createdAt: "", services: [], upstream: "192.0.2.1",
                                    upstreamPort: standard.port.rawValue, resolverState: "")
        var snapshots = 0
        let upstream = NetworkDNS(record: record, listenPort: 53, timeout: 0.5) {
            snapshots += 1
            var state: [String: [String: Any]] = [
                "State:/Network/Global/IPv4": ["PrimaryService": "ethernet"],
                "State:/Network/Service/ethernet/DNS": ["ServerAddresses": ["127.0.0.1"]],
            ]
            if snapshots == 1 {
                state["State:/Network/Service/tunnel/DNS"] = [
                    "SupplementalMatchDomains": ["vpn.example"], "ServerAddresses": ["::1"],
                    "ServerPort": Int(privateUDP.port.rawValue),
                ]
            }
            return state
        }
        let policy = try Policy(data: Data(#"{"adult":[],"custom":[],"allow":[],"safesearch":{}}"#.utf8))
        let query = DNSMessage.query("app.vpn.example", type: 1)
        let reply = try DNSMessage(await Resolver(policy: policy).resolve(query, tcp: false, upstream: upstream))
        XCTAssertEqual(reply.answers.first?.data, [192, 0, 2, 43])
        XCTAssertEqual(snapshots, 1)
    }
}
