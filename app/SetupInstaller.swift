import AppKit
import Darwin
import Security
import ServiceManagement

enum SetupInstaller {
    static let destination = URL(fileURLWithPath: "/Applications/Clearpath.app", isDirectory: true)
    static let continuation = "--continue-setup"
    static let loginItem = SMAppService.mainApp

    enum Location: Equatable {
        case installHere, copyToApplications, reopenInstalledCopy, conflict, unverified
    }

    enum Outcome {
        case installed, cancelled, failed(String)
    }

    enum AuthorizationResult {
        case completed(String), cancelled, failed(String)
    }

    static var runningFromApplications: Bool {
        Bundle.main.bundleURL.standardizedFileURL.path == destination.path
    }

    static func location() -> Location {
        guard let hash = runningCodeHash, verifies(Bundle.main.bundleURL, hash: hash) else { return .unverified }
        var info = stat()
        if lstat(destination.path, &info) == -1 {
            return errno == ENOENT && !runningFromApplications ? .copyToApplications : .unverified
        }
        guard info.st_mode & S_IFMT == S_IFDIR, verifies(destination, hash: hash) else { return .conflict }
        return runningFromApplications ? .installHere : .reopenInstalledCopy
    }

    @MainActor
    static func reopenInApplications() async throws {
        guard location() == .reopenInstalledCopy else { throw CocoaError(.fileReadCorruptFile) }
        let installed = NSWorkspace.shared.runningApplications.first {
            $0.bundleURL?.standardizedFileURL.path == destination.path
        }
        if let installed {
            installed.activate()
        } else {
            let configuration = NSWorkspace.OpenConfiguration()
            configuration.createsNewApplicationInstance = true
            configuration.arguments = [continuation]
            _ = try await NSWorkspace.shared.openApplication(at: destination, configuration: configuration)
        }
        NSApp.terminate(nil)
    }

    static func install(at location: Location) -> Outcome {
        guard location == .copyToApplications || location == .installHere, location == self.location(),
              let hash = runningCodeHash else {
            return .failed("Clearpath couldn’t verify this app or its location. DNS was not changed.")
        }
        switch authorize(privilegedInstall, hash: hash, option: location == .copyToApplications ? "copy" : "in-place") {
        case .completed: return .installed
        case .cancelled: return .cancelled
        case .failed(let message): return .failed(message)
        }
    }

    static func authorizeUninstall() -> AuthorizationResult {
        guard location() == .installHere, let hash = runningCodeHash, getuid() != 0 else {
            return .failed("Open the verified Clearpath app in Applications and try again.")
        }
        return authorize(privilegedUninstall, hash: hash, option: String(getuid()))
    }

    private static func authorize(_ script: String, hash: String, option: String) -> AuthorizationResult {
        let process = Process()
        let output = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-e", authorization, script, Bundle.main.bundleURL.path, hash, option]
        process.environment = ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin"]
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            let data = output.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            if process.terminationStatus == 0 {
                let response = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .newlines)
                if response.hasPrefix("completed\n") { return .completed(String(response.dropFirst("completed\n".count))) }
                if response == "cancelled" { return .cancelled }
                if response.hasPrefix("failed\n") { return .failed(String(response.dropFirst("failed\n".count))) }
            }
        } catch {}
        return .failed("Clearpath couldn’t confirm the result. Check DNS status before retrying.")
    }

    private static var runningCodeHash: String? {
        var code: SecCode?
        var staticCode: SecStaticCode?
        var information: CFDictionary?
        guard SecCodeCopySelf([], &code) == errSecSuccess, let code,
              SecCodeCheckValidity(code, [], nil) == errSecSuccess,
              SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess, let staticCode,
              SecCodeCopySigningInformation(staticCode, SecCSFlags(rawValue: kSecCSSigningInformation), &information) == errSecSuccess,
              let hash = (information as? [String: Any])?[kSecCodeInfoUnique as String] as? Data,
              hash.count == 20 else { return nil }
        return hash.map { String(format: "%02x", $0) }.joined()
    }

    private static func verifies(_ url: URL, hash: String) -> Bool {
        var code: SecStaticCode?
        var requirement: SecRequirement?
        let flags = SecCSFlags(rawValue: kSecCSStrictValidate | kSecCSCheckNestedCode)
        return SecStaticCodeCreateWithPath(url as CFURL, [], &code) == errSecSuccess
            && SecRequirementCreateWithString("cdhash H\"\(hash)\"" as CFString, [], &requirement) == errSecSuccess
            && code.map { SecStaticCodeCheckValidity($0, flags, requirement) == errSecSuccess } == true
    }

    private static let authorization = #"""
    on run argv
        set invocation to "/usr/bin/env -i PATH=/usr/bin:/bin:/usr/sbin:/sbin /bin/sh -c " & quoted form of item 1 of argv & " clearpath-setup " & quoted form of item 2 of argv & " " & quoted form of item 3 of argv & " " & quoted form of item 4 of argv
        try
            set response to do shell script invocation with administrator privileges
            return "completed" & linefeed & response
        on error detail number code
            if code is -128 then return "cancelled"
            return "failed" & linefeed & detail
        end try
    end run
    """#

    // Copy without following links into a root-only directory, then verify the copy against
    // the running app’s code hash before executing anything from it as root.
    private static let stageSignedApp = #"""
    set -eu
    umask 077
    stage=$(/usr/bin/mktemp -d /private/var/tmp/clearpath-setup.XXXXXXXX)
    trap '/bin/rm -rf "$stage"' EXIT
    app="$stage/Clearpath.app"
    /bin/cp -RPX "$1" "$app"
    unexpected=$(/usr/bin/find -P "$app" ! -type f ! -type d -print)
    if [ -n "$unexpected" ]; then
        echo 'The copied app contains an unexpected file type. DNS was not changed.' >&2
        exit 1
    fi
    /bin/chmod -RN "$app"
    /bin/chmod -R u=rwX,go=rX "$app"
    /usr/bin/codesign --verify --strict --deep -R="cdhash H\"$2\"" "$app"
    umask 022
    """#

    private static let privilegedInstall = stageSignedApp + "\n" + #"""
    "$app/Contents/MacOS/clearpath-service" install --from-setup "$3"
    """#

    private static let privilegedUninstall = stageSignedApp + "\n" + #"""
    "$app/Contents/MacOS/clearpath-service" uninstall --from-app "$2" "$3"
    """#
}
