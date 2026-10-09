import Darwin
import Observation
import SwiftUI
import XCTest
@testable import PortPilot

// Tests for the scan pipeline: idle cost with the panel closed (skipped ticks, no observed-state churn, lazy kill
// plans), the control queue, "Still running · no open port", the folder-access notice and Launch at login.
// Process-level tests only start and signal their own throwaway processes, in a temporary folder.

// MARK: - Pure rules

final class PipelineRuleTests: XCTestCase {
    private func basic(_ pid: Int32, ppid: Int32 = 1, start: UInt64 = 1_000, comm: String = "node") -> ProcessBasic {
        ProcessBasic(pid: pid, ppid: ppid, pgid: pid, uid: 501, comm: comm, startTime: start)
    }

    private func listener(_ pid: Int32, ports: [UInt16], ppid: Int32 = 1, uid: UInt32 = 501) -> ListenerProcess {
        let process = ProcessBasic(pid: pid, ppid: ppid, pgid: pid, uid: uid, comm: "node", startTime: UInt64(pid))
        return ListenerProcess(basic: process, details: nil,
                               sockets: ports.map { ListeningSocket(port: $0, address: "127.0.0.1", family: .ipv4, pid: pid) },
                               usage: .zero, treeUsage: .zero, category: .project, project: nil, displayName: "node",
                               frameworks: [], origin: nil, manager: .none, appName: nil, isRestricted: false)
    }

    private func group(_ id: String, _ processes: [ListenerProcess], category: ListenerCategory = .project) -> ListenerGroup {
        ListenerGroup(id: id, category: category, title: id, subtitle: nil, path: nil, processes: processes)
    }

    // MARK: Launch at login

    func testLaunchAtLoginSwitchShowsTheTruthForCopiesThatCannotManageIt() {
        // A copy in DerivedData / dist/ never claims an agent it can't write, even on first run.
        XCTAssertFalse(AppStore.initialLaunchAtLogin(canManage: false, isEnabled: false, hasStoredSettings: false, requested: true))
        XCTAssertFalse(AppStore.initialLaunchAtLogin(canManage: false, isEnabled: false, hasStoredSettings: true, requested: true))
        XCTAssertTrue(AppStore.initialLaunchAtLogin(canManage: false, isEnabled: true, hasStoredSettings: true, requested: false))
        // The installed copy turns it on by default on first run (start() writes the agent) and otherwise shows
        // whether the agent is there.
        XCTAssertTrue(AppStore.initialLaunchAtLogin(canManage: true, isEnabled: false, hasStoredSettings: false, requested: true))
        XCTAssertFalse(AppStore.initialLaunchAtLogin(canManage: true, isEnabled: false, hasStoredSettings: true, requested: true))
        XCTAssertTrue(AppStore.initialLaunchAtLogin(canManage: true, isEnabled: true, hasStoredSettings: true, requested: false))
    }

    // MARK: Menu bar count and plan comparison

    func testMenuBarCountCountsDistinctProjectPortsTheUserDidNotHide() {
        let groups = [group("project:/a", [listener(10, ports: [3000, 3001]), listener(11, ports: [3001])]),
                      group("project:/b", [listener(12, ports: [5173])]),
                      group("pid:13", [listener(13, ports: [8080])], category: .service)]
        XCTAssertEqual(AppStore.menuBarCount(for: groups, ignoredGroupIDs: []), 3)
        XCTAssertEqual(AppStore.menuBarCount(for: groups, ignoredGroupIDs: ["project:/b"]), 2)
        XCTAssertEqual(AppStore.menuBarCount(for: [], ignoredGroupIDs: []), 0)
    }

    func testPlansCompareByContent() {
        let root = basic(10)
        let plan = KillPlan(root: root, targets: [basic(11, ppid: 10), root], summary: ["npm (pid 10)"],
                            requiresAdmin: false, warnings: [])
        let same = KillPlan(root: root, targets: [basic(11, ppid: 10), root], summary: ["npm (pid 10)"],
                            requiresAdmin: false, warnings: [])
        let other = KillPlan(root: root, targets: [root], summary: ["npm (pid 10)"], requiresAdmin: false, warnings: [])
        let key = root.identity
        XCTAssertTrue(AppStore.samePlans([key: plan], [key: same]))
        XCTAssertFalse(AppStore.samePlans([key: plan], [key: other]))
        XCTAssertFalse(AppStore.samePlans([key: plan], [:]))
        XCTAssertTrue(AppStore.samePlans([:], [:]))
    }

    // MARK: launchctl list

    func testLaunchctlListIsOnlyReadAgainForNewLaunchdProcesses() {
        let readAt: UInt64 = 1_000_000_000_000
        let now = readAt + 60_000_000
        let old = basic(500, start: readAt - 3_600_000_000)
        let new = basic(501, start: readAt + 5_000_000)
        let racing = basic(502, start: readAt - 200_000)   // started just before the read
        XCTAssertTrue(ScanEngine.launchdLabelsNeedRefresh(candidates: [old], readAt: 0, now: now), "never read")
        XCTAssertFalse(ScanEngine.launchdLabelsNeedRefresh(candidates: [old], readAt: readAt, now: now))
        XCTAssertFalse(ScanEngine.launchdLabelsNeedRefresh(candidates: [], readAt: readAt, now: now))
        XCTAssertTrue(ScanEngine.launchdLabelsNeedRefresh(candidates: [old, new], readAt: readAt, now: now))
        XCTAssertTrue(ScanEngine.launchdLabelsNeedRefresh(candidates: [racing], readAt: readAt, now: now))
        XCTAssertTrue(ScanEngine.launchdLabelsNeedRefresh(candidates: [old], readAt: readAt,
                                                          now: readAt + ScanEngine.launchdLabelsMaxAge + 1),
                      "safety net")
        XCTAssertTrue(ScanEngine.launchdLabelsNeedRefresh(candidates: [old], readAt: readAt, now: readAt - 1),
                      "the clock went back")
    }

    // MARK: Fingerprint

    func testFingerprintChangesOnlyWhenAListenerChanges() {
        func raw(_ processes: [ProcessBasic], _ sockets: [Int32: [UInt16]]) -> RawScan {
            RawScan(table: ProcessTable(processes: processes),
                    socketsByPID: sockets.mapValues { $0.map { ListeningSocket(port: $0, address: "*", family: .ipv4, pid: 0) } },
                    restrictedPIDs: [])
        }
        let server = basic(10, start: 1)
        let helper = basic(11, start: 1)
        let base = ListenerFingerprint(raw: raw([server, helper], [10: [3000]]), includeOtherUsers: false)
        XCTAssertEqual(base, ListenerFingerprint(raw: raw([server, helper, basic(12)], [10: [3000]]), includeOtherUsers: false),
                       "a process without sockets doesn't matter")
        XCTAssertNotEqual(base, ListenerFingerprint(raw: raw([server], [10: [3000, 3001]]), includeOtherUsers: false))
        XCTAssertNotEqual(base, ListenerFingerprint(raw: raw([basic(10, start: 2)], [10: [3000]]), includeOtherUsers: false),
                          "same pid, new process")
        XCTAssertNotEqual(base, ListenerFingerprint(raw: raw([basic(10, ppid: 77, start: 1)], [10: [3000]]),
                                                    includeOtherUsers: false), "reparented")
        XCTAssertNotEqual(base, ListenerFingerprint(raw: raw([server], [10: [3000]]), includeOtherUsers: true))
    }

    // MARK: Still running · no open port

    func testVanishedGroupsAreToolsThatClosedEveryPortOnTheirOwn() {
        let gone = group("project:/gone", [listener(10, ports: [3000])])
        let restarted = group("project:/restarted", [listener(11, ports: [4000])])
        let stopped = group("project:/stopped", [listener(12, ports: [5000])])
        let launchd = ListenerGroup(id: "launchd:x", category: .service, title: "x", subtitle: nil, path: nil, processes: [
            ListenerProcess(basic: basic(13), details: nil,
                            sockets: [ListeningSocket(port: 6000, address: "*", family: .ipv4, pid: 13)],
                            usage: .zero, treeUsage: .zero, category: .service, project: nil, displayName: "x",
                            frameworks: [], origin: nil,
                            manager: .launchd(LaunchdJob(label: "x", domain: "gui/501", plistPath: nil, keepAlive: true,
                                                         runAtLoad: true, pid: 13)),
                            appName: nil, isRestricted: false)])
        let app = group("app:/Applications/X.app", [listener(14, ports: [7000])], category: .app)
        let otherUser = group("pid:15", [listener(15, ports: [7100], uid: 0)])
        let busy = group("project:/busy", [listener(16, ports: [7200])])
        let hidden = group("project:/hidden", [listener(17, ports: [7300])])
        let still = group("project:/still", [listener(18, ports: [7400])])
        let previous = [gone, restarted, stopped, launchd, app, otherUser, busy, hidden, still]
        // The restarted server holds its port again under another group; "still" is still there.
        let current = [group("pid:99", [listener(99, ports: [4000])]), still]
        let vanished = StillRunning.vanishedGroups(previous: previous, current: current, stoppedPorts: [5000],
                                                   busyGroupIDs: ["project:/busy"],
                                                   ignoredGroupIDs: ["project:/hidden"], ignoredPorts: [],
                                                   currentUID: 501)
        XCTAssertEqual(vanished.map(\.id), ["project:/gone"])
    }

    func testRefreshDropsExitedProcessesAndToolsThatListenAgain() {
        let make = basic(20, ppid: 1, start: 5)
        let worker = basic(21, ppid: 20, start: 6)
        let item = StillRunningItem(id: "project:/a", title: "a", path: nil, formerPorts: [3000], closedAt: Date(),
                                    root: make, processes: [worker, make], labels: [20: "make serve", 21: "sleep 600"],
                                    usage: .zero)
        XCTAssertEqual(item.processSummary, "make serve, sleep 600")
        XCTAssertEqual(item.plan.targets.map(\.pid), [21, 20], "children first")
        XCTAssertEqual(item.busyID, "still:project:/a")

        // The worker exited; make still runs and uses memory.
        let table = ProcessTable(processes: [make])
        let usage = [Int32(20): ResourceUsage(cpuPercent: 1.5, memoryBytes: 40_000_000)]
        let refreshed = StillRunning.refreshed([item], table: table, servingPIDs: [], usage: usage)
        XCTAssertEqual(refreshed.first?.processes.map(\.pid), [20])
        XCTAssertEqual(refreshed.first?.usage, usage[20])
        XCTAssertEqual(StillRunning.refreshed([item], table: table, servingPIDs: [], usage: nil).first?.usage, .zero)

        // Everything exited, or the tree listens again (a new server under make): the entry goes.
        XCTAssertTrue(StillRunning.refreshed([item], table: .empty, servingPIDs: [], usage: nil).isEmpty)
        let server = basic(22, ppid: 20, start: 7)
        let withServer = ProcessTable(processes: [make, worker, server])
        let serving = StillRunning.servingPIDs(listenerPIDs: [22], table: withServer)
        XCTAssertTrue(serving.isSuperset(of: [22, 20]))
        XCTAssertTrue(StillRunning.refreshed([item], table: withServer, servingPIDs: serving, usage: nil).isEmpty)
    }

    func testMergeReplacesEntriesOfTheSameToolAndKeepsTheListShort() {
        func item(_ id: String, root: Int32) -> StillRunningItem {
            StillRunningItem(id: id, title: id, path: nil, formerPorts: [], closedAt: Date(), root: basic(root),
                             processes: [basic(root)], labels: [:], usage: .zero)
        }
        let existing = (0..<StillRunning.maxItems).map { item("old\($0)", root: Int32(100 + $0)) }
        let merged = StillRunning.merged([item("old3", root: 300), item("new", root: 101)], into: existing)
        XCTAssertEqual(merged.count, StillRunning.maxItems)
        XCTAssertEqual(Array(merged.map(\.id).prefix(3)), ["old3", "new", "old0"],
                       "new entries first; old3 (same group) and old1 (same root) replaced")
        XCTAssertFalse(merged.contains { $0.id == "old1" })
    }

    func testClosedMessage() {
        XCTAssertNil(StillRunning.closedMessage(for: []))
        XCTAssertEqual(StillRunning.closedMessage(for: [group("my-app", [listener(1, ports: [5173])])]), "my-app closed (:5173)")
        XCTAssertEqual(StillRunning.closedMessage(for: [group("a", [listener(1, ports: [1])]), group("b", [listener(2, ports: [2])]),
                                                        group("c", [listener(3, ports: [3])])]),
                       "a and 2 more closed")
    }
}

// MARK: - Engine (real throwaway processes)

final class PipelineEngineTests: XCTestCase {
    private var sandbox: PipelineSandbox?
    private let fs = ResolverTestFS()

    override func tearDown() {
        sandbox?.killAll()
        sandbox = nil
        super.tearDown()
    }

    private func makeSandbox() throws -> PipelineSandbox {
        let sandbox = try PipelineSandbox()
        self.sandbox = sandbox
        return sandbox
    }

    /// Scans with a fake file system: only the sandbox's folders are projects, nothing real is probed.
    private func makeEngine(_ sandbox: PipelineSandbox) -> ScanEngine {
        ScanEngine(resolver: fs.makeResolver(home: sandbox.container, probeDeadline: 0.2))
    }

    private func skippingRequest() -> ScanEngine.ScanRequest {
        ScanEngine.ScanRequest(includeOtherUsers: false, planGroupIDs: [], skipIfUnchanged: true)
    }

    func testUnchangedTicksAreSkippedUntilAListenerChanges() async throws {
        let sandbox = try makeSandbox()
        let engine = makeEngine(sandbox)
        let first = await engine.scan(skippingRequest())
        XCTAssertNotNil(first, "the first tick always builds")
        XCTAssertEqual(first?.plans.isEmpty, true, "no rows asked for plans")

        // Other processes on this Mac may open or close a port between two ticks; one quiet pair is enough.
        var skipped = false
        for _ in 0..<10 where !skipped {
            skipped = await engine.scan(skippingRequest()) == nil
        }
        XCTAssertTrue(skipped, "nothing changed, so the tick stops after the socket walk")

        let folder = try sandbox.folder("server")
        fs.addDirectory(folder + "/.git")
        let port = try PipelineSandbox.freePort()
        _ = try sandbox.startServer(in: folder, port: port)
        try sandbox.waitForListener(port: port)
        let changed = await engine.scan(skippingRequest())
        XCTAssertEqual(changed?.snapshot.groups.contains { $0.ports.contains(port) }, true, "a new port is never skipped")

        engine.invalidateManagerCaches()
        let afterAction = await engine.scan(skippingRequest())
        XCTAssertNotNil(afterAction, "a control action forces a rebuild")
    }

    func testPlansAreOnlyComputedForTheRequestedRows() async throws {
        let sandbox = try makeSandbox()
        let folder = try sandbox.folder("planned")
        fs.addDirectory(folder + "/.git")
        let port = try PipelineSandbox.freePort()
        let pid = try sandbox.startServer(in: folder, port: port)
        try sandbox.waitForListener(port: port)
        let engine = makeEngine(sandbox)

        let planned = await engine.scan(ScanEngine.ScanRequest(includeOtherUsers: false, planGroupIDs: ["project:" + folder]))
        let output = try XCTUnwrap(planned)
        let group = try XCTUnwrap(output.snapshot.groups.first { $0.ports.contains(port) })
        XCTAssertEqual(group.id, "project:" + folder)
        XCTAssertEqual(Set(output.plans.keys), Set(group.processes.map(\.id)))
        XCTAssertEqual(output.plans.values.first?.root.pid, pid)

        let unplanned = await engine.scan(ScanEngine.ScanRequest(includeOtherUsers: false, planGroupIDs: []))
        let none = try XCTUnwrap(unplanned)
        XCTAssertTrue(none.plans.isEmpty)

        // A row expanded between ticks gets its plan from the latest scan.
        let previews = await engine.plans(for: [group])
        XCTAssertEqual(previews.values.first?.targets.map(\.pid), [pid])
    }

    func testStopAndPreviewsNeverWaitForARunningScan() async throws {
        let sandbox = try makeSandbox()
        let folder = try sandbox.folder("busy")
        fs.addDirectory(folder + "/.git")
        let port = try PipelineSandbox.freePort()
        let pid = try sandbox.startServer(in: folder, port: port)
        try sandbox.waitForListener(port: port)
        let engine = makeEngine(sandbox)
        let output = await engine.scan(includeOtherUsers: false)
        let group = try XCTUnwrap(output.snapshot.groups.first { $0.ports.contains(port) })

        // A scan stuck on the scan queue (as behind a folder-access prompt). Released after 5 s at the latest, so a
        // regression fails instead of hanging.
        let gate = DispatchSemaphore(value: 0)
        engine.queue.async { gate.wait() }
        DispatchQueue.global().asyncAfter(deadline: .now() + 5) { gate.signal() }
        defer { gate.signal() }

        let started = Date()
        let plans = await engine.freshPlans(for: group.processes, onlyThisProcess: false)
        let previews = await engine.plans(for: [group])
        XCTAssertLessThan(Date().timeIntervalSince(started), 2, "Stop waited for the scan")
        XCTAssertEqual(plans.first?.targets.map(\.pid), [pid])
        XCTAssertEqual(previews.count, 1)
    }
}

// MARK: - AppStore loop (real throwaway processes)

@MainActor
final class PipelineStoreTests: XCTestCase {
    private var sandbox: PipelineSandbox?
    private let fs = ResolverTestFS()

    override func tearDown() {
        sandbox?.killAll()
        sandbox = nil
        super.tearDown()
    }

    private func makeSandbox() throws -> PipelineSandbox {
        let sandbox = try PipelineSandbox()
        self.sandbox = sandbox
        return sandbox
    }

    private func makeStore(_ sandbox: PipelineSandbox, probeDeadline: TimeInterval = 0.2) -> AppStore {
        AppStore(engine: ScanEngine(resolver: fs.makeResolver(home: sandbox.container, probeDeadline: probeDeadline)))
    }

    /// Full scans until `condition` holds (other tasks of the store may be scanning too).
    private func poll(_ store: AppStore, timeout: TimeInterval = 10, until condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            guard Date() < deadline else { return XCTFail("condition not met within \(timeout) s") }
            await store.pollOnce(full: true)
            try await Task.sleep(for: .milliseconds(50))
        }
    }

    func testClosedPanelKeepsTheMenuBarCountLiveWithoutTouchingPanelState() async throws {
        let sandbox = try makeSandbox()
        let folder = try sandbox.folder("live-count")
        fs.addDirectory(folder + "/.git")
        let port = try PipelineSandbox.freePort()
        let pid = try sandbox.startServer(in: folder, port: port)
        try sandbox.waitForListener(port: port)
        let store = makeStore(sandbox)

        await store.pollOnce()
        XCTAssertEqual(store.menuBarCount, 1, "only the sandbox folder is a project for this resolver")
        XCTAssertTrue(store.snapshot.groups.isEmpty, "nothing is published while the panel is closed")
        XCTAssertNil(store.lastUpdated)
        XCTAssertFalse(store.isScanning)

        // Ticks with the panel closed change nothing the menu bar or the panel observes.
        let flag = ChangeFlag()
        withObservationTracking {
            _ = store.snapshot
            _ = store.lastUpdated
            _ = store.visibleGroups
            _ = store.menuBarCount
            _ = store.isScanning
            _ = store.startupItems
            _ = store.banner
        } onChange: {
            flag.set()
        }
        for _ in 0..<3 { await store.pollOnce() }
        XCTAssertFalse(flag.isSet, "a closed-panel tick wrote observed state")

        // Opening the panel shows the newest scan right away.
        store.isPanelVisible = true
        XCTAssertTrue(store.snapshot.groups.contains { $0.ports.contains(port) })
        XCTAssertNotNil(store.lastUpdated)
        store.isPanelVisible = false

        // The port closes while the panel is closed: the count follows on the next tick.
        sandbox.kill(pid)
        try sandbox.waitUntilGone(pid)
        try await poll(store) { store.menuBarCount == 0 }
    }

    func testExpandingARowComputesItsStopPreview() async throws {
        let sandbox = try makeSandbox()
        let folder = try sandbox.folder("preview")
        fs.addDirectory(folder + "/.git")
        let port = try PipelineSandbox.freePort()
        let pid = try sandbox.startServer(in: folder, port: port)
        try sandbox.waitForListener(port: port)
        let store = makeStore(sandbox)
        await store.pollOnce(full: true)
        store.isPanelVisible = true
        let group = try XCTUnwrap(store.snapshot.groups.first { $0.ports.contains(port) })
        XCTAssertTrue(store.killPlanPreview(for: group).isEmpty, "no plans until a row is expanded")

        store.expandedGroupIDs.insert(group.id)
        let deadline = Date().addingTimeInterval(5)
        while store.killPlanPreview(for: group).isEmpty && Date() < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertTrue(store.killPlanPreview(for: group).contains { $0.contains("pid \(pid)") },
                      "\(store.killPlanPreview(for: group))")
        store.isPanelVisible = false
    }

    func testLeftoverOfACrashedServerIsListedAndStopped() async throws {
        let sandbox = try makeSandbox()
        let folder = try sandbox.folder("crashy")
        fs.addFile(folder + "/Makefile", "serve:\n")
        fs.addDirectory(folder + "/.git")
        let port = try PipelineSandbox.freePort()
        let make = try sandbox.startServerWithWorker(in: folder, port: port)
        let server = try sandbox.waitForListener(port: port)
        let store = makeStore(sandbox)
        await store.pollOnce(full: true)
        XCTAssertEqual(store.menuBarCount, 1)

        // The server dies; make and its worker keep running (and holding memory). The panel is closed.
        sandbox.kill(server)
        try sandbox.waitUntilGone(server)
        try await poll(store) { !store.stillRunning.isEmpty }
        let item = try XCTUnwrap(store.stillRunning.first)
        XCTAssertEqual(item.id, "project:" + folder)
        XCTAssertEqual(item.formerPorts, [port])
        XCTAssertEqual(item.root.pid, make, "make launched it, so Stop ends make's whole tree")
        XCTAssertTrue(item.processes.contains { $0.pid == make })
        let worker = try XCTUnwrap(sandbox.pid(commandContaining: "time.sleep"))
        XCTAssertTrue(item.processes.contains { $0.pid == worker }, "\(item.processes.map(\.comm))")
        XCTAssertFalse(item.processes.contains { $0.pid == server })
        XCTAssertNil(store.banner, "nothing to say about it while the panel is closed")

        store.stopStillRunning(item)
        let deadline = Date().addingTimeInterval(10)
        while store.busyGroupIDs.contains(item.busyID) && Date() < deadline {
            try await Task.sleep(for: .milliseconds(50))
        }
        XCTAssertFalse(item.processes.contains { sandbox.isRunning($0) }, "every leftover process was stopped")
        XCTAssertTrue(store.stillRunning.isEmpty)
        XCTAssertEqual(store.banner?.message.hasPrefix("Stopped crashy"), true, "\(String(describing: store.banner))")
    }

    func testLeftoverGoesAwayOnItsOwnWhenItsProcessesExit() async throws {
        let sandbox = try makeSandbox()
        let folder = try sandbox.folder("fades")
        fs.addFile(folder + "/Makefile", "serve:\n")
        fs.addDirectory(folder + "/.git")
        let port = try PipelineSandbox.freePort()
        _ = try sandbox.startServerWithWorker(in: folder, port: port)
        let server = try sandbox.waitForListener(port: port)
        let store = makeStore(sandbox)
        await store.pollOnce(full: true)
        sandbox.kill(server)
        try sandbox.waitUntilGone(server)
        try await poll(store) { !store.stillRunning.isEmpty }

        // The rest exits too (no port changes, so closed-panel ticks skip the rebuild): the entry still goes.
        sandbox.killAll()
        let deadline = Date().addingTimeInterval(10)
        while !store.stillRunning.isEmpty && Date() < deadline {
            await store.pollOnce()
            try await Task.sleep(for: .milliseconds(50))
        }
        XCTAssertTrue(store.stillRunning.isEmpty)
    }

    func testToolThatClosesOnItsOwnGetsAShortNoteWhileThePanelIsOpen() async throws {
        let sandbox = try makeSandbox()
        let folder = try sandbox.folder("quitter")
        fs.addDirectory(folder + "/.git")
        let port = try PipelineSandbox.freePort()
        let pid = try sandbox.startServer(in: folder, port: port)
        try sandbox.waitForListener(port: port)
        let store = makeStore(sandbox)
        await store.pollOnce(full: true)
        store.isPanelVisible = true

        sandbox.kill(pid)
        try sandbox.waitUntilGone(pid)
        try await poll(store) { store.banner != nil }
        XCTAssertEqual(store.banner?.message, "quitter closed (:\(port))")
        XCTAssertTrue(store.stillRunning.isEmpty, "nothing of it runs any more")
        store.isPanelVisible = false
    }

    /// The scan loop feeds the folder-access notice at the top of the list (FolderAccessController), never a banner.
    func testFolderAccessNoticeExplainsTheWaitAndClearsItself() async throws {
        let sandbox = try makeSandbox()
        let folder = try sandbox.folder("Downloads/app/server")
        fs.addDirectory(sandbox.container + "/Downloads/app/.git")
        let port = try PipelineSandbox.freePort()
        _ = try sandbox.startServer(in: folder, port: port)
        try sandbox.waitForListener(port: port)
        fs.blockProbes(under: sandbox.container + "/Downloads")
        defer { fs.releaseBlockedProbes() }
        let store = makeStore(sandbox)

        let message = FolderAccess.waitingMessage(for: [sandbox.container + "/Downloads"])
        XCTAssertEqual(message, "Waiting for access to Downloads. Click Allow in the macOS prompt so PortPilot can "
                       + "name your projects.")
        await store.pollOnce(full: true)
        XCTAssertEqual(store.folderAccess.waitingMessage, message)
        XCTAssertNil(store.banner, "the notice is the only place that says it")

        // It goes by itself once access is settled.
        fs.releaseBlockedProbes()
        try await poll(store) { store.folderAccess.waitingMessage == nil }

        // A new wait shows it again.
        let other = try sandbox.folder("Downloads/other/server")
        fs.addDirectory(sandbox.container + "/Downloads/other/.git")
        fs.blockProbes(under: sandbox.container + "/Downloads")
        let otherPort = try PipelineSandbox.freePort()
        _ = try sandbox.startServer(in: other, port: otherPort)
        try sandbox.waitForListener(port: otherPort)
        try await poll(store) { store.folderAccess.waitingMessage == message }
        XCTAssertNil(store.banner)
    }

    func testLaunchAtLoginSwitchSnapsBackWhereThisCopyCannotManageIt() {
        var settings = AppSettings()
        settings.launchAtLogin = false
        let store = AppStore(engine: ScanEngine(resolver: fs.makeResolver()), settings: settings)
        XCTAssertFalse(AppStore.canManageLoginItem, "the XCTest host never manages the agent")
        // No agent points at the test host, so nothing will start it at login: the switch can't say otherwise.
        store.settings.launchAtLogin = true
        XCTAssertFalse(store.settings.launchAtLogin, "the switch shows what will really happen at login")
        XCTAssertEqual(store.banner?.style, .warning)
    }
}

// MARK: - Layout

/// "Still running · no open port" rows with synthetic data (no system access).
@MainActor
final class PipelineLayoutTests: XCTestCase {
    private func item(_ title: String, ports: [UInt16], memory: UInt64) -> StillRunningItem {
        let make = ProcessBasic(pid: 61000, ppid: 1, pgid: 61000, uid: 501, comm: "gnumake", startTime: 1)
        let shell = ProcessBasic(pid: 61001, ppid: 61000, pgid: 61000, uid: 501, comm: "bash", startTime: 2)
        let worker = ProcessBasic(pid: 61002, ppid: 61001, pgid: 61000, uid: 501, comm: "node", startTime: 3)
        return StillRunningItem(id: "project:/tmp/\(title)", title: title, path: "/tmp/\(title)", formerPorts: ports,
                                closedAt: Date().addingTimeInterval(-240), root: make,
                                processes: [worker, shell, make],
                                labels: [61000: "make dev", 61001: "sh -c \"node server.js & node worker.js\"",
                                         61002: "node worker.js --queue=a-very-long-queue-name-that-goes-on"],
                                usage: ResourceUsage(cpuPercent: 3.4, memoryBytes: memory))
    }

    func testStillRunningRowsFitThePanelAndRender() throws {
        let items = [item("firebase-emulator-suite-with-a-long-name", ports: UIFixtures.manyPorts, memory: 2_400_000_000),
                     item("api", ports: [8000], memory: 265_000_000)]
        let store = AppStore(previewSnapshot: .empty, startupItems: [], recentlyStopped: [], stillRunning: items)
        let rowWidth = Theme.panelWidth - 2 * Theme.listInset
        let controller = NSHostingController(rootView: StillRunningView(store: store, isCollapsed: .constant(false)))
        let width = controller.sizeThatFits(in: CGSize(width: rowWidth, height: 20_000)).width
        XCTAssertLessThanOrEqual(width, rowWidth + 0.5)

        let directory: URL
        if let path = ProcessInfo.processInfo.environment["PORTPILOT_UI_SNAPSHOT_DIR"], !path.isEmpty {
            directory = URL(fileURLWithPath: path, isDirectory: true)
        } else {
            directory = FileManager.default.temporaryDirectory
                .appendingPathComponent("PortPilotPipelineTests-\(UUID().uuidString)", isDirectory: true)
        }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { if ProcessInfo.processInfo.environment["PORTPILOT_UI_SNAPSHOT_DIR"] == nil {
            try? FileManager.default.removeItem(at: directory)
        } }
        for (name, scheme) in [("still-running-light", ColorScheme.light), ("still-running-dark", .dark)] {
            XCTAssertTrue(SnapshotRenderer.render(store: store, to: directory.appendingPathComponent("\(name).png"),
                                                  colorScheme: scheme))
        }
    }
}

/// Set from Observation's change callback, read by the test.
private final class ChangeFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false
    var isSet: Bool { lock.withLock { value } }
    func set() { lock.withLock { value = true } }
}

/// Throwaway servers for pipeline tests: a temporary folder (symlinks resolved, as processes report their cwd) and
/// processes started in their own process groups, all killed by `killAll()`.
final class PipelineSandbox {
    let container: String
    private var groups: [pid_t] = []
    private var killed = false

    init() throws {
        let created = FileManager.default.temporaryDirectory
            .appendingPathComponent("portpilot-pipeline-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: created, withIntermediateDirectories: true)
        guard let resolved = realpath(created.path, nil) else { throw XCTSkip("realpath failed") }
        container = String(cString: resolved)
        free(resolved)
    }

    deinit { killAll() }

    static var python: String? {
        ["/opt/homebrew/bin/python3", "/usr/local/bin/python3", "/usr/bin/python3"]
            .first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    func folder(_ subpath: String) throws -> String {
        let path = container + "/" + subpath
        try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
        return path
    }

    /// `python3 -m http.server <port>` on 127.0.0.1 with `directory` as its working directory.
    @discardableResult
    func startServer(in directory: String, port: UInt16) throws -> pid_t {
        guard let python = Self.python else { throw XCTSkip("python3 is not installed") }
        let script = "cd \(Self.quoted(directory)) && exec \(python) -m http.server \(port) --bind 127.0.0.1"
        return try spawn("/bin/sh", ["sh", "-c", script])
    }

    /// `make serve`: starts the server in the background next to a long-running python worker that outlives it.
    /// Returns make's pid.
    func startServerWithWorker(in directory: String, port: UInt16) throws -> pid_t {
        guard let python = Self.python else { throw XCTSkip("python3 is not installed") }
        guard FileManager.default.isExecutableFile(atPath: "/usr/bin/make") else { throw XCTSkip("make is not installed") }
        let makefile = "serve:\n\t\(python) -m http.server \(port) --bind 127.0.0.1 >/dev/null 2>&1 & "
            + "\(python) -c 'import time; time.sleep(600)'\n"
        try makefile.write(toFile: directory + "/Makefile", atomically: true, encoding: .utf8)
        return try spawn("/usr/bin/make", ["make", "-s", "-C", directory, "serve"])
    }

    /// Waits until some process listens on `port`; returns its pid.
    @discardableResult
    func waitForListener(port: UInt16, timeout: TimeInterval = 15) throws -> pid_t {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            for process in SysProc.allProcesses() where process.uid == getuid() && groups.contains(process.pgid) {
                if SysProc.listeningTCPSockets(pid: process.pid)?.contains(where: { $0.port == port }) == true {
                    return process.pid
                }
            }
            Thread.sleep(forTimeInterval: 0.05)
        }
        throw XCTSkip("the throwaway server did not start listening on :\(port)")
    }

    /// A running process started here whose command line contains `text`.
    func pid(commandContaining text: String) -> pid_t? {
        SysProc.allProcesses().first { process in
            groups.contains(process.pgid)
                && (SysProc.details(for: process)?.arguments.joined(separator: " ").contains(text) ?? false)
        }?.pid
    }

    /// SIGKILL to one of our processes.
    func kill(_ pid: pid_t) {
        guard let process = SysProc.basic(pid: pid), groups.contains(process.pgid) else { return }
        Darwin.kill(pid, SIGKILL)
    }

    /// Waits until `pid` exited (reaping it when it is our child; zombies count as gone, as for the engine).
    func waitUntilGone(_ pid: pid_t, timeout: TimeInterval = 5) throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            var status: Int32 = 0
            _ = waitpid(pid, &status, WNOHANG)
            if !SysProc.allProcesses().contains(where: { $0.pid == pid }) { return }
            Thread.sleep(forTimeInterval: 0.02)
        }
        XCTFail("pid \(pid) did not exit")
    }

    /// True while the process (same pid and start time) runs; reaps it first when it is our exited child.
    func isRunning(_ process: ProcessBasic) -> Bool {
        var status: Int32 = 0
        _ = waitpid(process.pid, &status, WNOHANG)
        return SysProc.allProcesses().contains { $0.identity == process.identity }
    }

    /// Kills every process group started here and removes the folder. Idempotent.
    func killAll() {
        guard !killed else { return }
        killed = true
        for group in groups where group > 1 {
            Darwin.kill(-group, SIGKILL)
            var status: Int32 = 0
            _ = waitpid(group, &status, 0)
        }
        try? FileManager.default.removeItem(atPath: container)
    }

    static func freePort() throws -> UInt16 {
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

    private static func quoted(_ path: String) -> String {
        "'" + path.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    /// posix_spawn in a new process group (so `killAll` reaches every child), stdio on /dev/null.
    private func spawn(_ path: String, _ arguments: [String]) throws -> pid_t {
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
        groups.append(pid)
        return pid
    }
}
