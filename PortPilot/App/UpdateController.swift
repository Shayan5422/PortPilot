import Foundation
import Observation

/// Update-check state for the UI: the header dot, the "PortPilot 1.1.0 is available" notice, and the result of
/// "Check for Updates…". Automatic checks run at most once every 24 hours and stay silent unless they find an
/// update; manual checks always report. Nothing is installed automatically.
///
/// Inert until `startAutomaticChecks` or `checkNow` is called, so preview and snapshot stores never touch the
/// network or UserDefaults.
@MainActor
@Observable
final class UpdateController {
    /// What the last manual check said (automatic checks never change it).
    enum Phase: Equatable {
        case idle
        case checking
        case finished(UpdateCheckResult)
    }

    /// UserDefaults keys. Listed so they can be cleared in one place.
    enum Keys {
        static let lastCheckDate = "update.lastCheckDate"
        /// The newest release seen (JSON-encoded `ReleaseInfo`), kept while it is newer than this build.
        static let latestRelease = "update.latestRelease"
        static let skippedVersion = "update.skippedVersion"
        static let all = [lastCheckDate, latestRelease, skippedVersion]
    }

    nonisolated static let checkInterval: TimeInterval = 24 * 60 * 60
    /// The first automatic check waits a little so it never competes with the first scans.
    nonisolated static let firstCheckDelay: TimeInterval = 8
    /// How often the automatic loop re-evaluates whether a check is due (and retries after a network error).
    nonisolated static let pollInterval: TimeInterval = 60 * 60

    /// A newer release the user hasn't skipped.
    private(set) var availableUpdate: ReleaseInfo?
    private(set) var phase: Phase = .idle
    /// Any check (manual or automatic) in flight.
    private(set) var isChecking = false

    let currentVersion: String
    @ObservationIgnored private let checker: UpdateChecker
    @ObservationIgnored private let defaults: PreferenceStore
    @ObservationIgnored private let now: () -> Date
    @ObservationIgnored private var loopTask: Task<Void, Never>?
    @ObservationIgnored private var didRestore = false
    /// "Check for Updates…" was pressed while an automatic check was running: report that one's result.
    @ObservationIgnored private var reportRunningCheck = false

    init(currentVersion: String = AppInfo.version, checker: UpdateChecker? = nil,
         defaults: PreferenceStore = UserDefaults.standard, now: @escaping () -> Date = Date.init) {
        self.currentVersion = currentVersion
        self.checker = checker ?? UpdateChecker(currentVersion: currentVersion)
        self.defaults = defaults
        self.now = now
    }

    // MARK: Checking

    /// True when no check finished in the last `interval` (or the clock went backwards).
    nonisolated static func isDue(lastCheck: Date?, now: Date, interval: TimeInterval = checkInterval) -> Bool {
        guard let lastCheck else { return true }
        let elapsed = now.timeIntervalSince(lastCheck)
        return elapsed >= interval || elapsed < 0
    }

    var lastCheckDate: Date? { defaults.object(forKey: Keys.lastCheckDate) as? Date }

    /// Starts the background loop: first check shortly after launch, then whenever 24 h have passed.
    /// `isEnabled` is read before each check (Settings › "Check for updates automatically"). Idempotent.
    func startAutomaticChecks(isEnabled: @escaping @MainActor () -> Bool) {
        restoreIfNeeded()
        guard loopTask == nil else { return }
        loopTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(Self.firstCheckDelay))
            while !Task.isCancelled, self != nil {
                await self?.checkIfDue(isEnabled: isEnabled)
                try? await Task.sleep(for: .seconds(Self.pollInterval))
            }
        }
    }

    private func checkIfDue(isEnabled: @MainActor () -> Bool) async {
        guard isEnabled(), Self.isDue(lastCheck: lastCheckDate, now: now()) else { return }
        await performCheck(manual: false)
    }

    /// "Check for Updates…": always reports up to date, update available, or a short error.
    func checkNow() {
        restoreIfNeeded()
        Task { await performCheck(manual: true) }
    }

    private func performCheck(manual: Bool) async {
        if manual { phase = .checking }
        guard !isChecking else {
            if manual { reportRunningCheck = true }
            return
        }
        isChecking = true
        let result = await checker.check()
        isChecking = false
        let report = manual || reportRunningCheck
        reportRunningCheck = false
        apply(result, manual: report)
    }

    /// Records a result. Automatic failures are silent; a manual check also un-skips the version it finds.
    func apply(_ result: UpdateCheckResult, manual: Bool) {
        if result.isConclusive { defaults.set(now(), forKey: Keys.lastCheckDate) }
        switch result {
        case .updateAvailable(let release):
            if let data = try? JSONEncoder().encode(release) { defaults.set(data, forKey: Keys.latestRelease) }
            if manual, skippedVersion == release.version { defaults.removeObject(forKey: Keys.skippedVersion) }
            availableUpdate = skippedVersion == release.version ? nil : release
        case .upToDate, .noReleases:
            defaults.removeObject(forKey: Keys.latestRelease)
            availableUpdate = nil
        case .failed:
            break
        }
        if manual {
            phase = .finished(result)
        } else if result.isConclusive, phase != .checking {
            // A newer automatic answer replaces what an earlier manual check said.
            phase = .idle
        }
    }

    // MARK: Actions

    /// "Skip This Version": hides the notice and the header dot until a newer version appears.
    func skip(_ release: ReleaseInfo) {
        defaults.set(release.version, forKey: Keys.skippedVersion)
        if availableUpdate?.version == release.version { availableUpdate = nil }
        if case .finished(.updateAvailable) = phase { phase = .idle }
    }

    /// Opens the disk image (or the release page when the release has none) in the browser.
    func download(_ release: ReleaseInfo) {
        AppInfo.open(release.downloadOrPageURL)
    }

    func openReleaseNotes(_ release: ReleaseInfo) {
        AppInfo.open(release.pageURL)
    }

    /// Shows `release` as available without persisting anything (previews, snapshots and UI tests).
    func showForPreview(_ release: ReleaseInfo?) {
        availableUpdate = release
    }

    // MARK: Text

    /// One line for About and Settings: "Checking…", "You’re up to date (1.0.0)", "PortPilot 1.1.0 is available"...
    var statusMessage: String? {
        switch phase {
        case .idle:
            return availableUpdate.map { "PortPilot \($0.version) is available" }
        case .checking:
            return "Checking for updates…"
        case .finished(let result):
            return result.message(currentVersion: currentVersion)
        }
    }

    /// True when the last manual check failed (the status is shown in a warning colour).
    var lastCheckFailed: Bool {
        if case .finished(.failed) = phase { return true }
        return false
    }

    // MARK: Persistence

    private var skippedVersion: String? { defaults.object(forKey: Keys.skippedVersion) as? String }

    /// Brings back an update found by an earlier launch, unless it was skipped or this build is already that new.
    private func restoreIfNeeded() {
        guard !didRestore else { return }
        didRestore = true
        guard let data = defaults.object(forKey: Keys.latestRelease) as? Data,
              let release = try? JSONDecoder().decode(ReleaseInfo.self, from: data) else { return }
        guard AppVersion.isNewer(release.version, than: currentVersion) else {
            defaults.removeObject(forKey: Keys.latestRelease)
            return
        }
        if skippedVersion != release.version { availableUpdate = release }
    }
}
