import XCTest
@testable import PortPilot

/// Banner wording and the actions offered after Stop, Stop All, Relaunch and Start (pure, no processes).
final class StopReportTests: XCTestCase {
    private func outcome(_ title: String = "web", ports: [UInt16] = [3000], groupID: String = "project:/x/web",
                         _ change: (inout StopOutcome) -> Void = { _ in }) -> StopOutcome {
        var outcome = StopOutcome(groupID: groupID, title: title, ports: ports)
        outcome.stoppedCount = 1
        change(&outcome)
        return outcome
    }

    private func record(_ arguments: [String], executable: String? = "/opt/homebrew/bin/node",
                        manager: ProcessManager = .none, ports: [UInt16] = [3000]) -> StoppedRecord {
        StoppedRecord(id: UUID(), date: Date(), title: "web · node", ports: ports, cwd: "/x/web", arguments: arguments,
                      environment: [:], executablePath: executable, manager: manager)
    }

    // MARK: One Stop

    func testSuccessOffersUndoForEveryRecordTheStopCreated() {
        let ids = [UUID(), UUID()]
        let banner = StopReport.banner(for: outcome(ports: [3000, 5173]) { $0.undoRecordIDs = ids })
        XCTAssertEqual(banner.style, .success)
        XCTAssertEqual(banner.message, "Stopped web (:3000, :5173)")
        XCTAssertEqual(banner.action, .relaunch(recordID: ids[0], moreRecordIDs: [ids[1]]))
        XCTAssertEqual(banner.actionTitle, "Undo")
    }

    func testUnloadedLaunchdJobOffersDisableAutoStartWithItsLabel() {
        let banner = StopReport.banner(for: outcome { $0.autoStartLabels = ["com.acme.api"]; $0.undoRecordIDs = [UUID()] })
        XCTAssertEqual(banner.message, "Stopped web (:3000). It will start again at next login.")
        XCTAssertEqual(banner.action, .disableAutoStart(groupID: "project:/x/web", launchdLabels: ["com.acme.api"]))
        XCTAssertEqual(banner.actionTitle, "Disable Auto-Start")
    }

    func testNotesForceKillAndErrors() {
        let noted = StopReport.banner(for: outcome { $0.escalated = true; $0.notes = ["pm2 api stopped"] })
        XCTAssertEqual(noted.message, "Stopped web (:3000) — had to force-kill · pm2 api stopped")
        XCTAssertNil(noted.action)

        let failed = StopReport.banner(for: outcome { $0.errors = ["a", "b", "c", "d"]; $0.undoRecordIDs = [UUID()] })
        XCTAssertEqual(failed.style, .error)
        XCTAssertEqual(failed.message, "Couldn't fully stop web: a; b; c")
        XCTAssertNil(failed.action)
    }

    func testAlreadyExitedIsInformationNotAnError() {
        let banner = StopReport.banner(for: outcome { $0.stoppedCount = 0; $0.alreadyExited = true })
        XCTAssertEqual(banner.style, .info)
        XCTAssertEqual(banner.message, "web had already exited")
    }

    func testAppsAreQuitOrAskedToQuitWithoutUndo() {
        let quit = StopReport.banner(for: outcome("Spotify", ports: [57621]) { $0.quitApp = true })
        XCTAssertEqual(quit.message, "Quit Spotify (:57621)")
        XCTAssertNil(quit.action)

        let asked = StopReport.banner(for: outcome("Xcode", ports: []) { $0.stoppedCount = 0; $0.stillQuitting = true })
        XCTAssertEqual(asked.style, .info)
        XCTAssertTrue(asked.message.hasPrefix("Asked Xcode to quit. It's still open"), asked.message)
    }

    // MARK: Stop All

    func testStopAllSummarizesInOneBanner() throws {
        let undo = [UUID(), UUID(), UUID()]
        let outcomes = [outcome("a", ports: [3000]) { $0.undoRecordIDs = [undo[0]] },
                        outcome("b", ports: [5173]) { $0.undoRecordIDs = [undo[1]] },
                        outcome("c", ports: [8000]) { $0.undoRecordIDs = [undo[2]] }]
        let banner = try XCTUnwrap(StopReport.summary(for: outcomes))
        XCTAssertEqual(banner.message, "Stopped 3 projects (:3000, :5173, :8000)")
        XCTAssertEqual(banner.action, .relaunch(recordID: undo[0], moreRecordIDs: [undo[1], undo[2]]))
        XCTAssertNil(StopReport.summary(for: []))
        XCTAssertEqual(StopReport.summary(for: [outcomes[0]])?.message, "Stopped a (:3000)", "one project: as Stop")
    }

    func testStopAllNamesTheFailures() throws {
        let outcomes = [outcome("a"), outcome("b") { $0.errors = ["pid 4: Permission denied"] },
                        outcome("c") { $0.errors = ["already exited"] }, outcome("d") { $0.errors = ["x"] }]
        let banner = try XCTUnwrap(StopReport.summary(for: outcomes))
        XCTAssertEqual(banner.style, .error)
        XCTAssertEqual(banner.message,
                       "Stopped 1 of 4 projects — b: pid 4: Permission denied; c: already exited; 1 more failed")
    }

    func testStopAllOffersOneDisableAutoStartForEveryUnloadedJob() throws {
        let outcomes = [outcome("a") { $0.autoStartLabels = ["com.acme.a"] },
                        outcome("b") { $0.autoStartLabels = ["com.acme.b", "com.acme.a"] }]
        let banner = try XCTUnwrap(StopReport.summary(for: outcomes))
        XCTAssertEqual(banner.message, "Stopped 2 projects (:3000). 2 launchd jobs start again at next login.")
        XCTAssertEqual(banner.action, .disableAutoStart(groupID: "", launchdLabels: ["com.acme.a", "com.acme.b"]))
    }

    func testStopAllConfirmTooltipListsTheProjects() {
        let job = LaunchdJob(label: "com.acme.monitor", domain: "gui/501", plistPath: nil, keepAlive: true,
                             runAtLoad: true, pid: 9)
        let groups = ["web", "api", "docs", "monitor"].map { name in
            UIFixtures.group(id: "project:/x/\(name)", category: .project, title: name, processes: [
                UIFixtures.process(pid: Int32(name.count), manager: name == "monitor" ? .launchd(job) : .none),
            ])
        }
        XCTAssertEqual(StopReport.stopAllConfirmHelp(Array(groups.prefix(2))), "Click again to stop web and api.")
        XCTAssertEqual(StopReport.stopAllConfirmHelp(groups),
                       "Click again to stop web, api, docs and 1 more. monitor starts again at next login.")
    }

    // MARK: Relaunch

    func testOnlyRealCommandsOrRebuildableTitlesCanBeRelaunched() {
        XCTAssertTrue(StopReport.canRelaunch(record(["node", "server.js"])))
        XCTAssertTrue(StopReport.canRelaunch(record(["npm run dev", "", ""])), "rebuilt as npm run dev")
        XCTAssertFalse(StopReport.canRelaunch(record(["nginx: master process /opt/homebrew/bin/nginx", ""],
                                                     executable: "/opt/homebrew/bin/nginx")))
        XCTAssertFalse(StopReport.canRelaunch(record([])))
        let job = LaunchdJob(label: "com.acme.api", domain: "gui/501", plistPath: nil, keepAlive: true,
                             runAtLoad: true, pid: nil)
        XCTAssertFalse(StopReport.canRelaunch(record(["node", "api.js"], manager: .launchd(job))))
    }

    func testRelaunchBannersTellTheTruth() throws {
        let server = record(["node", "server.js"])
        let log = "/tmp/logs/web.log"
        func banner(_ state: RelaunchResult.State, _ target: StoppedRecord = server) throws -> Banner {
            try XCTUnwrap(StopReport.relaunchBanner(for: [RelaunchResult(record: target, state: state, logPath: log)]))
        }
        XCTAssertEqual(try banner(.listening(pid: 7, port: 3000)).message, "Relaunched web · node — listening on :3000 again")
        XCTAssertEqual(try banner(.listening(pid: 7, port: 3000)).style, .success)
        XCTAssertEqual(try banner(.running(pid: 7)).style, .success)

        let quiet = try banner(.notListening(pid: 7))
        XCTAssertEqual(quiet.style, .warning)
        XCTAssertEqual(quiet.message, "Started web · node (pid 7), but :3000 isn't open yet. Its output is in /tmp/logs/web.log.")

        let exited = try banner(.exited)
        XCTAssertEqual(exited.style, .error)
        XCTAssertEqual(exited.message, "Couldn't relaunch web · node: it exited soon after starting. Its output is in /tmp/logs/web.log")
        XCTAssertEqual(try banner(.failed("the folder ~/x no longer exists")).message,
                       "Couldn't relaunch web · node: the folder ~/x no longer exists")

        let other = record(["node", "api.js"], ports: [4000])
        let many = try XCTUnwrap(StopReport.relaunchBanner(for: [
            RelaunchResult(record: server, state: .listening(pid: 7, port: 3000), logPath: log),
            RelaunchResult(record: other, state: .listening(pid: 8, port: 4000), logPath: log),
        ]))
        XCTAssertEqual(many.message, "Relaunched 2 servers (:3000, :4000)")
        let partly = try XCTUnwrap(StopReport.relaunchBanner(for: [
            RelaunchResult(record: server, state: .listening(pid: 7, port: 3000), logPath: log),
            RelaunchResult(record: other, state: .failed("boom"), logPath: log),
        ]))
        XCTAssertEqual(partly.style, .error)
        XCTAssertEqual(partly.message, "Relaunched 1 of 2 — web · node: boom")
        XCTAssertNil(StopReport.relaunchBanner(for: []))
    }

    func testRunningRelaunchesLeaveRecentlyStopped() {
        let server = record(["node", "server.js"])
        XCTAssertTrue(RelaunchResult(record: server, state: .notListening(pid: 1), logPath: "").isRunning,
                      "running: relaunching again would start a second copy")
        XCTAssertFalse(RelaunchResult(record: server, state: .exited, logPath: "").isRunning)
        XCTAssertFalse(RelaunchResult(record: server, state: .failed("x"), logPath: "").isRunning)
    }

    // MARK: Auto-start and Start

    func testAutoStartBanner() {
        XCTAssertEqual(StopReport.autoStartBanner(disabled: ["com.acme.api"], manual: [], errors: []).message,
                       "com.acme.api won't start at login anymore. Turn it back on under Startup Items.")
        let manual = StopReport.autoStartBanner(disabled: ["com.acme.a"], manual: ["com.app.helper"], errors: [])
        XCTAssertEqual(manual.style, .warning)
        XCTAssertEqual(manual.message, "Turned off auto-start for com.acme.a. PortPilot can't turn off auto-start for "
                       + "com.app.helper. Turn it off in System Settings › General › Login Items.")
        XCTAssertEqual(StopReport.autoStartBanner(disabled: [], manual: [], errors: ["x: denied"]).style, .error)
    }

    func testStartBannerReflectsWhatLaunchdSays() {
        let label = "com.acme.api"
        let running = StopReport.startBanner(label: label, error: nil,
                                             state: LaunchctlListEntry(pid: 42, lastExitStatus: 0, label: label))
        XCTAssertEqual(running.message, "Started com.acme.api (pid 42)")
        let failed = StopReport.startBanner(label: label, error: nil,
                                            state: LaunchctlListEntry(pid: nil, lastExitStatus: 78, label: label))
        XCTAssertEqual(failed.style, .error)
        XCTAssertTrue(failed.message.hasPrefix("com.acme.api didn't keep running — it exits with code 78"), failed.message)
        XCTAssertEqual(StopReport.startBanner(label: label, error: nil,
                                              state: LaunchctlListEntry(pid: nil, lastExitStatus: 0, label: label)).message,
                       "Ran com.acme.api. It has finished.")
        XCTAssertEqual(StopReport.startBanner(label: label, error: nil, state: nil).style, .error)
        XCTAssertEqual(StopReport.startBanner(label: label, error: ControlError("nope"), state: nil).message,
                       "com.acme.api: nope")
    }

    // MARK: Helpers and contracts

    func testPortTextAndLists() {
        XCTAssertEqual(StopReport.portText([]), "")
        XCTAssertEqual(StopReport.portText([1, 2, 3], limit: 2), " (:1, :2 +1)")
        XCTAssertEqual(StopReport.joinedList(["a"]), "a")
        XCTAssertEqual(StopReport.joinedList(["a", "b", "c"]), "a, b and c")
    }

    func testBannerActionsKeepTheirOldShape() {
        let id = UUID()
        XCTAssertEqual(Banner.Action.disableAutoStart(groupID: "g"), .disableAutoStart(groupID: "g", launchdLabels: []))
        XCTAssertEqual(Banner.Action.relaunch(recordID: id), .relaunch(recordID: id, moreRecordIDs: []))
    }
}

/// The UI wiring of these flows (pure parts).
@MainActor
final class StopFlowUITests: XCTestCase {
    func testStopAllCountsWhatItStops() {
        let visible = UIFixtures.group(id: "project:/x/web", category: .project, title: "web",
                                       processes: [UIFixtures.process(pid: 11, ports: [3000])])
        let hidden = UIFixtures.group(id: "project:/x/old", category: .project, title: "old",
                                      processes: [UIFixtures.process(pid: 12, ports: [4000])])
        let mutedPorts = UIFixtures.group(id: "project:/x/muted", category: .project, title: "muted",
                                          processes: [UIFixtures.process(pid: 13, ports: [5000])])
        let service = UIFixtures.group(id: "launchd:redis", category: .service, title: "redis",
                                       processes: [UIFixtures.process(pid: 14, ports: [6379], category: .service)])
        var settings = AppSettings()
        settings.ignoredGroupIDs = [hidden.id]
        settings.ignoredPorts = [5000]
        let snapshot = ScanSnapshot(date: Date(), groups: [visible, hidden, mutedPorts, service], table: .empty,
                                    duration: 0, restrictedCount: 0)
        let store = AppStore(previewSnapshot: snapshot, startupItems: [], recentlyStopped: [], settings: settings)
        XCTAssertEqual(store.stoppableProjects.map(\.id), [visible.id])
    }

    func testAutoRestartNoticeSaysWhatStopAndDisableDo() {
        let agents = NSHomeDirectory() + "/Library/LaunchAgents"
        let managed = LaunchdJob(label: "com.acme.api", domain: "gui/501", plistPath: agents + "/com.acme.api.plist",
                                 keepAlive: true, runAtLoad: true, pid: 9)
        XCTAssertEqual(GroupRow.autoRestartNotice(for: .launchd(managed)),
                       "launchd starts this again at next login. Stop & Disable keeps it off.")
        let helper = LaunchdJob(label: "com.app.helper", domain: "gui/501", plistPath: nil, keepAlive: true,
                                runAtLoad: false, pid: 9)
        XCTAssertEqual(GroupRow.autoRestartNotice(for: .launchd(helper)),
                       "launchd starts this again at next login. Turn that off in System Settings › General › Login Items.")
        XCTAssertEqual(GroupRow.autoRestartNotice(for: .pm2(id: 1, name: "api")), "pm2 restarts “api” automatically.")
    }

    func testTerminalOpensTheFolderOfAFile() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("pp-terminal-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let plist = directory.appendingPathComponent("com.acme.api.plist")
        try Data().write(to: plist)
        XCTAssertEqual(AppStore.terminalFolder(for: directory.path), directory.path)
        XCTAssertEqual(AppStore.terminalFolder(for: plist.path), directory.path)
        XCTAssertNil(AppStore.terminalFolder(for: directory.path + "/missing"))
    }

    func testStartIsOfferedForAJobStopUnloadedButNotForACrashLoop() {
        let unloaded = StartupItemStatus(UIFixtures.startupItem(keepAlive: true, isLoaded: false, pid: nil, lastExit: nil))
        XCTAssertEqual(unloaded.kind, .notLoaded)
        XCTAssertTrue(unloaded.offersStart)
        XCTAssertTrue(unloaded.help.contains("Start loads it"), unloaded.help)
        let crashLoop = StartupItemStatus(UIFixtures.startupItem(keepAlive: true, isLoaded: true, pid: nil, lastExit: 78))
        XCTAssertFalse(crashLoop.offersStart)
        let disabled = StartupItemStatus(UIFixtures.startupItem(keepAlive: true, isLoaded: false, pid: nil, lastExit: nil,
                                                               isDisabled: true))
        XCTAssertFalse(disabled.offersStart)
    }
}
