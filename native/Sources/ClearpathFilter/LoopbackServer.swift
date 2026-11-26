import Foundation
import Network
import ClearpathCore

/// UDP and TCP DNS listeners on one loopback address and port. Connection counts,
/// in-flight lookups, TCP buffering and idle time are all bounded. Nothing here logs
/// client addresses or query names.
final class LoopbackServer: @unchecked Sendable {
    static let maxConnections = 64
    static let maxInFlight = 128
    /// A connection with no query being answered is closed after this long.
    let idleTimeout: TimeInterval

    private let queue = DispatchQueue(label: "io.clearpath.filter.server")
    private var resolver: Resolver
    private let upstream: any DNSUpstream
    private let onBlocked: @Sendable () -> Void
    private var listeners: [NWListener] = []
    private var connections: [ObjectIdentifier: Client] = [:]
    private var inFlight = 0

    init(policy: Policy, upstream: any DNSUpstream, idleTimeout: TimeInterval,
         onBlocked: @escaping @Sendable () -> Void = {}) {
        self.resolver = Resolver(policy: policy, onBlocked: onBlocked)
        self.upstream = upstream; self.idleTimeout = idleTimeout
        self.onBlocked = onBlocked
    }

    func updatePolicy(_ policy: Policy) {
        queue.sync { resolver = Resolver(policy: policy, onBlocked: onBlocked) }
    }

    /// Binds UDP then TCP on the same port. With port 0 the UDP port is picked by the
    /// system and the pair is retried if TCP cannot take the same number.
    func start(host: String, port: UInt16) throws -> UInt16 {
        for _ in 0..<8 {
            let udp = try bind(host: host, port: port, tcp: false)
            guard let actual = udp.port else { udp.cancel(); throw DNSError.closed }
            do {
                let tcp = try bind(host: host, port: actual.rawValue, tcp: true)
                listeners = [udp, tcp]
                return actual.rawValue
            } catch {
                udp.cancel()
                if port != 0 { throw error }
            }
        }
        throw DNSError.closed
    }

    func stop() {
        queue.sync {
            listeners.forEach { $0.cancel() }
            connections.values.forEach { $0.connection.cancel() }
            connections.removeAll()
        }
    }

    private func bind(host: String, port: UInt16, tcp: Bool) throws -> NWListener {
        let parameters: NWParameters = tcp ? .tcp : .udp
        guard let localPort = NWEndpoint.Port(rawValue: port) else { throw DNSError.unsupported }
        parameters.requiredLocalEndpoint = .hostPort(host: NWEndpoint.Host(host), port: localPort)
        let listener = try NWListener(using: parameters)
        let ready = DispatchSemaphore(value: 0)
        var failed = false
        listener.stateUpdateHandler = { state in
            switch state {
            case .ready: ready.signal()
            case .failed, .cancelled: failed = true; ready.signal()
            default: break
            }
        }
        listener.newConnectionHandler = { [weak self] connection in self?.accept(connection, tcp: tcp) }
        listener.start(queue: queue)
        guard ready.wait(timeout: .now() + 3) == .success, !queue.sync(execute: { failed }), listener.port != nil else {
            listener.cancel(); throw DNSError.closed
        }
        listener.stateUpdateHandler = { state in
            // A listener that fails after start leaves the port unserved: exit so the
            // supervisor restarts the service instead of silently running deaf.
            if case .failed = state { FileHandle.standardError.write(Data("Listener failed; exiting\n".utf8)); exit(1) }
        }
        return listener
    }

    // MARK: Connections (all on queue)

    private final class Client {
        let connection: NWConnection
        let tcp: Bool
        var stream = DNSStream()
        var timer: DispatchSourceTimer?
        var busy = 0  // lookups in progress (each bounded by the upstream deadline); idle never closes these
        var lastActive = DispatchTime.now()
        init(connection: NWConnection, tcp: Bool) { self.connection = connection; self.tcp = tcp }
    }

    private func accept(_ connection: NWConnection, tcp: Bool) {
        // A full table makes room by closing the longest-idle client. A resolver in front of the
        // filter, such as a VPN's (#73), sends each lookup from a new port, and those answered
        // clients would otherwise hold every slot for the idle timeout.
        if connections.count >= Self.maxConnections {
            guard let idle = connections.filter({ $0.value.busy == 0 }).min(by: { $0.value.lastActive < $1.value.lastActive }) else {
                connection.cancel(); return
            }
            close(idle.key)
        }
        let client = Client(connection: connection, tcp: tcp)
        let key = ObjectIdentifier(connection)
        connections[key] = client
        connection.stateUpdateHandler = { [weak self] state in
            switch state {
            case .failed, .cancelled: self?.close(key)
            default: break
            }
        }
        connection.start(queue: queue)
        touch(client, key: key)
        tcp ? receiveTCP(client, key: key) : receiveUDP(client, key: key)
    }

    private func close(_ key: ObjectIdentifier) {
        guard let client = connections.removeValue(forKey: key) else { return }
        client.timer?.cancel(); client.timer = nil
        client.connection.stateUpdateHandler = nil
        client.connection.cancel()
    }

    private func touch(_ client: Client, key: ObjectIdentifier) {
        client.lastActive = DispatchTime.now()
        client.timer?.cancel()
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.setEventHandler { [weak self] in
            guard let self, let client = self.connections[key] else { return }
            if client.busy > 0 { self.touch(client, key: key) } else { self.close(key) }
        }
        timer.schedule(deadline: .now() + idleTimeout)
        timer.resume()
        client.timer = timer
    }

    private func receiveUDP(_ client: Client, key: ObjectIdentifier) {
        client.connection.receiveMessage { [weak self] data, _, _, error in
            guard let self, self.connections[key] != nil else { return }
            if error != nil { self.close(key); return }
            if let data {
                self.touch(client, key: key)
                self.answer(Array(data), tcp: false, client: client, key: key) { answer in
                    client.connection.send(content: Data(answer), completion: .contentProcessed { _ in })
                }
            }
            self.receiveUDP(client, key: key)
        }
    }

    private func receiveTCP(_ client: Client, key: ObjectIdentifier) {
        client.connection.receive(minimumIncompleteLength: 1, maximumLength: 65537) { [weak self] data, _, complete, error in
            guard let self, self.connections[key] != nil else { return }
            let messages: [[UInt8]]
            do { messages = try data.map { try client.stream.append(Array($0)) } ?? [] }
            catch { self.close(key); return }  // bad framing or oversized buffer
            // Messages on one connection are answered in order, then reading resumes.
            self.answerInOrder(messages, client: client, key: key) { [weak self] in
                guard let self, self.connections[key] != nil else { return }
                if error != nil || complete {
                    // Close only after replies are written; RFC 7766 lets a client half-close.
                    client.connection.send(content: nil, isComplete: true, completion: .contentProcessed { [weak self] _ in self?.close(key) })
                } else {
                    self.receiveTCP(client, key: key)
                }
            }
        }
    }

    private func answerInOrder(_ messages: [[UInt8]], client: Client, key: ObjectIdentifier, then done: @escaping () -> Void) {
        guard let first = messages.first else { done(); return }
        answer(first, tcp: true, client: client, key: key) { [weak self] answer in
            guard let self else { return }
            guard let frame = try? DNSStream.frame(answer) else { self.close(key); return }
            client.connection.send(content: Data(frame), completion: .contentProcessed { [weak self] error in
                guard let self else { return }
                if error != nil { self.close(key); return }
                self.answerInOrder(Array(messages.dropFirst()), client: client, key: key, then: done)
            })
        }
    }

    /// Resolves off the queue and delivers the answer back on it, only while the client is
    /// still connected. The client counts as busy only during the lookup: once the answer
    /// is handed to the connection, a client that stops reading is idle and gets closed.
    /// Over the in-flight bound a lookup is refused with SERVFAIL rather than queued.
    private func answer(_ packet: [UInt8], tcp: Bool, client: Client, key: ObjectIdentifier, deliver: @escaping ([UInt8]) -> Void) {
        guard inFlight < Self.maxInFlight else {
            deliver((try? DNSMessage(packet))?.response(code: 2) ?? DNSMessage.error(for: packet, code: 2)); return
        }
        inFlight += 1
        client.busy += 1
        let resolver = resolver, upstream = upstream
        Task { [weak self] in
            let answer = await resolver.resolve(packet, tcp: tcp, upstream: upstream)
            self?.queue.async { [weak self] in
                guard let self else { return }
                self.inFlight -= 1
                client.busy -= 1
                guard self.connections[key] != nil else { return }
                self.touch(client, key: key)  // the idle clock restarts when the answer is ready
                deliver(answer)
            }
        }
    }
}
