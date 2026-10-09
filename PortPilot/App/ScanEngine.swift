import Darwin
import Foundation

/// Result of one background scan, handed to the main actor.
struct ScanOutput {
    let snapshot: ScanSnapshot
    /// Kill plan per listener identity of the groups the scan was asked to plan (all of them for headless modes;
    /// the expanded rows for the panel), so the UI can preview what Stop will do. Stop computes fresh plans.
    let plans: [ProcessIdentity: KillPlan]
    /// Protected folders (e.g. ~/Downloads) whose project lookups are blocked right now, most likely behind a macOS
    /// folder-access prompt. Projects there show provisionally (by folder name) until access is granted.
    let foldersAwaitingAccess: [String]

    init(snapshot: ScanSnapshot, plans: [ProcessIdentity: KillPlan], foldersAwaitingAccess: [String] = []) {
        self.snapshot = snapshot
        self.plans = plans
        self.foldersAwaitingAccess = foldersAwaitingAccess
    }
}

/// Owns every non-UI service and runs all scanning / process control work off the main thread, so the main
/// thread never blocks on syscalls or subprocesses.
///
/// Scans run on `queue`. Work behind a button (fresh kill plans for Stop, Startup Items, plan previews) runs on
/// `controlQueue`, so it never waits for a scan that is slow (a big process table, or a project lookup stuck
/// behind a macOS folder-access prompt).
///
/// Sendable by confinement: scan bookkeeping is only touched on `queue`, what both queues read is guarded by
/// `stateLock`, and the services it exposes are thread-safe.
final class ScanEngine: @unchecked Sendable {
    let queue = DispatchQueue(label: "eu.shhshm.PortPilot.scan", qos: .utility)
    /// Stop, Startup Items and plan previews: never queued behind a scan, nor behind each other (concurrent: its
    /// work only reads shared state under locks, so a Stop never waits for a slow `launchctl`).
    let controlQueue = DispatchQueue(label: "eu.shhshm.PortPilot.control", qos: .userInitiated, attributes: .concurrent)

    let scanner = ProcessScanner()
    let resolver: ProjectResolver
    let launchd = LaunchdService()
    let pm2 = PM2Service()
    let docker = DockerService()
    let killer = ProcessKiller()
    let currentUID = SysProc.currentUID
    /// Per-process classification memo shared by every tick (pruned with the process table).
    let traits = ProcessTraitsCache()

    // `launchctl list` is a subprocess. A process's job never changes while it runs, so the pid → label map is only
    // read again when a launchd-started process in some listener's lineage is newer than the last read
    // (see `launchdLabelsNeedRefresh`). Scan-queue only.
    private var launchdLabels: [Int32: String] = [:]
    /// When `launchdLabels` was read, µs since 1970 (like `ProcessBasic.startTime`); 0 = read again.
    private var launchdLabelsReadAt: UInt64 = 0
    /// Job details per label for the pid that runs it, so unchanged jobs cost no plist reads or `launchctl print`.
    private var launchdJobCache: [String: LaunchdJob] = [:]
    // `pm2 jlist` starts node (~0.1 s CPU): reused while the daemon and its children are the same processes.
    private var pm2Map: [Int32: (id: Int, name: String)] = [:]
    private var pm2MapKey: Set<ProcessIdentity>?

    // Change detection for `scan(_:)`. Scan-queue only.
    private var lastFingerprint: ListenerFingerprint?
    /// The last full scan left no project lookup pending, so its rows were final.
    private var lastBuildSettled = false
    /// Set after a control action: the next scan rebuilds even if no listener changed.
    private var rebuildRequested = true

    /// Guards `recentScans`: written by scans, read by Stop and plan previews on `controlQueue`.
    private let stateLock = NSLock()
    /// Process tables and sockets of the latest scans (newest last). Kept for a couple of scans so a Stop clicked on a
    /// row whose listener was just replaced by a watcher restart can still find the server's launch tree.
    private var recentScans: [(table: ProcessTable, sockets: [Int32: [ListeningSocket]])] = []
    /// How many scans an exited listener's launch tree can still be found from (the latest scan plus two).
    private static let recentScanRetention = 3

    /// - Parameter resolver: injectable so tests can scan without touching the user's folders.
    init(resolver: ProjectResolver = ProjectResolver()) {
        self.resolver = resolver
    }

    /// Forces the next scan to re-read launchd/pm2/docker state and rebuild every row (call after a control action).
    func invalidateManagerCaches() {
        queue.async {
            self.launchdLabelsReadAt = 0
            self.launchdJobCache = [:]
            self.pm2MapKey = nil
            self.rebuildRequested = true
            self.launchd.invalidateCaches()
            self.pm2.invalidateCache()
            self.docker.invalidateCache()
        }
    }

    // MARK: Scanning

    /// What one tick of the app's poll loop asks for.
    struct ScanRequest {
        var includeOtherUsers: Bool
        /// Groups whose listeners get kill plans (the rows expanded on screen); nil = every listener.
        var planGroupIDs: Set<String>? = nil
        /// Return nil right after the socket walk when no listener changed since the last full scan (and that scan
        /// was final). For the closed panel: the rows would come out the same, and CPU/memory aren't on screen.
        var skipIfUnchanged = false
    }

    /// A full scan with a kill plan for every listener (tests and tools).
    func scan(includeOtherUsers: Bool) async -> ScanOutput {
        await withCheckedContinuation { continuation in
            queue.async {
                continuation.resume(returning: self.scanSync(includeOtherUsers: includeOtherUsers))
            }
        }
    }

    /// One poll tick: nil when `request.skipIfUnchanged` and nothing changed. Unchanged ticks cost the process
    /// table and the socket walk only (no usage sampling, project lookups, manager subprocesses or kill plans).
    func scan(_ request: ScanRequest) async -> ScanOutput? {
        await withCheckedContinuation { continuation in
            queue.async {
                continuation.resume(returning: self.tickSync(request))
            }
        }
    }

    /// Synchronous scan for CLI modes. Never call from the engine queue.
    ///
    /// Headless output should be final: when the scan left project lookups pending (a slow disk, or a folder-access
    /// prompt the user has not answered yet), it waits up to `probeTimeout` for them and scans again, so the result
    /// shows real projects instead of provisional folder names. Pass 0 to return the first scan as it is.
    func scanBlocking(includeOtherUsers: Bool,
                      probeTimeout: TimeInterval = ScanEngine.headlessProbeTimeout) -> ScanOutput {
        let output = queue.sync { scanSync(includeOtherUsers: includeOtherUsers) }
        guard probeTimeout > 0, resolver.pendingProbeCount > 0 || !output.foldersAwaitingAccess.isEmpty else {
            return output
        }
        _ = waitForPendingProbes(timeout: probeTimeout)
        return queue.sync { scanSync(includeOtherUsers: includeOtherUsers) }
    }

    /// How long `scanBlocking` waits for pending project lookups by default.
    static let headlessProbeTimeout: TimeInterval = 5

    /// Waits at most `timeout` for project lookups that earlier scans left running; the next scan then uses their
    /// answers. Returns false on timeout. Blocks the caller: for headless modes and tests, never the main thread of
    /// the running app.
    func waitForPendingProbes(timeout: TimeInterval) -> Bool {
        resolver.waitForPendingProbes(timeout: timeout)
    }

    /// `scanSync` for tests that measure it on the engine queue (call only from `queue`).
    func scanSyncForTesting(includeOtherUsers: Bool) -> ScanOutput {
        dispatchPrecondition(condition: .onQueue(queue))
        return scanSync(includeOtherUsers: includeOtherUsers)
    }

    private func scanSync(includeOtherUsers: Bool) -> ScanOutput {
        let started = Date()
        let raw = rawScan(includeOtherUsers: includeOtherUsers)
        return build(raw, fingerprint: ListenerFingerprint(raw: raw, includeOtherUsers: includeOtherUsers),
                     planGroupIDs: nil, started: started)
    }

    private func tickSync(_ request: ScanRequest) -> ScanOutput? {
        let started = Date()
        let raw = rawScan(includeOtherUsers: request.includeOtherUsers)
        let fingerprint = ListenerFingerprint(raw: raw, includeOtherUsers: request.includeOtherUsers)
        if request.skipIfUnchanged, !rebuildRequested, lastBuildSettled, resolver.pendingProbeCount == 0,
           fingerprint == lastFingerprint {
            return nil
        }
        return build(raw, fingerprint: fingerprint, planGroupIDs: request.planGroupIDs, started: started)
    }

    /// Process table + listening sockets, remembered for Stop. Scan-queue only.
    private func rawScan(includeOtherUsers: Bool) -> RawScan {
        let raw = scanner.scan(includeOtherUsers: includeOtherUsers)
        traits.prune(keepingAliveIn: raw.table)
        stateLock.withLock {
            recentScans.append((raw.table, raw.socketsByPID))
            if recentScans.count > Self.recentScanRetention {
                recentScans.removeFirst(recentScans.count - Self.recentScanRetention)
            }
        }
        return raw
    }

    /// Builds the rows (and the requested kill plans) from a raw scan. Scan-queue only.
    private func build(_ raw: RawScan, fingerprint: ListenerFingerprint, planGroupIDs: Set<String>?,
                       started: Date) -> ScanOutput {
        let table = raw.table
        let detailsFor: (ProcessBasic) -> ProcessDetails? = { [scanner] basic in scanner.details(for: basic) }

        let listenerBasics = raw.socketsByPID.keys.compactMap { table[$0] }

        // Every listener plus its descendants, for tree CPU/memory. ListenerBuilder samples the rest of each
        // launch tree (npm, `sh -c`, sibling workers) itself through `sampleUsage`.
        var usageBasics: [Int32: ProcessBasic] = [:]
        for basic in listenerBasics {
            usageBasics[basic.pid] = basic
            // launchd (pid 1) "owns" every process; other users' trees can't be sampled anyway.
            guard basic.pid > 1, basic.uid == currentUID else { continue }
            for child in table.descendants(of: basic.pid) { usageBasics[child.pid] = child }
        }
        let usage = scanner.usage(for: Array(usageBasics.values))

        let maps = managerMaps(listeners: listenerBasics, table: table, details: detailsFor)

        let groups = ListenerBuilder.build(raw: raw, details: detailsFor, usage: usage, resolver: resolver,
                                           maps: maps, currentUID: currentUID, traits: traits,
                                           sampleUsage: { [scanner] in scanner.usage(for: $0) })

        let planned = planGroupIDs.map { ids in groups.filter { ids.contains($0.id) } } ?? groups
        let plans = Self.plans(for: planned, table: table, socketsByPID: raw.socketsByPID, details: detailsFor,
                               currentUID: currentUID)

        let foldersAwaitingAccess = resolver.foldersAwaitingAccess()
        lastFingerprint = fingerprint
        lastBuildSettled = foldersAwaitingAccess.isEmpty && resolver.pendingProbeCount == 0
        rebuildRequested = false
        let snapshot = ScanSnapshot(date: Date(), groups: groups, table: table,
                                    duration: Date().timeIntervalSince(started),
                                    restrictedCount: raw.restrictedPIDs.count)
        return ScanOutput(snapshot: snapshot, plans: plans, foldersAwaitingAccess: foldersAwaitingAccess)
    }

    /// Kill plans for every plannable listener of `groups`.
    private static func plans(for groups: [ListenerGroup], table: ProcessTable,
                              socketsByPID: [Int32: [ListeningSocket]],
                              details: (ProcessBasic) -> ProcessDetails?,
                              currentUID: UInt32) -> [ProcessIdentity: KillPlan] {
        var plans: [ProcessIdentity: KillPlan] = [:]
        for group in groups {
            for listener in group.processes where !listener.isRestricted {
                // Docker / PM2 cluster rows share their backend's identity with its own row (if any); that row's
                // plan is the one Stop and the preview use, so it wins.
                let routed = isSplitFromSharedProcess(listener)
                if routed, plans[listener.id] != nil { continue }
                plans[listener.id] = clusterAppPlan(for: listener)
                    ?? KillPlanner.plan(for: listener, table: table, details: details, currentUID: currentUID,
                                        socketsByPID: socketsByPID)
            }
        }
        return plans
    }

    /// Kill plans for the listeners of `groups` (rows just expanded), against the latest scan's process table.
    /// Runs on `controlQueue`.
    func plans(for groups: [ListenerGroup]) async -> [ProcessIdentity: KillPlan] {
        await withCheckedContinuation { continuation in
            controlQueue.async {
                let latest = self.stateLock.withLock { self.recentScans.last }
                guard let latest else { return continuation.resume(returning: [:]) }
                let detailsFor: (ProcessBasic) -> ProcessDetails? = { [scanner = self.scanner] in scanner.details(for: $0) }
                let alive = groups.map { group in
                    var copy = group
                    copy.processes = group.processes.filter { latest.table.isAlive($0.id) }
                    return copy
                }
                continuation.resume(returning: Self.plans(for: alive, table: latest.table, socketsByPID: latest.sockets,
                                                          details: detailsFor, currentUID: self.currentUID))
            }
        }
    }

    /// Rows that ListenerBuilder split off a shared process (Docker backend per container, PM2 daemon per
    /// cluster app). They are stopped through their manager.
    private static func isSplitFromSharedProcess(_ listener: ListenerProcess) -> Bool {
        switch listener.manager {
        case .docker, .pm2: return true
        case .none, .watcher, .launchd: return false
        }
    }

    /// The plan of a PM2 cluster-mode app row: nothing to signal. Its process is the God Daemon, which holds the
    /// app's port (it is the Node cluster primary) and runs every other pm2 app too, so the app is only ever stopped
    /// through pm2 — also for "Kill only this process". nil for every other row.
    static func clusterAppPlan(for listener: ListenerProcess) -> KillPlan? {
        guard case .pm2(_, let name) = listener.manager,
              PM2Service.isDaemon(listener.basic, details: listener.details) else { return nil }
        return KillPlan(root: listener.basic, targets: [], summary: [], requiresAdmin: false,
                        warnings: ["pm2 runs \(name) in cluster mode, so only pm2 can stop it"])
    }

    private func managerMaps(listeners: [ProcessBasic], table: ProcessTable,
                             details: (ProcessBasic) -> ProcessDetails?) -> ManagerMaps {
        var maps = ManagerMaps()

        let lineages = listeners.map { [$0] + table.ancestors(of: $0.pid) }

        // launchd: only relevant when some listener (or an ancestor) was started by launchd directly.
        let startedByLaunchd = lineages.flatMap { $0.filter { $0.ppid == 1 && $0.pid > 1 } }
        if !startedByLaunchd.isEmpty {
            let now = Self.microsecondsSince1970()
            if Self.launchdLabelsNeedRefresh(candidates: startedByLaunchd, readAt: launchdLabelsReadAt, now: now) {
                launchdLabels = launchd.runningJobLabels()
                // An empty list means launchctl failed: try again on the next full scan.
                launchdLabelsReadAt = launchdLabels.isEmpty ? 0 : now
            }
            maps.launchdLabelsByPID = launchdLabels
            var jobs: [String: LaunchdJob] = [:]
            for lineage in lineages {
                // Nearest real job wins; GUI app instances ("application.*") and Apple jobs are skipped so a job
                // further up the tree is still found.
                for candidate in lineage where candidate.pid > 1 {
                    guard let label = launchdLabels[candidate.pid],
                          !LaunchdService.isAppInstanceLabel(label), !label.hasPrefix("com.apple.") else { continue }
                    if jobs[label] == nil {
                        if let cached = launchdJobCache[label], cached.pid == candidate.pid {
                            jobs[label] = cached
                        } else if let job = launchd.job(label: label, pid: candidate.pid) {
                            jobs[label] = job
                        }
                    }
                    break
                }
            }
            maps.launchdJobs = jobs
            launchdJobCache = jobs
        }

        // pm2: only query when a running PM2 God Daemon is a listener or one of its ancestors (pm2 jlist would
        // spawn a daemon otherwise). In cluster mode the daemon itself holds the apps' sockets.
        var daemons: [Int32: ProcessBasic] = [:]
        for lineage in lineages {
            for process in lineage where PM2Service.isDaemon(process, details: details(process)) {
                daemons[process.pid] = process
            }
        }
        if !daemons.isEmpty {
            // pm2's pid → app map only changes when the daemon starts or stops a process.
            var key = Set<ProcessIdentity>()
            for daemon in daemons.values {
                key.insert(daemon.identity)
                for child in table.childrenByPID[daemon.pid] ?? [] {
                    if let process = table[child] { key.insert(process.identity) }
                }
            }
            if key != pm2MapKey {
                pm2Map = pm2.processesByPID()
                pm2MapKey = pm2Map.isEmpty ? nil : key
            }
            maps.pm2ByPID = pm2Map
        }

        // Docker: only when a Docker/OrbStack/Colima backend process owns a listening port.
        let dockerOwned = listeners.contains { DockerService.isDockerBackend($0, details: details($0)) }
        if dockerOwned {
            maps.dockerByPort = docker.containersByHostPort()
        }
        return maps
    }

    /// True when `launchctl list` must be read again: never read, read over `maxAge` ago, or a launchd-started
    /// process in a listener's lineage is not clearly older than the last read (it may be a job the read missed).
    /// All times in µs since 1970.
    static func launchdLabelsNeedRefresh(candidates: [ProcessBasic], readAt: UInt64, now: UInt64,
                                         maxAge: UInt64 = launchdLabelsMaxAge) -> Bool {
        guard readAt > 0, now >= readAt, now - readAt <= maxAge else { return true }
        return candidates.contains { $0.startTime + launchdStartMargin >= readAt }
    }

    /// Safety net against clock changes: `launchctl list` is read at least this often while scans need it (µs).
    static let launchdLabelsMaxAge: UInt64 = 300_000_000
    /// A process started this close to a read may have been missed by it (µs).
    private static let launchdStartMargin: UInt64 = 1_000_000

    private static func microsecondsSince1970() -> UInt64 {
        UInt64(max(0, Date().timeIntervalSince1970 * 1_000_000))
    }

    // MARK: Startup items

    func startupItems() async -> [StartupItem] {
        await withCheckedContinuation { continuation in
            controlQueue.async { continuation.resume(returning: self.launchd.startupItems()) }
        }
    }

    // MARK: Control

    /// Fresh kill plans for the given listeners, computed against a brand-new process table so that
    /// children spawned since the last scan are included.
    ///
    /// A listener that exited since the scan was usually replaced by its watcher or runner (nodemon,
    /// `node --watch` and uvicorn --reload start a new server process on every save). Its plan then targets the
    /// process that holds its port again inside the same launch tree or, while the new server is still starting,
    /// the launch root the scan-time plan had. Only a listener whose whole tree is gone gets no plan.
    func freshPlans(for listeners: [ListenerProcess], onlyThisProcess: Bool) async -> [KillPlan] {
        await withCheckedContinuation { continuation in
            controlQueue.async {
                if onlyThisProcess {
                    continuation.resume(returning: listeners.map {
                        Self.clusterAppPlan(for: $0) ?? KillPlanner.singleProcessPlan(for: $0)
                    })
                    return
                }
                let table = ProcessTable(processes: SysProc.allProcesses())
                let detailsFor: (ProcessBasic) -> ProcessDetails? = { [scanner = self.scanner] in scanner.details(for: $0) }
                let lastSockets = self.stateLock.withLock { self.recentScans.last?.sockets ?? [:] }
                var seenRoots = Set<ProcessIdentity>()
                var plans: [KillPlan] = []
                for listener in listeners {
                    if let plan = Self.clusterAppPlan(for: listener) {
                        if seenRoots.insert(plan.root.identity).inserted { plans.append(plan) }
                        continue
                    }
                    let target: ListenerProcess
                    if table.isAlive(listener.id) {
                        target = listener
                    } else if let successor = self.successor(of: listener, in: table, details: detailsFor) {
                        target = successor
                    } else {
                        continue
                    }
                    let plan = KillPlanner.plan(for: target, table: table, details: detailsFor,
                                                currentUID: self.currentUID, socketsByPID: lastSockets)
                    if seenRoots.insert(plan.root.identity).inserted { plans.append(plan) }
                }
                continuation.resume(returning: plans)
            }
        }
    }

    /// What Stop should act on for a listener whose process is gone (see `freshPlans`). Control-queue only.
    ///
    /// Looks inside the launch tree the listener belonged to: below the scan-time plan root when that is an
    /// ancestor that is still the same process, else below the listener's parent when a watcher supervised it
    /// (and that parent is still running, plausibly its parent, and not protected). Returns a copy of the listener
    /// pointing at the process that listens on one of its ports now, or — only for a scan-time plan root — at that
    /// root, which is what the original Stop would have signalled. nil when nothing of the tree is left.
    private func successor(of listener: ListenerProcess, in table: ProcessTable,
                           details: (ProcessBasic) -> ProcessDetails?) -> ListenerProcess? {
        guard listener.basic.uid == currentUID, !listener.isRestricted, !listener.ports.isEmpty else { return nil }

        let anchor: ProcessBasic
        let anchorIsPlanRoot: Bool
        if let root = scanTimeRoot(of: listener, details: details), root.identity != listener.id,
           let live = table[root.pid], live.startTime == root.startTime {
            anchor = live
            anchorIsPlanRoot = true
        } else if case .watcher = listener.manager, let parent = table[listener.basic.ppid], parent.pid > 1,
                  parent.uid == currentUID, parent.startTime <= listener.basic.startTime,
                  !KillPlanner.isProtected(parent, details: details(parent)) {
            anchor = parent
            anchorIsPlanRoot = false
        } else {
            return nil
        }

        let ports = Set(listener.ports)
        var fdBuffer: [proc_fdinfo] = []
        let candidates = [anchor] + table.descendants(of: anchor.pid).prefix(Self.maxSuccessorCandidates)
        for candidate in candidates where candidate.pid > 1 && candidate.uid == currentUID {
            guard let sockets = SysProc.listeningTCPSockets(pid: candidate.pid, fdBuffer: &fdBuffer),
                  sockets.contains(where: { ports.contains($0.port) }),
                  SysProc.basic(pid: candidate.pid)?.startTime == candidate.startTime   // not recycled meanwhile
            else { continue }
            return listener.replacingProcess(candidate, details: details(candidate), sockets: sockets)
        }
        guard anchorIsPlanRoot else { return nil }
        return listener.replacingProcess(anchor, details: details(anchor), sockets: [])
    }

    /// Bound on processes inspected when looking for a restarted server.
    private static let maxSuccessorCandidates = 256

    /// The kill-plan root a listener had at scan time, worked out in the newest of the recent scans' process tables
    /// in which it was still alive. nil when it exited before all of them.
    private func scanTimeRoot(of listener: ListenerProcess,
                              details: (ProcessBasic) -> ProcessDetails?) -> ProcessBasic? {
        let tables = stateLock.withLock { recentScans.map(\.table) }
        guard let table = tables.last(where: { $0.isAlive(listener.id) }) else { return nil }
        return KillPlanner.plan(for: listener, table: table, details: details, currentUID: currentUID).root
    }

    // MARK: Still running without a port

    /// What still runs of groups whose ports all closed since the previous full scan: for each listener, the launch
    /// tree it had then (worked out in `previousTable`, where it still listened) as far as it is alive now. Groups
    /// with nothing left, or whose tree listens again elsewhere, are left out. Runs on `controlQueue`.
    func leftovers(of groups: [ListenerGroup], previousTable: ProcessTable, closedAt: Date = Date()) async -> [StillRunningItem] {
        await withCheckedContinuation { continuation in
            controlQueue.async {
                let latest = self.stateLock.withLock { self.recentScans.last }
                guard let latest else { return continuation.resume(returning: []) }
                let detailsFor: (ProcessBasic) -> ProcessDetails? = { [scanner = self.scanner] in scanner.details(for: $0) }
                var items: [StillRunningItem] = []
                for group in groups {
                    if let item = self.leftover(of: group, previousTable: previousTable, table: latest.table,
                                                details: detailsFor, closedAt: closedAt) {
                        items.append(item)
                    }
                }
                let serving = StillRunning.servingPIDs(listenerPIDs: Set(latest.sockets.keys), table: latest.table)
                items = StillRunning.refreshed(items, table: latest.table, servingPIDs: serving,
                                               usage: self.usage(of: items))
                continuation.resume(returning: items)
            }
        }
    }

    /// `items` against the latest scan: exited processes dropped, items that exited or listen again removed, and
    /// (when `sampleUsage`) fresh CPU/memory. Runs on `controlQueue`.
    func refreshLeftovers(_ items: [StillRunningItem], sampleUsage: Bool) async -> [StillRunningItem] {
        await withCheckedContinuation { continuation in
            controlQueue.async {
                guard let latest = self.stateLock.withLock({ self.recentScans.last }) else {
                    return continuation.resume(returning: items)
                }
                let serving = StillRunning.servingPIDs(listenerPIDs: Set(latest.sockets.keys), table: latest.table)
                var alive = StillRunning.refreshed(items, table: latest.table, servingPIDs: serving, usage: nil)
                if sampleUsage {
                    alive = StillRunning.refreshed(alive, table: latest.table, servingPIDs: serving,
                                                   usage: self.usage(of: alive))
                }
                continuation.resume(returning: alive)
            }
        }
    }

    private func leftover(of group: ListenerGroup, previousTable: ProcessTable, table: ProcessTable,
                          details: (ProcessBasic) -> ProcessDetails?, closedAt: Date) -> StillRunningItem? {
        var root: ProcessBasic?
        var processes: [ProcessBasic] = []
        var labels: [Int32: String] = [:]
        for listener in group.processes where listener.basic.uid == currentUID && !listener.isRestricted {
            let anchor: ListenerProcess
            if let live = table[listener.basic.pid], live.startTime == listener.basic.startTime {
                anchor = listener   // closed its socket but still runs
            } else if previousTable.isAlive(listener.id) {
                let launchRoot = KillPlanner.plan(for: listener, table: previousTable, details: details,
                                                  currentUID: currentUID).root
                guard launchRoot.identity != listener.id, let live = table[launchRoot.pid],
                      live.startTime == launchRoot.startTime else { continue }
                anchor = listener.replacingProcess(live, details: details(live), sockets: [])
            } else {
                continue
            }
            let plan = KillPlanner.plan(for: anchor, table: table, details: details, currentUID: currentUID)
            for target in plan.targets where target.uid == currentUID && !processes.contains(where: { $0.pid == target.pid }) {
                processes.append(target)
                labels[target.pid] = KillPlanner.label(for: target, details: details(target))
            }
            if root == nil, !plan.targets.isEmpty { root = plan.root }
        }
        guard let root, !processes.isEmpty else { return nil }
        return StillRunningItem(id: group.id, title: group.title, path: group.path, formerPorts: group.ports,
                                closedAt: closedAt, root: root, processes: processes, labels: labels, usage: .zero)
    }

    private func usage(of items: [StillRunningItem]) -> [Int32: ResourceUsage] {
        let processes = items.flatMap(\.processes)
        return processes.isEmpty ? [:] : scanner.usage(for: processes)
    }

    /// Runs a throwing control action off the main thread.
    func perform(_ work: @escaping () throws -> Void) async -> Error? {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    try work()
                    continuation.resume(returning: nil)
                } catch {
                    continuation.resume(returning: error)
                }
            }
        }
    }
}

private extension ListenerProcess {
    /// The same row (project, manager, origin, …) for another process that took over its role.
    func replacingProcess(_ basic: ProcessBasic, details: ProcessDetails?, sockets: [ListeningSocket]) -> ListenerProcess {
        ListenerProcess(basic: basic, details: details, sockets: sockets, usage: usage, treeUsage: treeUsage,
                        category: category, project: project, displayName: displayName, frameworks: frameworks,
                        origin: origin, manager: manager, appName: appName, isRestricted: details == nil)
    }
}

/// What a scan's rows depend on that can change from one tick to the next: every listener (identity, name, parent)
/// with its sockets. Equal fingerprints give the same rows, apart from CPU/memory and project lookups that were
/// still pending (`ScanEngine` rebuilds while any are).
struct ListenerFingerprint: Equatable {
    struct Listener: Equatable {
        let comm: String
        let ppid: Int32
        let sockets: Set<ListeningSocket>
    }

    let includeOtherUsers: Bool
    let listeners: [ProcessIdentity: Listener]
    let restrictedPIDs: Set<Int32>

    init(raw: RawScan, includeOtherUsers: Bool) {
        var listeners: [ProcessIdentity: Listener] = [:]
        listeners.reserveCapacity(raw.socketsByPID.count)
        for (pid, sockets) in raw.socketsByPID {
            let basic = raw.table[pid]
            let identity = basic?.identity ?? ProcessIdentity(pid: pid, startTime: 0)
            listeners[identity] = Listener(comm: basic?.comm ?? "", ppid: basic?.ppid ?? 0, sockets: Set(sockets))
        }
        self.includeOtherUsers = includeOtherUsers
        self.listeners = listeners
        self.restrictedPIDs = raw.restrictedPIDs
    }
}
