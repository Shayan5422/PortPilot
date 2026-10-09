import Darwin
import Foundation

/// One app from `pm2 jlist`.
struct PM2Process: Hashable, Sendable {
    /// pm_id.
    let id: Int
    let name: String
    /// 0 when the app is stopped/errored.
    let pid: Int32
    /// pm2_env.status, e.g. "online", "stopped", "errored".
    let status: String?
}

/// Talks to an already-running PM2 daemon through the `pm2` CLI.
///
/// Safety: every pm2 command would spawn a new God Daemon if none is running, so all commands are gated by
/// `isDaemonRunning()` (live pid in `$PM2_HOME/pm2.pid`, same user, started no later than the pid file was
/// written). Callers should additionally only call `processesByPID()` when a daemon is in the process table.
final class PM2Service: @unchecked Sendable {
    /// PM2_HOME the CLI will use: `$PM2_HOME`, else `~/.pm2` (same rule as pm2 itself).
    let pm2Home: String
    private let cacheMaxAge: TimeInterval = 5

    private let lock = NSLock()
    private var cache: (date: Date, processes: [Int32: (id: Int, name: String)])?

    init(pm2Home: String? = nil) {
        if let pm2Home {
            self.pm2Home = pm2Home
        } else if let env = ProcessInfo.processInfo.environment["PM2_HOME"], !env.isEmpty {
            self.pm2Home = env
        } else {
            self.pm2Home = NSHomeDirectory() + "/.pm2"
        }
    }

    /// True if `basic.comm`/argv looks like the PM2 God Daemon ("PM2 v5.x: God Daemon (...)").
    /// node rewrites argv[0] to the title (p_comm stays "node"), so argv[0] is the reliable signal.
    static func isDaemon(_ basic: ProcessBasic, details: ProcessDetails?) -> Bool {
        if isDaemonTitle(basic.comm) { return true }
        if let first = details?.arguments.first, isDaemonTitle(first) { return true }
        return false
    }

    static func isDaemonTitle(_ title: String) -> Bool {
        let trimmed = title.trimmingCharacters(in: .whitespaces)
        return trimmed.hasPrefix("PM2 v") && trimmed.contains("God Daemon")
    }

    /// Only call when a daemon is running. `pm2 jlist` → pid → (pm_id, name). Cached 5 s.
    /// Returns [:] without running anything when no daemon is alive for `pm2Home` or pm2 is not installed.
    func processesByPID() -> [Int32: (id: Int, name: String)] {
        lock.lock()
        if let cache, Date().timeIntervalSince(cache.date) < cacheMaxAge {
            defer { lock.unlock() }
            return cache.processes
        }
        lock.unlock()

        var map: [Int32: (id: Int, name: String)] = [:]
        if isDaemonRunning() {
            let result = Shell.runTool("pm2", ["jlist"], timeout: 10)
            if result.ok {
                for process in Self.parseJList(result.stdout) where process.pid > 0 && map[process.pid] == nil {
                    map[process.pid] = (process.id, process.name)
                }
            }
        }

        lock.lock()
        cache = (Date(), map)
        lock.unlock()
        return map
    }

    /// pm2 stop <id>
    func stop(id: Int) throws {
        try runCommand(["stop", String(id)], action: "stop")
    }

    /// pm2 delete <id> && pm2 save --force (so resurrect won't bring it back)
    func delete(id: Int) throws {
        try runCommand(["delete", String(id)], action: "delete")
        try runCommand(["save", "--force"], action: "save the process list after deleting")
    }

    private func runCommand(_ arguments: [String], action: String) throws {
        guard isDaemonRunning() else {
            throw ControlError("PM2 isn't running, so there is nothing to \(action).")
        }
        let result = Shell.runTool("pm2", arguments, timeout: 30)
        invalidateCache()
        guard result.ok else {
            if result.status == Shell.notFoundStatus, Shell.which("pm2") == nil {
                throw ControlError("The pm2 command was not found.")
            }
            throw ControlError("pm2 couldn't \(action): \(result.message)")
        }
    }

    func invalidateCache() {
        lock.lock()
        cache = nil
        lock.unlock()
    }

    // MARK: - Daemon detection (no subprocess)

    /// True when `pm2Home/pm2.pid` names a live process of the current user that started before (or within a
    /// few seconds after) the pid file was last written — i.e. the pid was not recycled after a crash.
    func isDaemonRunning() -> Bool {
        let pidFile = pm2Home + "/pm2.pid"
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: pidFile),
              let modified = attributes[.modificationDate] as? Date,
              let data = FileManager.default.contents(atPath: pidFile), data.count < 64,
              let pid = Int32(String(decoding: data, as: UTF8.self)
                  .trimmingCharacters(in: .whitespacesAndNewlines)),
              pid > 1,
              let info = Self.processStart(pid: pid),
              info.uid == getuid() else { return false }
        return info.start <= modified.addingTimeInterval(30)
    }

    /// Start date and uid of `pid` via sysctl(KERN_PROC_PID); nil when it does not exist.
    private static func processStart(pid: Int32) -> (start: Date, uid: uid_t)? {
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        let rc = mib.withUnsafeMutableBufferPointer { buffer in
            sysctl(buffer.baseAddress, u_int(buffer.count), &info, &size, nil, 0)
        }
        guard rc == 0, size >= MemoryLayout<kinfo_proc>.stride, info.kp_proc.p_pid == pid else { return nil }
        let started = info.kp_proc.p_un.__p_starttime
        let start = Date(timeIntervalSince1970: TimeInterval(started.tv_sec) + TimeInterval(started.tv_usec) / 1_000_000)
        return (start, info.kp_eproc.e_ucred.cr_uid)
    }

    // MARK: - Parsing (pure, tested)

    /// Parses `pm2 jlist`. PM2 may print warning lines (some starting with "[PM2]") before or after the JSON
    /// array, so every "[" that starts a line is tried as the start of the array; its end is found by
    /// string-aware bracket matching, so trailing noise containing "]" does not matter.
    static func parseJList(_ output: String) -> [PM2Process] {
        guard let array = extractJSONArray(output) else { return [] }
        return array.compactMap { element -> PM2Process? in
            guard let item = element as? [String: Any] else { return nil }
            let env = item["pm2_env"] as? [String: Any]
            guard let id = intValue(item["pm_id"]) ?? intValue(env?["pm_id"]) else { return nil }
            let name = (item["name"] as? String) ?? (env?["name"] as? String) ?? "pm2 #\(id)"
            let pid = intValue(item["pid"]).flatMap { Int32(exactly: $0) } ?? 0
            return PM2Process(id: id, name: name, pid: pid, status: env?["status"] as? String)
        }
    }

    private static func extractJSONArray(_ output: String) -> [Any]? {
        let bytes = Array(output.utf8)
        var atLineStart = true
        for (index, byte) in bytes.enumerated() {
            switch byte {
            case UInt8(ascii: "\n"), UInt8(ascii: "\r"):
                atLineStart = true
            case UInt8(ascii: " "), UInt8(ascii: "\t"):
                continue
            case UInt8(ascii: "[") where atLineStart:
                atLineStart = false
                if let end = matchingBracket(in: bytes, from: index),
                   let array = (try? JSONSerialization.jsonObject(with: Data(bytes[index...end]))) as? [Any] {
                    return array
                }
            default:
                atLineStart = false
            }
        }
        return nil
    }

    /// Index of the "]" closing the "[" at `start`, skipping brackets inside JSON strings; nil if unbalanced.
    static func matchingBracket(in bytes: [UInt8], from start: Int) -> Int? {
        var depth = 0
        var inString = false
        var escaped = false
        var index = start
        while index < bytes.count {
            let byte = bytes[index]
            if inString {
                if escaped {
                    escaped = false
                } else if byte == UInt8(ascii: "\\") {
                    escaped = true
                } else if byte == UInt8(ascii: "\"") {
                    inString = false
                }
            } else {
                switch byte {
                case UInt8(ascii: "\""): inString = true
                case UInt8(ascii: "["), UInt8(ascii: "{"): depth += 1
                case UInt8(ascii: "]"), UInt8(ascii: "}"):
                    depth -= 1
                    if depth == 0 { return byte == UInt8(ascii: "]") ? index : nil }
                    if depth < 0 { return nil }
                default: break
                }
            }
            index += 1
        }
        return nil
    }

    /// JSON integers (NSNumber bridging only succeeds for exactly representable values) or numeric strings.
    private static func intValue(_ value: Any?) -> Int? {
        if let int = value as? Int { return int }
        if let string = value as? String { return Int(string) }
        return nil
    }
}
