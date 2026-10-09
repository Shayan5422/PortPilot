import AppKit
import SwiftUI
import XCTest
@testable import PortPilot

/// Settings persistence, folder-access state, snapshot flags, About/welcome copy and rendering. Nothing here reads
/// the user's folders, the network or the app's real UserDefaults.
final class ReleaseFeaturesTests: XCTestCase {
    // MARK: Settings persistence

    func testSettingsSavedBeforeCheckForUpdatesExistedKeepTheirValues() throws {
        // What an earlier build stored: every field except `checkForUpdates`.
        let old = """
            {"refreshInterval":5,"showApps":true,"showSystem":false,"showCountInMenuBar":false,"launchAtLogin":false,
             "notifyOnNewPorts":true,"gracefulTimeout":7,"ignoredGroupIDs":["project:/tmp/x"],"ignoredPorts":[5432],
             "sortOrder":"memory","heavyCPUThreshold":150,"heavyMemoryBytes":4000000000}
            """
        XCTAssertNil(try? JSONDecoder().decode(AppSettings.self, from: Data(old.utf8)),
                     "synthesized decoding rejects it, which used to reset every setting")
        let settings = try XCTUnwrap(AppSettings.decoded(from: Data(old.utf8)))
        XCTAssertEqual(settings.refreshInterval, 5)
        XCTAssertTrue(settings.showApps)
        XCTAssertFalse(settings.showCountInMenuBar)
        XCTAssertFalse(settings.launchAtLogin)
        XCTAssertTrue(settings.notifyOnNewPorts)
        XCTAssertEqual(settings.gracefulTimeout, 7)
        XCTAssertEqual(settings.ignoredGroupIDs, ["project:/tmp/x"])
        XCTAssertEqual(settings.ignoredPorts, [5432])
        XCTAssertEqual(settings.sortOrder, .memory)
        XCTAssertEqual(settings.heavyCPUThreshold, 150)
        XCTAssertEqual(settings.heavyMemoryBytes, 4_000_000_000)
        XCTAssertTrue(settings.checkForUpdates, "new fields get their default")
    }

    func testSettingsRoundTripAndBadValuesFallBackPerField() throws {
        var custom = AppSettings()
        custom.checkForUpdates = false
        custom.sortOrder = .newest
        custom.ignoredPorts = [3000, 8080]
        XCTAssertEqual(AppSettings.decoded(from: try JSONEncoder().encode(custom)), custom)

        let odd = """
            {"refreshInterval":"fast","sortOrder":"alphabetical","showApps":true,"someFutureSetting":42,
             "checkForUpdates":false}
            """
        let settings = try XCTUnwrap(AppSettings.decoded(from: Data(odd.utf8)))
        XCTAssertEqual(settings.refreshInterval, AppSettings().refreshInterval)
        XCTAssertEqual(settings.sortOrder, AppSettings().sortOrder)
        XCTAssertTrue(settings.showApps)
        XCTAssertFalse(settings.checkForUpdates)

        XCTAssertNil(AppSettings.decoded(from: Data("[1,2]".utf8)))
        XCTAssertNil(AppSettings.decoded(from: Data("garbage".utf8)))
    }

    // MARK: Copy

    func testVersionLine() {
        XCTAssertEqual(AppInfo.versionLine(version: "1.0.0", build: "1"), "Version 1.0.0 (1)")
        XCTAssertEqual(AppInfo.versionLine(version: "1.0.0", build: "1.0.0"), "Version 1.0.0")
        XCTAssertEqual(AppInfo.versionLine(version: "1.0.0", build: ""), "Version 1.0.0")
    }

    func testInfoPlistCarriesTheCopyrightAndFolderPurposeStrings() throws {
        let info = try XCTUnwrap(Bundle.main.infoDictionary)
        XCTAssertEqual(info["NSHumanReadableCopyright"] as? String, "© 2026 Shayan Hashemi. MIT License.")
        let purpose = "PortPilot reads project files such as package.json and .git to show which project each server "
            + "comes from. It never changes your files."
        for key in ["NSDownloadsFolderUsageDescription", "NSDocumentsFolderUsageDescription",
                    "NSDesktopFolderUsageDescription", "NSRemovableVolumesUsageDescription",
                    "NSNetworkVolumesUsageDescription"] {
            XCTAssertEqual(info[key] as? String, purpose, key)
        }
        XCTAssertEqual(AppInfo.version, info["CFBundleShortVersionString"] as? String)
        XCTAssertEqual(AppInfo.build, info["CFBundleVersion"] as? String)
    }

    @MainActor
    func testSettingsCopy() {
        XCTAssertEqual(SettingsText.launchAtLoginSubtitle(canManage: false),
                       "Move PortPilot to Applications to start it at login")
        XCTAssertFalse(AppStore.canManageLoginItem, "never from the XCTest host")
        XCTAssertEqual(SettingsText.folderAccessSubtitle(denied: ["/Users/x/Downloads"]),
                       "Downloads — Not allowed. Projects there show by folder name only.")
    }

    // MARK: Folder access

    func testFolderNamesAndMessages() {
        XCTAssertEqual(FolderAccess.displayName(for: "/Users/x/Downloads"), "Downloads")
        XCTAssertEqual(FolderAccess.displayName(for: "/Users/x/Library/Mobile Documents"), "iCloud Drive")
        XCTAssertEqual(FolderAccess.displayName(for: "/Users/x/Library/CloudStorage/GoogleDrive-me@example.com"),
                       "Google Drive", "the account part is never shown")
        XCTAssertEqual(FolderAccess.displayName(for: "/Users/x/Library/CloudStorage/Dropbox"), "Dropbox")
        XCTAssertEqual(FolderAccess.displayName(for: "/Volumes/Backup"), "Backup")
        XCTAssertEqual(FolderAccess.list(["Downloads"]), "Downloads")
        XCTAssertEqual(FolderAccess.list(["Downloads", "Desktop"]), "Downloads and Desktop")
        XCTAssertEqual(FolderAccess.list(["Downloads", "Documents", "Desktop"]), "Downloads, Documents and Desktop")
        XCTAssertNil(FolderAccess.waitingMessage(for: []))
        XCTAssertEqual(FolderAccess.waitingMessage(for: ["/Users/x/Downloads"]),
                       "Waiting for access to Downloads. Click Allow in the macOS prompt so PortPilot can name your projects.")
        XCTAssertEqual(FolderAccess.standardFolders(home: "/Users/x"),
                       ["/Users/x/Downloads", "/Users/x/Documents", "/Users/x/Desktop"])
    }

    func testReadErrorsAreClassified() throws {
        XCTAssertEqual(FolderAccess.state(forReadError: nil), .allowed)
        XCTAssertEqual(FolderAccess.state(forReadError: CocoaError(.fileReadNoPermission)), .denied)
        XCTAssertEqual(FolderAccess.state(forReadError: NSError(domain: NSPOSIXErrorDomain, code: Int(EPERM))), .denied)
        XCTAssertEqual(FolderAccess.state(forReadError: CocoaError(.fileReadNoSuchFile)), .missing)

        // Real reads in a scratch folder (never a protected one).
        let scratch = FileManager.default.temporaryDirectory.appendingPathComponent("PortPilotFolderAccess-\(UUID())")
        let locked = scratch.appendingPathComponent("locked")
        try FileManager.default.createDirectory(at: locked, withIntermediateDirectories: true)
        defer {
            chmod(locked.path, 0o755)
            try? FileManager.default.removeItem(at: scratch)
        }
        XCTAssertEqual(FolderAccess.probe(scratch.path), .allowed)
        XCTAssertEqual(FolderAccess.probe(scratch.appendingPathComponent("missing").path), .missing)
        XCTAssertEqual(chmod(locked.path, 0o000), 0)
        XCTAssertEqual(FolderAccess.probe(locked.path), .denied)
    }

    // MARK: Panel pages & snapshot flags

    func testGearFromAboutGoesToSettings() {
        var settings = false, about = true
        PanelPages.toggleSettings(settings: &settings, about: &about)
        XCTAssertEqual([settings, about], [true, false])
        PanelPages.toggleSettings(settings: &settings, about: &about)
        XCTAssertEqual([settings, about], [false, false])
    }

    func testSnapshotFlags() {
        XCTAssertEqual(SnapshotOptions(arguments: ["--snapshot", "a.png"]).page, .list)
        XCTAssertEqual(SnapshotOptions(arguments: ["--snapshot", "a.png", "--settings"]).page, .settings)
        XCTAssertEqual(SnapshotOptions(arguments: ["--snapshot", "a.png", "--about", "--settings"]).page, .about)
        XCTAssertEqual(SnapshotOptions(arguments: ["--snapshot", "a.png", "--welcome"]).page, .welcome)
        XCTAssertEqual(SnapshotOptions(arguments: ["--snapshot", "a.png", "--welcome", "--folder-step"]).page,
                       .welcomeFolders)
        let options = SnapshotOptions(arguments: ["--snapshot", "a.png", "--demo", "--dark", "--expand-all", "--all",
                                                  "--welcome", "--move"])
        XCTAssertTrue(options.demo && options.dark && options.expandAll && options.showAll && options.showMove)
        XCTAssertFalse(SnapshotOptions(arguments: ["--snapshot", "a.png"]).demo)
    }
}

/// Folder-access tracking with a fake probe: a folder is only read once it was asked about.
@MainActor
final class FolderAccessControllerTests: XCTestCase {
    private var defaults: MemoryPreferences!
    private let downloads = "/Users/x/Downloads"
    private let desktop = "/Users/x/Desktop"

    override func setUp() {
        super.setUp()
        defaults = MemoryPreferences()
    }

    override func tearDown() {
        defaults = nil
        super.tearDown()
    }

    func testInactiveControllerNeverReads() {
        let probes = ProbeLog()
        let controller = FolderAccessController(defaults: defaults, probe: probes.probe(answer: .denied))
        controller.scanReported(awaiting: [downloads])
        controller.scanReported(awaiting: [])
        controller.refresh()
        controller.requestAccess(to: [downloads])
        XCTAssertTrue(probes.paths.isEmpty)
        XCTAssertNil(defaults.stringArray(forKey: FolderAccessController.Keys.asked))
    }

    func testWaitingFolderIsCheckedOnceThePromptIsAnswered() async throws {
        let probes = ProbeLog()
        let controller = FolderAccessController(defaults: defaults, probe: probes.probe(answer: .denied))
        controller.activate()
        XCTAssertTrue(probes.paths.isEmpty, "nothing asked yet, so nothing is read")

        controller.scanReported(awaiting: [downloads])
        XCTAssertEqual(controller.waitingMessage, FolderAccess.waitingMessage(for: [downloads]))
        XCTAssertEqual(controller.state(of: downloads), .asking)
        XCTAssertEqual(defaults.stringArray(forKey: FolderAccessController.Keys.asked), [downloads])

        controller.scanReported(awaiting: [])
        XCTAssertNil(controller.waitingMessage)
        try await waitUntil { controller.denied == [self.downloads] }
        XCTAssertEqual(probes.paths, [downloads])
    }

    func testRefreshOnlyReadsFoldersAskedAbout() async throws {
        defaults.set([desktop], forKey: FolderAccessController.Keys.asked)
        let probes = ProbeLog()
        let controller = FolderAccessController(defaults: defaults, probe: probes.probe(answer: .allowed))
        controller.activate()
        try await waitUntil { controller.state(of: self.desktop) == .allowed }
        controller.refresh()
        try await waitUntil { probes.paths.count == 2 }
        XCTAssertEqual(Set(probes.paths), [desktop])
        XCTAssertEqual(controller.state(of: downloads), .notAsked)
    }

    func testRequestAskedForEachExistingFolderInTurn() async throws {
        let scratch = FileManager.default.temporaryDirectory.appendingPathComponent("PortPilotRequest-\(UUID())")
        let first = scratch.appendingPathComponent("A").path
        let second = scratch.appendingPathComponent("B").path
        let missing = scratch.appendingPathComponent("C").path
        try FileManager.default.createDirectory(atPath: first, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(atPath: second, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: scratch) }

        let probes = ProbeLog()
        let controller = FolderAccessController(defaults: defaults, probe: probes.probe { $0.hasSuffix("/B") ? .denied : .allowed })
        controller.activate()
        var finished = false
        controller.requestAccess(to: [first, second, missing]) { finished = true }
        XCTAssertTrue(controller.isRequesting)
        try await waitUntil { finished }
        XCTAssertFalse(controller.isRequesting)
        XCTAssertEqual(probes.paths, [first, second], "one at a time, in order, skipping missing folders")
        XCTAssertEqual(controller.state(of: first), .allowed)
        XCTAssertEqual(controller.state(of: second), .denied)
        XCTAssertEqual(controller.state(of: missing), .missing)
        XCTAssertEqual(controller.denied, [second])
        XCTAssertEqual(defaults.stringArray(forKey: FolderAccessController.Keys.asked), [first, second])
    }

    private func waitUntil(_ condition: @escaping () -> Bool, file: StaticString = #filePath, line: UInt = #line) async throws {
        for _ in 0..<200 {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTFail("timed out", file: file, line: line)
    }
}

/// Records which folders a fake probe was asked to read (from the controller's background queue).
private final class ProbeLog: @unchecked Sendable {
    private let lock = NSLock()
    private var log: [String] = []

    var paths: [String] {
        lock.lock()
        defer { lock.unlock() }
        return log
    }

    func probe(answer: FolderAccessState) -> @Sendable (String) -> FolderAccessState {
        probe { _ in answer }
    }

    func probe(_ answer: @escaping @Sendable (String) -> FolderAccessState) -> @Sendable (String) -> FolderAccessState {
        { [self] path in
            lock.lock()
            log.append(path)
            lock.unlock()
            return answer(path)
        }
    }
}

/// Renders the new pages and notices offscreen (no system access): they must fit, in light and dark.
/// Set PORTPILOT_UI_SNAPSHOT_DIR (TEST_RUNNER_PORTPILOT_UI_SNAPSHOT_DIR for xcodebuild) to keep the PNGs.
@MainActor
final class ReleaseFeaturesLayoutTests: XCTestCase {
    private let rowWidth = Theme.panelWidth - 2 * Theme.listInset

    private func store() -> AppStore {
        AppStore(previewSnapshot: .empty, startupItems: [], recentlyStopped: [])
    }

    private var sampleRelease: ReleaseInfo {
        UpdateChecker.parseLatestRelease(ReleaseFixtures.release(tag: "v1.1.0"))!
    }

    func testNoticesFitTheList() {
        let store = store()
        store.updates.showForPreview(sampleRelease)
        store.folderAccess.showForPreview([:], awaiting: [NSHomeDirectory() + "/Downloads", NSHomeDirectory() + "/Desktop"])
        let size = NSHostingController(rootView: PanelNotices(store: store))
            .sizeThatFits(in: CGSize(width: rowWidth, height: 2_000))
        XCTAssertLessThanOrEqual(size.width, rowWidth + 0.5)
        XCTAssertGreaterThan(size.height, 60)

        let empty = NSHostingController(rootView: PanelNotices(store: self.store()))
            .sizeThatFits(in: CGSize(width: rowWidth, height: 2_000))
        XCTAssertEqual(empty.height, 0, accuracy: 0.5, "no notices, no space")
    }

    func testWelcomeStepsFitTheirFixedWindowSize() {
        for move in [false, true] {
            for step in [WelcomeModel.Step.intro, .folderAccess] {
                let model = WelcomeModel(store: store(), step: step, moveSource: move ? "your Downloads folder" : nil,
                                         folders: FolderAccess.standardFolders(), isPreview: true)
                let natural = NSHostingController(rootView: WelcomeView(model: model, fixedSize: false))
                    .sizeThatFits(in: CGSize(width: WelcomeView.width, height: 4_000))
                XCTAssertLessThanOrEqual(natural.height, WelcomeView.height(hasMoveCallout: move),
                                         "\(step) move=\(move) needs \(natural.height) pt")
                XCTAssertLessThanOrEqual(natural.width, WelcomeView.width + 0.5)
            }
        }
    }

    func testAboutSettingsWelcomeAndNoticesRenderInBothModes() throws {
        let directory = snapshotDirectory()
        defer { if ProcessInfo.processInfo.environment["PORTPILOT_UI_SNAPSHOT_DIR"] == nil {
            try? FileManager.default.removeItem(at: directory)
        } }

        let withUpdate = store()
        withUpdate.updates.showForPreview(sampleRelease)
        withUpdate.folderAccess.showForPreview([NSHomeDirectory() + "/Downloads": .denied],
                                               awaiting: [NSHomeDirectory() + "/Desktop"])
        for (suffix, scheme) in [("light", ColorScheme.light), ("dark", .dark)] {
            let about = directory.appendingPathComponent("about-\(suffix).png")
            XCTAssertTrue(SnapshotRenderer.render(store: store(), to: about, colorScheme: scheme, showAbout: true))
            XCTAssertEqual(try XCTUnwrap(NSImage(contentsOf: about)).size.width, Theme.panelWidth, accuracy: 0.5)

            let aboutUpdate = directory.appendingPathComponent("about-update-\(suffix).png")
            XCTAssertTrue(SnapshotRenderer.render(store: withUpdate, to: aboutUpdate, colorScheme: scheme, showAbout: true))
            let settings = directory.appendingPathComponent("settings-\(suffix).png")
            XCTAssertTrue(SnapshotRenderer.render(store: withUpdate, to: settings, colorScheme: scheme, showSettings: true))
            let list = directory.appendingPathComponent("notices-\(suffix).png")
            XCTAssertTrue(SnapshotRenderer.render(store: withUpdate, to: list, colorScheme: scheme))

            let answered = store()
            let folders = FolderAccess.standardFolders()
            answered.folderAccess.showForPreview([folders[0]: .allowed, folders[1]: .denied, folders[2]: .asking])
            for (name, step, move) in [("welcome", WelcomeModel.Step.intro, false), ("welcome-move", .intro, true),
                                       ("welcome-folders", .folderAccess, false),
                                       ("welcome-folders-answered", .folderAccess, false)] {
                let isAnswered = name.hasSuffix("answered")
                let model = WelcomeModel(store: isAnswered ? answered : store(), step: step,
                                         moveSource: move ? "your Downloads folder" : nil,
                                         folders: folders, isPreview: true, didRequestAccess: isAnswered)
                let url = directory.appendingPathComponent("\(name)-\(suffix).png")
                XCTAssertTrue(SnapshotRenderer.renderWelcome(model, to: url, colorScheme: scheme))
                let image = try XCTUnwrap(NSImage(contentsOf: url))
                XCTAssertEqual(image.size.width, WelcomeView.width, accuracy: 0.5)
                XCTAssertEqual(image.size.height, WelcomeView.height(hasMoveCallout: move), accuracy: 0.5)
            }
        }
    }

    private func snapshotDirectory() -> URL {
        if let path = ProcessInfo.processInfo.environment["PORTPILOT_UI_SNAPSHOT_DIR"], !path.isEmpty {
            return URL(fileURLWithPath: path, isDirectory: true)
        }
        return FileManager.default.temporaryDirectory
            .appendingPathComponent("PortPilotFeatureUITests-\(UUID().uuidString)", isDirectory: true)
    }
}

/// The menu bar item lookup the welcome window uses to open the panel. The XCTest host is the real app, so its
/// MenuBarExtra status item exists unless the session has no menu bar.
@MainActor
final class StatusItemAccessTests: XCTestCase {
    func testFindsTheMenuBarExtraButton() throws {
        try XCTSkipIf(!NSApp.windows.contains { $0.className.contains("NSStatusBarWindow") },
                      "no status item in this session")
        XCTAssertNotNil(StatusItemAccess.button())
    }
}

/// In-memory `PreferenceStore`: tests never create preference files.
final class MemoryPreferences: PreferenceStore {
    private var values: [String: Any] = [:]

    func object(forKey key: String) -> Any? { values[key] }
    func set(_ value: Any?, forKey key: String) { values[key] = value }
    func removeObject(forKey key: String) { values[key] = nil }

    func data(forKey key: String) -> Data? { values[key] as? Data }
    func stringArray(forKey key: String) -> [String]? { values[key] as? [String] }
}
