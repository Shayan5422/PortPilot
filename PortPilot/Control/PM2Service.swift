import Darwin
import Foundation

/// One app instance from `pm2 jlist`.
struct PM2Process: Hashable, Sendable {
    /// pm_id.
    let id: Int
    let name: String
    /// 0 when the app is stopped/errored. In cluster mode this is a worker: the port is held by the God Daemon.
    let pid: Int32
    /// pm2_env.status, e.g. "online", "stopped", "errored".
    let status: String?
    /// pm2_env.exec_mode: "fork_mode" or "cluster_mode".
    var execMode: String? = nil
    /// The PORT the app was started with (pm2_env.PORT, else pm2_env.env.PORT), when set.
    var port: UInt16? = nil

    /// Cluster-mode instances share one port through the daemon, so they are stopped and deleted together.
    var isClusterMode: Bool { execMode == "cluster_mode" || execMode == "cluster" }
}

/// What `PM2Service.delete` did to pm2's saved process list (`$PM2_HOME/dump.pm2`, read by `pm2 resurrect`).
enum PM2SavedListUpdate: Equatable, Sendable {
    /// This many entries for the app were removed; the previous file was kept as dump.pm2.bak.
    case removed(Int)
    /// The saved list has no entry for the app (never saved, or there is no saved list at all).
    case notSaved
    /// The saved list could not be read or written; it was left as it was.
    case unavailable(String)

    /// Short note for the banner when the user needs to act; nil when all is well.
    var note: String? {
        switch self {
        case .removed, .notSaved: return nil
        case .unavailable: return "pm2's saved list wasn't updated, so run “pm2 save” to keep it from coming back"
        }
    }
}

/// Talks to an already-running PM2 daemon through the `pm2` CLI.
///
/// Safety: every pm2 command would spawn a new God Daemon if none is running, so all commands are gated by
/// `isDaemonRunning()` (live pid in `$PM2_HOME/pm2.pid`, same user, started no later than the pid file was
/// written). Callers should additionally only call `processesByPID()` when a daemon is in the process table.
///
/// PortPilot never runs `pm2 save`: that would replace the user's whole saved list with whatever the daemon happens
/// to run right now. Deleting an app edits only that app's entries in dump.pm2.
final class PM2Service: @unchecked Sendable {
    /// PM2_HOME the CLI will use: `$PM2_HOME`, else `~/.pm2` (same rule as pm2 itself).
    let pm2Home: String
    private let cacheMaxAge: TimeInterval = 5

    private let lock = NSLock()
    private var cache: (date: Date, processes: [PM2Process])?

    init(pm2Home: String? = nil) {
        if let pm2Home {
            self.pm2Home = pm2Home
        } else if let env = ProcessInfo.processInfo.environment["PM2_HOME"], !env.isEmpty {
            self.pm2Home = env
        } else {
            self.pm2Home = NSHomeDirectory() + "/.pm2"
        }
    }

    /// `$PM2_HOME/dump.pm2`: the list `pm2 resurrect` (and a `pm2 startup` boot script) starts again.
    var dumpFileURL: URL { URL(fileURLWithPath: pm2Home, isDirectory: true).appendingPathComponent("dump.pm2") }

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
        var map: [Int32: (id: Int, name: String)] = [:]
        for process in processList() where process.pid > 0 && map[process.pid] == nil {
            map[process.pid] = (process.id, process.name)
        }
        return map
    }

    /// Only call when a daemon is running. Every app instance from `pm2 jlist`, including stopped ones, with its
    /// exec mode and PORT (cluster-mode apps listen through the daemon, so their ports are attributed by these).
    /// Cached 5 s; [] without running anything when no daemon is alive or pm2 is missing.
    func processList() -> [PM2Process] {
        lock.lock()
        if let cache, Date().timeIntervalSince(cache.date) < cacheMaxAge {
            defer { lock.unlock() }
            return cache.processes
        }
        lock.unlock()

        let processes = freshProcessList() ?? []
        lock.lock()
        cache = (Date(), processes)
        lock.unlock()
        return processes
    }

    /// pm2 stop <id>. A cluster-mode app is stopped as a whole (`pm2 stop <every instance id>`): its instances share
    /// the port through the daemon, so stopping one of them would leave the port open. Succeeds without running
    /// anything when the instance no longer exists.
    func stop(id: Int) throws {
        let list = freshProcessList()
        let ids = Self.instanceIDs(for: id, name: nil, in: list, wholeApp: { $0.isClusterMode })
        guard !ids.isEmpty else { return }
        try runCommand(["stop"] + ids.map(String.init), action: "stop")
    }

    /// Removes the app for good: `pm2 delete` on every instance of the app (all cluster workers, all fork
    /// instances sharing its name), then drops only this app's entries from dump.pm2 so `pm2 resurrect` won't bring
    /// it back. It never runs `pm2 save`, so the rest of the saved list is left exactly as the user saved it.
    ///
    /// - Parameter name: the app's name when the caller knows it (used if the instance is already gone).
    /// - Returns: what happened to the saved list (`note` says whether the user should run `pm2 save`).
    @discardableResult
    func delete(id: Int, name: String? = nil) throws -> PM2SavedListUpdate {
        let list = freshProcessList()
        let appName = list?.first(where: { $0.id == id })?.name ?? name
        let ids = Self.instanceIDs(for: id, name: appName, in: list, wholeApp: { _ in true })
        if !ids.isEmpty {
            try runCommand(["delete"] + ids.map(String.init), action: "delete")
        }
        guard let appName, !appName.isEmpty else {
            return .unavailable("the app's name is unknown")
        }
        return Self.removeApp(named: appName, fromDumpAt: dumpFileURL)
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

    /// Uncached `pm2 jlist`; nil when no daemon runs or the command fails (the caller then falls back to the id).
    private func freshProcessList() -> [PM2Process]? {
        guard isDaemonRunning() else { return nil }
        let result = Shell.runTool("pm2", ["jlist"], timeout: 10)
        guard result.ok else { return nil }
        return Self.parseJList(result.stdout)
    }

    func invalidateCache() {
        lock.lock()
        cache = nil
        lock.unlock()
    }

    // MARK: - Targets (pure, tested)

    /// pm_ids a command for instance `id` must address, ascending.
    /// - `list` nil (jlist unavailable): just `id`.
    /// - `id` listed: its whole app (every instance with the same name) when `wholeApp` says so, else `id` alone.
    /// - `id` gone: the remaining instances named `name` when `wholeApp` applies to them, else nothing.
    static func instanceIDs(for id: Int, name: String?, in list: [PM2Process]?,
                            wholeApp: (PM2Process) -> Bool) -> [Int] {
        guard let list else { return [id] }
        if let process = list.first(where: { $0.id == id }) {
            guard wholeApp(process) else { return [id] }
            return Array(Set(list.filter { $0.name == process.name }.map(\.id) + [id])).sorted()
        }
        guard let name else { return [] }
        return Array(Set(list.filter { $0.name == name && wholeApp($0) }.map(\.id))).sorted()
    }

    /// The cluster-mode app a port held by the God Daemon belongs to. In pm2 cluster mode the daemon is the Node
    /// cluster primary, so it — not the app's workers — owns the listening socket.
    ///
    /// The only running cluster app when there is one; otherwise the running cluster app started with PORT=`port`.
    /// nil when that is still ambiguous (or nothing matches): the row then stays unattributed and Stop refuses to
    /// signal the daemon. Returns the app's lowest pm_id; `stop(id:)` and `delete(id:name:)` act on every instance.
    static func clusterApp(forDaemonPort port: UInt16, in list: [PM2Process]) -> PM2Process? {
        let running = list.filter { process in
            guard process.isClusterMode else { return false }
            return !["stopped", "stopping", "errored", "one-launch-status"].contains(process.status ?? "online")
        }
        func single(_ candidates: [PM2Process]) -> PM2Process? {
            guard Set(candidates.map(\.name)).count == 1 else { return nil }
            return candidates.min { $0.id < $1.id }
        }
        return single(running) ?? single(running.filter { $0.port == port })
    }

    // MARK: - Saved list (dump.pm2)

    /// Largest dump.pm2 PortPilot will rewrite.
    static let maxDumpBytes = 32 * 1024 * 1024

    /// Removes every entry named `name` from a pm2 dump file. The previous contents are copied to
    /// `<file>.bak` first (what `pm2 save` does too), the new list is written atomically, and the file's permissions
    /// are kept. Every other entry is left untouched. A missing file means nothing is saved.
    static func removeApp(named name: String, fromDumpAt url: URL) -> PM2SavedListUpdate {
        let fileURL = url.resolvingSymlinksInPath()
        let path = fileURL.path
        guard FileManager.default.fileExists(atPath: path) else { return .notSaved }
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: path),
              (attributes[.size] as? NSNumber)?.intValue ?? Int.max <= maxDumpBytes,
              let data = FileManager.default.contents(atPath: path) else {
            return .unavailable("couldn't read \(Format.abbreviatePath(path))")
        }
        guard let entries = (try? JSONSerialization.jsonObject(with: data)) as? [Any] else {
            return .unavailable("\(Format.abbreviatePath(path)) isn't a pm2 process list")
        }
        let kept = entries.filter { (($0 as? [String: Any])?["name"] as? String) != name }
        let removed = entries.count - kept.count
        guard removed > 0 else { return .notSaved }
        do {
            let output = try JSONSerialization.data(withJSONObject: kept,
                                                    options: [.prettyPrinted, .withoutEscapingSlashes])
            let backupURL = fileURL.deletingLastPathComponent()
                .appendingPathComponent(fileURL.lastPathComponent + ".bak")
            try data.write(to: backupURL, options: .atomic)
            try output.write(to: fileURL, options: .atomic)
            if let permissions = attributes[.posixPermissions] {
                try? FileManager.default.setAttributes([.posixPermissions: permissions], ofItemAtPath: path)
                try? FileManager.default.setAttributes([.posixPermissions: permissions], ofItemAtPath: backupURL.path)
            }
        } catch {
            return .unavailable(error.localizedDescription)
        }
        return .removed(removed)
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
            let port = intValue(env?["PORT"]) ?? intValue((env?["env"] as? [String: Any])?["PORT"])
            return PM2Process(id: id, name: name, pid: pid, status: env?["status"] as? String,
                              execMode: env?["exec_mode"] as? String,
                              port: port.flatMap { UInt16(exactly: $0) }.flatMap { $0 > 0 ? $0 : nil })
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
        if let string = value as? String { return Int(string.trimmingCharacters(in: .whitespaces)) }
        return nil
    }
}
