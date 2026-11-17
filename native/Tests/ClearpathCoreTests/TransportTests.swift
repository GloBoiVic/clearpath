import XCTest
import Network
import ClearpathCore
import ClearpathNetwork

/// Real Network.framework sockets, bound exclusively to IPv4/IPv6 loopback.
/// This bypasses the unactivated NE flow adapter and never changes system DNS.
private final class LocalDNSServer: @unchecked Sendable {
    let listener: NWListener
    let tcp: Bool
    let queue = DispatchQueue(label: "io.clearpath.tests.listener")
    var connections: [NWConnection] = []
    let silent: Bool
    init(tcp: Bool, ipv6: Bool = false, silent: Bool = false) throws {
        self.tcp = tcp; self.silent = silent
        let parameters: NWParameters = tcp ? .tcp : .udp
        parameters.requiredLocalEndpoint = .hostPort(host: NWEndpoint.Host(ipv6 ? "::1" : "127.0.0.1"), port: .any)
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
        query.response(answers: [DNSRecord(name: query.name, type: 1, data: [192,0,2,42])])
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
    func testHostnameUpstreamRejectedToPreventRecursion() async throws {
        do {
            _ = try await NetworkUpstream(endpoint: .hostPort(host: "resolver.example", port: 53)).exchange(DNSMessage.query("example.com", type: 1), tcp: false)
            XCTFail()
        } catch { XCTAssertTrue(error is DNSError) }
    }
}
