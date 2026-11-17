import Foundation
import Security
import Network
import ClearpathCore
import ClearpathNetwork

enum ControlError: Error { case usage, notInstalled, notSigned, consentRequired }

func requireInstalledSignature() throws {
    let bundle = Bundle.main
    guard bundle.bundleIdentifier == "io.clearpath.Clearpath",
          bundle.bundleURL.path.hasPrefix("/Applications/"), bundle.bundleURL.pathExtension == "app"
    else { throw ControlError.notInstalled }
    var code: SecCode?
    guard SecCodeCopySelf([], &code) == errSecSuccess, let code else { throw ControlError.notSigned }
    var requirement: SecRequirement?
    // Ad-hoc builds cannot trigger system changes; the platform still performs
    // entitlement/profile verification on an installed Developer ID build.
    guard SecRequirementCreateWithString("anchor apple generic" as CFString, [], &requirement) == errSecSuccess,
          SecCodeCheckValidity(code, [], requirement) == errSecSuccess else { throw ControlError.notSigned }
}

func run() async throws {
    let arguments = Array(CommandLine.arguments.dropFirst())
    guard let command = arguments.first else { throw ControlError.usage }
    if command == "validate", arguments.count == 2 {
        let policy = try Policy(data: Data(contentsOf: URL(fileURLWithPath: arguments[1])))
        print("Valid policy SHA256 \(policy.digest)")
        return
    }
    // Explicit, process-local test path; does not invoke either manager API.
    if command == "probe", (6...7).contains(arguments.count) {
        let policy = try Policy(data: Data(contentsOf: URL(fileURLWithPath: arguments[1])))
        let host = try Policy.domain(arguments[2])
        guard let type = UInt16(arguments[3]), let port = NWEndpoint.Port(arguments[5]),
              arguments.count <= 7, arguments.count != 7 || arguments[6] == "--tcp" else { throw ControlError.usage }
        let upstream = NetworkUpstream(endpoint: .hostPort(host: NWEndpoint.Host(arguments[4]), port: port))
        let packet = DNSMessage.query(host, type: type)
        let response = await Resolver(policy: policy).resolve(packet, tcp: arguments.contains("--tcp"), upstream: upstream)
        let output: [String: Any] = ["packetHex": response.map { String(format: "%02x", $0) }.joined(),
                                     "systemConfigurationChanged": false]
        print(String(decoding: try JSONSerialization.data(withJSONObject: output, options: .sortedKeys), as: UTF8.self))
        return
    }
    guard ["activate", "deactivate", "uninstall", "status"].contains(command) else { throw ControlError.usage }
    if command != "status" {
        guard arguments.contains("--allow-system-changes") else { throw ControlError.consentRequired }
        try requireInstalledSignature()
    }
    let preferences = ApplePreferences()
    let lifecycle = Lifecycle(preferences: preferences, extensions: AppleExtensions())
    switch command {
    case "activate":
        guard arguments.count == 3, arguments[2] == "--allow-system-changes" else { throw ControlError.usage }
        let policy = try Policy(data: Data(contentsOf: URL(fileURLWithPath: arguments[1])))
        let result = try await lifecycle.activate(policy: policy)
        print(result == .completed
              ? "DNS configuration enabled. Verify actual filtering with the VM test matrix; saved state is not runtime health."
              : "Extension activation requires reboot. DNS configuration was not enabled; keep the app installed and retry after reboot.")
    case "deactivate":
        guard arguments.count == 2 else { throw ControlError.usage }
        try await lifecycle.deactivate()
        print("Clearpath DNS configuration disabled and read back. Verify ordinary resolution before removing the app.")
    case "uninstall":
        guard arguments.count == 2 else { throw ControlError.usage }
        let result = try await lifecycle.uninstall()
        print(result == .completed
              ? "Clearpath DNS configuration removed and extension deactivated. Remove only the Clearpath browser profile separately."
              : "Clearpath DNS configuration removed. Extension removal requires reboot; keep the app installed until verified.")
    case "status":
        guard arguments.count == 1 else { throw ControlError.usage }
        if let config = try await preferences.load() {
            print("Saved provider: \(config.providerID); enabled: \(config.enabled)")
            print("Policy SHA256: \((try? Policy(data: config.policyData).digest) ?? "invalid")")
        } else { print("No saved DNS Proxy configuration for this app") }
        print("Runtime flow capture, approval and browser coverage are not established by saved preferences.")
    default: throw ControlError.usage
    }
}

Task {
    do { try await run(); exit(0) }
    catch {
        // No policy contents, requested domains, URLs, or arbitrary error userInfo.
        if let error = error as? ControlError {
            switch error {
            case .consentRequired: fputs("Missing --allow-system-changes; no system configuration changed.\n", stderr)
            case .notInstalled: fputs("System changes require the signed Clearpath.app in /Applications; no manager call was made.\n", stderr)
            case .notSigned: fputs("The application signature is not eligible for activation.\n", stderr)
            case .usage: break
            }
        }
        if let error = error as? LifecycleError, error == .rollbackFailed {
            fputs("Rollback could not be verified. Keep Clearpath installed and inspect its DNS configuration before removal.\n", stderr)
        }
        let ns = error as NSError
        fputs("Clearpath command failed (\(ns.domain):\(ns.code)).\n", stderr)
        fputs("Usage: clearpathctl validate POLICY | probe POLICY HOST QTYPE UPSTREAM_IP PORT [--tcp] | status | activate POLICY --allow-system-changes | deactivate --allow-system-changes | uninstall --allow-system-changes\n", stderr)
        fputs("System changes require an installed, properly signed app and explicit authorization on the target Mac.\n", stderr)
        exit(1)
    }
}
RunLoop.main.run()
