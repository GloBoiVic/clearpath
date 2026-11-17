import Foundation
import Network
import ClearpathCore

/// One bounded transaction per NWConnection, to the resolver endpoint on the original
/// flow. Never selects a public resolver, performs OS hostname resolution, or caches.
public struct NetworkUpstream: DNSUpstream, @unchecked Sendable {
    private let endpoint: NWEndpoint
    private let interface: NWInterface?
    private let configure: (NWParameters) -> Void
    private let timeout: TimeInterval

    public init(endpoint: NWEndpoint, interface: NWInterface? = nil, timeout: TimeInterval = 4,
                configure: @escaping (NWParameters) -> Void = { _ in }) {
        self.endpoint = endpoint; self.interface = interface; self.timeout = timeout; self.configure = configure
    }

    public func exchange(_ packet: [UInt8], tcp: Bool) async throws -> [UInt8] {
        guard case .hostPort(let host, _) = endpoint else { throw DNSError.unsupported }
        switch host {
        case .ipv4, .ipv6: break
        case .name: throw DNSError.unsupported // no bootstrap DNS/recursion
        @unknown default: throw DNSError.unsupported
        }
        let parameters: NWParameters = tcp ? .tcp : .udp
        configure(parameters)
        if let interface { parameters.requiredInterface = interface }
        let transaction = Transaction(connection: NWConnection(to: endpoint, using: parameters), tcp: tcp, timeout: timeout)
        return try await withTaskCancellationHandler(operation: {
            try await transaction.run(packet)
        }, onCancel: { transaction.cancel() })
    }
}

// All mutable connection state is confined to queue. Cancellation and timeout have
// exactly one completion path and release the connection and continuation.
private final class Transaction: @unchecked Sendable {
    private let queue = DispatchQueue(label: "io.clearpath.dns.transaction")
    private let connection: NWConnection
    private let tcp: Bool
    private let timeout: TimeInterval
    private var continuation: CheckedContinuation<[UInt8], Error>?
    private var finished = false
    private var cancelled = false
    private var stream = DNSStream()
    private var timer: DispatchSourceTimer?

    init(connection: NWConnection, tcp: Bool, timeout: TimeInterval) {
        self.connection = connection; self.tcp = tcp; self.timeout = timeout
    }
    func run(_ packet: [UInt8]) async throws -> [UInt8] {
        try await withCheckedThrowingContinuation { continuation in
            queue.async { [self] in
                self.continuation = continuation
                if self.cancelled { self.finish(.failure(CancellationError())); return }
                let timer = DispatchSource.makeTimerSource(queue: self.queue)
                timer.setEventHandler { [weak self] in self?.finish(.failure(DNSError.timeout)) }
                timer.schedule(deadline: .now() + self.timeout)
                self.timer = timer
                timer.resume()
                self.connection.stateUpdateHandler = { [weak self] state in
                    guard let self, !self.finished else { return }
                    switch state {
                    case .ready: self.send(packet)
                    case .failed(let error): self.finish(.failure(error))
                    case .cancelled: self.finish(.failure(CancellationError()))
                    default: break // .waiting is bounded by the transaction deadline
                    }
                }
                self.connection.start(queue: self.queue)
            }
        }
    }
    func cancel() {
        queue.async {
            self.cancelled = true
            if self.continuation != nil { self.finish(.failure(CancellationError())) }
        }
    }
    private func finish(_ result: Result<[UInt8], Error>) {
        guard !finished else { return }
        finished = true
        timer?.cancel(); timer = nil
        connection.stateUpdateHandler = nil
        connection.cancel()
        let callback = continuation; continuation = nil
        callback?.resume(with: result)
    }
    private func send(_ packet: [UInt8]) {
        do {
            let data = Data(try tcp ? DNSStream.frame(packet) : packet)
            connection.send(content: data, completion: .contentProcessed { [weak self] error in
                guard let self, !self.finished else { return }
                if let error { self.finish(.failure(error)); return }
                self.receive()
            })
        } catch { finish(.failure(error)) }
    }
    private func receive() {
        if tcp {
            connection.receive(minimumIncompleteLength: 1, maximumLength: 65537) { [weak self] data, _, complete, error in
                guard let self, !self.finished else { return }
                do {
                    if let data {
                        let messages = try self.stream.append(Array(data))
                        if let first = messages.first { self.finish(.success(first)); return }
                    }
                    if let error { throw error }
                    if complete { throw DNSError.closed }
                    self.receive()
                } catch { self.finish(.failure(error)) }
            }
        } else {
            connection.receiveMessage { [weak self] data, _, _, error in
                guard let self, !self.finished else { return }
                if let error { self.finish(.failure(error)) }
                else if let data { self.finish(.success(Array(data))) }
                else { self.finish(.failure(DNSError.closed)) }
            }
        }
    }
}
