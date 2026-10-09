import Foundation
import XCTest
@testable import PortPilot

/// Version comparison, GitHub release parsing and the update state machine. ReleaseFixtures only: no test touches the
/// network or the app's real UserDefaults.
final class UpdateCheckerTests: XCTestCase {
    // MARK: Versions

    func testVersionComponentsStripLeadingVAndRejectMalformedTags() {
        XCTAssertEqual(AppVersion.components("1.2.0"), [1, 2, 0])
        XCTAssertEqual(AppVersion.components("v1.10.3"), [1, 10, 3])
        XCTAssertEqual(AppVersion.components("V2"), [2])
        XCTAssertEqual(AppVersion.components(" 1.0 "), [1, 0])
        for malformed in ["", "v", "latest", "1..2", "1.2.", ".1", "1.2.0-beta", "1.2.0b", "1.x", "1.2.3.4.5", "١.٢"] {
            XCTAssertNil(AppVersion.components(malformed), malformed)
        }
        XCTAssertEqual(AppVersion.normalized("v1.02.0"), "1.2.0")
    }

    func testVersionsCompareNumericallyComponentByComponent() {
        XCTAssertTrue(AppVersion.isNewer("1.10.0", than: "1.9.3"))
        XCTAssertTrue(AppVersion.isNewer("v2.0", than: "1.99.99"))
        XCTAssertTrue(AppVersion.isNewer("1.0.1", than: "1.0"))
        XCTAssertFalse(AppVersion.isNewer("1.9.3", than: "1.10.0"))
        XCTAssertFalse(AppVersion.isNewer("1.2", than: "1.2.0"), "missing components count as 0")
        XCTAssertFalse(AppVersion.isNewer("1.0.0", than: "1.0.0"))
        XCTAssertEqual(AppVersion.compare("1.2", "1.2.0"), .orderedSame)
        XCTAssertFalse(AppVersion.isNewer("nightly", than: "1.0.0"), "a malformed tag is never an update")
        XCTAssertFalse(AppVersion.isNewer("2.0.0", than: "dev"))
    }

    // MARK: Parsing

    func testParsesTheLatestReleaseAndPicksTheFirstDMG() throws {
        let release = try XCTUnwrap(UpdateChecker.parseLatestRelease(ReleaseFixtures.release(tag: "v1.2.0")))
        XCTAssertEqual(release.version, "1.2.0")
        XCTAssertEqual(release.tagName, "v1.2.0")
        XCTAssertEqual(release.name, "PortPilot 1.2.0")
        XCTAssertEqual(release.notes, "Faster scans.")
        XCTAssertEqual(release.pageURL.absoluteString, "https://github.com/Shayan5422/PortPilot/releases/tag/v1.2.0")
        XCTAssertEqual(release.downloadURL?.absoluteString,
                       "https://github.com/Shayan5422/PortPilot/releases/download/v1.2.0/PortPilot-1.2.0.dmg")
        XCTAssertEqual(release.downloadOrPageURL, release.downloadURL)
        XCTAssertEqual(release.publishedAt, ISO8601DateFormatter().date(from: "2026-10-01T12:00:00Z"))
    }

    func testReleaseWithoutDMGFallsBackToTheReleasePage() throws {
        let release = try XCTUnwrap(UpdateChecker.parseLatestRelease(ReleaseFixtures.release(tag: "1.3.0", assets: [])))
        XCTAssertNil(release.downloadURL)
        XCTAssertEqual(release.downloadOrPageURL, release.pageURL)
    }

    func testDraftsPrereleasesAndMalformedTagsAreSkipped() {
        XCTAssertNil(UpdateChecker.parseLatestRelease(ReleaseFixtures.release(tag: "v9.0.0", draft: true)))
        XCTAssertNil(UpdateChecker.parseLatestRelease(ReleaseFixtures.release(tag: "v9.0.0", prerelease: true)))
        XCTAssertNil(UpdateChecker.parseLatestRelease(ReleaseFixtures.release(tag: "v9.0.0-rc.1")))
        XCTAssertNil(UpdateChecker.parseLatestRelease(Data("not json".utf8)))
        XCTAssertNil(UpdateChecker.parseLatestRelease(Data("{\"name\":\"no tag\"}".utf8)))
    }

    func testOnlyHTTPSLinksFromTheResponseAreUsed() throws {
        let json = """
            {"tag_name":"v2.0.0","html_url":"javascript:alert(1)","draft":false,"prerelease":false,
             "assets":[{"name":"PortPilot.dmg","browser_download_url":"http://example.com/PortPilot.dmg"}]}
            """
        let release = try XCTUnwrap(UpdateChecker.parseLatestRelease(Data(json.utf8)))
        XCTAssertEqual(release.pageURL, AppInfo.releasesURL)
        XCTAssertNil(release.downloadURL)
    }

    func testEvaluateMapsStatusCodes() {
        let newer = ReleaseFixtures.release(tag: "v1.1.0")
        XCTAssertEqual(UpdateChecker.evaluate(status: 200, data: newer, currentVersion: "1.0.0"),
                       .updateAvailable(UpdateChecker.parseLatestRelease(newer)!))
        XCTAssertEqual(UpdateChecker.evaluate(status: 200, data: newer, currentVersion: "1.1.0"), .upToDate(latest: "1.1.0"))
        XCTAssertEqual(UpdateChecker.evaluate(status: 200, data: ReleaseFixtures.release(tag: "v1.0.0"), currentVersion: "1.2.0"),
                       .upToDate(latest: "1.0.0"))
        XCTAssertEqual(UpdateChecker.evaluate(status: 200, data: ReleaseFixtures.release(tag: "v5.0.0", prerelease: true),
                                              currentVersion: "1.0.0"), .upToDate(latest: nil))
        XCTAssertEqual(UpdateChecker.evaluate(status: 404, data: Data("{\"message\":\"Not Found\"}".utf8),
                                              currentVersion: "1.0.0"), .noReleases)
        if case .failed = UpdateChecker.evaluate(status: 403, data: Data(), currentVersion: "1.0.0") {} else {
            XCTFail("a rate limit is an error")
        }
        if case .failed = UpdateChecker.evaluate(status: 502, data: Data(), currentVersion: "1.0.0") {} else {
            XCTFail("a server error is an error")
        }
    }

    func testMessages() {
        let release = UpdateChecker.parseLatestRelease(ReleaseFixtures.release(tag: "v1.1.0"))!
        XCTAssertEqual(UpdateCheckResult.updateAvailable(release).message(currentVersion: "1.0.0"),
                       "PortPilot 1.1.0 is available")
        XCTAssertEqual(UpdateCheckResult.upToDate(latest: "1.0.0").message(currentVersion: "1.0.0"),
                       "You’re up to date (1.0.0)")
        XCTAssertTrue(UpdateCheckResult.noReleases.message(currentVersion: "1.0.0").hasPrefix("You’re up to date (1.0.0)"))
        XCTAssertTrue(UpdateCheckResult.failed("you’re offline.").message(currentVersion: "1.0.0")
            .hasPrefix("Couldn’t check for updates"))
        XCTAssertFalse(UpdateCheckResult.failed("x").isConclusive)
        XCTAssertTrue(UpdateCheckResult.noReleases.isConclusive)
    }

    // MARK: Request

    func testRequestSendsNoIdentifiers() {
        let request = UpdateChecker.request(currentVersion: "1.0.0")
        XCTAssertEqual(request.url?.absoluteString, "https://api.github.com/repos/Shayan5422/PortPilot/releases/latest")
        XCTAssertEqual(request.httpMethod, "GET")
        XCTAssertEqual(request.timeoutInterval, 10)
        XCTAssertFalse(request.httpShouldHandleCookies)
        XCTAssertEqual(request.value(forHTTPHeaderField: "Accept"), "application/vnd.github+json")
        XCTAssertEqual(request.value(forHTTPHeaderField: "User-Agent"), "PortPilot/1.0.0")
        XCTAssertEqual(Set(request.allHTTPHeaderFields?.keys.map { $0.lowercased() } ?? []), ["accept", "user-agent"])
        XCTAssertNil(request.httpBody)
    }

    func testCheckUsesTheTransportAndMapsErrors() async {
        let notFound = UpdateChecker(currentVersion: "1.0.0", transport: ReleaseFixtures.transport(status: 404))
        let result = await notFound.check()
        XCTAssertEqual(result, .noReleases)

        let offline = UpdateChecker(currentVersion: "1.0.0") { _ in throw URLError(.notConnectedToInternet) }
        let offlineResult = await offline.check()
        XCTAssertEqual(offlineResult, .failed("you’re offline."))

        let newer = UpdateChecker(currentVersion: "1.0.0",
                                  transport: ReleaseFixtures.transport(status: 200, body: ReleaseFixtures.release(tag: "v1.0.1")))
        let newerResult = await newer.check()
        guard case .updateAvailable(let release) = newerResult else { return XCTFail("expected an update") }
        XCTAssertEqual(release.version, "1.0.1")
    }
}

/// The state behind the header dot, the notice and "Check for Updates…".
@MainActor
final class UpdateControllerTests: XCTestCase {
    private var defaults: MemoryPreferences!

    override func setUp() {
        super.setUp()
        defaults = MemoryPreferences()
    }

    override func tearDown() {
        defaults = nil
        super.tearDown()
    }

    private func controller(version: String = "1.0.0", status: Int = 200, body: Data = Data(),
                            now: Date = Date()) -> UpdateController {
        UpdateController(currentVersion: version,
                         checker: UpdateChecker(currentVersion: version,
                                                transport: ReleaseFixtures.transport(status: status, body: body)),
                         defaults: defaults, now: { now })
    }

    func testAutomaticChecksRunAtMostOnceADay() {
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        XCTAssertTrue(UpdateController.isDue(lastCheck: nil, now: now))
        XCTAssertFalse(UpdateController.isDue(lastCheck: now.addingTimeInterval(-3_600), now: now))
        XCTAssertFalse(UpdateController.isDue(lastCheck: now.addingTimeInterval(-86_399), now: now))
        XCTAssertTrue(UpdateController.isDue(lastCheck: now.addingTimeInterval(-86_400), now: now))
        XCTAssertTrue(UpdateController.isDue(lastCheck: now.addingTimeInterval(3_600), now: now),
                      "a check dated in the future (clock changed) doesn't block checks")
    }

    func testAvailableUpdateIsRememberedAndRestored() {
        let release = UpdateChecker.parseLatestRelease(ReleaseFixtures.release(tag: "v1.1.0"))!
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        let first = controller(now: now)
        first.apply(.updateAvailable(release), manual: false)
        XCTAssertEqual(first.availableUpdate, release)
        XCTAssertEqual(first.lastCheckDate, now)
        XCTAssertEqual(first.phase, .idle, "automatic checks don't touch the manual status")

        let relaunched = controller()
        relaunched.startAutomaticChecks { false }
        XCTAssertEqual(relaunched.availableUpdate, release, "the dot survives a relaunch")

        let updated = controller(version: "1.1.0")
        updated.startAutomaticChecks { false }
        XCTAssertNil(updated.availableUpdate, "already running that version")
        XCTAssertNil(defaults.data(forKey: UpdateController.Keys.latestRelease))
    }

    func testSkipThisVersionHidesItUntilANewerOne() {
        let v110 = UpdateChecker.parseLatestRelease(ReleaseFixtures.release(tag: "v1.1.0"))!
        let v120 = UpdateChecker.parseLatestRelease(ReleaseFixtures.release(tag: "v1.2.0"))!
        let updates = controller()
        updates.apply(.updateAvailable(v110), manual: false)
        updates.skip(v110)
        XCTAssertNil(updates.availableUpdate)
        updates.apply(.updateAvailable(v110), manual: false)
        XCTAssertNil(updates.availableUpdate, "a skipped version stays hidden for automatic checks")

        let relaunched = controller()
        relaunched.startAutomaticChecks { false }
        XCTAssertNil(relaunched.availableUpdate)

        updates.apply(.updateAvailable(v120), manual: false)
        XCTAssertEqual(updates.availableUpdate, v120)

        updates.skip(v120)
        updates.apply(.updateAvailable(v120), manual: true)
        XCTAssertEqual(updates.availableUpdate, v120, "a manual check shows a skipped version again")
    }

    func testManualChecksAlwaysReportAndAutomaticFailuresStaySilent() {
        let updates = controller()
        updates.apply(.failed("you’re offline."), manual: false)
        XCTAssertEqual(updates.phase, .idle)
        XCTAssertNil(updates.statusMessage)
        XCTAssertNil(updates.lastCheckDate, "an error doesn't count as a check")

        updates.apply(.noReleases, manual: true)
        XCTAssertEqual(updates.statusMessage, UpdateCheckResult.noReleases.message(currentVersion: "1.0.0"))
        XCTAssertNotNil(updates.lastCheckDate)
        XCTAssertFalse(updates.lastCheckFailed)

        updates.apply(.failed("you’re offline."), manual: true)
        XCTAssertTrue(updates.lastCheckFailed)
        XCTAssertEqual(updates.statusMessage, "Couldn’t check for updates: you’re offline.")
    }

    func testCheckNowWithA404ReportsUpToDate() async throws {
        let updates = controller(status: 404)
        updates.checkNow()
        for _ in 0..<100 where updates.phase == .checking || updates.phase == .idle {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertEqual(updates.phase, .finished(.noReleases))
        XCTAssertFalse(updates.isChecking)
        XCTAssertNil(updates.availableUpdate)
        XCTAssertTrue(updates.statusMessage?.hasPrefix("You’re up to date (1.0.0)") == true)
    }

    func testCheckNowFindsAnUpdate() async throws {
        let updates = controller(status: 200, body: ReleaseFixtures.release(tag: "v1.4.0"))
        updates.checkNow()
        for _ in 0..<100 where updates.availableUpdate == nil {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertEqual(updates.availableUpdate?.version, "1.4.0")
        XCTAssertEqual(updates.statusMessage, "PortPilot 1.4.0 is available")
    }
}

enum ReleaseFixtures {
    /// A GitHub "latest release" response.
    static func release(tag: String, draft: Bool = false, prerelease: Bool = false,
                        assets: [(name: String, url: String)]? = nil) -> Data {
        let version = tag.hasPrefix("v") ? String(tag.dropFirst()) : tag
        let base = "https://github.com/Shayan5422/PortPilot/releases"
        let assetList = assets ?? [
            ("PortPilot-\(version).zip.sha256", "\(base)/download/\(tag)/PortPilot-\(version).zip.sha256"),
            ("PortPilot-\(version).dmg", "\(base)/download/\(tag)/PortPilot-\(version).dmg"),
            ("PortPilot-\(version)-arm64.dmg", "\(base)/download/\(tag)/PortPilot-\(version)-arm64.dmg"),
        ]
        let object: [String: Any] = [
            "url": "https://api.github.com/repos/Shayan5422/PortPilot/releases/1",
            "html_url": "\(base)/tag/\(tag)",
            "id": 1,
            "tag_name": tag,
            "name": "PortPilot \(version)",
            "body": "Faster scans.",
            "draft": draft,
            "prerelease": prerelease,
            "created_at": "2026-10-01T11:00:00Z",
            "published_at": "2026-10-01T12:00:00Z",
            "assets": assetList.map { ["name": $0.name, "browser_download_url": $0.url, "size": 4_200_000] },
        ]
        return try! JSONSerialization.data(withJSONObject: object)
    }

    static func transport(status: Int, body: Data = Data()) -> UpdateChecker.Transport {
        { request in
            (body, HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: [:])!)
        }
    }
}
