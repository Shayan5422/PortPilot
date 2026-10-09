import AppKit
import Foundation
import Observation

/// Central state for the menu bar panel. All UI reads from here and calls its actions.
@MainActor
@Observable
final class AppStore {
    // MARK: State (read by UI)

    /// Latest scan shown in the panel (unfiltered). While the panel is closed new scans wait in `latest` and are
    /// published when it opens, so nothing that only the panel shows changes in the background.
    private(set) var snapshot: ScanSnapshot = .empty
    /// Groups after applying settings (category visibility, ignored items), search and sort.
    private(set) var visibleGroups: [ListenerGroup] = []
    /// launchd agents from ~/Library/LaunchAgents (non-Apple), with live status.
    private(set) var startupItems: [StartupItem] = []
    /// Most recent first, max 20, in-memory only.
    private(set) var recentlyStopped: [StoppedRecord] = []
    /// Tools whose ports closed while some of their processes kept running ("Still running · no open port").
    private(set) var stillRunning: [StillRunningItem] = []
    /// True while a scan runs with the panel open (drives the refresh spinner; never toggled while it's closed).
    private(set) var isScanning = false
    private(set) var lastUpdated: Date?
    /// Group ids with a stop/disable action in flight (UI shows a spinner instead of the Stop button).
    private(set) var busyGroupIDs: Set<String> = []
    /// Recently Stopped records being relaunched (UI shows a spinner instead of Relaunch).
    private(set) var relaunchingRecordIDs: Set<UUID> = []
    /// Transient feedback shown at the top of the panel.
    var banner: Banner? { didSet { scheduleBannerDismissal() } }
    /// Free-text filter (matches port, project name, path, command).
    var searchText: String = "" { didSet { recomputeVisible() } }
    /// Persisted in UserDefaults on change.
    var settings: AppSettings = AppSettings() { didSet { settingsDidChange(from: oldValue) } }
    /// Section expansion state (not persisted). Kill-plan previews are computed for expanded rows only.
    var expandedGroupIDs: Set<String> = [] { didSet { requestMissingPlans() } }
    /// True while the panel is on screen (UI sets it from the window's visibility). Opening it publishes the newest
    /// scan at once and starts a fresh full one; while it's closed, ticks skip everything only the panel shows.
    var isPanelVisible = false {
        didSet {
            guard isPanelVisible != oldValue else { return }
            if isPanelVisible {
                if hasUnpublishedScan { publish() }
                refreshNow()
            } else if isScanning {
                isScanning = false
            }
        }
    }

    /// Number shown next to the menu bar icon: distinct ports owned by `.project` groups. Stored, and assigned only
    /// when it changes, so the status item re-renders only when the number does (not on every scan).
    private(set) var menuBarCount = 0

    // MARK: Derived (read by UI)

    /// Visible groups bucketed by category, in display order, empty buckets removed.
    var sections: [(category: ListenerCategory, groups: [ListenerGroup])] {
        ListenerCategory.allCases.compactMap { cat in
            let g = visibleGroups.filter { $0.category == cat }
            return g.isEmpty ? nil : (cat, g)
        }
    }
    /// Aggregate usage of `.project` + `.service` groups.
    var devUsage: ResourceUsage {
        snapshot.groups.filter { $0.category == .project || $0.category == .service }
            .reduce(.zero) { $0 + $1.usage }
    }
    var hiddenCount: Int { snapshot.groups.count - visibleGroups.count }

    func isHeavy(_ group: ListenerGroup) -> Bool {
        group.usage.cpuPercent >= settings.heavyCPUThreshold || group.usage.memoryBytes >= settings.heavyMemoryBytes
    }

    // MARK: Private state

    @ObservationIgnored private let engine: ScanEngine?
    @ObservationIgnored private let loginItem = LoginItemManager()
    @ObservationIgnored private let notifier = Notifier()
    @ObservationIgnored private var pollTask: Task<Void, Never>?
    /// Kill plans of the expanded rows' listeners (see `killPlanPreview`). Observed: previews appear when they arrive.
    private var plans: [ProcessIdentity: KillPlan] = [:]
    @ObservationIgnored private var lastStartupRefresh: Date = .distantPast
    @ObservationIgnored private var recentStops: [RecentStop] = []
    @ObservationIgnored private var bannerTask: Task<Void, Never>?
    @ObservationIgnored private var isApplyingSettings = false
    @ObservationIgnored private var scanGeneration = 0
    /// Newest full scan, published or not (the panel may be closed). Detection and the menu bar count use it.
    @ObservationIgnored private var latest: ScanSnapshot = .empty
    /// `latest` is newer than `snapshot`: publish when the panel opens.
    @ObservationIgnored private var hasUnpublishedScan = false
    @ObservationIgnored private var scanInFlight = false
    @ObservationIgnored private var scanInFlightIsFull = false
    /// A full scan was asked for while another scan ran: run one more when it finishes.
    @ObservationIgnored private var fullScanPending = false
    /// `scanOnce` callers waiting for that extra full scan (resumed when the running scan loop ends).
    @ObservationIgnored private var fullScanWaiters: [CheckedContinuation<Void, Never>] = []
    /// False for test stores: their settings never reach UserDefaults.
    @ObservationIgnored private var persistsSettings = true
    @ObservationIgnored private var isQuitting = false
    /// The "… closed" note on screen, if any: the only banner a newer note may replace.
    @ObservationIgnored private var closedNoteID: UUID?
    /// Stand-ins a test store runs launchd / pm2 commands through (nil: the engine's own services).
    @ObservationIgnored private var launchdOverride: LaunchdService?
    @ObservationIgnored private var pm2Override: PM2Commands?

    // MARK: Control seams (replaced in tests)

    /// Asks the GUI app running as a pid to quit like ⌘Q does; nil when that pid isn't an app with a UI.
    @ObservationIgnored var askAppToQuit: @MainActor (Int32) -> Bool? = { AppStore.askRunningAppToQuit(pid: $0) }
    /// Where relaunched servers log their output.
    @ObservationIgnored var relaunchLogDirectory: URL = Relauncher.logDirectory
    /// How long a relaunched server gets to open one of its ports before the banner says it isn't listening.
    @ObservationIgnored var relaunchPortTimeout: TimeInterval = 15
    /// Snapshots and previews only (no engine): the copy they depict can or can't manage Launch at login.
    @ObservationIgnored var previewCanManageLoginItem: Bool?

    /// Ports we just stopped — if they come back within `respawnWindow` we tell the user who restarted them.
    private struct RecentStop {
        let date: Date
        let ports: Set<UInt16>
        let groupTitle: String
    }

    private static let settingsKey = "settings.v1"
    private static let respawnWindow: TimeInterval = 20
    private static let startupRefreshInterval: TimeInterval = 15
    private static let maxRecentlyStopped = 20
    /// Launch-at-login changes run launchctl: off the main thread, one at a time.
    private static let loginItemQueue = DispatchQueue(label: "eu.shhshm.PortPilot.login-item", qos: .userInitiated)

    // MARK: Lifecycle

    init() {
        engine = ScanEngine()
        isApplyingSettings = true
        settings = Self.loadSettings()
        // Repair first (an app moved to another folder), so the switch shows what will really happen at login.
        let canManage = Self.canManageLoginItem
        if canManage { loginItem.repairIfNeeded() }
        settings.launchAtLogin = Self.initialLaunchAtLogin(canManage: canManage, isEnabled: loginItem.isEnabled,
                                                           hasStoredSettings: Self.storedLaunchAtLoginChoice != nil,
                                                           requested: settings.launchAtLogin)
        isApplyingSettings = false
    }

    /// What the Launch at login switch starts as. Installed copies show whether the agent is set up, and turn it on
    /// by default until a choice is stored (`hasStoredSettings`; `start()` then writes the agent). Other copies
    /// (DerivedData, dist/, a mounted DMG) can't manage it, so they show the truth: on only if the agent already
    /// points at this very copy.
    nonisolated static func initialLaunchAtLogin(canManage: Bool, isEnabled: Bool, hasStoredSettings: Bool,
                                     requested: Bool) -> Bool {
        guard canManage else { return isEnabled }
        return isEnabled || (!hasStoredSettings && requested)
    }

    /// Static store for snapshots/previews: no polling, actions are no-ops.
    init(previewSnapshot: ScanSnapshot, startupItems: [StartupItem], recentlyStopped: [StoppedRecord],
         settings: AppSettings = AppSettings(), banner: Banner? = nil, stillRunning: [StillRunningItem] = []) {
        engine = nil
        isApplyingSettings = true
        self.snapshot = previewSnapshot
        self.latest = previewSnapshot
        self.startupItems = startupItems
        self.recentlyStopped = recentlyStopped
        self.stillRunning = stillRunning
        self.settings = settings
        self.banner = banner
        self.lastUpdated = previewSnapshot.date
        isApplyingSettings = false
        recomputeVisible()
        updateMenuBarCount()
    }

    /// Store for tests: drives `engine` without polling (tests call `pollOnce` or the actions directly), shows
    /// `initial` (a scan the test ran) until its first own scan, has no login-item management, never loads or saves
    /// settings, and runs launchd / pm2 commands through the given stand-ins when set (a LaunchdService over a
    /// temporary home folder, recording closures), so nothing reaches the user's own jobs.
    init(engine: ScanEngine, initial: ScanOutput? = nil, settings: AppSettings = AppSettings(),
         launchd: LaunchdService? = nil, pm2: PM2Commands? = nil) {
        self.engine = engine
        isApplyingSettings = true
        persistsSettings = false
        launchdOverride = launchd
        pm2Override = pm2
        self.settings = settings
        if let initial {
            snapshot = initial.snapshot
            latest = initial.snapshot
            plans = initial.plans
            lastUpdated = initial.snapshot.date
        }
        isApplyingSettings = false
        recomputeVisible()
        updateMenuBarCount()
    }

    /// Starts the polling loop. Idempotent.
    func start() {
        guard engine != nil, pollTask == nil else { return }
        // The XCTest host must not scan: it would probe real project folders (and trigger folder-access prompts).
        guard ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] == nil else { return }
        // The one-time login-shell PATH capture must never land inside a scan tick or a button action.
        DispatchQueue.global(qos: .utility).async { _ = Shell.toolPATH }
        // First run of an installed copy: set up the agent the switch shows as on.
        if Self.canManageLoginItem && settings.launchAtLogin && !loginItem.isEnabled {
            applyLaunchAtLogin(true)
        }
        if settings.notifyOnNewPorts { notifier.requestAuthorizationIfNeeded() }
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                await self.pollOnce()
                let interval = max(1, self.settings.refreshInterval)
                // The tolerance lets macOS coalesce PortPilot's wakeups with others'.
                try? await Task.sleep(for: .seconds(interval), tolerance: .seconds(interval * 0.25))
            }
        }
    }

    /// Immediate full rescan (also refreshes startup items). Joins a full scan that is already running.
    func refreshNow() {
        guard engine != nil else { return }
        lastStartupRefresh = .distantPast
        if scanInFlight && scanInFlightIsFull { return }
        Task { await scanOnce() }
    }

    /// Full rescan after an action: rows are rebuilt even if no port changed. If a scan is running it may predate
    /// the action, so another one follows it; either way this returns once a full scan that started after the call
    /// is done.
    private func scanOnce() async {
        guard engine != nil else { return }
        guard scanInFlight else { return await pollOnce(full: true) }
        fullScanPending = true
        await withCheckedContinuation { fullScanWaiters.append($0) }
    }

    /// One tick of the poll loop (the loop calls it; tests drive it directly). With the panel closed and `full`
    /// false, a tick whose listeners didn't change since the last full scan stops after the socket walk and
    /// touches no state: the menu bar count, new-port notifications and respawn checks can't change then.
    func pollOnce(full: Bool = false) async {
        guard let engine else { return }
        guard !scanInFlight else {
            if full { fullScanPending = true }
            return
        }
        scanInFlight = true
        var full = full
        repeat {
            fullScanPending = false
            await scanPass(engine, full: full)
            full = true
        } while fullScanPending
        scanInFlight = false
        let waiters = fullScanWaiters
        fullScanWaiters.removeAll()
        waiters.forEach { $0.resume() }
    }

    private func scanPass(_ engine: ScanEngine, full: Bool) async {
        scanInFlightIsFull = full || isPanelVisible
        scanGeneration += 1
        if isPanelVisible { isScanning = true }
        let request = ScanEngine.ScanRequest(includeOtherUsers: settings.showSystem,
                                             planGroupIDs: isPanelVisible ? expandedGroupIDs : [],
                                             skipIfUnchanged: !full && !isPanelVisible)
        if let output = await engine.scan(request) {
            let previous = latest
            apply(output)
            await updateStillRunning(previous: previous)
        } else if !stillRunning.isEmpty {
            await updateStillRunning(previous: nil)
        }
        await refreshStartupItemsIfNeeded()
        if isScanning { isScanning = false }
    }

    private func apply(_ output: ScanOutput) {
        latest = output.snapshot
        updatePlans(output.plans)
        updateMenuBarCount()
        detectNewPorts()
        // Drives the "Waiting for access to Downloads…" notice at the top of the list (and Settings' folder rows).
        folderAccess.scanReported(awaiting: output.foldersAwaitingAccess)
        if isPanelVisible {
            publish()
        } else {
            hasUnpublishedScan = true
        }
    }

    /// Shows `latest` in the panel.
    private func publish() {
        hasUnpublishedScan = false
        snapshot = latest
        lastUpdated = latest.date
        recomputeVisible()
        detectRespawns()
    }

    private func updateMenuBarCount() {
        let count = Self.menuBarCount(for: latest.groups, ignoredGroupIDs: settings.ignoredGroupIDs)
        if count != menuBarCount { menuBarCount = count }
    }

    /// Distinct ports owned by `.project` groups the user didn't hide.
    nonisolated static func menuBarCount(for groups: [ListenerGroup], ignoredGroupIDs: [String]) -> Int {
        let ignored = Set(ignoredGroupIDs)
        return Set(groups.filter { $0.category == .project && !ignored.contains($0.id) }.flatMap(\.ports)).count
    }

    // MARK: Kill-plan previews

    private func updatePlans(_ fresh: [ProcessIdentity: KillPlan]) {
        if !Self.samePlans(plans, fresh) { plans = fresh }
        requestMissingPlans()
    }

    /// Expanded rows whose listeners have no plan yet (just expanded, or expanded during a scan) get theirs
    /// computed on the engine's control queue.
    private func requestMissingPlans() {
        guard let engine, isPanelVisible, !expandedGroupIDs.isEmpty else { return }
        let groups = latest.groups.filter { group in
            expandedGroupIDs.contains(group.id)
                && group.processes.contains { !$0.isRestricted && plans[$0.id] == nil }
        }
        guard !groups.isEmpty else { return }
        Task {
            let found = await engine.plans(for: groups)
            guard !found.isEmpty else { return }
            let current = Set(latest.groups.flatMap { $0.processes.map(\.id) })
            var merged = plans.filter { current.contains($0.key) }
            for (identity, plan) in found where current.contains(identity) { merged[identity] = plan }
            if !Self.samePlans(plans, merged) { plans = merged }
        }
    }

    /// KillPlan isn't Equatable (it's a shared model type); compared here so previews only re-render on change.
    nonisolated static func samePlans(_ lhs: [ProcessIdentity: KillPlan], _ rhs: [ProcessIdentity: KillPlan]) -> Bool {
        guard lhs.count == rhs.count else { return false }
        for (identity, plan) in lhs {
            guard let other = rhs[identity], plan.root == other.root, plan.targets == other.targets,
                  plan.summary == other.summary, plan.warnings == other.warnings,
                  plan.requiresAdmin == other.requiresAdmin else { return false }
        }
        return true
    }

    // MARK: Startup items

    /// Startup Items only show in the panel: refreshed when it opens, every 15 s while it's open and after actions
    /// (which reset `lastStartupRefresh`), never while it's closed.
    private func refreshStartupItemsIfNeeded() async {
        guard let engine, isPanelVisible else { return }
        var items = startupItems
        if Date().timeIntervalSince(lastStartupRefresh) > Self.startupRefreshInterval {
            lastStartupRefresh = Date()
            items = await engine.startupItems()
        }
        attachPorts(to: &items)
        if items != startupItems { startupItems = items }
    }

    private func attachPorts(to items: inout [StartupItem]) {
        var portsByLabel: [String: [UInt16]] = [:]
        for group in latest.groups {
            for process in group.processes {
                if case .launchd(let job) = process.manager {
                    portsByLabel[job.label, default: []].append(contentsOf: process.ports)
                }
            }
        }
        for index in items.indices {
            items[index].ports = Array(Set(portsByLabel[items[index].label] ?? [])).sorted()
        }
    }

    // MARK: Still running without a port

    /// Compares a new full scan with the previous one (`previous`; nil for a tick that skipped the rebuild): groups
    /// whose ports all closed without PortPilot stopping them either left processes running (listed under "Still
    /// running · no open port") or closed for good (a short note while the panel is open). Existing entries drop
    /// exited processes and go once nothing is left.
    private func updateStillRunning(previous: ScanSnapshot?) async {
        guard let engine else { return }
        let before = stillRunning
        var items = before
        var foundIDs = Set<String>()
        if let previous, previous.date != .distantPast {
            let vanished = StillRunning.vanishedGroups(
                previous: previous.groups, current: latest.groups,
                stoppedPorts: Set(recentStops.flatMap(\.ports)), busyGroupIDs: busyGroupIDs,
                ignoredGroupIDs: Set(settings.ignoredGroupIDs), ignoredPorts: Set(settings.ignoredPorts),
                currentUID: engine.currentUID)
            if !vanished.isEmpty {
                let found = await engine.leftovers(of: vanished, previousTable: previous.table)
                items = StillRunning.merged(found, into: items)
                foundIDs = Set(found.map(\.id))
                showClosedNote(for: vanished.filter { !foundIDs.contains($0.id) })
            }
        }
        if !items.isEmpty {
            items = await engine.refreshLeftovers(items, sampleUsage: isPanelVisible)
        }
        // Entries stopped from the panel while this ran stay gone.
        let removedMeanwhile = Set(before.map(\.id)).subtracting(stillRunning.map(\.id))
        items.removeAll { removedMeanwhile.contains($0.id) && !foundIDs.contains($0.id) }
        if items != stillRunning { stillRunning = items }
    }

    /// "my-app closed (:5173)" for tools that exited on their own, only while the panel is open, and never over
    /// other feedback (an action's result or progress such as "Relaunching…", a warning, an error): it only replaces
    /// an older note.
    private func showClosedNote(for groups: [ListenerGroup]) {
        guard isPanelVisible, let message = StillRunning.closedMessage(for: groups) else { return }
        if let current = banner, current.id != closedNoteID { return }
        let note = Banner(style: .info, message: message)
        closedNoteID = note.id
        banner = note
    }

    /// Stops what still runs of a tool that closed its ports (⌥-click: force kill). Every process is re-verified by
    /// `ProcessKiller` before it is signalled.
    func stopStillRunning(_ item: StillRunningItem, mode: StopMode = .graceful) {
        guard let engine, !busyGroupIDs.contains(item.busyID) else { return }
        busyGroupIDs.insert(item.busyID)
        let timeout = settings.gracefulTimeout
        Task {
            let result = await engine.killer.stop(item.plan, mode: mode, timeout: timeout, allowAdmin: false)
            busyGroupIDs.remove(item.busyID)
            if result.failures.isEmpty {
                stillRunning.removeAll { $0.id == item.id }
                banner = Banner(style: .success, message: "Stopped \(item.title)"
                                + (result.escalated ? " — had to force-kill" : ""))
            } else {
                let reasons = result.failures.prefix(3).map { "pid \($0.pid): \($0.reason)" }
                banner = Banner(style: .error, message: "Couldn't fully stop \(item.title): " + reasons.joined(separator: "; "))
            }
            await scanOnce()
        }
    }

    // MARK: Actions

    /// One-click stop for a whole group (project / service / app). For launchd jobs: bootout (stops until next login).
    /// Apps are asked to quit (they can ask to save); apps and macOS services are never force-killed by it.
    @discardableResult
    func stop(_ group: ListenerGroup, mode: StopMode = .graceful) -> Task<Void, Never>? {
        startStop(StopRequest(group: group, mode: mode, disableAutoStart: false))
    }

    /// Stop one listener's kill plan (or only its PID when `onlyThisProcess`).
    @discardableResult
    func stop(_ process: ListenerProcess, mode: StopMode = .graceful,
              onlyThisProcess: Bool = false) -> Task<Void, Never>? {
        let group = snapshot.groups.first { $0.processes.contains { $0.id == process.id } }
        return startStop(StopRequest(processes: [process], groupID: group?.id ?? "pid:\(process.id)",
                                     title: process.displayName, category: group?.category ?? process.category,
                                     mode: mode, onlyThisProcess: onlyThisProcess, disableAutoStart: false))
    }

    /// Stop now AND prevent restarts: launchctl bootout+disable (only for agents Startup Items can switch back on;
    /// others are just stopped, with a note) / pm2 delete (+ removes it from pm2's saved list) /
    /// docker update --restart=no + stop.
    @discardableResult
    func stopAndDisableAutoStart(_ group: ListenerGroup) -> Task<Void, Never>? {
        startStop(StopRequest(group: group, mode: .graceful, disableAutoStart: true))
    }

    private func startStop(_ request: StopRequest) -> Task<Void, Never>? {
        guard engine != nil, !busyGroupIDs.contains(request.groupID) else { return nil }
        busyGroupIDs.insert(request.groupID)
        return Task {
            let outcome = await performStop(request)
            finishStops([outcome])
            banner = StopReport.banner(for: outcome)
            await scanOnce()
        }
    }

    /// Runs one Stop and reports what it did. The caller marks the group busy first and does the bookkeeping
    /// (`finishStops`) and the banner afterwards.
    private func performStop(_ request: StopRequest) async -> StopOutcome {
        var outcome = StopOutcome(groupID: request.groupID, title: request.title,
                                  ports: Array(Set(request.processes.flatMap(\.ports))).sorted())
        guard let engine else { return outcome }
        var plainProcesses: [ListenerProcess] = []
        var launchdStopped: [String: Bool] = [:]
        var unloadedByLaunchd: [ListenerProcess] = []
        var handledPM2 = Set<Int>()
        var handledDocker = Set<String>()

        // 1. Processes owned by a manager are stopped through that manager (a plain kill would respawn).
        for process in request.processes {
            switch process.manager {
            case .launchd(let job) where job.isUserAgent && !request.onlyThisProcess:
                if launchdStopped[job.label] == nil {
                    launchdStopped[job.label] = await stopLaunchdJob(job, disable: request.disableAutoStart,
                                                                     outcome: &outcome)
                }
                if launchdStopped[job.label] == true { unloadedByLaunchd.append(process) }
            case .pm2(let id, let name) where !request.onlyThisProcess:
                guard handledPM2.insert(id).inserted else { continue }
                await stopPM2App(id: id, name: name, delete: request.disableAutoStart, outcome: &outcome)
            case .docker(let container):
                guard handledDocker.insert(container.id).inserted else { continue }
                let disableAutoStart = request.disableAutoStart
                let error = await engine.perform {
                    if disableAutoStart { try engine.docker.disableRestart(id: container.id) }
                    try engine.docker.stop(id: container.id)
                }
                if let error {
                    outcome.errors.append("\(container.name): \(error.localizedDescription)")
                } else {
                    outcome.notes.append("container \(container.name) stopped")
                    outcome.stoppedCount += 1
                }
            default:
                plainProcesses.append(process)
            }
        }

        // 2. bootout only ends the job's own process group: a listener the job detached (setsid, a daemonizing
        //    fork, Node's `detached: true`) keeps running, orphaned. Check, and stop survivors directly.
        if !unloadedByLaunchd.isEmpty {
            let survivors = Set(await ProcessWatch.survivors(of: unloadedByLaunchd.map(\.id),
                                                             waitingUpTo: Self.launchdExitWait))
            for process in unloadedByLaunchd where survivors.contains(process.id) {
                plainProcesses.append(process)
                if case .launchd(let job) = process.manager {
                    outcome.notes.append("\(process.displayName) was detached from \(job.label), so it was stopped directly")
                }
            }
        }

        // 3. Everything else: signal the kill plan (whole dev-server tree), or ask an app to quit.
        if !plainProcesses.isEmpty {
            await stopPlainProcesses(plainProcesses, request: request, outcome: &outcome)
        }
        return outcome
    }

    /// How long a launchd-managed listener gets to exit after its job was unloaded before it counts as detached.
    private static let launchdExitWait: TimeInterval = 1.5

    /// Unloads one launchd job (bootout) or, for Stop & Disable, also turns off its auto-start — but only where
    /// Startup Items can turn it back on; any other job is only stopped, with a note saying where to turn it off.
    /// Returns false when launchctl failed.
    private func stopLaunchdJob(_ job: LaunchdJob, disable: Bool, outcome: inout StopOutcome) async -> Bool {
        guard let launchd else { return false }
        let label = job.label
        let result: Result<(disabled: Bool, reversible: Bool), Error> = await OffMain.run {
            do {
                if disable {
                    let disabled = try launchd.stopAndDisableIfReversible(job: job)
                    return .success((disabled, disabled))
                }
                let reversible = launchd.canDisableReversibly(job: job)   // reads the plist: before bootout
                try launchd.stop(label: label)
                return .success((false, reversible))
            } catch {
                return .failure(error)
            }
        }
        switch result {
        case .failure(let error):
            outcome.errors.append("\(label): \(error.localizedDescription)")
            return false
        case .success(let state):
            outcome.stoppedCount += 1
            let manual = "\(label) may start again at login — turn it off in \(StopReport.loginItemsSettings)"
            if disable {
                outcome.notes.append(state.disabled ? "auto-start turned off for \(label)" : manual)
            } else if job.keepAlive || job.runAtLoad {
                if state.reversible { outcome.autoStartLabels.append(label) } else { outcome.notes.append(manual) }
            }
            return true
        }
    }

    /// `pm2 stop`, or for Stop & Disable `pm2 delete` plus removing the app from pm2's saved list. Cluster-mode apps
    /// are addressed as a whole; the PM2 daemon itself is never signalled.
    private func stopPM2App(id: Int, name: String, delete: Bool, outcome: inout StopOutcome) async {
        guard let pm2 else { return }
        let result: Result<PM2SavedListUpdate?, Error> = await OffMain.run {
            do {
                if delete { return .success(try pm2.delete(id, name)) }
                try pm2.stop(id)
                return .success(nil)
            } catch {
                return .failure(error)
            }
        }
        switch result {
        case .failure(let error):
            outcome.errors.append("pm2 \(name): \(error.localizedDescription)")
        case .success(let update):
            outcome.stoppedCount += 1
            if delete {
                outcome.notes.append("pm2 \(name) removed" + (update?.note.map { " — \($0)" } ?? ""))
            } else {
                outcome.notes.append("pm2 \(name) stopped")
            }
        }
    }

    /// Signals the fresh kill plans of `listeners` (an app is asked to quit instead) and records what can be
    /// relaunched.
    private func stopPlainProcesses(_ listeners: [ListenerProcess], request: StopRequest,
                                    outcome: inout StopOutcome) async {
        guard let engine else { return }
        var targets = listeners
        var plans = await engine.freshPlans(for: targets, onlyThisProcess: request.onlyThisProcess)
        if plans.isEmpty {
            // Every listener exited since the last scan, and nothing of its launch tree holds its ports. A watcher or
            // the user may have started the server again in a new tree: look again before saying "already exited".
            let found = await listenersAfterRestart(of: targets, groupID: request.groupID)
            if !found.matching.isEmpty {
                targets = found.matching
                plans = await engine.freshPlans(for: targets, onlyThisProcess: false)
            } else if let holder = found.others.first {
                outcome.errors.append("it had already exited, and \(holder) now uses "
                                      + (outcome.ports.count == 1 ? "its port" : "its ports"))
                return
            } else {
                outcome.alreadyExited = true
                return
            }
        }

        let timeout = settings.gracefulTimeout
        if request.mode == .graceful, request.category == .app {
            // A GUI app quits through its own Quit (it can ask to save), before any of its helpers is signalled;
            // they usually exit with it. While it is still open (a save dialog), its helpers are left alone too.
            plans = await quitApps(in: plans, timeout: timeout, outcome: &outcome)
            if outcome.stillQuitting { return }
        }
        for plan in plans {
            guard !plan.targets.isEmpty else {
                outcome.errors.append(plan.warnings.first ?? "\(plan.root.comm) is protected and was not stopped")
                continue
            }
            let matched = targets.filter { listener in plan.targets.contains { $0.pid == listener.basic.pid } }
            let planListeners = matched.isEmpty && plans.count == 1 ? targets : matched
            // Read the command before stopping: afterwards the tree's argv, environment and cwd are gone. Apps and
            // macOS services get no Recently Stopped record (relaunching a bare helper argv would be wrong).
            let relaunch = request.isAppOrSystem ? nil : await relaunchInfo(for: plan)

            // App helpers (not a GUI app's main process) and macOS services get SIGTERM only: no SIGKILL unless the
            // user picks Force Kill.
            let result = await engine.killer.stop(plan, mode: request.mode, timeout: timeout,
                                                  allowAdmin: plan.requiresAdmin, escalate: !request.isAppOrSystem)
            outcome.escalated = outcome.escalated || result.escalated
            for failure in result.failures {
                outcome.errors.append("pid \(failure.pid): \(failure.reason)")
            }
            guard !result.stopped.isEmpty else { continue }
            outcome.stoppedCount += 1
            guard let relaunch else { continue }
            let listener = planListeners.first
            let command = relaunch.command
            let record = StoppedRecord(
                id: UUID(), date: Date(),
                title: listener.map { "\(request.title) · \($0.displayName)" } ?? request.title,
                ports: Array(Set(planListeners.flatMap(\.ports))).sorted(),
                cwd: command?.cwd ?? relaunch.root?.cwd,
                arguments: command?.arguments ?? relaunch.root?.arguments ?? [],
                environment: command?.environment ?? relaunch.root?.environment ?? [:],
                // nil on purpose for a rebuilt `npm run dev`: npm is then found on the record's PATH.
                executablePath: command != nil ? command?.executablePath : relaunch.root?.executablePath,
                manager: listener?.manager ?? .none)
            outcome.records.append(record)
            if StopReport.canRelaunch(record) { outcome.undoRecordIDs.append(record.id) }
        }
    }

    /// What a StoppedRecord needs, read before the plan is stopped (off the main thread): the command Relaunch should
    /// run (`Relauncher.relaunchCommand`, nil when unknown) and the root's own details as a fallback for display.
    private func relaunchInfo(for plan: KillPlan) async -> (command: RelaunchCommand?, root: ProcessDetails?)? {
        guard let scanner = engine?.scanner else { return nil }
        return await OffMain.run {
            let details: (ProcessBasic) -> ProcessDetails? = { scanner.details(for: $0) }
            return (Relauncher.relaunchCommand(for: plan, details: details), details(plan.root))
        }
    }

    /// Asks every GUI app among the plans' roots to quit (its own Quit: it can ask to save) and waits up to `timeout`
    /// for them; never force-quits. Sets `quitApp` or `stillQuitting`. Returns the plans still to signal (helpers and
    /// background processes).
    private func quitApps(in plans: [KillPlan], timeout: TimeInterval, outcome: inout StopOutcome) async -> [KillPlan] {
        var asked: [ProcessIdentity] = []
        var remaining: [KillPlan] = []
        for plan in plans {
            if !plan.targets.isEmpty, askAppToQuit(plan.root.pid) == true {
                asked.append(plan.root.identity)
            } else {
                remaining.append(plan)
            }
        }
        guard !asked.isEmpty else { return plans }
        if await ProcessWatch.survivors(of: asked, waitingUpTo: max(1, timeout)).isEmpty {
            outcome.quitApp = true
            outcome.stoppedCount += asked.count
        } else {
            outcome.stillQuitting = true
        }
        return remaining
    }

    /// ⌘Q for the app running as `pid` (`NSRunningApplication.terminate()`); nil when `pid` isn't an app with a UI or
    /// menu bar item (a helper or a background process). Otherwise whether the request was sent.
    static func askRunningAppToQuit(pid: Int32) -> Bool? {
        guard pid > 1, let app = NSRunningApplication(processIdentifier: pid),
              app.activationPolicy == .regular || app.activationPolicy == .accessory else { return nil }
        return app.terminate()
    }

    /// After a Stop found every listener in `stale` gone: scans again and returns the listeners that hold their
    /// ports now in the same group, or with the same command in the same folder (`matching`: a watcher's or the
    /// user's restart of that server), plus the names of any other process on those ports (`others`, never stopped).
    private func listenersAfterRestart(of stale: [ListenerProcess], groupID: String) async
        -> (matching: [ListenerProcess], others: [String]) {
        guard let engine else { return ([], []) }
        let ports = Set(stale.flatMap(\.ports))
        guard !ports.isEmpty else { return ([], []) }
        let output = await engine.scan(includeOtherUsers: settings.showSystem)
        let staleIDs = Set(stale.map(\.id))
        let launches = Set(stale.map { "\($0.details?.cwd ?? "?")\n\($0.commandLine)" })
        var matching: [ListenerProcess] = []
        var others: [String] = []
        for group in output.snapshot.groups {
            for process in group.processes
            where !staleIDs.contains(process.id) && !ports.isDisjoint(with: process.ports) {
                let sameLaunch = process.details?.cwd != nil
                    && launches.contains("\(process.details?.cwd ?? "")\n\(process.commandLine)")
                if !process.isRestricted && (group.id == groupID || sameLaunch) {
                    matching.append(process)
                } else {
                    others.append(process.displayName)
                }
            }
        }
        return (matching, others)
    }

    /// Bookkeeping after stops: Recently Stopped, the respawn watch, busy flags, fresh manager state next scan.
    private func finishStops(_ outcomes: [StopOutcome]) {
        for outcome in outcomes {
            recentlyStopped.insert(contentsOf: outcome.records, at: 0)
            if !outcome.ports.isEmpty {
                recentStops.append(RecentStop(date: Date(), ports: Set(outcome.ports), groupTitle: outcome.title))
            }
            busyGroupIDs.remove(outcome.groupID)
        }
        if recentlyStopped.count > Self.maxRecentlyStopped {
            recentlyStopped.removeLast(recentlyStopped.count - Self.maxRecentlyStopped)
        }
        engine?.invalidateManagerCaches()
        lastStartupRefresh = .distantPast
    }

    /// launchd / pm2 services the control actions use: the engine's own, or a test store's stand-ins.
    private var launchd: LaunchdService? { launchdOverride ?? engine?.launchd }
    private var pm2: PM2Commands? { pm2Override ?? engine.map { PM2Commands.live($0.pm2) } }

    /// Enable or disable a startup item (launchctl enable+bootstrap / bootout+disable).
    @discardableResult
    func setStartupItem(_ item: StartupItem, enabled: Bool) -> Task<Void, Never>? {
        guard let engine, let launchd, item.label != LoginItemManager.label else { return nil }
        let id = StartupItemsView.busyID(for: item.label)
        guard !busyGroupIDs.contains(id) else { return nil }
        busyGroupIDs.insert(id)
        return Task {
            let error = await engine.perform {
                if enabled { try launchd.enable(label: item.label, plistPath: item.plistPath) }
                else { try launchd.disable(label: item.label) }
            }
            busyGroupIDs.remove(id)
            if let error {
                banner = Banner(style: .error, message: "\(item.label): \(error.localizedDescription)")
            } else {
                banner = Banner(style: .success, message: enabled
                                ? "\(item.label) enabled and started"
                                : "\(item.label) stopped and won't start at login")
            }
            engine.invalidateManagerCaches()
            lastStartupRefresh = .distantPast
            await scanOnce()
        }
    }

    /// Start a startup item that isn't running: kickstart when it is loaded; when Stop unloaded it, load it again
    /// (bootstrap) and kickstart it unless it runs at load. The banner reports what launchd says a second later.
    @discardableResult
    func startStartupItem(_ item: StartupItem) -> Task<Void, Never>? {
        guard let engine, let launchd, item.label != LoginItemManager.label else { return nil }
        let id = StartupItemsView.busyID(for: item.label)
        guard !busyGroupIDs.contains(id) else { return nil }
        busyGroupIDs.insert(id)
        return Task {
            let error = await engine.perform {
                if item.isLoaded {
                    try launchd.start(label: item.label)
                } else {
                    try launchd.enable(label: item.label, plistPath: item.plistPath)
                    // bootstrap only starts a job that runs at load.
                    if !item.runAtLoad { try launchd.start(label: item.label) }
                }
            }
            let state = error == nil ? await ProcessWatch.launchdJob(item.label, after: Self.startSettleTime) : nil
            busyGroupIDs.remove(id)
            banner = StopReport.startBanner(label: item.label, error: error, state: state)
            engine.invalidateManagerCaches()
            lastStartupRefresh = .distantPast
            await scanOnce()
        }
    }

    /// How long a started launchd job must stay up before Start reports it running.
    private static let startSettleTime: TimeInterval = 1

    /// Projects "Stop All Projects" ends: every `.project` group the user hasn't hidden (a hidden item, or one whose
    /// ports are all hidden). The footer's count uses the same list, so it always matches what the button stops.
    var stoppableProjects: [ListenerGroup] {
        let ignoredIDs = Set(settings.ignoredGroupIDs)
        let ignoredPorts = Set(settings.ignoredPorts)
        return snapshot.groups.filter { group in
            group.category == .project && !ignoredIDs.contains(group.id)
                && (ignoredPorts.isEmpty || !group.ports.allSatisfy(ignoredPorts.contains))
        }
    }

    /// Stops every group in `stoppableProjects` at once and reports them in one banner.
    @discardableResult
    func stopAllProjects() -> Task<Void, Never>? {
        guard engine != nil else { return nil }
        let requests = stoppableProjects
            .filter { !busyGroupIDs.contains($0.id) }
            .map { StopRequest(group: $0, mode: .graceful, disableAutoStart: false) }
        guard !requests.isEmpty else { return nil }
        requests.forEach { busyGroupIDs.insert($0.groupID) }
        return Task {
            let outcomes = await withTaskGroup(of: (Int, StopOutcome).self) { group in
                for (index, request) in requests.enumerated() {
                    group.addTask { (index, await self.performStop(request)) }
                }
                var results: [(Int, StopOutcome)] = []
                for await result in group { results.append(result) }
                return results.sorted { $0.0 < $1.0 }.map(\.1)
            }
            finishStops(outcomes)
            banner = StopReport.summary(for: outcomes)
            await scanOnce()
        }
    }

    /// Re-run a stopped command with its original argv, env and cwd (detached, logs to ~/Library/Logs/PortPilot).
    @discardableResult
    func relaunch(_ record: StoppedRecord) -> Task<Void, Never>? {
        relaunch([record])
    }

    /// Relaunches `records` together (Undo of a Stop that ended several servers). Success is reported only once a
    /// process stayed up and, when it had ports, listens on one of them again; a record that didn't come back stays
    /// in Recently Stopped.
    private func relaunch(_ records: [StoppedRecord]) -> Task<Void, Never>? {
        guard engine != nil else { return nil }
        let pending = records.filter { $0.canRelaunch && !relaunchingRecordIDs.contains($0.id) }
        guard !pending.isEmpty else { return nil }
        let ids = pending.map(\.id)
        relaunchingRecordIDs.formUnion(ids)
        banner = Banner(style: .info, message: pending.count == 1 ? "Relaunching \(pending[0].title)…"
                                                                  : "Relaunching \(pending.count) servers…")
        let logDirectory = relaunchLogDirectory
        let portTimeout = relaunchPortTimeout
        return Task {
            let results = await withTaskGroup(of: (Int, RelaunchResult).self) { group in
                for (index, record) in pending.enumerated() {
                    group.addTask {
                        (index, await Relauncher.relaunchAndVerify(record, logDirectory: logDirectory,
                                                                    portTimeout: portTimeout))
                    }
                }
                var collected: [(Int, RelaunchResult)] = []
                for await result in group { collected.append(result) }
                return collected.sorted { $0.0 < $1.0 }.map(\.1)
            }
            for result in results where result.isRunning {
                recentlyStopped.removeAll { $0.id == result.record.id }
                recentStops.removeAll { !$0.ports.isDisjoint(with: result.record.ports) }
            }
            relaunchingRecordIDs.subtract(ids)
            banner = StopReport.relaunchBanner(for: results)
            await scanOnce()
        }
    }

    func clearRecentlyStopped() {
        recentlyStopped.removeAll()
    }

    /// Lines describing exactly what Stop will signal for this group.
    func killPlanPreview(for group: ListenerGroup) -> [String] {
        var lines: [String] = []
        var seenRoots = Set<ProcessIdentity>()
        for process in group.processes {
            switch process.manager {
            case .launchd(let job) where job.isUserAgent:
                // The label is the line's only identifying part: no suffix that truncation would keep instead.
                // The auto-restart notice below says what happens at next login.
                let line = "launchd job \(job.label)"
                if !lines.contains(line) { lines.append(line) }
            case .pm2(_, let name):
                lines.append("pm2 app \(name)")
            case .docker(let container):
                lines.append("Docker container \(container.name)")
            default:
                guard let plan = plans[process.id], seenRoots.insert(plan.root.identity).inserted else { continue }
                lines.append(contentsOf: plan.summary)
                lines.append(contentsOf: plan.warnings.map { "⚠︎ " + $0 })
            }
        }
        return lines
    }

    func ignore(_ group: ListenerGroup) {
        guard !settings.ignoredGroupIDs.contains(group.id) else { return }
        settings.ignoredGroupIDs.append(group.id)
        banner = Banner(style: .info, message: "Hidden \(group.title). Unhide it from Settings.")
    }

    func unignoreAll() {
        settings.ignoredGroupIDs.removeAll()
        settings.ignoredPorts.removeAll()
    }

    @discardableResult
    func performBannerAction(_ banner: Banner) -> Task<Void, Never>? {
        guard let action = banner.action else { return nil }
        dismissBanner()
        switch action {
        case .disableAutoStart(let groupID, let launchdLabels):
            if let group = snapshot.groups.first(where: { $0.id == groupID }) {
                return stopAndDisableAutoStart(group)
            } else if !launchdLabels.isEmpty {
                // The Stop that offered this unloaded the jobs, so their group has left the list: act on the labels.
                return disableAutoStart(labels: launchdLabels)
            } else if let label = groupID.split(separator: ":", maxSplits: 1).last.map(String.init),
                      groupID.hasPrefix("launchd:"),
                      let item = startupItems.first(where: { $0.label == label }) {
                return setStartupItem(item, enabled: false)
            } else {
                self.banner = Banner(style: .info, message: "Already stopped. Use Startup Items below to disable it.")
                return nil
            }
        case .relaunch(let recordID, let moreRecordIDs):
            let records = ([recordID] + moreRecordIDs).compactMap { id in recentlyStopped.first { $0.id == id } }
            return relaunch(records)
        }
    }

    /// Turns off auto-start for launchd jobs a Stop already unloaded: `launchctl disable` where Startup Items can
    /// switch it back on; for any other job the banner says where to turn it off.
    private func disableAutoStart(labels: [String]) -> Task<Void, Never>? {
        guard let engine, let launchd else { return nil }
        let labels = labels.filter { $0 != LoginItemManager.label }
        let ids = labels.map(StartupItemsView.busyID(for:))
        guard !labels.isEmpty, !ids.contains(where: busyGroupIDs.contains) else { return nil }
        busyGroupIDs.formUnion(ids)
        return Task {
            var disabled: [String] = []
            var manual: [String] = []
            var errors: [String] = []
            for label in labels {
                let result: Result<Bool, Error> = await OffMain.run {
                    // Unloaded jobs are found through their plist; one launchd no longer knows can't be managed here.
                    guard let job = launchd.job(label: label, pid: nil) else { return .success(false) }
                    return Result { try launchd.stopAndDisableIfReversible(job: job) }
                }
                switch result {
                case .success(true): disabled.append(label)
                case .success(false): manual.append(label)
                case .failure(let error): errors.append("\(label): \(error.localizedDescription)")
                }
            }
            busyGroupIDs.subtract(ids)
            banner = StopReport.autoStartBanner(disabled: disabled, manual: manual, errors: errors)
            engine.invalidateManagerCaches()
            lastStartupRefresh = .distantPast
            await scanOnce()
        }
    }

    func dismissBanner() {
        banner = nil
    }

    private func scheduleBannerDismissal() {
        bannerTask?.cancel()
        guard let current = banner, engine != nil else { return }
        let seconds: UInt64 = current.action == nil ? (current.style == .error ? 12 : 6) : 20
        bannerTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: seconds * 1_000_000_000)
            guard !Task.isCancelled, let self, self.banner?.id == current.id else { return }
            self.banner = nil
        }
    }

    // MARK: Respawn & new-port detection

    private func detectRespawns() {
        let now = Date()
        recentStops.removeAll { now.timeIntervalSince($0.date) > Self.respawnWindow }
        guard !recentStops.isEmpty else { return }
        for stop in recentStops {
            // Give the kill a moment to land before judging.
            guard now.timeIntervalSince(stop.date) > 1.5 else { continue }
            guard let group = snapshot.groups.first(where: { !$0.ports.filter(stop.ports.contains).isEmpty }) else { continue }
            let back = group.ports.filter(stop.ports.contains)
            let portText = back.map { ":\($0)" }.joined(separator: ", ")
            recentStops.removeAll { $0.date == stop.date }
            if group.manager.isAutoRestarting, let badge = group.manager.badge {
                banner = Banner(style: .warning,
                                message: "\(stop.groupTitle) came back on \(portText) — restarted by \(badge).",
                                action: .disableAutoStart(groupID: group.id), actionTitle: "Stop & Disable")
            } else {
                banner = Banner(style: .warning,
                                message: "Something restarted \(portText) (\(group.title)). Its parent may be a watcher or supervisor.")
            }
            return
        }
    }

    private func detectNewPorts() {
        guard settings.notifyOnNewPorts else { return }
        // Notifier diffs against the previous call itself (first call only records a baseline). `latest`, not the
        // published snapshot: notifications must work while the panel is closed.
        notifier.notifyNewPorts(latest.groups.filter { !settings.ignoredGroupIDs.contains($0.id) })
    }

    // MARK: Filtering & sorting

    private func recomputeVisible() {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let ignoredIDs = Set(settings.ignoredGroupIDs)
        let ignoredPorts = Set(settings.ignoredPorts)
        var groups = snapshot.groups.filter { group in
            switch group.category {
            case .project, .service: break
            case .app: if !settings.showApps && query.isEmpty { return false }
            case .system: if !settings.showSystem && query.isEmpty { return false }
            }
            if ignoredIDs.contains(group.id) { return false }
            if !ignoredPorts.isEmpty, group.ports.allSatisfy(ignoredPorts.contains) { return false }
            return query.isEmpty || Self.matches(group, query: query)
        }
        groups.sort(by: sortPredicate)
        visibleGroups = groups
    }

    private static func matches(_ group: ListenerGroup, query: String) -> Bool {
        let tokens = query.split(separator: " ").map(String.init)
        var haystack = [group.title, group.subtitle ?? "", group.path ?? "", group.manager.badge ?? "",
                        group.origin?.name ?? ""]
        haystack += group.frameworks
        haystack += group.ports.map { String($0) }
        for process in group.processes {
            haystack.append(process.displayName)
            haystack.append(process.commandLine)
            haystack.append(String(process.basic.pid))
            if case .launchd(let job) = process.manager { haystack.append(job.label) }
        }
        let text = haystack.joined(separator: "\n").lowercased()
        return tokens.allSatisfy { token in
            let bare = token.hasPrefix(":") ? String(token.dropFirst()) : token
            return text.contains(bare)
        }
    }

    private var sortPredicate: (ListenerGroup, ListenerGroup) -> Bool {
        switch settings.sortOrder {
        case .port:
            return { ($0.ports.first ?? .max, $0.title) < ($1.ports.first ?? .max, $1.title) }
        case .name:
            return { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
        case .cpu:
            return { $0.usage.cpuPercent > $1.usage.cpuPercent }
        case .memory:
            return { $0.usage.memoryBytes > $1.usage.memoryBytes }
        case .newest:
            return { ($0.oldestStart ?? .distantPast) > ($1.oldestStart ?? .distantPast) }
        }
    }

    // MARK: Settings

    /// Launch at login as a copy that manages it stored it; nil while no choice is stored. Copies that can't manage
    /// it never store their switch (it only shows the truth for that copy), so Move to Applications and the installed
    /// copy's first run go by the user's own choice, or the default.
    static var storedLaunchAtLoginChoice: Bool? {
        storedLaunchAtLoginChoice(in: UserDefaults.standard.data(forKey: settingsKey))
    }

    nonisolated static func storedLaunchAtLoginChoice(in data: Data?) -> Bool? {
        guard let data, let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return nil }
        return object[launchAtLoginKey] as? Bool
    }

    /// The settings JSON to store. A copy that can't manage Launch at login keeps the stored choice (or none) in place
    /// of its switch.
    nonisolated static func settingsDataToStore(_ settings: AppSettings, canManageLoginItem: Bool,
                                                stored: Data?) -> Data? {
        guard let data = try? JSONEncoder().encode(settings) else { return nil }
        guard !canManageLoginItem,
              var object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return data }
        if let choice = storedLaunchAtLoginChoice(in: stored) {
            object[launchAtLoginKey] = choice
        } else {
            object.removeValue(forKey: launchAtLoginKey)
        }
        return try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
    }

    /// `AppSettings.launchAtLogin`'s key in the stored JSON.
    nonisolated private static let launchAtLoginKey = "launchAtLogin"

    private static func loadSettings() -> AppSettings {
        guard let data = UserDefaults.standard.data(forKey: settingsKey),
              let decoded = AppSettings.decoded(from: data) else {
            return AppSettings()
        }
        return decoded
    }

    private func settingsDidChange(from old: AppSettings) {
        guard !isApplyingSettings, engine != nil else {
            if engine == nil {
                recomputeVisible()
                updateMenuBarCount()
            }
            return
        }
        persistSettings()
        if settings.launchAtLogin != old.launchAtLogin {
            if Self.canManageLoginItem {
                applyLaunchAtLogin(settings.launchAtLogin)
            } else {
                // This copy can't set up the agent: the switch goes back to what will really happen at login.
                setLaunchAtLoginQuietly(loginItem.isEnabled)
                banner = Banner(style: .warning, message: "Launch at login can only be changed from the installed copy in Applications.")
            }
        }
        if settings.notifyOnNewPorts && !old.notifyOnNewPorts {
            notifier.requestAuthorizationIfNeeded()
            notifier.resetBaseline()
        }
        if settings.showSystem != old.showSystem || settings.refreshInterval != old.refreshInterval {
            // Not `refreshNow()`: a scan already running uses the old settings, so another one must follow it.
            Task { await scanOnce() }
        }
        recomputeVisible()
        updateMenuBarCount()
    }

    private func persistSettings() {
        guard persistsSettings,
              let data = Self.settingsDataToStore(settings, canManageLoginItem: Self.canManageLoginItem,
                                                  stored: UserDefaults.standard.data(forKey: Self.settingsKey))
        else { return }
        UserDefaults.standard.set(data, forKey: Self.settingsKey)
    }

    /// Sets the Launch at login switch to `value` without acting on it (it already describes reality) and saves it.
    private func setLaunchAtLoginQuietly(_ value: Bool) {
        guard settings.launchAtLogin != value else { return }
        isApplyingSettings = true
        settings.launchAtLogin = value
        isApplyingSettings = false
        persistSettings()
    }

    /// Writes or removes the agent off the main thread (launchctl runs). Afterwards the switch shows what will really
    /// happen at the next login: a failed change flips it back and says why.
    private func applyLaunchAtLogin(_ enabled: Bool) {
        // Safe to hand to the serial queue: LoginItemManager's state is immutable.
        nonisolated(unsafe) let loginItem = self.loginItem
        Task {
            let error: Error? = await withCheckedContinuation { continuation in
                Self.loginItemQueue.async {
                    do {
                        try loginItem.setEnabled(enabled)
                        continuation.resume(returning: nil)
                    } catch {
                        continuation.resume(returning: error)
                    }
                }
            }
            // Flipped again meanwhile: that newer change (queued behind this one) has the last word.
            guard settings.launchAtLogin == enabled else { return }
            setLaunchAtLoginQuietly(loginItem.isEnabled)
            if let error {
                banner = Banner(style: .error, message: "Launch at login: \(error.localizedDescription)")
            }
        }
    }

    /// Only manage the login item from an installed copy — never from DerivedData, dist/ or the XCTest host,
    /// which would repoint the LaunchAgent at a build folder. SettingsView disables the switch otherwise.
    static var canManageLoginItem: Bool {
        if ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil { return false }
        let path = Bundle.main.bundlePath
        return path.hasPrefix("/Applications/") || path.hasPrefix(NSHomeDirectory() + "/Applications/")
    }

    /// What the Launch at login switch can do in this store: `canManageLoginItem`, except in snapshots of sample data
    /// (`previewCanManageLoginItem`), which show the switch of the copy they depict.
    var canManageLaunchAtLogin: Bool {
        engine == nil ? (previewCanManageLoginItem ?? Self.canManageLoginItem) : Self.canManageLoginItem
    }

    // MARK: - Release features: About, updates, folder access, first run (owner: features)

    /// GitHub release check, the app's only network request. Inert until `startReleaseFeatures()`.
    let updates = UpdateController()
    /// macOS folder-access prompts (Downloads, Documents, Desktop…): folders waiting on a prompt, and denied ones.
    let folderAccess = FolderAccessController()

    /// Live app only (never previews, snapshots or the XCTest host): starts automatic update checks and
    /// folder-access tracking. Idempotent.
    func startReleaseFeatures() {
        guard engine != nil, ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] == nil else { return }
        updates.startAutomaticChecks { [weak self] in self?.settings.checkForUpdates ?? false }
        folderAccess.activate()
    }

    // MARK: - End of release features

    // MARK: Convenience actions

    func openInBrowser(port: UInt16) {
        guard let url = URL(string: "http://localhost:\(port)") else { return }
        NSWorkspace.shared.open(url)
    }

    func revealInFinder(_ path: String) {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory) else {
            banner = Banner(style: .error, message: "\(Format.abbreviatePath(path)) no longer exists")
            return
        }
        if isDirectory.boolValue && !path.hasSuffix(".app") {
            NSWorkspace.shared.open(URL(fileURLWithPath: path, isDirectory: true))
        } else {
            NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
        }
    }

    /// Opens a terminal in `path`, or in the folder containing it when `path` is a file (a launchd plist).
    func openInTerminal(_ path: String) {
        let candidates = ["com.googlecode.iterm2", "com.mitchellh.ghostty", "dev.warp.Warp-Stable", "com.apple.Terminal"]
        guard let appURL = candidates.lazy.compactMap({ NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0) }).first
        else { return }
        guard let folder = Self.terminalFolder(for: path) else {
            banner = Banner(style: .error, message: "\(Format.abbreviatePath(path)) no longer exists")
            return
        }
        NSWorkspace.shared.open([URL(fileURLWithPath: folder, isDirectory: true)], withApplicationAt: appURL,
                                configuration: NSWorkspace.OpenConfiguration())
    }

    /// The folder a terminal should open for `path`: the path itself when it is a folder, else its parent folder.
    /// nil when it no longer exists.
    nonisolated static func terminalFolder(for path: String) -> String? {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory) else { return nil }
        return isDirectory.boolValue ? path : (path as NSString).deletingLastPathComponent
    }

    /// Opens the folder in the first installed editor among Cursor, VS Code, Zed, Xcode (by bundle id).
    func openInEditor(_ path: String) {
        guard let editor = Self.preferredEditor else { return }
        NSWorkspace.shared.open([URL(fileURLWithPath: path, isDirectory: true)], withApplicationAt: editor.url,
                                configuration: NSWorkspace.OpenConfiguration())
    }

    /// Name of the editor `openInEditor` will use, nil if none installed.
    var preferredEditorName: String? { Self.preferredEditor?.name }

    private static let preferredEditor: (name: String, url: URL)? = {
        let editors: [(String, String)] = [
            ("Cursor", "com.todesktop.230313mzl4w4u92"),
            ("VS Code", "com.microsoft.VSCode"),
            ("Antigravity", "com.google.antigravity-ide"),
            ("Zed", "dev.zed.Zed"),
            ("Xcode", "com.apple.dt.Xcode"),
        ]
        for (name, bundleID) in editors {
            if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) { return (name, url) }
        }
        return nil
    }()

    func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    /// Quits. With Launch at login off while launchd runs PortPilot as its agent job (the switch was turned off this
    /// session), the job is booted out first, so launchd's crash restart can't bring PortPilot back.
    func quit() {
        guard !isQuitting else { return }
        isQuitting = true
        pollTask?.cancel()
        let launchAtLogin = settings.launchAtLogin
        // Safe to hand to the serial queue: LoginItemManager's state is immutable.
        nonisolated(unsafe) let loginItem = self.loginItem
        Self.loginItemQueue.async {
            loginItem.bootOutOwnJobIfDisabled(launchAtLogin: launchAtLogin)
            DispatchQueue.main.async { NSApp.terminate(nil) }
        }
    }
}
