import Foundation
import Network
@preconcurrency import NetworkExtension
import OSLog
import ClearpathCore
import ClearpathNetwork

@objc(ClearpathDNSProxyProvider)
final class DNSProxyProvider: NEDNSProxyProvider, NEAppProxyUDPFlowHandling {
    private let queue = DispatchQueue(label: "io.clearpath.provider")
    private let lock = NSLock()
    private var resolver: Resolver?
    private var sessions: [UUID: FlowSession] = [:]
    private let log = Logger(subsystem: "io.clearpath.Clearpath.DNSProxy", category: "lifecycle")

    override func startProxy(options: [String: Any]? = nil, completionHandler: @escaping (Error?) -> Void) {
        do {
            guard let config = options,
                  config["schema"] as? Int == 1, let data = config["policy"] as? Data,
                  let digest = config["policySHA256"] as? String else { throw LifecycleError.invalidConfiguration }
            try DNSProxyConfiguration(enabled: true, policyData: data).validate()
            let policy = try Policy(data: data)
            guard policy.digest == digest else { throw LifecycleError.invalidConfiguration }
            lock.lock(); resolver = Resolver(policy: policy); lock.unlock()
            log.notice("Provider started with validated local policy")
            completionHandler(nil)
        } catch {
            log.error("Provider start rejected invalid configuration")
            completionHandler(NSError(domain: "io.clearpath.configuration", code: 1))
        }
    }
    override func stopProxy(with reason: NEProviderStopReason, completionHandler: @escaping () -> Void) {
        lock.lock(); resolver = nil; let active = Array(sessions.values); sessions.removeAll(); lock.unlock()
        queue.async {
            for session in active { session.close() }
            self.log.notice("Provider stopped")
            completionHandler()
        }
    }
    override func handleNewFlow(_ flow: NEAppProxyFlow) -> Bool { accept(flow) }
    func handleNewUDPFlow(_ flow: NEAppProxyUDPFlow, initialRemoteFlowEndpoint remoteEndpoint: Network.NWEndpoint) -> Bool {
        accept(flow)
    }
    private func accept(_ flow: NEAppProxyFlow) -> Bool {
        lock.lock()
        guard let resolver, sessions.count < 128,
              flow is NEAppProxyTCPFlow || flow is NEAppProxyUDPFlow else { lock.unlock(); return false }
        let id = UUID()
        let session = FlowSession(flow: flow, resolver: resolver, queue: queue) { [weak self] in
            guard let self else { return }
            self.lock.lock(); self.sessions.removeValue(forKey: id); self.lock.unlock()
        }
        sessions[id] = session
        lock.unlock()
        session.start()
        return true // returning false drops a DNS Proxy flow; it is not passthrough
    }
}

/// A flow is retained until close, with a fixed idle deadline and read/write
/// backpressure. UDP datagrams in a batch and TCP requests are processed in order.
private final class FlowSession: @unchecked Sendable {
    let flow: NEAppProxyFlow
    let resolver: Resolver
    let queue: DispatchQueue
    let done: () -> Void
    var task: Task<Void, Never>?
    var timer: DispatchSourceTimer?
    var closed = false
    var framer = DNSStream()

    init(flow: NEAppProxyFlow, resolver: Resolver, queue: DispatchQueue, done: @escaping () -> Void) {
        self.flow = flow; self.resolver = resolver; self.queue = queue; self.done = done
    }
    func start() {
        queue.async {
            guard !self.closed else { return }
            self.touch()
            self.flow.open(withLocalFlowEndpoint: nil) { error in
                self.queue.async {
                    if error != nil { self.close(); return }
                    self.read()
                }
            }
        }
    }
    func stop() { queue.async { self.close() } }
    func touch() {
        if timer == nil {
            let timer = DispatchSource.makeTimerSource(queue: queue)
            timer.setEventHandler { [weak self] in self?.close() }
            timer.schedule(deadline: .now() + 30)
            timer.resume()
            self.timer = timer
        } else {
            timer?.schedule(deadline: .now() + 30)
        }
    }
    func close() {
        guard !closed else { return }; closed = true
        timer?.cancel(); timer = nil
        task?.cancel(); task = nil
        flow.closeReadWithError(nil); flow.closeWriteWithError(nil)
        done()
    }
    func upstream(_ endpoint: Network.NWEndpoint) -> NetworkUpstream {
        NetworkUpstream(endpoint: endpoint, interface: flow.interface) { [flow] parameters in
            flow.setMetadata(on: parameters)
        }
    }
    func read() {
        guard !closed else { return }
        if let udp = flow as? NEAppProxyUDPFlow {
            udp.readDatagrams { datagrams, error in
                self.queue.async {
                    guard !self.closed else { return }
                    guard error == nil, let datagrams, !datagrams.isEmpty, datagrams.count <= 64,
                          datagrams.reduce(0, { $0 + $1.0.count }) <= 262144 else { self.close(); return }
                    self.touch()
                    self.task = Task {
                        var output: [(Data, Network.NWEndpoint)] = []
                        for (data, endpoint) in datagrams {
                            if Task.isCancelled { return }
                            let answer = await self.resolver.resolve(Array(data), tcp: false, upstream: self.upstream(endpoint))
                            output.append((Data(answer), endpoint))
                        }
                        let responses = output
                        self.queue.async {
                            guard !self.closed else { return }
                            udp.writeDatagrams(responses) { error in
                                self.queue.async {
                                    if error != nil { self.close() } else { self.read() }
                                }
                            }
                        }
                    }
                }
            }
        } else if let tcp = flow as? NEAppProxyTCPFlow {
            tcp.readData { data, error in
                self.queue.async {
                    guard !self.closed else { return }
                    guard error == nil, let data, !data.isEmpty else { self.close(); return }
                    do {
                        self.touch()
                        let packets = try self.framer.append(Array(data))
                        guard packets.count <= 64 else { self.close(); return }
                        self.task = Task {
                            var output = Data()
                            for packet in packets {
                                if Task.isCancelled { return }
                                let answer = await self.resolver.resolve(packet, tcp: true, upstream: self.upstream(tcp.remoteFlowEndpoint))
                                guard let framed = try? DNSStream.frame(answer) else { self.stop(); return }
                                output.append(contentsOf: framed)
                                guard output.count <= 262144 else { self.stop(); return }
                            }
                            let responses = output
                            self.queue.async {
                                guard !self.closed else { return }
                                if responses.isEmpty { self.read(); return }
                                tcp.write(responses) { error in
                                    self.queue.async {
                                        if error != nil { self.close() } else { self.read() }
                                    }
                                }
                            }
                        }
                    } catch { self.close() }
                }
            }
        }
    }
}
