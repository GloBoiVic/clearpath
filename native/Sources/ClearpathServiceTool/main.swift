import Foundation
import ClearpathService

// Installs, removes and reports the Clearpath filter LaunchDaemon. Install, restore and uninstall change
// the Mac's DNS settings and need root; run them only where that is approved (docs/TESTING.md).

let usage = """
usage: clearpath-service install --filter PATH --policy PATH [--upstream IP] [--upstream-port N]
       clearpath-service restore
       clearpath-service uninstall
       clearpath-service status
       clearpath-service blocked-sites
       clearpath-service block-site [DOMAIN]
       clearpath-service browser-profile
  install records every network service's DNS, starts the filter on 127.0.0.1:53 and points DNS at it.
  Without --upstream it follows the Mac's current default and supplemental DNS resolvers.
  restore returns DNS to its saved settings if the filter stays down, retaining the installation.
  uninstall restores the recorded DNS, then stops the filter and removes only Clearpath's files.
  blocked-sites prints the installed block rules and their exceptions as JSON.
  block-site adds a custom block through the installed local service. With no argument, it reads the domain from stdin.
  browser-profile writes Clearpath's removable Chrome and Firefox profile to standard output.

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
        guard let executable = Bundle.main.executableURL else {
            throw ServiceError.refused("Could not locate the current service executable.")
        }
        try manager.install(filter: URL(fileURLWithPath: filter), policy: URL(fileURLWithPath: policy),
                            upstream: options["--upstream"], upstreamPort: port, controlTool: executable)
    }
case "restore":
    guard arguments.isEmpty else { fail(usage, code: 2) }
    run { try manager.restoreInternet() }
case "uninstall":
    guard arguments.isEmpty else { fail(usage, code: 2) }
    run { try manager.uninstall() }
case "status":
    guard arguments.isEmpty else { fail(usage, code: 2) }
    run {
        alarm(5) // Bound an unresponsive system command so the app cannot keep stale health.
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        print(String(decoding: try encoder.encode(manager.status()), as: UTF8.self))
    }
case "blocked-sites":
    guard arguments.isEmpty else { fail(usage, code: 2) }
    run {
        alarm(5)
        try FileHandle.standardOutput.write(contentsOf: JSONEncoder().encode(manager.siteBlocks()))
    }
case "block-site":
    guard arguments.count <= 1 else { fail(usage, code: 2) }
    run {
        let domain: String
        if let argument = arguments.first {
            domain = argument
        } else {
            alarm(2)
            let data = try FileHandle.standardInput.read(upToCount: 1025)
            alarm(0)
            guard let data, let input = String(data: data, encoding: .utf8) else {
                throw ServiceError.refused("Enter a domain such as example.com.")
            }
            domain = input
        }
        print(try SiteBlockControl.add(domain))
    }
case "serve-site-blocks":
    guard arguments.isEmpty else { fail(usage, code: 2) }
    run { try SiteBlockControl.serve(manager: manager) }
case "browser-profile":
    guard arguments.isEmpty else { fail(usage, code: 2) }
    run {
        try FileHandle.standardOutput.write(contentsOf: BrowserProfile.configuration())
    }
default:
    fail(usage, code: 2)
}
