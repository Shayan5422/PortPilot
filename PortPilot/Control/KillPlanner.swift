import Darwin
import Foundation

/// Decides *what* gets signalled when the user stops a listener.
///
/// The planner is pure: it only reads the process table and the `details` provider it is given (no syscalls,
/// no subprocesses), so it is cheap enough to run for every listener on every scan and easy to unit test.
///
/// Safety model (defence in depth): besides `Classifier.isBoundaryProcess`, the planner itself refuses to
/// climb into or signal anything that looks like the user's interactive session — login/interactive shells,
/// terminal multiplexers, sshd, launchd, coding agents and editors, REPLs, the PM2 daemon and any process
/// that lives inside a `.app` bundle (except dev runtimes such as the Python framework or bundled node).
enum KillPlanner {

    /// Builds the set of processes to signal for `listener`. See SPEC "Control/KillPlanner.swift".
    ///
    /// - Parameter socketsByPID: optional listening sockets from the same scan (`RawScan.socketsByPID`). Only used
    ///   to annotate the summary with ports and to warn "Also stops: …" when the plan takes down other listeners.
    static func plan(for listener: ListenerProcess, table: ProcessTable,
                     details: (ProcessBasic) -> ProcessDetails?, currentUID: UInt32,
                     ownPID: Int32 = getpid(),
                     socketsByPID: [Int32: [ListeningSocket]] = [:]) -> KillPlan {
        let basic = listener.basic
        guard basic.pid > 1, basic.pid != ownPID else { return protectedPlan(for: listener) }
        if case .docker = listener.manager {
            // The listener is Docker's port forwarder (com.docker.backend, vpnkit, OrbStack…): killing it never stops
            // the container but takes Docker itself down. Plan no signals; the container is stopped through Docker.
            return KillPlan(root: basic, targets: [], summary: [], requiresAdmin: false,
                            warnings: managerWarnings(for: listener.manager))
        }

        // The table must describe *this* process. If the pid exited or was recycled since the scan, never walk
        // the relatives of whatever owns the pid now; the killer will re-verify and skip the stale identity.
        guard let live = table[basic.pid], live.startTime == basic.startTime else {
            return singleProcessPlan(for: listener, currentUID: currentUID, ownPID: ownPID)
        }

        return withoutActuallyEscaping(details) { details in
            let walker = TreeWalker(table: table, details: details, currentUID: currentUID, ownPID: ownPID,
                                    projectRoot: listener.project?.rootPath)
            let root = walker.launchRoot(of: live)
            let ordered = walker.planTree(from: root, listener: live)
            return makePlan(for: listener, root: root, ordered: ordered, currentUID: currentUID,
                            socketsByPID: socketsByPID, details: details)
        }
    }

    /// Plan containing only the listener (Option-click "Kill only this process").
    static func singleProcessPlan(for listener: ListenerProcess) -> KillPlan {
        singleProcessPlan(for: listener, currentUID: getuid(), ownPID: getpid())
    }

    /// Testable variant of `singleProcessPlan(for:)`.
    static func singleProcessPlan(for listener: ListenerProcess, currentUID: UInt32, ownPID: Int32) -> KillPlan {
        let basic = listener.basic
        guard basic.pid > 1, basic.pid != ownPID else { return protectedPlan(for: listener) }
        let requiresAdmin = basic.uid != currentUID
        var warnings = managerWarnings(for: listener.manager)
        if listener.isExposedToNetwork { warnings.append(networkWarning(for: listener)) }
        if requiresAdmin { warnings.append(adminWarning) }
        let line = summaryLine(for: basic, label: label(for: basic, details: listener.details),
                               ports: listener.ports, currentUID: currentUID)
        return KillPlan(root: basic, targets: [basic], summary: [line], requiresAdmin: requiresAdmin,
                        warnings: warnings)
    }

    // MARK: - Boundary detection (shared with ProcessKiller)

    /// True for processes that must never be signalled as part of a tree plan, nor climbed through when looking
    /// for the launch root: `Classifier.isBoundaryProcess` OR any of the planner's own conservative checks.
    static func isProtected(_ basic: ProcessBasic, details: ProcessDetails?) -> Bool {
        if basic.pid <= 1 { return true }
        if Classifier.isBoundaryProcess(basic: basic, details: details) { return true }
        return isLocallyProtected(basic, details: details)
    }

    /// The planner's own boundary rules, independent of `Classifier` (defence in depth).
    static func isLocallyProtected(_ basic: ProcessBasic, details: ProcessDetails?) -> Bool {
        let names = candidateNames(basic, details: details)
        if !names.isDisjoint(with: sessionProcessNames) { return true }
        if !names.isDisjoint(with: agentAndEditorNames) { return true }
        if let arguments = details?.arguments, let argv0 = arguments.first {
            // process.title of the PM2 daemon: "PM2 v5.3.0: God Daemon (/Users/me/.pm2)". Killing it stops every pm2 app.
            if argv0.hasPrefix("PM2 v") || argv0.contains("God Daemon") { return true }
            // Agent CLIs installed as node/bun scripts: `node /opt/homebrew/bin/claude`.
            if arguments.count > 1, isInterpreter(normalizedName(argv0)) {
                let script = normalizedName(arguments[1])
                let stem = (script as NSString).deletingPathExtension
                if agentAndEditorNames.contains(script) || agentAndEditorNames.contains(stem) { return true }
            }
            if arguments.contains(where: { $0.hasSuffix("ipykernel_launcher") || $0.hasSuffix("ipykernel_launcher.py") }) {
                return true
            }
        }
        switch shellMode(basic, details: details) {
        case .interactive: return true
        case .command, .script, .notShell: break
        }
        if isInteractiveInterpreter(basic, details: details) { return true }
        if isInsideAppBundle(basic, details: details) { return true }
        return false
    }

    // MARK: - Shell & interpreter heuristics

    enum ShellMode: Equatable {
        case notShell
        /// Login or interactive shell (`-zsh`, `zsh -l`, `bash -i`, `zsh` with no script) — a user session.
        case interactive
        /// `sh -c "…"`, `bash -lc "…"`: runs one command line and exits.
        case command
        /// `bash ./dev.sh`: runs a script file.
        case script(String)
    }

    static func shellMode(_ basic: ProcessBasic, details: ProcessDetails?) -> ShellMode {
        guard !candidateNames(basic, details: details).isDisjoint(with: shellNames) else { return .notShell }
        // Unknown arguments: assume the worst.
        guard let arguments = details?.arguments, let argv0 = arguments.first else { return .interactive }
        // login(1) and terminal emulators prefix argv[0] with "-" for login shells.
        if argv0.hasPrefix("-") { return .interactive }

        var index = 1
        var commandMode = false
        var interactiveFlag = false
        while index < arguments.count {
            let argument = arguments[index]
            if argument == "--" || argument == "-" { index += 1; break }
            if argument == "--interactive" { interactiveFlag = true }
            if argument.hasPrefix("--") { index += 1; continue }               // --login, --norc, --noprofile
            guard argument.count > 1, argument.hasPrefix("-") || argument.hasPrefix("+") else { break }
            if argument.hasPrefix("-") {
                let flags = argument.dropFirst()
                if flags.contains("c") { commandMode = true }
                if flags.contains("i") { interactiveFlag = true }
            }
            // Options that consume the next argument (bash/zsh `-o name`, bash `-O shopt`).
            if ["-o", "+o", "-O", "+O"].contains(argument) { index += 2; continue }
            index += 1
        }
        // `zsh -i -l -c 'env'` (IDE environment probes) runs one command and exits.
        if commandMode { return .command }
        if interactiveFlag { return .interactive }
        if index < arguments.count { return .script(arguments[index]) }
        return .interactive
    }

    static func isScriptShell(_ basic: ProcessBasic, details: ProcessDetails?) -> Bool {
        switch shellMode(basic, details: details) {
        case .command, .script: return true
        case .interactive, .notShell: return false
        }
    }

    /// A bare `python3` / `node` / `irb` REPL (no script, module or inline code) is an interactive session.
    static func isInteractiveInterpreter(_ basic: ProcessBasic, details: ProcessDetails?) -> Bool {
        guard let arguments = details?.arguments, let argv0 = arguments.first else { return false }
        let name = normalizedName(argv0)
        if replOnlyNames.contains(name) { return true }
        guard name == "node" || name == "nodejs" || name.hasPrefix("python") || name == "ruby" else { return false }
        let options = arguments.dropFirst()
        if options.contains("-i") || options.contains("--interactive") { return true }
        let codeFlags: Set<String> = ["-c", "-m", "-e", "--eval", "-p", "--print", "-r", "--require", "--import",
                                      "--test", "--run"]
        if options.contains(where: { codeFlags.contains($0) || $0.hasPrefix("--eval=") }) { return false }
        // Any operand (script path) means it runs a program.
        return !options.contains { !$0.hasPrefix("-") }
    }

    /// Executables inside `*.app/Contents/` (IDE helpers, terminal emulators, Electron apps…), except dev runtimes
    /// (e.g. Python.framework's `Python.app`, an editor's bundled `node`), app bundles inside `node_modules`
    /// (Electron apps under development) and Xcode's command-line toolchain (`Xcode.app/Contents/Developer/usr/bin/
    /// make`, `git`, `swift`…, which `/usr/bin` shims exec into).
    static func isInsideAppBundle(_ basic: ProcessBasic, details: ProcessDetails?) -> Bool {
        let path = details?.executablePath ?? details?.arguments.first ?? ""
        guard path.hasPrefix("/"),
              let innermost = path.range(of: ".app/Contents/", options: [.caseInsensitive, .backwards]) else { return false }
        if path.contains("/node_modules/") { return false }
        // Judge by the innermost bundle: `Xcode.app/Contents/Developer/Applications/Simulator.app/…` is still an app.
        if path[innermost.upperBound...].hasPrefix("Developer/") { return false }
        return !isDevRuntime(normalizedName(path))
    }

    static func isDevRuntime(_ name: String) -> Bool {
        if devRuntimeNames.contains(name) { return true }
        return devRuntimePrefixes.contains { name.hasPrefix($0) }
    }

    private static func isInterpreter(_ name: String) -> Bool {
        name == "node" || name == "nodejs" || name == "bun" || name == "deno" || name.hasPrefix("python")
    }

    // MARK: - Labels

    /// Short human label for a process, e.g. "npm run dev", "node vite", "python3 -m http.server 8000".
    static func label(for basic: ProcessBasic, details: ProcessDetails?) -> String {
        guard let arguments = details?.arguments, let argv0 = arguments.first, !argv0.isEmpty else { return basic.comm }
        var rest = Array(arguments.dropFirst())
        var tokens: [String]
        if isInterpreter(normalizedName(argv0)), let script = rest.first, let tool = packageManagerName(script) {
            tokens = [tool]               // node /opt/homebrew/bin/npm run dev → npm run dev
            rest.removeFirst()
        } else {
            tokens = [displayToken(argv0, stripLoginDash: true)]
        }
        for argument in rest where !argument.isEmpty {
            if tokens.count >= 7 { tokens.append("…"); break }
            tokens.append(displayToken(argument, stripLoginDash: false))
        }
        let text = tokens.joined(separator: " ")
        return text.count > 64 ? String(text.prefix(63)) + "…" : text
    }

    private static func displayToken(_ argument: String, stripLoginDash: Bool) -> String {
        var token = argument
        if token.hasPrefix("/") || token.hasPrefix("./") || token.hasPrefix("../") || token.hasPrefix("~/") {
            let last = (token as NSString).lastPathComponent
            token = last.isEmpty ? token : last
        }
        if stripLoginDash, token.hasPrefix("-"), token.count > 1 { token.removeFirst() }
        return token
    }

    private static func packageManagerName(_ scriptPath: String) -> String? {
        let base = ((scriptPath as NSString).lastPathComponent as NSString).deletingPathExtension
        switch base {
        case "npm", "npm-cli": return "npm"
        case "npx", "npx-cli": return "npx"
        case "pnpm", "pnpx", "yarn", "yarnpkg", "corepack": return base
        default: return nil
        }
    }

    // MARK: - Plan assembly

    private static func makePlan(for listener: ListenerProcess, root: ProcessBasic, ordered: [PlannedProcess],
                                 currentUID: UInt32, socketsByPID: [Int32: [ListeningSocket]],
                                 details: (ProcessBasic) -> ProcessDetails?) -> KillPlan {
        let listenerPID = listener.basic.pid
        func ports(of process: ProcessBasic) -> [UInt16] {
            if process.pid == listenerPID { return listener.ports }
            return Array(Set((socketsByPID[process.pid] ?? []).map(\.port))).sorted()
        }
        func labelFor(_ process: ProcessBasic) -> String {
            process.pid == listenerPID && listener.details != nil
                ? label(for: process, details: listener.details)
                : label(for: process, details: details(process))
        }

        // Children first: deepest level first, BFS order reversed within a level.
        let targets = ordered.enumerated()
            .sorted { lhs, rhs in
                lhs.element.depth != rhs.element.depth ? lhs.element.depth > rhs.element.depth : lhs.offset > rhs.offset
            }
            .map(\.element.basic)
        let summary = ordered.map { summaryLine(for: $0.basic, label: labelFor($0.basic), ports: ports(of: $0.basic),
                                                currentUID: currentUID) }
        let requiresAdmin = targets.contains { $0.uid != currentUID }

        var warnings = managerWarnings(for: listener.manager)
        if listener.isExposedToNetwork { warnings.append(networkWarning(for: listener)) }
        let otherListeners = ordered.map(\.basic).filter { $0.pid != listenerPID && !ports(of: $0).isEmpty }
        if !otherListeners.isEmpty {
            let names = otherListeners.prefix(4).map { process in
                "\(labelFor(process)) (\(ports(of: process).map { ":\($0)" }.joined(separator: ", ")))"
            }
            let more = otherListeners.count > 4 ? " +\(otherListeners.count - 4) more" : ""
            warnings.append("Also stops: " + names.joined(separator: ", ") + more)
        }
        if requiresAdmin { warnings.append(adminWarning) }

        return KillPlan(root: root, targets: targets, summary: summary, requiresAdmin: requiresAdmin, warnings: warnings)
    }

    /// Plan for the listener when it is pid ≤ 1 or PortPilot itself: nothing is ever signalled.
    private static func protectedPlan(for listener: ListenerProcess) -> KillPlan {
        KillPlan(root: listener.basic, targets: [], summary: [], requiresAdmin: false,
                 warnings: ["This process is protected and can't be stopped by PortPilot"])
    }

    private static func summaryLine(for basic: ProcessBasic, label: String, ports: [UInt16], currentUID: UInt32) -> String {
        var line = "\(label) (pid \(basic.pid))"
        if !ports.isEmpty { line += " · " + ports.map { ":\($0)" }.joined(separator: ", ") }
        if basic.uid != currentUID { line += " · other user" }
        return line
    }

    static func managerWarnings(for manager: ProcessManager) -> [String] {
        let action = "use Stop & Disable Auto-Start"
        switch manager {
        case .none, .watcher:
            return []
        case .launchd(let job):
            if job.keepAlive { return ["Will restart automatically (launchd: \(job.label)) — \(action)"] }
            if job.runAtLoad { return ["Starts again at next login (launchd: \(job.label)) — \(action)"] }
            return []
        case .pm2(_, let name):
            return ["Will restart automatically (pm2: \(name)) — \(action)"]
        case .docker(let container):
            return ["Published by Docker container \(container.name) — stop the container, not the Docker process (\(action))"]
        }
    }

    private static func networkWarning(for listener: ListenerProcess) -> String {
        let exposed = listener.sockets.filter(\.isExposed).map(\.port)
        let ports = Array(Set(exposed)).sorted().map { ":\($0)" }.joined(separator: ", ")
        return "Exposed to the network: \(ports) accepts connections from other devices"
    }

    private static let adminWarning = "Owned by another user — macOS will ask for an administrator password"

    // MARK: - Names

    /// Lower-cased names a process is known by: p_comm, executable file name and argv[0] (login "-" stripped).
    private static func candidateNames(_ basic: ProcessBasic, details: ProcessDetails?) -> Set<String> {
        var names: Set<String> = [normalizedName(basic.comm)]
        if let path = details?.executablePath, !path.isEmpty { names.insert(normalizedName(path)) }
        if let argv0 = details?.arguments.first, !argv0.isEmpty { names.insert(normalizedName(argv0)) }
        names.remove("")
        return names
    }

    /// "/bin/-zsh" → "zsh", "Python" → "python".
    static func normalizedName(_ pathOrName: String) -> String {
        var name = (pathOrName as NSString).lastPathComponent.lowercased()
        while name.hasPrefix("-") { name.removeFirst() }
        return name
    }

    static let shellNames: Set<String> = [
        "sh", "bash", "zsh", "dash", "ksh", "mksh", "oksh", "yash", "fish", "tcsh", "csh", "nu", "xonsh", "elvish",
        "pwsh",
    ]

    /// Session plumbing that owns a user's terminal/login session.
    private static let sessionProcessNames: Set<String> = [
        "launchd", "kernel_task", "loginwindow", "windowserver", "login", "su", "sudo", "doas",
        "sshd", "sshd-session", "sshd-auth", "mosh-server", "tmux", "screen", "zellij", "abduco", "dtach", "byobu",
        "script", "supervisord", "pm2",
    ]

    /// Interactive tools a server is commonly launched *from*; they must survive stopping that server.
    private static let agentAndEditorNames: Set<String> = [
        "claude", "codex", "gemini", "aider", "opencode", "cursor-agent", "goose", "amp", "copilot", "crush",
        "vim", "nvim", "vi", "emacs", "nano", "hx", "helix", "kak",
    ]

    /// Names that are always an interactive REPL.
    private static let replOnlyNames: Set<String> = ["irb", "ipython", "ipython3", "bpython", "ptpython", "iex"]

    private static let devRuntimeNames: Set<String> = [
        "node", "nodejs", "bun", "deno", "ruby", "php", "php-fpm", "java", "go", "dotnet", "beam.smp", "erl",
        "elixir", "perl", "pypy", "pypy3", "lua", "luajit", "swift",
    ]
    private static let devRuntimePrefixes = ["python", "pypy", "ruby", "php", "perl", "java"]
}

// MARK: - Tree walking

/// One process in a plan with its depth below the plan root (root = 0).
private struct PlannedProcess {
    let basic: ProcessBasic
    let depth: Int
}

/// Walks the process table for one plan. Holds the (non-escaping) details provider for the duration of a call.
private struct TreeWalker {
    let table: ProcessTable
    let details: (ProcessBasic) -> ProcessDetails?
    let currentUID: UInt32
    let ownPID: Int32
    let projectRoot: String?
    /// PortPilot and its own ancestors: never part of a plan, never climbed through.
    let ownLineage: Set<Int32>

    init(table: ProcessTable, details: @escaping (ProcessBasic) -> ProcessDetails?, currentUID: UInt32, ownPID: Int32,
         projectRoot: String?) {
        self.table = table
        self.details = details
        self.currentUID = currentUID
        self.ownPID = ownPID
        // A root path of "/" or one too short to be a project would make every process "same project".
        if let root = projectRoot, root.count > 1, root != NSHomeDirectory() {
            self.projectRoot = root.hasSuffix("/") ? String(root.dropLast()) : root
        } else {
            self.projectRoot = nil
        }
        var lineage: Set<Int32> = [ownPID]
        for ancestor in table.ancestors(of: ownPID) { lineage.insert(ancestor.pid) }
        self.ownLineage = lineage
    }

    // MARK: Step 1 — launch root

    /// Highest ancestor that still belongs to the server's launch (e.g. `npm run dev`), or `listener` itself.
    ///
    /// Climbs while ancestors are eligible and are either launch anchors (runner / same-project program) or
    /// non-interactive script shells. Script shells only become part of the plan when an anchor sits above them
    /// (`npm → sh -c vite → node`): the root is the highest *anchor*, so a chain like
    /// `claude → zsh -c → python` stops at the listener and never takes the agent's shell.
    func launchRoot(of listener: ProcessBasic) -> ProcessBasic {
        var root = listener
        var below = listener
        for candidate in table.ancestors(of: listener.pid) {      // nearest first
            let candidateDetails = details(candidate)
            guard isEligibleAncestor(candidate, details: candidateDetails, below: below) else { break }
            if isLaunchAnchor(candidate, details: candidateDetails) {
                root = candidate
            } else if !KillPlanner.isScriptShell(candidate, details: candidateDetails) {
                break
            }
            below = candidate
        }
        return root
    }

    /// Same user, not pid ≤ 1, not PortPilot's own lineage, not protected, and plausibly the parent of `child`
    /// (a parent can't be younger than its child — protects against stale tables / recycled ppids).
    private func isEligibleAncestor(_ candidate: ProcessBasic, details candidateDetails: ProcessDetails?,
                                    below child: ProcessBasic) -> Bool {
        guard candidate.pid > 1, !ownLineage.contains(candidate.pid), candidate.uid == currentUID,
              candidate.startTime <= child.startTime else { return false }
        return !KillPlanner.isProtected(candidate, details: candidateDetails)
    }

    /// Runner (npm, make, turbo…), a non-shell program of the same project (`node scripts/dev.js`), or a
    /// script-file shell whose script lives in the project (`bash ./scripts/dev.sh`).
    ///
    /// Shells are never anchors through `Classifier.isRunnerProcess`: a `zsh -c "npm run dev"` spawned by a coding
    /// agent or IDE belongs to that tool, so a shell is only ever included *below* a real anchor.
    private func isLaunchAnchor(_ candidate: ProcessBasic, details candidateDetails: ProcessDetails?) -> Bool {
        let mode = KillPlanner.shellMode(candidate, details: candidateDetails)
        if mode == .notShell, Classifier.isRunnerProcess(basic: candidate, details: candidateDetails) { return true }
        guard let root = projectRoot, let candidateDetails else { return false }
        switch mode {
        case .notShell:
            return belongsToProject(candidateDetails, root: root)
        case .script(let script):
            let path = script.hasPrefix("/") ? script
                : ((candidateDetails.cwd ?? "") as NSString).appendingPathComponent(script)
            return isPath((path as NSString).standardizingPath, inside: root)
        case .command, .interactive:
            return false
        }
    }

    private func belongsToProject(_ details: ProcessDetails, root: String) -> Bool {
        if let cwd = details.cwd, isPath(cwd, inside: root) { return true }
        if let executable = details.executablePath, isPath(executable, inside: root) { return true }
        return details.arguments.dropFirst().contains { $0.hasPrefix("/") && isPath($0, inside: root) }
    }

    private func isPath(_ path: String, inside root: String) -> Bool {
        path == root || path.hasPrefix(root + "/")
    }

    // MARK: Step 2 — targets

    /// Root plus descendants in BFS order with depths. Subtrees are pruned at PortPilot itself, pid ≤ 1, protected
    /// processes and processes of other users — except the listener, which is always kept (it is what the user
    /// asked to stop; another user's listener makes the plan require admin rights).
    func planTree(from root: ProcessBasic, listener: ProcessBasic) -> [PlannedProcess] {
        var result = [PlannedProcess(basic: root, depth: 0)]
        var seen: Set<Int32> = [root.pid]
        var index = 0
        while index < result.count {
            let parent = result[index]
            index += 1
            for childPID in table.childrenByPID[parent.basic.pid] ?? [] {
                guard seen.insert(childPID).inserted, let child = table[childPID] else { continue }
                guard child.pid > 1, !ownLineage.contains(child.pid),
                      child.startTime >= parent.basic.startTime else { continue }
                if child.identity != listener.identity {
                    guard child.uid == currentUID, !KillPlanner.isProtected(child, details: details(child)) else { continue }
                }
                result.append(PlannedProcess(basic: child, depth: parent.depth + 1))
            }
        }
        return result
    }
}
