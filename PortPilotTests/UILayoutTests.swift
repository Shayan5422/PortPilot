import AppKit
import SwiftUI
import XCTest
@testable import PortPilot

/// Lays out real panel views with synthetic data (no system access). Rows must never be wider than the list,
/// whatever the number of ports: one over-wide row widens the whole list and clips every row's Stop button.
///
/// Set PORTPILOT_UI_SNAPSHOT_DIR (via TEST_RUNNER_PORTPILOT_UI_SNAPSHOT_DIR for xcodebuild) to keep the rendered
/// PNGs for a visual check; otherwise they go to a temporary folder that is removed.
@MainActor
final class UILayoutTests: XCTestCase {
    /// Width the list gives each row: panel width minus the list's horizontal inset.
    private let rowWidth = Theme.panelWidth - 2 * Theme.listInset

    private func fittingWidth<V: View>(_ view: V, proposedWidth: CGFloat) -> CGFloat {
        let controller = NSHostingController(rootView: view)
        return controller.sizeThatFits(in: CGSize(width: proposedWidth, height: 20_000)).width
    }

    func testGroupRowsWithManyPortsFitThePanel() {
        let store = UIFixtures.worstCaseStore()
        for group in UIFixtures.worstCaseGroups() {
            // Expanded, so ProcessRow (one java process with 10 ports) is measured too.
            let width = fittingWidth(GroupRow(group: group, store: store), proposedWidth: rowWidth)
            XCTAssertLessThanOrEqual(width, rowWidth + 0.5, "\(group.title) is \(width) pt wide")
        }
    }

    func testStartupItemWithManyPortsFitsThePanel() {
        let store = UIFixtures.worstCaseStore()
        let width = fittingWidth(StartupItemsView(store: store, isCollapsed: .constant(false)), proposedWidth: rowWidth)
        XCTAssertLessThanOrEqual(width, rowWidth + 0.5)
    }

    func testStoppedRecordWithManyPortsFitsThePanel() {
        let store = UIFixtures.worstCaseStore()
        let width = fittingWidth(RecentlyStoppedView(store: store, isCollapsed: .constant(false)), proposedWidth: rowWidth)
        XCTAssertLessThanOrEqual(width, rowWidth + 0.5)
    }

    func testSnapshotRendersTheWholeListAndBannerInBothModes() throws {
        let directory = snapshotDirectory()
        defer { if ProcessInfo.processInfo.environment["PORTPILOT_UI_SNAPSHOT_DIR"] == nil {
            try? FileManager.default.removeItem(at: directory)
        } }

        let store = UIFixtures.worstCaseStore(banner: UIFixtures.longErrorBanner)
        XCTAssertFalse(store.isPanelVisible, "snapshots must not depend on the panel being on screen")
        for (name, scheme) in [("worst-light", ColorScheme.light), ("worst-dark", .dark)] {
            let url = directory.appendingPathComponent("\(name).png")
            XCTAssertTrue(SnapshotRenderer.render(store: store, to: url, colorScheme: scheme))
            let image = try XCTUnwrap(NSImage(contentsOf: url))
            // Seven expanded groups, startup items and a stopped record: far taller than an empty panel.
            XCTAssertGreaterThan(image.size.height, 1_200, "\(name): list missing from the snapshot")
            XCTAssertEqual(image.size.width, Theme.panelWidth, accuracy: 0.5)
        }

        // Settings with a banner: the banner must be rendered there too.
        let settingsURL = directory.appendingPathComponent("settings-banner.png")
        XCTAssertTrue(SnapshotRenderer.render(store: store, to: settingsURL, colorScheme: .light, showSettings: true))
        let bannerless = UIFixtures.worstCaseStore(banner: nil)
        let plainURL = directory.appendingPathComponent("settings-plain.png")
        XCTAssertTrue(SnapshotRenderer.render(store: bannerless, to: plainURL, colorScheme: .light, showSettings: true))
        let withBanner = try XCTUnwrap(NSImage(contentsOf: settingsURL)).size.height
        let without = try XCTUnwrap(NSImage(contentsOf: plainURL)).size.height
        // In snapshots the banner's height is added below the content so nothing is hidden under it.
        XCTAssertGreaterThan(withBanner, without + 20, "banner missing from Settings")
    }

    private func snapshotDirectory() -> URL {
        if let path = ProcessInfo.processInfo.environment["PORTPILOT_UI_SNAPSHOT_DIR"], !path.isEmpty {
            return URL(fileURLWithPath: path, isDirectory: true)
        }
        return FileManager.default.temporaryDirectory
            .appendingPathComponent("PortPilotUITests-\(UUID().uuidString)", isDirectory: true)
    }
}
