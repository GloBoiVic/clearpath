import Foundation
import ClearpathService

// Installs, removes and reports the Clearpath filter LaunchDaemon. Install, restore and uninstall change
// the Mac's DNS settings and need root; run them only where that is approved (docs/TESTING.md).

let usage = """
usage: clearpath-service install --filter PATH --policy PATH [--upstream IP] [--upstream-port N] [--partner-config PATH]
       clearpath-service restore
       clearpath-service uninstall
       clearpath-service status
       clearpath-service blocked-sites
       clearpath-service block-site DOMAIN
       clearpath-service request-site-removal custom|adult DOMAIN
       clearpath-service site-removals
       clearpath-service record-partner-pairing
       clearpath-service refresh-community-list
       clearpath-service browser-profile
  install records every network service's DNS, starts the filter on 127.0.0.1:53 and points DNS at it.
  Without --upstream it follows the Mac's current default and supplemental DNS resolvers.
  restore returns DNS to its saved settings if the filter stays down, retaining the installation.
  uninstall restores the recorded DNS, then stops the filter and removes only Clearpath's files.
  blocked-sites prints the installed block rules and their exceptions as JSON.
  block-site adds a custom block through the installed local service.
  request-site-removal asks the installed service to request removal of the selected block rule.
  site-removals prints the installed service's removal requests as JSON.
  record-partner-pairing tells the installed service this Mac uses a partner service, ending solo removals.
  refresh-community-list checks the weekly community list schedule as root.
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
    if arguments == ["--from-setup", "copy"] || arguments == ["--from-setup", "in-place"] {
        run {
            guard let executable = Bundle.main.executableURL else {
                throw ServiceError.refused("Could not locate the bundled service executable.")
            }
            let bundle = executable.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            let destination = "/Applications/Clearpath.app"
            let copyApp = arguments.last == "copy"
            var info = stat()
            guard copyApp ? (lstat(destination, &info) == -1 && errno == ENOENT)
                          : (lstat(destination, &info) == 0 && info.st_mode & S_IFMT == S_IFDIR) else {
                throw ServiceError.refused("Clearpath’s Applications location changed. DNS was not changed.")
            }
            try manager.installFromSetup(filter: executable.deletingLastPathComponent().appendingPathComponent("clearpath-filter"),
                                         policy: bundle.appendingPathComponent("Contents/Resources/default-policy.json"),
                                         controlTool: executable) {
                guard !copyApp || renamex_np(bundle.path, destination, UInt32(RENAME_EXCL)) == 0 else {
                    throw ServiceError.failed("Could not move Clearpath into Applications.")
                }
            }
        }
    }
    var options: [String: String] = ["--upstream-port": "53"]
    while let flag = arguments.first {
        arguments.removeFirst()
        guard ["--filter", "--policy", "--upstream", "--upstream-port", "--partner-config"].contains(flag),
              let value = arguments.first else { fail(usage, code: 2) }
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
                            upstream: options["--upstream"], upstreamPort: port, controlTool: executable,
                            partnerConfig: options["--partner-config"].map { URL(fileURLWithPath: $0) })
    }
case "restore":
    guard arguments.isEmpty else { fail(usage, code: 2) }
    run { try manager.restoreInternet() }
case "uninstall":
    if arguments.count == 3, arguments[0] == "--from-app", let uid = uid_t(arguments[2]) {
        run {
            guard let executable = Bundle.main.executableURL else {
                throw ServiceError.refused("Could not locate the bundled service executable.")
            }
            let stage = executable.deletingLastPathComponent().deletingLastPathComponent()
                .deletingLastPathComponent().deletingLastPathComponent()
            let uninstaller = ServiceManager(log: { _ in })
            let outcome = try uninstaller.uninstallApplication(codeHash: arguments[1], consoleUID: uid,
                                                               stagingDirectory: stage, reason: .withoutApproval)
            print(outcome == .removed ? "removed" : "remove-browser-profile")
        }
    }
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
    guard arguments.count == 1 else { fail(usage, code: 2) }
    run { print(try SiteBlockControl.add(arguments[0])) }
case "request-site-removal":
    guard arguments.count == 2 else { fail(usage, code: 2) }
    run { try SiteBlockControl.requestRemoval(arguments[1], rule: arguments[0]) }
case "site-removals":
    guard arguments.isEmpty else { fail(usage, code: 2) }
    run { print(try SiteBlockControl.listRemovals()) }
case "record-partner-pairing":
    guard arguments.isEmpty else { fail(usage, code: 2) }
    run { try SiteBlockControl.recordPartnerPairing() }
case "serve-site-blocks":
    guard arguments.isEmpty else { fail(usage, code: 2) }
    run { try SiteBlockControl.serve(manager: manager) }
case "refresh-community-list":
    guard arguments.isEmpty else { fail(usage, code: 2) }
    run { try manager.refreshCommunityList() }
case "browser-profile":
    guard arguments.isEmpty else { fail(usage, code: 2) }
    run {
        try FileHandle.standardOutput.write(contentsOf: BrowserProfile.configuration())
    }
default:
    fail(usage, code: 2)
}
