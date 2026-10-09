import Darwin
import Foundation

/// A command PortPilot can start again, as a `StoppedRecord` should store it (see
/// `Relauncher.relaunchCommand(for:details:)`).
struct RelaunchCommand: Equatable, Sendable {
    /// argv including argv[0].
    let arguments: [String]
    /// The environment to start it with (from the stopped process tree, never PortPilot's own).
    let environment: [String: String]
    /// nil: look `arguments[0]` up on `environment["PATH"]`, like a shell would.
    let executablePath: String?
    let cwd: String?
}

/// Re-runs a server the user stopped (from "Recently Stopped") exactly as it was started: same executable, argv,
/// environment and working directory — detached from PortPilot in its own session, output appended to a log.
enum Relauncher {
    /// ~/Library/Logs/PortPilot
    static var logDirectory: URL {
        URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
            .appendingPathComponent("Library/Logs/PortPilot", isDirectory: true)
    }

    /// How long a relaunched process must stay up before the relaunch counts as a success.
    static let defaultSettleTime: TimeInterval = 1.2

    /// posix_spawn the original executable+argv with the original env and cwd, in a new session
    /// (POSIX_SPAWN_SETSID), stdin=/dev/null, stdout+stderr appended to `<logDirectory>/<sanitized-title>.log`.
    /// Returns the new pid once the process has stayed up for `defaultSettleTime` (blocks the calling background
    /// thread that long). Throws `ControlError` on failure, including when the process exits right away. Its
    /// message is a short reason written to follow "Couldn't relaunch <title>: " in the banner.
    ///
    /// A record whose argv is a process title (npm's "npm run dev") is rebuilt into a real command
    /// (`npm run dev`, found on the record's PATH); any other title throws, because its command is unknown.
    static func relaunch(_ record: StoppedRecord) throws -> Int32 {
        try relaunch(record, logDirectory: logDirectory)
    }

    /// Same as `relaunch(_:)` with an explicit log directory and settle time (tests, harnesses).
    static func relaunch(_ record: StoppedRecord, logDirectory: URL,
                         settleTime: TimeInterval = defaultSettleTime) throws -> Int32 {
        guard !record.arguments.isEmpty else {
            throw ControlError(message: "its command line is unknown")
        }
        guard record.canRelaunch else {
            let manager = record.manager.badge ?? "its manager"
            throw ControlError(message: "it’s managed by \(manager), so start it from there")
        }
        var arguments = record.arguments
        var executablePath = record.executablePath
        if isTitleRewritten(arguments, executablePath: executablePath) {
            guard let rebuilt = commandFromTitle(arguments[0]) else {
                let fullTitle = arguments[0].trimmingCharacters(in: .whitespaces)
                let title = fullTitle.count > 60 ? String(fullTitle.prefix(59)) + "…" : fullTitle
                throw ControlError(message: "it renamed itself to “\(title)”, so its original command is unknown. "
                                   + "Start it again the way you usually do.")
            }
            arguments = rebuilt
            executablePath = nil   // found on the record's PATH below
        }
        // An unreadable environment would leave the child without PATH/HOME: use a clean login-like one.
        let environment = record.environment.isEmpty ? fallbackEnvironment() : record.environment
        let directory = try workingDirectory(for: record)
        guard let executable = resolveExecutable(arguments: arguments, executablePath: executablePath,
                                                 environment: environment, workingDirectory: directory) else {
            let name = executablePath ?? arguments[0]
            throw ControlError(message: "“\(name)” wasn’t found. Was it moved or uninstalled?")
        }

        let logURL = logFileURL(forTitle: record.title, in: logDirectory)
        try prepareLog(at: logURL, arguments: arguments, executable: executable, workingDirectory: directory)

        let pid = try spawn(executable: executable, arguments: arguments, environment: environment,
                            workingDirectory: directory, logPath: logURL.path)
        let exit = ExitWatch()
        ChildReaper.shared.reapWhenExited(pid) { status in exit.record(status) }
        if settleTime > 0, let status = exit.wait(upTo: settleTime) {
            throw ControlError(message: "it exited right after starting (\(status.description)). "
                               + "Its output is in \(Format.abbreviatePath(logURL.path))")
        }
        return pid
    }

    // MARK: - Rewritten command lines

    /// True when `arguments` is a process title written over argv rather than a command line: npm's
    /// ["npm run dev", "", "", ""], nginx's ["nginx: master process …"], ["next-server (v15.0.3)", ""].
    /// argv[0] then holds spaces, is not a path and is not the executable's own name, and every other slot is empty.
    static func isTitleRewritten(_ arguments: [String], executablePath: String? = nil) -> Bool {
        guard let first = arguments.first else { return false }
        let title = first.trimmingCharacters(in: .whitespaces)
        guard title.contains(" "), !title.hasPrefix("/") else { return false }
        if let executablePath, executablePath == first || executablePath.hasSuffix("/" + first) { return false }
        return arguments.dropFirst().allSatisfy(\.isEmpty)
    }

    /// Rebuilds a runnable argv from a package manager's process title: "npm run dev" → ["npm", "run", "dev"],
    /// "npm exec next start" → ["npm", "exec", "next", "start"]. nil for any other title (nginx, next-server…):
    /// those don't say how they were started.
    static func commandFromTitle(_ title: String) -> [String]? {
        let words = title.split(whereSeparator: \.isWhitespace).map(String.init)
        guard let first = words.first, Classifier.packageManagerNames.contains(first) else { return nil }
        return words
    }

    /// What a `StoppedRecord` should hold for a stopped plan so Relaunch / Undo really restarts it.
    ///
    /// - The root's own command when its argv is intact (`make dev`, `node scripts/dev.js`).
    /// - When the root rewrote its argv (npm's "npm run dev"): the highest target below the root whose argv is
    ///   intact, provided it is the only process at that level — for npm that is the `sh -c <script>` child, with
    ///   the package folder as its cwd and npm's environment (PATH with node_modules/.bin).
    /// - Otherwise the command rebuilt from a package-manager title, with `executablePath` nil so it is found on
    ///   PATH.
    /// - Either way the environment is the nearest one the tree still has (titled processes lose theirs, and
    ///   macOS shows none for Apple's own binaries such as /bin/sh).
    /// - nil when nothing relaunchable is known (the caller keeps the raw argv for Copy Command only).
    ///
    /// Call it before stopping the plan: `details` must still describe the plan's processes.
    static func relaunchCommand(for plan: KillPlan, details: (ProcessBasic) -> ProcessDetails?) -> RelaunchCommand? {
        guard let rootDetails = details(plan.root), !rootDetails.arguments.isEmpty else { return nil }

        // Depth of every target below the root (targets are root + descendants; follow ppid up to the root).
        let byPID = Dictionary(plan.targets.map { ($0.pid, $0) }, uniquingKeysWith: { first, _ in first })
        func depth(of process: ProcessBasic) -> Int? {
            var current = process
            var steps = 0
            while current.pid != plan.root.pid {
                guard steps < 64, let parent = byPID[current.ppid] else { return nil }
                current = parent
                steps += 1
            }
            return steps
        }
        var levels: [Int: [ProcessBasic]] = [:]
        for target in plan.targets where target.pid != plan.root.pid {
            if let level = depth(of: target) { levels[level, default: []].append(target) }
        }
        let orderedLevels = levels.keys.sorted()

        // A titled root has usually lost its environment, and macOS returns no environment at all for Apple's own
        // binaries (/bin/sh, /usr/bin/make): use the nearest process in the tree that has one. The dev server below
        // npm inherited npm's environment (PATH with node_modules/.bin, PORT, npm_* variables).
        var treeEnvironment = rootDetails.environment
        if treeEnvironment.isEmpty {
            search: for level in orderedLevels {
                for member in levels[level] ?? [] {
                    if let found = details(member)?.environment, !found.isEmpty {
                        treeEnvironment = found
                        break search
                    }
                }
            }
        }

        if !isTitleRewritten(rootDetails.arguments, executablePath: rootDetails.executablePath) {
            return RelaunchCommand(arguments: rootDetails.arguments, environment: treeEnvironment,
                                   executablePath: rootDetails.executablePath, cwd: rootDetails.cwd)
        }

        for level in orderedLevels {
            let members = levels[level] ?? []
            let intact = members.compactMap { member -> ProcessDetails? in
                guard let info = details(member), !info.arguments.isEmpty, !(info.arguments.first ?? "").isEmpty,
                      !isTitleRewritten(info.arguments, executablePath: info.executablePath) else { return nil }
                return info
            }
            guard !intact.isEmpty else { continue }
            // Starting only one of several siblings would leave the rest of the launch missing.
            guard members.count == 1, let child = intact.first else { break }
            return RelaunchCommand(arguments: child.arguments,
                                   environment: child.environment.isEmpty ? treeEnvironment : child.environment,
                                   executablePath: child.executablePath, cwd: child.cwd ?? rootDetails.cwd)
        }

        guard let rebuilt = commandFromTitle(rootDetails.arguments[0]) else { return nil }
        return RelaunchCommand(arguments: rebuilt, environment: treeEnvironment, executablePath: nil,
                               cwd: rootDetails.cwd)
    }

    /// Environment for a record whose environment could not be read: a login-like PATH (the user's shell PATH plus
    /// Homebrew & co., not launchd's minimal one) and the basic session variables — not PortPilot's own settings.
    static func fallbackEnvironment() -> [String: String] {
        let own = ProcessInfo.processInfo.environment
        var environment: [String: String] = [:]
        for key in ["HOME", "USER", "LOGNAME", "SHELL", "TMPDIR", "LANG", "LC_ALL", "LC_CTYPE", "TERM"] {
            if let value = own[key], !value.isEmpty { environment[key] = value }
        }
        environment["HOME"] = NSHomeDirectory()
        environment["PATH"] = Shell.toolPATH
        return environment
    }

    // MARK: - Resolution

    /// The record's cwd when it still exists, else the home folder (cwd unknown).
    private static func workingDirectory(for record: StoppedRecord) throws -> String {
        guard let cwd = record.cwd, !cwd.isEmpty else { return NSHomeDirectory() }
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: cwd, isDirectory: &isDirectory), isDirectory.boolValue else {
            throw ControlError(message: "the folder \(Format.abbreviatePath(cwd)) no longer exists")
        }
        return cwd
    }

    /// `record.executablePath` when it still exists; otherwise argv[0] resolved against the cwd (when it contains
    /// a "/") or looked up on the record's own PATH (like a shell would).
    static func resolveExecutable(for record: StoppedRecord, environment: [String: String],
                                  workingDirectory: String) -> String? {
        resolveExecutable(arguments: record.arguments, executablePath: record.executablePath,
                          environment: environment, workingDirectory: workingDirectory)
    }

    /// `executablePath` when it still exists; otherwise argv[0] resolved against the cwd (when it contains a "/")
    /// or looked up on `environment["PATH"]` (like a shell would).
    static func resolveExecutable(arguments: [String], executablePath: String?, environment: [String: String],
                                  workingDirectory: String) -> String? {
        if let path = executablePath, path.hasPrefix("/"), isExecutableFile(path) { return path }
        guard let argv0 = arguments.first, !argv0.isEmpty else { return nil }
        if argv0.contains("/") {
            let candidate = argv0.hasPrefix("/") ? argv0 : (workingDirectory as NSString).appendingPathComponent(argv0)
            let standardized = (candidate as NSString).standardizingPath
            return isExecutableFile(standardized) ? standardized : nil
        }
        let searchPath = environment["PATH"].flatMap { $0.isEmpty ? nil : $0 } ?? defaultSearchPath
        // Empty PATH entries mean "current directory" to a shell; skip them rather than run a stray binary.
        for entry in searchPath.split(separator: ":", omittingEmptySubsequences: true) {
            let directory = entry.hasPrefix("/") ? String(entry)
                : (workingDirectory as NSString).appendingPathComponent(String(entry))
            let candidate = (directory as NSString).appendingPathComponent(argv0)
            if isExecutableFile(candidate) { return (candidate as NSString).standardizingPath }
        }
        return nil
    }

    private static let defaultSearchPath = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"

    private static func isExecutableFile(_ path: String) -> Bool {
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory) && !isDirectory.boolValue
            && FileManager.default.isExecutableFile(atPath: path)
    }

    // MARK: - Logging

    static func logFileURL(forTitle title: String, in directory: URL) -> URL {
        directory.appendingPathComponent(sanitizedFileName(title) + ".log", isDirectory: false)
    }

    /// ASCII letters, digits, "-", "_" and "." only; runs of anything else become one "-". Never hidden, never empty.
    static func sanitizedFileName(_ title: String) -> String {
        var result = ""
        var lastWasDash = false
        for scalar in title.unicodeScalars {
            let isSafe = scalar.isASCII && (CharacterSet.alphanumerics.contains(scalar) || "-_.".unicodeScalars.contains(scalar))
            if isSafe {
                result.unicodeScalars.append(scalar)
                lastWasDash = scalar == "-"
            } else if !lastWasDash {
                result.append("-")
                lastWasDash = true
            }
        }
        let trimmed = result.trimmingCharacters(in: CharacterSet(charactersIn: "-."))
        let limited = String(trimmed.prefix(80))
        return limited.isEmpty ? "process" : limited
    }

    /// Creates the log directory/file and appends a header so consecutive runs are distinguishable.
    /// The environment is deliberately never written (it may contain secrets).
    private static func prepareLog(at url: URL, arguments: [String], executable: String,
                                   workingDirectory: String) throws {
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        } catch {
            throw ControlError(message: "couldn’t create the log folder \(Format.abbreviatePath(url.deletingLastPathComponent().path)): \(error.localizedDescription)")
        }
        let descriptor = open(url.path, O_WRONLY | O_CREAT | O_APPEND | O_CLOEXEC, 0o644)
        guard descriptor >= 0 else {
            throw ControlError(message: "couldn’t open the log file \(Format.abbreviatePath(url.path)): \(String(cString: strerror(errno)))")
        }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        let stamp = ISO8601DateFormatter().string(from: Date())
        let commandLine = arguments.map { $0.contains(" ") || $0.isEmpty ? "\"\($0)\"" : $0 }.joined(separator: " ")
        let header = "\n=== PortPilot relaunch \(stamp) ===\n$ cd \(workingDirectory)\n$ \(commandLine)\n# executable: \(executable)\n\n"
        try? handle.write(contentsOf: Data(header.utf8))   // header is cosmetic; the spawn decides success
        try? handle.close()
    }

    // MARK: - Spawning

    private static func spawn(executable: String, arguments: [String], environment: [String: String],
                              workingDirectory: String, logPath: String) throws -> pid_t {
        var fileActions: posix_spawn_file_actions_t?
        var attributes: posix_spawnattr_t?
        try check(posix_spawn_file_actions_init(&fileActions), "posix_spawn_file_actions_init")
        defer { posix_spawn_file_actions_destroy(&fileActions) }
        try check(posix_spawnattr_init(&attributes), "posix_spawnattr_init")
        defer { posix_spawnattr_destroy(&attributes) }

        // File actions run in order inside the child.
        if #available(macOS 26.0, *) {
            try check(posix_spawn_file_actions_addchdir(&fileActions, workingDirectory), "addchdir")
        } else {
            try check(posix_spawn_file_actions_addchdir_np(&fileActions, workingDirectory), "addchdir")
        }
        try check(posix_spawn_file_actions_addopen(&fileActions, STDIN_FILENO, "/dev/null", O_RDONLY, 0), "stdin")
        try check(posix_spawn_file_actions_addopen(&fileActions, STDOUT_FILENO, logPath,
                                                   O_WRONLY | O_CREAT | O_APPEND, 0o644), "stdout")
        try check(posix_spawn_file_actions_adddup2(&fileActions, STDOUT_FILENO, STDERR_FILENO), "stderr")

        // Fresh signal state: dispositions PortPilot set (e.g. SIGPIPE ignored) must not leak into the server.
        var emptyMask = sigset_t()
        sigemptyset(&emptyMask)
        var defaultSignals = sigset_t()
        sigfillset(&defaultSignals)
        sigdelset(&defaultSignals, SIGKILL)
        sigdelset(&defaultSignals, SIGSTOP)
        try check(posix_spawnattr_setsigmask(&attributes, &emptyMask), "setsigmask")
        try check(posix_spawnattr_setsigdefault(&attributes, &defaultSignals), "setsigdefault")

        // New session (no controlling terminal, own process group) and no inherited descriptors besides 0/1/2.
        let flags = POSIX_SPAWN_SETSID | POSIX_SPAWN_SETSIGDEF | POSIX_SPAWN_SETSIGMASK | POSIX_SPAWN_CLOEXEC_DEFAULT
        try check(posix_spawnattr_setflags(&attributes, Int16(flags)), "setflags")

        let environmentStrings = environment.map { "\($0.key)=\($0.value)" }.sorted()
        var pid: pid_t = 0
        let status = try withCStringArray(arguments) { argv in
            try withCStringArray(environmentStrings) { envp in
                posix_spawn(&pid, executable, &fileActions, &attributes, argv, envp)
            }
        }
        guard status == 0, pid > 0 else {
            let reason = status == 0 ? "no process id returned" : String(cString: strerror(status))
            throw ControlError(message: "couldn’t start \((executable as NSString).lastPathComponent): \(reason)")
        }
        return pid
    }

    /// posix_spawn* functions return an errno value (not -1/errno).
    private static func check(_ status: Int32, _ step: String) throws {
        guard status == 0 else {
            throw ControlError(message: "couldn’t prepare the relaunch (\(step)): \(String(cString: strerror(status)))")
        }
    }

    /// NULL-terminated `char *[]` built from `strings`, valid only inside `body`.
    private static func withCStringArray<R>(_ strings: [String],
                                            _ body: (UnsafePointer<UnsafeMutablePointer<CChar>?>) throws -> R) throws -> R {
        var pointers: [UnsafeMutablePointer<CChar>?] = []
        pointers.reserveCapacity(strings.count + 1)
        defer { pointers.forEach { free($0) } }
        for string in strings {
            guard let copy = strdup(string) else { throw ControlError(message: "out of memory") }
            pointers.append(copy)
        }
        pointers.append(nil)
        return try pointers.withUnsafeBufferPointer { buffer in
            guard let base = buffer.baseAddress else { throw ControlError(message: "out of memory") }
            return try body(base)
        }
    }
}

/// How a relaunched child ended.
enum ChildExit: Equatable, Sendable, CustomStringConvertible {
    case exited(code: Int32)
    case signaled(Int32)
    /// Someone else reaped it (ECHILD) or waitpid failed.
    case unknown

    /// Decodes a `waitpid` status word (the WIFEXITED / WEXITSTATUS / WTERMSIG macros are not imported to Swift).
    init(waitStatus status: Int32) {
        let signal = status & 0x7f
        if signal == 0 {
            self = .exited(code: (status >> 8) & 0xff)
        } else if signal != 0x7f {
            self = .signaled(signal)
        } else {
            self = .unknown   // stopped, not exited
        }
    }

    var description: String {
        switch self {
        case .exited(let code): return "exit code \(code)"
        case .signaled(let signal): return "signal \(signal)"
        case .unknown: return "exit status unknown"
        }
    }
}

/// One-shot exit notification for a relaunched child, waited on by the relaunching thread.
private final class ExitWatch: @unchecked Sendable {
    private let lock = NSLock()
    private let semaphore = DispatchSemaphore(value: 0)
    private var status: ChildExit?   // guarded by `lock`

    func record(_ exit: ChildExit) {
        lock.withLock { status = exit }
        semaphore.signal()
    }

    /// The child's exit if it ended within `seconds`, nil while it is still running.
    func wait(upTo seconds: TimeInterval) -> ChildExit? {
        guard semaphore.wait(timeout: .now() + max(0, seconds)) == .success else { return nil }
        return lock.withLock { status }
    }
}

/// Relaunched servers are PortPilot's children until PortPilot quits. Reap them when they exit so they never
/// linger as zombies (which would also look "alive" to anything that only checks the PID).
private final class ChildReaper: @unchecked Sendable {
    static let shared = ChildReaper()

    private let lock = NSLock()
    /// User-initiated: `Relauncher.relaunch` waits on these exit events from a user-initiated thread.
    private let queue = DispatchQueue(label: "eu.shhshm.PortPilot.relauncher.reaper", qos: .userInitiated)
    private var sources: [pid_t: DispatchSourceProcess] = [:]   // guarded by `lock`

    /// Reaps `pid` once it exits and then reports how it ended through `onExit` (on a background queue).
    func reapWhenExited(_ pid: pid_t, onExit: (@Sendable (ChildExit) -> Void)? = nil) {
        guard pid > 0 else { return }
        // libdispatch delivers a synthetic exit event if the child already exited before registration.
        let source = DispatchSource.makeProcessSource(identifier: pid, eventMask: .exit, queue: queue)
        source.setEventHandler { [weak self] in
            var status: Int32 = 0
            var result: pid_t = -1
            // The child has exited: this returns immediately (or with ECHILD if someone else reaped it).
            repeat { result = waitpid(pid, &status, 0) } while result == -1 && errno == EINTR
            self?.stopWatching(pid)
            onExit?(result == pid ? ChildExit(waitStatus: status) : .unknown)
        }
        lock.withLock { sources[pid] = source }
        source.resume()
    }

    private func stopWatching(_ pid: pid_t) {
        let source = lock.withLock { sources.removeValue(forKey: pid) }
        source?.cancel()
    }
}
