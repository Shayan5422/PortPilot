import AppKit
import Darwin
import Foundation

/// Where PortPilot runs from, and whether to offer "Move PortPilot to Applications". Pure.
enum InstallLocation {
    /// Built by Xcode or the build scripts (DerivedData, dist/, build/): never offered a move.
    static func isDeveloperBuild(_ bundlePath: String) -> Bool {
        let folders = (bundlePath as NSString).pathComponents.dropLast().map { $0.lowercased() }
        return folders.contains { ["deriveddata", "dist", "build"].contains($0) }
    }

    /// True when PortPilot lives in /Applications or ~/Applications (where launch at login is managed).
    static func isInApplications(_ bundlePath: String, home: String = NSHomeDirectory()) -> Bool {
        bundlePath.hasPrefix("/Applications/") || bundlePath.hasPrefix(home + "/Applications/")
    }

    /// True when "Move PortPilot to Applications" should be offered: running from a disk image (/Volumes/…), from
    /// App Translocation (a quarantined app opened where it was downloaded), from ~/Downloads or any other folder
    /// outside Applications, and not a developer build. Launch at login and updates need a stable place.
    static func needsMove(_ bundlePath: String, home: String = NSHomeDirectory()) -> Bool {
        !isDeveloperBuild(bundlePath) && !isInApplications(bundlePath, home: home)
    }

    /// Where the app runs from, for "It’s running from …".
    static func sourceDescription(_ bundlePath: String, home: String = NSHomeDirectory()) -> String {
        if bundlePath.hasPrefix(home + "/Downloads/") { return "your Downloads folder" }
        if bundlePath.contains("/AppTranslocation/") { return "a temporary copy macOS made" }
        if bundlePath.hasPrefix("/Volumes/") { return "the disk image" }
        let folder = (bundlePath as NSString).deletingLastPathComponent
        return Format.abbreviatePath(folder)
    }
}

/// Copies PortPilot into Applications ("Move PortPilot to Applications" in the welcome window).
///
/// Safety rules: the copy is staged in a temporary folder and only its own quarantine attribute is removed; the
/// only thing ever deleted is an older PortPilot already in the destination, and only after its bundle id was
/// confirmed to be ours. A newer copy already installed is opened instead of being downgraded. The running copy
/// (a disk image, Downloads) is left where it is.
struct AppMover {
    enum Outcome: Equatable {
        /// Copied (or replaced) at this location.
        case installed(URL)
        /// A same-or-newer PortPilot is already there; open it instead.
        case useExisting(URL)
    }

    static let bundleName = "PortPilot.app"

    let bundleIdentifier: String
    let version: String
    var systemApplications = URL(fileURLWithPath: "/Applications", isDirectory: true)
    var userApplications = URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
        .appendingPathComponent("Applications", isDirectory: true)
    /// Runs a shell command with administrator rights (Shell.runAsAdmin); used only to replace a copy we can't.
    var runAsAdmin: (String) -> ShellResult = Shell.runAsAdmin
    /// Quits a running copy at the destination before it is replaced; false when it wouldn't quit.
    var quitRunningCopy: (URL) -> Bool = { AppMover.quitRunningApp(at: $0) }

    /// The current app's identity.
    static func forCurrentApp() -> AppMover {
        AppMover(bundleIdentifier: Bundle.main.bundleIdentifier ?? "eu.shhshm.PortPilot", version: AppInfo.version)
    }

    /// Installs `source` in /Applications, or in ~/Applications when /Applications isn't writable.
    /// Blocking (copies a few MB): call off the main thread.
    func install(from source: URL) throws -> Outcome {
        let fileManager = FileManager.default
        if fileManager.isWritableFile(atPath: systemApplications.path) {
            return try install(source, at: systemApplications.appendingPathComponent(Self.bundleName, isDirectory: true), allowAdmin: true)
        }
        do {
            try fileManager.createDirectory(at: userApplications, withIntermediateDirectories: true)
        } catch {
            throw ControlError(message: "Couldn’t create \(Format.abbreviatePath(userApplications.path)): \(error.localizedDescription)")
        }
        return try install(source, at: userApplications.appendingPathComponent(Self.bundleName, isDirectory: true), allowAdmin: false)
    }

    private func install(_ source: URL, at destination: URL, allowAdmin: Bool) throws -> Outcome {
        let fileManager = FileManager.default
        if source.resolvingSymlinksInPath().standardizedFileURL == destination.resolvingSymlinksInPath().standardizedFileURL {
            return .useExisting(destination)
        }
        var replacing = false
        if fileManager.fileExists(atPath: destination.path) {
            let existing = Self.bundleInfo(at: destination)
            guard existing?.identifier == bundleIdentifier else {
                throw ControlError(message: "\(Format.abbreviatePath(destination.deletingLastPathComponent().path)) "
                    + "already has a different app named PortPilot. Rename it, then try again.")
            }
            if let installed = existing?.version, let order = AppVersion.compare(installed, version),
               order != .orderedAscending {
                return .useExisting(destination)
            }
            replacing = true
        }

        // 1. Stage a copy next to the destination's volume and strip the quarantine flag from that copy only
        //    (a quarantined copy would be translocated again at launch).
        let staging: URL
        do {
            staging = try fileManager.url(for: .itemReplacementDirectory, in: .userDomainMask,
                                          appropriateFor: destination, create: true)
        } catch {
            staging = fileManager.temporaryDirectory.appendingPathComponent("PortPilot-\(UUID().uuidString)", isDirectory: true)
            try fileManager.createDirectory(at: staging, withIntermediateDirectories: true)
        }
        defer { try? fileManager.removeItem(at: staging) }
        let staged = staging.appendingPathComponent(Self.bundleName, isDirectory: true)
        do {
            try fileManager.copyItem(at: source, to: staged)
        } catch {
            throw ControlError(message: "Couldn’t copy PortPilot: \(error.localizedDescription)")
        }
        Self.removeQuarantine(from: staged)

        // 2. Put it in place. The copy being replaced must not be running.
        if replacing, !quitRunningCopy(destination) {
            throw ControlError(message: "Quit the PortPilot in \(Format.abbreviatePath(destination.deletingLastPathComponent().path)), then try again.")
        }
        do {
            if replacing {
                _ = try fileManager.replaceItemAt(destination, withItemAt: staged)
            } else {
                try fileManager.moveItem(at: staged, to: destination)
            }
        } catch {
            guard allowAdmin, Self.isPermissionError(error) else {
                throw ControlError(message: "Couldn’t move PortPilot to \(Format.abbreviatePath(destination.deletingLastPathComponent().path)): \(error.localizedDescription)")
            }
            try installAsAdmin(staged, at: destination, replacing: replacing)
        }
        return .installed(destination)
    }

    /// An existing copy we may not replace ourselves (installed by another user): ask for an administrator.
    private func installAsAdmin(_ staged: URL, at destination: URL, replacing: Bool) throws {
        let target = Self.shellQuoted(destination.path)
        let copy = "/usr/bin/ditto \(Self.shellQuoted(staged.path)) \(target)"
        // Only the verified PortPilot bundle at `destination` is removed.
        let command = replacing ? "/bin/rm -rf \(target) && \(copy)" : copy
        let result = runAsAdmin(command)
        guard result.ok else {
            if result.stderr.contains("-128") { throw ControlError(message: "Move to Applications was cancelled.") }
            throw ControlError(message: "Couldn’t move PortPilot to Applications: \(result.stderr.trimmingCharacters(in: .whitespacesAndNewlines))")
        }
    }

    // MARK: Helpers

    /// CFBundleIdentifier and CFBundleShortVersionString of the bundle at `url` (read fresh, never cached).
    static func bundleInfo(at url: URL) -> (identifier: String?, version: String?)? {
        let plistURL = url.appendingPathComponent("Contents/Info.plist", isDirectory: false)
        guard let data = try? Data(contentsOf: plistURL),
              let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
        else { return nil }
        return (plist["CFBundleIdentifier"] as? String, plist["CFBundleShortVersionString"] as? String)
    }

    /// Removes `com.apple.quarantine` from `url` and everything inside it (symlinks themselves, not their targets).
    /// Returns how many items still carry it (0 on success).
    @discardableResult
    static func removeQuarantine(from url: URL) -> Int {
        let attribute = "com.apple.quarantine"
        var failures = 0
        func strip(_ path: String) {
            if removexattr(path, attribute, XATTR_NOFOLLOW) != 0, errno != ENOATTR { failures += 1 }
        }
        strip(url.path)
        if let enumerator = FileManager.default.enumerator(atPath: url.path) {
            for case let relative as String in enumerator {
                strip((url.path as NSString).appendingPathComponent(relative))
            }
        }
        return failures
    }

    static func isPermissionError(_ error: Error) -> Bool {
        let nsError = error as NSError
        if nsError.domain == NSCocoaErrorDomain,
           [NSFileWriteNoPermissionError, NSFileReadNoPermissionError].contains(nsError.code) { return true }
        let posix = nsError.domain == NSPOSIXErrorDomain ? nsError : nsError.userInfo[NSUnderlyingErrorKey] as? NSError
        return posix?.domain == NSPOSIXErrorDomain && [Int(EPERM), Int(EACCES)].contains(posix?.code ?? 0)
    }

    /// Single-quotes a path for /bin/sh.
    static func shellQuoted(_ text: String) -> String {
        "'" + text.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    /// Asks a PortPilot running from `bundleURL` to quit and waits up to 5 s. True when none is left running.
    static func quitRunningApp(at bundleURL: URL) -> Bool {
        let target = bundleURL.resolvingSymlinksInPath().standardizedFileURL
        let me = ProcessInfo.processInfo.processIdentifier
        let running = NSWorkspace.shared.runningApplications.filter { app in
            app.processIdentifier != me
                && app.bundleURL?.resolvingSymlinksInPath().standardizedFileURL == target
        }
        guard !running.isEmpty else { return true }
        running.forEach { $0.terminate() }
        let deadline = Date().addingTimeInterval(5)
        while Date() < deadline {
            if running.allSatisfy(\.isTerminated) { return true }
            Thread.sleep(forTimeInterval: 0.1)
        }
        return running.allSatisfy(\.isTerminated)
    }

    /// Opens the app at `bundleURL` once this process has exited (the new copy's single-instance check must not
    /// see us), from a detached helper. The caller quits right after. False if the helper couldn't start.
    static func relaunch(_ bundleURL: URL, afterExitOf pid: Int32 = ProcessInfo.processInfo.processIdentifier) -> Bool {
        // Waits at most 10 s for us to exit, then opens a new instance of the copy.
        let script = "i=0; while /bin/kill -0 \"$1\" 2>/dev/null && [ \"$i\" -lt 100 ]; do /bin/sleep 0.1; i=$((i+1)); done; "
            + "exec /usr/bin/open -n \"$2\""
        return LoginItemManager.spawnDetached("/bin/sh", ["-c", script, "sh", String(pid), bundleURL.path])
    }
}
