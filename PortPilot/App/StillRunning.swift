import Foundation

/// A tool whose ports all closed while some of its processes kept running (and using CPU and memory), and that
/// PortPilot did not stop: a crashed server under `npm run dev` with a sibling worker, or a tool that closed its
/// socket but never exited. Shown under "Still running · no open port" with a Stop button until it exits.
struct StillRunningItem: Identifiable, Equatable, Sendable {
    /// The former group's id ("project:/path", "pid:…").
    let id: String
    let title: String
    /// The former group's folder.
    let path: String?
    /// Ports it listened on before they closed.
    let formerPorts: [UInt16]
    /// When PortPilot noticed the ports were gone.
    let closedAt: Date
    /// Launch root of what still runs (the root Stop would have used for the whole tool).
    let root: ProcessBasic
    /// Processes still running, children first (the order Stop signals them in).
    var processes: [ProcessBasic]
    /// Short label per pid, e.g. "npm run dev", "node worker.js".
    let labels: [Int32: String]
    /// CPU and memory of `processes`.
    var usage: ResourceUsage

    /// Key in `AppStore.busyGroupIDs` while its Stop runs.
    var busyID: String { "still:" + id }

    /// "npm run dev, node worker.js" (deduplicated, in Stop order reversed so the launcher comes first).
    var processSummary: String {
        var seen = Set<String>()
        return processes.reversed().compactMap { labels[$0.pid] }.filter { seen.insert($0).inserted }
            .joined(separator: ", ")
    }

    /// What Stop signals: exactly the processes still running, re-verified by `ProcessKiller` before each signal.
    var plan: KillPlan {
        KillPlan(root: root, targets: processes,
                 summary: processes.map { "\(labels[$0.pid] ?? $0.comm) (pid \($0.pid))" },
                 requiresAdmin: false, warnings: [])
    }
}

/// Pure rules behind "Still running · no open port" (unit tested). `ScanEngine.leftovers` finds the processes,
/// `AppStore` keeps the list.
enum StillRunning {
    /// Entries kept at most; the oldest drop off.
    static let maxItems = 10

    /// Groups of `previous` whose ports all closed in `current` and that may have left processes behind. Only
    /// projects and plain services of this user: Docker, pm2 and launchd jobs come back or are managed by their
    /// manager, and apps open and close ports all the time. Groups PortPilot is stopping or just stopped, and
    /// groups the user hid, are left out. A group counts as gone only when none of its ports listens any more
    /// (a server restarted under another group keeps its ports).
    static func vanishedGroups(previous: [ListenerGroup], current: [ListenerGroup], stoppedPorts: Set<UInt16>,
                               busyGroupIDs: Set<String>, ignoredGroupIDs: Set<String>, ignoredPorts: Set<UInt16>,
                               currentUID: UInt32) -> [ListenerGroup] {
        let currentIDs = Set(current.map(\.id))
        let currentPorts = Set(current.flatMap(\.ports))
        return previous.filter { group in
            guard group.category == .project || group.category == .service else { return false }
            switch group.manager {
            case .none, .watcher: break
            case .launchd, .pm2, .docker: return false
            }
            guard !group.ports.isEmpty, !currentIDs.contains(group.id), currentPorts.isDisjoint(with: group.ports),
                  stoppedPorts.isDisjoint(with: group.ports), !busyGroupIDs.contains(group.id),
                  !ignoredGroupIDs.contains(group.id) else { return false }
            if !ignoredPorts.isEmpty, group.ports.allSatisfy(ignoredPorts.contains) { return false }
            return group.processes.contains { $0.basic.uid == currentUID && !$0.isRestricted }
        }
    }

    /// Processes that serve ports now: every listener and its ancestors. A leftover that contains one of them is
    /// listening again (it is back in the list) and must not be shown twice.
    static func servingPIDs(listenerPIDs: Set<Int32>, table: ProcessTable) -> Set<Int32> {
        var result = listenerPIDs
        for pid in listenerPIDs {
            for ancestor in table.ancestors(of: pid) { result.insert(ancestor.pid) }
        }
        return result
    }

    /// `items` against a newer process table: exited processes dropped, and items with nothing left or that serve a
    /// port again removed. With `usage`, each item's CPU and memory become the sum over its processes.
    static func refreshed(_ items: [StillRunningItem], table: ProcessTable, servingPIDs: Set<Int32>,
                          usage: [Int32: ResourceUsage]?) -> [StillRunningItem] {
        items.compactMap { item in
            var item = item
            item.processes = item.processes.filter { table.isAlive($0.identity) }
            guard !item.processes.isEmpty, !item.processes.contains(where: { servingPIDs.contains($0.pid) }) else {
                return nil
            }
            if let usage {
                item.usage = item.processes.reduce(.zero) { $0 + (usage[$1.pid] ?? .zero) }
            }
            return item
        }
    }

    /// Newly found items first, replacing older entries of the same group or launch root, at most `maxItems`.
    static func merged(_ found: [StillRunningItem], into items: [StillRunningItem]) -> [StillRunningItem] {
        let ids = Set(found.map(\.id))
        let roots = Set(found.map(\.root.identity))
        let kept = items.filter { !ids.contains($0.id) && !roots.contains($0.root.identity) }
        return Array((found + kept).prefix(maxItems))
    }

    /// Short feedback for tools that closed on their own and left nothing running: "my-app closed (:5173)",
    /// "my-app and 2 more closed". nil for no groups.
    static func closedMessage(for groups: [ListenerGroup]) -> String? {
        guard let first = groups.first else { return nil }
        if groups.count == 1 {
            let ports = first.ports.prefix(3).map { ":\($0)" }.joined(separator: ", ")
            return ports.isEmpty ? "\(first.title) closed" : "\(first.title) closed (\(ports))"
        }
        return "\(first.title) and \(groups.count - 1) more closed"
    }
}
