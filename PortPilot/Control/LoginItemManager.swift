import Darwin
import Foundation
import os

/// Keeps PortPilot running: a LaunchAgent at ~/Library/LaunchAgents/eu.shhshm.PortPilot.agent.plist with
/// ProgramArguments=[<Bundle.main.executablePath>], RunAtLoad=true, KeepAlive={SuccessfulExit=false} (restart after
/// a crash, not after Quit), ProcessType=Interactive, LimitLoadToSessionType=Aqua, and stdout/stderr going to
/// ~/Library/Logs/PortPilot/portpilot.log.
final class LoginItemManager {
    static let label = "eu.shhshm.PortPilot.agent"

    /// Runs an executable with arguments; injectable so tests never touch the real launchd domain.
    typealias CommandRunner = (_ executable: String, _ arguments: [String]) -> ShellResult
    /// Starts an executable detached from PortPilot (own session) without waiting; true when it was started.
    typealias DetachedLauncher = (_ executable: String, _ arguments: [String]) -> Bool

    private let launchAgentsDirectory: URL
    private let executablePath: String?
    private let uid: uid_t
    private let logFileURL: URL
    private let bundleIdentifier: String?
    private let ownPID: Int32
    private let environment: [String: String]
    private let runCommand: CommandRunner
    private let launchDetached: DetachedLauncher
    private let logger = Logger(subsystem: "eu.shhshm.PortPilot", category: "LoginItem")

    init(launchAgentsDirectory: URL = URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
            .appendingPathComponent("Library/LaunchAgents", isDirectory: true),
         executablePath: String? = Bundle.main.executablePath,
         uid: uid_t = getuid(),
         logFileURL: URL = Relauncher.logDirectory.appendingPathComponent("portpilot.log", isDirectory: false),
         bundleIdentifier: String? = Bundle.main.bundleIdentifier,
         ownPID: Int32 = getpid(),
         runCommand: @escaping CommandRunner = { Shell.run($0, $1, timeout: 5) },
         environment: [String: String] = ProcessInfo.processInfo.environment,
         launchDetached: @escaping DetachedLauncher = LoginItemManager.spawnDetached) {
        self.launchAgentsDirectory = launchAgentsDirectory
        self.executablePath = executablePath.map { (($0 as NSString).resolvingSymlinksInPath as NSString).standardizingPath }
        self.uid = uid
        self.logFileURL = logFileURL
        self.bundleIdentifier = bundleIdentifier
        self.ownPID = ownPID
        self.runCommand = runCommand
        self.environment = environment
        self.launchDetached = launchDetached
    }

    var plistURL: URL {
        launchAgentsDirectory.appendingPathComponent("\(Self.label).plist", isDirectory: false)
    }

    /// `gui/<uid>/eu.shhshm.PortPilot.agent`
    var serviceTarget: String { "gui/\(uid)/\(Self.label)" }

    /// Plist exists AND points at the current executable.
    var isEnabled: Bool {
        guard let executablePath, let program = installedProgramPath() else { return false }
        return program == executablePath
    }

    /// Writes/removes the plist.
    /// - Enabling writes the plist atomically and runs `launchctl enable` (clears an earlier `disable`). It never
    ///   bootstraps: we are already running, and bootstrapping a RunAtLoad agent would start a second instance.
    ///   launchd loads the agent at the next login.
    /// - Disabling runs `launchctl disable`, boots the job out only when it is loaded and is not this process
    ///   (booting ourselves out would kill us), then removes the plist.
    func setEnabled(_ enabled: Bool) throws {
        if enabled {
            guard let executablePath else {
                throw ControlError(message: "Can't enable Launch at Login: PortPilot's executable path is unknown")
            }
            if executablePath.contains("/AppTranslocation/") {
                throw ControlError(message: "Move PortPilot to the Applications folder, then turn on Launch at Login")
            }
            try writePlist(for: executablePath)
            let result = runCommand("/bin/launchctl", ["enable", serviceTarget])
            if !result.ok {
                logger.error("launchctl enable failed (\(result.status)): \(result.stderr, privacy: .public)")
            }
        } else {
            let disable = runCommand("/bin/launchctl", ["disable", serviceTarget])
            if !disable.ok {
                logger.error("launchctl disable failed (\(disable.status)): \(disable.stderr, privacy: .public)")
            }
            let state = loadedJobState()
            if state.isLoaded, state.pid != ownPID {
                let bootout = runCommand("/bin/launchctl", ["bootout", serviceTarget])
                // 3 / 113: not loaded any more — fine.
                if !bootout.ok, ![3, 113].contains(bootout.status) {
                    logger.error("launchctl bootout failed (\(bootout.status)): \(bootout.stderr, privacy: .public)")
                }
            }
            do {
                try FileManager.default.removeItem(at: plistURL)
            } catch CocoaError.fileNoSuchFile {
                // Already gone.
            } catch {
                throw ControlError(message: "Couldn't remove \(Format.abbreviatePath(plistURL.path)): \(error.localizedDescription)")
            }
        }
    }

    /// Called at launch: if the agent plist exists but behaves differently from what this build would write
    /// (typically the app was moved, so ProgramArguments points to an old path), rewrite it. Cosmetic differences
    /// (log paths, AssociatedBundleIdentifiers, key order, XML vs binary) never cause a rewrite: each rewrite makes
    /// macOS re-register the agent and may show another "Background Items Added" notification.
    /// Never touches launchctl.
    func repairIfNeeded() {
        guard let executablePath, !executablePath.contains("/AppTranslocation/"),
              let data = try? Data(contentsOf: plistURL),
              let installed = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
        else { return }
        guard needsRepair(installed: installed, executablePath: executablePath) else { return }
        do {
            try writePlist(for: executablePath)
            logger.info("Repaired launch agent to point at \(executablePath, privacy: .public)")
        } catch {
            logger.error("Couldn't repair launch agent: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Keys that change what launchd does with the agent. Everything else in the plist (log paths,
    /// AssociatedBundleIdentifiers, keys another tool added) is cosmetic.
    static let semanticKeys = ["Label", "Program", "ProgramArguments", "RunAtLoad", "KeepAlive", "ProcessType",
                               "LimitLoadToSessionType"]

    /// True when `installed` differs from `plistContents(for:)` in a semantic key. The program path is compared
    /// with symlinks resolved, like `isEnabled` does.
    func needsRepair(installed: [String: Any], executablePath: String) -> Bool {
        var expected = plistContents(for: executablePath)
        var actual = installed
        if let arguments = actual["ProgramArguments"] as? [String], let program = arguments.first {
            actual["ProgramArguments"] = [Self.normalizedProgramPath(program)] + arguments.dropFirst()
        }
        if let arguments = expected["ProgramArguments"] as? [String], let program = arguments.first {
            expected["ProgramArguments"] = [Self.normalizedProgramPath(program)] + arguments.dropFirst()
        }
        func semantic(_ dictionary: [String: Any]) -> NSDictionary {
            NSDictionary(dictionary: dictionary.filter { Self.semanticKeys.contains($0.key) })
        }
        return semantic(actual) != semantic(expected)
    }

    private static func normalizedProgramPath(_ path: String) -> String {
        ((path as NSString).resolvingSymlinksInPath as NSString).standardizingPath
    }

    // MARK: - Quit

    /// True when this process was started by launchd as PortPilot's own agent job (not from Finder or Terminal).
    var isRunningAsAgentJob: Bool { environment["XPC_SERVICE_NAME"] == Self.label }

    /// Call as the last step of Quit. Turning Launch at login off while PortPilot runs as its agent job can't boot
    /// the job out (that would kill PortPilot), so the job stays loaded with KeepAlive for the rest of the session.
    /// When the toggle is off and this process is that job, this hands `launchctl bootout` to a detached helper so
    /// launchd forgets the job and nothing can start PortPilot again until the user does.
    ///
    /// Runs one `launchctl print` (a few milliseconds) to confirm the loaded job is this process; call it off the
    /// main thread.
    ///
    /// - Returns: true when the bootout was started. The caller should then terminate right away: launchd may
    ///   SIGTERM this process while it unloads the job, which is fine because the job is being removed.
    @discardableResult
    func bootOutOwnJobIfDisabled(launchAtLogin: Bool) -> Bool {
        guard !launchAtLogin, isRunningAsAgentJob else { return false }
        // Only our own job: never unload a copy launchd runs for another PortPilot process.
        let state = loadedJobState()
        guard state.isLoaded, state.pid == nil || state.pid == ownPID else { return false }
        let started = launchDetached("/bin/launchctl", ["bootout", serviceTarget])
        if !started { logger.error("Couldn't start launchctl bootout for \(Self.label, privacy: .public)") }
        return started
    }

    /// posix_spawn in a new session with stdio on /dev/null, not waited for: the helper must survive this process
    /// exiting (launchd cleans up a job's process group when its main process exits).
    static func spawnDetached(_ executable: String, _ arguments: [String]) -> Bool {
        var fileActions: posix_spawn_file_actions_t?
        var attributes: posix_spawnattr_t?
        guard posix_spawn_file_actions_init(&fileActions) == 0 else { return false }
        defer { posix_spawn_file_actions_destroy(&fileActions) }
        guard posix_spawnattr_init(&attributes) == 0 else { return false }
        defer { posix_spawnattr_destroy(&attributes) }
        for descriptor in [STDIN_FILENO, STDOUT_FILENO, STDERR_FILENO] {
            let mode = descriptor == STDIN_FILENO ? O_RDONLY : O_WRONLY
            guard posix_spawn_file_actions_addopen(&fileActions, descriptor, "/dev/null", mode, 0) == 0 else { return false }
        }
        guard posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_SETSID | POSIX_SPAWN_CLOEXEC_DEFAULT)) == 0 else {
            return false
        }
        let argv = ([executable] + arguments).map { strdup($0) } + [nil]
        defer { argv.forEach { free($0) } }
        guard !argv.dropLast().contains(where: { $0 == nil }) else { return false }
        var pid: pid_t = 0
        let status = posix_spawn(&pid, executable, &fileActions, &attributes, argv, environ)
        return status == 0 && pid > 0
    }

    // MARK: - Plist

    func plistContents(for executablePath: String) -> [String: Any] {
        var contents: [String: Any] = [
            "Label": Self.label,
            "ProgramArguments": [executablePath],
            "RunAtLoad": true,
            "KeepAlive": ["SuccessfulExit": false],
            "ProcessType": "Interactive",
            "LimitLoadToSessionType": "Aqua",
            "StandardOutPath": logFileURL.path,
            "StandardErrorPath": logFileURL.path,
        ]
        // Lets System Settings › Login Items attribute the agent to the app instead of showing a bare binary.
        if let bundleIdentifier { contents["AssociatedBundleIdentifiers"] = [bundleIdentifier] }
        return contents
    }

    private func writePlist(for executablePath: String) throws {
        do {
            try FileManager.default.createDirectory(at: launchAgentsDirectory, withIntermediateDirectories: true)
            // launchd does not create missing directories for StandardOutPath.
            try FileManager.default.createDirectory(at: logFileURL.deletingLastPathComponent(),
                                                    withIntermediateDirectories: true)
            let data = try PropertyListSerialization.data(fromPropertyList: plistContents(for: executablePath),
                                                          format: .xml, options: 0)
            try data.write(to: plistURL, options: .atomic)
        } catch {
            throw ControlError(message: "Couldn't write \(Format.abbreviatePath(plistURL.path)): \(error.localizedDescription)")
        }
    }

    /// ProgramArguments[0] (or Program) of the installed plist, symlinks resolved.
    private func installedProgramPath() -> String? {
        guard let data = try? Data(contentsOf: plistURL),
              let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
        else { return nil }
        let program = (plist["ProgramArguments"] as? [String])?.first ?? plist["Program"] as? String
        return program.map { (($0 as NSString).resolvingSymlinksInPath as NSString).standardizingPath }
    }

    // MARK: - launchd state

    /// `launchctl print gui/<uid>/<label>`: loaded? and the running pid, if any.
    private func loadedJobState() -> (isLoaded: Bool, pid: Int32?) {
        let result = runCommand("/bin/launchctl", ["print", serviceTarget])
        guard result.ok else { return (false, nil) }
        return (true, Self.parsePID(fromLaunchctlPrint: result.stdout))
    }

    /// Top-level "pid = 123" line of `launchctl print` output.
    static func parsePID(fromLaunchctlPrint output: String) -> Int32? {
        for line in output.split(separator: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard trimmed.hasPrefix("pid = ") else { continue }
            return Int32(trimmed.dropFirst("pid = ".count).trimmingCharacters(in: .whitespaces))
        }
        return nil
    }
}
