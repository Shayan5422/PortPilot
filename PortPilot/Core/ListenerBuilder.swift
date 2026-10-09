import Foundation

/// Process-manager facts gathered by the Control services, keyed for O(1) lookups while building a snapshot.
struct ManagerMaps {
    /// pid → launchd label for running jobs in gui/<uid> (from LaunchdService.runningJobLabels()).
    var launchdLabelsByPID: [Int32: String] = [:]
    /// label → job info.
    var launchdJobs: [String: LaunchdJob] = [:]
    /// pid → (pm2 id, name).
    var pm2ByPID: [Int32: (id: Int, name: String)] = [:]
    /// host port → container.
    var dockerByPort: [UInt16: DockerContainer] = [:]
}

/// Turns a raw scan into the grouped rows the panel shows. Pure with respect to the system: it only uses the
/// values and closures passed in (no syscalls, no subprocesses).
enum ListenerBuilder {

    /// Builds ListenerProcess values and groups them.
    /// Grouping: by project rootPath ("project:<root>"); else by launchd label ("launchd:<label>"); else by Docker
    /// container ("docker:<id>"); else by pm2 app ("pm2:<name>"); else by app bundle ("app:<bundlePath>"); else by
    /// the listener's launch root ("pid:<identity>": the kill-plan root, i.e. the listener climbs through same-user
    /// runners such as npm/concurrently and the `sh -c` shells between them, stopping at protected processes).
    /// Groups are returned sorted by first port (AppStore re-sorts per settings); processes inside a group are
    /// sorted by first port.
    ///
    /// Manager resolution: walk self+ancestors (stopping at boundary processes such as shells, terminals and agents);
    /// first pid in launchdLabelsByPID with a label that is neither "application.*" (GUI app instance) nor
    /// "com.apple.*" (OS job — never offer to disable it) → .launchd(job); pm2ByPID hit → .pm2; sockets on ports in
    /// dockerByPort (for a non-runtime, project-less process such as com.docker.backend) → one .docker listener per
    /// container; the PM2 God Daemon's sockets → one .pm2 listener per cluster-mode app (in cluster mode the daemon
    /// is the Node cluster primary and holds the app's socket); watcher → .watcher(name); else .none.
    ///
    /// Usage: `treeUsage` = usage of the process + its descendants present in `usage`, except descendants that are
    /// listeners themselves (they report their own subtree) — so `ListenerGroup.usage` never double-counts
    /// nginx/uvicorn workers. `ListenerGroup.extraUsage` adds what else Stop ends: the launch root (npm, `sh -c`)
    /// and its other children (workers, `tsc -w`), each counted in one group only.
    ///
    /// - Parameters:
    ///   - traits: memo of per-process classification, kept across ticks by the caller (a fresh one otherwise).
    ///   - sampleUsage: samples processes missing from `usage` (the launch roots and their other children); when
    ///     nil, only `usage` is used.
    static func build(raw: RawScan, details: (ProcessBasic) -> ProcessDetails?, usage: [Int32: ResourceUsage],
                      resolver: ProjectResolver, maps: ManagerMaps, currentUID: UInt32,
                      traits: ProcessTraitsCache? = nil,
                      sampleUsage: (([ProcessBasic]) -> [Int32: ResourceUsage])? = nil) -> [ListenerGroup] {
        withoutActuallyEscaping(details) { fetchDetails in
            let builder = GroupBuilder(raw: raw, details: DetailsMemo(fetch: fetchDetails), usage: usage,
                                       resolver: resolver, maps: maps, currentUID: currentUID,
                                       traits: traits ?? ProcessTraitsCache(), sampleUsage: sampleUsage)
            return builder.build()
        }
    }

    /// Display name for a launchd job label, shared by the Projects list and Startup Items.
    ///
    /// Homebrew services show their formula ("homebrew.mxcl.postgresql@16" → "postgresql@16"). Reverse-DNS labels
    /// lose their top-level domain; the vendor segment is dropped only when what remains is one specific name
    /// ("com.acme.docs-frontend" → "docs-frontend"). It is kept, joined with spaces, when the rest is a
    /// generic word or several segments, because then the vendor is usually the project's name
    /// ("com.northwind.app" → "northwind app", "ai.tinybot.gateway" → "tinybot gateway",
    /// "com.example.status.tunnel" → "example status tunnel"). Other labels are returned unchanged.
    static func launchdTitle(for label: String) -> String {
        launchdTitle(for: label, keepingVendor: false)
    }

    /// `launchdTitle(for:)`, optionally always keeping the vendor (to tell apart two jobs with the same short name).
    static func launchdTitle(for label: String, keepingVendor: Bool) -> String {
        for prefix in ["homebrew.mxcl.", "sh.brew."] where label.hasPrefix(prefix) && label.count > prefix.count {
            return String(label.dropFirst(prefix.count))
        }
        let parts = label.split(separator: ".").map(String.init)
        guard parts.count >= 2, reverseDNSPrefixes.contains(parts[0].lowercased()) else { return label }
        let named = Array(parts.dropFirst())
        guard named.count >= 2 else { return named[0] }                     // "local.myserver" → "myserver"
        let rest = named.dropFirst()
        if !keepingVendor, rest.count == 1, let only = rest.first, !genericJobNames.contains(only.lowercased()) {
            return only
        }
        return named.joined(separator: " ")
    }

    /// Framework hint from a container image reference ("postgres:16-alpine" → "PostgreSQL").
    static func frameworks(forImage image: String) -> [String] {
        let withoutDigest = image.split(separator: "@").first.map(String.init) ?? image
        let lastPart = withoutDigest.split(separator: "/").last.map(String.init) ?? withoutDigest
        let name = (lastPart.split(separator: ":").first.map(String.init) ?? lastPart).lowercased()
        let known: [String: String] = [
            "postgres": "PostgreSQL", "postgis": "PostgreSQL", "redis": "Redis", "valkey": "Redis", "mysql": "MySQL",
            "mariadb": "MySQL", "mongo": "MongoDB", "nginx": "nginx", "caddy": "Caddy", "ollama": "Ollama",
            "rabbitmq": "RabbitMQ", "elasticsearch": "Elasticsearch", "minio": "MinIO", "localstack": "LocalStack",
        ]
        return known[name].map { [$0] } ?? []
    }

    /// Folder for a service that has no project: its working directory, else the folder of the script (for an
    /// interpreter or shell) or program it runs. Never a file, "/", a system folder or a spot inside an app bundle;
    /// nil when there is no such folder.
    static func serviceFolder(for details: ProcessDetails?) -> String? {
        guard let details else { return nil }
        if let cwd = details.cwd, !cwd.isEmpty, cwd != "/" { return cwd }
        let name = details.executableName
        let isInterpreter = Classifier.isDevRuntime(name: name)
            || KillPlanner.shellNames.contains(KillPlanner.normalizedName(name))
        let file: String?
        if isInterpreter {
            file = details.arguments.dropFirst().first { !$0.hasPrefix("-") }
        } else {
            file = details.executablePath
        }
        guard let file, file.hasPrefix("/") else { return nil }
        let parent = ProjectResolver.parent(of: (file as NSString).standardizingPath)
        guard parent.count > 1, !Classifier.isSystemExecutable(parent + "/"),
              !parent.contains(".app/"), !parent.hasSuffix(".app") else { return nil }
        return parent
    }

    /// Sort key for processes: first port, then pid.
    static func precedes(_ lhs: ListenerProcess, _ rhs: ListenerProcess) -> Bool {
        let left = lhs.ports.first ?? .max, right = rhs.ports.first ?? .max
        return left != right ? left < right : lhs.basic.pid < rhs.basic.pid
    }

    /// First labels segments treated as a reverse-DNS top-level domain.
    private static let reverseDNSPrefixes: Set<String> = [
        "com", "org", "net", "io", "dev", "app", "me", "co", "sh", "local", "ai", "de", "fr", "uk", "us", "xyz",
        "tech", "cloud", "eu", "ch", "nl", "be", "ca", "info", "edu",
    ]

    /// Job names too generic to stand on their own without the vendor ("com.northwind.app").
    private static let genericJobNames: Set<String> = [
        "agent", "api", "app", "backend", "bot", "client", "daemon", "dashboard", "dev", "frontend", "gateway",
        "helper", "job", "launcher", "main", "monitor", "prod", "proxy", "runner", "scheduler", "server", "service",
        "staging", "sync", "task", "tunnel", "ui", "updater", "watcher", "web", "worker",
    ]
}

// MARK: - Implementation

/// Per-build memo so each process's details are fetched at most once per build.
private final class DetailsMemo {
    private let fetch: (ProcessBasic) -> ProcessDetails?
    private var storage: [Int32: ProcessDetails?] = [:]

    init(fetch: @escaping (ProcessBasic) -> ProcessDetails?) {
        self.fetch = fetch
    }

    func callAsFunction(_ basic: ProcessBasic) -> ProcessDetails? {
        if let cached = storage[basic.pid] { return cached }
        let value = fetch(basic)
        storage[basic.pid] = .some(value)
        return value
    }
}

/// How a listener is grouped, with the data needed to title the group.
private enum GroupContext {
    case project(ProjectInfo)
    case launchd(LaunchdJob)
    case docker(DockerContainer)
    /// `path`: folder of the app when known up front (cluster-mode apps, whose listener is the daemon).
    case pm2(name: String, path: String?)
    case app(name: String, bundlePath: String)
    case process(root: ProcessBasic)

    var id: String {
        switch self {
        case .project(let project): return "project:" + project.rootPath
        case .launchd(let job): return "launchd:" + job.label
        case .docker(let container): return "docker:" + container.id
        case .pm2(let name, _): return "pm2:" + name
        case .app(_, let bundlePath): return "app:" + bundlePath
        case .process(let root): return "pid:" + root.identity.description
        }
    }
}

/// One listener row and where it goes.
private struct Entry {
    let process: ListenerProcess
    let context: GroupContext
    /// Root of the process tree Stop signals for this listener (the kill-plan launch root); nil when Stop does not
    /// signal a tree (Docker and PM2 cluster apps are stopped through their manager, other users' processes are
    /// never planned).
    let launchRoot: ProcessBasic?
}

private struct GroupBuilder {
    let raw: RawScan
    let details: DetailsMemo
    let usage: [Int32: ResourceUsage]
    let resolver: ProjectResolver
    let maps: ManagerMaps
    let currentUID: UInt32
    let traitsCache: ProcessTraitsCache
    let sampleUsage: (([ProcessBasic]) -> [Int32: ResourceUsage])?
    let listenerPIDs: Set<Int32>
    /// PortPilot and its ancestors: never part of a launch tree (as in KillPlanner).
    let ownLineage: Set<Int32>

    init(raw: RawScan, details: DetailsMemo, usage: [Int32: ResourceUsage], resolver: ProjectResolver,
         maps: ManagerMaps, currentUID: UInt32, traits: ProcessTraitsCache,
         sampleUsage: (([ProcessBasic]) -> [Int32: ResourceUsage])?) {
        self.raw = raw
        self.details = details
        self.usage = usage
        self.resolver = resolver
        self.maps = maps
        self.currentUID = currentUID
        self.traitsCache = traits
        self.sampleUsage = sampleUsage
        self.listenerPIDs = Set(raw.socketsByPID.keys)
        let ownPID = getpid()
        self.ownLineage = Set([ownPID] + raw.table.ancestors(of: ownPID).map(\.pid))
    }

    func build() -> [ListenerGroup] {
        var entries: [Entry] = []
        for pid in raw.socketsByPID.keys.sorted() {
            guard let basic = raw.table[pid], let sockets = raw.socketsByPID[pid], !sockets.isEmpty else { continue }
            entries += makeListeners(basic: basic, sockets: sockets)
        }
        var groups = makeGroups(entries)
        attachExtraUsage(to: &groups, entries: entries)
        return groups
    }

    private func traits(_ basic: ProcessBasic, _ info: ProcessDetails?) -> ProcessTraits {
        traitsCache.traits(for: basic, details: info)
    }

    // MARK: Listeners

    private func makeListeners(basic: ProcessBasic, sockets: [ListeningSocket]) -> [Entry] {
        let sameUser = basic.uid == currentUID
        let info: ProcessDetails? = raw.restrictedPIDs.contains(basic.pid) ? nil : details(basic)
        let isRestricted = info == nil
        let ownTraits = traits(basic, info)
        // Agents, terminals, IDEs and shells are never part of a project group: a project's one-click Stop must
        // not reach them (e.g. an agent CLI that opened a port while running inside the project folder).
        let project = sameUser && !ownTraits.isBoundary ? resolver.resolve(details: info) : nil
        let ancestors = raw.table.ancestors(of: basic.pid)
        var result: [Entry] = []

        // Docker publishes container ports from its backend process: one listener (and group) per container so each
        // can be stopped on its own. Container CPU/memory lives in the VM, so these rows carry no host usage.
        var remaining = sockets
        let executableName = info?.executableName ?? basic.comm
        if project == nil, !maps.dockerByPort.isEmpty, !Classifier.isDevRuntime(name: executableName) {
            var byContainer: [String: (container: DockerContainer, sockets: [ListeningSocket])] = [:]
            remaining = []
            for socket in sockets {
                if let container = maps.dockerByPort[socket.port] {
                    byContainer[container.id, default: (container, [])].sockets.append(socket)
                } else {
                    remaining.append(socket)
                }
            }
            for key in byContainer.keys.sorted() {
                guard let part = byContainer[key] else { continue }
                let process = ListenerProcess(
                    basic: basic, details: info, sockets: part.sockets, usage: .zero, treeUsage: .zero,
                    category: .service, project: nil, displayName: part.container.name,
                    frameworks: ListenerBuilder.frameworks(forImage: part.container.image),
                    origin: LaunchOrigin(kind: .docker, name: "Docker"), manager: .docker(part.container),
                    appName: nil, isRestricted: isRestricted)
                result.append(Entry(process: process, context: .docker(part.container), launchRoot: nil))
            }
            if remaining.isEmpty { return result }
        }

        // PM2 cluster mode: the daemon holds the apps' sockets; hand them to the apps so they stop through pm2.
        var clusterWorkers = Set<Int32>()
        if sameUser, ownTraits.isPM2Daemon, !maps.pm2ByPID.isEmpty {
            let split = splitClusterApps(daemon: basic, details: info, sockets: remaining)
            result += split.entries
            remaining = split.remaining
            clusterWorkers = split.workerPIDs
            if remaining.isEmpty { return result }
        }

        let lineage = Lineage(builder: self, basic: basic, details: info, ancestors: ancestors)
        let (manager, launchdLabel) = resolveManager(for: basic, ancestors: ancestors, details: info, lineage: lineage)
        let category = Classifier.category(basic: basic, details: info, project: project, manager: manager,
                                           currentUID: currentUID)
        let origin: LaunchOrigin?
        switch (category, manager) {
        case (.app, _), (.system, _):
            origin = nil   // the app name already says where it comes from
        case (_, .pm2):
            origin = LaunchOrigin(kind: .pm2, name: "PM2")
        default:
            let table = raw.table
            origin = traitsCache.origin(for: basic.identity, lineage: lineage.key, launchdLabel: launchdLabel) {
                Classifier.origin(details: info, ancestors: ancestors,
                                  ancestorDetails: { pid in table[pid].flatMap { details($0) } },
                                  launchdLabel: launchdLabel)
            }
        }
        let bundle = category == .app ? info?.executablePath.flatMap(Classifier.appBundle(forExecutable:)) : nil

        let process = ListenerProcess(
            basic: basic, details: info, sockets: remaining, usage: usage[basic.pid] ?? .zero,
            treeUsage: treeUsage(of: basic.pid, excluding: clusterWorkers), category: category, project: project,
            displayName: ownTraits.displayName, frameworks: ownTraits.frameworks, origin: origin, manager: manager,
            appName: bundle?.name, isRestricted: isRestricted)

        let root = launchRoot(of: process, lineage: lineage)
        let context: GroupContext
        if let project {
            context = .project(project)
        } else if case .launchd(let job) = manager {
            context = .launchd(job)
        } else if case .pm2(_, let name) = manager {
            context = .pm2(name: name, path: nil)
        } else if let bundle {
            context = .app(name: bundle.name, bundlePath: bundle.bundlePath)
        } else {
            context = .process(root: root)
        }
        let plansTree = sameUser && !isRestricted && basic.pid > 1
        result.append(Entry(process: process, context: context, launchRoot: plansTree ? root : nil))
        return result
    }

    private func resolveManager(for basic: ProcessBasic, ancestors: [ProcessBasic], details info: ProcessDetails?,
                                lineage: Lineage) -> (ProcessManager, String?) {
        guard basic.uid == currentUID else { return (.none, nil) }
        for (index, node) in ([basic] + ancestors).enumerated() where node.pid > 1 {
            // A job above an interactive shell/terminal/agent did not start this server (e.g. a web terminal agent).
            if index > 0, traits(node, details(node)).isBoundary { break }
            if let label = maps.launchdLabelsByPID[node.pid], Self.isManagedLaunchdLabel(label) {
                // Unknown job details: assume RunAtLoad so the UI offers "Stop & Disable" rather than surprising
                // the user with a restart.
                let job = maps.launchdJobs[label]
                    ?? LaunchdJob(label: label, domain: "gui/\(currentUID)", plistPath: nil, keepAlive: false,
                                  runAtLoad: true, pid: node.pid)
                return (.launchd(job), label)
            }
            if let app = maps.pm2ByPID[node.pid] {
                return (.pm2(id: app.id, name: app.name), nil)
            }
        }
        let table = raw.table
        let watcher = traitsCache.watcherName(for: basic.identity, lineage: lineage.key) {
            Classifier.watcherName(for: basic, details: info, ancestors: ancestors,
                                   ancestorDetails: { pid in table[pid].flatMap { details($0) } })
        }
        if let watcher { return (.watcher(name: watcher), nil) }
        return (.none, nil)
    }

    private static func isManagedLaunchdLabel(_ label: String) -> Bool {
        !label.isEmpty && !label.hasPrefix("application.") && !label.hasPrefix("com.apple.")
    }

    /// A listener plus its ancestors, for memoizing answers that depend on the whole ancestry. Built lazily: only
    /// listeners that need a watcher or origin pay for reading their ancestors' details.
    private final class Lineage {
        private let builder: GroupBuilder
        private let basic: ProcessBasic
        private let info: ProcessDetails?
        private let ancestors: [ProcessBasic]
        private var cached: ProcessTraitsCache.Lineage?

        init(builder: GroupBuilder, basic: ProcessBasic, details: ProcessDetails?, ancestors: [ProcessBasic]) {
            self.builder = builder
            self.basic = basic
            self.info = details
            self.ancestors = ancestors
        }

        var key: ProcessTraitsCache.Lineage {
            if let cached { return cached }
            var members = [basic.identity]
            var signatures = [ProcessTraitsCache.Signature(basic, info)]
            for ancestor in ancestors {
                members.append(ancestor.identity)
                signatures.append(ProcessTraitsCache.Signature(ancestor, builder.details(ancestor)))
            }
            let key = ProcessTraitsCache.Lineage(members: members, signatures: signatures)
            cached = key
            return key
        }
    }

    // MARK: PM2 cluster mode

    private struct ClusterSplit {
        var entries: [Entry] = []
        /// Sockets no cluster app could be matched to; they stay with the daemon.
        var remaining: [ListeningSocket]
        /// Workers whose usage now belongs to a cluster app (excluded from the daemon's own tree).
        var workerPIDs: Set<Int32> = []
    }

    /// In PM2 cluster mode the God Daemon is the Node cluster primary, so it — not the app's workers — holds the
    /// listening socket. Its sockets are attributed to the cluster-mode apps among its children that `pm2 jlist`
    /// knows: by the app's PORT setting, else to the only app left without one. Each app becomes a `.pm2` listener
    /// (stopped with pm2, never by signalling the daemon) whose usage is its workers' trees.
    private func splitClusterApps(daemon: ProcessBasic, details info: ProcessDetails?,
                                  sockets: [ListeningSocket]) -> ClusterSplit {
        struct App {
            let name: String
            var id: Int
            var port: UInt16?
            var workers: [ProcessBasic]
        }
        var apps: [App] = []
        for childPID in raw.table.childrenByPID[daemon.pid] ?? [] {
            guard let child = raw.table[childPID], child.uid == currentUID, child.startTime >= daemon.startTime,
                  let known = maps.pm2ByPID[childPID],
                  let worker = traits(child, details(child)).pm2ClusterWorker else { continue }
            if let index = apps.firstIndex(where: { $0.name == known.name }) {
                apps[index].id = min(apps[index].id, known.id)
                apps[index].port = apps[index].port ?? worker.port
                apps[index].workers.append(child)
            } else {
                apps.append(App(name: known.name, id: known.id, port: worker.port, workers: [child]))
            }
        }
        guard !apps.isEmpty else { return ClusterSplit(remaining: sockets) }

        var socketsByApp = [[ListeningSocket]](repeating: [], count: apps.count)
        var unmatched: [ListeningSocket] = []
        for socket in sockets {
            if let index = apps.firstIndex(where: { $0.port == socket.port }) {
                socketsByApp[index].append(socket)
            } else {
                unmatched.append(socket)
            }
        }
        let unclaimed = apps.indices.filter { socketsByApp[$0].isEmpty }
        if !unmatched.isEmpty, unclaimed.count == 1, let only = unclaimed.first {
            socketsByApp[only] = unmatched
            unmatched = []
        }

        var split = ClusterSplit(remaining: unmatched)
        for (index, app) in apps.enumerated() where !socketsByApp[index].isEmpty {
            guard let primary = app.workers.first else { continue }
            let workerInfo = details(primary)
            let workerTraits = traits(primary, workerInfo)
            let project = workerTraits.isBoundary ? nil : resolver.resolve(details: workerInfo)
            let manager = ProcessManager.pm2(id: app.id, name: app.name)
            let category = Classifier.category(basic: primary, details: workerInfo, project: project,
                                               manager: manager, currentUID: currentUID)
            let usage = app.workers.reduce(ResourceUsage.zero) { $0 + treeUsage(of: $1.pid) }
            let workers = app.workers.count == 1 ? "1 worker" : "\(app.workers.count) workers"
            let process = ListenerProcess(
                basic: daemon, details: info, sockets: socketsByApp[index], usage: .zero, treeUsage: usage,
                category: category, project: project, displayName: "pm2 cluster · " + workers,
                frameworks: workerTraits.frameworks, origin: LaunchOrigin(kind: .pm2, name: "PM2"), manager: manager,
                appName: nil, isRestricted: info == nil)
            let folder = project?.rootPath ?? workerInfo?.cwd.flatMap { $0.isEmpty || $0 == "/" ? nil : $0 }
            split.entries.append(Entry(process: process, context: .pm2(name: app.name, path: folder), launchRoot: nil))
            split.workerPIDs.formUnion(app.workers.map(\.pid))
        }
        return split
    }

    // MARK: Trees

    /// Usage of `pid` plus descendants, not descending into other listeners (they account for themselves) nor into
    /// `excluded` processes (accounted for elsewhere).
    private func treeUsage(of pid: Int32, excluding excluded: Set<Int32> = []) -> ResourceUsage {
        var total = usage[pid] ?? .zero
        // launchd's "descendants" are the whole system — never aggregate them into its row.
        guard pid > 1 else { return total }
        var stack = raw.table.childrenByPID[pid] ?? []
        var seen: Set<Int32> = [pid]
        while let child = stack.popLast() {
            guard seen.insert(child).inserted, !listenerPIDs.contains(child), !excluded.contains(child) else { continue }
            total = total + (usage[child] ?? .zero)
            stack += raw.table.childrenByPID[child] ?? []
        }
        return total
    }

    /// The launch root of this listener's kill plan: what Stop signals with all its descendants (`npm run dev` above
    /// `sh -c` above the server, or the listener itself). Taken from KillPlanner itself so grouping and group usage
    /// always follow its rules, and memoized per listener and ancestry: the root only depends on the ancestors, so a
    /// running server pays for it once, not on every tick.
    private func launchRoot(of process: ListenerProcess, lineage: Lineage) -> ProcessBasic {
        let basic = process.basic
        guard basic.uid == currentUID, basic.pid > 1, !process.isRestricted else { return basic }
        return traitsCache.launchRoot(for: basic.identity, lineage: lineage.key, projectRoot: process.project?.rootPath) {
            KillPlanner.plan(for: process, table: raw.table, details: { details($0) }, currentUID: currentUID).root
        }
    }

    // MARK: Groups

    private func makeGroups(_ entries: [Entry]) -> [ListenerGroup] {
        var contexts: [String: GroupContext] = [:]
        var members: [String: [ListenerProcess]] = [:]
        for entry in entries {
            let id = entry.context.id
            if contexts[id] == nil { contexts[id] = entry.context }
            members[id, default: []].append(entry.process)
        }
        // Two launchd jobs with the same short title keep their vendor ("acme cloudflared" / "northwind cloudflared").
        var launchdTitleCounts: [String: Int] = [:]
        for context in contexts.values {
            if case .launchd(let job) = context {
                launchdTitleCounts[ListenerBuilder.launchdTitle(for: job.label), default: 0] += 1
            }
        }
        var groups: [ListenerGroup] = []
        groups.reserveCapacity(contexts.count)
        for (id, context) in contexts {
            let processes = (members[id] ?? []).sorted(by: ListenerBuilder.precedes)
            guard !processes.isEmpty else { continue }
            var keepVendor = false
            if case .launchd(let job) = context {
                keepVendor = launchdTitleCounts[ListenerBuilder.launchdTitle(for: job.label), default: 0] > 1
            }
            groups.append(makeGroup(id: id, context: context, processes: processes, keepVendor: keepVendor))
        }
        // `ports` is stored, so this comparator is cheap.
        return groups.sorted { lhs, rhs in
            let left = lhs.ports.first ?? .max, right = rhs.ports.first ?? .max
            return left != right ? left < right : lhs.id < rhs.id
        }
    }

    private func makeGroup(id: String, context: GroupContext, processes: [ListenerProcess],
                           keepVendor: Bool) -> ListenerGroup {
        let primary = processes[0]
        let category = processes.map(\.category).min { Self.rank($0) < Self.rank($1) } ?? primary.category
        let title: String
        let subtitle: String?
        let path: String?

        switch context {
        case .project(let project):
            title = project.name
            var parts: [String] = []
            for process in processes {
                guard let subpath = process.project?.subpath, !parts.contains(subpath),
                      ProjectResolver.lastComponent(of: subpath) != title else { continue }
                parts.append(subpath)
            }
            subtitle = parts.isEmpty ? primary.displayName : parts.joined(separator: ", ")
            path = project.rootPath
        case .launchd(let job):
            title = ListenerBuilder.launchdTitle(for: job.label, keepingVendor: keepVendor)
            subtitle = Self.distinctLabels(processes, excluding: title)
            // A folder, never the plist file: Open in Terminal / Editor need a directory.
            path = ListenerBuilder.serviceFolder(for: primary.details)
        case .docker(let container):
            title = container.name
            subtitle = container.image
            path = nil
        case .pm2(let name, let folder):
            title = name
            subtitle = Self.distinctLabels(processes, excluding: title)
            path = folder ?? Self.meaningfulDirectory(primary.details?.cwd)
        case .app(let name, let bundlePath):
            title = name
            subtitle = Self.distinctLabels(processes, excluding: title)
            path = bundlePath
        case .process:
            title = primary.displayName
            if let directory = Self.meaningfulDirectory(primary.details?.cwd) {
                subtitle = Format.abbreviatePath(directory)
                path = directory
            } else {
                let command = primary.commandLine
                subtitle = command == title || command.isEmpty ? nil : String(command.prefix(120))
                path = nil
            }
        }
        return ListenerGroup(id: id, category: category, title: title, subtitle: subtitle, path: path,
                             processes: processes)
    }

    // MARK: Group usage beyond the listeners' own trees

    /// Adds to each group the usage of the rest of what its Stop ends: every launch root that is not a listener,
    /// plus that root's descendants outside listener trees, pruned like KillPlanner prunes its targets (other users,
    /// protected processes, PortPilot's lineage, impossible parent/child start order). Each process is counted in
    /// the first group (in display order) that reaches it, so totals across groups never double-count.
    private func attachExtraUsage(to groups: inout [ListenerGroup], entries: [Entry]) {
        var rootsByGroup: [String: [ProcessBasic]] = [:]
        for entry in entries {
            guard let root = entry.launchRoot, !listenerPIDs.contains(root.pid) else { continue }
            rootsByGroup[entry.context.id, default: []].append(root)
        }
        guard !rootsByGroup.isEmpty else { return }

        var attributed = Set<Int32>()
        var extras: [(index: Int, processes: [ProcessBasic])] = []
        var missing: [ProcessBasic] = []
        for (index, group) in groups.enumerated() {
            guard let roots = rootsByGroup[group.id] else { continue }
            var processes: [ProcessBasic] = []
            for root in roots { collectLaunchTree(from: root, into: &processes, attributed: &attributed) }
            guard !processes.isEmpty else { continue }
            extras.append((index, processes))
            missing += processes.filter { usage[$0.pid] == nil }
        }
        let sampled = missing.isEmpty ? [:] : (sampleUsage?(missing) ?? [:])
        for (index, processes) in extras {
            groups[index].extraUsage = processes.reduce(.zero) { total, process in
                total + (usage[process.pid] ?? sampled[process.pid] ?? .zero)
            }
        }
    }

    /// `root` and its descendants that are not listeners and not yet attributed (breadth-first, bounded).
    private func collectLaunchTree(from root: ProcessBasic, into processes: inout [ProcessBasic],
                                   attributed: inout Set<Int32>) {
        guard attributed.insert(root.pid).inserted else { return }
        processes.append(root)
        var queue = [root]
        var index = 0
        while index < queue.count, processes.count < Self.maxLaunchTreeSize {
            let parent = queue[index]
            index += 1
            for childPID in raw.table.childrenByPID[parent.pid] ?? [] {
                guard let child = raw.table[childPID], child.pid > 1, child.uid == currentUID,
                      !listenerPIDs.contains(child.pid), !ownLineage.contains(child.pid),
                      child.startTime >= parent.startTime, !attributed.contains(child.pid),
                      !traits(child, details(child)).isProtected else { continue }
                attributed.insert(child.pid)
                processes.append(child)
                queue.append(child)
            }
        }
    }

    /// Upper bound on one launch tree's extra processes (a runaway fork bomb must not blow the tick budget).
    private static let maxLaunchTreeSize = 256

    // MARK: Helpers

    /// "nginx" / "Code Helper, Code Helper (Plugin)" — at most two distinct row labels.
    private static func distinctLabels(_ processes: [ListenerProcess], excluding title: String) -> String? {
        var labels: [String] = []
        for process in processes where process.displayName != title && !labels.contains(process.displayName) {
            labels.append(process.displayName)
        }
        guard !labels.isEmpty else { return nil }
        return labels.count > 2 ? labels.prefix(2).joined(separator: ", ") + ", …" : labels.joined(separator: ", ")
    }

    private static func meaningfulDirectory(_ directory: String?) -> String? {
        guard let directory, !directory.isEmpty, directory != "/" else { return nil }
        return directory
    }

    private static func rank(_ category: ListenerCategory) -> Int {
        ListenerCategory.allCases.firstIndex(of: category) ?? Int.max
    }
}
