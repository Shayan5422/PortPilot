import Darwin
import Foundation

/// Outcome of a finished subprocess.
struct ShellResult: Sendable {
    /// Exit status. `Shell.timeoutStatus` (-1) when the child was killed for exceeding its timeout,
    /// `Shell.notFoundStatus` (127) when it could not be launched / found, and 128 + signal number
    /// when it died from a signal we did not send.
    let status: Int32
    let stdout: String
    let stderr: String

    var ok: Bool { status == 0 }

    /// Best human-readable explanation of the result: trimmed stderr, else trimmed stdout,
    /// else a generic "exited with status N" line. Used to build `ControlError` messages.
    var message: String {
        let err = stderr.trimmingCharacters(in: .whitespacesAndNewlines)
        if !err.isEmpty { return err }
        let out = stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        if !out.isEmpty { return out }
        if status == Shell.timeoutStatus { return "Timed out." }
        return "Exited with status \(status)."
    }
}

/// Subprocess helpers. Every function is safe to call concurrently from any background thread;
/// none of them should be called on the main thread because they block until the child exits.
enum Shell {
    /// Status reported when a child is killed because it exceeded its timeout.
    static let timeoutStatus: Int32 = -1
    /// Status reported when a tool is not found or the executable cannot be launched.
    static let notFoundStatus: Int32 = 127

    /// Upper bound kept per output stream. The rest is still drained (so the child never blocks on a
    /// full pipe) but discarded.
    static let maxCapturedBytes = 8 * 1024 * 1024

    /// Directories always appended to the login-shell PATH (SPEC), `~` expanded. Includes where Docker Desktop
    /// ("user" CLI install) and OrbStack put the `docker` CLI, so published container ports are attributed to their
    /// container even when the user's shell PATH doesn't list those folders.
    static var extraToolDirectories: [String] {
        let home = NSHomeDirectory()
        return ["/opt/homebrew/bin", "/usr/local/bin", home + "/.bun/bin", home + "/.local/bin",
                home + "/.cargo/bin", home + "/.deno/bin", home + "/.docker/bin", home + "/.orbstack/bin",
                "/Applications/Docker.app/Contents/Resources/bin"]
    }

    /// Last-resort system directories so lookups work even if every other source is empty.
    static let systemDirectories = ["/usr/bin", "/bin", "/usr/sbin", "/sbin"]

    // MARK: - run

    /// Runs an executable directly (no shell), with timeout (kills the child on timeout → status -1). Never blocks main
    /// thread for long: callers call it from background. Reads pipes concurrently to avoid deadlock on large output.
    ///
    /// - stdin is `/dev/null`, stdout/stderr are drained by non-blocking dispatch read sources while the child runs.
    /// - On timeout the child gets SIGTERM, then SIGKILL one second later if it is still alive.
    /// - After the child exits, output is collected until both pipes hit EOF, waiting at most a short grace period
    ///   (a grandchild that inherited the pipe must not hang us).
    static func run(_ executable: String, _ arguments: [String], timeout: TimeInterval = 10,
                    environment: [String: String]? = nil, currentDirectory: String? = nil) -> ShellResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        if let environment { process.environment = environment }
        if let currentDirectory {
            process.currentDirectoryURL = URL(fileURLWithPath: currentDirectory, isDirectory: true)
        }
        process.standardInput = FileHandle.nullDevice

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        let exited = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in exited.signal() }

        let stdoutDrain = PipeDrain(pipe: stdoutPipe, limit: maxCapturedBytes)
        let stderrDrain = PipeDrain(pipe: stderrPipe, limit: maxCapturedBytes)

        do {
            try process.run()
        } catch {
            _ = stdoutDrain.collect(deadline: .now())
            _ = stderrDrain.collect(deadline: .now())
            return ShellResult(status: notFoundStatus, stdout: "",
                               stderr: "Could not launch \(executable): \(error.localizedDescription)")
        }
        // Foundation closes the parent's copies of the pipes' write ends right after spawning (and spawns with
        // close-on-exec by default), so EOF arrives as soon as the child and anything that inherited its
        // stdout/stderr exit. Do NOT close them again here: the descriptor numbers may already be reused.

        var timedOut = false
        if exited.wait(timeout: deadline(after: timeout)) == .timedOut {
            timedOut = true
            process.terminate() // SIGTERM
            if exited.wait(timeout: .now() + 1) == .timedOut {
                let pid = process.processIdentifier
                // Only our own, still-unreaped child: `exited` has not fired, so the pid cannot have been recycled.
                if pid > 0, process.isRunning { kill(pid, SIGKILL) }
                _ = exited.wait(timeout: .now() + 2)
            }
        }

        let grace: TimeInterval = timedOut ? 0.25 : 2
        let drainDeadline = DispatchTime.now() + grace
        let out = stdoutDrain.collect(deadline: drainDeadline)
        let err = stderrDrain.collect(deadline: drainDeadline)

        let status: Int32
        if timedOut {
            // Never read terminationStatus here: it raises if the child is somehow still running.
            status = timeoutStatus
        } else {
            switch process.terminationReason {
            case .exit: status = process.terminationStatus
            case .uncaughtSignal: status = 128 + process.terminationStatus
            @unknown default: status = process.terminationStatus
            }
        }
        return ShellResult(status: status,
                           stdout: String(decoding: out, as: UTF8.self),
                           stderr: String(decoding: err, as: UTF8.self))
    }

    /// Converts a relative timeout to a dispatch deadline, clamping NaN/negative/huge values.
    private static func deadline(after timeout: TimeInterval) -> DispatchTime {
        let seconds = timeout.isNaN ? 0 : min(max(timeout, 0), 86_400)
        return .now() + seconds
    }

    // MARK: - Tool lookup

    /// PATH used for tool lookup: user's login-shell PATH (captured once via `/bin/zsh -l -c 'printf %s "$PATH"'`,
    /// 3 s timeout, cached) + /opt/homebrew/bin, /usr/local/bin, ~/.bun/bin, ~/.local/bin, ~/.cargo/bin, ~/.deno/bin.
    /// The first access blocks for up to ~3 s; it is computed once per process (thread-safe lazy static).
    static var toolPATH: String { cachedToolPATH }

    private static let cachedToolPATH: String = {
        let loginPATH = captureLoginShellPATH() ?? ""
        let ownPATH = ProcessInfo.processInfo.environment["PATH"] ?? ""
        return mergePATH([
            splitPATH(loginPATH),
            extraToolDirectories,
            splitPATH(ownPATH),
            systemDirectories,
        ])
    }()

    /// Sentinel printed before the PATH so noise from the user's profile scripts can be ignored.
    static let pathMarker = "__PORTPILOT_PATH__="

    /// Runs the user's login shell once to learn the PATH they see in Terminal.
    private static func captureLoginShellPATH() -> String? {
        let result = run("/bin/zsh", ["-l", "-c", "printf '\\n%s%s' '\(pathMarker)' \"$PATH\""], timeout: 3)
        guard result.ok else { return nil }
        return parseLoginShellPATH(result.stdout)
    }

    /// Extracts the PATH printed after `pathMarker` (last occurrence wins). Falls back to the last non-empty line
    /// that looks like a PATH when the marker is missing. Pure; used by tests.
    static func parseLoginShellPATH(_ output: String) -> String? {
        if let range = output.range(of: pathMarker, options: .backwards) {
            let rest = output[range.upperBound...]
            let line = rest.split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: false).first ?? ""
            let value = line.trimmingCharacters(in: .whitespacesAndNewlines)
            return value.isEmpty ? nil : value
        }
        let lines = output.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        guard let last = lines.last, last.hasPrefix("/") else { return nil }
        return last
    }

    /// Splits a PATH string into components (empty components dropped).
    static func splitPATH(_ path: String) -> [String] {
        path.split(separator: ":", omittingEmptySubsequences: true).map(String.init)
    }

    /// Joins several directory lists into one PATH: order kept, duplicates removed, trailing slashes trimmed,
    /// `~/` expanded, and relative entries (".", "bin") dropped because they would make lookups depend on the
    /// current directory. Pure; used by tests.
    static func mergePATH(_ lists: [[String]], homeDirectory: String = NSHomeDirectory()) -> String {
        var seen = Set<String>()
        var result: [String] = []
        for list in lists {
            for raw in list {
                var dir = raw.trimmingCharacters(in: .whitespaces)
                if dir == "~" {
                    dir = homeDirectory
                } else if dir.hasPrefix("~/") {
                    dir = homeDirectory + dir.dropFirst(1)
                }
                while dir.count > 1, dir.hasSuffix("/") { dir.removeLast() }
                guard dir.hasPrefix("/"), seen.insert(dir).inserted else { continue }
                result.append(dir)
            }
        }
        return result.joined(separator: ":")
    }

    /// Finds an executable on toolPATH. Cached.
    /// Positive hits are re-validated on every call (one `stat`); misses are remembered for 60 s so a tool
    /// installed while PortPilot runs is eventually found.
    static func which(_ tool: String) -> String? {
        guard !tool.isEmpty else { return nil }
        if tool.contains("/") { return isExecutableFile(tool) ? tool : nil }
        return whichCache.value(for: tool) {
            findExecutable(tool, searchPath: toolPATH, isExecutable: isExecutableFile)
        }
    }

    /// Pure PATH search; used by `which` and tests.
    static func findExecutable(_ tool: String, searchPath: String,
                               isExecutable: (String) -> Bool) -> String? {
        guard !tool.isEmpty, !tool.contains("/") else { return nil }
        for dir in splitPATH(searchPath) where dir.hasPrefix("/") {
            let candidate = dir.hasSuffix("/") ? dir + tool : dir + "/" + tool
            if isExecutable(candidate) { return candidate }
        }
        return nil
    }

    /// Regular file (after following symlinks) that the current user may execute.
    static func isExecutableFile(_ path: String) -> Bool {
        var info = stat()
        guard stat(path, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG else { return false }
        return access(path, X_OK) == 0
    }

    private static let whichCache = WhichCache(negativeTTL: 60)

    /// Runs a tool found via which() with environment PATH=toolPATH (+ HOME). Returns status 127 if not found.
    /// The rest of PortPilot's environment is inherited (USER, TMPDIR, LANG, PM2_HOME...).
    static func runTool(_ tool: String, _ arguments: [String], timeout: TimeInterval = 15) -> ShellResult {
        guard let path = which(tool) else {
            return ShellResult(status: notFoundStatus, stdout: "", stderr: "\(tool): command not found")
        }
        return run(path, arguments, timeout: timeout, environment: toolEnvironment())
    }

    /// Environment for tools: inherited environment with PATH and HOME pinned.
    static func toolEnvironment() -> [String: String] {
        var env = ProcessInfo.processInfo.environment
        env["PATH"] = toolPATH
        env["HOME"] = NSHomeDirectory()
        return env
    }

    // MARK: - Admin

    /// Runs `/usr/bin/osascript -e 'do shell script "<cmd>" with administrator privileges'` (escaped safely).
    /// Shows the standard macOS password dialog; status 1 with "User canceled. (-128)" when dismissed.
    static func runAsAdmin(_ command: String) -> ShellResult {
        run("/usr/bin/osascript", ["-e", doShellScript(command, administrator: true)], timeout: 300)
    }

    /// AppleScript source for `do shell script` (osascript receives it as one argv element, so only
    /// AppleScript-level escaping is needed). Pure; used by tests.
    static func doShellScript(_ command: String, administrator: Bool) -> String {
        "do shell script \(appleScriptStringLiteral(command))" + (administrator ? " with administrator privileges" : "")
    }

    /// Quotes `text` as an AppleScript string literal: backslashes and double quotes are escaped; everything
    /// else (including newlines) is legal inside an AppleScript string.
    static func appleScriptStringLiteral(_ text: String) -> String {
        var literal = "\""
        for scalar in text.unicodeScalars {
            switch scalar {
            case "\\": literal += "\\\\"
            case "\"": literal += "\\\""
            default: literal.unicodeScalars.append(scalar)
            }
        }
        literal += "\""
        return literal
    }
}

// MARK: - Helpers

/// Drains one pipe with a non-blocking dispatch read source so the child never stalls on a full pipe buffer
/// and no thread ever blocks in `read(2)`. The source owns the read end until it is cancelled; the `Pipe`
/// (whose FileHandle closes the descriptor on dealloc) is kept alive by the cancel handler, so the descriptor
/// cannot be closed or reused while the source still watches it.
private final class PipeDrain: @unchecked Sendable {
    private let source: DispatchSourceRead
    private let lock = NSLock()
    private var buffer = Data()
    private let limit: Int
    /// Signalled exactly once, from the cancel handler (after EOF, a read error or `collect`).
    private let finished = DispatchSemaphore(value: 0)

    private static let utilityQueue = DispatchQueue(label: "eu.shhshm.PortPilot.shell.pipes", qos: .utility,
                                                    attributes: .concurrent)
    private static let userInitiatedQueue = DispatchQueue(label: "eu.shhshm.PortPilot.shell.pipes.user",
                                                          qos: .userInitiated, attributes: .concurrent)

    /// The readers run at the caller's priority: a button action (user-initiated) never waits on utility-QoS
    /// readers (a priority inversion), while background scans keep theirs at utility.
    private static var queueForCurrentThread: DispatchQueue {
        qos_class_self().rawValue > QOS_CLASS_UTILITY.rawValue ? userInitiatedQueue : utilityQueue
    }

    init(pipe: Pipe, limit: Int) {
        self.limit = limit
        let fd = pipe.fileHandleForReading.fileDescriptor
        let flags = fcntl(fd, F_GETFL)
        if flags >= 0 { _ = fcntl(fd, F_SETFL, flags | O_NONBLOCK) }

        source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: Self.queueForCurrentThread)
        let finished = self.finished
        source.setEventHandler { [unowned self] in self.drain(fd) }
        source.setCancelHandler {
            withExtendedLifetime(pipe) {}
            finished.signal()
        }
        source.resume()
    }

    /// Reads everything currently available; cancels the source on EOF or error.
    private func drain(_ fd: Int32) {
        var chunk = [UInt8](repeating: 0, count: 64 * 1024)
        while true {
            let count = chunk.withUnsafeMutableBytes { read(fd, $0.baseAddress, $0.count) }
            if count > 0 {
                lock.lock()
                let room = limit - buffer.count
                if room > 0 { buffer.append(contentsOf: chunk[0..<min(count, room)]) }
                lock.unlock()
                continue
            }
            if count < 0 {
                let code = errno
                if code == EINTR { continue }
                if code == EAGAIN || code == EWOULDBLOCK { return }
            }
            source.cancel() // EOF (0) or a real read error
            return
        }
    }

    /// Waits until EOF or `deadline`, stops reading, and returns what was captured. Call exactly once.
    func collect(deadline: DispatchTime) -> Data {
        if finished.wait(timeout: deadline) == .timedOut {
            source.cancel()
            // The event handler never blocks, so the cancel handler runs promptly.
            finished.wait()
        }
        lock.lock()
        defer { lock.unlock() }
        return buffer
    }
}

/// Thread-safe memo for `Shell.which`.
private final class WhichCache: @unchecked Sendable {
    private struct Entry {
        let path: String?
        let date: Date
    }

    private let lock = NSLock()
    private var entries: [String: Entry] = [:]
    private let negativeTTL: TimeInterval

    init(negativeTTL: TimeInterval) {
        self.negativeTTL = negativeTTL
    }

    func value(for tool: String, compute: () -> String?) -> String? {
        lock.lock()
        let cached = entries[tool]
        lock.unlock()

        if let cached {
            if let path = cached.path, Shell.isExecutableFile(path) { return path }
            if cached.path == nil, Date().timeIntervalSince(cached.date) < negativeTTL { return nil }
        }
        // Computed outside the lock: the first call may capture the login-shell PATH (up to 3 s).
        let path = compute()
        lock.lock()
        entries[tool] = Entry(path: path, date: Date())
        lock.unlock()
        return path
    }
}
