import Darwin
import XCTest
@testable import PortPilot

/// End-to-end checks of ScanEngine against real throwaway processes started (and killed) by the test itself:
/// `make serve` → `sh -c "while true; do python3 -m http.server …; done"` → python, i.e. a runner whose server
/// gets replaced, like nodemon / `node --watch` / uvicorn --reload do on every save.
final class ScanEngineTests: XCTestCase {
    private var tree: ThrowawayServerTree?
    /// Keeps the fake file system alive for the engine's resolver (it holds it unowned).
    private let fs = ResolverTestFS()

    override func tearDown() {
        tree?.kill()
        tree = nil
        super.tearDown()
    }

    /// The resolver never touches the real disk, so scans can't wait on privacy prompts in the test host. It knows
    /// one project: the tree's folder with its Makefile (make itself is a launch anchor as part of that project).
    private func makeEngine() -> ScanEngine {
        guard let tree else { return ScanEngine(resolver: fs.makeResolver()) }
        fs.addFile(tree.directory + "/Makefile", "serve:\n")
        return ScanEngine(resolver: fs.makeResolver(home: ProjectResolver.parent(of: tree.directory)))
    }

    func testStopRightAfterARestartTargetsTheReplacementServer() async throws {
        let tree = try startTree()
        let first = try tree.waitForServer()
        let engine = makeEngine()
        let output = await engine.scan(includeOtherUsers: false)
        let listener = try XCTUnwrap(output.snapshot.groups.flatMap(\.processes).first { $0.ports.contains(tree.port) })
        XCTAssertEqual(listener.basic.pid, first)
        XCTAssertEqual(output.plans[listener.id]?.root.pid, tree.makePID, "make is the runner, so it is the plan root")

        // The runner replaces the server (a watcher restart) after the scan the UI is showing.
        Darwin.kill(first, SIGKILL)
        let second = try tree.waitForServer(other: first)

        let plans = await engine.freshPlans(for: [listener], onlyThisProcess: false)
        XCTAssertEqual(plans.count, 1, "the server still runs, so Stop must not report 'already exited'")
        let plan = try XCTUnwrap(plans.first)
        XCTAssertEqual(plan.root.pid, tree.makePID)
        XCTAssertTrue(plan.targets.contains { $0.pid == second }, "the replacement server is stopped: \(plan.summary)")
        XCTAssertFalse(plan.targets.contains { $0.pid == first })
        XCTAssertTrue(plan.summary.contains { $0.contains(":\(tree.port)") }, "\(plan.summary)")
    }

    func testStopWhileTheReplacementIsStartingTargetsTheLaunchRoot() async throws {
        let tree = try startTree(restartDelay: 3)
        let first = try tree.waitForServer()
        let engine = makeEngine()
        let output = await engine.scan(includeOtherUsers: false)
        let listener = try XCTUnwrap(output.snapshot.groups.flatMap(\.processes).first { $0.ports.contains(tree.port) })

        Darwin.kill(first, SIGKILL)
        try tree.waitUntilGone(first)
        let plans = await engine.freshPlans(for: [listener], onlyThisProcess: false)
        let plan = try XCTUnwrap(plans.first, "the runner is alive: stop it like the original plan would have")
        XCTAssertEqual(plan.root.pid, tree.makePID)
        XCTAssertTrue(plan.targets.contains { $0.pid == tree.makePID })
        XCTAssertFalse(plan.targets.contains { $0.pid == first })
    }

    func testWatcherParentIsSearchedWhenThereIsNoScanTimeRoot() async throws {
        let tree = try startTree()
        let first = try tree.waitForServer()
        let table = ProcessTable(processes: SysProc.allProcesses())
        let basic = try XCTUnwrap(table[first])
        let sockets = try XCTUnwrap(SysProc.listeningTCPSockets(pid: first))
        // A row from a scan this engine never ran (no remembered root), supervised by a watcher.
        let listener = ListenerProcess(basic: basic, details: SysProc.details(for: basic), sockets: sockets,
                                       usage: .zero, treeUsage: .zero, category: .service, project: nil,
                                       displayName: "python -m http.server", frameworks: [], origin: nil,
                                       manager: .watcher(name: "make"), appName: nil, isRestricted: false)
        let engine = makeEngine()
        Darwin.kill(first, SIGKILL)
        let second = try tree.waitForServer(other: first)
        let plans = await engine.freshPlans(for: [listener], onlyThisProcess: false)
        let plan = try XCTUnwrap(plans.first)
        XCTAssertTrue(plan.targets.contains { $0.pid == second })
    }

    func testListenerWhoseTreeIsGoneGetsNoPlan() async throws {
        let tree = try startTree()
        _ = try tree.waitForServer()
        let engine = makeEngine()
        let output = await engine.scan(includeOtherUsers: false)
        let listener = try XCTUnwrap(output.snapshot.groups.flatMap(\.processes).first { $0.ports.contains(tree.port) })
        tree.kill()
        try tree.waitUntilGone(tree.makePID)
        let plans = await engine.freshPlans(for: [listener], onlyThisProcess: false)
        XCTAssertTrue(plans.isEmpty, "\(plans.map(\.summary))")
    }

    func testScanCountsTheRunnerInTheGroupUsage() async throws {
        let tree = try startTree()
        _ = try tree.waitForServer()
        let engine = makeEngine()
        _ = await engine.scan(includeOtherUsers: false)
        let output = await engine.scan(includeOtherUsers: false)
        let group = try XCTUnwrap(output.snapshot.groups.first { $0.ports.contains(tree.port) })
        let listener = try XCTUnwrap(group.processes.first)
        // make and the `sh -c` loop are sampled on demand and counted once, on top of the server's own tree.
        XCTAssertGreaterThan(group.extraUsage.memoryBytes, 0)
        XCTAssertEqual(group.usage.memoryBytes, listener.treeUsage.memoryBytes + group.extraUsage.memoryBytes)
    }

    // MARK: PM2 cluster rows

    func testPM2ClusterRowIsNeverSignalled() async throws {
        let daemon = ClassifierFixture(pid: 4242, executable: "/opt/homebrew/bin/node",
                                       arguments: ["PM2 v5.4.3: God Daemon (/Users/test/.pm2)"])
        let row = listener(daemon, manager: .pm2(id: 3, name: "api"))
        let plan = try XCTUnwrap(ScanEngine.clusterAppPlan(for: row))
        XCTAssertTrue(plan.targets.isEmpty, "the daemon runs every pm2 app")
        XCTAssertEqual(plan.warnings, ["pm2 runs api in cluster mode, so only pm2 can stop it"])

        let engine = makeEngine()
        for onlyThisProcess in [true, false] {
            let plans = await engine.freshPlans(for: [row], onlyThisProcess: onlyThisProcess)
            XCTAssertEqual(plans.count, 1)
            XCTAssertEqual(plans.first?.targets.count, 0, "onlyThisProcess: \(onlyThisProcess)")
        }

        // A fork-mode app's own process, and a daemon row that pm2 does not route, are planned as usual.
        let worker = ClassifierFixture(pid: 4243, ppid: 4242, executable: "/opt/homebrew/bin/node", arguments: ["node", "app.js"])
        XCTAssertNil(ScanEngine.clusterAppPlan(for: listener(worker, manager: .pm2(id: 1, name: "web"))))
        XCTAssertNil(ScanEngine.clusterAppPlan(for: listener(daemon, manager: .none)))
    }

    private func listener(_ fixture: ClassifierFixture, manager: ProcessManager) -> ListenerProcess {
        ListenerProcess(basic: fixture.basic, details: fixture.details,
                        sockets: [ListeningSocket(port: 3000, address: "127.0.0.1", family: .ipv4, pid: fixture.basic.pid)],
                        usage: .zero, treeUsage: .zero, category: .project, project: nil, displayName: "x",
                        frameworks: [], origin: nil, manager: manager, appName: nil, isRestricted: false)
    }

    // MARK: Headless scans and folder-access prompts

    /// While macOS asks for access to ~/Downloads, project lookups there block. A scan reports the folder and shows
    /// the server provisionally; the headless scan waits for the lookups and gives the real project.
    func testHeadlessScanWaitsForProjectsBehindAFolderPrompt() throws {
        let tree = try startTree(subpath: "Downloads/app/server")
        _ = try tree.waitForServer()
        let home = tree.container
        fs.addDirectory(home + "/Downloads/app/.git")
        fs.addFile(tree.directory + "/Makefile", "serve:\n")
        fs.blockProbes(under: home + "/Downloads")
        defer { fs.releaseBlockedProbes() }
        let engine = ScanEngine(resolver: fs.makeResolver(home: home, probeDeadline: 0.2))

        let pending = engine.scanBlocking(includeOtherUsers: false, probeTimeout: 0)
        XCTAssertEqual(pending.foldersAwaitingAccess, [home + "/Downloads"])
        let provisional = try XCTUnwrap(pending.snapshot.groups.first { $0.ports.contains(tree.port) })
        XCTAssertEqual(provisional.path, tree.directory, "provisionally the server's own folder")

        DispatchQueue.global().asyncAfter(deadline: .now() + 0.3) { [fs] in fs.releaseBlockedProbes() }
        let settled = engine.scanBlocking(includeOtherUsers: false)
        XCTAssertEqual(settled.foldersAwaitingAccess, [])
        let group = try XCTUnwrap(settled.snapshot.groups.first { $0.ports.contains(tree.port) })
        XCTAssertEqual(group.id, "project:" + home + "/Downloads/app", "the real project once access is granted")
    }

    private func startTree(restartDelay: Double = 0.1, subpath: String? = nil) throws -> ThrowawayServerTree {
        let tree = try ThrowawayServerTree(restartDelay: restartDelay, subpath: subpath)
        self.tree = tree
        return tree
    }
}

/// `make` → `sh -c` loop → `python3 -m http.server <port>` in its own process group, in a temporary folder.
private final class ThrowawayServerTree {
    let port: UInt16
    let makePID: pid_t
    /// Temporary folder holding everything (symlinks resolved, as processes report their cwd).
    let container: String
    /// The tree's working directory: `container`, or the given subpath inside it.
    let directory: String
    private var killed = false

    init(restartDelay: Double = 0.1, subpath: String? = nil) throws {
        let python = ["/opt/homebrew/bin/python3", "/usr/local/bin/python3", "/usr/bin/python3"]
            .first { FileManager.default.isExecutableFile(atPath: $0) }
        guard let python else { throw XCTSkip("python3 is not installed") }
        guard FileManager.default.isExecutableFile(atPath: "/usr/bin/make") else { throw XCTSkip("make is not installed") }
        port = try Self.freePort()
        let created = FileManager.default.temporaryDirectory
            .appendingPathComponent("portpilot-engine-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: created, withIntermediateDirectories: true)
        // realpath keeps "/private" (URL/NSString symlink resolution strips it), matching what the kernel reports.
        guard let resolved = realpath(created.path, nil) else { throw XCTSkip("realpath failed") }
        let container = String(cString: resolved)
        free(resolved)
        self.container = container
        directory = subpath.map { container + "/" + $0 } ?? container
        try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
        let folder = URL(fileURLWithPath: directory, isDirectory: true)
        let makefile = "serve:\n\twhile true; do \(python) -m http.server \(port) --bind 127.0.0.1 >/dev/null 2>&1; "
            + "sleep \(restartDelay); done\n"
        try makefile.write(to: folder.appendingPathComponent("Makefile"), atomically: true, encoding: .utf8)
        makePID = try Self.spawnInOwnProcessGroup("/usr/bin/make", ["make", "-s", "-C", directory, "serve"])
    }

    deinit { kill() }

    /// Kills the whole tree (its own process group) and removes the folder. Idempotent.
    func kill() {
        guard !killed else { return }
        killed = true
        Darwin.kill(-makePID, SIGKILL)
        var status: Int32 = 0
        _ = waitpid(makePID, &status, 0)
        try? FileManager.default.removeItem(atPath: container)
    }

    /// Waits until a process of the tree (other than `other`) listens on `port`; returns its pid.
    func waitForServer(other: pid_t? = nil, timeout: TimeInterval = 15) throws -> pid_t {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            let table = ProcessTable(processes: SysProc.allProcesses())
            for process in table.descendants(of: makePID) where process.pid != other {
                if SysProc.listeningTCPSockets(pid: process.pid)?.contains(where: { $0.port == port }) == true {
                    return process.pid
                }
            }
            Thread.sleep(forTimeInterval: 0.05)
        }
        throw XCTSkip("the throwaway server did not start listening on :\(port)")
    }

    func waitUntilGone(_ pid: pid_t, timeout: TimeInterval = 5) throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if SysProc.basic(pid: pid) == nil { return }
            Thread.sleep(forTimeInterval: 0.02)
        }
        XCTFail("pid \(pid) did not exit")
    }

    private static func freePort() throws -> UInt16 {
        let fd = socket(AF_INET, SOCK_STREAM, IPPROTO_TCP)
        guard fd >= 0 else { throw XCTSkip("socket() failed") }
        defer { close(fd) }
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let bound = withUnsafeMutablePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(fd, $0, length) == 0 && getsockname(fd, $0, &length) == 0
            }
        }
        guard bound else { throw XCTSkip("bind() failed") }
        return UInt16(bigEndian: address.sin_port)
    }

    private static func spawnInOwnProcessGroup(_ path: String, _ arguments: [String]) throws -> pid_t {
        var attributes: posix_spawnattr_t?
        posix_spawnattr_init(&attributes)
        defer { posix_spawnattr_destroy(&attributes) }
        posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_SETPGROUP))
        posix_spawnattr_setpgroup(&attributes, 0)
        var actions: posix_spawn_file_actions_t?
        posix_spawn_file_actions_init(&actions)
        defer { posix_spawn_file_actions_destroy(&actions) }
        posix_spawn_file_actions_addopen(&actions, 0, "/dev/null", O_RDONLY, 0)
        posix_spawn_file_actions_addopen(&actions, 1, "/dev/null", O_WRONLY, 0)
        posix_spawn_file_actions_addopen(&actions, 2, "/dev/null", O_WRONLY, 0)
        let argv: [UnsafeMutablePointer<CChar>?] = arguments.map { strdup($0) } + [nil]
        defer { argv.forEach { free($0) } }
        var pid: pid_t = 0
        let status = posix_spawn(&pid, path, &actions, &attributes, argv, environ)
        guard status == 0 else { throw XCTSkip("posix_spawn failed: \(status)") }
        return pid
    }
}
