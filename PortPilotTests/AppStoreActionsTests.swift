import Darwin
import XCTest
@testable import PortPilot

/// AppStore's Stop / Undo / Relaunch / Stop All paths, end to end against throwaway servers the tests start in a
/// sandbox folder (`ActionSandbox`) and always kill. Stores only ever show and stop the tests' own groups, and pm2 and
/// GUI-app control go through stand-ins, so nothing of the user's is touched.
@MainActor
final class AppStoreActionsTests: XCTestCase {
    private var sandbox: ActionSandbox!
    /// Fake project files for the engine's resolver: scans never read real folders. Kept alive here (the resolver
    /// holds it unowned).
    private let fs = ResolverTestFS()

    override func setUp() async throws {
        sandbox = try ActionSandbox()
    }

    override func tearDown() async throws {
        await sandbox?.cleanUpInBackground()
        sandbox = nil
    }

    private func makeEngine() -> ScanEngine {
        ScanEngine(resolver: fs.makeResolver(home: ProjectResolver.parent(of: sandbox.root)))
    }

    private var testSettings: AppSettings {
        var settings = AppSettings()
        settings.gracefulTimeout = 1
        return settings
    }

    /// A store showing only the groups that hold `ports`, with relaunch logs kept in the sandbox.
    private func makeStore(engine: ScanEngine, ports: Set<UInt16>, settings: AppSettings? = nil,
                           pm2: PM2Commands? = nil) async -> AppStore {
        let output = await engine.scan(includeOtherUsers: false)
        let store = AppStore(engine: engine, initial: ActionSandbox.output(output, keepingPorts: ports),
                             settings: settings ?? testSettings, pm2: pm2)
        store.relaunchLogDirectory = URL(fileURLWithPath: sandbox.root + "/relaunch-logs", isDirectory: true)
        store.relaunchPortTimeout = 15
        return store
    }

    // MARK: Undo / Relaunch

    /// Finding #3 / #43: Undo after stopping `npm run dev` must really start the server again. npm rewrites its argv
    /// into the title "npm run dev"; the record holds the real command below it instead, and Undo reports success
    /// only once the port listens again.
    func testUndoRelaunchesAnNpmServerAndWaitsForItsPort() async throws {
        guard let npm = ActionSandbox.npm, ActionSandbox.node != nil else { throw XCTSkip("npm is not installed") }
        let port = try sandbox.freePort()
        let project = try sandbox.folder("web")
        let manifest = #"{"name":"pp-selftest-web","version":"1.0.0","private":true,"scripts":{"dev":"node server.js"}}"#
        try sandbox.write(manifest, to: "web/package.json")
        try sandbox.write("""
            const http = require('http');
            http.createServer((req, res) => res.end('ok')).listen(Number(process.env.PORT), '127.0.0.1');
            """, to: "web/server.js")
        fs.addFile(project + "/package.json", manifest)
        try sandbox.spawn(npm, ["npm", "run", "dev"], in: project, environment: ["PORT": String(port)])
        let server = try await sandbox.waitForListener(on: port)

        let engine = makeEngine()
        let store = await makeStore(engine: engine, ports: [port])
        let group = try XCTUnwrap(store.snapshot.groups.first { $0.ports.contains(port) })
        XCTAssertEqual(group.category, .project)

        await store.stop(group)?.value
        let stopBanner = try XCTUnwrap(store.banner)
        XCTAssertEqual(stopBanner.style, .success, stopBanner.message)
        let isFree = await sandbox.waitUntilFree(port)
        XCTAssertTrue(isFree)
        XCTAssertFalse(sandbox.isAlive(server))

        let record = try XCTUnwrap(store.recentlyStopped.first)
        XCTAssertNotEqual(record.arguments.first, "npm run dev", "never npm's process title: \(record.arguments)")
        XCTAssertFalse(Relauncher.isTitleRewritten(record.arguments, executablePath: record.executablePath))
        XCTAssertEqual(record.cwd, project)
        XCTAssertEqual(record.ports, [port])
        XCTAssertEqual(record.environment["PORT"], String(port), "npm's environment is kept")
        XCTAssertEqual(stopBanner.action, .relaunch(recordID: record.id))
        XCTAssertEqual(stopBanner.actionTitle, "Undo")

        await store.performBannerAction(stopBanner)?.value
        let banner = try XCTUnwrap(store.banner)
        XCTAssertEqual(banner.style, .success, banner.message)
        XCTAssertTrue(banner.message.contains(":\(port)"), banner.message)
        XCTAssertFalse(sandbox.listeners(on: port).isEmpty, "the server really listens again")
        XCTAssertFalse(store.recentlyStopped.contains { $0.id == record.id })
        XCTAssertTrue(store.relaunchingRecordIDs.isEmpty)
    }

    /// No false success: a relaunch whose process exits right away (its port is taken) reports the failure and keeps
    /// the record so the command can still be copied or retried.
    func testRelaunchThatExitsReportsItAndKeepsTheRecord() async throws {
        let port = try sandbox.freePort()
        let directory = try sandbox.folder("files")
        fs.addFile(directory + "/pyproject.toml", "[project]\nname = \"files\"\n")
        let server = try sandbox.startHTTPServer(port: port, in: directory)
        _ = try await sandbox.waitForListener(on: port)

        let store = await makeStore(engine: makeEngine(), ports: [port])
        let group = try XCTUnwrap(store.snapshot.groups.first { $0.ports.contains(port) })
        await store.stop(group)?.value
        XCTAssertFalse(sandbox.isAlive(server))
        let record = try XCTUnwrap(store.recentlyStopped.first)

        // Something else takes the port, so the relaunched http.server fails to bind and exits.
        let blocker = try sandbox.startStubbornListener(port: port, in: directory)
        _ = try await sandbox.waitForListener(on: port)
        await store.relaunch(record)?.value
        let banner = try XCTUnwrap(store.banner)
        XCTAssertEqual(banner.style, .error, banner.message)
        XCTAssertTrue(banner.message.hasPrefix("Couldn't relaunch"), banner.message)
        XCTAssertTrue(store.recentlyStopped.contains { $0.id == record.id }, "kept for another try")
        XCTAssertEqual(sandbox.listeners(on: port).map(\.pid), [blocker])
    }

    /// C2: Undo of a Stop that ended several servers relaunches all of them, not only the first.
    func testUndoRelaunchesEveryServerTheStopEnded() async throws {
        let first = try sandbox.freePort()
        let second = try sandbox.freePort()
        let project = try sandbox.folder("suite")
        fs.addFile(project + "/pyproject.toml", "[project]\nname = \"suite\"\n")
        try sandbox.startHTTPServer(port: first, in: project)
        try sandbox.startHTTPServer(port: second, in: project)
        _ = try await sandbox.waitForListener(on: first)
        _ = try await sandbox.waitForListener(on: second)

        let store = await makeStore(engine: makeEngine(), ports: [first, second])
        let group = try XCTUnwrap(store.snapshot.groups.first { $0.ports.contains(first) })
        XCTAssertEqual(Set(group.ports), [first, second], "one project group with both servers")
        await store.stop(group)?.value
        XCTAssertEqual(store.recentlyStopped.count, 2)
        let banner = try XCTUnwrap(store.banner)
        guard case .relaunch(let id, let more) = banner.action else { return XCTFail("no Undo: \(banner.message)") }
        XCTAssertEqual(Set([id] + more), Set(store.recentlyStopped.map(\.id)))

        await store.performBannerAction(banner)?.value
        XCTAssertEqual(store.banner?.style, .success, store.banner?.message ?? "")
        XCTAssertFalse(sandbox.listeners(on: first).isEmpty)
        XCTAssertFalse(sandbox.listeners(on: second).isEmpty)
        XCTAssertTrue(store.recentlyStopped.isEmpty)
    }

    // MARK: Apps and macOS services (U1, U2)

    /// An app is asked to quit (⌘Q), never signalled: when it doesn't quit in time (a save dialog), PortPilot says so
    /// and leaves it running. No Recently Stopped record, no Undo.
    func testAppIsAskedToQuitAndNeverForceKilled() async throws {
        let port = try sandbox.freePort()
        let helperPort = try sandbox.freePort()
        let app = try sandbox.startStubbornListener(port: port, in: sandbox.root)
        let helper = try sandbox.startHTTPServer(port: helperPort, in: try sandbox.folder("helper"))
        _ = try await sandbox.waitForListener(on: port)
        _ = try await sandbox.waitForListener(on: helperPort)
        let store = await makeStore(engine: makeEngine(), ports: [port, helperPort])
        var asked: [Int32] = []
        // The main process is a GUI app that shows a save dialog; the helper isn't an app.
        store.askAppToQuit = { pid in asked.append(pid); return pid == app ? true : nil }
        let group = ListenerGroup(id: "app:/Applications/Fake.app", category: .app, title: "Fake", subtitle: nil,
                                  path: nil, processes: [try sandbox.listener(pid: helper, category: .app, name: "Helper"),
                                                         try sandbox.listener(pid: app, category: .app, name: "Fake")])

        await store.stop(group)?.value
        XCTAssertEqual(Set(asked), [app, helper])
        XCTAssertTrue(sandbox.isAlive(app), "never force-killed")
        XCTAssertTrue(sandbox.isAlive(helper), "its helpers are left alone while it asks to save")
        let banner = try XCTUnwrap(store.banner)
        XCTAssertTrue(banner.message.hasPrefix("Asked Fake to quit"), banner.message)
        XCTAssertNil(banner.action)
        XCTAssertTrue(store.recentlyStopped.isEmpty)
    }

    /// An app that quits when asked is reported as quit, still with no record or Undo.
    func testAppThatQuitsWhenAskedIsReportedAsQuit() async throws {
        let port = try sandbox.freePort()
        let directory = try sandbox.folder("app")
        let app = try sandbox.startHTTPServer(port: port, in: directory)
        _ = try await sandbox.waitForListener(on: port)
        let store = await makeStore(engine: makeEngine(), ports: [port])
        store.askAppToQuit = { pid in kill(pid, SIGTERM) == 0 }   // the app's own Quit
        let group = ListenerGroup(id: "app:/Applications/Fake.app", category: .app, title: "Fake", subtitle: nil,
                                  path: nil, processes: [try sandbox.listener(pid: app, category: .app, name: "Fake")])

        await store.stop(group)?.value
        let banner = try XCTUnwrap(store.banner)
        XCTAssertEqual(banner.message, "Quit Fake (:\(port))")
        XCTAssertNil(banner.action, "no Undo for apps")
        XCTAssertTrue(store.recentlyStopped.isEmpty)
        XCTAssertFalse(sandbox.isAlive(app))
    }

    /// App helpers (not a GUI app's main process) and macOS services get SIGTERM only: a plain Stop never escalates
    /// to SIGKILL for them. Force Kill still works.
    func testAppHelpersAndSystemServicesAreNeverSIGKILLedByAPlainStop() async throws {
        for category in [ListenerCategory.app, .system] {
            let port = try sandbox.freePort()
            let helper = try sandbox.startStubbornListener(port: port, in: sandbox.root)
            _ = try await sandbox.waitForListener(on: port)
            let store = await makeStore(engine: makeEngine(), ports: [port])
            store.askAppToQuit = { _ in nil }   // not a GUI app
            let group = ListenerGroup(id: "\(category.rawValue):helper", category: category, title: "Helper",
                                      subtitle: nil, path: nil,
                                      processes: [try sandbox.listener(pid: helper, category: category, name: "Helper")])

            await store.stop(group)?.value
            XCTAssertTrue(sandbox.isAlive(helper), "\(category): no SIGKILL")
            let banner = try XCTUnwrap(store.banner)
            XCTAssertEqual(banner.style, .error)
            XCTAssertTrue(banner.message.contains("Still running — use Force Kill"), banner.message)
            XCTAssertTrue(store.recentlyStopped.isEmpty, "\(category): no record")

            await store.stop(group, mode: .force)?.value
            let gone = await sandbox.waitUntilFree(port)
            XCTAssertTrue(gone, "\(category): Force Kill ends it")
            XCTAssertTrue(store.recentlyStopped.isEmpty, "\(category): still no record")
            XCTAssertNil(store.banner?.action)
        }
    }

    // MARK: Stop All Projects

    /// One banner for the whole Stop All, and it stops exactly the projects the footer counts (hidden ones excluded).
    func testStopAllProjectsStopsWhatItCountsAndReportsOnce() async throws {
        var ports: [UInt16] = []
        var servers: [String: pid_t] = [:]
        for name in ["alpha", "beta", "gamma", "hidden"] {
            let port = try sandbox.freePort()
            let project = try sandbox.folder(name)
            fs.addFile(project + "/pyproject.toml", "[project]\nname = \"\(name)\"\n")
            servers[name] = try sandbox.startHTTPServer(port: port, in: project)
            ports.append(port)
        }
        for port in ports { _ = try await sandbox.waitForListener(on: port) }

        var settings = testSettings
        settings.ignoredGroupIDs = ["project:" + sandbox.root + "/hidden"]
        let store = await makeStore(engine: makeEngine(), ports: Set(ports), settings: settings)
        XCTAssertEqual(store.snapshot.groups.filter { $0.category == .project }.count, 4)
        XCTAssertEqual(store.stoppableProjects.map(\.title).sorted(), ["alpha", "beta", "gamma"],
                       "the footer's count leaves the hidden project out")

        var banners: [Banner] = []
        let observation = BannerRecorder(store: store) { banners.append($0) }
        await store.stopAllProjects()?.value
        observation.stop()

        XCTAssertEqual(banners.count, 1, "one aggregated banner: \(banners.map(\.message))")
        let banner = try XCTUnwrap(store.banner)
        XCTAssertTrue(banner.message.hasPrefix("Stopped 3 projects"), banner.message)
        XCTAssertEqual(store.recentlyStopped.count, 3)
        guard case .relaunch(let id, let more) = banner.action else { return XCTFail("no Undo: \(banner.message)") }
        XCTAssertEqual(Set([id] + more), Set(store.recentlyStopped.map(\.id)))
        for name in ["alpha", "beta", "gamma"] { XCTAssertFalse(sandbox.isAlive(servers[name] ?? 0), name) }
        XCTAssertTrue(sandbox.isAlive(servers["hidden"] ?? 0), "hidden projects are left alone")
        XCTAssertTrue(store.busyGroupIDs.isEmpty)
    }

    // MARK: Stop right after a restart (E1(b), finding #7)

    /// The server was restarted in a new process (not in the old tree) after the scan the row came from: Stop scans
    /// again and stops the new one instead of reporting "already exited".
    func testStopAfterARestartOutsideTheOldTreeRescansAndStopsTheNewServer() async throws {
        let port = try sandbox.freePort()
        let directory = try sandbox.folder("restarted")
        let old = try sandbox.startHTTPServer(port: port, in: directory)
        _ = try await sandbox.waitForListener(on: port)
        let row = try sandbox.listener(pid: old, name: "http.server")
        let group = ListenerGroup(id: "pid:\(row.id)", category: .service, title: "http.server", subtitle: nil,
                                  path: directory, processes: [row])
        kill(old, SIGKILL)
        let isFree = await sandbox.waitUntilFree(port)
        XCTAssertTrue(isFree)
        let new = try sandbox.startHTTPServer(port: port, in: directory)
        _ = try await sandbox.waitForListener(on: port)

        let store = await makeStore(engine: makeEngine(), ports: [port])
        await store.stop(group)?.value
        let banner = try XCTUnwrap(store.banner)
        XCTAssertEqual(banner.style, .success, banner.message)
        XCTAssertFalse(sandbox.isAlive(new), "the restarted server was stopped")
    }

    /// Nothing of the server is left: "already exited" (not an error). Another program on the port is named and
    /// left running.
    func testStopOfAnExitedServerSaysSoAndNeverTouchesAnotherProgramOnItsPort() async throws {
        let port = try sandbox.freePort()
        let directory = try sandbox.folder("gone")
        let old = try sandbox.startHTTPServer(port: port, in: directory)
        _ = try await sandbox.waitForListener(on: port)
        let row = try sandbox.listener(pid: old, name: "http.server")
        let group = ListenerGroup(id: "pid:\(row.id)", category: .service, title: "http.server", subtitle: nil,
                                  path: directory, processes: [row])
        kill(old, SIGKILL)
        _ = await sandbox.waitUntilFree(port)

        let store = await makeStore(engine: makeEngine(), ports: [port])
        await store.stop(group)?.value
        XCTAssertEqual(store.banner?.style, .info)
        XCTAssertEqual(store.banner?.message, "http.server had already exited")

        let other = try sandbox.startStubbornListener(port: port, in: try sandbox.folder("elsewhere"))
        _ = try await sandbox.waitForListener(on: port)
        await store.stop(group)?.value
        let banner = try XCTUnwrap(store.banner)
        XCTAssertEqual(banner.style, .error)
        XCTAssertTrue(banner.message.contains("already exited") && banner.message.contains("now uses its port"),
                      banner.message)
        XCTAssertTrue(sandbox.isAlive(other), "a different program on the port is never stopped")
    }

    /// `node --watch` replaces its server on every save. A Stop clicked right after a save stops the watcher and the
    /// new server.
    func testStopRightAfterANodeWatchRestartStopsTheNewServer() async throws {
        guard let node = ActionSandbox.node else { throw XCTSkip("node is not installed") }
        let port = try sandbox.freePort()
        let project = try sandbox.folder("watched")
        let manifest = #"{"name":"pp-selftest-watched","version":"1.0.0","private":true}"#
        try sandbox.write(manifest, to: "watched/package.json")
        fs.addFile(project + "/package.json", manifest)
        let source = """
            require('http').createServer((q, s) => s.end('ok')).listen(Number(process.env.PORT), '127.0.0.1');
            """
        try sandbox.write(source, to: "watched/server.js")
        let watcher = try sandbox.spawn(node, ["node", "--watch", "server.js"], in: project,
                                        environment: ["PORT": String(port)])
        let first = try await sandbox.waitForListener(on: port)

        let store = await makeStore(engine: makeEngine(), ports: [port])
        let group = try XCTUnwrap(store.snapshot.groups.first { $0.ports.contains(port) })
        // A save in place (same file), as an editor does.
        let handle = try FileHandle(forWritingTo: URL(fileURLWithPath: project + "/server.js"))
        try handle.seekToEnd()
        try handle.write(contentsOf: Data("\n// saved\n".utf8))
        try handle.close()
        let second = try await sandbox.waitForListener(on: port, other: first)

        await store.stop(group)?.value
        let banner = try XCTUnwrap(store.banner)
        XCTAssertEqual(banner.style, .success, banner.message)
        XCTAssertFalse(sandbox.isAlive(second))
        XCTAssertFalse(sandbox.isAlive(watcher), "the watcher would start it again")
        let isFree = await sandbox.waitUntilFree(port)
        XCTAssertTrue(isFree)
    }

    // MARK: pm2 (finding #9, C4)

    /// pm2 rows (a cluster app's row is the PM2 daemon) stop through pm2, never by signal: Stop runs `pm2 stop`,
    /// Stop & Disable `pm2 delete`, and the banner passes on what happened to pm2's saved list.
    func testPM2RowsStopThroughPM2AndAreNeverSignalled() async throws {
        let port = try sandbox.freePort()
        let standIn = try sandbox.startHTTPServer(port: port, in: sandbox.root)
        _ = try await sandbox.waitForListener(on: port)
        var commands: [String] = []
        let pm2 = PM2Commands(stop: { commands.append("stop \($0)") },
                              delete: { id, name in
                                  commands.append("delete \(id) \(name)")
                                  return .unavailable("read-only")
                              })
        let store = await makeStore(engine: makeEngine(), ports: [port], pm2: pm2)
        let row = try sandbox.listener(pid: standIn, manager: .pm2(id: 7, name: "api"), name: "api")
        let group = ListenerGroup(id: "pm2:api", category: .project, title: "api", subtitle: nil, path: nil,
                                  processes: [row, row])

        await store.stop(group)?.value
        XCTAssertEqual(commands, ["stop 7"], "once per app")
        XCTAssertEqual(store.banner?.message, "Stopped api (:\(port)) · pm2 api stopped")
        XCTAssertTrue(sandbox.isAlive(standIn), "pm2 rows are never signalled")
        XCTAssertTrue(store.recentlyStopped.isEmpty)

        await store.stopAndDisableAutoStart(group)?.value
        XCTAssertEqual(commands, ["stop 7", "delete 7 api"])
        let message = store.banner?.message ?? ""
        XCTAssertTrue(message.contains("pm2 api removed — pm2's saved list wasn't updated"), message)
        XCTAssertTrue(sandbox.isAlive(standIn))
    }
}

/// Records every banner a store shows while it runs (Observation), to check that Stop All shows exactly one.
@MainActor
private final class BannerRecorder {
    private let store: AppStore
    private let onChange: (Banner) -> Void
    private var isActive = true

    init(store: AppStore, onChange: @escaping (Banner) -> Void) {
        self.store = store
        self.onChange = onChange
        observe()
    }

    func stop() { isActive = false }

    private func observe() {
        withObservationTracking {
            _ = store.banner
        } onChange: { [weak self] in
            Task { @MainActor in
                guard let self, self.isActive else { return }
                if let banner = self.store.banner { self.onChange(banner) }
                self.observe()
            }
        }
    }
}
