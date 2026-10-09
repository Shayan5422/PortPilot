import Foundation

/// Result of one background scan, handed to the main actor.
struct ScanOutput {
    let snapshot: ScanSnapshot
    /// Kill plan per listener identity, precomputed so the UI can preview what Stop will do.
    let plans: [ProcessIdentity: KillPlan]
}

/// Owns every non-UI service and runs all scanning / process control work on its own serial queue,
/// so the main thread never blocks on syscalls or subprocesses.
final class ScanEngine {
    let queue = DispatchQueue(label: "app.portpilot.scan", qos: .utility)

    let scanner = ProcessScanner()
    let resolver = ProjectResolver()
    let launchd = LaunchdService()
    let pm2 = PM2Service()
    let docker = DockerService()
    let killer = ProcessKiller()
    let currentUID = SysProc.currentUID

    // launchd `list` is a subprocess: cache it briefly.
    private var launchdLabels: [Int32: String] = [:]
    private var launchdLabelsDate: Date = .distantPast
    private let launchdLabelsTTL: TimeInterval = 10

    /// Sockets from the latest scan, for ":port" annotations in fresh kill plans. Engine-queue only.
    private var lastSocketsByPID: [Int32: [ListeningSocket]] = [:]

    /// Forces the next scan to re-read launchd/pm2/docker state (call after a control action).
    func invalidateManagerCaches() {
        queue.async {
            self.launchdLabelsDate = .distantPast
            self.launchd.invalidateCaches()
            self.pm2.invalidateCache()
            self.docker.invalidateCache()
        }
    }

    // MARK: Scanning

    func scan(includeOtherUsers: Bool) async -> ScanOutput {
        await withCheckedContinuation { continuation in
            queue.async {
                continuation.resume(returning: self.scanSync(includeOtherUsers: includeOtherUsers))
            }
        }
    }

    /// Synchronous scan for CLI modes. Never call from the engine queue.
    func scanBlocking(includeOtherUsers: Bool) -> ScanOutput {
        queue.sync { scanSync(includeOtherUsers: includeOtherUsers) }
    }

    private func scanSync(includeOtherUsers: Bool) -> ScanOutput {
        let started = Date()
        let raw = scanner.scan(includeOtherUsers: includeOtherUsers)
        let table = raw.table
        let detailsFor: (ProcessBasic) -> ProcessDetails? = { [scanner] basic in scanner.details(for: basic) }

        let listenerBasics = raw.socketsByPID.keys.compactMap { table[$0] }

        // Every listener plus its descendants, for tree CPU/memory.
        var usageBasics: [Int32: ProcessBasic] = [:]
        for basic in listenerBasics {
            usageBasics[basic.pid] = basic
            // launchd (pid 1) "owns" every process; other users' trees can't be sampled anyway.
            guard basic.pid > 1, basic.uid == currentUID else { continue }
            for child in table.descendants(of: basic.pid) { usageBasics[child.pid] = child }
        }
        let usage = scanner.usage(for: Array(usageBasics.values))

        let maps = managerMaps(listeners: listenerBasics, table: table, sockets: raw.socketsByPID, details: detailsFor)

        let groups = ListenerBuilder.build(raw: raw, details: detailsFor, usage: usage,
                                           resolver: resolver, maps: maps, currentUID: currentUID)

        var plans: [ProcessIdentity: KillPlan] = [:]
        for group in groups {
            for listener in group.processes where !listener.isRestricted {
                plans[listener.id] = KillPlanner.plan(for: listener, table: table, details: detailsFor,
                                                      currentUID: currentUID, socketsByPID: raw.socketsByPID)
            }
        }

        lastSocketsByPID = raw.socketsByPID
        let snapshot = ScanSnapshot(date: Date(), groups: groups, table: table,
                                    duration: Date().timeIntervalSince(started),
                                    restrictedCount: raw.restrictedPIDs.count)
        return ScanOutput(snapshot: snapshot, plans: plans)
    }

    private func managerMaps(listeners: [ProcessBasic], table: ProcessTable,
                             sockets: [Int32: [ListeningSocket]],
                             details: (ProcessBasic) -> ProcessDetails?) -> ManagerMaps {
        var maps = ManagerMaps()

        // launchd: only relevant when some listener (or an ancestor) was started by launchd directly.
        let launchedByLaunchd = listeners.contains { basic in
            basic.ppid == 1 || table.ancestors(of: basic.pid).contains { $0.ppid == 1 && $0.pid != 1 }
        }
        if launchedByLaunchd {
            if Date().timeIntervalSince(launchdLabelsDate) > launchdLabelsTTL {
                launchdLabels = launchd.runningJobLabels()
                launchdLabelsDate = Date()
            }
            maps.launchdLabelsByPID = launchdLabels
            for basic in listeners {
                // Nearest real job wins; GUI app instances ("application.*") and Apple jobs are skipped so a job
                // further up the tree is still found.
                for candidate in [basic] + table.ancestors(of: basic.pid) where candidate.pid > 1 {
                    guard let label = launchdLabels[candidate.pid],
                          !LaunchdService.isAppInstanceLabel(label), !label.hasPrefix("com.apple.") else { continue }
                    if maps.launchdJobs[label] == nil, let job = launchd.job(label: label, pid: candidate.pid) {
                        maps.launchdJobs[label] = job
                    }
                    break
                }
            }
        }

        // pm2: only query when a listener descends from a running PM2 God Daemon (pm2 jlist would spawn one otherwise).
        let underPM2 = listeners.contains { basic in
            table.ancestors(of: basic.pid).contains { PM2Service.isDaemon($0, details: details($0)) }
        }
        if underPM2 {
            maps.pm2ByPID = pm2.processesByPID()
        }

        // Docker: only when a Docker/OrbStack/Colima backend process owns a listening port.
        let dockerOwned = listeners.contains { DockerService.isDockerBackend($0, details: details($0)) }
        if dockerOwned {
            maps.dockerByPort = docker.containersByHostPort()
        }
        _ = sockets
        return maps
    }

    // MARK: Startup items

    func startupItems() async -> [StartupItem] {
        await withCheckedContinuation { continuation in
            queue.async { continuation.resume(returning: self.launchd.startupItems()) }
        }
    }

    // MARK: Control

    /// Fresh kill plans for the given listeners, computed against a brand-new process table so that
    /// children spawned since the last scan are included.
    func freshPlans(for listeners: [ListenerProcess], onlyThisProcess: Bool) async -> [KillPlan] {
        await withCheckedContinuation { continuation in
            queue.async {
                if onlyThisProcess {
                    continuation.resume(returning: listeners.map { KillPlanner.singleProcessPlan(for: $0) })
                    return
                }
                let table = ProcessTable(processes: SysProc.allProcesses())
                let detailsFor: (ProcessBasic) -> ProcessDetails? = { [scanner = self.scanner] in scanner.details(for: $0) }
                var seenRoots = Set<ProcessIdentity>()
                var plans: [KillPlan] = []
                for listener in listeners where table.isAlive(listener.id) {
                    let plan = KillPlanner.plan(for: listener, table: table, details: detailsFor,
                                                currentUID: self.currentUID, socketsByPID: self.lastSocketsByPID)
                    if seenRoots.insert(plan.root.identity).inserted { plans.append(plan) }
                }
                continuation.resume(returning: plans)
            }
        }
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
