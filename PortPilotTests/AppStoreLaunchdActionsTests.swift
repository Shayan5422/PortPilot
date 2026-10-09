import Darwin
import XCTest
@testable import PortPilot

/// AppStore's launchd paths against real launchd jobs the tests load themselves: labels start with
/// `eu.shhshm.PortPilot.selftest.`, plists live in the sandbox folder (a "home" for a LaunchdService of the test's
/// own, never ~/Library/LaunchAgents), and every job is booted out and re-enabled afterwards.
@MainActor
final class AppStoreLaunchdActionsTests: XCTestCase {
    private var sandbox: ActionSandbox!
    private let fs = ResolverTestFS()

    override func setUp() async throws {
        sandbox = try ActionSandbox()
        guard ActionSandbox.python != nil else { throw XCTSkip("python3 is not installed") }
    }

    override func tearDown() async throws {
        await sandbox?.cleanUpInBackground()
        sandbox = nil
    }

    private func makeEngine() -> ScanEngine {
        ScanEngine(resolver: fs.makeResolver(home: ProjectResolver.parent(of: sandbox.root)))
    }

    /// A LaunchdService whose ~/Library/LaunchAgents is the sandbox's: agents there count as manageable.
    private var sandboxLaunchd: LaunchdService {
        LaunchdService(homeDirectory: sandbox.root + "/home")
    }

    private var sandboxAgents: String { sandbox.root + "/home/Library/LaunchAgents" }

    private func makeStore(engine: ScanEngine, ports: Set<UInt16>) async -> AppStore {
        var settings = AppSettings()
        settings.gracefulTimeout = 1
        let output = await engine.scan(includeOtherUsers: false)
        return AppStore(engine: engine, initial: ActionSandbox.output(output, keepingPorts: ports), settings: settings,
                        launchd: sandboxLaunchd)
    }

    private func httpServerArguments(port: UInt16) -> [String] {
        [ActionSandbox.python ?? "python3", "-m", "http.server", String(port), "--bind", "127.0.0.1"]
    }

    // MARK: Startup Items: Start a job Stop unloaded

    /// Findings #12/#13/#14/#26/#47: a job that isn't loaded (Stop booted it out) can be started from Startup Items:
    /// Start loads it again and, since it doesn't run at load, kickstarts it. The banner reports what launchd says.
    func testStartLoadsAndKickstartsAnUnloadedJob() async throws {
        let port = try sandbox.freePort()
        let label = ActionSandbox.selftestLabel()
        let plist = try sandbox.writeLaunchAgent(label: label, directory: sandboxAgents,
                                                 programArguments: httpServerArguments(port: port),
                                                 runAtLoad: false, keepAlive: false)
        let item = StartupItem(label: label, plistPath: plist, command: "python3 -m http.server", workingDirectory: nil,
                               runAtLoad: false, keepAlive: false, isDisabled: false, isLoaded: false, pid: nil,
                               lastExitStatus: nil, ports: [])
        XCTAssertTrue(StartupItemStatus(item).offersStart, "Start is offered for an unloaded job")

        let store = await makeStore(engine: makeEngine(), ports: [port])
        await store.startStartupItem(item)?.value
        let banner = try XCTUnwrap(store.banner)
        XCTAssertEqual(banner.style, .success, banner.message)
        XCTAssertTrue(banner.message.hasPrefix("Started \(label)"), banner.message)
        _ = try await sandbox.waitForListener(on: port)
    }

    /// No false "Started": a job that exits right away is reported with its exit code.
    func testStartReportsAJobThatExitsRightAway() async throws {
        let label = ActionSandbox.selftestLabel()
        let plist = try sandbox.writeLaunchAgent(label: label, directory: sandboxAgents,
                                                 programArguments: ["/bin/sh", "-c", "exit 3"],
                                                 runAtLoad: false, keepAlive: false)
        let item = StartupItem(label: label, plistPath: plist, command: "/bin/sh -c \"exit 3\"", workingDirectory: nil,
                               runAtLoad: false, keepAlive: false, isDisabled: false, isLoaded: false, pid: nil,
                               lastExitStatus: nil, ports: [])
        let store = await makeStore(engine: makeEngine(), ports: [])
        await store.startStartupItem(item)?.value
        let banner = try XCTUnwrap(store.banner)
        XCTAssertEqual(banner.style, .error, banner.message)
        XCTAssertTrue(banner.message.contains("didn't keep running") && banner.message.contains("code 3"), banner.message)
    }

    // MARK: Stop

    /// Finding #13 (launchd-stop-unverified-supervisor): Stop is verified. A listener the job detached into its own
    /// session survives `launchctl bootout`; PortPilot notices and stops it directly instead of reporting success.
    func testLaunchdStopStopsADetachedChildDirectly() async throws {
        let python = try XCTUnwrap(ActionSandbox.python)
        let port = try sandbox.freePort()
        let script = try sandbox.write("""
            import os, sys
            os.setsid()
            os.execv(sys.executable, [sys.executable, "-m", "http.server", sys.argv[1], "--bind", "127.0.0.1"])
            """, to: "detach.py")
        let label = ActionSandbox.selftestLabel()
        let plist = try sandbox.writeLaunchAgent(label: label, directory: sandbox.root + "/agents",
                                                 programArguments: ["/bin/sh", "-c", "'\(python)' '\(script)' \(port) & wait"],
                                                 runAtLoad: true, keepAlive: false)
        try await sandbox.bootstrap(plist)
        let server = try await sandbox.waitForListener(on: port)

        let store = await makeStore(engine: makeEngine(), ports: [port])
        let group = try XCTUnwrap(store.snapshot.groups.first { $0.ports.contains(port) })
        guard case .launchd(let job) = group.manager else { return XCTFail("not attributed to launchd: \(group.id)") }
        XCTAssertEqual(job.label, label)

        await store.stop(group)?.value
        let banner = try XCTUnwrap(store.banner)
        XCTAssertEqual(banner.style, .success, banner.message)
        XCTAssertTrue(banner.message.contains("was detached from \(label), so it was stopped directly"), banner.message)
        XCTAssertFalse(sandbox.isAlive(server))
        let isFree = await sandbox.waitUntilFree(port)
        XCTAssertTrue(isFree)
    }

    /// C3 / finding #12: Stop & Disable never writes a disable PortPilot can't undo. A job whose plist isn't in a
    /// LaunchAgents folder is only stopped, and the banner says where to turn it off.
    func testStopAndDisableOnlyStopsAJobPortPilotCantSwitchBackOn() async throws {
        let port = try sandbox.freePort()
        let label = ActionSandbox.selftestLabel()
        let plist = try sandbox.writeLaunchAgent(label: label, directory: sandbox.root + "/project-folder",
                                                 programArguments: httpServerArguments(port: port),
                                                 runAtLoad: true, keepAlive: true)
        try await sandbox.bootstrap(plist)
        _ = try await sandbox.waitForListener(on: port)

        let store = await makeStore(engine: makeEngine(), ports: [port])
        let group = try XCTUnwrap(store.snapshot.groups.first { $0.ports.contains(port) })
        XCTAssertTrue(group.manager.isAutoRestarting)

        await store.stopAndDisableAutoStart(group)?.value
        let banner = try XCTUnwrap(store.banner)
        XCTAssertEqual(banner.style, .success, banner.message)
        XCTAssertTrue(banner.message.contains("\(label) may start again at login — turn it off in "
                                              + StopReport.loginItemsSettings), banner.message)
        let override = await sandbox.launchdOverride(for: label)
        XCTAssertNotEqual(override, true, "no disable override was written")
        let isFree = await sandbox.waitUntilFree(port)
        XCTAssertTrue(isFree, "KeepAlive can't bring it back after bootout")
    }

    /// Findings #8/#11/#25: after a plain Stop of an auto-start job, the banner's "Disable Auto-Start" still works
    /// although the job's group has left the list: the action carries the job's label.
    func testDisableAutoStartBannerActionWorksAfterTheGroupIsGone() async throws {
        let port = try sandbox.freePort()
        let label = ActionSandbox.selftestLabel()
        let plist = try sandbox.writeLaunchAgent(label: label, directory: sandboxAgents,
                                                 programArguments: httpServerArguments(port: port),
                                                 runAtLoad: true, keepAlive: true)
        try await sandbox.bootstrap(plist)
        _ = try await sandbox.waitForListener(on: port)

        let store = await makeStore(engine: makeEngine(), ports: [port])
        // Stop and the banner are used in the open panel, which shows every scan as it comes in.
        store.isPanelVisible = true
        defer { store.isPanelVisible = false }
        let group = try XCTUnwrap(store.snapshot.groups.first { $0.ports.contains(port) })
        XCTAssertEqual(store.killPlanPreview(for: group), ["launchd job \(label)"], "the label is the whole line")

        await store.stop(group)?.value
        let stopBanner = try XCTUnwrap(store.banner)
        XCTAssertEqual(stopBanner.action, .disableAutoStart(groupID: group.id, launchdLabels: [label]),
                       stopBanner.message)
        XCTAssertEqual(stopBanner.actionTitle, "Disable Auto-Start")
        XCTAssertTrue(stopBanner.message.hasSuffix("It will start again at next login."), stopBanner.message)
        let isFree = await sandbox.waitUntilFree(port)
        XCTAssertTrue(isFree)
        XCTAssertFalse(store.snapshot.groups.contains { $0.id == group.id }, "the group has left the list")
        XCTAssertTrue(store.recentlyStopped.isEmpty, "launchd jobs are started again from Startup Items")

        await store.performBannerAction(stopBanner)?.value
        let banner = try XCTUnwrap(store.banner)
        XCTAssertEqual(banner.style, .success, banner.message)
        XCTAssertTrue(banner.message.hasPrefix("\(label) won't start at login anymore"), banner.message)
        let override = await sandbox.launchdOverride(for: label)
        XCTAssertEqual(override, true, "launchctl disable was written")
        // The clean-up's `launchctl enable` undoes it, like the Startup Items switch would.
    }
}
