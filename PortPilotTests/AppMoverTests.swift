import Darwin
import Foundation
import XCTest
@testable import PortPilot

/// "Move PortPilot to Applications", against fake app bundles in a temporary folder. Nothing here touches the
/// real /Applications, ~/Applications, LaunchAgents or running apps.
final class AppMoverTests: XCTestCase {
    private var root: URL!
    private let bundleID = "eu.shhshm.PortPilot"
    private let quarantine = "com.apple.quarantine"

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("PortPilotMoverTests-\(UUID().uuidString)",
                                                                             isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        // Read-only test folders must be writable again before they can be removed.
        if let enumerator = FileManager.default.enumerator(atPath: root.path) {
            for case let relative as String in enumerator {
                chmod((root.path as NSString).appendingPathComponent(relative), 0o755)
            }
        }
        try? FileManager.default.removeItem(at: root)
    }

    // MARK: Where we run from

    func testDeveloperBuildsAreNeverOfferedAMove() {
        let home = "/Users/someone"
        XCTAssertTrue(InstallLocation.isDeveloperBuild("\(home)/Library/Developer/Xcode/DerivedData/PortPilot-abc/Build/Products/Debug/PortPilot.app"))
        XCTAssertTrue(InstallLocation.isDeveloperBuild("\(home)/code/PortPilot/dist/PortPilot.app"))
        XCTAssertTrue(InstallLocation.isDeveloperBuild("\(home)/Downloads/PortPilot/build/Release/PortPilot.app"))
        XCTAssertFalse(InstallLocation.isDeveloperBuild("/Volumes/PortPilot/PortPilot.app"))
        XCTAssertFalse(InstallLocation.needsMove("\(home)/Downloads/PortPilot/dist/PortPilot.app", home: home))
    }

    func testCopiesOutsideApplicationsAreOfferedAMove() {
        let home = "/Users/someone"
        XCTAssertTrue(InstallLocation.needsMove("/Volumes/PortPilot/PortPilot.app", home: home))
        XCTAssertTrue(InstallLocation.needsMove("/private/var/folders/x/T/AppTranslocation/1234/d/PortPilot.app", home: home))
        XCTAssertTrue(InstallLocation.needsMove("\(home)/Downloads/PortPilot.app", home: home))
        XCTAssertTrue(InstallLocation.needsMove("\(home)/Desktop/PortPilot.app", home: home))
        XCTAssertFalse(InstallLocation.needsMove("/Applications/PortPilot.app", home: home))
        XCTAssertFalse(InstallLocation.needsMove("\(home)/Applications/PortPilot.app", home: home))

        XCTAssertEqual(InstallLocation.sourceDescription("\(home)/Downloads/PortPilot.app", home: home), "your Downloads folder")
        XCTAssertEqual(InstallLocation.sourceDescription("/Volumes/PortPilot/PortPilot.app", home: home), "the disk image")
        XCTAssertEqual(InstallLocation.sourceDescription("/private/var/folders/x/T/AppTranslocation/1/d/PortPilot.app",
                                                         home: home), "a temporary copy macOS made")
    }

    // MARK: Installing

    func testInstallsACopyAndStripsQuarantineFromTheCopyOnly() throws {
        let source = try makeBundle(at: root.appendingPathComponent("Volume/PortPilot.app"), version: "1.0.0", quarantined: true)
        let mover = makeMover(version: "1.0.0")

        let outcome = try mover.install(from: source)

        let installed = mover.systemApplications.appendingPathComponent("PortPilot.app", isDirectory: true)
        XCTAssertEqual(outcome, .installed(installed))
        XCTAssertEqual(AppMover.bundleInfo(at: installed)?.identifier, bundleID)
        XCTAssertTrue(FileManager.default.fileExists(atPath: installed.appendingPathComponent("Contents/MacOS/PortPilot").path))
        XCTAssertFalse(hasQuarantine(installed))
        XCTAssertFalse(hasQuarantine(installed.appendingPathComponent("Contents/MacOS/PortPilot")))
        XCTAssertTrue(hasQuarantine(source), "the original is never modified")
        XCTAssertTrue(hasQuarantine(source.appendingPathComponent("Contents/MacOS/PortPilot")))
    }

    func testReplacesAnOlderPortPilotAfterQuittingIt() throws {
        let source = try makeBundle(at: root.appendingPathComponent("Volume/PortPilot.app"), version: "1.2.0")
        var mover = makeMover(version: "1.2.0")
        let destination = mover.systemApplications.appendingPathComponent("PortPilot.app", isDirectory: true)
        try makeBundle(at: destination, version: "1.0.0")
        var quitAsked: URL?
        mover.quitRunningCopy = { url in quitAsked = url; return true }

        XCTAssertEqual(try mover.install(from: source), .installed(destination))
        XCTAssertEqual(AppMover.bundleInfo(at: destination)?.version, "1.2.0")
        XCTAssertEqual(quitAsked, destination)
    }

    func testRefusesToReplaceADifferentAppWithTheSameName() throws {
        let source = try makeBundle(at: root.appendingPathComponent("Volume/PortPilot.app"), version: "1.0.0")
        let mover = makeMover(version: "1.0.0")
        let destination = mover.systemApplications.appendingPathComponent("PortPilot.app", isDirectory: true)
        try makeBundle(at: destination, version: "0.1", identifier: "com.example.SomethingElse")

        XCTAssertThrowsError(try mover.install(from: source))
        XCTAssertEqual(AppMover.bundleInfo(at: destination)?.identifier, "com.example.SomethingElse", "left untouched")
    }

    func testANewerInstalledCopyIsOpenedInsteadOfDowngraded() throws {
        let source = try makeBundle(at: root.appendingPathComponent("Volume/PortPilot.app"), version: "1.0.0")
        var mover = makeMover(version: "1.0.0")
        mover.quitRunningCopy = { _ in XCTFail("nothing is replaced"); return false }
        let destination = mover.systemApplications.appendingPathComponent("PortPilot.app", isDirectory: true)
        try makeBundle(at: destination, version: "1.3.0")

        XCTAssertEqual(try mover.install(from: source), .useExisting(destination))
        XCTAssertEqual(AppMover.bundleInfo(at: destination)?.version, "1.3.0")
    }

    func testFallsBackToTheUserApplicationsFolderWhenApplicationsIsReadOnly() throws {
        let source = try makeBundle(at: root.appendingPathComponent("Volume/PortPilot.app"), version: "1.0.0")
        let mover = makeMover(version: "1.0.0")
        XCTAssertEqual(chmod(mover.systemApplications.path, 0o555), 0)

        let outcome = try mover.install(from: source)

        let installed = mover.userApplications.appendingPathComponent("PortPilot.app", isDirectory: true)
        XCTAssertEqual(outcome, .installed(installed))
        XCTAssertEqual(AppMover.bundleInfo(at: installed)?.identifier, bundleID)
        XCTAssertFalse(FileManager.default.fileExists(atPath: mover.systemApplications.appendingPathComponent("PortPilot.app", isDirectory: true).path))
    }

    func testAStillRunningCopyIsNotReplaced() throws {
        let source = try makeBundle(at: root.appendingPathComponent("Volume/PortPilot.app"), version: "1.2.0")
        var mover = makeMover(version: "1.2.0")
        mover.quitRunningCopy = { _ in false }
        let destination = mover.systemApplications.appendingPathComponent("PortPilot.app", isDirectory: true)
        try makeBundle(at: destination, version: "1.0.0")

        XCTAssertThrowsError(try mover.install(from: source))
        XCTAssertEqual(AppMover.bundleInfo(at: destination)?.version, "1.0.0")
    }

    func testShellQuoting() {
        XCTAssertEqual(AppMover.shellQuoted("/Applications/PortPilot.app"), "'/Applications/PortPilot.app'")
        XCTAssertEqual(AppMover.shellQuoted("/tmp/it's here"), "'/tmp/it'\\''s here'")
    }

    // MARK: Helpers

    private func makeMover(version: String) -> AppMover {
        var mover = AppMover(bundleIdentifier: bundleID, version: version)
        mover.systemApplications = root.appendingPathComponent("Applications", isDirectory: true)
        mover.userApplications = root.appendingPathComponent("home/Applications", isDirectory: true)
        mover.runAsAdmin = { _ in XCTFail("no admin prompt in tests"); return ShellResult(status: 1, stdout: "", stderr: "") }
        mover.quitRunningCopy = { _ in true }
        try? FileManager.default.createDirectory(at: mover.systemApplications, withIntermediateDirectories: true)
        return mover
    }

    @discardableResult
    private func makeBundle(at url: URL, version: String, identifier: String? = nil,
                            quarantined: Bool = false) throws -> URL {
        let macOS = url.appendingPathComponent("Contents/MacOS", isDirectory: true)
        try FileManager.default.createDirectory(at: macOS, withIntermediateDirectories: true)
        let info: [String: Any] = ["CFBundleIdentifier": identifier ?? bundleID, "CFBundleShortVersionString": version,
                                   "CFBundleExecutable": "PortPilot"]
        try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
            .write(to: url.appendingPathComponent("Contents/Info.plist"))
        let executable = macOS.appendingPathComponent("PortPilot")
        try Data("#!/bin/sh\n".utf8).write(to: executable)
        if quarantined {
            for path in [url.path, executable.path] {
                let value = "0081;00000000;Safari;"
                XCTAssertEqual(setxattr(path, quarantine, value, value.utf8.count, 0, XATTR_NOFOLLOW), 0)
            }
        }
        return url
    }

    private func hasQuarantine(_ url: URL) -> Bool {
        getxattr(url.path, quarantine, nil, 0, 0, XATTR_NOFOLLOW) >= 0
    }
}
