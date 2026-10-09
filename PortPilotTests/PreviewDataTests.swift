import AppKit
import SwiftUI
import XCTest
@testable import PortPilot

/// The demo data behind previews and README screenshots: fictional, complete, and laid out like real rows.
@MainActor
final class PreviewDataTests: XCTestCase {
    override func tearDown() {
        Format.setDisplayHome(nil)
        super.tearDown()
    }

    // MARK: Privacy

    /// Every user-visible or copyable string of the demo set.
    private func demoStrings() -> [String] {
        var strings: [String] = []
        for group in PreviewData.snapshot().groups {
            strings += [group.id, group.title, group.subtitle ?? "", group.path ?? ""]
            for process in group.processes {
                strings += [process.displayName, process.commandLine, process.details?.cwd ?? "",
                            process.details?.executablePath ?? "", process.project?.rootPath ?? "",
                            process.project?.name ?? ""]
                strings += process.details?.arguments ?? []
                strings += process.details?.environment.values.map { $0 } ?? []
                if case .launchd(let job) = process.manager { strings += [job.label, job.plistPath ?? ""] }
            }
        }
        for item in PreviewData.startupItems() {
            strings += [item.label, item.plistPath, item.command, item.workingDirectory ?? ""]
        }
        for record in PreviewData.recentlyStopped() {
            strings += [record.title, record.commandLine, record.cwd ?? "", record.executablePath ?? ""]
            strings += record.arguments + record.environment.values
        }
        strings.append(PreviewData.respawnBanner.message)
        if case .disableAutoStart(let groupID, let labels) = PreviewData.respawnBanner.action {
            strings.append(groupID)
            strings += labels
        }
        return strings
    }

    func testDemoPathsStayInsideTheFictionalHome() {
        XCTAssertEqual(PreviewData.home, "/Users/alex")
        let realHome = NSHomeDirectory()
        for string in demoStrings() {
            var rest = Substring(string)
            while let range = rest.range(of: "/Users/") {
                let user = rest[range.upperBound...].prefix { $0 != "/" && $0 != " " }
                XCTAssertEqual(user, "alex", "\(string) points outside the demo home")
                rest = rest[range.upperBound...]
            }
            if realHome != PreviewData.home {
                XCTAssertFalse(string.contains(realHome), "\(string) contains the real home folder")
            }
        }
    }

    func testDemoUsesNoRealUserName() throws {
        let user = NSUserName()
        try XCTSkipIf(user.count < 4 || user == "alex", "user name too short or too common to search for")
        for string in demoStrings() {
            XCTAssertFalse(string.localizedCaseInsensitiveContains(user), "\(string) contains the user name")
        }
    }

    // MARK: Coverage of row states

    func testDemoShowsEveryRowState() throws {
        let groups = PreviewData.snapshot().groups
        let settings = AppSettings()
        func group(_ title: String) throws -> ListenerGroup {
            try XCTUnwrap(groups.first { $0.title == title }, "\(title) missing")
        }

        let shop = try group("acme-shop")
        XCTAssertEqual(shop.id, PreviewData.featuredGroupID)
        XCTAssertEqual(shop.ports, [3000, 8000])
        XCTAssertEqual(shop.origin?.kind, .claudeCode)
        XCTAssertTrue(shop.processes.contains { $0.manager == .watcher(name: "uvicorn --reload") })
        XCTAssertFalse(shop.manager.isAutoRestarting)

        let notes = try group("notes-api")
        XCTAssertTrue(notes.manager.isAutoRestarting, "launchd · auto-start badge")
        XCTAssertEqual(notes.manager.badgeText, "launchd · auto-start")

        let ml = try group("ml-playground")
        XCTAssertTrue(ml.isExposedToNetwork, "Network badge")
        XCTAssertGreaterThanOrEqual(ml.usage.cpuPercent, settings.heavyCPUThreshold, "heavy CPU highlight")
        XCTAssertEqual(groups.filter(\.isExposedToNetwork).map(\.category).filter { $0 != .app && $0 != .system },
                       [.project], "only one visible row is open to the network")

        let postgres = try group("postgresql@16")
        XCTAssertEqual(postgres.manager.badgeText, "brew services · auto-start")

        let failing = PreviewData.startupItems().filter { StartupItemStatus($0).kind.isFailingRepeatedly }
        XCTAssertEqual(failing.map(\.label), ["com.example.invoice-worker"])
        XCTAssertEqual(StartupItemStatus(failing[0]).text, "Keeps failing · exit 78")

        let stopped = PreviewData.recentlyStopped()
        XCTAssertEqual(stopped.count, 2)
        XCTAssertTrue(stopped.allSatisfy(\.canRelaunch))
    }

    func testDemoIdentitiesAreConsistent() throws {
        let snapshot = PreviewData.snapshot()
        let pids = snapshot.groups.flatMap { $0.processes.map(\.basic.pid) }
        XCTAssertEqual(Set(pids).count, pids.count, "PIDs are unique")
        XCTAssertEqual(Set(snapshot.groups.map(\.id)).count, snapshot.groups.count, "group ids are unique")

        guard case .disableAutoStart(let groupID, _) = PreviewData.respawnBanner.action else {
            return XCTFail("the respawn banner offers Stop & Disable")
        }
        let target = try XCTUnwrap(snapshot.groups.first { $0.id == groupID })
        XCTAssertTrue(target.manager.isAutoRestarting)

        // Running startup items match the rows they own.
        for item in PreviewData.startupItems() {
            guard let pid = item.pid else { continue }
            let owner = try XCTUnwrap(snapshot.groups.first { $0.processes.contains { $0.basic.pid == pid } })
            XCTAssertEqual(owner.ports, item.ports, item.label)
        }
    }

    func testDefaultStoreShowsProjectsAndServicesAndHidesTheRest() {
        let store = PreviewData.store()
        XCTAssertEqual(store.sections.map { $0.category }, [.project, .service])
        XCTAssertEqual(store.sections.first?.groups.map { $0.title }, ["acme-shop", "notes-api", "blog", "ml-playground"])
        XCTAssertEqual(store.hiddenCount, 3, "VS Code, Spotify and rapportd")
        XCTAssertTrue(store.expandedGroupIDs.isEmpty)
        XCTAssertEqual(PreviewData.store(expandFeatured: true).expandedGroupIDs, [PreviewData.featuredGroupID])
        XCTAssertTrue(PreviewData.store(empty: true, expandFeatured: true).expandedGroupIDs.isEmpty)
    }

    // MARK: Home abbreviation

    func testDisplayHomeIsTheRealHomeUnlessDemoDataSetsIt() {
        Format.setDisplayHome(nil)
        XCTAssertEqual(Format.displayHome, NSHomeDirectory())
        XCTAssertEqual(Format.abbreviatePath(NSHomeDirectory() + "/code/app"), "~/code/app")

        _ = PreviewData.store()
        XCTAssertEqual(Format.displayHome, PreviewData.home)
        XCTAssertEqual(Format.abbreviatePath(PreviewData.developer + "/acme-shop"), "~/Developer/acme-shop")
        XCTAssertEqual(Format.abbreviatePath(PreviewData.home), "~")
        XCTAssertEqual(DisplayText.command(PreviewData.home + "/.bun/bin/bun run start"), "~/.bun/bin/bun run start")
        if NSHomeDirectory() != PreviewData.home {
            XCTAssertEqual(Format.abbreviatePath(NSHomeDirectory() + "/x"), NSHomeDirectory() + "/x")
        }

        Format.setDisplayHome(nil)
        XCTAssertEqual(Format.abbreviatePath(PreviewData.developer), NSHomeDirectory() == PreviewData.home
                       ? "~/Developer" : PreviewData.developer)
    }

    // MARK: Layout

    func testDemoRowsFitThePanel() {
        let rowWidth = Theme.panelWidth - 2 * Theme.listInset
        let store = PreviewData.store(expandFeatured: true)
        for group in PreviewData.snapshot().groups {
            let controller = NSHostingController(rootView: GroupRow(group: group, store: store))
            let width = controller.sizeThatFits(in: CGSize(width: rowWidth, height: 20_000)).width
            XCTAssertLessThanOrEqual(width, rowWidth + 0.5, "\(group.title) is \(width) pt wide")
        }
    }

    /// Renders the demo panel. Set PORTPILOT_UI_SNAPSHOT_DIR (TEST_RUNNER_PORTPILOT_UI_SNAPSHOT_DIR for xcodebuild)
    /// to keep the PNGs for a visual check.
    func testDemoSnapshotRendersInBothModes() throws {
        let keep = ProcessInfo.processInfo.environment["PORTPILOT_UI_SNAPSHOT_DIR"].flatMap { $0.isEmpty ? nil : $0 }
        let directory = keep.map { URL(fileURLWithPath: $0, isDirectory: true) }
            ?? FileManager.default.temporaryDirectory.appendingPathComponent("PortPilotDemo-\(UUID().uuidString)")
        defer { if keep == nil { try? FileManager.default.removeItem(at: directory) } }

        for (name, scheme) in [("demo-light", ColorScheme.light), ("demo-dark", .dark)] {
            let store = PreviewData.store(expandFeatured: true)
            let url = directory.appendingPathComponent("\(name).png")
            XCTAssertTrue(SnapshotRenderer.render(store: store, to: url, colorScheme: scheme))
            let image = try XCTUnwrap(NSImage(contentsOf: url))
            XCTAssertEqual(image.size.width, Theme.panelWidth, accuracy: 0.5)
            XCTAssertGreaterThan(image.size.height, 600, "\(name): list missing from the snapshot")
        }
        let banner = PreviewData.store(banner: PreviewData.respawnBanner)
        XCTAssertTrue(SnapshotRenderer.render(store: banner, to: directory.appendingPathComponent("demo-banner.png"),
                                              colorScheme: .dark))
    }
}
