import Darwin
import Foundation

/// Re-runs a server the user stopped (from "Recently Stopped") exactly as it was started: same executable, argv,
/// environment and working directory — detached from PortPilot in its own session, output appended to a log.
enum Relauncher {
    /// ~/Library/Logs/PortPilot
    static var logDirectory: URL {
        URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
            .appendingPathComponent("Library/Logs/PortPilot", isDirectory: true)
    }

    /// posix_spawn the original executable+argv with the original env and cwd, in a new session
    /// (POSIX_SPAWN_SETSID), stdin=/dev/null, stdout+stderr appended to `<logDirectory>/<sanitized-title>.log`.
    /// Returns the new pid. Throws `ControlError` on failure.
    static func relaunch(_ record: StoppedRecord) throws -> Int32 {
        try relaunch(record, logDirectory: logDirectory)
    }

    /// Same as `relaunch(_:)` with an explicit log directory (tests, harnesses).
    static func relaunch(_ record: StoppedRecord, logDirectory: URL) throws -> Int32 {
        guard !record.arguments.isEmpty else {
            throw ControlError(message: "Can't relaunch \(record.title): its command line is unknown")
        }
        guard record.canRelaunch else {
            let manager = record.manager.badge ?? "its manager"
            throw ControlError(message: "\(record.title) is managed by \(manager) — start it from there instead")
        }
        // An unreadable environment would leave the child without PATH/HOME; fall back to ours.
        let environment = record.environment.isEmpty ? ProcessInfo.processInfo.environment : record.environment
        let directory = try workingDirectory(for: record)
        guard let executable = resolveExecutable(for: record, environment: environment, workingDirectory: directory) else {
            let name = record.executablePath ?? record.arguments[0]
            throw ControlError(message: "Can't relaunch \(record.title): “\(name)” was not found (moved or uninstalled?)")
        }

        let logURL = logFileURL(forTitle: record.title, in: logDirectory)
        try prepareLog(at: logURL, record: record, executable: executable, workingDirectory: directory)

        let pid = try spawn(executable: executable, arguments: record.arguments, environment: environment,
                            workingDirectory: directory, logPath: logURL.path)
        ChildReaper.shared.reapWhenExited(pid)
        return pid
    }

    // MARK: - Resolution

    /// The record's cwd when it still exists, else the home folder (cwd unknown).
    private static func workingDirectory(for record: StoppedRecord) throws -> String {
        guard let cwd = record.cwd, !cwd.isEmpty else { return NSHomeDirectory() }
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: cwd, isDirectory: &isDirectory), isDirectory.boolValue else {
            throw ControlError(message: "Can't relaunch \(record.title): the folder \(Format.abbreviatePath(cwd)) no longer exists")
        }
        return cwd
    }

    /// `record.executablePath` when it still exists; otherwise argv[0] resolved against the cwd (when it contains
    /// a "/") or looked up on the record's own PATH (like a shell would).
    static func resolveExecutable(for record: StoppedRecord, environment: [String: String],
                                  workingDirectory: String) -> String? {
        if let path = record.executablePath, path.hasPrefix("/"), isExecutableFile(path) { return path }
        guard let argv0 = record.arguments.first, !argv0.isEmpty else { return nil }
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
    private static func prepareLog(at url: URL, record: StoppedRecord, executable: String,
                                   workingDirectory: String) throws {
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        } catch {
            throw ControlError(message: "Can't create the log folder \(Format.abbreviatePath(url.deletingLastPathComponent().path)): \(error.localizedDescription)")
        }
        let descriptor = open(url.path, O_WRONLY | O_CREAT | O_APPEND | O_CLOEXEC, 0o644)
        guard descriptor >= 0 else {
            throw ControlError(message: "Can't open the log file \(Format.abbreviatePath(url.path)): \(String(cString: strerror(errno)))")
        }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        let stamp = ISO8601DateFormatter().string(from: Date())
        let header = "\n=== PortPilot relaunch \(stamp) ===\n$ cd \(workingDirectory)\n$ \(record.commandLine)\n# executable: \(executable)\n\n"
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
            throw ControlError(message: "Couldn't start \((executable as NSString).lastPathComponent): \(reason)")
        }
        return pid
    }

    /// posix_spawn* functions return an errno value (not -1/errno).
    private static func check(_ status: Int32, _ step: String) throws {
        guard status == 0 else {
            throw ControlError(message: "Couldn't prepare the relaunch (\(step)): \(String(cString: strerror(status)))")
        }
    }

    /// NULL-terminated `char *[]` built from `strings`, valid only inside `body`.
    private static func withCStringArray<R>(_ strings: [String],
                                            _ body: (UnsafePointer<UnsafeMutablePointer<CChar>?>) throws -> R) throws -> R {
        var pointers: [UnsafeMutablePointer<CChar>?] = []
        pointers.reserveCapacity(strings.count + 1)
        defer { pointers.forEach { free($0) } }
        for string in strings {
            guard let copy = strdup(string) else { throw ControlError(message: "Out of memory while relaunching") }
            pointers.append(copy)
        }
        pointers.append(nil)
        return try pointers.withUnsafeBufferPointer { buffer in
            guard let base = buffer.baseAddress else { throw ControlError(message: "Out of memory while relaunching") }
            return try body(base)
        }
    }
}

/// Relaunched servers are PortPilot's children until PortPilot quits. Reap them when they exit so they never
/// linger as zombies (which would also look "alive" to anything that only checks the PID).
private final class ChildReaper: @unchecked Sendable {
    static let shared = ChildReaper()

    private let lock = NSLock()
    private let queue = DispatchQueue(label: "app.portpilot.relauncher.reaper", qos: .utility)
    private var sources: [pid_t: DispatchSourceProcess] = [:]   // guarded by `lock`

    func reapWhenExited(_ pid: pid_t) {
        guard pid > 0 else { return }
        // libdispatch delivers a synthetic exit event if the child already exited before registration.
        let source = DispatchSource.makeProcessSource(identifier: pid, eventMask: .exit, queue: queue)
        source.setEventHandler { [weak self] in
            var status: Int32 = 0
            // The child has exited: this returns immediately (or with ECHILD if someone else reaped it).
            while waitpid(pid, &status, 0) == -1 && errno == EINTR {}
            self?.stopWatching(pid)
        }
        lock.withLock { sources[pid] = source }
        source.resume()
    }

    private func stopWatching(_ pid: pid_t) {
        let source = lock.withLock { sources.removeValue(forKey: pid) }
        source?.cancel()
    }
}
