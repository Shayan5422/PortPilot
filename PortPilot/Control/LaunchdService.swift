import Darwin
import Foundation

/// User-facing error thrown by the Control layer (launchctl / pm2 / docker / signals).
struct ControlError: LocalizedError { let message: String; var errorDescription: String? { message } }

extension ControlError {
    init(_ message: String) {
        self.init(message: message)
    }
}

/// One row of `launchctl list`.
struct LaunchctlListEntry: Hashable, Sendable {
    /// nil when the job is loaded but not running ("-").
    let pid: Int32?
    /// Last exit status; negative values are signals (e.g. -15 = SIGTERM). nil when "-".
    let lastExitStatus: Int32?
    let label: String
}

/// The launchd-relevant parts of a job plist.
struct LaunchdPlistInfo: Hashable, Sendable {
    let label: String
    let path: String
    /// Program + arguments summary, e.g. "/opt/homebrew/bin/node server.js". Empty when the plist has no program.
    let command: String
    let workingDirectory: String?
    let runAtLoad: Bool
    let keepAlive: Bool
    /// The plist's own `Disabled` key (overridden by `launchctl enable/disable`).
    let disabledInPlist: Bool
    /// False when `LimitLoadToSessionType` excludes "Aqua" (e.g. "LoginWindow"-only agents): such a job never
    /// loads in the user's GUI domain, so it is not offered as a startup item.
    var loadsInGUISession: Bool = true
}

/// What `launchctl print <service>` tells us when a job has no plist in the indexed folders.
struct LaunchctlPrintInfo: Hashable, Sendable {
    let path: String?
    /// Flags from the "properties = keepalive | runatload | …" line, lowercased.
    let properties: Set<String>
}

/// Reads and controls launchd jobs in the user's GUI domain through `/bin/launchctl`.
/// Thread-safe: caches are guarded by a lock and subprocesses run on the calling (background) thread.
/// Never modifies or deletes plist files.
final class LaunchdService: @unchecked Sendable {
    let uid: UInt32
    private let homeDirectory: String
    private let launchctlPath = "/bin/launchctl"

    /// How long the label → plist index and `launchctl print` fallbacks are reused.
    private let indexMaxAge: TimeInterval = 30

    private let lock = NSLock()
    private var plistIndex: [String: LaunchdPlistInfo] = [:]
    private var plistIndexDate: Date?
    private var printCache: [String: (job: LaunchdJob?, date: Date)] = [:]

    init(uid: UInt32 = getuid(), homeDirectory: String = NSHomeDirectory()) {
        self.uid = uid
        self.homeDirectory = homeDirectory
    }

    var guiDomain: String { "gui/\(uid)" }

    /// `~/Library/LaunchAgents` — agents the user owns and can manage without admin rights.
    var userAgentsDirectory: String { homeDirectory + "/Library/LaunchAgents" }
    static let sharedAgentsDirectory = "/Library/LaunchAgents"
    static let daemonsDirectory = "/Library/LaunchDaemons"

    /// Search order for the label index: earlier folders win when two plists declare the same label.
    private var indexedDirectories: [String] {
        [userAgentsDirectory, Self.sharedAgentsDirectory, Self.daemonsDirectory]
    }

    private func serviceTarget(_ label: String) -> String { "\(guiDomain)/\(label)" }

    // MARK: - Reading state

    /// `launchctl list` → pid → label for running jobs (skips "-" pids). Includes "application.*" labels (callers filter).
    func runningJobLabels() -> [Int32: String] {
        let result = launchctl(["list"], timeout: 5)
        guard result.ok else { return [:] }
        return Self.runningLabels(fromListOutput: result.stdout)
    }

    /// Job info for a label: plist path (search ~/Library/LaunchAgents, /Library/LaunchAgents, /Library/LaunchDaemons
    /// by Label key — cached index of plists, refreshed at most every 30 s), keepAlive/runAtLoad from the plist
    /// (KeepAlive may be bool or dict → true), pid. Falls back to `launchctl print gui/<uid>/<label>` "path = ".
    ///
    /// Returns nil for "application.*" labels (GUI app instances, never auto-start jobs) and for labels launchd
    /// does not know when `pid` is nil. Fallback lookups are cached per label for 30 s, so calling this every
    /// tick costs at most one `launchctl print` per unknown label per 30 s.
    func job(label: String, pid: Int32?) -> LaunchdJob? {
        guard Self.isValidLabel(label), !Self.isAppInstanceLabel(label) else { return nil }

        if let info = indexedPlist(for: label) {
            let domain = info.path.hasPrefix(Self.daemonsDirectory + "/") ? "system" : guiDomain
            return LaunchdJob(label: label, domain: domain, plistPath: info.path,
                              keepAlive: info.keepAlive, runAtLoad: info.runAtLoad, pid: pid)
        }

        lock.lock()
        let cached = printCache[label]
        lock.unlock()
        if let cached, Date().timeIntervalSince(cached.date) < indexMaxAge {
            return Self.restamped(cached.job, label: label, domain: guiDomain, pid: pid)
        }

        var resolved: LaunchdJob?
        let printed = launchctl(["print", serviceTarget(label)], timeout: 5)
        if printed.ok {
            let info = Self.parsePrintOutput(printed.stdout)
            var keepAlive = info.properties.contains("keepalive")
            var runAtLoad = info.properties.contains("runatload")
            if let path = info.path, let plist = Self.readPlist(at: path) {
                keepAlive = plist.keepAlive
                runAtLoad = plist.runAtLoad
            }
            resolved = LaunchdJob(label: label, domain: guiDomain, plistPath: info.path,
                                  keepAlive: keepAlive, runAtLoad: runAtLoad, pid: pid)
        }
        lock.lock()
        printCache[label] = (resolved, Date())
        lock.unlock()
        return Self.restamped(resolved, label: label, domain: guiDomain, pid: pid)
    }

    /// Re-stamps a cached job with the caller's pid; a running label launchd could not describe still counts
    /// as a (non-restarting) launchd job.
    private static func restamped(_ cached: LaunchdJob?, label: String, domain: String, pid: Int32?) -> LaunchdJob? {
        if let cached {
            return LaunchdJob(label: cached.label, domain: cached.domain, plistPath: cached.plistPath,
                              keepAlive: cached.keepAlive, runAtLoad: cached.runAtLoad, pid: pid)
        }
        guard let pid else { return nil }
        return LaunchdJob(label: label, domain: domain, plistPath: nil, keepAlive: false, runAtLoad: false, pid: pid)
    }

    /// Non-Apple user agents: every plist in ~/Library/LaunchAgents (+ /Library/LaunchAgents read-only), merged with
    /// `launchctl print-disabled gui/<uid>` and `launchctl list` (pid/last exit). Skips "com.apple." labels.
    ///
    /// Plists that cannot be read/parsed, empty placeholder plists with neither Label nor program, and agents whose
    /// LimitLoadToSessionType excludes Aqua (they never run in the user's session) are skipped.
    /// A plist without Label uses its file name. Items from ~/Library/LaunchAgents come first, then the shared
    /// /Library/LaunchAgents ones (see `StartupItem.isSharedAgent`); each block sorted by label.
    func startupItems() -> [StartupItem] {
        let index = refreshIndex(force: true)

        let list = launchctl(["list"], timeout: 5)
        let listEntries = list.ok ? Self.parseList(list.stdout) : []
        var entriesByLabel: [String: LaunchctlListEntry] = [:]
        for entry in listEntries where entriesByLabel[entry.label] == nil {
            entriesByLabel[entry.label] = entry
        }

        let disabledOutput = launchctl(["print-disabled", guiDomain], timeout: 5)
        let overrides = disabledOutput.ok ? Self.parsePrintDisabled(disabledOutput.stdout) : [:]

        let agentPrefixes = [userAgentsDirectory + "/", Self.sharedAgentsDirectory + "/"]
        let items = index.values
            .filter { info in
                !info.label.hasPrefix("com.apple.") && info.loadsInGUISession
                    && agentPrefixes.contains { info.path.hasPrefix($0) }
            }
            .map { info -> StartupItem in
                let entry = entriesByLabel[info.label]
                return StartupItem(label: info.label, plistPath: info.path, command: info.command,
                                   workingDirectory: info.workingDirectory, runAtLoad: info.runAtLoad,
                                   keepAlive: info.keepAlive,
                                   isDisabled: overrides[info.label] ?? info.disabledInPlist,
                                   isLoaded: entry != nil, pid: entry?.pid,
                                   lastExitStatus: entry?.lastExitStatus, ports: [])
            }
        return items.sorted { lhs, rhs in
            if lhs.isSharedAgent != rhs.isSharedAgent { return !lhs.isSharedAgent }
            return lhs.label.localizedCaseInsensitiveCompare(rhs.label) == .orderedAscending
        }
    }

    /// True when `label` currently appears in `launchctl list` (bootstrapped into the GUI domain).
    func isLoaded(label: String) -> Bool {
        let result = launchctl(["list"], timeout: 5)
        guard result.ok else { return false }
        return Self.parseList(result.stdout).contains { $0.label == label }
    }

    // MARK: - Actions

    /// launchctl bootout gui/<uid>/<label> (stops now; returns at next login if RunAtLoad). Treat "No such process" /
    /// "Could not find service" (status 3/113) as success.
    func stop(label: String) throws {
        try Self.validate(label)
        // bootout waits for the job to exit (launchd escalates to SIGKILL after the job's ExitTimeOut, 20 s default).
        let result = launchctl(["bootout", serviceTarget(label)], timeout: 30)
        if result.ok || Self.isNotLoadedError(result) { return }
        // bootout sometimes reports EIO (5) although the job is gone — trust the job list.
        if !isLoaded(label: label) { return }
        throw ControlError("Couldn't stop \(label): \(result.message)")
    }

    /// bootout + `launchctl disable gui/<uid>/<label>` (persists across logins; the plist is NOT deleted).
    /// The disable override is written first so the job cannot come back at next login even if bootout fails.
    func disable(label: String) throws {
        try Self.validate(label)
        let disabled = launchctl(["disable", serviceTarget(label)], timeout: 10)
        var problems: [String] = []
        if !disabled.ok { problems.append("couldn't disable auto-start (\(disabled.message))") }
        do {
            try stop(label: label)
        } catch {
            problems.append(error.localizedDescription)
        }
        invalidateCaches()
        if !problems.isEmpty {
            throw ControlError("\(label): " + problems.joined(separator: "; "))
        }
    }

    /// `launchctl enable gui/<uid>/<label>` + `launchctl bootstrap gui/<uid> <plistPath>` (ignore "already loaded"/status 5/37).
    /// A failed bootstrap counts as success when the label is in `launchctl list` afterwards.
    func enable(label: String, plistPath: String) throws {
        try Self.validate(label)
        guard plistPath.hasPrefix("/") else { throw ControlError("Invalid plist path for \(label): \(plistPath)") }
        guard FileManager.default.fileExists(atPath: plistPath) else {
            throw ControlError("Can't enable \(label): \(plistPath) no longer exists.")
        }
        let enabled = launchctl(["enable", serviceTarget(label)], timeout: 10)
        guard enabled.ok else { throw ControlError("Couldn't enable \(label): \(enabled.message)") }
        invalidateCaches()

        let bootstrap = launchctl(["bootstrap", guiDomain, plistPath], timeout: 15)
        if bootstrap.ok { return }
        // 5 (EIO) / 37 (EALREADY) usually mean "already loaded" but EIO is also used for real failures,
        // so the job list decides.
        if isLoaded(label: label) { return }
        throw ControlError("Couldn't load \(label): \(bootstrap.message)")
    }

    /// `launchctl kickstart gui/<uid>/<label>`.
    func start(label: String) throws {
        try Self.validate(label)
        let result = launchctl(["kickstart", serviceTarget(label)], timeout: 15)
        if result.ok { return }
        if Self.isNotLoadedError(result) {
            throw ControlError("\(label) isn't loaded — turn it on first.")
        }
        throw ControlError("Couldn't start \(label): \(result.message)")
    }

    /// "application.*" labels are GUI app instances, not auto-start jobs.
    static func isAppInstanceLabel(_ label: String) -> Bool {
        label.hasPrefix("application.")
    }

    // MARK: - Plist index

    /// Drops cached lookups so the next `job(label:pid:)` sees fresh state.
    func invalidateCaches() {
        lock.lock()
        plistIndexDate = nil
        printCache.removeAll()
        lock.unlock()
    }

    private func indexedPlist(for label: String) -> LaunchdPlistInfo? {
        refreshIndex(force: false)[label]
    }

    /// Returns the label → plist index, rescanning the folders when forced or older than `indexMaxAge`.
    @discardableResult
    private func refreshIndex(force: Bool) -> [String: LaunchdPlistInfo] {
        lock.lock()
        if !force, let date = plistIndexDate, Date().timeIntervalSince(date) < indexMaxAge {
            defer { lock.unlock() }
            return plistIndex
        }
        lock.unlock()

        var index: [String: LaunchdPlistInfo] = [:]
        for directory in indexedDirectories {
            for info in Self.scanDirectory(directory) where index[info.label] == nil {
                index[info.label] = info
            }
        }

        lock.lock()
        plistIndex = index
        plistIndexDate = Date()
        lock.unlock()
        return index
    }

    /// Parses every `*.plist` in `directory` (sorted by file name). Unreadable entries are skipped.
    static func scanDirectory(_ directory: String) -> [LaunchdPlistInfo] {
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: directory) else { return [] }
        return names
            .filter { $0.hasSuffix(".plist") && !$0.hasPrefix(".") }
            .sorted()
            .compactMap { readPlist(at: directory + "/" + $0) }
    }

    /// Largest plist we are willing to parse; launchd plists are a few KB.
    static let maxPlistBytes = 1 << 20

    /// Reads a launchd plist (XML or binary). nil when it is not a regular file, too large, unreadable or invalid.
    static func readPlist(at path: String) -> LaunchdPlistInfo? {
        var info = stat()
        // stat follows symlinks (e.g. /Library/LaunchAgents/com.avast.userinit.plist → inside an app bundle);
        // refusing non-regular files keeps us from blocking on a FIFO.
        guard stat(path, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG,
              info.st_size <= off_t(maxPlistBytes) else { return nil }
        guard let data = FileManager.default.contents(atPath: path) else { return nil }
        return parsePlist(data: data, path: path)
    }

    /// Parses plist bytes. Pure; used by tests.
    static func parsePlist(data: Data, path: String) -> LaunchdPlistInfo? {
        guard let object = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil),
              let dictionary = object as? [String: Any] else { return nil }
        return parsePlist(dictionary, path: path)
    }

    /// Interprets a launchd plist dictionary. Missing Label → file name without ".plist". Returns nil for
    /// placeholder plists that have neither a Label nor a program (launchd refuses those anyway).
    static func parsePlist(_ plist: [String: Any], path: String) -> LaunchdPlistInfo? {
        let program = (plist["Program"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        let arguments = (plist["ProgramArguments"] as? [Any])?.compactMap { $0 as? String } ?? []
        let explicitLabel = (plist["Label"] as? String).flatMap { isValidLabel($0) ? $0 : nil }

        guard explicitLabel != nil || program != nil || !arguments.isEmpty else { return nil }
        let fileName = (path as NSString).lastPathComponent
        let fallbackLabel = fileName.hasSuffix(".plist") ? String(fileName.dropLast(6)) : fileName
        guard let label = explicitLabel ?? (isValidLabel(fallbackLabel) ? fallbackLabel : nil) else { return nil }

        let workingDirectory = (plist["WorkingDirectory"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        return LaunchdPlistInfo(label: label, path: path,
                                command: commandSummary(program: program, arguments: arguments),
                                workingDirectory: workingDirectory,
                                runAtLoad: boolValue(plist["RunAtLoad"]),
                                keepAlive: keepAliveValue(plist["KeepAlive"]),
                                disabledInPlist: boolValue(plist["Disabled"]),
                                loadsInGUISession: loadsInGUISession(plist["LimitLoadToSessionType"]))
    }

    /// `LimitLoadToSessionType` is a string or an array of strings; absent means "Aqua" for agents.
    static func loadsInGUISession(_ value: Any?) -> Bool {
        let types: [String]
        if let single = value as? String {
            types = [single]
        } else if let list = value as? [Any] {
            types = list.compactMap { $0 as? String }
        } else {
            return true
        }
        return types.isEmpty || types.contains { $0.caseInsensitiveCompare("Aqua") == .orderedSame }
    }

    /// KeepAlive is a bool or a dictionary of conditions (SuccessfulExit, NetworkState, PathState…). Any
    /// non-empty condition dictionary means launchd may restart the job, so it counts as true.
    static func keepAliveValue(_ value: Any?) -> Bool {
        if let dictionary = value as? [String: Any] { return !dictionary.isEmpty }
        return boolValue(value)
    }

    /// Plist booleans (also tolerates 0/1 numbers written by hand-made plists).
    static func boolValue(_ value: Any?) -> Bool {
        if let bool = value as? Bool { return bool }
        if let number = value as? NSNumber { return number.boolValue }
        return false
    }

    /// launchd semantics: `Program` is the executable, `ProgramArguments` is argv (argv[0] included). When both
    /// are present the summary is Program + argv[1...]. Arguments with spaces are quoted like
    /// `ProcessDetails.commandLine`.
    static func commandSummary(program: String?, arguments: [String]) -> String {
        var parts: [String]
        if let program {
            parts = [program] + arguments.dropFirst()
        } else {
            parts = arguments
        }
        parts = parts.map { $0.isEmpty || $0.contains(" ") ? "\"\($0)\"" : $0 }
        return parts.joined(separator: " ")
    }

    // MARK: - Output parsers (pure, tested)

    /// Parses `launchctl list` ("PID\tStatus\tLabel" header + one tab-separated row per job).
    static func parseList(_ output: String) -> [LaunchctlListEntry] {
        var entries: [LaunchctlListEntry] = []
        for rawLine in output.split(whereSeparator: \.isNewline) {
            var fields = rawLine.split(separator: "\t", maxSplits: 2, omittingEmptySubsequences: false)
                .map { $0.trimmingCharacters(in: .whitespaces) }
            if fields.count != 3 {
                // Defensive: tolerate space-separated columns.
                fields = rawLine.split(separator: " ", maxSplits: 2, omittingEmptySubsequences: true)
                    .map { $0.trimmingCharacters(in: .whitespaces) }
            }
            guard fields.count == 3, fields[0] != "PID", !fields[2].isEmpty else { continue }
            guard fields[0] == "-" || Int32(fields[0]) != nil else { continue }
            let pid = Int32(fields[0]).flatMap { $0 > 0 ? $0 : nil }
            entries.append(LaunchctlListEntry(pid: pid, lastExitStatus: Int32(fields[1]), label: fields[2]))
        }
        return entries
    }

    /// pid → label for running jobs. When two rows share a pid the first wins.
    static func runningLabels(fromListOutput output: String) -> [Int32: String] {
        var labels: [Int32: String] = [:]
        for entry in parseList(output) {
            guard let pid = entry.pid, labels[pid] == nil else { continue }
            labels[pid] = entry.label
        }
        return labels
    }

    /// Parses `launchctl print-disabled <domain>` into label → isDisabled.
    /// Handles both `"label" => disabled|enabled` (macOS 11+) and the older `"label" => true|false`.
    static func parsePrintDisabled(_ output: String) -> [String: Bool] {
        var result: [String: Bool] = [:]
        for rawLine in output.split(whereSeparator: \.isNewline) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard line.hasPrefix("\""), let arrow = line.range(of: "\" => ", options: .backwards) else { continue }
            let label = String(line[line.index(after: line.startIndex)..<arrow.lowerBound])
            let value = line[arrow.upperBound...].trimmingCharacters(in: .whitespaces).lowercased()
            guard !label.isEmpty else { continue }
            switch value {
            case "disabled", "true": result[label] = true
            case "enabled", "false": result[label] = false
            default: continue
            }
        }
        return result
    }

    /// Extracts the top-level `path = …` and `properties = …` of `launchctl print <service>`. Nested blocks
    /// (environment, endpoints, coalitions…) and keys such as "stdout path" are ignored by tracking brace depth.
    static func parsePrintOutput(_ output: String) -> LaunchctlPrintInfo {
        var depth = 0
        var path: String?
        var properties = Set<String>()
        for rawLine in output.split(whereSeparator: \.isNewline) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("}") {
                depth = max(0, depth - 1)
                continue
            }
            if depth == 1 {
                if path == nil, line.hasPrefix("path = ") {
                    let value = line.dropFirst("path = ".count).trimmingCharacters(in: .whitespaces)
                    if value.hasPrefix("/") { path = value }
                } else if line.hasPrefix("properties = ") {
                    for flag in line.dropFirst("properties = ".count).split(separator: "|") {
                        let name = flag.trimmingCharacters(in: .whitespaces).lowercased()
                        if !name.isEmpty { properties.insert(name) }
                    }
                }
            }
            if line.hasSuffix("{") { depth += 1 }
        }
        return LaunchctlPrintInfo(path: path, properties: properties)
    }

    /// bootout/kickstart of a service that is not in the domain: "Boot-out failed: 3: No such process",
    /// "Could not find service …" / "Could not find specified service" (113).
    static func isNotLoadedError(_ result: ShellResult) -> Bool {
        if result.status == 3 || result.status == 113 { return true }
        let text = (result.stderr + "\n" + result.stdout).lowercased()
        return text.contains("no such process") || text.contains("could not find service")
            || text.contains("could not find specified service")
    }

    /// Labels are passed inside a service target ("gui/501/<label>"), so they must be non-empty single-line
    /// strings without "/".
    static func isValidLabel(_ label: String) -> Bool {
        !label.isEmpty && !label.contains("/") && !label.contains(where: \.isNewline)
    }

    private static func validate(_ label: String) throws {
        guard isValidLabel(label) else { throw ControlError("Invalid launchd label: \(label)") }
    }

    private func launchctl(_ arguments: [String], timeout: TimeInterval) -> ShellResult {
        Shell.run(launchctlPath, arguments, timeout: timeout)
    }
}

extension StartupItem {
    /// True for agents installed system-wide in /Library/LaunchAgents (plist owned by root; PortPilot only
    /// toggles their per-user enable/disable override and never touches the file).
    var isSharedAgent: Bool { plistPath.hasPrefix(LaunchdService.sharedAgentsDirectory + "/") }
}
