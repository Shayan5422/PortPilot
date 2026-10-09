import Foundation
import os
import UserNotifications

/// "New port opened" notifications.
///
/// Stateful: call `notifyNewPorts` with the *full* current list of (visible) groups after every scan. The first call
/// only records a baseline (no burst of notifications at launch); afterwards a port is "new" when no group had it
/// in the previous call. At most one notification per group per `throttleInterval` (SPEC: 60 s).
///
/// Thread-safe. A no-op when the process has no bundle identifier (CLI / test harness runs), because
/// `UNUserNotificationCenter.current()` crashes outside an app bundle.
final class Notifier {
    /// What would be (or was) posted; exposed for tests.
    struct PortNotification: Equatable {
        let groupID: String
        let ports: [UInt16]
        let title: String
        let body: String
    }

    private let throttleInterval: TimeInterval
    private let categories: Set<ListenerCategory>
    private let now: () -> Date
    private let lock = NSLock()
    private let logger = Logger(subsystem: "app.portpilot", category: "Notifier")
    private let presenter = ForegroundPresenter()

    // Guarded by `lock`.
    private var knownPorts: Set<UInt16> = []
    private var hasBaseline = false
    private var lastNotified: [String: Date] = [:]
    private var authorizationRequested = false

    /// - Parameters:
    ///   - categories: only groups in these categories notify (apps/system churn ports constantly).
    ///   - now: clock, injectable for tests.
    init(throttleInterval: TimeInterval = 60, categories: Set<ListenerCategory> = [.project, .service],
         now: @escaping () -> Date = Date.init) {
        self.throttleInterval = throttleInterval
        self.categories = categories
        self.now = now
    }

    /// True when UserNotifications can be used from this process.
    static var isAvailable: Bool { Bundle.main.bundleIdentifier != nil }

    func requestAuthorizationIfNeeded() {
        guard Self.isAvailable else { return }
        let shouldRequest = lock.withLock { () -> Bool in
            defer { authorizationRequested = true }
            return !authorizationRequested
        }
        guard shouldRequest else { return }
        let center = UNUserNotificationCenter.current()
        center.delegate = presenter
        center.getNotificationSettings { [logger] settings in
            guard settings.authorizationStatus == .notDetermined else { return }
            UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, error in
                if let error {
                    logger.error("Notification authorization failed: \(error.localizedDescription, privacy: .public)")
                }
            }
        }
    }

    /// "New port opened: :5173 — my-app (Vite)". Throttle: max 1 per group per 60 s.
    func notifyNewPorts(_ groups: [ListenerGroup]) {
        let notifications = pendingNotifications(for: groups)
        guard !notifications.isEmpty, Self.isAvailable else { return }
        requestAuthorizationIfNeeded()
        let center = UNUserNotificationCenter.current()
        for notification in notifications {
            let content = UNMutableNotificationContent()
            content.title = notification.title
            content.body = notification.body
            content.threadIdentifier = "new-ports"
            // One identifier per group: a newer notification for the same group replaces the older one.
            let request = UNNotificationRequest(identifier: "new-port:\(notification.groupID)", content: content,
                                                trigger: nil)
            center.add(request) { [logger] error in
                if let error {
                    logger.error("Couldn't post notification: \(error.localizedDescription, privacy: .public)")
                }
            }
        }
    }

    /// Forget the baseline, e.g. when the user turns notifications back on (avoids a burst for everything that
    /// opened while they were off).
    func resetBaseline() {
        lock.withLock {
            hasBaseline = false
            knownPorts = []
        }
    }

    /// Diffs `groups` against the previous call, applies the throttle and updates state. Posts nothing.
    func pendingNotifications(for groups: [ListenerGroup]) -> [PortNotification] {
        let relevant = groups.filter { categories.contains($0.category) }
        let currentPorts = Set(relevant.flatMap(\.ports))
        let date = now()
        return lock.withLock {
            defer {
                knownPorts = currentPorts
                hasBaseline = true
                lastNotified = lastNotified.filter { date.timeIntervalSince($0.value) < throttleInterval }
            }
            guard hasBaseline else { return [] }
            var result: [PortNotification] = []
            for group in relevant {
                let newPorts = group.ports.filter { !knownPorts.contains($0) }
                guard !newPorts.isEmpty else { continue }
                if let last = lastNotified[group.id], date.timeIntervalSince(last) < throttleInterval { continue }
                lastNotified[group.id] = date
                result.append(Self.makeNotification(for: group, ports: newPorts))
            }
            return result
        }
    }

    static func makeNotification(for group: ListenerGroup, ports: [UInt16]) -> PortNotification {
        let portList = ports.map { ":\($0)" }.joined(separator: ", ")
        var name = group.title
        if let framework = group.frameworks.first { name += " (\(framework))" }
        let title = "New port opened: \(portList)"
        var body = name
        if let path = group.path { body += " — " + Format.abbreviatePath(path) }
        return PortNotification(groupID: group.id, ports: ports, title: title, body: body)
    }
}

/// Shows banners even while PortPilot is the active app (the menu bar panel is open).
private final class ForegroundPresenter: NSObject, UNUserNotificationCenterDelegate {
    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .list])
    }
}
