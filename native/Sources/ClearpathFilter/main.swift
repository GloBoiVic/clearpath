import Foundation
import Network
import ClearpathCore
import ClearpathNetwork
import ClearpathService

// Loopback DNS filter: the shipping Swift engine behind a loopback UDP/TCP listener.
// It reads the installed service's DNS routing state or forwards to a fixed upstream IP.
// As the LaunchDaemon (clearpath-service install) it binds port 53 as root, then drops to --user.

let usage = """
usage: clearpath-filter --policy FILE (--upstream IP | --network-dns RECOVERY_FILE) [--upstream-port N] [--listen 127.0.0.1|::1] [--port N] [--timeout SECONDS] [--idle-timeout SECONDS] [--user NAME]
  --port 0 picks a free port; otherwise 53 or 1024-65535. The listener is loopback only.
  --user: started as root, run as this user once the listener is bound.

"""

func fail(_ message: String, code: Int32 = 2) -> Never {
    FileHandle.standardError.write(Data((message + "\n").utf8))
    exit(code)
}

var options: [String: String] = ["--upstream-port": "53", "--listen": "127.0.0.1", "--port": "1053", "--timeout": "4", "--idle-timeout": "10"]
var arguments = CommandLine.arguments.dropFirst()
while let flag = arguments.popFirst() {
    guard ["--policy", "--upstream", "--network-dns", "--upstream-port", "--listen", "--port", "--timeout", "--idle-timeout", "--user"].contains(flag),
          let value = arguments.popFirst() else { fail(usage) }
    options[flag] = value
}
guard let policyPath = options["--policy"],
      (options["--upstream"] == nil) != (options["--network-dns"] == nil) else { fail(usage) }
let listen = options["--listen"]!
guard listen == "127.0.0.1" || listen == "::1" else { fail("The listener must be 127.0.0.1 or ::1.") }
guard let port = UInt16(options["--port"]!), port == 0 || port == 53 || port >= 1024 else { fail("--port must be 0, 53 or 1024-65535.") }
guard let upstreamPort = UInt16(options["--upstream-port"]!), upstreamPort > 0,
      let upstreamPortValue = NWEndpoint.Port(rawValue: upstreamPort) else { fail("--upstream-port must be 1-65535.") }
guard let timeout = Double(options["--timeout"]!), (0.01...30).contains(timeout) else { fail("--timeout must be 0.01-30 seconds.") }
guard let idleTimeout = Double(options["--idle-timeout"]!), (0.01...300).contains(idleTimeout) else { fail("--idle-timeout must be 0.01-300 seconds.") }

let upstream: any DNSUpstream
if let path = options["--network-dns"] {
    do {
        let record = try JSONDecoder().decode(RecoveryRecord.self, from: Data(contentsOf: URL(fileURLWithPath: path)))
        upstream = try NetworkDNS(record: record, listenPort: port, timeout: timeout)
    } catch { fail("Could not read installed DNS routing configuration.", code: 1) }
} else {
    // An IP literal only: a hostname here would recurse through the system resolver.
    guard let host = NetworkDNS.resolverHost(options["--upstream"]!) else {
        fail("--upstream must be an IP address usable as a unicast resolver.")
    }
    if NetworkDNS.isLoopback(host) && upstreamPort == port { fail("The upstream must not point back to this listener.") }
    upstream = NetworkUpstream(endpoint: .hostPort(host: host, port: upstreamPortValue), timeout: timeout)
}

// The account to run as after binding; checked before anything starts.
var runAs: passwd?
if let user = options["--user"] {
    guard geteuid() == 0 else { fail("--user needs the filter to start as root.") }
    guard let entry = getpwnam(user), entry.pointee.pw_uid != 0 else { fail("--user must name an existing non-root user.") }
    runAs = entry.pointee
}

// Fail closed: an unreadable or invalid policy stops startup.
let policyFile = URL(fileURLWithPath: policyPath)
let initialVersion = PolicyVersion(file: policyFile)
let policy: Policy
do { policy = try Policy(file: policyFile.resolvingSymlinksInPath()) }
catch { fail("Policy rejected: \(type(of: error)).\(error)", code: 1) }

let server = LoopbackServer(resolver: Resolver(policy: policy), upstream: upstream, idleTimeout: idleTimeout)
let actualPort: UInt16
do { actualPort = try server.start(host: listen, port: port) }
catch { fail("Could not listen on \(listen):\(port).", code: 1) }

// Drop root for good once the listener holds the port: groups, then group, then user.
if let account = runAs {
    var group = account.pw_gid
    guard setgroups(1, &group) == 0, setgid(account.pw_gid) == 0, setuid(account.pw_uid) == 0,
          setuid(0) != 0, geteuid() == account.pw_uid else { fail("Could not drop privileges.", code: 1) }
}

var signalSources: [DispatchSourceSignal] = []
for number in [SIGTERM, SIGINT] {
    signal(number, SIG_IGN)
    let source = DispatchSource.makeSignalSource(signal: number, queue: .main)
    source.setEventHandler { server.stop(); exit(0) }
    source.resume()
    signalSources.append(source)
}

let shown = listen.contains(":") ? "[\(listen)]" : listen
let policyWatcher = watchPolicy(policyFile, initialVersion: initialVersion, server: server)
print("Clearpath filter on \(shown):\(actualPort); policy SHA256 \(policy.digest)")
fflush(stdout)
dispatchMain()
