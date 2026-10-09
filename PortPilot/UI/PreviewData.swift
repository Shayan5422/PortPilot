import Foundation
import SwiftUI

/// Realistic sample data (modelled on a typical day on Shayan's Mac) for SwiftUI previews, snapshot checks
/// and UI tests. Pure values — nothing here touches the system.
enum PreviewData {
    static let uid: UInt32 = 501
    static var home: String { NSHomeDirectory() }

    // MARK: Snapshot

    static func snapshot(now: Date = Date()) -> ScanSnapshot {
        let groups = [
            institutDeMai(now), claudeMonitor(now), idmPublicDeployment(now), cliquetteBackend(now), randomTool(now),
            postgres(now), redis(now), cloudflared(now),
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
            StartupItem(label: "com.shayan.claude-monitor", plistPath: agents + "/com.shayan.claude-monitor.plist",
                        command: "/opt/homebrew/bin/node server.js",
                        workingDirectory: home + "/Downloads/NODES/claude-monitor",
                        runAtLoad: true, keepAlive: true, isDisabled: false, isLoaded: true,
                        pid: 1187, lastExitStatus: 0, ports: [4180]),
            StartupItem(label: "com.shayan.idm-public-deployment",
                        plistPath: agents + "/com.shayan.idm-public-deployment.plist",
                        command: "/bin/bash scripts/serve-public.sh",
                        workingDirectory: home + "/Downloads/NODES/idm-public-deployment",
                        runAtLoad: true, keepAlive: true, isDisabled: false, isLoaded: true,
                        pid: 1203, lastExitStatus: 0, ports: [4173, 8000]),
            StartupItem(label: "homebrew.mxcl.postgresql@16", plistPath: agents + "/homebrew.mxcl.postgresql@16.plist",
                        command: "/opt/homebrew/opt/postgresql@16/bin/postgres -D /opt/homebrew/var/postgresql@16",
                        workingDirectory: "/opt/homebrew", runAtLoad: true, keepAlive: true, isDisabled: false,
                        isLoaded: true, pid: 712, lastExitStatus: 0, ports: [5433]),
            StartupItem(label: "homebrew.mxcl.redis", plistPath: agents + "/homebrew.mxcl.redis.plist",
                        command: "/opt/homebrew/opt/redis/bin/redis-server /opt/homebrew/etc/redis.conf",
                        workingDirectory: "/opt/homebrew/var", runAtLoad: true, keepAlive: true, isDisabled: false,
                        isLoaded: true, pid: 715, lastExitStatus: 0, ports: [6379]),
            StartupItem(label: "com.shayan.cliquette-sync", plistPath: agents + "/com.shayan.cliquette-sync.plist",
                        command: "/usr/bin/python3 sync.py --every 15m",
                        workingDirectory: home + "/Downloads/NODES/cliquette-backend",
                        runAtLoad: true, keepAlive: false, isDisabled: false, isLoaded: true,
                        pid: nil, lastExitStatus: 1, ports: []),
            StartupItem(label: "com.google.keystone.agent", plistPath: agents + "/com.google.keystone.agent.plist",
                        command: home + "/Library/Google/GoogleSoftwareUpdate/GoogleSoftwareUpdate.bundle/Contents/Resources/"
                            + "GoogleSoftwareUpdateAgent.app/Contents/MacOS/GoogleSoftwareUpdateAgent -runMode ifneeded",
                        workingDirectory: nil, runAtLoad: true, keepAlive: false, isDisabled: false, isLoaded: true,
                        pid: nil, lastExitStatus: 0, ports: []),
            StartupItem(label: "com.shayan.random-tool", plistPath: agents + "/com.shayan.random-tool.plist",
                        command: home + "/.bun/bin/bun run start",
                        workingDirectory: home + "/Downloads/NODES/random-tool",
                        runAtLoad: true, keepAlive: true, isDisabled: true, isLoaded: false,
                        pid: nil, lastExitStatus: nil, ports: []),
        ]
    }

    static func recentlyStopped(now: Date = Date()) -> [StoppedRecord] {
        [
            StoppedRecord(id: UUID(), date: now.addingTimeInterval(-4 * 60), title: "vite-playground",
                          ports: [5174], cwd: home + "/Downloads/NODES/vite-playground",
                          arguments: ["/opt/homebrew/bin/node", "node_modules/.bin/vite", "--port", "5174"],
                          environment: ["PATH": "/opt/homebrew/bin:/usr/bin:/bin"],
                          executablePath: "/opt/homebrew/bin/node", manager: .none),
            StoppedRecord(id: UUID(), date: now.addingTimeInterval(-38 * 60), title: "idm-worker",
                          ports: [8020], cwd: home + "/Downloads/NODES/idm-public-deployment",
                          arguments: ["/opt/homebrew/bin/python3", "-m", "worker", "--port", "8020"],
                          environment: [:], executablePath: "/opt/homebrew/bin/python3",
                          manager: .launchd(LaunchdJob(label: "com.shayan.idm-worker", domain: "gui/\(uid)",
                                                       plistPath: nil, keepAlive: true, runAtLoad: true, pid: nil))),
        ]
    }

    @MainActor
    static func store(settings: AppSettings = AppSettings(), banner: Banner? = nil, empty: Bool = false,
                      now: Date = Date()) -> AppStore {
        AppStore(previewSnapshot: empty ? emptySnapshot(now: now) : snapshot(now: now),
                 startupItems: startupItems(),
                 recentlyStopped: empty ? [] : recentlyStopped(now: now),
                 settings: settings,
                 banner: banner)
    }

    static let respawnBanner = Banner(
        style: .warning,
        message: "claude-monitor came back — launchd restarts it automatically.",
        action: .disableAutoStart(groupID: "project:" + NSHomeDirectory() + "/Downloads/NODES/claude-monitor"),
        actionTitle: "Stop & Disable")

    // MARK: Projects

    private static func institutDeMai(_ now: Date) -> ListenerGroup {
        let root = home + "/Downloads/NODES/Institut de mai"
        let origin = LaunchOrigin(kind: .claudeCode, name: "Claude Code")
        let frontend = process(
            pid: 48211, ppid: 48190, comm: "node", uptime: 2 * 3600 + 14 * 60, now: now,
            exe: "/opt/homebrew/bin/node",
            argv: ["node", root + "/frontend/node_modules/.bin/vite", "--port", "5330", "--strictPort"],
            cwd: root + "/frontend", ports: [(5330, "127.0.0.1")],
            usage: (1.6, 168_000_000), tree: (2.1, 231_000_000), category: .project,
            project: ProjectInfo(rootPath: root, name: "Institut de mai", subpath: "frontend",
                                 markers: [".git", "package.json"]),
            displayName: "vite", frameworks: ["Vite"], origin: origin)
        let backend = process(
            pid: 48236, ppid: 48229, comm: "Python", uptime: 2 * 3600 + 13 * 60, now: now,
            exe: root + "/backend/.venv/bin/python3.12",
            argv: [root + "/backend/.venv/bin/python", "-m", "uvicorn", "app.main:app", "--reload", "--port", "8014"],
            cwd: root + "/backend", ports: [(8014, "127.0.0.1")],
            usage: (0.4, 88_000_000), tree: (0.7, 131_000_000), category: .project,
            project: ProjectInfo(rootPath: root, name: "Institut de mai", subpath: "backend",
                                 markers: [".git", "pyproject.toml"]),
            displayName: "uvicorn app.main:app", frameworks: ["uvicorn", "FastAPI"], origin: origin,
            manager: .watcher(name: "uvicorn --reload"))
        return ListenerGroup(id: "project:" + root, category: .project, title: "Institut de mai", subtitle: nil,
                             path: root, processes: [frontend, backend])
    }

    private static func claudeMonitor(_ now: Date) -> ListenerGroup {
        let root = home + "/Downloads/NODES/claude-monitor"
        let job = LaunchdJob(label: "com.shayan.claude-monitor", domain: "gui/\(uid)",
                             plistPath: home + "/Library/LaunchAgents/com.shayan.claude-monitor.plist",
                             keepAlive: true, runAtLoad: true, pid: 1187)
        let server = process(
            pid: 1187, ppid: 1, comm: "node", uptime: 3 * 86400 + 5 * 3600, now: now,
            exe: "/opt/homebrew/bin/node", argv: ["/opt/homebrew/bin/node", "server.js"],
            cwd: root, ports: [(4180, "127.0.0.1")],
            usage: (0.3, 61_000_000), tree: (0.3, 61_000_000), category: .project,
            project: ProjectInfo(rootPath: root, name: "claude-monitor", subpath: nil, markers: [".git", "package.json"]),
            displayName: "node server.js", frameworks: ["Express"],
            origin: LaunchOrigin(kind: .launchd, name: "launchd"), manager: .launchd(job))
        return ListenerGroup(id: "project:" + root, category: .project, title: "claude-monitor",
                             subtitle: "node server.js", path: root, processes: [server])
    }

    private static func idmPublicDeployment(_ now: Date) -> ListenerGroup {
        let root = home + "/Downloads/NODES/idm-public-deployment"
        let job = LaunchdJob(label: "com.shayan.idm-public-deployment", domain: "gui/\(uid)",
                             plistPath: home + "/Library/LaunchAgents/com.shayan.idm-public-deployment.plist",
                             keepAlive: true, runAtLoad: true, pid: 1203)
        let project = ProjectInfo(rootPath: root, name: "idm-public-deployment", subpath: nil,
                                  markers: [".git", "requirements.txt"])
        let nginx = process(
            pid: 1251, ppid: 1203, comm: "nginx", uptime: 3 * 86400 + 5 * 3600, now: now,
            exe: "/opt/homebrew/Cellar/nginx/1.27.2/bin/nginx",
            argv: ["nginx: master process /opt/homebrew/opt/nginx/bin/nginx", "-c", root + "/deploy/nginx.conf"],
            cwd: root, ports: [(4173, "*")],
            usage: (0.0, 6_000_000), tree: (0.1, 14_000_000), category: .project, project: project,
            displayName: "nginx", frameworks: ["nginx"],
            origin: LaunchOrigin(kind: .launchd, name: "launchd"), manager: .launchd(job))
        let api = process(
            pid: 1244, ppid: 1203, comm: "Python", uptime: 3 * 86400 + 5 * 3600, now: now,
            exe: root + "/.venv/bin/python3.12",
            argv: [root + "/.venv/bin/python", "-m", "uvicorn", "server:app", "--host", "127.0.0.1", "--port", "8000"],
            cwd: root, ports: [(8000, "127.0.0.1")],
            usage: (0.5, 112_000_000), tree: (0.5, 112_000_000), category: .project, project: project,
            displayName: "uvicorn server:app", frameworks: ["uvicorn"],
            origin: LaunchOrigin(kind: .launchd, name: "launchd"), manager: .launchd(job))
        return ListenerGroup(id: "project:" + root, category: .project, title: "idm-public-deployment",
                             subtitle: nil, path: root, processes: [nginx, api])
    }

    private static func cliquetteBackend(_ now: Date) -> ListenerGroup {
        let root = home + "/Downloads/NODES/cliquette-backend"
        let app = process(
            pid: 61022, ppid: 60998, comm: "Python", uptime: 47 * 60, now: now,
            exe: "/opt/homebrew/Cellar/python@3.12/3.12.7/Frameworks/Python.framework/Versions/3.12/bin/python3.12",
            argv: ["python", "app.py"], cwd: root, ports: [(8777, "*")],
            usage: (96.4, 1_120_000_000), tree: (96.4, 1_120_000_000), category: .project,
            project: ProjectInfo(rootPath: root, name: "cliquette-backend", subpath: nil,
                                 markers: [".git", "requirements.txt"]),
            displayName: "python app.py", frameworks: ["Flask"],
            origin: LaunchOrigin(kind: .terminal, name: "Terminal"))
        return ListenerGroup(id: "project:" + root, category: .project, title: "cliquette-backend",
                             subtitle: "python app.py", path: root, processes: [app])
    }

    private static func randomTool(_ now: Date) -> ListenerGroup {
        let root = home + "/Downloads/NODES/random-tool"
        let server = process(
            pid: 70415, ppid: 70402, comm: "bun", uptime: 9 * 60, now: now,
            exe: home + "/.bun/bin/bun", argv: ["bun", "run", "src/index.ts"],
            cwd: root, ports: [(53012, "127.0.0.1")],
            usage: (0.2, 42_000_000), tree: (0.2, 42_000_000), category: .project,
            project: ProjectInfo(rootPath: root, name: "random-tool", subpath: nil, markers: ["package.json", "bun.lockb"]),
            displayName: "bun src/index.ts", frameworks: ["Bun"],
            origin: LaunchOrigin(kind: .claudeCode, name: "Claude Code"))
        return ListenerGroup(id: "project:" + root, category: .project, title: "random-tool",
                             subtitle: "bun src/index.ts", path: root, processes: [server])
    }

    // MARK: Services

    private static func postgres(_ now: Date) -> ListenerGroup {
        let job = LaunchdJob(label: "homebrew.mxcl.postgresql@16", domain: "gui/\(uid)",
                             plistPath: home + "/Library/LaunchAgents/homebrew.mxcl.postgresql@16.plist",
                             keepAlive: true, runAtLoad: true, pid: 712)
        let server = process(
            pid: 712, ppid: 1, comm: "postgres", uptime: 6 * 86400 + 2 * 3600, now: now,
            exe: "/opt/homebrew/Cellar/postgresql@16/16.4/bin/postgres",
            argv: ["/opt/homebrew/opt/postgresql@16/bin/postgres", "-D", "/opt/homebrew/var/postgresql@16", "-p", "5433"],
            cwd: "/opt/homebrew/var/postgresql@16", ports: [(5433, "127.0.0.1"), (5433, "::1")],
            usage: (0.1, 24_000_000), tree: (0.3, 97_000_000), category: .service, project: nil,
            displayName: "postgres", frameworks: ["PostgreSQL"],
            origin: LaunchOrigin(kind: .launchd, name: "launchd"), manager: .launchd(job))
        return ListenerGroup(id: "launchd:homebrew.mxcl.postgresql@16", category: .service, title: "postgres",
                             subtitle: "postgresql@16", path: "/opt/homebrew/var/postgresql@16", processes: [server])
    }

    private static func redis(_ now: Date) -> ListenerGroup {
        let job = LaunchdJob(label: "homebrew.mxcl.redis", domain: "gui/\(uid)",
                             plistPath: home + "/Library/LaunchAgents/homebrew.mxcl.redis.plist",
                             keepAlive: true, runAtLoad: true, pid: 715)
        let server = process(
            pid: 715, ppid: 1, comm: "redis-server", uptime: 6 * 86400 + 2 * 3600, now: now,
            exe: "/opt/homebrew/Cellar/redis/7.4.1/bin/redis-server",
            argv: ["/opt/homebrew/opt/redis/bin/redis-server", "127.0.0.1:6379"],
            cwd: "/opt/homebrew/var", ports: [(6379, "127.0.0.1"), (6379, "::1")],
            usage: (0.2, 9_400_000), tree: (0.2, 9_400_000), category: .service, project: nil,
            displayName: "redis-server", frameworks: ["Redis"],
            origin: LaunchOrigin(kind: .launchd, name: "launchd"), manager: .launchd(job))
        return ListenerGroup(id: "launchd:homebrew.mxcl.redis", category: .service, title: "redis",
                             subtitle: "redis-server", path: "/opt/homebrew/var", processes: [server])
    }

    private static func cloudflared(_ now: Date) -> ListenerGroup {
        let server = process(
            pid: 33410, ppid: 33377, comm: "cloudflared", uptime: 5 * 3600 + 32 * 60, now: now,
            exe: "/opt/homebrew/Cellar/cloudflared/2024.10.1/bin/cloudflared",
            argv: ["cloudflared", "tunnel", "--metrics", "127.0.0.1:20241", "run", "idm-public"],
            cwd: home, ports: [(20241, "127.0.0.1"), (20242, "127.0.0.1")],
            usage: (0.6, 31_000_000), tree: (0.6, 31_000_000), category: .service, project: nil,
            displayName: "cloudflared tunnel run", frameworks: ["cloudflared"],
            origin: LaunchOrigin(kind: .terminal, name: "Terminal"))
        return ListenerGroup(id: "pid:" + server.basic.identity.description, category: .service,
                             title: "cloudflared", subtitle: "tunnel run idm-public", path: nil, processes: [server])
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
            PanelView(store: PreviewData.store(), snapshotMode: true)
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
