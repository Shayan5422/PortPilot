import Foundation
import SwiftUI

/// Demo data: a believable afternoon on a fictional developer's Mac, for SwiftUI previews, demo snapshots
/// (README screenshots) and UI checks. Pure values — nothing here touches the system.
///
/// Every path lives under the fictional `home`, never the real one, so a screenshot can't show the real user
/// name; `store(...)` also makes the UI shorten that fictional home to "~" (`Format.setDisplayHome`).
///
/// The set covers each state the panel can show: a monorepo started by Claude Code with a `--reload` watcher,
/// a launchd job that restarts on its own, a heavy process reachable from the network, Homebrew services,
/// a startup item that keeps failing, and two recently stopped servers.
enum PreviewData {
    static let uid: UInt32 = 501
    /// Fictional home folder (not `NSHomeDirectory()`).
    static let home = "/Users/alex"
    /// Where the fictional developer keeps projects.
    static let developer = home + "/Developer"

    // MARK: Snapshot

    static func snapshot(now: Date = Date()) -> ScanSnapshot {
        let groups = [
            acmeShop(now), notesAPI(now), blog(now), mlPlayground(now),
            postgres(now), redis(now), ollama(now), cloudflared(now),
            vsCode(now), spotify(now),
            rapportd(now),
        ]
        let basics = groups.flatMap { $0.processes.map(\.basic) }
        return ScanSnapshot(date: now.addingTimeInterval(-2), groups: groups,
                            table: ProcessTable(processes: basics), duration: 0.009, restrictedCount: 0)
    }

    static func emptySnapshot(now: Date = Date()) -> ScanSnapshot {
        // Only app ports are open, which are hidden by default → the empty state with a "hidden" hint.
        ScanSnapshot(date: now.addingTimeInterval(-1), groups: [vsCode(now), spotify(now)],
                     table: .empty, duration: 0.007, restrictedCount: 0)
    }

    static func startupItems() -> [StartupItem] {
        let agents = home + "/Library/LaunchAgents"
        return [
            StartupItem(label: "com.example.notes-api", plistPath: agents + "/com.example.notes-api.plist",
                        command: "/opt/homebrew/bin/node server.js", workingDirectory: developer + "/notes-api",
                        runAtLoad: true, keepAlive: true, isDisabled: false, isLoaded: true,
                        pid: 1187, lastExitStatus: 0, ports: [4000]),
            StartupItem(label: "homebrew.mxcl.postgresql@16", plistPath: agents + "/homebrew.mxcl.postgresql@16.plist",
                        command: "/opt/homebrew/opt/postgresql@16/bin/postgres -D /opt/homebrew/var/postgresql@16",
                        workingDirectory: "/opt/homebrew", runAtLoad: true, keepAlive: true, isDisabled: false,
                        isLoaded: true, pid: 712, lastExitStatus: 0, ports: [5432]),
            StartupItem(label: "homebrew.mxcl.redis", plistPath: agents + "/homebrew.mxcl.redis.plist",
                        command: "/opt/homebrew/opt/redis/bin/redis-server /opt/homebrew/etc/redis.conf",
                        workingDirectory: "/opt/homebrew/var", runAtLoad: true, keepAlive: true, isDisabled: false,
                        isLoaded: true, pid: 715, lastExitStatus: 0, ports: [6379]),
            // Its folder was deleted, so launchd retries it and it fails with exit 78 every time.
            StartupItem(label: "com.example.invoice-worker", plistPath: agents + "/com.example.invoice-worker.plist",
                        command: "/opt/homebrew/bin/node dist/worker.js",
                        workingDirectory: developer + "/invoice-worker",
                        runAtLoad: true, keepAlive: true, isDisabled: false, isLoaded: true,
                        pid: nil, lastExitStatus: 78, ports: []),
            StartupItem(label: "com.example.nightly-backup", plistPath: agents + "/com.example.nightly-backup.plist",
                        command: "/usr/bin/python3 backup.py --keep 14",
                        workingDirectory: developer + "/dotfiles/scripts",
                        runAtLoad: true, keepAlive: false, isDisabled: false, isLoaded: true,
                        pid: nil, lastExitStatus: 0, ports: []),
            StartupItem(label: "com.google.keystone.agent", plistPath: agents + "/com.google.keystone.agent.plist",
                        command: home + "/Library/Google/GoogleSoftwareUpdate/GoogleSoftwareUpdate.bundle/Contents/Resources/"
                            + "GoogleSoftwareUpdateAgent.app/Contents/MacOS/GoogleSoftwareUpdateAgent -runMode ifneeded",
                        workingDirectory: nil, runAtLoad: true, keepAlive: false, isDisabled: false, isLoaded: true,
                        pid: nil, lastExitStatus: 0, ports: []),
            StartupItem(label: "com.example.weather-bot", plistPath: agents + "/com.example.weather-bot.plist",
                        command: home + "/.bun/bin/bun run start", workingDirectory: developer + "/weather-bot",
                        runAtLoad: true, keepAlive: true, isDisabled: true, isLoaded: false,
                        pid: nil, lastExitStatus: nil, ports: []),
        ]
    }

    static func recentlyStopped(now: Date = Date()) -> [StoppedRecord] {
        [
            // Titles follow AppStore's "<group> · <process>"; npm and pnpm are the launch roots that Relaunch reruns.
            StoppedRecord(id: UUID(), date: now.addingTimeInterval(-4 * 60), title: "kanban · vite",
                          ports: [5173], cwd: developer + "/kanban",
                          arguments: ["npm", "run", "dev"],
                          environment: ["PATH": "/opt/homebrew/bin:/usr/bin:/bin"],
                          executablePath: nil, manager: .none),
            StoppedRecord(id: UUID(), date: now.addingTimeInterval(-38 * 60), title: "wiki · next dev",
                          ports: [3001], cwd: developer + "/wiki",
                          arguments: ["pnpm", "dev", "--port", "3001"],
                          environment: ["PATH": "/opt/homebrew/bin:/usr/bin:/bin"],
                          executablePath: nil, manager: .none),
        ]
    }

    /// The group worth expanding in a screenshot: two processes, a watcher and an AI-agent origin.
    static var featuredGroupID: String { "project:" + developer + "/acme-shop" }

    /// A preview store over the demo data. It also makes the UI show the fictional `home` as "~" for the rest of
    /// the process (previews and demo snapshots only; the app itself never calls this).
    @MainActor
    static func store(settings: AppSettings = AppSettings(), banner: Banner? = nil, empty: Bool = false,
                      now: Date = Date(), expandFeatured: Bool = false) -> AppStore {
        Format.setDisplayHome(home)
        let store = AppStore(previewSnapshot: empty ? emptySnapshot(now: now) : snapshot(now: now),
                             startupItems: startupItems(),
                             recentlyStopped: empty ? [] : recentlyStopped(now: now),
                             settings: settings,
                             banner: banner)
        if expandFeatured && !empty { store.expandedGroupIDs = [featuredGroupID] }
        return store
    }

    static let respawnBanner = Banner(
        style: .warning,
        message: "notes-api came back — launchd restarts it automatically.",
        action: .disableAutoStart(groupID: "project:" + developer + "/notes-api"),
        actionTitle: "Stop & Disable")

    // MARK: Projects

    /// Monorepo with a Next.js frontend and a FastAPI backend (`uvicorn --reload`), both started by Claude Code.
    private static func acmeShop(_ now: Date) -> ListenerGroup {
        let root = developer + "/acme-shop"
        let origin = LaunchOrigin(kind: .claudeCode, name: "Claude Code")
        let frontend = process(
            pid: 48211, ppid: 48190, comm: "node", uptime: 2 * 3600 + 14 * 60, now: now,
            exe: "/opt/homebrew/bin/node",
            argv: ["node", root + "/frontend/node_modules/.bin/next", "dev", "--port", "3000"],
            cwd: root + "/frontend", ports: [(3000, "127.0.0.1"), (3000, "::1")],
            usage: (2.4, 214_000_000), tree: (3.1, 296_000_000), category: .project,
            project: ProjectInfo(rootPath: root, name: "acme-shop", subpath: "frontend",
                                 markers: [".git", "package.json"]),
            displayName: "next dev", frameworks: ["Next.js"], origin: origin)
        let backend = process(
            pid: 48236, ppid: 48229, comm: "Python", uptime: 2 * 3600 + 13 * 60, now: now,
            exe: root + "/backend/.venv/bin/python3.12",
            argv: [root + "/backend/.venv/bin/python", "-m", "uvicorn", "app.main:app", "--reload", "--port", "8000"],
            cwd: root + "/backend", ports: [(8000, "127.0.0.1")],
            usage: (0.4, 88_000_000), tree: (0.7, 131_000_000), category: .project,
            project: ProjectInfo(rootPath: root, name: "acme-shop", subpath: "backend",
                                 markers: [".git", "pyproject.toml"]),
            displayName: "uvicorn app.main:app", frameworks: ["uvicorn", "FastAPI"], origin: origin,
            manager: .watcher(name: "uvicorn --reload"))
        // `npm run dev` and the uvicorn reloader end with Stop too.
        return ListenerGroup(id: "project:" + root, category: .project, title: "acme-shop",
                             subtitle: "frontend, backend", path: root, processes: [frontend, backend],
                             extraUsage: ResourceUsage(cpuPercent: 0.1, memoryBytes: 74_000_000))
    }

    /// Small API kept alive by a user LaunchAgent: it comes back when stopped, until auto-start is disabled.
    private static func notesAPI(_ now: Date) -> ListenerGroup {
        let root = developer + "/notes-api"
        let job = LaunchdJob(label: "com.example.notes-api", domain: "gui/\(uid)",
                             plistPath: home + "/Library/LaunchAgents/com.example.notes-api.plist",
                             keepAlive: true, runAtLoad: true, pid: 1187)
        let server = process(
            pid: 1187, ppid: 1, comm: "node", uptime: 3 * 86400 + 5 * 3600, now: now,
            exe: "/opt/homebrew/bin/node", argv: ["/opt/homebrew/bin/node", "server.js"],
            cwd: root, ports: [(4000, "127.0.0.1")],
            usage: (0.3, 61_000_000), tree: (0.3, 61_000_000), category: .project,
            project: ProjectInfo(rootPath: root, name: "notes-api", subpath: nil, markers: [".git", "package.json"]),
            displayName: "node server.js", frameworks: ["Express"],
            origin: LaunchOrigin(kind: .launchd, name: "launchd"), manager: .launchd(job))
        return ListenerGroup(id: "project:" + root, category: .project, title: "notes-api",
                             subtitle: "node server.js", path: root, processes: [server])
    }

    private static func blog(_ now: Date) -> ListenerGroup {
        let root = developer + "/blog"
        let server = process(
            pid: 52310, ppid: 52298, comm: "node", uptime: 41 * 60, now: now,
            exe: "/opt/homebrew/bin/node", argv: ["node", root + "/node_modules/.bin/astro", "dev"],
            cwd: root, ports: [(4321, "::1")],
            usage: (0.6, 143_000_000), tree: (0.9, 176_000_000), category: .project,
            project: ProjectInfo(rootPath: root, name: "blog", subpath: nil, markers: [".git", "package.json"]),
            displayName: "astro dev", frameworks: ["Astro"],
            origin: LaunchOrigin(kind: .terminal, name: "Terminal"))
        return ListenerGroup(id: "project:" + root, category: .project, title: "blog",
                             subtitle: "astro dev", path: root, processes: [server],
                             extraUsage: ResourceUsage(cpuPercent: 0, memoryBytes: 38_000_000))
    }

    /// A Gradio demo busy on a model (heavy CPU and memory, open to the network) next to Jupyter.
    private static func mlPlayground(_ now: Date) -> ListenerGroup {
        let root = developer + "/ml-playground"
        let project = ProjectInfo(rootPath: root, name: "ml-playground", subpath: nil,
                                  markers: [".git", "pyproject.toml"])
        let origin = LaunchOrigin(kind: .ide, name: "VS Code")
        let python = root + "/.venv/bin/python3.12"
        let gradio = process(
            pid: 61540, ppid: 61498, comm: "Python", uptime: 18 * 60, now: now,
            exe: python, argv: [root + "/.venv/bin/python", "app.py"],
            cwd: root, ports: [(7860, "*")],
            usage: (164.2, 2_140_000_000), tree: (164.2, 2_140_000_000), category: .project, project: project,
            displayName: "python app.py", frameworks: ["Gradio"], origin: origin)
        let jupyter = process(
            pid: 61022, ppid: 60998, comm: "Python", uptime: 1 * 3600 + 52 * 60, now: now,
            exe: python, argv: [root + "/.venv/bin/python", root + "/.venv/bin/jupyter-lab", "--no-browser"],
            cwd: root, ports: [(8888, "127.0.0.1"), (8888, "::1")],
            usage: (0.5, 118_000_000), tree: (0.8, 164_000_000), category: .project, project: project,
            displayName: "jupyter-lab", frameworks: ["Jupyter"], origin: origin)
        return ListenerGroup(id: "project:" + root, category: .project, title: "ml-playground",
                             subtitle: "python app.py", path: root, processes: [gradio, jupyter])
    }

    // MARK: Services

    private static func postgres(_ now: Date) -> ListenerGroup {
        let job = LaunchdJob(label: "homebrew.mxcl.postgresql@16", domain: "gui/\(uid)",
                             plistPath: home + "/Library/LaunchAgents/homebrew.mxcl.postgresql@16.plist",
                             keepAlive: true, runAtLoad: true, pid: 712)
        let server = process(
            pid: 712, ppid: 1, comm: "postgres", uptime: 6 * 86400 + 2 * 3600, now: now,
            exe: "/opt/homebrew/Cellar/postgresql@16/16.10/bin/postgres",
            argv: ["/opt/homebrew/opt/postgresql@16/bin/postgres", "-D", "/opt/homebrew/var/postgresql@16"],
            cwd: "/opt/homebrew/var/postgresql@16", ports: [(5432, "127.0.0.1"), (5432, "::1")],
            usage: (0.1, 24_000_000), tree: (0.3, 97_000_000), category: .service, project: nil,
            displayName: "postgres", frameworks: ["PostgreSQL"],
            origin: LaunchOrigin(kind: .launchd, name: "launchd"), manager: .launchd(job))
        return ListenerGroup(id: "launchd:homebrew.mxcl.postgresql@16", category: .service, title: "postgresql@16",
                             subtitle: "postgres", path: "/opt/homebrew/var/postgresql@16", processes: [server])
    }

    private static func redis(_ now: Date) -> ListenerGroup {
        let job = LaunchdJob(label: "homebrew.mxcl.redis", domain: "gui/\(uid)",
                             plistPath: home + "/Library/LaunchAgents/homebrew.mxcl.redis.plist",
                             keepAlive: true, runAtLoad: true, pid: 715)
        let server = process(
            pid: 715, ppid: 1, comm: "redis-server", uptime: 6 * 86400 + 2 * 3600, now: now,
            exe: "/opt/homebrew/Cellar/redis/8.2.1/bin/redis-server",
            argv: ["/opt/homebrew/opt/redis/bin/redis-server", "127.0.0.1:6379"],
            cwd: "/opt/homebrew/var", ports: [(6379, "127.0.0.1"), (6379, "::1")],
            usage: (0.2, 9_400_000), tree: (0.2, 9_400_000), category: .service, project: nil,
            displayName: "redis-server", frameworks: ["Redis"],
            origin: LaunchOrigin(kind: .launchd, name: "launchd"), manager: .launchd(job))
        return ListenerGroup(id: "launchd:homebrew.mxcl.redis", category: .service, title: "redis",
                             subtitle: "redis-server", path: "/opt/homebrew/var", processes: [server])
    }

    private static func ollama(_ now: Date) -> ListenerGroup {
        let server = process(
            pid: 30882, ppid: 30851, comm: "ollama", uptime: 5 * 3600 + 32 * 60, now: now,
            exe: "/opt/homebrew/Cellar/ollama/0.12.3/bin/ollama", argv: ["ollama", "serve"],
            cwd: home, ports: [(11434, "127.0.0.1")],
            usage: (0.2, 486_000_000), tree: (0.2, 486_000_000), category: .service, project: nil,
            displayName: "ollama serve", frameworks: ["Ollama"],
            origin: LaunchOrigin(kind: .terminal, name: "Terminal"))
        return ListenerGroup(id: "pid:" + server.basic.identity.description, category: .service,
                             title: "ollama serve", subtitle: nil, path: home, processes: [server])
    }

    private static func cloudflared(_ now: Date) -> ListenerGroup {
        let server = process(
            pid: 33410, ppid: 33377, comm: "cloudflared", uptime: 47 * 60, now: now,
            exe: "/opt/homebrew/Cellar/cloudflared/2025.9.1/bin/cloudflared",
            argv: ["cloudflared", "tunnel", "--metrics", "127.0.0.1:20241", "run", "acme-preview"],
            cwd: "/", ports: [(20241, "127.0.0.1")],
            usage: (0.6, 31_000_000), tree: (0.6, 31_000_000), category: .service, project: nil,
            displayName: "cloudflared tunnel run", frameworks: ["cloudflared"],
            origin: LaunchOrigin(kind: .terminal, name: "Terminal"))
        return ListenerGroup(id: "pid:" + server.basic.identity.description, category: .service,
                             title: "cloudflared", subtitle: "tunnel run acme-preview", path: nil, processes: [server])
    }

    // MARK: Apps & system

    private static func vsCode(_ now: Date) -> ListenerGroup {
        let bundle = "/Applications/Visual Studio Code.app"
        let helper = bundle + "/Contents/Frameworks/Code Helper (Plugin).app/Contents/MacOS/Code Helper (Plugin)"
        let extensionHost = process(
            pid: 2290, ppid: 2101, comm: "Code Helper (Pl", uptime: 26 * 3600, now: now,
            exe: helper, argv: [helper, "--type=utility", "--utility-sub-type=node.mojom.NodeService"],
            cwd: "/", ports: [(64815, "127.0.0.1"), (64817, "127.0.0.1"), (64819, "127.0.0.1")],
            usage: (3.1, 412_000_000), tree: (4.4, 690_000_000), category: .app, project: nil,
            displayName: "Code Helper (Plugin)", frameworks: [], origin: LaunchOrigin(kind: .app, name: "VS Code"),
            appName: "Visual Studio Code")
        let languageServer = process(
            pid: 2344, ppid: 2290, comm: "Code Helper (Pl", uptime: 26 * 3600, now: now,
            exe: helper, argv: [helper, "--type=utility", "tsserver.js"],
            cwd: "/", ports: [(52368, "127.0.0.1")],
            usage: (0.8, 210_000_000), tree: (0.8, 210_000_000), category: .app, project: nil,
            displayName: "Code Helper (Plugin)", frameworks: [], origin: LaunchOrigin(kind: .app, name: "VS Code"),
            appName: "Visual Studio Code")
        return ListenerGroup(id: "app:" + bundle, category: .app, title: "Visual Studio Code", subtitle: nil,
                             path: bundle, processes: [languageServer, extensionHost])
    }

    private static func spotify(_ now: Date) -> ListenerGroup {
        let bundle = "/Applications/Spotify.app"
        let exe = bundle + "/Contents/MacOS/Spotify"
        let app = process(
            pid: 1650, ppid: 1, comm: "Spotify", uptime: 2 * 86400 + 3 * 3600, now: now,
            exe: exe, argv: [exe], cwd: "/", ports: [(7768, "127.0.0.1"), (57621, "*")],
            usage: (1.2, 324_000_000), tree: (2.0, 512_000_000), category: .app, project: nil,
            displayName: "Spotify", frameworks: [], origin: LaunchOrigin(kind: .app, name: "Spotify"),
            appName: "Spotify")
        return ListenerGroup(id: "app:" + bundle, category: .app, title: "Spotify", subtitle: nil,
                             path: bundle, processes: [app])
    }

    private static func rapportd(_ now: Date) -> ListenerGroup {
        let process = process(
            pid: 612, ppid: 1, comm: "rapportd", uptime: 6 * 86400 + 2 * 3600, now: now,
            exe: "/usr/libexec/rapportd", argv: ["/usr/libexec/rapportd"], cwd: "/",
            ports: [(49152, "*")], usage: (0.0, 7_800_000), tree: (0.0, 7_800_000),
            category: .system, project: nil, displayName: "rapportd", frameworks: [], origin: nil)
        return ListenerGroup(id: "pid:" + process.basic.identity.description, category: .system, title: "rapportd",
                             subtitle: "Continuity", path: nil, processes: [process])
    }

    // MARK: Builder

    private static func process(pid: Int32, ppid: Int32, comm: String, uptime: TimeInterval, now: Date,
                                exe: String, argv: [String], cwd: String, ports: [(UInt16, String)],
                                usage: (Double, UInt64), tree: (Double, UInt64), category: ListenerCategory,
                                project: ProjectInfo?, displayName: String, frameworks: [String],
                                origin: LaunchOrigin?, manager: ProcessManager = .none,
                                appName: String? = nil) -> ListenerProcess {
        let start = UInt64(max(0, now.timeIntervalSince1970 - uptime) * 1_000_000)
        let basic = ProcessBasic(pid: pid, ppid: ppid, pgid: ppid > 1 ? ppid : pid, uid: uid, comm: comm, startTime: start)
        let details = ProcessDetails(identity: basic.identity, executablePath: exe, arguments: argv,
                                     environment: [:], cwd: cwd)
        let sockets = ports.map { port, address in
            ListeningSocket(port: port, address: address, family: address.contains(":") ? .ipv6 : .ipv4, pid: pid)
        }
        return ListenerProcess(basic: basic, details: details, sockets: sockets,
                               usage: ResourceUsage(cpuPercent: usage.0, memoryBytes: usage.1),
                               treeUsage: ResourceUsage(cpuPercent: tree.0, memoryBytes: tree.1),
                               category: category, project: project, displayName: displayName,
                               frameworks: frameworks, origin: origin, manager: manager, appName: appName,
                               isRestricted: false)
    }
}

#if DEBUG
struct PanelView_Previews: PreviewProvider {
    static var previews: some View {
        Group {
            PanelView(store: PreviewData.store(expandFeatured: true), snapshotMode: true)
                .previewDisplayName("Panel")
            PanelView(store: PreviewData.store(banner: PreviewData.respawnBanner), snapshotMode: true)
                .preferredColorScheme(.dark)
                .previewDisplayName("Panel · dark · banner")
            PanelView(store: PreviewData.store(empty: true), snapshotMode: true)
                .previewDisplayName("Empty")
            PanelView(store: PreviewData.store(), snapshotMode: true, initiallyShowingSettings: true)
                .previewDisplayName("Settings")
        }
    }
}
#endif
