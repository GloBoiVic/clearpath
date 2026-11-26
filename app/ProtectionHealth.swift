import Combine
import Darwin
import Foundation

struct FilterStatus: Decodable, Sendable {
    enum Recovery: String, Decodable, Sendable {
        case restoring, restored, unknown
    }

    struct CommunityList: Decodable, Sendable {
        let lastSuccess: Date
        let sourceVersion: String
    }

    let installed: Bool
    let daemonLoaded: Bool
    let pid: Int?
    let answering: Bool
    let dnsPointsToFilter: Bool
    let defaultResolverUsesFilter: Bool?
    let lookupsFailThroughFilter: Bool?
    let defaultResolverReachesFilter: Bool?
    let recovery: Recovery?
    let restoreAvailable: Bool?
    let setupInstallAvailable: Bool?
    let communityList: CommunityList?

    /// The filter is down, or it runs but lookups through it fail while the network's own
    /// resolver works, as in a VPN DNS loop (#73). Either way Restore internet can help.
    var outage: Bool {
        installed && dnsPointsToFilter && recovery == nil && (!answering || lookupsFailThroughFilter == true)
    }

    private var filterWorks: Bool {
        installed && daemonLoaded && pid != nil && answering && dnsPointsToFilter && recovery == nil
            && lookupsFailThroughFilter != true
    }

    /// Lookups verifiably go through Clearpath: it is the default resolver, or the default
    /// resolver (a VPN) sent a check name through it (#76).
    var protected: Bool {
        filterWorks && (defaultResolverUsesFilter == true || throughVPN)
    }

    var throughVPN: Bool {
        filterWorks && defaultResolverUsesFilter == false && defaultResolverReachesFilter == true
    }

    /// The default resolver (a VPN) answered a check name without Clearpath.
    var vpnBypass: Bool {
        filterWorks && defaultResolverUsesFilter == false && defaultResolverReachesFilter == false
    }

    var message: String {
        if throughVPN && communityList != nil { return "Protection is on through your VPN. The community blocklist is active." }
        if throughVPN { return "DNS filtering is on through your VPN. The community blocklist has not been verified." }
        if protected && communityList != nil { return "Protection is on. The community blocklist is active." }
        if protected { return "DNS filtering is on. The community blocklist has not been verified." }
        if vpnBypass {
            return "Your VPN answers lookups without Clearpath, so sites aren’t filtered. Turn off your VPN’s DNS setting to turn protection back on."
        }
        if recovery == .restored { return "DNS was restored to its previous settings." }
        if setupInstallAvailable == true {
            return "The Clearpath filter service is not installed."
        }
        return "Clearpath couldn’t verify the DNS configuration. Check DNS status before continuing."
    }

    static func read() -> FilterStatus? {
        guard let executable = Bundle.main.url(forAuxiliaryExecutable: "clearpath-service") else { return nil }
        let process = Process()
        let output = Pipe()
        process.executableURL = executable
        process.arguments = ["status"]
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            let data = output.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            guard process.terminationStatus == 0 else { return nil }
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            return try decoder.decode(Self.self, from: data)
        } catch {
            return nil
        }
    }
}

enum ProtectionState: Equatable {
    case unknown, protected, protectedThroughVPN, vpnBypass, restarting, offline, restoring, interrupted, restored

    var headline: String {
        switch self {
        case .unknown: return "Protection status unknown"
        case .protected: return "Protection is on"
        case .protectedThroughVPN: return "Protection is on through your VPN"
        case .vpnBypass: return "Your VPN is bypassing Clearpath"
        case .restarting: return "Restarting protection…"
        case .offline: return "Protection is offline"
        case .restoring: return "Restoring internet…"
        case .interrupted: return "DNS restoration interrupted"
        case .restored: return "Previous DNS settings restored"
        }
    }

    var offersRestore: Bool { self == .offline || self == .interrupted }
    var isOn: Bool { self == .protected || self == .protectedThroughVPN }

    /// Shown under the headline.
    var note: String? {
        self == .vpnBypass ? "Sites aren’t filtered while your VPN answers lookups itself. Turn off your VPN’s DNS setting to turn protection back on." : nil
    }

    static func from(_ status: FilterStatus?) -> ProtectionState {
        guard let status else { return .unknown }
        if status.throughVPN { return .protectedThroughVPN }
        if status.protected { return .protected }
        return status.vpnBypass ? .vpnBypass : .unknown
    }
}

@MainActor
final class ProtectionHealth: ObservableObject {
    @Published private(set) var state: ProtectionState = .unknown
    @Published private(set) var restoreAvailable = false
    @Published private(set) var restoreError: String?
    var onStateChange: (() -> Void)?

    private var checking = false
    private var restoring = false
    private var outageStarted: ContinuousClock.Instant?
    private var lastCheck: ContinuousClock.Instant?
    private let clock = ContinuousClock()

    func refresh() async {
        guard !checking, !restoring else { return }
        checking = true
        let checkStarted = clock.now
        let result = await Task.detached { FilterStatus.read() }.value
        checking = false
        guard !restoring else { return }

        // A long gap before this check (sleep, a suspended app) restarts the outage clock. The
        // check's own time doesn't count: a lookup that fails through the filter takes seconds.
        let now = clock.now
        if let lastCheck, checkStarted - lastCheck > .seconds(4) { outageStarted = nil }
        lastCheck = now
        restoreAvailable = result?.restoreAvailable == true
        if let result, result.outage {
            let started = outageStarted ?? now
            outageStarted = started
            updateState(now - started >= .seconds(10) ? .offline : .restarting)
        } else {
            outageStarted = nil
            switch result?.recovery {
            case .restored: updateState(.restored)
            case .restoring: updateState(.interrupted)
            default: updateState(ProtectionState.from(result))
            }
        }
    }

    func restore() async {
        guard state.offersRestore, restoreAvailable else { return }
        restoring = true
        restoreError = nil
        updateState(.restoring)
        let outcome = await Task.detached(priority: .userInitiated) { RestoreCommand.run() }.value
        restoring = false
        await refresh()
        restoreError = state == .restored || state.isOn ? nil : outcome.message
        if state == .restoring { updateState(.unknown) }
        onStateChange?()
    }

    private func updateState(_ next: ProtectionState) {
        guard state != next else { return }
        state = next
        if next == .restored || next.isOn { restoreError = nil }
        onStateChange?()
    }
}

private enum RestoreCommand {
    static func run() -> RestoreOutcome {
        // The privileged command has no interpolated input and never runs an executable
        // from the user-writable app bundle. Reject a replaced path before asking for approval.
        guard isRootControlled("/", kind: S_IFDIR),
              isRootControlled("/Library", kind: S_IFDIR),
              isRootControlled("/Library/Application Support", kind: S_IFDIR),
              isRootControlled("/Library/Application Support/Clearpath", kind: S_IFDIR),
              isRootControlled("/Library/Application Support/Clearpath/clearpath-service", kind: S_IFREG) else {
            return .failed(reason: nil)
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-e", #"do shell script "exec '/Library/Application Support/Clearpath/clearpath-service' restore" with administrator privileges"#]
        process.environment = ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin"]
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        let errors = Pipe()
        process.standardError = errors
        do {
            try process.run()
            let data = errors.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            return RestoreOutcome.from(status: process.terminationStatus, errorOutput: String(decoding: data.prefix(4096), as: UTF8.self))
        } catch {
            return .failed(reason: nil)
        }
    }

    private static func isRootControlled(_ path: String, kind: mode_t) -> Bool {
        var info = stat()
        guard lstat(path, &info) == 0,
              info.st_uid == 0, info.st_mode & 0o022 == 0, info.st_mode & S_IFMT == kind else { return false }
        guard let acl = acl_get_link_np(path, ACL_TYPE_EXTENDED) else { return errno == ENOENT }
        defer { acl_free(UnsafeMutableRawPointer(acl)) }
        var entry: acl_entry_t?
        return acl_get_entry(acl, Int32(ACL_FIRST_ENTRY.rawValue), &entry) != 0 && errno == EINVAL
    }
}
