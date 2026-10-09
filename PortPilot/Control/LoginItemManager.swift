import Darwin
import Foundation
import os

/// Keeps PortPilot running: a LaunchAgent at ~/Library/LaunchAgents/app.portpilot.agent.plist with
/// ProgramArguments=[<Bundle.main.executablePath>], RunAtLoad=true, KeepAlive={SuccessfulExit=false} (restart after
/// a crash, not after Quit), ProcessType=Interactive, LimitLoadToSessionType=Aqua, and stdout/stderr going to
/// ~/Library/Logs/PortPilot/portpilot.log.
final class LoginItemManager {
    static let label = "app.portpilot.agent"

    /// Runs an executable with arguments; injectable so tests never touch the real launchd domain.
    typealias CommandRunner = (_ executable: String, _ arguments: [String]) -> ShellResult

    private let launchAgentsDirectory: URL
    private let executablePath: String?
    private let uid: uid_t
    private let logFileURL: URL
    private let bundleIdentifier: String?
    private let ownPID: Int32
    private let runCommand: CommandRunner
    private let logger = Logger(subsystem: "app.portpilot", category: "LoginItem")

    init(launchAgentsDirectory: URL = URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
            .appendingPathComponent("Library/LaunchAgents", isDirectory: true),
         executablePath: String? = Bundle.main.executablePath,
         uid: uid_t = getuid(),
         logFileURL: URL = Relauncher.logDirectory.appendingPathComponent("portpilot.log", isDirectory: false),
         bundleIdentifier: String? = Bundle.main.bundleIdentifier,
         ownPID: Int32 = getpid(),
         runCommand: @escaping CommandRunner = { Shell.run($0, $1, timeout: 5) }) {
        self.launchAgentsDirectory = launchAgentsDirectory
        self.executablePath = executablePath.map { (($0 as NSString).resolvingSymlinksInPath as NSString).standardizingPath }
        self.uid = uid
        self.logFileURL = logFileURL
        self.bundleIdentifier = bundleIdentifier
        self.ownPID = ownPID
        self.runCommand = runCommand
    }

    var plistURL: URL {
        launchAgentsDirectory.appendingPathComponent("\(Self.label).plist", isDirectory: false)
    }

    /// `gui/<uid>/app.portpilot.agent`
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

    /// Called at launch: if the agent plist exists but differs from what this build would write (typically the app
    /// was moved, so ProgramArguments points to an old path), rewrite it. Never touches launchctl.
    func repairIfNeeded() {
        guard let executablePath, !executablePath.contains("/AppTranslocation/"),
              let data = try? Data(contentsOf: plistURL),
              let installed = try? PropertyListSerialization.propertyList(from: data, format: nil) as? NSDictionary
        else { return }
        guard installed != NSDictionary(dictionary: plistContents(for: executablePath)) else { return }
        do {
            try writePlist(for: executablePath)
            logger.info("Repaired launch agent to point at \(executablePath, privacy: .public)")
        } catch {
            logger.error("Couldn't repair launch agent: \(error.localizedDescription, privacy: .public)")
        }
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
