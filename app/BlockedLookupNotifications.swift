import Foundation
import CoreFoundation
import UserNotifications

/// Converts the daemon's payload-free local event into a generic user notification.
/// The app must be running to observe events; DNS filtering itself remains in the daemon.
final class BlockedLookupNotifications: @unchecked Sendable {
    private static let eventName = "org.clearpath.blocked-lookup" as CFString

    func start() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert]) { _, _ in }
        CFNotificationCenterAddObserver(CFNotificationCenterGetDarwinNotifyCenter(),
                                        Unmanaged.passUnretained(self).toOpaque(),
                                        Self.receivedEvent, Self.eventName, nil, .deliverImmediately)
    }

    private static let receivedEvent: CFNotificationCallback = { _, observer, _, _, _ in
        guard let observer else { return }
        let listener = Unmanaged<BlockedLookupNotifications>.fromOpaque(observer).takeUnretainedValue()
        DispatchQueue.main.async { listener.showNotice() }
    }

    private func showNotice() {
        let content = UNMutableNotificationContent()
        content.title = "Blocked by Clearpath"
        content.body = "A site was blocked."
        content.sound = nil
        let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }
}
