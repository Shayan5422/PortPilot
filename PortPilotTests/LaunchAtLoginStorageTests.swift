import XCTest
@testable import PortPilot

/// How settings are stored by a copy that can't manage Launch at login (a disk image, Downloads, a build folder):
/// its switch only shows the truth for that copy, so it never replaces the user's stored choice. Move to Applications
/// and the installed copy's first run go by that choice, or by the default (on).
final class LaunchAtLoginStorageTests: XCTestCase {
    private func object(_ data: Data?) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(data)) as? [String: Any])
    }

    func testACopyThatCannotManageItStoresNoChoiceOfItsOwn() throws {
        var settings = AppSettings()
        settings.launchAtLogin = false      // what a disk-image copy's switch shows
        settings.notifyOnNewPorts = true    // a real choice made in its welcome window
        let data = AppStore.settingsDataToStore(settings, canManageLoginItem: false, stored: nil)

        let stored = try object(data)
        XCTAssertNil(stored["launchAtLogin"], "no choice was made: the installed copy's first run still turns it on")
        XCTAssertEqual(stored["notifyOnNewPorts"] as? Bool, true)
        XCTAssertNil(AppStore.storedLaunchAtLoginChoice(in: data))

        let decoded = try XCTUnwrap(AppSettings.decoded(from: XCTUnwrap(data)))
        XCTAssertTrue(decoded.notifyOnNewPorts)
        XCTAssertTrue(decoded.launchAtLogin, "the default")
    }

    func testAChoiceMadeInTheInstalledCopyIsKept() throws {
        var installed = AppSettings()
        installed.launchAtLogin = false
        let storedOff = AppStore.settingsDataToStore(installed, canManageLoginItem: true, stored: nil)
        XCTAssertEqual(AppStore.storedLaunchAtLoginChoice(in: storedOff), false)

        // A disk-image copy changes another setting: the stored choice stays, whatever its own switch shows.
        var other = AppSettings()
        other.launchAtLogin = true
        other.refreshInterval = 5
        let data = AppStore.settingsDataToStore(other, canManageLoginItem: false, stored: storedOff)
        XCTAssertEqual(AppStore.storedLaunchAtLoginChoice(in: data), false)
        XCTAssertEqual(try XCTUnwrap(AppSettings.decoded(from: XCTUnwrap(data))).refreshInterval, 5)

        // The installed copy stores what its switch says.
        XCTAssertEqual(AppStore.storedLaunchAtLoginChoice(
            in: AppStore.settingsDataToStore(other, canManageLoginItem: true, stored: storedOff)), true)
    }

    func testStoredChoiceIgnoresDataThatIsNotSettings() {
        XCTAssertNil(AppStore.storedLaunchAtLoginChoice(in: nil))
        XCTAssertNil(AppStore.storedLaunchAtLoginChoice(in: Data("not json".utf8)))
        XCTAssertNil(AppStore.storedLaunchAtLoginChoice(in: Data("[true]".utf8)))
        XCTAssertNil(AppStore.storedLaunchAtLoginChoice(in: Data(#"{"launchAtLogin":"yes"}"#.utf8)))
        XCTAssertEqual(AppStore.storedLaunchAtLoginChoice(in: Data(#"{"launchAtLogin":true}"#.utf8)), true)
    }

    @MainActor
    func testSnapshotsOfSampleDataShowTheSwitchOfTheCopyTheyDepict() {
        let preview = AppStore(previewSnapshot: .empty, startupItems: [], recentlyStopped: [])
        XCTAssertFalse(preview.canManageLaunchAtLogin, "the XCTest host can't manage it")
        preview.previewCanManageLoginItem = true
        XCTAssertTrue(preview.canManageLaunchAtLogin)

        // A store with an engine always tells the truth.
        let live = AppStore(engine: ScanEngine(resolver: ResolverTestFS().makeResolver()))
        live.previewCanManageLoginItem = true
        XCTAssertFalse(live.canManageLaunchAtLogin)
    }
}
