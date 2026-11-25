import XCTest
@testable import ClearpathService

final class PartnerCheckInTests: XCTestCase {
    func test_background_worker_sends_check_ins_and_service_alerts_once_per_outage() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("clearpath-check-in-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }
        let now = 2_000_000_000
        let day = 24 * 60 * 60
        let pairing = try PairingFixture(root: root, now: now)
        defer { pairing.stop() }
        try await pairing.acceptBothPartners()

        func runWorker(every interval: Duration, checkIns: Int) async throws {
            var previous = try await pairing.checkInRevision()
            let worker = Task {
                await PairingClient.sendCheckIns(every: interval) { try pairing.client }
            }
            defer { worker.cancel() }
            for _ in 0..<checkIns {
                let revision = try await waitFor {
                    let current = try await pairing.checkInRevision()
                    return current != previous ? current : nil
                }
                previous = revision
            }
            worker.cancel()
            await worker.value
        }

        // Run the installed daemon's worker with no menu-bar process.
        try await runWorker(every: .milliseconds(100), checkIns: 2)
        try pairing.setClock(now + day - 1)
        try await pairing.advance()
        XCTAssertTrue(try pairing.missedCheckInMail().isEmpty)

        pairing.stop()
        try pairing.setClock(now + day)
        try pairing.restart()
        // Observe the service's automatic sweep without an HTTP status request.
        let firstBatch = try await waitFor {
            let mail = try pairing.missedCheckInMail()
            return mail.isEmpty ? nil : mail
        }
        XCTAssertEqual(firstBatch.map(\.lastPathComponent).sorted(), ["backup.eml", "primary.eml"])
        for path in firstBatch {
            let message = try String(contentsOf: path, encoding: .utf8)
            XCTAssertTrue(message.contains("hasn't checked in for 24 hours"))
            XCTAssertTrue(message.contains("may simply be off"))
        }
        try await pairing.advance()
        XCTAssertEqual(Set(try pairing.missedCheckInMail()), Set(firstBatch))

        try pairing.setClock(now + day + 1)
        try await runWorker(every: .seconds(3600), checkIns: 1)
        try pairing.setClock(now + 2 * day)
        try await pairing.advance()
        XCTAssertEqual(Set(try pairing.missedCheckInMail()), Set(firstBatch))
        try pairing.setClock(now + 2 * day + 1)
        try await pairing.advance()
        XCTAssertEqual(try pairing.missedCheckInMail().count, 4)
    }

    private func waitFor<T>(_ read: () async throws -> T?) async throws -> T {
        let deadline = ContinuousClock.now + .seconds(5)
        repeat {
            if let value = try await read() { return value }
            try await Task.sleep(for: .milliseconds(25))
        } while ContinuousClock.now < deadline
        throw ServiceError.failed("The background worker or alert did not reach the loopback fixture.")
    }
}
