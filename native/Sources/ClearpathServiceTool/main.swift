import Foundation
import ClearpathService

// Installs, removes and reports the Clearpath filter LaunchDaemon. Install and uninstall change
// the Mac's DNS settings and need root; run them only where that is approved (docs/TESTING.md).

let usage = """
usage: clearpath-service install --filter PATH --policy PATH [--upstream IP] [--upstream-port N]
       clearpath-service uninstall
       clearpath-service status
  install records every network service's DNS, starts the filter on 127.0.0.1:53 and points DNS at it.
  Without --upstream it forwards to the Mac's current primary DNS server.
  uninstall restores the recorded DNS, then stops the filter and removes only Clearpath's files.

"""

func fail(_ message: String, code: Int32) -> Never {
    FileHandle.standardError.write(Data((message + "\n").utf8))
    exit(code)
}

var arguments = Array(CommandLine.arguments.dropFirst())
guard let command = arguments.first else { fail(usage, code: 2) }
arguments.removeFirst()
let manager = ServiceManager()

func run(_ body: () throws -> Void) -> Never {
    do { try body(); exit(0) }
    catch ServiceError.refused(let text) { fail(text, code: 2) }
    catch { fail("\(error)", code: 1) }
}

switch command {
case "install":
    var options: [String: String] = ["--upstream-port": "53"]
    while let flag = arguments.first {
        arguments.removeFirst()
        guard ["--filter", "--policy", "--upstream", "--upstream-port"].contains(flag), let value = arguments.first else { fail(usage, code: 2) }
        arguments.removeFirst()
        options[flag] = value
    }
    guard let filter = options["--filter"], let policy = options["--policy"],
          let port = UInt16(options["--upstream-port"]!) else { fail(usage, code: 2) }
    run {
        try manager.install(filter: URL(fileURLWithPath: filter), policy: URL(fileURLWithPath: policy),
                            upstream: options["--upstream"], upstreamPort: port)
    }
case "uninstall":
    guard arguments.isEmpty else { fail(usage, code: 2) }
    run { try manager.uninstall() }
case "status":
    guard arguments.isEmpty else { fail(usage, code: 2) }
    run {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        print(String(decoding: try encoder.encode(manager.status()), as: UTF8.self))
    }
default:
    fail(usage, code: 2)
}
