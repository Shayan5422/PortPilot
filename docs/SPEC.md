# PortPilot — implementation spec

Native macOS menu bar app (Swift 5 language mode, SwiftUI + AppKit, macOS 14+, NOT sandboxed, ad-hoc signed).
Built with XcodeGen (`project.yml`) + `xcodebuild`. Single app module — use `internal` (default) access, no `public`.

## The user's problem (verbatim intent)

> "I build lots of tools and they keep landing on random ports (53000, 52000, 32000, 40000, 30000…), eat RAM/CPU,
> slow my Mac, and I often can't tell whether a tool closed or is still running. I want an app that starts
> automatically (and comes back after restarts), sits in the macOS menu bar next to Wi-Fi, checks every few
> seconds which ports are open/occupied, shows which project/folder each one comes from, and lets me close the
> ones I made with one click — even the ones that are set to auto-start (I must be able to cancel those too)."

Interface language: **English**.

## Architecture

```
PortPilot/
  App/      PortPilotApp.swift (entry, MenuBarExtra), AppStore.swift (state + actions, @Observable @MainActor),
            CommandLineMode.swift (--dump / --snapshot headless modes)
  Core/     Models.swift (SHARED CONTRACT — do not edit without being asked), SysProc.swift, ProcessScanner.swift,
            ProjectResolver.swift, Classifier.swift, ListenerBuilder.swift
  Control/  Shell.swift, LaunchdService.swift, PM2Service.swift, DockerService.swift, KillPlanner.swift,
            ProcessKiller.swift, Relauncher.swift, LoginItemManager.swift, Notifier.swift
  UI/       PanelView.swift, GroupRow.swift, ProcessRow.swift, StartupItemsView.swift, RecentlyStoppedView.swift,
            SettingsView.swift, MenuBarLabel.swift, Components.swift, SnapshotRenderer.swift
  Resources/ Info.plist, Assets.xcassets (AppIcon)
PortPilotTests/  XCTest unit tests for pure logic (resolver, classifier, kill planner, parsers)
scripts/   build.sh, install.sh, uninstall.sh, make-icon.swift
```

Data flow per tick (default every 3 s, 1 s minimum; when the panel is closed scans still run at the
configured interval so the menu bar count stays live):

1. `ProcessScanner.scan()` → `RawScan` (process table via one `sysctl(KERN_PROC_ALL)`, listening TCP sockets via
   libproc for every same-uid process; optionally `netstat -anv -p tcp` for other-uid listeners when System is shown).
2. For each listener pid: `ProcessDetails` (cached per `ProcessIdentity`), resource usage (stateful CPU% delta).
3. `ListenerBuilder.build(...)` → `[ListenerGroup]` using `ProjectResolver`, `Classifier`, launchd/pm2/docker maps.
4. `AppStore` publishes the snapshot on the main actor; UI renders.

Performance budget: a scan must cost < 15 ms CPU on a machine with ~800 processes. Never spawn a subprocess
per process. Subprocesses allowed per tick: at most `launchctl list` (and only when some listener has ppid 1 or
an ancestor that is launchd; cache ≥ 10 s otherwise), `pm2 jlist` only when a PM2 God Daemon is in the table,
`docker ps` only when a Docker backend process owns a listener. Heavy work happens off the main thread.

**NEVER** run `pm2` commands unless a PM2 daemon process ("PM2 v… God Daemon") is already in the process table —
`pm2 jlist` spawns a daemon if none is running.

## Core contracts (exact signatures — other modules call these)

### Core/SysProc.swift — thin, safe wrappers over libproc/sysctl (owner: ENGINE)

```swift
enum SysProc {
    /// All processes via sysctl(CTL_KERN, KERN_PROC, KERN_PROC_ALL). Retries on ENOMEM with a bigger buffer.
    static func allProcesses() -> [ProcessBasic]
    /// Single process via sysctl(KERN_PROC_PID); nil if gone.
    static func basic(pid: Int32) -> ProcessBasic?
    /// proc_pidpath.
    static func executablePath(pid: Int32) -> String?
    /// KERN_PROCARGS2 parse → (argv, env). nil when not permitted / gone. Handles the exec-path + NUL padding layout.
    static func argumentsAndEnvironment(pid: Int32) -> (arguments: [String], environment: [String: String])?
    /// PROC_PIDVNODEPATHINFO → pvi_cdir path.
    static func currentDirectory(pid: Int32) -> String?
    /// PROC_PIDLISTFDS + PROC_PIDFDSOCKETINFO; returns TCP sockets in LISTEN state (TSI_S_LISTEN).
    /// nil when the process can't be inspected (EPERM/ESRCH), [] when it has none.
    static func listeningTCPSockets(pid: Int32) -> [ListeningSocket]?
    /// proc_pid_rusage(RUSAGE_INFO_V4): total CPU time in nanoseconds (user+system converted with
    /// mach_timebase_info) and ri_phys_footprint.
    static func resourceSample(pid: Int32) -> (cpuNanos: UInt64, footprintBytes: UInt64)?
    /// Full ProcessDetails (path + args/env + cwd) for one process; nil if gone.
    static func details(for basic: ProcessBasic) -> ProcessDetails?
    static var currentUID: UInt32 { get }
}
```

### Core/ProcessScanner.swift (owner: ENGINE)

```swift
struct RawScan {
    let table: ProcessTable
    /// pid → listening sockets (deduped by port+address+family).
    let socketsByPID: [Int32: [ListeningSocket]]
    /// Other-user listener pids discovered through netstat (no details available).
    let restrictedPIDs: Set<Int32>
}

final class ProcessScanner {   // used from ONE background serial context at a time; internal lock for safety
    init()
    func scan(includeOtherUsers: Bool) -> RawScan
    /// Cached by ProcessIdentity; cache entries for dead identities are pruned on each scan.
    func details(for basic: ProcessBasic) -> ProcessDetails?
    /// CPU% since the previous sample of the same identity (0 on first sample) + footprint.
    func usage(for basics: [ProcessBasic]) -> [Int32: ResourceUsage]
}
```

### Core/ProjectResolver.swift (owner: RESOLVER)

```swift
final class ProjectResolver {   // thread-safe (NSLock), caches directory lookups for 60 s
    init(homeDirectory: String = NSHomeDirectory(), fileExists: ((String) -> Bool)? = nil, readFile: ((String) -> Data?)? = nil)
    /// Determines the project for a process. Order: cwd (if not "/" and not inside an .app bundle or
    /// a system dir) → script path inferred from argv (first existing absolute file arg; strip at
    /// node_modules/.venv/venv/site-packages/.bin) → executable path if it lives in a project
    /// (e.g. ~/code/foo/target/debug/server). Returns nil for things outside $HOME (except /opt, /srv, /var/www style
    /// code dirs that have markers) and for $HOME itself / ~/Downloads / ~/Desktop / ~/Documents roots.
    func resolve(details: ProcessDetails?) -> ProjectInfo?
    /// Walks up from `directory` (stops at $HOME or "/"): rootPath = nearest ancestor with `.git`
    /// (dir or file), else the outermost ancestor with a manifest that is still a direct code root,
    /// else `directory`. `subpath` = nearest manifest dir relative to rootPath (nil when same).
    func project(forDirectory directory: String) -> ProjectInfo?
    static let manifestFiles: [String]  // package.json, pyproject.toml, requirements.txt, Pipfile, Cargo.toml, go.mod,
                                        // Gemfile, composer.json, pom.xml, build.gradle(.kts), deno.json(c), bun.lockb,
                                        // Package.swift, mix.exs, manage.py, setup.py, Makefile, docker-compose.yml, ...
}
```
Name rule: prefer `name` from package.json / pyproject.toml ([project] or [tool.poetry]) / Cargo.toml ([package])
at the ROOT; if it is missing, generic ("app", "backend", "frontend", "server", "web", "api", "client") or a scoped
`@org/x` keep folder name of the root. Never block on huge files: read at most 256 KB.

### Core/Classifier.swift (owner: RESOLVER)

```swift
enum Classifier {
    /// .system: other uid, or executable under /System, /usr/libexec, /usr/sbin, /sbin, /usr/bin (except dev
    ///          runtimes), /Library/Apple, or an Apple bundle id app (ControlCenter, rapportd, sharingd...).
    /// .app:    executable inside a *.app bundle that is not a dev runtime and has no project
    ///          (VS Code helpers, Spotify, Antigravity language_server...).
    /// .project: has a ProjectInfo.
    /// .service: everything else owned by the user (Homebrew postgres/redis, tunnels, launchd agents).
    static func category(basic: ProcessBasic, details: ProcessDetails?, project: ProjectInfo?,
                         manager: ProcessManager, currentUID: UInt32) -> ListenerCategory
    /// Outermost ".app" bundle in the path → its CFBundleName/CFBundleDisplayName (read Info.plist, cached) or folder name sans ".app".
    static func appBundle(forExecutable path: String) -> (name: String, bundlePath: String)?
    /// Framework/tool hints from argv/exe: Vite, Next.js, Nuxt, Astro, Remix, SvelteKit, Webpack, Parcel, Storybook,
    /// Expo, Metro, Angular, Express(?), NestJS, uvicorn, gunicorn, FastAPI(uvicorn), Flask, Django, Streamlit,
    /// Gradio, Jupyter, http.server, Rails, Puma, PHP, Laravel, Hugo, Jekyll, nginx, Caddy, PostgreSQL, Redis,
    /// MySQL, MongoDB, Ollama, cloudflared, ngrok, Bun, Deno, Go, Rust/cargo, Java/Spring, .NET.
    static func frameworks(details: ProcessDetails?, comm: String) -> [String]
    /// Short row label: e.g. "vite", "next dev", "uvicorn app.main:app", "python app.py", "postgres", "node server.js".
    static func displayName(basic: ProcessBasic, details: ProcessDetails?) -> String
    /// Who started this tree — uses env (CLAUDECODE=1 / CLAUDE_CODE_*, CODEX_*/codex, TERM_PROGRAM, __CFBundleIdentifier,
    /// VSCODE_*, CURSOR_*, TMUX) and ancestor names/paths (claude, codex, Terminal, iTerm2, Warp, Ghostty, kitty,
    /// WezTerm, Alacritty, Code Helper, Cursor, Zed, Xcode, tmux, PM2, launchd).
    static func origin(details: ProcessDetails?, ancestors: [ProcessBasic],
                       ancestorDetails: (Int32) -> ProcessDetails?, launchdLabel: String?) -> LaunchOrigin?
    /// Watcher/supervisor detection among ancestors+self: nodemon, tsx watch, ts-node-dev, node --watch,
    /// uvicorn/flask/django autoreloader parent, watchfiles, cargo-watch, air, reflex, entr, concurrently, turbo.
    static func watcherName(for basic: ProcessBasic, details: ProcessDetails?, ancestors: [ProcessBasic],
                            ancestorDetails: (Int32) -> ProcessDetails?) -> String?
    /// Runtimes that make something a "dev" thing even when inside /usr/bin or an .app (node, python, bun, deno,
    /// ruby, php, java, go, dotnet, beam.smp, perl, deno...).
    static func isDevRuntime(name: String) -> Bool
    /// Interactive/terminal/IDE/agent processes that must NEVER be killed as part of a kill plan.
    static func isBoundaryProcess(basic: ProcessBasic, details: ProcessDetails?) -> Bool
    /// npm, npx, pnpm, yarn, bun (run/x), deno task, node running npm-cli/yarn/pnpm/nodemon/concurrently/turbo/vite?,
    /// nodemon, concurrently, turbo, nx, tsx, ts-node-dev, make, just, foreman, overmind, honcho, poetry run, uv run,
    /// pipenv run, cargo run/watch, go run, air, mix, rails, bundle exec ...
    static func isRunnerProcess(basic: ProcessBasic, details: ProcessDetails?) -> Bool
}
```

### Core/ListenerBuilder.swift (owner: RESOLVER)

```swift
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

enum ListenerBuilder {
    /// Builds ListenerProcess values and groups them.
    /// Grouping: by project rootPath ("project:<root>"); else by launchd label ("launchd:<label>"); else by app bundle
    /// ("app:<bundlePath>"); else by kill-plan root pid ("pid:<identity>"). Groups sorted per settings.sortOrder later
    /// by AppStore. Processes inside a group sorted by first port.
    /// Manager resolution: walk self+ancestors; first ancestor-or-self pid in launchdLabelsByPID with a non
    /// "application." label → .launchd(job); pm2ByPID hit → .pm2; docker backend process with port in dockerByPort → .docker;
    /// watcher → .watcher(name); else .none.
    static func build(raw: RawScan, details: (ProcessBasic) -> ProcessDetails?, usage: [Int32: ResourceUsage],
                      resolver: ProjectResolver, maps: ManagerMaps, currentUID: UInt32) -> [ListenerGroup]
}
```
`treeUsage` = usage of the process + all descendants present in `usage` (the caller passes usage for listeners
AND their descendants).

## Control contracts (owner: CONTROL)

### Control/Shell.swift
```swift
struct ShellResult { let status: Int32; let stdout: String; let stderr: String; var ok: Bool { status == 0 } }
enum Shell {
    /// Runs an executable directly (no shell), with timeout (kills the child on timeout → status -1). Never blocks main
    /// thread for long: callers call it from background. Reads pipes concurrently to avoid deadlock on large output.
    static func run(_ executable: String, _ arguments: [String], timeout: TimeInterval = 10,
                    environment: [String: String]? = nil, currentDirectory: String? = nil) -> ShellResult
    /// PATH used for tool lookup: user's login-shell PATH (captured once via `/bin/zsh -l -c 'printf %s "$PATH"'`,
    /// 3 s timeout, cached) + /opt/homebrew/bin, /usr/local/bin, ~/.bun/bin, ~/.local/bin, ~/.cargo/bin, ~/.deno/bin.
    static var toolPATH: String { get }
    /// Finds an executable on toolPATH. Cached.
    static func which(_ tool: String) -> String?
    /// Runs a tool found via which() with environment PATH=toolPATH (+ HOME). Returns status 127 if not found.
    static func runTool(_ tool: String, _ arguments: [String], timeout: TimeInterval = 15) -> ShellResult
    /// Runs `/usr/bin/osascript -e 'do shell script "<cmd>" with administrator privileges'` (escaped safely).
    static func runAsAdmin(_ command: String) -> ShellResult
}
```

### Control/LaunchdService.swift
```swift
final class LaunchdService {
    init(uid: UInt32 = getuid())
    var guiDomain: String { "gui/\(uid)" }
    /// `launchctl list` → pid → label for running jobs (skips "-" pids). Includes "application.*" labels (callers filter).
    func runningJobLabels() -> [Int32: String]
    /// Job info for a label: plist path (search ~/Library/LaunchAgents, /Library/LaunchAgents, /Library/LaunchDaemons
    /// by Label key — cached index of plists, refreshed at most every 30 s), keepAlive/runAtLoad from the plist
    /// (KeepAlive may be bool or dict → true), pid. Falls back to `launchctl print gui/<uid>/<label>` "path = ".
    func job(label: String, pid: Int32?) -> LaunchdJob?
    /// Non-Apple user agents: every plist in ~/Library/LaunchAgents (+ /Library/LaunchAgents read-only), merged with
    /// `launchctl print-disabled gui/<uid>` and `launchctl list` (pid/last exit). Skips "com.apple." labels.
    func startupItems() -> [StartupItem]
    /// launchctl bootout gui/<uid>/<label> (stops now; returns at next login if RunAtLoad). Treat "No such process" /
    /// "Could not find service" (status 3/113) as success.
    func stop(label: String) throws
    /// bootout + `launchctl disable gui/<uid>/<label>` (persists across logins; the plist is NOT deleted).
    func disable(label: String) throws
    /// `launchctl enable gui/<uid>/<label>` + `launchctl bootstrap gui/<uid> <plistPath>` (ignore "already loaded"/status 5/37).
    func enable(label: String, plistPath: String) throws
    /// `launchctl kickstart gui/<uid>/<label>`.
    func start(label: String) throws
    /// "application.*" labels are GUI app instances, not auto-start jobs.
    static func isAppInstanceLabel(_ label: String) -> Bool
}
struct ControlError: LocalizedError { let message: String; var errorDescription: String? { message } }
```

### Control/PM2Service.swift
```swift
final class PM2Service {
    /// True if `basic.comm`/argv looks like the PM2 God Daemon ("PM2 v5.x: God Daemon (...)").
    static func isDaemon(_ basic: ProcessBasic, details: ProcessDetails?) -> Bool
    /// Only call when a daemon is running. `pm2 jlist` → pid → (pm_id, name). Cached 5 s.
    func processesByPID() -> [Int32: (id: Int, name: String)]
    func stop(id: Int) throws           // pm2 stop <id>
    func delete(id: Int) throws         // pm2 delete <id> && pm2 save --force (so resurrect won't bring it back)
}
```

### Control/DockerService.swift
```swift
final class DockerService {
    /// com.docker.backend, com.docker.vpnkit, vpnkit-bridge, "Docker Desktop", OrbStack Helper, colima/lima ssh mux, podman gvproxy.
    static func isDockerBackend(_ basic: ProcessBasic, details: ProcessDetails?) -> Bool
    /// `docker ps --format '{{json .}}'` → host port → container (parse Ports like "0.0.0.0:5432->5432/tcp, :::5432->5432/tcp").
    /// Restart policy via `docker inspect --format '{{.HostConfig.RestartPolicy.Name}}' <ids>`. Cached 5 s. [] if docker missing.
    func containersByHostPort() -> [UInt16: DockerContainer]
    func stop(id: String) throws                 // docker stop
    func disableRestart(id: String) throws       // docker update --restart=no <id>
}
```

### Control/KillPlanner.swift
```swift
enum KillPlanner {
    /// Builds the set of processes to signal for a listener:
    /// 1. Start at the listener. Walk up ancestors while the ancestor is same-uid, pid > 1, NOT
    ///    Classifier.isBoundaryProcess, and either Classifier.isRunnerProcess, or a non-interactive script shell
    ///    (`sh/bash/zsh -c …`) whose own parent is a runner, or the same project root as the listener AND not a shell.
    ///    The highest such ancestor is `root` (may be the listener itself).
    /// 2. targets = root + all descendants (children first / deepest first), excluding: our own pid, pid ≤ 1,
    ///    boundary processes, and processes of other users (those set requiresAdmin instead of being dropped
    ///    only if they are the listener itself).
    /// 3. warnings: launchd/pm2/docker manager → "Will restart automatically — use Stop & Disable"; exposed to
    ///    network; > 1 listener in the plan ("Also stops: …").
    static func plan(for listener: ListenerProcess, table: ProcessTable,
                     details: (ProcessBasic) -> ProcessDetails?, currentUID: UInt32,
                     ownPID: Int32 = getpid()) -> KillPlan
    /// Plan containing only the listener (Option-click "Kill only this process").
    static func singleProcessPlan(for listener: ListenerProcess) -> KillPlan
}
```

### Control/ProcessKiller.swift
```swift
final class ProcessKiller {
    /// Re-verifies each target identity (SysProc.basic(pid:)?.startTime == identity.startTime) immediately before
    /// signalling — skips recycled PIDs. graceful: SIGTERM to all (children first), also SIGTERM the process group
    /// of the root ONLY if pgid == root.pid (root is a group leader of its own job) and the group contains no
    /// boundary process; poll every 100 ms up to `timeout`; then SIGKILL survivors; poll up to 2 s more.
    /// force: SIGKILL immediately. EPERM → if plan.requiresAdmin offer Shell.runAsAdmin("kill -TERM …") — done only
    /// when `allowAdmin` is true. Runs off the main thread (async).
    func stop(_ plan: KillPlan, mode: StopMode, timeout: TimeInterval, allowAdmin: Bool) async -> StopResult
}
```

### Control/Relauncher.swift
```swift
enum Relauncher {
    /// posix_spawn the original executable+argv with the original env and cwd, in a new session (setsid via
    /// POSIX_SPAWN_SETSID), stdin=/dev/null, stdout+stderr appended to ~/Library/Logs/PortPilot/<sanitized-title>.log.
    /// Returns the new pid. Throws ControlError on failure.
    static func relaunch(_ record: StoppedRecord) throws -> Int32
    static var logDirectory: URL { get }
}
```

### Control/LoginItemManager.swift
```swift
/// Keeps PortPilot running: a LaunchAgent at ~/Library/LaunchAgents/app.portpilot.agent.plist with
/// ProgramArguments=[<Bundle.main.executablePath>], RunAtLoad=true, KeepAlive={SuccessfulExit=false} (restart after
/// crash, not after Quit), ProcessType=Interactive, LimitLoadToSessionType=Aqua.
final class LoginItemManager {
    static let label = "app.portpilot.agent"
    var plistURL: URL { get }
    /// Plist exists AND points at the current executable.
    var isEnabled: Bool { get }
    /// Writes/removes plist. When enabling, does NOT bootstrap if we're already running under launchd (avoid a
    /// second instance); bootstrap happens at next login. When disabling: `launchctl disable` + remove plist
    /// (no bootout of ourselves while running — that would kill us; use `launchctl bootout` only when not our own pid).
    func setEnabled(_ enabled: Bool) throws
    /// Called at launch: if enabled but the plist points to an old path (app moved), rewrite it.
    func repairIfNeeded()
}
```

### Control/Notifier.swift
```swift
final class Notifier {
    func requestAuthorizationIfNeeded()
    /// "New port opened: :5173 — my-app (Vite)". Throttle: max 1 per group per 60 s.
    func notifyNewPorts(_ groups: [ListenerGroup])
}
```

## UI contract (owner: UI)

- `PortPilotApp` (`@main`): `MenuBarExtra { PanelView(store:) } label: { MenuBarLabel(store:) }` with
  `.menuBarExtraStyle(.window)`; `LSUIElement` = YES (no Dock icon). App delegate handles CLI modes before UI.
- Panel: width 440, max height ~620 (scrolling list), native look (`.regularMaterial`, SF Symbols, system fonts),
  light + dark mode. Everything happens INSIDE the panel (no sheets/alerts — they break MenuBarExtra windows):
  confirmations are inline (button turns into "Confirm" for 3 s).
- Header: app name, summary ("7 ports · 4 projects · 1.2 GB · 6% CPU"), "Updated 2s ago", refresh button
  (spins while scanning), settings toggle (gear) which swaps the list for SettingsView in place.
- Search field (filters port/name/path/command).
- Banner area for `store.banner` (style colors, optional action button, close ×).
- Sections in order Projects / Background Services / Apps / System (Apps/System only if enabled in settings);
  each section header shows count, collapsible.
- GroupRow: title (+ subpath), path (abbreviated, click → Finder), badges: frameworks, manager badge
  ("launchd · auto-start" in orange when isAutoRestarting), origin ("Claude Code", "Terminal"…), "Network" badge
  when exposed beyond localhost, uptime; usage (CPU %, memory) with heavy highlighting; port chips (click →
  open http://localhost:PORT, context menu: Copy URL / Copy port); trailing one-click Stop button
  (xmark.circle.fill, red on hover; spinner while busy). ⌥-click on Stop = force kill (SIGKILL).
  Overflow menu (ellipsis): Open in Browser, Reveal in Finder, Open in Terminal, Open in <Editor>, Copy Command,
  Copy PID(s), Stop, Force Kill, Stop & Disable Auto-Start (only when manager isAutoRestarting), Hide this item.
  Disclosure chevron expands ProcessRow list (pid, name, command, CPU, mem, ports, per-process stop; hover shows
  full command; Option-click on per-process stop kills only that pid). Also shows the kill plan preview lines.
- StartupItemsView (collapsible section "Startup Items"): each non-Apple LaunchAgent: label, command, status dot
  (running / loaded / disabled / failed exit), ports, Toggle(enabled) → store.setStartupItem; "Start" button when
  loaded but not running.
- RecentlyStoppedView (collapsible "Recently Stopped"): title, ports, time ago, buttons: Relaunch (if canRelaunch),
  Copy Command, Reveal; "Clear".
- Footer: "Stop All Projects" (inline confirm), hidden count ("3 hidden · Show"), Quit (⌘Q).
- SettingsView: refresh interval picker (1/2/3/5/10/30 s), Launch at login toggle, Show port count in menu bar,
  Show Apps, Show System, Notify on new ports, Graceful timeout slider (1–10 s), Sort order, Heavy CPU threshold,
  Unhide all ignored, About (version, "Built for Shayan"), Done.
- MenuBarLabel: SF Symbol `network` (or `point.3.filled.connected.trianglepath.dotted`), plus count text when
  `settings.showCountInMenuBar` and count > 0. Monospaced digits.
- SnapshotRenderer: `static func render(store: AppStore, to url: URL, width: CGFloat = 440, colorScheme: ColorScheme)`
  renders PanelView in an offscreen NSWindow/NSHostingView via `cacheDisplay` → PNG (used by `--snapshot` for
  verification without screen-recording permission). PanelView must take an optional `snapshotMode: Bool` that
  disables ScrollView (renders full height) and animations.

## CLI modes (App/CommandLineMode.swift, owner: INTEGRATION)
- `PortPilot --dump` → JSON of the grouped scan to stdout, exit.
- `PortPilot --snapshot <out.png> [--dark]` → renders the panel with live data, exit.
- `PortPilot --plan <pid>` → prints the kill plan for a listener pid, exit (no signals sent).
