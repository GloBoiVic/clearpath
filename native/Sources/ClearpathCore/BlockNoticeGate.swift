import Foundation

/// Publishes only that a blocked lookup occurred. The timestamp is transient process memory;
/// it does not retain a domain, attempt, or count.
public final class BlockNoticeGate: @unchecked Sendable {
    private let lock = NSLock()
    private let minimumInterval: TimeInterval
    private let now: @Sendable () -> Date
    private let publish: @Sendable () -> Void
    private var lastPublished: Date?

    public init(minimumInterval: TimeInterval = 30,
                now: @escaping @Sendable () -> Date = { Date() },
                publish: @escaping @Sendable () -> Void) {
        self.minimumInterval = max(0, minimumInterval)
        self.now = now
        self.publish = publish
    }

    public func blockedLookup() {
        let current = now()
        lock.lock()
        guard lastPublished.map({ current.timeIntervalSince($0) >= minimumInterval }) ?? true else {
            lock.unlock()
            return
        }
        lastPublished = current
        lock.unlock()
        publish()
    }
}
