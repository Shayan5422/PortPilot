import AppKit
import XCTest
@testable import PortPilot

// Pure UI logic: confirm-button guard, stop safety, port chip caps, startup item status, banner hold, header texts.
// Nothing here touches the system or renders views.

final class ConfirmGateTests: XCTestCase {
    private let interval: TimeInterval = 0.5
    private let t0 = Date(timeIntervalSince1970: 1_000)

    func testFirstClickArmsWithoutConfirming() {
        var gate = ConfirmGate()
        XCTAssertEqual(gate.click(at: t0, doubleClickInterval: interval), .armed)
        XCTAssertTrue(gate.isArmed)
    }

    func testDoubleClickNeverConfirms() {
        var gate = ConfirmGate()
        XCTAssertEqual(gate.click(at: t0, clickCount: 1, doubleClickInterval: interval), .armed)
        // Second mouse-up of a habitual double-click, ~180 ms later.
        XCTAssertEqual(gate.click(at: t0 + 0.18, clickCount: 2, doubleClickInterval: interval), .ignored)
        XCTAssertTrue(gate.isArmed, "an ignored click keeps the button armed")
    }

    func testClickInsideDoubleClickIntervalIsIgnoredEvenWithClickCountOne() {
        var gate = ConfirmGate()
        _ = gate.click(at: t0, doubleClickInterval: interval)
        // Keyboard / VoiceOver activations report clickCount 1; the time guard still applies.
        XCTAssertEqual(gate.click(at: t0 + 0.3, clickCount: 1, doubleClickInterval: interval), .ignored)
    }

    func testLateSecondHalfOfDoubleClickIsIgnored() {
        var gate = ConfirmGate()
        _ = gate.click(at: t0, doubleClickInterval: interval)
        // A user with a long system double-click setting: clickCount says it is still a double-click.
        XCTAssertEqual(gate.click(at: t0 + 0.7, clickCount: 2, doubleClickInterval: interval), .ignored)
    }

    func testDeliberateSecondClickConfirmsAndDisarms() {
        var gate = ConfirmGate()
        _ = gate.click(at: t0, doubleClickInterval: interval)
        XCTAssertEqual(gate.click(at: t0 + 0.2, clickCount: 2, doubleClickInterval: interval), .ignored)
        XCTAssertEqual(gate.click(at: t0 + 0.9, clickCount: 1, doubleClickInterval: interval), .confirmed)
        XCTAssertFalse(gate.isArmed)
        // The next click starts over.
        XCTAssertEqual(gate.click(at: t0 + 1.0, doubleClickInterval: interval), .armed)
    }

    func testDisarmResets() {
        var gate = ConfirmGate()
        _ = gate.click(at: t0, doubleClickInterval: interval)
        gate.disarm()
        XCTAssertFalse(gate.isArmed)
        XCTAssertEqual(gate.click(at: t0 + 5, doubleClickInterval: interval), .armed)
    }

    @MainActor
    func testCurrentClickCountWithoutMouseEventIsOne() {
        // In tests there is no mouse event being handled; key events must not be asked for clickCount either.
        XCTAssertEqual(ConfirmGate.currentClickCount, 1)
    }
}

final class StopSafetyTests: XCTestCase {
    func testProjectsAndServicesStopWithOneClick() {
        XCTAssertEqual(StopSafety.evaluate(category: .project, processes: [UIFixtures.process(pid: 500)]), .oneClick)
        XCTAssertEqual(StopSafety.evaluate(category: .service, processes: [UIFixtures.process(pid: 501)]), .oneClick)
    }

    func testAppsAndSystemNeedConfirmation() {
        XCTAssertEqual(StopSafety.evaluate(category: .app, processes: [UIFixtures.process(pid: 94297, category: .app)]),
                       .confirm(.app))
        XCTAssertEqual(StopSafety.evaluate(category: .system, processes: [UIFixtures.process(pid: 709, category: .system)]),
                       .confirm(.system))
    }

    func testOtherUsersProcessNeedsConfirmationWhateverTheCategory() {
        let restricted = UIFixtures.process(pid: 393, category: .system, uid: 0, restricted: true)
        XCTAssertEqual(StopSafety.evaluate(category: .system, processes: [restricted]), .confirm(.otherUser))
        // Even inside a project group, an admin-password stop must not be one click.
        let mixed = [UIFixtures.process(pid: 600), UIFixtures.process(pid: 601, uid: 0, restricted: true)]
        XCTAssertEqual(StopSafety.evaluate(category: .project, processes: mixed), .confirm(.otherUser))
    }

    func testLaunchdItselfHasNoStop() {
        let launchd = UIFixtures.process(pid: 1, category: .system, uid: 0)
        XCTAssertEqual(StopSafety.evaluate(category: .system, processes: [launchd]), .unavailable)
        XCTAssertEqual(StopSafety.evaluate(category: .system, processes: []), .unavailable)
        XCTAssertFalse(StopSafety.unavailable.isAvailable)
        // One stoppable process is enough to offer Stop.
        let mixed = [launchd, UIFixtures.process(pid: 700, category: .system)]
        XCTAssertEqual(StopSafety.evaluate(category: .system, processes: mixed), .confirm(.system))
    }

    func testGroupAndProcessEntryPoints() {
        let app = UIFixtures.group(id: "app:/Applications/Antigravity IDE.app", category: .app, title: "Antigravity IDE",
                                   processes: [UIFixtures.process(pid: 94297, category: .app)])
        XCTAssertEqual(StopSafety.forGroup(app), .confirm(.app))
        XCTAssertEqual(StopSafety.forProcess(app.processes[0]), .confirm(.app))
        XCTAssertEqual(StopSafety.forGroup(app).reason, .app)
        XCTAssertNil(StopSafety.oneClick.reason)
    }

    func testConfirmationTextsNameTheTarget() {
        XCTAssertTrue(StopSafety.Reason.app.armedHelp(title: "Spotify").hasPrefix("Spotify is an app"))
        XCTAssertTrue(StopSafety.Reason.otherUser.armedHelp(title: "kdc").contains("administrator password"))
        XCTAssertFalse(StopSafety.Reason.system.menuNote.isEmpty)
    }
}

final class PortChipOverflowTests: XCTestCase {
    func testUpToTheLimitEveryPortIsAChip() {
        XCTAssertEqual(PortChipOverflow.split([]).shown, [])
        XCTAssertEqual(PortChipOverflow.split([3000]).shown, [3000])
        let three = PortChipOverflow.split([3000, 3001, 3002])
        XCTAssertEqual(three.shown, [3000, 3001, 3002])
        XCTAssertTrue(three.hidden.isEmpty)
    }

    func testBeyondTheLimitTheLastSlotBecomesPlusN() {
        let four = PortChipOverflow.split([3000, 3001, 3002, 3003])
        XCTAssertEqual(four.shown, [3000, 3001])
        XCTAssertEqual(four.hidden, [3002, 3003])
        let ports = (0..<10).map { UInt16(9000 + $0) }
        let ten = PortChipOverflow.split(ports)
        XCTAssertEqual(ten.shown.count, PortChipOverflow.defaultLimit - 1)
        XCTAssertEqual(ten.shown + ten.hidden, ports, "nothing is lost or reordered")
    }

    func testDegenerateLimits() {
        let one = PortChipOverflow.split([1, 2, 3], limit: 1)
        XCTAssertEqual(one.shown, [])
        XCTAssertEqual(one.hidden, [1, 2, 3])
        XCTAssertEqual(PortChipOverflow.split([1, 2], limit: 0).hidden, [1, 2], "limit is clamped to 1")
    }

    func testTooltipList() {
        XCTAssertEqual(PortChipOverflow.list([5173, 8080]), ":5173  :8080")
    }
}

final class StartupItemStatusTests: XCTestCase {
    func testCrashLoopingKeepAliveAgentIsExplainedAndOffersNoStart() {
        // Like com.northwind.app: KeepAlive, spawn failed, last exit 78, retried thousands of times.
        let status = StartupItemStatus(UIFixtures.startupItem(keepAlive: true, isLoaded: true, pid: nil, lastExit: 78))
        XCTAssertEqual(status.kind, .failingRepeatedly(exit: 78))
        XCTAssertEqual(status.text, "Keeps failing · exit 78")
        XCTAssertTrue(status.help.contains("configuration error"))
        XCTAssertTrue(status.help.contains("Turn it off"))
        XCTAssertTrue(status.isProblem)
        XCTAssertFalse(status.offersStart, "kickstarting a crash loop just fails again")
    }

    func testCrashLoopBySignal() {
        let status = StartupItemStatus(UIFixtures.startupItem(keepAlive: true, isLoaded: true, pid: nil, lastExit: -11))
        XCTAssertEqual(status.text, "Keeps crashing · SIGSEGV")
        XCTAssertFalse(status.offersStart)
    }

    func testOneShotJobThatFailedStillOffersStart() {
        let status = StartupItemStatus(UIFixtures.startupItem(keepAlive: false, isLoaded: true, pid: nil, lastExit: 78))
        XCTAssertEqual(status.kind, .exited(78))
        XCTAssertEqual(status.text, "Exited with 78")
        XCTAssertTrue(status.help.contains("code 78 (configuration error"), status.help)
        XCTAssertTrue(status.offersStart)
    }

    func testKilledBySignal() {
        let status = StartupItemStatus(UIFixtures.startupItem(keepAlive: false, isLoaded: true, pid: nil, lastExit: -9))
        XCTAssertEqual(status.text, "Killed by SIGKILL")
        XCTAssertTrue(status.help.contains("SIGKILL"))
    }

    func testUnloadedKeepAliveJobIsNotACrashLoop() {
        // launchd only retries loaded jobs.
        let status = StartupItemStatus(UIFixtures.startupItem(keepAlive: true, isLoaded: false, pid: nil, lastExit: 1))
        XCTAssertEqual(status.kind, .exited(1))
        XCTAssertTrue(status.offersStart, "Start loads an unloaded job again")
    }

    func testOtherStates() {
        let running = StartupItemStatus(UIFixtures.startupItem(keepAlive: true, isLoaded: true, pid: 964, lastExit: 0))
        XCTAssertEqual(running.text, "Running · PID 964")
        XCTAssertFalse(running.offersStart)
        XCTAssertFalse(running.isProblem)

        let disabled = StartupItemStatus(UIFixtures.startupItem(keepAlive: true, isLoaded: false, pid: nil,
                                                                lastExit: 78, isDisabled: true))
        XCTAssertEqual(disabled.kind, .disabled)
        XCTAssertTrue(disabled.isHollow)
        XCTAssertFalse(disabled.offersStart)

        let idle = StartupItemStatus(UIFixtures.startupItem(keepAlive: false, isLoaded: true, pid: nil, lastExit: 0))
        XCTAssertEqual(idle.kind, .loaded)
        XCTAssertTrue(idle.offersStart)

        let unloaded = StartupItemStatus(UIFixtures.startupItem(keepAlive: false, isLoaded: false, pid: nil, lastExit: nil))
        XCTAssertEqual(unloaded.kind, .notLoaded)
        XCTAssertTrue(unloaded.isHollow)
    }

    func testExitCodeMeanings() {
        XCTAssertEqual(StartupItemStatus.exitMeaning(127), "the program wasn't found")
        XCTAssertEqual(StartupItemStatus.exitMeaning(126), "the program can't be run")
        XCTAssertEqual(StartupItemStatus.exitMeaning(137), "ended by SIGKILL")
        XCTAssertEqual(StartupItemStatus.exitMeaning(143), "ended by SIGTERM")
        XCTAssertNil(StartupItemStatus.exitMeaning(3))
        XCTAssertEqual(StartupItemStatus.endedPhrase(3), "exits with code 3")
        XCTAssertEqual(StartupItemStatus.signalName(42), "signal 42")
    }

    func testCollapsedHeaderCountsOnlyCrashLoops() {
        // The worst-case set holds one crash loop (com.northwind.app), one running agent and one failed one-shot job.
        let items = UIFixtures.worstCaseStartupItems()
        XCTAssertEqual(StartupItemStatus.failingRepeatedlyCount(items), 1)
        XCTAssertEqual(StartupItemStatus.failingRepeatedlyCount([]), 0)
        let disabledLoop = UIFixtures.startupItem(keepAlive: true, isLoaded: true, pid: nil, lastExit: 78, isDisabled: true)
        XCTAssertEqual(StartupItemStatus.failingRepeatedlyCount([disabledLoop]), 0, "turned off: nothing to warn about")
        XCTAssertEqual(StartupItemStatus.failingRepeatedlyNote(1), "1 keeps failing")
        XCTAssertEqual(StartupItemStatus.failingRepeatedlyNote(3), "3 keep failing")
    }
}

final class StartupToggleStateTests: XCTestCase {
    func testPendingChoiceIsShownWhileApplying() {
        XCTAssertTrue(StartupToggleState.displayedEnabled(isDisabled: false, pending: nil))
        XCTAssertFalse(StartupToggleState.displayedEnabled(isDisabled: true, pending: nil))
        // Switched off, launchctl still running: the switch stays off instead of snapping back.
        XCTAssertFalse(StartupToggleState.displayedEnabled(isDisabled: false, pending: false))
    }

    func testPendingClearsOnceLaunchdAgrees() {
        XCTAssertTrue(StartupToggleState.shouldClearPending(pending: false, isDisabled: true, isBusy: false, failed: false))
        XCTAssertTrue(StartupToggleState.shouldClearPending(pending: true, isDisabled: false, isBusy: true, failed: false))
    }

    func testPendingStaysWhileBusyOrAwaitingTheRefresh() {
        XCTAssertFalse(StartupToggleState.shouldClearPending(pending: false, isDisabled: false, isBusy: true, failed: false))
        XCTAssertFalse(StartupToggleState.shouldClearPending(pending: false, isDisabled: false, isBusy: false, failed: false))
        XCTAssertFalse(StartupToggleState.shouldClearPending(pending: nil, isDisabled: false, isBusy: false, failed: true))
    }

    func testPendingClearsWhenTheActionFailed() {
        XCTAssertTrue(StartupToggleState.shouldClearPending(pending: false, isDisabled: false, isBusy: false, failed: true))
        // …but not before launchctl has returned.
        XCTAssertFalse(StartupToggleState.shouldClearPending(pending: false, isDisabled: false, isBusy: true, failed: true))
    }

    func testSettleDelayCoversTheNextScan() {
        XCTAssertEqual(StartupToggleState.settleDelay(refreshInterval: 3), 5)
        XCTAssertEqual(StartupToggleState.settleDelay(refreshInterval: 0), 3)
        XCTAssertEqual(StartupToggleState.settleDelay(refreshInterval: 30), 32)
    }

    func testBusyIDMatchesAppStore() {
        // AppStore.setStartupItem / startStartupItem insert "startup:<label>".
        XCTAssertEqual(StartupItemsView.busyID(for: "com.acme.tool"), "startup:com.acme.tool")
    }
}

final class BannerHoldTests: XCTestCase {
    private let first = Banner(style: .error, message: "Couldn't fully stop x")
    private let second = Banner(style: .success, message: "Stopped y")

    func testStoreBannerIsShownAsIs() {
        let hold = BannerHold()
        XCTAssertEqual(hold.shown(current: first), first)
        XCTAssertNil(hold.shown(current: nil))
    }

    func testBannerUnderThePointerOutlivesTheAutoDismiss() {
        var hold = BannerHold()
        hold.pointerEntered(current: first)
        hold.storeBannerChanged(to: nil) // AppStore's timer fired
        XCTAssertEqual(hold.shown(current: nil), first)
        hold.pointerExited()
        XCTAssertEqual(hold.shown(current: nil), first, "lingers briefly after the pointer leaves")
        hold.releaseIfPointerOutside()
        XCTAssertNil(hold.shown(current: nil))
    }

    func testANewerBannerReplacesTheHeldOne() {
        var hold = BannerHold()
        hold.pointerEntered(current: first)
        hold.storeBannerChanged(to: second)
        XCTAssertEqual(hold.shown(current: second), second)
        hold.storeBannerChanged(to: nil)
        XCTAssertEqual(hold.shown(current: nil), second, "never resurrects the older banner")
    }

    func testNothingIsHeldWithoutThePointer() {
        var hold = BannerHold()
        hold.storeBannerChanged(to: first)
        hold.storeBannerChanged(to: nil)
        XCTAssertNil(hold.shown(current: nil))
    }

    func testReleaseWhileInsideIsIgnoredButExplicitReleaseWins() {
        var hold = BannerHold()
        hold.pointerEntered(current: first)
        hold.releaseIfPointerOutside()
        XCTAssertEqual(hold.shown(current: nil), first)
        hold.release() // closed or acted on
        XCTAssertNil(hold.shown(current: nil))
        XCTAssertFalse(hold.isPointerInside)
    }
}

final class PanelLogicTests: XCTestCase {
    func testRecentlyStoppedComesBeforeStartupItems() {
        XCTAssertEqual(TrailingSection.visible(searchText: "", hasRecentlyStopped: true, hasStartupItems: true),
                       [.recentlyStopped, .startupItems])
        XCTAssertEqual(TrailingSection.visible(searchText: "", hasRecentlyStopped: false, hasStartupItems: true),
                       [.startupItems])
        XCTAssertEqual(TrailingSection.visible(searchText: "", hasRecentlyStopped: true, hasStartupItems: false),
                       [.recentlyStopped])
        XCTAssertEqual(TrailingSection.visible(searchText: "vite", hasRecentlyStopped: true, hasStartupItems: true), [])
    }

    func testUpdatedLabel() {
        let now = Date(timeIntervalSince1970: 10_000)
        XCTAssertEqual(PanelText.updatedLabel(lastUpdated: nil, now: now), "Not updated yet")
        XCTAssertEqual(PanelText.updatedLabel(lastUpdated: now - 1, now: now), "Updated just now")
        XCTAssertEqual(PanelText.updatedLabel(lastUpdated: now - 12, now: now), "Updated 12s ago")
        XCTAssertEqual(PanelText.updatedLabel(lastUpdated: now - 3 * 3600 - 240, now: now), "Updated 3h 4m ago")
    }

    func testUpdatedLabelFitsItsFixedWidth() {
        // The label has a fixed frame so its once-a-second change never resizes the panel; it must still fit.
        let font = NSFont.monospacedDigitSystemFont(ofSize: 10.5, weight: .regular)
        let longest = PanelText.updatedLabel(lastUpdated: Date(timeIntervalSince1970: 0),
                                             now: Date(timeIntervalSince1970: 99 * 86400 + 23 * 3600))
        XCTAssertEqual(longest, "Updated 99d 23h ago")
        let width = (longest as NSString).size(withAttributes: [.font: font]).width
        XCTAssertLessThan(width, PanelText.updatedLabelWidth - 4)
    }

    func testPathLikeTitlesKeepTheirLastComponent() {
        XCTAssertEqual(GroupRow.titleTruncation(for: "acme-public-deployment-20261008/release"), .middle)
        XCTAssertEqual(GroupRow.titleTruncation(for: "uptime-monitor"), .tail)
    }

    /// The planner never stops supervisord, so its tooltip must not promise that Stop ends it.
    func testWatcherTooltipDoesNotPromiseToStopSupervisord() {
        XCTAssertEqual(ProcessRow.watcherHelp(for: "nodemon"), "Reloaded on file changes by nodemon — Stop ends the watcher too")
        let supervisord = ProcessRow.watcherHelp(for: "supervisord")
        XCTAssertFalse(supervisord.contains("Stop ends"))
        XCTAssertTrue(supervisord.contains("supervisorctl"))
    }

    func testPanelCountsAsOnScreenWhileOpening() {
        typealias Reader = WindowVisibilityReader.ObserverView
        XCTAssertTrue(Reader.isOnScreen(isVisible: true, isKey: false, occlusionVisible: true))
        // Key before the window server reports it visible: the panel is opening, build the list now.
        XCTAssertTrue(Reader.isOnScreen(isVisible: true, isKey: true, occlusionVisible: false))
        XCTAssertFalse(Reader.isOnScreen(isVisible: false, isKey: true, occlusionVisible: true))
        XCTAssertFalse(Reader.isOnScreen(isVisible: true, isKey: false, occlusionVisible: false))
    }
}
