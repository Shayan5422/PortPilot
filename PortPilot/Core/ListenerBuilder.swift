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
    /// the topmost runner ancestor ("pid:<identity>", an approximation of the kill-plan root: the listener climbs
    /// through same-user runners such as npm/concurrently and `sh -c` shells spawned by them, stopping at boundary
    /// processes). Groups are returned sorted by first port (AppStore re-sorts per settings); processes inside a
    /// group are sorted by first port.
    ///
    /// Manager resolution: walk self+ancestors (stopping at boundary processes such as shells, terminals and agents);
    /// first pid in launchdLabelsByPID with a label that is neither "application.*" (GUI app instance) nor
    /// "com.apple.*" (OS job — never offer to disable it) → .launchd(job); pm2ByPID hit → .pm2; sockets on ports in
    /// dockerByPort (for a non-runtime, project-less process such as com.docker.backend) → one .docker listener per
    /// container; watcher → .watcher(name); else .none.
    ///
    /// `treeUsage` = usage of the process + its descendants present in `usage`, except descendants that are
    /// listeners themselves (they report their own subtree) — so `ListenerGroup.usage` never double-counts
    /// nginx/uvicorn workers.
    static func build(raw: RawScan, details: (ProcessBasic) -> ProcessDetails?, usage: [Int32: ResourceUsage],
                      resolver: ProjectResolver, maps: ManagerMaps, currentUID: UInt32) -> [ListenerGroup] {
        withoutActuallyEscaping(details) { fetchDetails in
            let builder = GroupBuilder(raw: raw, details: DetailsMemo(fetch: fetchDetails), usage: usage,
                                       resolver: resolver, maps: maps, currentUID: currentUID)
            return builder.build()
        }
    }

    /// Group title for a launchd job without a project: Homebrew formula name ("postgresql@16"), otherwise the label
    /// without its reverse-DNS prefix ("com.acme.planning-frontend" → "planning-frontend").
    static func launchdTitle(for label: String) -> String {
        for prefix in ["homebrew.mxcl.", "sh.brew."] where label.hasPrefix(prefix) && label.count > prefix.count {
            return String(label.dropFirst(prefix.count))
        }
        var parts = label.split(separator: ".").map(String.init)
        let topLevelDomains: Set<String> = [
            "com", "org", "net", "io", "dev", "app", "me", "co", "sh", "local", "ai", "de", "fr", "uk", "us", "xyz",
            "tech", "cloud",
        ]
        if parts.count >= 2, topLevelDomains.contains(parts[0].lowercased()) {
            parts.removeFirst()
            if parts.count >= 2 { parts.removeFirst() }   // vendor
        }
        let title = parts.joined(separator: ".")
        return title.isEmpty ? label : title
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

    /// Sort key for processes: first port, then pid.
    static func precedes(_ lhs: ListenerProcess, _ rhs: ListenerProcess) -> Bool {
        let left = lhs.ports.first ?? .max, right = rhs.ports.first ?? .max
        return left != right ? left < right : lhs.basic.pid < rhs.basic.pid
    }
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
    case pm2(name: String)
    case app(name: String, bundlePath: String)
    case process(root: ProcessBasic)

    var id: String {
        switch self {
        case .project(let project): return "project:" + project.rootPath
        case .launchd(let job): return "launchd:" + job.label
        case .docker(let container): return "docker:" + container.id
        case .pm2(let name): return "pm2:" + name
        case .app(_, let bundlePath): return "app:" + bundlePath
        case .process(let root): return "pid:" + root.identity.description
        }
    }
}

private struct GroupBuilder {
    let raw: RawScan
    let details: DetailsMemo
    let usage: [Int32: ResourceUsage]
    let resolver: ProjectResolver
    let maps: ManagerMaps
    let currentUID: UInt32
    let listenerPIDs: Set<Int32>

    init(raw: RawScan, details: DetailsMemo, usage: [Int32: ResourceUsage], resolver: ProjectResolver,
         maps: ManagerMaps, currentUID: UInt32) {
        self.raw = raw
        self.details = details
        self.usage = usage
        self.resolver = resolver
        self.maps = maps
        self.currentUID = currentUID
        self.listenerPIDs = Set(raw.socketsByPID.keys)
    }

    func build() -> [ListenerGroup] {
        var entries: [(process: ListenerProcess, context: GroupContext)] = []
        for pid in raw.socketsByPID.keys.sorted() {
            guard let basic = raw.table[pid], let sockets = raw.socketsByPID[pid], !sockets.isEmpty else { continue }
            entries += makeListeners(basic: basic, sockets: sockets)
        }
        return makeGroups(entries)
    }

    // MARK: Listeners

    private func makeListeners(basic: ProcessBasic,
                               sockets: [ListeningSocket]) -> [(process: ListenerProcess, context: GroupContext)] {
        let sameUser = basic.uid == currentUID
        let info: ProcessDetails? = raw.restrictedPIDs.contains(basic.pid) ? nil : details(basic)
        let isRestricted = info == nil
        // Agents, terminals, IDEs and shells are never part of a project group: a project's one-click Stop must
        // not reach them (e.g. an agent CLI that opened a port while running inside the project folder).
        let isBoundary = Classifier.isBoundaryProcess(basic: basic, details: info)
        let project = sameUser && !isBoundary ? resolver.resolve(details: info) : nil
        let ancestors = raw.table.ancestors(of: basic.pid)
        var result: [(process: ListenerProcess, context: GroupContext)] = []

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
                result.append((process, .docker(part.container)))
            }
            if remaining.isEmpty { return result }
        }

        let (manager, launchdLabel) = resolveManager(for: basic, ancestors: ancestors, details: info)
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
            origin = Classifier.origin(details: info, ancestors: ancestors,
                                       ancestorDetails: { pid in table[pid].flatMap { details($0) } },
                                       launchdLabel: launchdLabel)
        }
        let bundle = category == .app ? info?.executablePath.flatMap(Classifier.appBundle(forExecutable:)) : nil

        let process = ListenerProcess(
            basic: basic, details: info, sockets: remaining, usage: usage[basic.pid] ?? .zero,
            treeUsage: treeUsage(of: basic.pid), category: category, project: project,
            displayName: Classifier.displayName(basic: basic, details: info),
            frameworks: Classifier.frameworks(details: info, comm: basic.comm), origin: origin, manager: manager,
            appName: bundle?.name, isRestricted: isRestricted)

        let context: GroupContext
        if let project {
            context = .project(project)
        } else if case .launchd(let job) = manager {
            context = .launchd(job)
        } else if case .pm2(_, let name) = manager {
            context = .pm2(name: name)
        } else if let bundle {
            context = .app(name: bundle.name, bundlePath: bundle.bundlePath)
        } else {
            context = .process(root: runnerRoot(for: basic, ancestors: ancestors))
        }
        result.append((process, context))
        return result
    }

    private func resolveManager(for basic: ProcessBasic, ancestors: [ProcessBasic],
                                details info: ProcessDetails?) -> (ProcessManager, String?) {
        guard basic.uid == currentUID else { return (.none, nil) }
        for (index, node) in ([basic] + ancestors).enumerated() where node.pid > 1 {
            // A job above an interactive shell/terminal/agent did not start this server (e.g. a web terminal agent).
            if index > 0, Classifier.isBoundaryProcess(basic: node, details: details(node)) { break }
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
        if let watcher = Classifier.watcherName(for: basic, details: info, ancestors: ancestors,
                                                ancestorDetails: { pid in table[pid].flatMap { details($0) } }) {
            return (.watcher(name: watcher), nil)
        }
        return (.none, nil)
    }

    private static func isManagedLaunchdLabel(_ label: String) -> Bool {
        !label.isEmpty && !label.hasPrefix("application.") && !label.hasPrefix("com.apple.")
    }

    /// Usage of `pid` plus descendants, not descending into other listeners (they account for themselves).
    private func treeUsage(of pid: Int32) -> ResourceUsage {
        var total = usage[pid] ?? .zero
        // launchd's "descendants" are the whole system — never aggregate them into its row.
        guard pid > 1 else { return total }
        var stack = raw.table.childrenByPID[pid] ?? []
        var seen: Set<Int32> = [pid]
        while let child = stack.popLast() {
            guard seen.insert(child).inserted, !listenerPIDs.contains(child) else { continue }
            total = total + (usage[child] ?? .zero)
            stack += raw.table.childrenByPID[child] ?? []
        }
        return total
    }

    /// Topmost same-user runner ancestor (npm, pnpm, concurrently, make...) or `sh -c` shell spawned by one, stopping
    /// at boundary processes; the listener itself when there is none. Mirrors KillPlanner step 1 minus the
    /// "same project root" clause (this is only used for listeners without a project).
    private func runnerRoot(for basic: ProcessBasic, ancestors: [ProcessBasic]) -> ProcessBasic {
        guard basic.uid == currentUID else { return basic }
        var root = basic
        for (index, ancestor) in ancestors.enumerated() {
            guard ancestor.pid > 1, ancestor.uid == currentUID else { break }
            let info = details(ancestor)
            if Classifier.isBoundaryProcess(basic: ancestor, details: info) { break }
            if Classifier.isRunnerProcess(basic: ancestor, details: info) {
                root = ancestor
                continue
            }
            if Classifier.isScriptShell(basic: ancestor, details: info), index + 1 < ancestors.count {
                let parent = ancestors[index + 1]
                let parentInfo = details(parent)
                if parent.pid > 1, parent.uid == currentUID,
                   Classifier.isRunnerProcess(basic: parent, details: parentInfo),
                   !Classifier.isBoundaryProcess(basic: parent, details: parentInfo) {
                    root = ancestor
                    continue
                }
            }
            break
        }
        return root
    }

    // MARK: Groups

    private func makeGroups(_ entries: [(process: ListenerProcess, context: GroupContext)]) -> [ListenerGroup] {
        var contexts: [String: GroupContext] = [:]
        var members: [String: [ListenerProcess]] = [:]
        for entry in entries {
            let id = entry.context.id
            if contexts[id] == nil { contexts[id] = entry.context }
            members[id, default: []].append(entry.process)
        }
        var groups: [ListenerGroup] = []
        for (id, context) in contexts {
            let processes = (members[id] ?? []).sorted(by: ListenerBuilder.precedes)
            guard !processes.isEmpty else { continue }
            groups.append(makeGroup(id: id, context: context, processes: processes))
        }
        return groups.sorted { lhs, rhs in
            let left = lhs.ports.first ?? .max, right = rhs.ports.first ?? .max
            return left != right ? left < right : lhs.id < rhs.id
        }
    }

    private func makeGroup(id: String, context: GroupContext, processes: [ListenerProcess]) -> ListenerGroup {
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
            title = ListenerBuilder.launchdTitle(for: job.label)
            subtitle = Self.distinctLabels(processes, excluding: title)
            path = Self.meaningfulDirectory(primary.details?.cwd) ?? job.plistPath
        case .docker(let container):
            title = container.name
            subtitle = container.image
            path = nil
        case .pm2(let name):
            title = name
            subtitle = Self.distinctLabels(processes, excluding: title)
            path = Self.meaningfulDirectory(primary.details?.cwd)
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
