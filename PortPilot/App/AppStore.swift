import AppKit
import Foundation
import Observation

/// Central state for the menu bar panel. All UI reads from here and calls its actions.
@MainActor
@Observable
final class AppStore {
    // MARK: State (read by UI)

    /// Latest scan (unfiltered).
    private(set) var snapshot: ScanSnapshot = .empty
    /// Groups after applying settings (category visibility, ignored items), search and sort.
    private(set) var visibleGroups: [ListenerGroup] = []
    /// launchd agents from ~/Library/LaunchAgents (non-Apple), with live status.
    private(set) var startupItems: [StartupItem] = []
    /// Most recent first, max 20, in-memory only.
    private(set) var recentlyStopped: [StoppedRecord] = []
    private(set) var isScanning = false
    private(set) var lastUpdated: Date?
    /// Group ids with a stop/disable action in flight (UI shows a spinner instead of the Stop button).
    private(set) var busyGroupIDs: Set<String> = []
    /// Transient feedback shown at the top of the panel.
    var banner: Banner? { didSet { scheduleBannerDismissal() } }
    /// Free-text filter (matches port, project name, path, command).
    var searchText: String = "" { didSet { recomputeVisible() } }
    /// Persisted in UserDefaults on change.
    var settings: AppSettings = AppSettings() { didSet { settingsDidChange(from: oldValue) } }
    /// Section expansion state (not persisted).
    var expandedGroupIDs: Set<String> = []
    /// True while the panel is on screen (UI sets it in onAppear/onDisappear) — scans more often when open.
    var isPanelVisible = false {
        didSet {
            if isPanelVisible && !oldValue {
                refreshNow()
            }
        }
    }

    // MARK: Derived (read by UI)

    /// Number shown next to the menu bar icon: distinct ports owned by `.project` groups.
    var menuBarCount: Int {
        Set(snapshot.groups.filter { $0.category == .project && !settings.ignoredGroupIDs.contains($0.id) }
            .flatMap(\.ports)).count
    }
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
    @ObservationIgnored private var plans: [ProcessIdentity: KillPlan] = [:]
    @ObservationIgnored private var lastStartupRefresh: Date = .distantPast
    @ObservationIgnored private var recentStops: [RecentStop] = []
    @ObservationIgnored private var bannerTask: Task<Void, Never>?
    @ObservationIgnored private var isApplyingSettings = false
    @ObservationIgnored private var scanGeneration = 0

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

    // MARK: Lifecycle

    init() {
        engine = ScanEngine()
        isApplyingSettings = true
        settings = Self.loadSettings()
        settings.launchAtLogin = loginItem.isEnabled || (!Self.hasStoredSettings && settings.launchAtLogin)
        isApplyingSettings = false
    }

    /// Static store for snapshots/previews: no polling, actions are no-ops.
    init(previewSnapshot: ScanSnapshot, startupItems: [StartupItem], recentlyStopped: [StoppedRecord],
         settings: AppSettings = AppSettings(), banner: Banner? = nil) {
        engine = nil
        isApplyingSettings = true
        self.snapshot = previewSnapshot
        self.startupItems = startupItems
        self.recentlyStopped = recentlyStopped
        self.settings = settings
        self.banner = banner
        self.lastUpdated = previewSnapshot.date
        isApplyingSettings = false
        recomputeVisible()
    }

    /// Starts the polling loop. Idempotent.
    func start() {
        guard engine != nil, pollTask == nil else { return }
        // The one-time login-shell PATH capture must never land inside a scan tick or a button action.
        DispatchQueue.global(qos: .utility).async { _ = Shell.toolPATH }
        if Self.canManageLoginItem {
            loginItem.repairIfNeeded()
            if settings.launchAtLogin && !loginItem.isEnabled {
                try? loginItem.setEnabled(true)
            }
        }
        if settings.notifyOnNewPorts { notifier.requestAuthorizationIfNeeded() }
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                await self.scanOnce()
                let interval = max(1, self.settings.refreshInterval)
                try? await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
            }
        }
    }

    /// Immediate rescan (also refreshes startup items).
    func refreshNow() {
        guard engine != nil else { return }
        lastStartupRefresh = .distantPast
        Task { await scanOnce() }
    }

    private func scanOnce() async {
        guard let engine, !isScanning else { return }
        isScanning = true
        scanGeneration += 1
        let output = await engine.scan(includeOtherUsers: settings.showSystem)
        apply(output)
        if Date().timeIntervalSince(lastStartupRefresh) > Self.startupRefreshInterval || isPanelVisible
            && Date().timeIntervalSince(lastStartupRefresh) > 5 {
            lastStartupRefresh = Date()
            var items = await engine.startupItems()
            attachPorts(to: &items)
            startupItems = items
        } else {
            attachPorts(to: &startupItems)
        }
        isScanning = false
    }

    private func apply(_ output: ScanOutput) {
        snapshot = output.snapshot
        plans = output.plans
        lastUpdated = output.snapshot.date
        recomputeVisible()
        detectRespawns()
        detectNewPorts()
    }

    private func attachPorts(to items: inout [StartupItem]) {
        var portsByLabel: [String: [UInt16]] = [:]
        for group in snapshot.groups {
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

    // MARK: Actions

    /// One-click stop for a whole group (project / service / app). For launchd jobs: bootout (stops until next login).
    func stop(_ group: ListenerGroup, mode: StopMode = .graceful) {
        stopProcesses(group.processes, groupID: group.id, title: group.title, mode: mode,
                      onlyThisProcess: false, disableAutoStart: false)
    }

    /// Stop one listener's kill plan (or only its PID when `onlyThisProcess`).
    func stop(_ process: ListenerProcess, mode: StopMode = .graceful, onlyThisProcess: Bool = false) {
        let group = snapshot.groups.first { $0.processes.contains { $0.id == process.id } }
        stopProcesses([process], groupID: group?.id ?? "pid:\(process.id)", title: process.displayName,
                      mode: mode, onlyThisProcess: onlyThisProcess, disableAutoStart: false)
    }

    /// Stop now AND prevent restarts: launchctl bootout+disable / pm2 delete+save / docker update --restart=no + stop.
    func stopAndDisableAutoStart(_ group: ListenerGroup) {
        stopProcesses(group.processes, groupID: group.id, title: group.title, mode: .graceful,
                      onlyThisProcess: false, disableAutoStart: true)
    }

    private func stopProcesses(_ processes: [ListenerProcess], groupID: String, title: String, mode: StopMode,
                               onlyThisProcess: Bool, disableAutoStart: Bool) {
        guard let engine, !busyGroupIDs.contains(groupID) else { return }
        busyGroupIDs.insert(groupID)
        let ports = Set(processes.flatMap(\.ports))
        let timeout = settings.gracefulTimeout

        Task {
            var errors: [String] = []
            var managedNotes: [String] = []
            var plainProcesses: [ListenerProcess] = []
            var handledLaunchd = Set<String>()
            var handledPM2 = Set<Int>()
            var handledDocker = Set<String>()

            // 1. Processes owned by a manager are stopped through that manager (a plain kill would respawn).
            for process in processes {
                switch process.manager {
                case .launchd(let job) where job.isUserAgent && !onlyThisProcess:
                    guard handledLaunchd.insert(job.label).inserted else { continue }
                    let label = job.label
                    let error = await engine.perform {
                        if disableAutoStart { try engine.launchd.disable(label: label) } else { try engine.launchd.stop(label: label) }
                    }
                    if let error { errors.append("\(label): \(error.localizedDescription)") }
                    else { managedNotes.append(disableAutoStart ? "\(label) disabled" : "\(label) stopped until next login") }
                case .pm2(let id, let name) where !onlyThisProcess:
                    guard handledPM2.insert(id).inserted else { continue }
                    let error = await engine.perform {
                        if disableAutoStart { try engine.pm2.delete(id: id) } else { try engine.pm2.stop(id: id) }
                    }
                    if let error { errors.append("pm2 \(name): \(error.localizedDescription)") }
                    else { managedNotes.append(disableAutoStart ? "pm2 \(name) removed" : "pm2 \(name) stopped") }
                case .docker(let container):
                    guard handledDocker.insert(container.id).inserted else { continue }
                    let error = await engine.perform {
                        if disableAutoStart { try engine.docker.disableRestart(id: container.id) }
                        try engine.docker.stop(id: container.id)
                    }
                    if let error { errors.append("\(container.name): \(error.localizedDescription)") }
                    else { managedNotes.append("container \(container.name) stopped") }
                default:
                    plainProcesses.append(process)
                }
            }

            // 2. Everything else: signal the kill plan (whole dev-server tree).
            var stoppedRecords: [StoppedRecord] = []
            var escalated = false
            if !plainProcesses.isEmpty {
                let freshPlans = await engine.freshPlans(for: plainProcesses, onlyThisProcess: onlyThisProcess)
                if freshPlans.isEmpty {
                    errors.append("already exited")
                }
                for plan in freshPlans {
                    guard !plan.targets.isEmpty else {
                        errors.append(plan.warnings.first ?? "\(plan.root.comm) is protected and was not stopped")
                        continue
                    }
                    let rootDetails = engine.scanner.details(for: plan.root)
                    let result = await engine.killer.stop(plan, mode: mode, timeout: timeout, allowAdmin: plan.requiresAdmin)
                    escalated = escalated || result.escalated
                    for failure in result.failures {
                        errors.append("pid \(failure.pid): \(failure.reason)")
                    }
                    if !result.stopped.isEmpty {
                        let planPorts = plainProcesses
                            .filter { p in plan.targets.contains { $0.pid == p.basic.pid } }
                            .flatMap(\.ports)
                        let listener = plainProcesses.first { p in plan.targets.contains { $0.pid == p.basic.pid } }
                        stoppedRecords.append(StoppedRecord(
                            id: UUID(), date: Date(),
                            title: listener.map { "\(title) · \($0.displayName)" } ?? title,
                            ports: Array(Set(planPorts)).sorted(),
                            cwd: rootDetails?.cwd,
                            arguments: rootDetails?.arguments ?? [],
                            environment: rootDetails?.environment ?? [:],
                            executablePath: rootDetails?.executablePath,
                            manager: listener?.manager ?? .none))
                    }
                }
            }

            recentlyStopped.insert(contentsOf: stoppedRecords, at: 0)
            if recentlyStopped.count > Self.maxRecentlyStopped {
                recentlyStopped.removeLast(recentlyStopped.count - Self.maxRecentlyStopped)
            }
            if !ports.isEmpty {
                recentStops.append(RecentStop(date: Date(), ports: ports, groupTitle: title))
            }

            busyGroupIDs.remove(groupID)
            engine.invalidateManagerCaches()
            lastStartupRefresh = .distantPast

            let portText = ports.isEmpty ? "" : " (" + ports.sorted().map { ":\($0)" }.joined(separator: ", ") + ")"
            if errors.isEmpty {
                var message = "Stopped \(title)\(portText)"
                if escalated { message += " — had to force-kill" }
                if !managedNotes.isEmpty { message += " · " + managedNotes.joined(separator: ", ") }
                let managedNoDisable = !disableAutoStart && processes.contains { $0.manager.isAutoRestarting }
                if managedNoDisable, processes.contains(where: { if case .launchd = $0.manager { return true } else { return false } }) {
                    banner = Banner(style: .success, message: message + ". It will start again at next login.",
                                    action: .disableAutoStart(groupID: groupID), actionTitle: "Disable Auto-Start")
                } else if let record = stoppedRecords.first, record.canRelaunch {
                    banner = Banner(style: .success, message: message, action: .relaunch(recordID: record.id),
                                    actionTitle: "Undo")
                } else {
                    banner = Banner(style: .success, message: message)
                }
            } else {
                banner = Banner(style: .error, message: "Couldn't fully stop \(title): " + errors.prefix(3).joined(separator: "; "))
            }
            await scanOnce()
        }
    }

    /// Enable or disable a startup item (launchctl enable+bootstrap / bootout+disable).
    func setStartupItem(_ item: StartupItem, enabled: Bool) {
        guard let engine, item.label != LoginItemManager.label else { return }
        let id = "startup:\(item.label)"
        guard !busyGroupIDs.contains(id) else { return }
        busyGroupIDs.insert(id)
        Task {
            let error = await engine.perform {
                if enabled { try engine.launchd.enable(label: item.label, plistPath: item.plistPath) }
                else { try engine.launchd.disable(label: item.label) }
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

    /// Start (kickstart) a loaded-but-stopped startup item.
    func startStartupItem(_ item: StartupItem) {
        guard let engine, item.label != LoginItemManager.label else { return }
        let id = "startup:\(item.label)"
        guard !busyGroupIDs.contains(id) else { return }
        busyGroupIDs.insert(id)
        Task {
            let error = await engine.perform {
                if item.isLoaded { try engine.launchd.start(label: item.label) }
                else { try engine.launchd.enable(label: item.label, plistPath: item.plistPath) }
            }
            busyGroupIDs.remove(id)
            banner = error.map { Banner(style: .error, message: "\(item.label): \($0.localizedDescription)") }
                ?? Banner(style: .success, message: "Started \(item.label)")
            engine.invalidateManagerCaches()
            lastStartupRefresh = .distantPast
            await scanOnce()
        }
    }

    /// Stops every `.project` group.
    func stopAllProjects() {
        for group in snapshot.groups where group.category == .project && !settings.ignoredGroupIDs.contains(group.id) {
            stop(group)
        }
    }

    /// Re-run a stopped command with its original argv, env and cwd (detached, logs to ~/Library/Logs/PortPilot).
    func relaunch(_ record: StoppedRecord) {
        guard engine != nil, record.canRelaunch else { return }
        Task {
            let result: Result<Int32, Error> = await withCheckedContinuation { continuation in
                DispatchQueue.global(qos: .userInitiated).async {
                    do { continuation.resume(returning: .success(try Relauncher.relaunch(record))) }
                    catch { continuation.resume(returning: .failure(error)) }
                }
            }
            switch result {
            case .success(let pid):
                recentlyStopped.removeAll { $0.id == record.id }
                recentStops.removeAll { !$0.ports.isDisjoint(with: record.ports) }
                banner = Banner(style: .success, message: "Relaunched \(record.title) (pid \(pid)) — log in ~/Library/Logs/PortPilot")
            case .failure(let error):
                banner = Banner(style: .error, message: "Couldn't relaunch \(record.title): \(error.localizedDescription)")
            }
            try? await Task.sleep(nanoseconds: 800_000_000)
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
                let line = "launchd job \(job.label) (stops until next login)"
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

    func performBannerAction(_ banner: Banner) {
        guard let action = banner.action else { return }
        dismissBanner()
        switch action {
        case .disableAutoStart(let groupID):
            if let group = snapshot.groups.first(where: { $0.id == groupID }) {
                stopAndDisableAutoStart(group)
            } else if let label = groupID.split(separator: ":", maxSplits: 1).last.map(String.init),
                      groupID.hasPrefix("launchd:"),
                      let item = startupItems.first(where: { $0.label == label }) {
                setStartupItem(item, enabled: false)
            } else {
                // The group is gone (stopped). Disable any startup item whose ports matched it.
                self.banner = Banner(style: .info, message: "Already stopped. Use Startup Items below to disable it.")
            }
        case .relaunch(let recordID):
            if let record = recentlyStopped.first(where: { $0.id == recordID }) {
                relaunch(record)
            }
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
        // Notifier diffs against the previous call itself (first call only records a baseline).
        notifier.notifyNewPorts(snapshot.groups.filter { !settings.ignoredGroupIDs.contains($0.id) })
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

    private static var hasStoredSettings: Bool {
        UserDefaults.standard.data(forKey: settingsKey) != nil
    }

    private static func loadSettings() -> AppSettings {
        guard let data = UserDefaults.standard.data(forKey: settingsKey),
              let decoded = try? JSONDecoder().decode(AppSettings.self, from: data) else {
            return AppSettings()
        }
        return decoded
    }

    private func settingsDidChange(from old: AppSettings) {
        guard !isApplyingSettings, engine != nil else {
            if engine == nil { recomputeVisible() }
            return
        }
        if let data = try? JSONEncoder().encode(settings) {
            UserDefaults.standard.set(data, forKey: Self.settingsKey)
        }
        if settings.launchAtLogin != old.launchAtLogin {
            guard Self.canManageLoginItem else {
                banner = Banner(style: .warning, message: "Launch at login can only be changed from the installed copy in Applications.")
                return
            }
            do {
                try loginItem.setEnabled(settings.launchAtLogin)
            } catch {
                banner = Banner(style: .error, message: "Launch at login: \(error.localizedDescription)")
            }
        }
        if settings.notifyOnNewPorts && !old.notifyOnNewPorts {
            notifier.requestAuthorizationIfNeeded()
            notifier.resetBaseline()
        }
        if settings.showSystem != old.showSystem || settings.refreshInterval != old.refreshInterval {
            refreshNow()
        }
        recomputeVisible()
    }

    /// Only manage the login item from an installed copy — never from DerivedData, dist/ or the XCTest host,
    /// which would repoint the LaunchAgent at a build folder.
    private static var canManageLoginItem: Bool {
        if ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil { return false }
        let path = Bundle.main.bundlePath
        return path.hasPrefix("/Applications/") || path.hasPrefix(NSHomeDirectory() + "/Applications/")
    }

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

    func openInTerminal(_ path: String) {
        let candidates = ["com.googlecode.iterm2", "com.mitchellh.ghostty", "dev.warp.Warp-Stable", "com.apple.Terminal"]
        guard let appURL = candidates.lazy.compactMap({ NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0) }).first
        else { return }
        NSWorkspace.shared.open([URL(fileURLWithPath: path, isDirectory: true)], withApplicationAt: appURL,
                                configuration: NSWorkspace.OpenConfiguration())
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

    func quit() {
        pollTask?.cancel()
        NSApp.terminate(nil)
    }
}
