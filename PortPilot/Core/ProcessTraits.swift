import Foundation

/// Classification facts about one process. They only depend on its p_comm, executable, argv and exec-time
/// environment — all fixed for a `ProcessIdentity` — but computing them means parsing argv several times, so
/// `ProcessTraitsCache` computes them once per process instead of on every tick.
struct ProcessTraits: Sendable {
    /// `Classifier.isBoundaryProcess`.
    let isBoundary: Bool
    /// `KillPlanner.isProtected`: a boundary process or one of the planner's own session / agent / app rules.
    let isProtected: Bool
    /// `PM2Service.isDaemon`.
    let isPM2Daemon: Bool
    /// `Classifier.displayName`.
    let displayName: String
    /// `Classifier.frameworks`.
    let frameworks: [String]
    /// Set for a worker the PM2 God Daemon forked in cluster mode (read from its exec-time environment).
    let pm2ClusterWorker: PM2ClusterWorker?

    init(basic: ProcessBasic, details: ProcessDetails?) {
        isBoundary = Classifier.isBoundaryProcess(basic: basic, details: details)
        // A boundary process is always protected; only ask the planner (which re-checks the boundary) otherwise.
        isProtected = isBoundary || KillPlanner.isProtected(basic, details: details)
        isPM2Daemon = PM2Service.isDaemon(basic, details: details)
        displayName = Classifier.displayName(basic: basic, details: details)
        frameworks = Classifier.frameworks(details: details, comm: basic.comm)
        pm2ClusterWorker = details.flatMap { PM2ClusterWorker(environment: $0.environment) }
    }
}

/// What a PM2 cluster-mode worker's environment says about the app it belongs to.
///
/// In cluster mode the God Daemon is the Node cluster primary: it holds the listening socket and forks each
/// instance with `cluster.fork({pm2_env: JSON.stringify(env)})`, so the worker's exec-time environment has
/// `NODE_UNIQUE_ID` and a `pm2_env` JSON with the app's name, pm_id, exec_mode and its own env (e.g. PORT).
struct PM2ClusterWorker: Hashable, Sendable {
    let name: String?
    let id: Int?
    /// The app's PORT setting, when it has one.
    let port: UInt16?

    /// nil when the environment is not the one of a cluster-mode worker.
    init?(environment: [String: String]) {
        let isClusterWorker = environment["NODE_UNIQUE_ID"] != nil
        guard isClusterWorker || environment["pm2_env"] != nil else { return nil }
        var name: String?, id: Int?, port: UInt16?
        if let json = environment["pm2_env"], json.utf8.count < 1 << 20,
           let object = (try? JSONSerialization.jsonObject(with: Data(json.utf8))) as? [String: Any] {
            if let mode = object["exec_mode"] as? String, mode != "cluster_mode" { return nil }
            name = object["name"] as? String
            id = Self.int(object["pm_id"])
            let nested = object["env"] as? [String: Any]
            port = Self.int(object["PORT"] ?? nested?["PORT"]).flatMap { UInt16(exactly: $0) }
        } else if !isClusterWorker {
            return nil
        }
        self.name = name
        self.id = id
        self.port = port
    }

    init(name: String?, id: Int?, port: UInt16?) {
        self.name = name
        self.id = id
        self.port = port
    }

    private static func int(_ value: Any?) -> Int? {
        if let number = value as? Int { return number }
        if let text = value as? String { return Int(text.trimmingCharacters(in: .whitespaces)) }
        return nil
    }
}

/// Thread-safe memo of `ProcessTraits` per process identity, plus the per-listener answers that depend on the
/// listener's whole ancestry (watcher, launch origin, kill-plan launch root). Owned by `ScanEngine` across ticks and
/// pruned with the process table; `ListenerBuilder` creates a throwaway one when it is not given one.
///
/// An entry is reused only while the process looks the same: same p_comm (an exec keeps the pid and start time
/// but changes it) and the same kind of details (unreadable, empty argv while exec'ing, or complete).
final class ProcessTraitsCache: @unchecked Sendable {
    /// What an entry was computed from; a different value means the facts may have changed.
    struct Signature: Hashable {
        let comm: String
        /// -1 when details were unavailable, else argv count.
        let argumentCount: Int
        let hasExecutablePath: Bool

        init(_ basic: ProcessBasic, _ details: ProcessDetails?) {
            comm = basic.comm
            argumentCount = details.map { $0.arguments.count } ?? -1
            hasExecutablePath = details?.executablePath != nil
        }
    }

    /// A listener and its ancestors (nearest first), as they were when an ancestry answer was computed.
    struct Lineage: Hashable {
        let members: [ProcessIdentity]
        let signatures: [Signature]
    }

    private struct TraitsEntry {
        let signature: Signature
        let traits: ProcessTraits
    }

    private struct LineageEntry<Value> {
        let lineage: Lineage
        let extra: String?
        let value: Value
    }

    private let lock = NSLock()
    private var traitsByIdentity: [ProcessIdentity: TraitsEntry] = [:]
    private var watchers: [ProcessIdentity: LineageEntry<String?>] = [:]
    private var origins: [ProcessIdentity: LineageEntry<LaunchOrigin?>] = [:]
    private var launchRoots: [ProcessIdentity: LineageEntry<ProcessBasic>] = [:]

    init() {}

    /// Traits of `basic`, computed at most once per identity (and again only if its details change kind).
    func traits(for basic: ProcessBasic, details: ProcessDetails?) -> ProcessTraits {
        let signature = Signature(basic, details)
        let identity = basic.identity
        if let entry = lock.withLock({ traitsByIdentity[identity] }), entry.signature == signature {
            return entry.traits
        }
        let traits = ProcessTraits(basic: basic, details: details)
        lock.withLock { traitsByIdentity[identity] = TraitsEntry(signature: signature, traits: traits) }
        return traits
    }

    /// `compute()` once per listener and unchanged ancestry.
    func watcherName(for listener: ProcessIdentity, lineage: Lineage, compute: () -> String?) -> String? {
        if let entry = lock.withLock({ watchers[listener] }), entry.lineage == lineage { return entry.value }
        let value = compute()
        lock.withLock { watchers[listener] = LineageEntry(lineage: lineage, extra: nil, value: value) }
        return value
    }

    /// `compute()` once per listener, unchanged ancestry and launchd label.
    func origin(for listener: ProcessIdentity, lineage: Lineage, launchdLabel: String?,
                compute: () -> LaunchOrigin?) -> LaunchOrigin? {
        if let entry = lock.withLock({ origins[listener] }), entry.lineage == lineage, entry.extra == launchdLabel {
            return entry.value
        }
        let value = compute()
        lock.withLock { origins[listener] = LineageEntry(lineage: lineage, extra: launchdLabel, value: value) }
        return value
    }

    /// `compute()` once per listener, unchanged ancestry and project root. The kill-plan launch root only depends on
    /// the listener's ancestors (and the project they are compared with), never on its descendants.
    func launchRoot(for listener: ProcessIdentity, lineage: Lineage, projectRoot: String?,
                    compute: () -> ProcessBasic) -> ProcessBasic {
        if let entry = lock.withLock({ launchRoots[listener] }), entry.lineage == lineage, entry.extra == projectRoot {
            return entry.value
        }
        let value = compute()
        lock.withLock { launchRoots[listener] = LineageEntry(lineage: lineage, extra: projectRoot, value: value) }
        return value
    }

    /// Drops entries of processes that are no longer alive (call once per scan with the fresh table).
    func prune(keepingAliveIn table: ProcessTable) {
        lock.withLock {
            traitsByIdentity = traitsByIdentity.filter { table.isAlive($0.key) }
            watchers = watchers.filter { table.isAlive($0.key) }
            origins = origins.filter { table.isAlive($0.key) }
            launchRoots = launchRoots.filter { table.isAlive($0.key) }
        }
    }

    /// Number of memoized processes (for tests).
    var count: Int { lock.withLock { traitsByIdentity.count } }
}
