import Darwin
import XCTest
@testable import PortPilot

// Synthetic process tables only: nothing here inspects or signals real processes.

private let userUID: UInt32 = 501
private let rootUID: UInt32 = 0
/// A pid that is certainly not in the synthetic tables unless a test puts it there.
private let harnessPID: Int32 = 99_999
private let projectPath = "/Users/me/code/my-app"
private let project = ProjectInfo(rootPath: projectPath, name: "my-app", subpath: nil, markers: [".git", "package.json"])
private let nodeExe = "/opt/homebrew/Cellar/node/24.1.0/bin/node"

/// In-memory process table + details provider.
private final class FakeSystem {
    private(set) var processes: [Int32: (basic: ProcessBasic, details: ProcessDetails?)] = [:]
    private var clock: UInt64 = 1_760_000_000_000_000

    init(withLaunchd: Bool = true) {
        if withLaunchd {
            add(1, ppid: 0, comm: "launchd", args: ["/sbin/launchd"], exe: "/sbin/launchd", uid: rootUID)
        }
    }

    /// Adds a process. Start times increase with insertion order, so add parents before children.
    @discardableResult
    func add(_ pid: Int32, ppid: Int32, comm: String, args: [String]?, exe: String? = nil, cwd: String? = nil,
             uid: UInt32 = userUID, pgid: Int32? = nil, startTime: UInt64? = nil) -> ProcessBasic {
        clock += 1_000
        let basic = ProcessBasic(pid: pid, ppid: ppid, pgid: pgid ?? pid, uid: uid, comm: comm,
                                 startTime: startTime ?? clock)
        let details = args.map {
            ProcessDetails(identity: basic.identity, executablePath: exe, arguments: $0, environment: [:], cwd: cwd)
        }
        processes[pid] = (basic, details)
        return basic
    }

    var table: ProcessTable { ProcessTable(processes: processes.values.map(\.basic)) }

    func details(_ basic: ProcessBasic) -> ProcessDetails? {
        guard let entry = processes[basic.pid], entry.basic.startTime == basic.startTime else { return nil }
        return entry.details
    }

    func listener(_ pid: Int32, ports: [UInt16] = [5173], address: String = "127.0.0.1",
                  project: ProjectInfo? = project, manager: ProcessManager = .none,
                  category: ListenerCategory = .project) -> ListenerProcess {
        guard let entry = processes[pid] else { fatalError("unknown pid \(pid)") }
        return makeListener(entry.basic, details: entry.details, ports: ports, address: address, project: project,
                            manager: manager, category: category)
    }

    func plan(for listener: ListenerProcess, ownPID: Int32 = harnessPID,
              sockets: [Int32: [ListeningSocket]] = [:]) -> KillPlan {
        KillPlanner.plan(for: listener, table: table, details: { self.details($0) }, currentUID: userUID,
                         ownPID: ownPID, socketsByPID: sockets)
    }
}

private func makeListener(_ basic: ProcessBasic, details: ProcessDetails?, ports: [UInt16], address: String = "127.0.0.1",
                          project: ProjectInfo? = project, manager: ProcessManager = .none,
                          category: ListenerCategory = .project) -> ListenerProcess {
    ListenerProcess(basic: basic, details: details,
                    sockets: ports.map { ListeningSocket(port: $0, address: address, family: .ipv4, pid: basic.pid) },
                    usage: .zero, treeUsage: .zero, category: category, project: project,
                    displayName: basic.comm, frameworks: [], origin: nil, manager: manager, appName: nil,
                    isRestricted: basic.uid != userUID)
}

/// Terminal.app → login (root) → -zsh. Returns the login shell's pid.
@discardableResult
private func addTerminalSession(_ system: FakeSystem, base: Int32) -> Int32 {
    system.add(base, ppid: 1, comm: "Terminal", args: ["/System/Applications/Utilities/Terminal.app/Contents/MacOS/Terminal"],
               exe: "/System/Applications/Utilities/Terminal.app/Contents/MacOS/Terminal", cwd: "/")
    system.add(base + 1, ppid: base, comm: "login", args: ["login", "-pf", "me"], exe: "/usr/bin/login", uid: rootUID)
    system.add(base + 2, ppid: base + 1, comm: "zsh", args: ["-zsh"], exe: "/bin/zsh", cwd: projectPath)
    return base + 2
}

private func pids(_ processes: [ProcessBasic]) -> [Int32] { processes.map(\.pid) }

final class KillPlannerTests: XCTestCase {

    // MARK: Spec scenarios

    /// Terminal → zsh(login) → npm run dev → sh -c vite → node vite (listener) → esbuild
    func testNpmViteTreeStopsAtNpmAndNeverTouchesTheTerminal() {
        let system = FakeSystem()
        let zsh = addTerminalSession(system, base: 400)
        system.add(410, ppid: zsh, comm: "node", args: ["node", "/opt/homebrew/bin/npm", "run", "dev"], exe: nodeExe,
                   cwd: projectPath)
        system.add(411, ppid: 410, comm: "sh", args: ["sh", "-c", "vite"], exe: "/bin/sh", cwd: projectPath, pgid: 410)
        system.add(412, ppid: 411, comm: "node", args: ["node", "\(projectPath)/node_modules/.bin/vite"], exe: nodeExe,
                   cwd: projectPath, pgid: 410)
        system.add(413, ppid: 412, comm: "esbuild",
                   args: ["\(projectPath)/node_modules/@esbuild/darwin-arm64/bin/esbuild", "--service=0.21.5", "--ping"],
                   exe: "\(projectPath)/node_modules/@esbuild/darwin-arm64/bin/esbuild", cwd: projectPath, pgid: 410)

        let plan = system.plan(for: system.listener(412))

        XCTAssertEqual(plan.root.pid, 410)
        XCTAssertEqual(Set(pids(plan.targets)), [410, 411, 412, 413])
        for forbidden: Int32 in [1, 400, 401, 402] { XCTAssertFalse(pids(plan.targets).contains(forbidden)) }
        // Children first: deepest first, the root last.
        XCTAssertEqual(pids(plan.targets), [413, 412, 411, 410])
        XCTAssertFalse(plan.requiresAdmin)
        XCTAssertEqual(plan.summary.first, "npm run dev (pid 410)")
        XCTAssertTrue(plan.summary.contains("node vite (pid 412) · :5173"), "\(plan.summary)")
        XCTAssertTrue(plan.warnings.isEmpty, "\(plan.warnings)")
    }

    /// Claude Code (claude) → zsh -c → python app.py (listener): the agent and its shell survive.
    func testClaudeCodeShellIsNeverPartOfThePlan() {
        let system = FakeSystem()
        let zsh = addTerminalSession(system, base: 400)
        system.add(500, ppid: zsh, comm: "2.0.14", args: ["claude"], exe: "/Users/me/.local/share/claude/versions/2.0.14",
                   cwd: projectPath)
        system.add(501, ppid: 500, comm: "zsh",
                   args: ["/bin/zsh", "-c", "-l", "source /Users/me/.claude/shell-snapshots/snapshot-zsh.sh && eval 'python app.py'"],
                   exe: "/bin/zsh", cwd: projectPath)
        let pythonExe = "/opt/homebrew/Cellar/python@3.13/3.13.1/Frameworks/Python.framework/Versions/3.13/Resources/Python.app/Contents/MacOS/Python"
        system.add(502, ppid: 501, comm: "Python", args: ["/opt/homebrew/opt/python@3.13/bin/python3.13", "app.py"],
                   exe: pythonExe, cwd: projectPath, pgid: 501)
        system.add(503, ppid: 502, comm: "Python", args: ["/opt/homebrew/opt/python@3.13/bin/python3.13", "app.py"],
                   exe: pythonExe, cwd: projectPath, pgid: 501)

        let plan = system.plan(for: system.listener(502, ports: [8000]))

        XCTAssertEqual(plan.root.pid, 502)
        XCTAssertEqual(pids(plan.targets), [503, 502], "the reloader child is included, the agent shell is not")
    }

    /// launchd(1) → node server.js (ppid 1)
    func testProcessStartedByLaunchdIsItsOwnRoot() {
        let system = FakeSystem()
        system.add(700, ppid: 1, comm: "node", args: [nodeExe, "\(projectPath)/server.js"], exe: nodeExe, cwd: projectPath)
        system.add(701, ppid: 700, comm: "node", args: [nodeExe, "\(projectPath)/worker.js"], exe: nodeExe, cwd: projectPath)

        let plan = system.plan(for: system.listener(700, ports: [3000]))

        XCTAssertEqual(plan.root.pid, 700)
        XCTAssertEqual(pids(plan.targets), [701, 700])
        XCTAssertFalse(pids(plan.targets).contains(1))
    }

    /// VS Code helper → node (listener): the helper (inside an .app, cwd in the project) is not taken.
    func testIDEHelperIsABoundaryEvenWithProjectCwd() {
        let system = FakeSystem()
        let codeMain = "/Applications/Visual Studio Code.app/Contents/MacOS/Electron"
        let helper = "/Applications/Visual Studio Code.app/Contents/Frameworks/Code Helper (Plugin).app/Contents/MacOS/Code Helper (Plugin)"
        system.add(600, ppid: 1, comm: "Electron", args: [codeMain], exe: codeMain, cwd: "/")
        system.add(601, ppid: 600, comm: "Code Helper (Plu", args: [helper, "--type=utility"], exe: helper, cwd: projectPath)
        system.add(602, ppid: 601, comm: "node", args: [nodeExe, "\(projectPath)/server.js"], exe: nodeExe, cwd: projectPath)

        let plan = system.plan(for: system.listener(602, ports: [4000]))

        XCTAssertEqual(plan.root.pid, 602)
        XCTAssertEqual(pids(plan.targets), [602])
    }

    // MARK: PID reuse & stale tables

    func testRecycledListenerPidIsNotWalked() {
        let system = FakeSystem()
        let zsh = addTerminalSession(system, base: 400)
        system.add(410, ppid: zsh, comm: "node", args: ["node", "/opt/homebrew/bin/npm", "run", "dev"], exe: nodeExe,
                   cwd: projectPath)
        let current = system.add(412, ppid: 410, comm: "node", args: [nodeExe, "other.js"], exe: nodeExe, cwd: projectPath)
        system.add(413, ppid: 412, comm: "esbuild", args: ["esbuild"], cwd: projectPath)
        // The scan saw a different process with the same pid (older start time).
        let stale = ProcessBasic(pid: 412, ppid: 410, pgid: 412, uid: userUID, comm: "node",
                                 startTime: current.startTime - 5_000_000)
        let listener = makeListener(stale, details: nil, ports: [5173])

        let plan = system.plan(for: listener)

        XCTAssertEqual(plan.root, stale)
        XCTAssertEqual(plan.targets, [stale], "only the stale identity; the killer re-verifies and skips it")
    }

    func testImpossibleParentChildStartTimesArePruned() {
        let system = FakeSystem()
        system.add(800, ppid: 1, comm: "node", args: [nodeExe, "server.js"], exe: nodeExe, cwd: projectPath)
        // A "child" that started before its parent can't be a real child (stale ppid / recycled pid).
        system.add(801, ppid: 800, comm: "node", args: [nodeExe, "other.js"], exe: nodeExe, cwd: projectPath,
                   startTime: 1_000)
        let plan = system.plan(for: system.listener(800))
        XCTAssertEqual(pids(plan.targets), [800])

        // A "parent" younger than the listener is not climbed.
        let system2 = FakeSystem()
        system2.add(900, ppid: 1, comm: "node", args: ["node", "/opt/homebrew/bin/npm", "start"], exe: nodeExe,
                    cwd: projectPath, startTime: 9_000_000_000_000_000)
        system2.add(901, ppid: 900, comm: "node", args: [nodeExe, "server.js"], exe: nodeExe, cwd: projectPath)
        XCTAssertEqual(system2.plan(for: system2.listener(901)).root.pid, 901)
    }

    // MARK: Own process

    func testOwnPidAndItsSubtreeAreExcluded() {
        let system = FakeSystem()
        system.add(700, ppid: 1, comm: "node", args: [nodeExe, "server.js"], exe: nodeExe, cwd: projectPath)
        system.add(701, ppid: 700, comm: "node", args: [nodeExe, "worker.js"], exe: nodeExe, cwd: projectPath)
        system.add(777, ppid: 700, comm: "PortPilot", args: ["/Applications/PortPilot.app/Contents/MacOS/PortPilot"],
                   exe: "/tmp/PortPilot", cwd: projectPath)
        system.add(778, ppid: 777, comm: "launchctl", args: ["/bin/launchctl", "list"], exe: "/bin/launchctl")

        let plan = system.plan(for: system.listener(700), ownPID: 777)

        XCTAssertEqual(plan.root.pid, 700)
        XCTAssertEqual(Set(pids(plan.targets)), [700, 701])

        // When the listener's parent is one of PortPilot's own ancestors, the walk does not climb into it.
        let nested = FakeSystem()
        nested.add(410, ppid: 1, comm: "node", args: ["node", "/opt/homebrew/bin/npm", "run", "dev"], exe: nodeExe,
                   cwd: projectPath)
        nested.add(412, ppid: 410, comm: "node", args: [nodeExe, "server.js"], exe: nodeExe, cwd: projectPath)
        nested.add(777, ppid: 412, comm: "PortPilot", args: ["PortPilot"], exe: "/tmp/PortPilot", cwd: projectPath)
        let nestedPlan = nested.plan(for: nested.listener(412), ownPID: 777)
        XCTAssertEqual(nestedPlan.root.pid, 412)
        XCTAssertEqual(pids(nestedPlan.targets), [412])
    }

    func testNeverClimbsIntoOwnLineage() {
        let system = FakeSystem()
        // PortPilot (a harness here) is itself a runner-looking process that spawned the server via sh -c.
        system.add(777, ppid: 1, comm: "node", args: ["node", "/opt/homebrew/bin/npm", "test"], exe: nodeExe,
                   cwd: projectPath)
        system.add(778, ppid: 777, comm: "sh", args: ["/bin/sh", "-c", "python3 -m http.server"], exe: "/bin/sh",
                   cwd: projectPath)
        system.add(779, ppid: 778, comm: "Python", args: ["python3", "-m", "http.server"], exe: "/usr/bin/python3",
                   cwd: projectPath)

        let plan = system.plan(for: system.listener(779, ports: [8000]), ownPID: 777)

        XCTAssertEqual(plan.root.pid, 779)
        XCTAssertEqual(pids(plan.targets), [779])
    }

    func testListenerThatIsPortPilotOrLaunchdIsNeverPlanned() {
        let system = FakeSystem()
        system.add(777, ppid: 1, comm: "PortPilot", args: ["PortPilot"], exe: "/tmp/PortPilot")
        XCTAssertTrue(system.plan(for: system.listener(777), ownPID: 777).targets.isEmpty)
        XCTAssertTrue(system.plan(for: system.listener(1)).targets.isEmpty)
        XCTAssertTrue(KillPlanner.singleProcessPlan(for: system.listener(1)).targets.isEmpty)
    }

    // MARK: Other users

    func testOtherUserListenerRequiresAdmin() {
        let system = FakeSystem()
        system.add(410, ppid: 1, comm: "node", args: ["node", "/opt/homebrew/bin/npm", "run", "dev"], exe: nodeExe,
                   cwd: projectPath)
        system.add(412, ppid: 410, comm: "node", args: [nodeExe, "server.js"], exe: nodeExe, cwd: projectPath,
                   uid: rootUID)
        system.add(413, ppid: 412, comm: "node", args: [nodeExe, "worker.js"], exe: nodeExe, uid: rootUID)

        let plan = system.plan(for: system.listener(412))

        XCTAssertEqual(plan.root.pid, 410)
        XCTAssertEqual(Set(pids(plan.targets)), [410, 412], "other-user child of the listener is dropped")
        XCTAssertTrue(plan.requiresAdmin)
        XCTAssertTrue(plan.summary.contains { $0.hasPrefix("node server.js (pid 412)") && $0.hasSuffix("other user") },
                      "\(plan.summary)")
        XCTAssertTrue(plan.warnings.contains { $0.contains("administrator") })
    }

    func testOtherUserChildIsDroppedWithoutAdmin() {
        let system = FakeSystem()
        system.add(700, ppid: 1, comm: "node", args: [nodeExe, "server.js"], exe: nodeExe, cwd: projectPath)
        system.add(701, ppid: 700, comm: "helper", args: ["/usr/local/bin/helper"], exe: "/usr/local/bin/helper",
                   uid: rootUID)
        system.add(702, ppid: 701, comm: "node", args: [nodeExe, "child.js"], exe: nodeExe)

        let plan = system.plan(for: system.listener(700))

        XCTAssertEqual(pids(plan.targets), [700])
        XCTAssertFalse(plan.requiresAdmin)
    }

    func testOtherUserListenerAloneRequiresAdmin() {
        let system = FakeSystem()
        system.add(300, ppid: 1, comm: "nginx", args: ["nginx: master process /opt/homebrew/bin/nginx"],
                   exe: "/opt/homebrew/bin/nginx", uid: rootUID)
        let plan = system.plan(for: system.listener(300, ports: [80], project: nil, category: .system))
        XCTAssertEqual(pids(plan.targets), [300])
        XCTAssertTrue(plan.requiresAdmin)
    }

    // MARK: Walking rules

    func testChainedScriptShellsBelowARunnerAreIncluded() {
        let system = FakeSystem()
        let zsh = addTerminalSession(system, base: 400)
        system.add(410, ppid: zsh, comm: "node", args: ["node", "/opt/homebrew/bin/npm", "run", "dev"], exe: nodeExe,
                   cwd: projectPath)
        system.add(411, ppid: 410, comm: "sh", args: ["sh", "-c", "bash -c 'node server.js'"], exe: "/bin/sh",
                   cwd: projectPath)
        system.add(412, ppid: 411, comm: "bash", args: ["bash", "-c", "node server.js"], exe: "/bin/bash", cwd: projectPath)
        system.add(413, ppid: 412, comm: "node", args: ["node", "server.js"], exe: nodeExe, cwd: projectPath)

        let plan = system.plan(for: system.listener(413))
        XCTAssertEqual(plan.root.pid, 410)
        XCTAssertEqual(pids(plan.targets), [413, 412, 411, 410])
    }

    func testSameProjectProgramIsAnAnchorButInteractiveShellIsNot() {
        let system = FakeSystem()
        let zsh = addTerminalSession(system, base: 400)
        system.add(420, ppid: zsh, comm: "node", args: ["node", "scripts/dev.js"], exe: nodeExe, cwd: projectPath)
        system.add(421, ppid: 420, comm: "node", args: ["node", "server.js"], exe: nodeExe, cwd: projectPath)

        let plan = system.plan(for: system.listener(421))
        XCTAssertEqual(plan.root.pid, 420)
        XCTAssertEqual(pids(plan.targets), [421, 420])

        // Without a project the unknown parent program is not taken.
        let unrelated = system.plan(for: system.listener(421, project: nil, category: .service))
        XCTAssertEqual(unrelated.root.pid, 421)
    }

    func testProjectScriptShellIsAnAnchor() {
        let system = FakeSystem()
        let zsh = addTerminalSession(system, base: 400)
        system.add(430, ppid: zsh, comm: "bash", args: ["/bin/bash", "./scripts/dev.sh"], exe: "/bin/bash", cwd: projectPath)
        system.add(431, ppid: 430, comm: "node", args: ["node", "server.js"], exe: nodeExe, cwd: projectPath)
        XCTAssertEqual(system.plan(for: system.listener(431)).root.pid, 430)

        // A script outside the project is not.
        system.add(440, ppid: zsh, comm: "bash", args: ["/bin/bash", "/usr/local/bin/serve.sh"], exe: "/bin/bash",
                   cwd: projectPath)
        system.add(441, ppid: 440, comm: "node", args: ["node", "server.js"], exe: nodeExe, cwd: projectPath)
        XCTAssertEqual(system.plan(for: system.listener(441)).root.pid, 441)
    }

    /// `make` from the developer toolchain (what /usr/bin/make execs into) is a runner, not a boundary.
    /// (The Xcode.app/Contents/Developer variant is covered by the planner's own .app rule in
    /// `testProtectedDescendantsArePrunedWithTheirSubtrees`; Classifier decides it independently.)
    func testToolchainMakeIsARunner() {
        let system = FakeSystem()
        let zsh = addTerminalSession(system, base: 400)
        let make = "/Library/Developer/CommandLineTools/usr/bin/make"
        system.add(455, ppid: zsh, comm: "make", args: [make, "dev"], exe: make, cwd: projectPath)
        system.add(456, ppid: 455, comm: "sh", args: ["/bin/sh", "-c", "python3 -m http.server 8000 & wait"],
                   exe: "/bin/sh", cwd: projectPath)
        system.add(457, ppid: 456, comm: "Python", args: ["python3", "-m", "http.server", "8000"],
                   exe: "/opt/homebrew/bin/python3", cwd: projectPath)
        let plan = system.plan(for: system.listener(457, ports: [8000]))
        XCTAssertEqual(plan.root.pid, 455)
        XCTAssertEqual(pids(plan.targets), [457, 456, 455])
    }

    func testTmuxSessionIsABoundary() {
        let system = FakeSystem()
        system.add(450, ppid: 1, comm: "tmux", args: ["tmux"], exe: "/opt/homebrew/bin/tmux", cwd: projectPath)
        system.add(451, ppid: 450, comm: "zsh", args: ["-zsh"], exe: "/bin/zsh", cwd: projectPath)
        system.add(452, ppid: 451, comm: "node", args: ["node", "/opt/homebrew/bin/npm", "start"], exe: nodeExe,
                   cwd: projectPath)
        system.add(453, ppid: 452, comm: "node", args: ["node", "server.js"], exe: nodeExe, cwd: projectPath)

        let plan = system.plan(for: system.listener(453))
        XCTAssertEqual(plan.root.pid, 452)
        XCTAssertEqual(Set(pids(plan.targets)), [452, 453])
    }

    func testSSHAndNonLoginInteractiveShellsAreBoundaries() {
        let system = FakeSystem()
        system.add(460, ppid: 1, comm: "sshd-session", args: ["sshd-session: me@ttys004"], exe: "/usr/libexec/sshd-session")
        system.add(461, ppid: 460, comm: "zsh", args: ["zsh"], exe: "/bin/zsh", cwd: projectPath)
        system.add(462, ppid: 461, comm: "node", args: ["node", "dev-server.js"], exe: nodeExe, cwd: projectPath)
        let plan = system.plan(for: system.listener(462))
        XCTAssertEqual(pids(plan.targets), [462])
    }

    func testPM2DaemonIsNeverTheRoot() {
        let system = FakeSystem()
        system.add(470, ppid: 1, comm: "node", args: ["PM2 v5.4.2: God Daemon (/Users/me/.pm2)"], exe: nodeExe,
                   cwd: projectPath)
        system.add(471, ppid: 470, comm: "node", args: [nodeExe, "\(projectPath)/server.js"], exe: nodeExe, cwd: projectPath)
        let plan = system.plan(for: system.listener(471, manager: .pm2(id: 0, name: "api")))
        XCTAssertEqual(pids(plan.targets), [471])
        XCTAssertTrue(plan.warnings.contains { $0.contains("Will restart automatically") })
    }

    func testProtectedDescendantsArePrunedWithTheirSubtrees() {
        let system = FakeSystem()
        system.add(480, ppid: 1, comm: "node", args: [nodeExe, "server.js"], exe: nodeExe, cwd: projectPath)
        // A web terminal: interactive shell + whatever the user runs in it.
        system.add(481, ppid: 480, comm: "zsh", args: ["/bin/zsh", "-i"], exe: "/bin/zsh", cwd: projectPath)
        system.add(482, ppid: 481, comm: "vim", args: ["vim", "notes.md"], exe: "/usr/bin/vim", cwd: projectPath)
        // A browser launched by puppeteer (inside an .app).
        let chrome = "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"
        system.add(483, ppid: 480, comm: "Google Chrome", args: [chrome, "--headless"], exe: chrome)
        // A regular worker stays.
        system.add(484, ppid: 480, comm: "node", args: [nodeExe, "worker.js"], exe: nodeExe, cwd: projectPath)

        let plan = system.plan(for: system.listener(480))
        XCTAssertEqual(Set(pids(plan.targets)), [480, 484])

        // The planner's own .app rule exempts dev runtimes and Electron apps under development (node_modules).
        let electron = "\(projectPath)/node_modules/electron/dist/Electron.app/Contents/MacOS/Electron"
        let pythonApp = "/opt/homebrew/Frameworks/Python.framework/Versions/3.13/Resources/Python.app/Contents/MacOS/Python"
        let xcodeMake = "/Applications/Xcode.app/Contents/Developer/usr/bin/make"
        let simulator = "/Applications/Xcode.app/Contents/Developer/Applications/Simulator.app/Contents/MacOS/Simulator"
        let xcode = "/Applications/Xcode.app/Contents/MacOS/Xcode"
        for (exe, expected) in [(electron, false), (pythonApp, false), (xcodeMake, false), (chrome, true),
                                (simulator, true), (xcode, true)] {
            let basic = ProcessBasic(pid: 10, ppid: 1, pgid: 10, uid: userUID, comm: "x", startTime: 1)
            let details = ProcessDetails(identity: basic.identity, executablePath: exe, arguments: [exe],
                                         environment: [:], cwd: nil)
            XCTAssertEqual(KillPlanner.isInsideAppBundle(basic, details: details), expected, exe)
        }
    }

    // MARK: Warnings

    func testWarningsForManagersNetworkAndOtherListeners() {
        let system = FakeSystem()
        let zsh = addTerminalSession(system, base: 400)
        system.add(490, ppid: zsh, comm: "node", args: ["node", "\(projectPath)/node_modules/.bin/concurrently", "a", "b"],
                   exe: nodeExe, cwd: projectPath)
        system.add(491, ppid: 490, comm: "node", args: ["node", "web.js"], exe: nodeExe, cwd: projectPath)
        system.add(492, ppid: 490, comm: "node", args: ["node", "api.js"], exe: nodeExe, cwd: projectPath)
        let job = LaunchdJob(label: "com.me.web", domain: "gui/501", plistPath: nil, keepAlive: true, runAtLoad: true,
                             pid: 490)
        let listener = system.listener(491, ports: [5173], address: "*", manager: .launchd(job))
        let sockets: [Int32: [ListeningSocket]] = [
            491: [ListeningSocket(port: 5173, address: "*", family: .ipv4, pid: 491)],
            492: [ListeningSocket(port: 3000, address: "127.0.0.1", family: .ipv4, pid: 492)],
        ]

        let plan = system.plan(for: listener, sockets: sockets)

        XCTAssertEqual(plan.root.pid, 490)
        XCTAssertTrue(plan.warnings.contains { $0.hasPrefix("Will restart automatically (launchd: com.me.web)") },
                      "\(plan.warnings)")
        XCTAssertTrue(plan.warnings.contains { $0.hasPrefix("Exposed to the network: :5173") }, "\(plan.warnings)")
        XCTAssertTrue(plan.warnings.contains("Also stops: node api.js (:3000)"), "\(plan.warnings)")
    }

    func testDockerPublishedPortIsNeverKilledThroughTheBackend() {
        let system = FakeSystem()
        let backend = "/Applications/Docker.app/Contents/MacOS/com.docker.backend"
        system.add(495, ppid: 1, comm: "com.docker.backe", args: [backend], exe: backend)
        let container = DockerContainer(id: "abc", name: "postgres", image: "postgres:16", restartPolicy: "always")
        let plan = system.plan(for: system.listener(495, ports: [5432], project: nil, manager: .docker(container),
                                                    category: .service))
        XCTAssertTrue(plan.targets.isEmpty)
        XCTAssertTrue(plan.warnings.contains { $0.contains("postgres") })
    }

    func testSingleProcessPlan() {
        let system = FakeSystem()
        system.add(410, ppid: 1, comm: "node", args: ["node", "/opt/homebrew/bin/npm", "run", "dev"], exe: nodeExe,
                   cwd: projectPath)
        system.add(412, ppid: 410, comm: "node", args: ["node", "server.js"], exe: nodeExe, cwd: projectPath)
        system.add(413, ppid: 412, comm: "esbuild", args: ["esbuild"], cwd: projectPath)
        let listener = system.listener(412)

        let plan = KillPlanner.singleProcessPlan(for: listener, currentUID: userUID, ownPID: harnessPID)
        XCTAssertEqual(plan.root.pid, 412)
        XCTAssertEqual(pids(plan.targets), [412])
        XCTAssertEqual(plan.summary, ["node server.js (pid 412) · :5173"])
    }

    // MARK: Heuristics

    func testShellModes() {
        func mode(_ args: [String]?, comm: String = "zsh") -> KillPlanner.ShellMode {
            let basic = ProcessBasic(pid: 10, ppid: 1, pgid: 10, uid: userUID, comm: comm, startTime: 1)
            let details = args.map { ProcessDetails(identity: basic.identity, executablePath: "/bin/\(comm)",
                                                    arguments: $0, environment: [:], cwd: nil) }
            return KillPlanner.shellMode(basic, details: details)
        }
        XCTAssertEqual(mode(["-zsh"]), .interactive)
        XCTAssertEqual(mode(["zsh"]), .interactive)
        XCTAssertEqual(mode(["/bin/zsh", "-l"]), .interactive)
        XCTAssertEqual(mode(["/bin/zsh", "-i"]), .interactive)
        XCTAssertEqual(mode(nil), .interactive, "unknown arguments are treated as interactive")
        XCTAssertEqual(mode(["/bin/zsh", "-c", "-l", "eval 'x'"]), .command)
        XCTAssertEqual(mode(["/bin/zsh", "-i", "-l", "-c", "env"]), .command)
        XCTAssertEqual(mode(["/bin/zsh", "-i", "script.zsh"]), .interactive)
        XCTAssertEqual(mode(["bash", "-lc", "npm start"], comm: "bash"), .command)
        XCTAssertEqual(mode(["bash", "-o", "pipefail", "./dev.sh"], comm: "bash"), .script("./dev.sh"))
        XCTAssertEqual(mode(["/bin/bash", "./dev.sh"], comm: "bash"), .script("./dev.sh"))
        XCTAssertEqual(mode(["node", "server.js"], comm: "node"), .notShell)
    }

    func testLabels() {
        func label(_ args: [String]) -> String {
            let basic = ProcessBasic(pid: 10, ppid: 1, pgid: 10, uid: userUID, comm: "node", startTime: 1)
            return KillPlanner.label(for: basic, details: ProcessDetails(identity: basic.identity, executablePath: nil,
                                                                         arguments: args, environment: [:], cwd: nil))
        }
        XCTAssertEqual(label(["node", "/opt/homebrew/bin/npm", "run", "dev"]), "npm run dev")
        XCTAssertEqual(label(["node", "/Users/me/app/node_modules/.bin/vite"]), "node vite")
        XCTAssertEqual(label(["/usr/bin/python3", "-m", "http.server", "8000"]), "python3 -m http.server 8000")
        XCTAssertEqual(label(["-zsh"]), "zsh")
    }
}

// MARK: - Other control components (pure parts only; no real launchd, signals or notifications)

final class ControlComponentTests: XCTestCase {

    func testAdminKillCommandGuardsEachPidWithItsStartTime() throws {
        let start: UInt64 = 1_760_000_000_123_456
        let target = ProcessBasic(pid: 4321, ppid: 1, pgid: 4321, uid: rootUID, comm: "nginx", startTime: start)
        let command = try XCTUnwrap(ProcessKiller.adminKillCommand(signalName: "TERM", targets: [target]))
        let expected = try XCTUnwrap(ProcessKiller.psStartString(forMicroseconds: start))
        XCTAssertEqual(command, "[ \"$(echo $(LC_ALL=C /bin/ps -o lstart= -p 4321))\" = '\(expected)' ] && /bin/kill -TERM 4321; exit 0")
        XCTAssertFalse(expected.contains("  "))
        XCTAssertNil(ProcessKiller.adminKillCommand(signalName: "KILL", targets: [
            ProcessBasic(pid: 1, ppid: 0, pgid: 1, uid: 0, comm: "launchd", startTime: start),
        ]), "pid 1 is never part of an admin kill")
    }

    func testLoginItemManagerWritesAndRemovesPlistInTempDirectory() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("PortPilotTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        var calls: [[String]] = []
        let manager = LoginItemManager(
            launchAgentsDirectory: directory.appendingPathComponent("LaunchAgents"),
            executablePath: "/Applications/PortPilot.app/Contents/MacOS/PortPilot",
            uid: 501,
            logFileURL: directory.appendingPathComponent("Logs/portpilot.log"),
            bundleIdentifier: "app.portpilot.PortPilot",
            ownPID: 4242,
            runCommand: { _, arguments in
                calls.append(arguments)
                // `print` reports "loaded, running as another pid" → bootout is expected.
                if arguments.first == "print" { return ShellResult(status: 0, stdout: "\tstate = running\n\tpid = 777\n", stderr: "") }
                return ShellResult(status: 0, stdout: "", stderr: "")
            })

        XCTAssertFalse(manager.isEnabled)
        try manager.setEnabled(true)
        XCTAssertTrue(manager.isEnabled)
        let data = try Data(contentsOf: manager.plistURL)
        let plist = try XCTUnwrap(PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any])
        XCTAssertEqual(plist["Label"] as? String, "app.portpilot.agent")
        XCTAssertEqual(plist["ProgramArguments"] as? [String], ["/Applications/PortPilot.app/Contents/MacOS/PortPilot"])
        XCTAssertEqual(plist["RunAtLoad"] as? Bool, true)
        XCTAssertEqual((plist["KeepAlive"] as? [String: Bool])?["SuccessfulExit"], false)
        XCTAssertEqual(plist["ProcessType"] as? String, "Interactive")
        XCTAssertEqual(plist["LimitLoadToSessionType"] as? String, "Aqua")
        XCTAssertEqual(plist["StandardOutPath"] as? String, directory.appendingPathComponent("Logs/portpilot.log").path)
        XCTAssertEqual(calls, [["enable", "gui/501/app.portpilot.agent"]], "enabling never bootstraps")

        try manager.setEnabled(false)
        XCTAssertFalse(FileManager.default.fileExists(atPath: manager.plistURL.path))
        XCTAssertFalse(manager.isEnabled)
        XCTAssertEqual(calls.dropFirst().map { $0 }, [
            ["disable", "gui/501/app.portpilot.agent"],
            ["print", "gui/501/app.portpilot.agent"],
            ["bootout", "gui/501/app.portpilot.agent"],
        ])
    }

    func testLoginItemManagerNeverBootsOutItself() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("PortPilotTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        var calls: [[String]] = []
        let manager = LoginItemManager(launchAgentsDirectory: directory, executablePath: "/tmp/PortPilot", uid: 501,
                                       logFileURL: directory.appendingPathComponent("portpilot.log"),
                                       bundleIdentifier: nil, ownPID: 777,
                                       runCommand: { _, arguments in
                                           calls.append(arguments)
                                           return ShellResult(status: 0, stdout: "pid = 777\n", stderr: "")
                                       })
        try manager.setEnabled(true)
        try manager.setEnabled(false)
        XCTAssertFalse(calls.contains { $0.first == "bootout" })
    }

    func testLoginItemManagerRepairsMovedApp() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("PortPilotTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let noop: LoginItemManager.CommandRunner = { _, _ in ShellResult(status: 0, stdout: "", stderr: "") }
        let old = LoginItemManager(launchAgentsDirectory: directory, executablePath: "/Old/PortPilot", uid: 501,
                                   logFileURL: directory.appendingPathComponent("p.log"), bundleIdentifier: nil,
                                   runCommand: noop)
        try old.setEnabled(true)
        let moved = LoginItemManager(launchAgentsDirectory: directory, executablePath: "/New/PortPilot", uid: 501,
                                     logFileURL: directory.appendingPathComponent("p.log"), bundleIdentifier: nil,
                                     runCommand: noop)
        XCTAssertFalse(moved.isEnabled)
        moved.repairIfNeeded()
        XCTAssertTrue(moved.isEnabled)
    }

    func testNotifierBaselineAndThrottle() {
        var now = Date(timeIntervalSince1970: 1_000_000)
        let notifier = Notifier(throttleInterval: 60, now: { now })
        func group(_ id: String, _ ports: [UInt16], category: ListenerCategory = .project) -> ListenerGroup {
            let basic = ProcessBasic(pid: 10, ppid: 1, pgid: 10, uid: userUID, comm: "node", startTime: 1)
            return ListenerGroup(id: id, category: category, title: "my-app", subtitle: nil, path: nil,
                                 processes: [makeListener(basic, details: nil, ports: ports)])
        }

        XCTAssertTrue(notifier.pendingNotifications(for: [group("a", [3000])]).isEmpty, "first call is a baseline")
        let first = notifier.pendingNotifications(for: [group("a", [3000, 5173])])
        XCTAssertEqual(first.map(\.title), ["New port opened: :5173"])
        now += 10
        XCTAssertTrue(notifier.pendingNotifications(for: [group("a", [3000, 5173, 5174])]).isEmpty, "throttled")
        XCTAssertTrue(notifier.pendingNotifications(for: [group("a", [3000, 5173, 5174]),
                                                          group("s", [1234], category: .system)]).isEmpty,
                      "system groups never notify")
        now += 61
        XCTAssertEqual(notifier.pendingNotifications(for: [group("a", [3000, 8080])]).map(\.ports), [[8080]])
    }

    func testRelauncherFileNamesAndExecutableLookup() {
        XCTAssertEqual(Relauncher.sanitizedFileName("my-app (Vite) :5173"), "my-app-Vite-5173")
        XCTAssertEqual(Relauncher.sanitizedFileName("../../etc/passwd"), "etc-passwd")
        XCTAssertEqual(Relauncher.sanitizedFileName("…"), "process")
        let record = StoppedRecord(id: UUID(), date: Date(), title: "t", ports: [], cwd: "/tmp", arguments: ["sh", "-c", "true"],
                                   environment: ["PATH": "/nonexistent:/bin"], executablePath: "/nonexistent/sh",
                                   manager: .none)
        XCTAssertEqual(Relauncher.resolveExecutable(for: record, environment: record.environment, workingDirectory: "/tmp"),
                       "/bin/sh")
    }
}
