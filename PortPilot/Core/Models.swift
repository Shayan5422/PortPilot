import Foundation

// Shared data model for PortPilot. Every module codes against these types.
// Keep this file free of side effects (no syscalls, no shell, no UI).

// MARK: - Process identity

/// A PID plus its start time. PIDs are recycled by the kernel, so every action
/// that targets a process (kill, inspect) must re-verify the start time first.
struct ProcessIdentity: Hashable, Codable, Sendable, CustomStringConvertible {
    let pid: Int32
    /// Process start time in microseconds since 1970 (from kinfo_proc p_starttime).
    let startTime: UInt64

    var description: String { "\(pid)@\(startTime)" }
}

/// Cheap per-process facts gathered for *every* process on each scan
/// (one sysctl(KERN_PROC_ALL) call).
struct ProcessBasic: Hashable, Sendable {
    let pid: Int32
    let ppid: Int32
    let pgid: Int32
    let uid: UInt32
    /// Short kernel name (p_comm, max 16 chars), e.g. "node", "Python", "zsh".
    let comm: String
    /// Microseconds since 1970.
    let startTime: UInt64

    var identity: ProcessIdentity { ProcessIdentity(pid: pid, startTime: startTime) }
    var startDate: Date { Date(timeIntervalSince1970: TimeInterval(startTime) / 1_000_000) }
}

/// Snapshot of the whole process table with parent/child indexes.
struct ProcessTable: Sendable {
    let processes: [Int32: ProcessBasic]
    let childrenByPID: [Int32: [Int32]]

    init(processes list: [ProcessBasic]) {
        var map: [Int32: ProcessBasic] = [:]
        var children: [Int32: [Int32]] = [:]
        map.reserveCapacity(list.count)
        for p in list {
            map[p.pid] = p
        }
        for p in list where p.pid != p.ppid && p.pid > 0 {
            children[p.ppid, default: []].append(p.pid)
        }
        for key in children.keys { children[key]?.sort() }
        self.processes = map
        self.childrenByPID = children
    }

    static let empty = ProcessTable(processes: [])

    subscript(pid: Int32) -> ProcessBasic? { processes[pid] }

    func parent(of pid: Int32) -> ProcessBasic? {
        guard let p = processes[pid], p.ppid != p.pid else { return nil }
        return processes[p.ppid]
    }

    /// Ancestors nearest-first, excluding `pid` itself. Includes launchd (pid 1) as the
    /// last element when reachable. Cycle-safe.
    func ancestors(of pid: Int32) -> [ProcessBasic] {
        var result: [ProcessBasic] = []
        var seen: Set<Int32> = [pid]
        var current = processes[pid]
        while let c = current, c.ppid > 0, !seen.contains(c.ppid), let parent = processes[c.ppid] {
            result.append(parent)
            seen.insert(parent.pid)
            current = parent
        }
        return result
    }

    /// All descendants (breadth-first), excluding `pid` itself. Cycle-safe.
    func descendants(of pid: Int32) -> [ProcessBasic] {
        var result: [ProcessBasic] = []
        var queue: [Int32] = childrenByPID[pid] ?? []
        var seen: Set<Int32> = [pid]
        var index = 0
        while index < queue.count {
            let child = queue[index]
            index += 1
            guard !seen.contains(child), let p = processes[child] else { continue }
            seen.insert(child)
            result.append(p)
            queue.append(contentsOf: childrenByPID[child] ?? [])
        }
        return result
    }

    /// True when `identity` still refers to the same live process.
    func isAlive(_ identity: ProcessIdentity) -> Bool {
        processes[identity.pid]?.startTime == identity.startTime
    }
}

/// Expensive per-process facts (argv, env, cwd, executable). Cached per ProcessIdentity
/// because none of these change during a process's life in practice.
struct ProcessDetails: Sendable {
    let identity: ProcessIdentity
    /// Absolute executable path from proc_pidpath, e.g. "/opt/homebrew/bin/node".
    let executablePath: String?
    /// argv including argv[0]. Empty when unreadable.
    let arguments: [String]
    /// Environment of the process at exec time (KERN_PROCARGS2). Empty when unreadable.
    let environment: [String: String]
    /// Current working directory (PROC_PIDVNODEPATHINFO). nil when unreadable.
    let cwd: String?

    /// Best-effort human executable name: last path component of executablePath,
    /// falling back to argv[0].
    var executableName: String {
        if let path = executablePath, !path.isEmpty { return (path as NSString).lastPathComponent }
        if let first = arguments.first, !first.isEmpty { return (first as NSString).lastPathComponent }
        return ""
    }

    /// argv joined with spaces, arguments containing spaces are quoted.
    var commandLine: String {
        arguments.map { arg in
            arg.contains(" ") || arg.isEmpty ? "\"\(arg)\"" : arg
        }.joined(separator: " ")
    }
}

// MARK: - Sockets & resources

enum IPFamily: String, Codable, Sendable {
    case ipv4, ipv6
}

struct ListeningSocket: Hashable, Sendable {
    let port: UInt16
    /// "127.0.0.1", "::1", "*" (any address), or a concrete address.
    let address: String
    let family: IPFamily
    let pid: Int32

    /// True when bound only to loopback (127.0.0.0/8 or ::1).
    var isLoopbackOnly: Bool { address.hasPrefix("127.") || address == "::1" }
    /// True when reachable from other machines on the network.
    var isExposed: Bool { !isLoopbackOnly }
}

struct ResourceUsage: Hashable, Sendable {
    /// Percent of ONE core (Activity Monitor convention: 200% = two cores busy).
    var cpuPercent: Double
    /// Physical footprint in bytes (Activity Monitor "Memory" column).
    var memoryBytes: UInt64

    static let zero = ResourceUsage(cpuPercent: 0, memoryBytes: 0)

    static func + (lhs: ResourceUsage, rhs: ResourceUsage) -> ResourceUsage {
        ResourceUsage(cpuPercent: lhs.cpuPercent + rhs.cpuPercent,
                      memoryBytes: lhs.memoryBytes &+ rhs.memoryBytes)
    }
}

// MARK: - Classification

enum ListenerCategory: String, Codable, CaseIterable, Sendable, Identifiable {
    /// Something the user is building: has a project folder (git repo / package manifest / code dir under ~).
    case project
    /// Long-running user services without a project folder (Homebrew postgres/redis, tunnels, launchd agents).
    case service
    /// Ports opened by GUI applications (.app bundles): VS Code helpers, Spotify, Electron apps...
    case app
    /// Apple/system processes or processes owned by other users (root).
    case system

    var id: String { rawValue }

    var title: String {
        switch self {
        case .project: return "Projects"
        case .service: return "Background Services"
        case .app: return "Apps"
        case .system: return "System"
        }
    }
}

/// Where a process tree was started from (shown as a badge, e.g. "Claude Code", "Terminal").
struct LaunchOrigin: Hashable, Sendable {
    enum Kind: String, Sendable {
        case claudeCode, codex, aiAgent, ide, terminal, launchd, pm2, docker, app, shell, unknown
    }
    let kind: Kind
    /// Human label, e.g. "Claude Code", "VS Code", "Terminal", "iTerm2", "launchd", "Cursor".
    let name: String
}

/// Something that will restart the process if we only kill it.
enum ProcessManager: Hashable, Sendable {
    case none
    /// launchd job in the user's GUI domain (or system domain).
    case launchd(LaunchdJob)
    /// pm2-managed app.
    case pm2(id: Int, name: String)
    /// Docker container publishing the port.
    case docker(DockerContainer)
    /// A file watcher / supervisor parent (nodemon, tsx watch, uvicorn --reload, cargo watch...).
    /// Stopping the kill-plan root (which includes the watcher) is enough.
    case watcher(name: String)

    var isAutoRestarting: Bool {
        switch self {
        case .launchd(let job): return job.keepAlive || job.runAtLoad
        case .pm2, .docker: return true
        case .watcher, .none: return false
        }
    }

    var badge: String? {
        switch self {
        case .none: return nil
        case .launchd(let job): return job.isHomebrew ? "brew services" : "launchd"
        case .pm2: return "pm2"
        case .docker: return "Docker"
        case .watcher(let name): return name
        }
    }
}

struct LaunchdJob: Hashable, Sendable {
    let label: String
    /// "gui/<uid>" for user agents, "system" for daemons.
    let domain: String
    let plistPath: String?
    let keepAlive: Bool
    let runAtLoad: Bool
    /// pid of the job's main process when running.
    let pid: Int32?

    var serviceTarget: String { "\(domain)/\(label)" }
    var isHomebrew: Bool { label.hasPrefix("homebrew.mxcl.") || label.hasPrefix("sh.brew.") }
    /// Agents in ~/Library/LaunchAgents can be managed without admin rights.
    var isUserAgent: Bool { domain.hasPrefix("gui/") }
}

struct DockerContainer: Hashable, Sendable {
    let id: String
    let name: String
    let image: String
    /// Docker restart policy, e.g. "no", "always", "unless-stopped".
    let restartPolicy: String?
}

struct ProjectInfo: Hashable, Sendable {
    /// Absolute path used as the grouping key (git root, else nearest manifest dir, else cwd).
    let rootPath: String
    /// Display name: package.json/pyproject name or the root folder name.
    let name: String
    /// Path of the process's package dir relative to rootPath, e.g. "frontend"; nil when equal.
    let subpath: String?
    /// Marker files found, e.g. [".git", "package.json"].
    let markers: [String]
}

// MARK: - Scan results

/// One process that owns at least one listening TCP socket.
struct ListenerProcess: Identifiable, Sendable {
    var id: ProcessIdentity { basic.identity }
    let basic: ProcessBasic
    let details: ProcessDetails?
    let sockets: [ListeningSocket]
    /// Usage of this process alone.
    var usage: ResourceUsage
    /// Usage of this process plus its descendants (esbuild, workers...), excluding descendants that are
    /// themselves listeners so group totals never double-count.
    var treeUsage: ResourceUsage
    let category: ListenerCategory
    let project: ProjectInfo?
    /// Short label for the row, e.g. "vite", "uvicorn app.main:app", "postgres", "Spotify".
    let displayName: String
    /// Framework/tool hints from argv, e.g. ["Vite"], ["Next.js"], ["uvicorn"].
    let frameworks: [String]
    let origin: LaunchOrigin?
    let manager: ProcessManager
    /// For `.app` category: application name derived from the enclosing .app bundle.
    let appName: String?
    /// True when we could not read details (other user / permission).
    let isRestricted: Bool

    var ports: [UInt16] { Array(Set(sockets.map(\.port))).sorted() }
    var commandLine: String { details?.commandLine ?? basic.comm }
    var isExposedToNetwork: Bool { sockets.contains { $0.isExposed } }
}

/// Listeners grouped for display: one group per project root, launchd job, app, or lone process.
struct ListenerGroup: Identifiable, Sendable {
    /// Stable key, e.g. "project:/Users/me/code/foo", "launchd:homebrew.mxcl.redis",
    /// "app:/Applications/Spotify.app", "docker:<containerID>", "pm2:<name>", "pid:1234@..."
    let id: String
    let category: ListenerCategory
    let title: String
    /// Secondary line, e.g. "frontend · Vite" or a shortened command.
    let subtitle: String?
    /// Folder to reveal in Finder (project root / cwd / app bundle).
    let path: String?
    var processes: [ListenerProcess]

    var ports: [UInt16] { Array(Set(processes.flatMap(\.ports))).sorted() }
    var usage: ResourceUsage { processes.reduce(.zero) { $0 + $1.treeUsage } }
    /// The manager that matters most for Stop: an auto-restarting one (launchd/pm2/Docker) beats a watcher.
    var manager: ProcessManager {
        processes.lazy.map(\.manager).first { $0.isAutoRestarting }
            ?? processes.lazy.map(\.manager).first { $0 != .none } ?? .none
    }
    var origin: LaunchOrigin? { processes.lazy.compactMap(\.origin).first }
    var frameworks: [String] {
        var seen = Set<String>()
        return processes.flatMap(\.frameworks).filter { seen.insert($0).inserted }
    }
    var oldestStart: Date? { processes.map(\.basic.startDate).min() }
    var isExposedToNetwork: Bool { processes.contains { $0.isExposedToNetwork } }
}

struct ScanSnapshot: Sendable {
    let date: Date
    let groups: [ListenerGroup]
    let table: ProcessTable
    /// Wall-clock duration of the scan, for the debug footer.
    let duration: TimeInterval
    /// Processes we could not inspect (other users) — shown only in System mode.
    let restrictedCount: Int

    static let empty = ScanSnapshot(date: .distantPast, groups: [], table: .empty, duration: 0, restrictedCount: 0)
}

// MARK: - Startup items (launchd agents the user can enable/disable)

struct StartupItem: Identifiable, Hashable, Sendable {
    var id: String { label }
    let label: String
    let plistPath: String
    /// Program + arguments summary, e.g. "/opt/homebrew/bin/node server.js".
    let command: String
    let workingDirectory: String?
    let runAtLoad: Bool
    let keepAlive: Bool
    /// `launchctl print-disabled` says disabled.
    let isDisabled: Bool
    /// Present in `launchctl list` (bootstrapped into the domain).
    let isLoaded: Bool
    let pid: Int32?
    let lastExitStatus: Int32?
    /// Ports currently opened by this job's process tree (filled in by AppStore).
    var ports: [UInt16]

    var isRunning: Bool { pid != nil }
    var isHomebrew: Bool { label.hasPrefix("homebrew.mxcl.") || label.hasPrefix("sh.brew.") }
}

// MARK: - Stopping processes

enum StopMode: String, Sendable {
    /// SIGTERM the plan, wait, then SIGKILL survivors.
    case graceful
    /// SIGKILL immediately.
    case force
}

/// What will be signalled when the user presses Stop for a listener.
struct KillPlan: Sendable {
    /// Topmost process that belongs to this server's launch (e.g. `npm run dev`), may equal the listener.
    let root: ProcessBasic
    /// Everything to signal: root + descendants, children-first order.
    let targets: [ProcessBasic]
    /// Human-readable lines, e.g. ["npm run dev (pid 1200)", "node vite (pid 1201)"].
    let summary: [String]
    /// True when any target belongs to another user (needs an admin prompt).
    let requiresAdmin: Bool
    /// Warnings shown before stopping, e.g. "Managed by launchd — it will restart unless disabled".
    let warnings: [String]
}

struct StopResult: Sendable {
    let requested: [ProcessIdentity]
    /// PIDs confirmed gone.
    let stopped: [Int32]
    /// PIDs still alive after escalation, with reason.
    let failures: [StopFailure]
    /// True if SIGKILL had to be used.
    let escalated: Bool

    var succeeded: Bool { failures.isEmpty }
}

struct StopFailure: Hashable, Sendable {
    let pid: Int32
    let reason: String
}

/// Kept in memory (never written to disk — environment may contain secrets) so the user can
/// copy the command or relaunch a server they stopped by mistake.
struct StoppedRecord: Identifiable, Sendable {
    let id: UUID
    let date: Date
    let title: String
    let ports: [UInt16]
    let cwd: String?
    let arguments: [String]
    let environment: [String: String]
    let executablePath: String?
    let manager: ProcessManager

    var commandLine: String {
        arguments.map { $0.contains(" ") ? "\"\($0)\"" : $0 }.joined(separator: " ")
    }
    /// launchd/pm2/docker items are restarted through their manager instead.
    var canRelaunch: Bool {
        guard !arguments.isEmpty else { return false }
        switch manager {
        case .none, .watcher: return true
        case .launchd, .pm2, .docker: return false
        }
    }
}

// MARK: - Settings

struct AppSettings: Codable, Equatable, Sendable {
    /// Seconds between background scans.
    var refreshInterval: Double = 3
    var showApps: Bool = false
    var showSystem: Bool = false
    var showCountInMenuBar: Bool = true
    var launchAtLogin: Bool = true
    var notifyOnNewPorts: Bool = false
    /// Seconds to wait after SIGTERM before SIGKILL.
    var gracefulTimeout: Double = 3
    /// Group ids the user chose to hide.
    var ignoredGroupIDs: [String] = []
    /// Ports the user chose to hide.
    var ignoredPorts: [UInt16] = []
    var sortOrder: SortOrder = .port
    /// CPU % (of one core) above which a group is highlighted as heavy.
    var heavyCPUThreshold: Double = 80
    /// Memory above which a group is highlighted as heavy.
    var heavyMemoryBytes: UInt64 = 1_500_000_000

    enum SortOrder: String, Codable, CaseIterable, Sendable, Identifiable {
        case port, name, cpu, memory, newest
        var id: String { rawValue }
        var title: String {
            switch self {
            case .port: return "Port"
            case .name: return "Name"
            case .cpu: return "CPU"
            case .memory: return "Memory"
            case .newest: return "Newest"
            }
        }
    }

    static let refreshChoices: [Double] = [1, 2, 3, 5, 10, 30]
}

// MARK: - Banners (transient feedback in the panel)

struct Banner: Identifiable, Equatable, Sendable {
    enum Style: Sendable { case info, success, warning, error }
    enum Action: Equatable, Sendable {
        /// Offer to stop the respawned job and disable its auto-start.
        case disableAutoStart(groupID: String)
        case relaunch(recordID: UUID)
    }
    let id: UUID
    let style: Style
    let message: String
    let action: Action?
    let actionTitle: String?

    init(style: Style, message: String, action: Action? = nil, actionTitle: String? = nil) {
        self.id = UUID()
        self.style = style
        self.message = message
        self.action = action
        self.actionTitle = actionTitle
    }
}

// MARK: - Formatting helpers (pure)

enum Format {
    static func bytes(_ value: UInt64) -> String {
        let v = Double(value)
        if v >= 1_000_000_000 { return String(format: "%.1f GB", v / 1_000_000_000) }
        if v >= 1_000_000 { return String(format: "%.0f MB", v / 1_000_000) }
        if v >= 1_000 { return String(format: "%.0f KB", v / 1_000) }
        return "\(value) B"
    }

    static func cpu(_ percent: Double) -> String {
        if percent < 0.05 { return "0%" }
        if percent < 10 { return String(format: "%.1f%%", percent) }
        return String(format: "%.0f%%", percent)
    }

    /// "45s", "12m", "3h 4m", "2d 5h".
    static func uptime(since date: Date, now: Date = Date()) -> String {
        let s = max(0, Int(now.timeIntervalSince(date)))
        if s < 60 { return "\(s)s" }
        let m = s / 60
        if m < 60 { return "\(m)m" }
        let h = m / 60
        if h < 24 { return m % 60 == 0 ? "\(h)h" : "\(h)h \(m % 60)m" }
        let d = h / 24
        return h % 24 == 0 ? "\(d)d" : "\(d)d \(h % 24)h"
    }

    /// Replaces the home directory prefix with "~".
    static func abbreviatePath(_ path: String) -> String {
        let home = NSHomeDirectory()
        if path == home { return "~" }
        if path.hasPrefix(home + "/") { return "~" + path.dropFirst(home.count) }
        return path
    }
}
