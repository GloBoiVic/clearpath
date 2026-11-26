import Foundation

public enum InternetRecoveryStatus: String, Codable, Sendable {
    case restoring, restored, unknown
}

/// An event for the partner delivery layer. Contains no DNS settings or browsing data.
public struct InternetRestoreEvent: Codable, Equatable, Sendable {
    public let id: UUID
    public let restoredAt: Date
}

private struct InternetRecoveryRecord: Codable {
    let format: Int
    let id: UUID
    var restoredAt: Date?

    var event: InternetRestoreEvent? {
        restoredAt.map { InternetRestoreEvent(id: id, restoredAt: $0) }
    }
}

extension ServiceManager {
    public func restoreInternet() throws {
        guard system.isRoot else { throw ServiceError.refused("Restore internet must run as root.") }
        try withServiceLock {
            guard !isSymlink(paths.recovery), let original = try readRecord(),
                  !original.services.isEmpty,
                  original.services.allSatisfy({ service in
                      service.servers.allSatisfy { Self.ipFamily($0) != nil && $0 != Self.listenAddress }
                  }) else {
                throw ServiceError.refused("The original DNS settings could not be verified.")
            }
            let location = try recoveryLocation(original)
            var recovery: InternetRecoveryRecord
            if let saved = try readInternetRecovery() {
                if saved.event != nil {
                    guard try originalDNSMatches(original, location: location) else {
                        throw ServiceError.refused("DNS has changed since Clearpath restored it.")
                    }
                    return
                }
                recovery = saved
            } else {
                guard try allServicesUseFilter() else {
                    throw ServiceError.refused("Clearpath could not verify that system DNS uses the filter.")
                }
                guard !filterRecovered() else {
                    throw ServiceError.refused("The filter is answering. DNS was left in place.")
                }
                _ = try recoveryLocation(original)
                guard try allServicesUseFilter() else {
                    throw ServiceError.refused("System DNS changed while checking the filter.")
                }
                recovery = InternetRecoveryRecord(format: 1, id: UUID())
                try saveInternetRecovery(recovery, exclusive: true)
            }

            try restoreOriginalDNS(original)
            let currentLocation = try recoveryLocation(original)
            guard try originalDNSMatches(original, location: currentLocation) else {
                throw ServiceError.failed("Could not verify the restored DNS settings. Try Restore internet again.")
            }
            recovery.restoredAt = Date()
            try saveInternetRecovery(recovery)
        }
    }

    func applyRecoveryStatus(to status: inout ServiceStatus) throws {
        guard let recovery = try readInternetRecovery() else { return }
        status.restoreEvent = recovery.event
        guard !isSymlink(paths.recovery), let original = try readRecord(),
              let location = try? recoveryLocation(original) else {
            status.recovery = .unknown
            return
        }
        if recovery.event == nil {
            status.recovery = .restoring
        } else {
            status.recovery = try originalDNSMatches(original, location: location) ? .restored : .unknown
        }
    }

    /// Restore leaves DNS alone only when the filter has restarted and resolves again. A filter
    /// stuck in a DNS loop still answers the nameless probe at times, but resolves nothing.
    private func filterRecovered() -> Bool {
        var waited = 0.0
        while waited < Self.readyTimeout {
            if system.filterAnswers(port: Self.listenPort) {
                if system.filterResolves(port: Self.listenPort) { return true }
                waited += 2  // the lookup's own timeout
            }
            system.pause(seconds: 0.25)
            waited += 0.25
        }
        return false
    }

    private func allServicesUseFilter() throws -> Bool {
        let services = try readServices()
        return !services.isEmpty && services.allSatisfy { $0.servers == [Self.listenAddress] }
    }

    private func originalDNSMatches(_ original: RecoveryRecord, location: NetworkLocation) throws -> Bool {
        let current = try readServices(ids: location.serviceIDs)
        guard !current.contains(where: { $0.servers.contains(Self.listenAddress) }) else { return false }
        let matched = original.services.compactMap { saved in
            matchingService(saved, in: current).map { $0.servers == saved.servers }
        }
        return !matched.isEmpty && matched.allSatisfy { $0 }
    }

    private func readInternetRecovery() throws -> InternetRecoveryRecord? {
        guard !isSymlink(paths.internetRecovery) else {
            throw ServiceError.failed("The internet recovery record is a symbolic link.")
        }
        let data: Data
        do {
            data = try Data(contentsOf: paths.internetRecovery)
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
            return nil
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let record = try? decoder.decode(InternetRecoveryRecord.self, from: data), record.format == 1 else {
            throw ServiceError.failed("The internet recovery record is unreadable.")
        }
        return record
    }

    private func saveInternetRecovery(_ recovery: InternetRecoveryRecord, exclusive: Bool = false) throws {
        try writeFile(try Self.encoder.encode(recovery), to: paths.internetRecovery, mode: 0o644, exclusive: exclusive)
        let directory = open(paths.supportDirectory.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
        guard directory >= 0 else { throw ServiceError.failed("Could not open the service directory to save recovery.") }
        defer { close(directory) }
        guard fsync(directory) == 0 else { throw ServiceError.failed("Could not flush the internet recovery record.") }
    }
}
