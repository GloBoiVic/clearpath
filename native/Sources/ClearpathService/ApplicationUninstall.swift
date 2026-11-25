import Foundation

public enum ApplicationUninstallOutcome: Equatable {
    case removed, removeBrowserProfile
}

public enum ApplicationUninstallReason: String, Codable {
    case withoutApproval = "uninstalledWithoutApproval"
}

private struct UninstallEvent: Codable {
    let id: UUID
    let occurredAt: Date
    let kind: ApplicationUninstallReason
}

private struct ManualProfileRemoval: Error {}

extension ServiceManager {
    /// Both owner-authorized and partner-approved removal use the same system cleanup.
    public func uninstallApplication(codeHash: String, consoleUID: uid_t, stagingDirectory: URL,
                                     reason: ApplicationUninstallReason) throws -> ApplicationUninstallOutcome {
        guard system.isRoot, consoleUID != 0, consoleUID == system.consoleUserID else {
            throw ServiceError.refused("Uninstall needs administrator approval from the user signed in on this Mac.")
        }
        guard codeHash.utf8.count == 40, codeHash.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }) else {
            throw ServiceError.refused("Clearpath couldn’t verify this build.")
        }
        try verifyPrivateDirectory(stagingDirectory)
        try makeDirectory(paths.supportDirectory)
        do {
            try withServiceLock {
                let application = try verifiedApplication(codeHash: codeHash)
                try uninstallLocked(beforeRemovingFiles: {
                    try removeBrowserProfile()
                    try unregisterLoginItem(consoleUID)
                    try queueUninstallEvent(reason)
                }, finish: {
                    let current = try verifiedApplication(codeHash: codeHash)
                    guard current.st_dev == application.st_dev, current.st_ino == application.st_ino else {
                        throw ServiceError.failed("The app in Applications changed during uninstall. Open Clearpath and try again.")
                    }
                    // Retire the whole bundle at once. The authorized shell cleans its private stage on exit.
                    let retired = stagingDirectory.appendingPathComponent("RemovedClearpath.app")
                    guard renamex_np(paths.application.path, retired.path, UInt32(RENAME_EXCL)) == 0 else {
                        throw ServiceError.failed("Clearpath couldn’t remove the app from Applications. Try again.")
                    }
                })
            }
            return .removed
        } catch is ManualProfileRemoval {
            return .removeBrowserProfile
        }
    }

    private func verifiedApplication(codeHash: String) throws -> stat {
        var info = stat()
        let app = paths.application.path
        guard lstat(app, &info) == 0, info.st_mode & S_IFMT == S_IFDIR,
              try system.run(.codesign, ["--verify", "--strict", "--deep", "-R=cdhash H\"\(codeHash)\"", app]).status == 0 else {
            throw ServiceError.refused("Clearpath couldn’t verify the app in Applications. Open the installed copy and try again.")
        }
        return info
    }

    private func removeBrowserProfile() throws {
        guard try BrowserProfile.isInstalled(using: system) else { return }
        _ = try? system.run(.profiles, ["remove", "-type", "configuration", "-forced", "-identifier", BrowserProfile.identifier])
        guard (try? BrowserProfile.isInstalled(using: system)) == false else { throw ManualProfileRemoval() }
    }

    private func unregisterLoginItem(_ uid: uid_t) throws {
        guard uid == system.consoleUserID else {
            throw ServiceError.failed("The signed-in user changed. Sign back in to finish removing Clearpath.")
        }
        // asuser selects the GUI bootstrap. sudo drops root before the app executable is loaded.
        let executable = paths.application.appendingPathComponent("Contents/MacOS/Clearpath").path
        let result = try system.run(.launchctl, ["asuser", String(uid), "/usr/bin/sudo", "-n", "-H", "-u", "#\(uid)",
                                                  "--", executable, "--unregister-login-item"])
        guard result.status == 0, result.output.trimmingCharacters(in: .newlines) == "unregistered" else {
            throw ServiceError.failed("Clearpath couldn’t unregister its login item. Try again while signed in.")
        }
    }

    private func queueUninstallEvent(_ reason: ApplicationUninstallReason) throws {
        var config = stat()
        if lstat(paths.partnerConfig.path, &config) != 0, errno == ENOENT { return }
        guard config.st_mode & S_IFMT == S_IFREG, config.st_uid == geteuid(), config.st_mode & 0o077 == 0 else {
            throw ServiceError.failed("Clearpath couldn’t verify that the pairing configuration is private.")
        }

        // Keep one ID across retries. The pending copy survives removal of the service directory.
        var marker = stat()
        if lstat(paths.uninstallEvent.path, &marker) != 0, errno == ENOENT {
            let event = UninstallEvent(id: UUID(), occurredAt: Date(), kind: reason)
            try writeFile(try Self.encoder.encode(event), to: paths.uninstallEvent, mode: 0o600, exclusive: true)
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard lstat(paths.uninstallEvent.path, &marker) == 0, marker.st_mode & S_IFMT == S_IFREG,
              marker.st_uid == geteuid(), marker.st_mode & 0o077 == 0, (1...1024).contains(marker.st_size),
              let event = try? decoder.decode(UninstallEvent.self, from: Data(contentsOf: paths.uninstallEvent)),
              event.kind == reason else {
            throw ServiceError.failed("Clearpath couldn’t verify the pending uninstall event.")
        }
        try FileManager.default.createDirectory(at: paths.pendingUninstallEvents, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        try verifyPrivateDirectory(paths.pendingUninstallEvents)
        let pending = paths.pendingUninstallEvents.appendingPathComponent("\(event.id.uuidString.lowercased()).json")
        if link(paths.uninstallEvent.path, pending.path) == 0 { return }
        var existing = stat()
        guard errno == EEXIST, lstat(pending.path, &existing) == 0,
              existing.st_dev == marker.st_dev, existing.st_ino == marker.st_ino else {
            throw ServiceError.failed("Clearpath couldn’t save the pending uninstall event.")
        }
    }

    private func verifyPrivateDirectory(_ directory: URL) throws {
        var info = stat()
        guard lstat(directory.path, &info) == 0, info.st_mode & S_IFMT == S_IFDIR,
              info.st_uid == geteuid(), info.st_mode & 0o077 == 0 else {
            throw ServiceError.failed("Clearpath couldn’t verify a private uninstall directory.")
        }
    }
}
