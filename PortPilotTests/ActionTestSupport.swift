import Darwin
import XCTest
@testable import PortPilot

/// Throwaway servers for the AppStore action tests, all inside one temporary folder (`PORTPILOT_TEST_TMP` when set,
/// else the test host's temporary folder — never a user folder such as ~/Downloads).
///
/// `cleanUp()` removes everything it started: the process groups it spawned, the launchd self-test jobs it loaded
/// (bootout, then `launchctl enable` for any it left disabled), and any process of this user still listening
/// on one of its ports whose working folder is inside the sandbox (relaunched servers, detached children).
/// launchd jobs only ever use labels starting with `eu.shhshm.PortPilot.selftest.`.
final class ActionSandbox {
    /// Real path of the sandbox folder (symlinks resolved, as the kernel reports working folders).
    let root: String
    /// Spawned process-group leaders with their start times (a group is only killed while it is still ours).
    private var spawned: [(pid: pid_t, startTime: UInt64)] = []
    private var ports: [UInt16] = []
    private var launchdLabels: [String] = []
    private var reapers: [DispatchSourceProcess] = []
    private var cleanedUp = false

    static let labelPrefix = "eu.shhshm.PortPilot.selftest."
    static let python = executable(["/opt/homebrew/bin/python3", "/usr/local/bin/python3"])
    static let node = executable(["/opt/homebrew/bin/node", "/usr/local/bin/node"])
    static let npm = executable(["/opt/homebrew/bin/npm", "/usr/local/bin/npm"])

    private static func executable(_ candidates: [String]) -> String? {
        candidates.first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    init() throws {
        let base = ProcessInfo.processInfo.environment["PORTPILOT_TEST_TMP"]
            .map { URL(fileURLWithPath: $0, isDirectory: true) } ?? FileManager.default.temporaryDirectory
        let created = base.appendingPathComponent("pp-actions-\(UUID().uuidString.prefix(8))", isDirectory: true)
        try FileManager.default.createDirectory(at: created, withIntermediateDirectories: true)
        guard let resolved = realpath(created.path, nil) else { throw XCTSkip("realpath failed") }
        root = String(cString: resolved)
        free(resolved)
        for protected in ["Downloads", "Documents", "Desktop"] where root.hasPrefix(NSHomeDirectory() + "/" + protected) {
            try? FileManager.default.removeItem(atPath: root)
            throw XCTSkip("the sandbox must not live in ~/\(protected)")
        }
    }

    deinit { cleanUp() }

    // MARK: Files

    /// Creates `relativePath` (and its folders) inside the sandbox; returns its absolute path.
    @discardableResult
    func write(_ contents: String, to relativePath: String, executable: Bool = false) throws -> String {
        let path = root + "/" + relativePath
        try FileManager.default.createDirectory(atPath: (path as NSString).deletingLastPathComponent,
                                                withIntermediateDirectories: true)
        try contents.write(toFile: path, atomically: true, encoding: .utf8)
        if executable { try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: path) }
        return path
    }

    /// Creates a folder inside the sandbox; returns its absolute path.
    func folder(_ relativePath: String) throws -> String {
        let path = root + "/" + relativePath
        try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
        return path
    }

    // MARK: Ports and processes

    /// A port nothing listens on right now, remembered for the clean-up sweep.
    func freePort() throws -> UInt16 {
        let fd = socket(AF_INET, SOCK_STREAM, IPPROTO_TCP)
        guard fd >= 0 else { throw XCTSkip("socket() failed") }
        defer { close(fd) }
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let bound = withUnsafeMutablePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(fd, $0, length) == 0 && getsockname(fd, $0, &length) == 0
            }
        }
        guard bound else { throw XCTSkip("bind() failed") }
        let port = UInt16(bigEndian: address.sin_port)
        ports.append(port)
        return port
    }

    /// PATH with Homebrew, HOME, and npm settings that keep npm away from the user's cache, logs and config.
    var environment: [String: String] {
        ["PATH": "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin", "HOME": NSHomeDirectory(), "LANG": "en_US.UTF-8",
         "npm_config_cache": root + "/.npm-cache", "npm_config_userconfig": root + "/.npmrc",
         "npm_config_logs_max": "0", "npm_config_update_notifier": "false", "npm_config_fund": "false",
         "npm_config_audit": "false"]
    }

    /// Starts `arguments` (argv, argv[0] included) from `executable` in `directory`, in its own process group,
    /// output to `<root>/logs`. It is reaped when it exits and killed (with its group) by `cleanUp()`.
    @discardableResult
    func spawn(_ executable: String, _ arguments: [String], in directory: String,
               environment extra: [String: String] = [:]) throws -> pid_t {
        let logs = try folder("logs")
        var attributes: posix_spawnattr_t?
        posix_spawnattr_init(&attributes)
        defer { posix_spawnattr_destroy(&attributes) }
        posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_SETPGROUP))
        posix_spawnattr_setpgroup(&attributes, 0)
        var actions: posix_spawn_file_actions_t?
        posix_spawn_file_actions_init(&actions)
        defer { posix_spawn_file_actions_destroy(&actions) }
        posix_spawn_file_actions_addchdir_np(&actions, directory)
        posix_spawn_file_actions_addopen(&actions, 0, "/dev/null", O_RDONLY, 0)
        posix_spawn_file_actions_addopen(&actions, 1, logs + "/\(spawned.count).log", O_WRONLY | O_CREAT | O_APPEND, 0o644)
        posix_spawn_file_actions_adddup2(&actions, 1, 2)
        let env = environment.merging(extra) { _, new in new }.map { "\($0.key)=\($0.value)" }
        let argv: [UnsafeMutablePointer<CChar>?] = arguments.map { strdup($0) } + [nil]
        let envp: [UnsafeMutablePointer<CChar>?] = env.map { strdup($0) } + [nil]
        defer { argv.forEach { free($0) }; envp.forEach { free($0) } }
        var pid: pid_t = 0
        let status = posix_spawn(&pid, executable, &actions, &attributes, argv, envp)
        guard status == 0 else { throw XCTSkip("posix_spawn \(executable) failed: \(status)") }
        spawned.append((pid, SysProc.basic(pid: pid)?.startTime ?? 0))
        let reaper = DispatchSource.makeProcessSource(identifier: pid, eventMask: .exit, queue: .global())
        reaper.setEventHandler {
            var status: Int32 = 0
            _ = waitpid(pid, &status, WNOHANG)
        }
        reaper.resume()
        reapers.append(reaper)
        return pid
    }

    /// A Python `http.server` on `port` in `directory`.
    @discardableResult
    func startHTTPServer(port: UInt16, in directory: String) throws -> pid_t {
        guard let python = Self.python else { throw XCTSkip("python3 is not installed") }
        return try spawn(python, [python, "-m", "http.server", String(port), "--bind", "127.0.0.1"], in: directory)
    }

    /// A Python listener on `port` that ignores SIGTERM (only SIGKILL ends it), like an app busy saving.
    @discardableResult
    func startStubbornListener(port: UInt16, in directory: String) throws -> pid_t {
        guard let python = Self.python else { throw XCTSkip("python3 is not installed") }
        let script = try write("""
            import signal, socket, sys, time
            signal.signal(signal.SIGTERM, signal.SIG_IGN)
            s = socket.socket()
            s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
            s.bind(("127.0.0.1", int(sys.argv[1])))
            s.listen()
            time.sleep(600)
            """, to: "stubborn.py")
        return try spawn(python, [python, script, String(port)], in: directory)
    }

    /// Sandbox processes of this user listening on `port`.
    func listeners(on port: UInt16) -> [ProcessBasic] {
        let uid = getuid()
        let own = getpid()
        var buffer: [proc_fdinfo] = []
        return SysProc.allProcesses().filter { process in
            guard process.uid == uid, process.pid > 1, process.pid != own,
                  SysProc.listeningTCPSockets(pid: process.pid, fdBuffer: &buffer)?.contains(where: { $0.port == port }) == true,
                  let cwd = SysProc.currentDirectory(pid: process.pid) else { return false }
            return cwd == root || cwd.hasPrefix(root + "/")
        }
    }

    /// Waits until a sandbox process other than `other` listens on `port`; returns its pid.
    func waitForListener(on port: UInt16, other: pid_t? = nil, timeout: TimeInterval = 20) async throws -> pid_t {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if let pid = listeners(on: port).map(\.pid).first(where: { $0 != other }) { return pid }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        throw XCTSkip("nothing started listening on :\(port) (see \(root)/logs)")
    }

    /// True once nothing of the sandbox listens on `port` (waits up to `timeout`).
    func waitUntilFree(_ port: UInt16, timeout: TimeInterval = 10) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if listeners(on: port).isEmpty { return true }
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        return listeners(on: port).isEmpty
    }

    func isAlive(_ pid: pid_t) -> Bool {
        ProcessWatch.isRunning(ProcessIdentity(pid: pid, startTime: SysProc.basic(pid: pid)?.startTime ?? 0))
    }

    // MARK: Scans

    /// A listener row for a live sandbox process, as a scan would show it.
    func listener(pid: pid_t, category: ListenerCategory = .service, manager: ProcessManager = .none,
                  name: String = "server") throws -> ListenerProcess {
        let basic = try XCTUnwrap(SysProc.basic(pid: pid))
        let sockets = try XCTUnwrap(SysProc.listeningTCPSockets(pid: pid))
        return ListenerProcess(basic: basic, details: SysProc.details(for: basic), sockets: sockets, usage: .zero,
                               treeUsage: .zero, category: category, project: nil, displayName: name,
                               frameworks: [], origin: nil, manager: manager, appName: nil, isRestricted: false)
    }

    /// Only the groups holding one of `ports`: a test never shows, let alone stops, anything that isn't its own.
    static func output(_ output: ScanOutput, keepingPorts ports: Set<UInt16>) -> ScanOutput {
        let groups = output.snapshot.groups.filter { !ports.isDisjoint(with: $0.ports) }
        let ids = Set(groups.flatMap { $0.processes.map(\.id) })
        let snapshot = ScanSnapshot(date: output.snapshot.date, groups: groups, table: output.snapshot.table,
                                    duration: output.snapshot.duration, restrictedCount: 0)
        return ScanOutput(snapshot: snapshot, plans: output.plans.filter { ids.contains($0.key) })
    }

    // MARK: launchd self-test jobs

    static func selftestLabel() -> String {
        labelPrefix + UUID().uuidString.prefix(8).lowercased()
    }

    /// Writes a launchd agent plist for `label` into `directory` (inside the sandbox) with the sandbox as its working
    /// folder and log destination. Returns its path.
    func writeLaunchAgent(label: String, directory: String, programArguments: [String], runAtLoad: Bool,
                          keepAlive: Bool) throws -> String {
        precondition(label.hasPrefix(Self.labelPrefix))
        try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
        let path = directory + "/\(label).plist"
        let plist: [String: Any] = [
            "Label": label, "ProgramArguments": programArguments, "RunAtLoad": runAtLoad, "KeepAlive": keepAlive,
            "WorkingDirectory": root, "StandardOutPath": root + "/logs-\(label).log",
            "StandardErrorPath": root + "/logs-\(label).log", "EnvironmentVariables": ["PATH": environment["PATH"] ?? ""],
        ]
        let data = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
        try data.write(to: URL(fileURLWithPath: path))
        launchdLabels.append(label)
        return path
    }

    func launchctl(_ arguments: [String]) -> ShellResult {
        Shell.run("/bin/launchctl", arguments, timeout: 30)
    }

    /// `launchctl` from a utility-QoS thread (Shell's pipe readers run at utility), so the test never blocks a
    /// higher-priority thread on it.
    func launchctlInBackground(_ arguments: [String]) async -> ShellResult {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                continuation.resume(returning: Shell.run("/bin/launchctl", arguments, timeout: 30))
            }
        }
    }

    var guiDomain: String { "gui/\(getuid())" }

    /// `launchctl bootstrap` of a self-test plist.
    func bootstrap(_ plistPath: String) async throws {
        let result = await launchctlInBackground(["bootstrap", guiDomain, plistPath])
        guard result.ok else { throw XCTSkip("launchctl bootstrap failed: \(result.message)") }
    }

    /// launchd's override for `label` from `launchctl print-disabled`: true disabled, false enabled, nil none.
    func launchdOverride(for label: String) async -> Bool? {
        LaunchdService.parsePrintDisabled(await launchctlInBackground(["print-disabled", guiDomain]).stdout)[label]
    }

    // MARK: Clean-up

    /// `cleanUp()` on a utility-QoS thread (tearDown).
    func cleanUpInBackground() async {
        // The caller awaits the clean-up, so nothing else touches the sandbox meanwhile.
        nonisolated(unsafe) let sandbox = self
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                sandbox.cleanUp()
                continuation.resume()
            }
        }
    }

    func cleanUp() {
        guard !cleanedUp else { return }
        cleanedUp = true
        // Unload every self-test job; re-enable only labels left disabled (running `launchctl enable` on a label that
        // has no override would itself add an entry to launchd's override list).
        let ownLabels = launchdLabels.filter { $0.hasPrefix(Self.labelPrefix) }
        for label in ownLabels { _ = launchctl(["bootout", "\(guiDomain)/\(label)"]) }
        if !ownLabels.isEmpty {
            let overrides = LaunchdService.parsePrintDisabled(launchctl(["print-disabled", guiDomain]).stdout)
            for label in ownLabels where overrides[label] == true {
                _ = launchctl(["enable", "\(guiDomain)/\(label)"])
            }
        }
        // Every member of each spawned process group, never anything started before the group's leader.
        let uid = getuid()
        for leader in spawned where leader.pid > 1 {
            for member in SysProc.allProcesses()
            where member.pgid == leader.pid && member.uid == uid && member.startTime >= leader.startTime {
                kill(member.pid, SIGKILL)
            }
        }
        for port in ports {
            for process in listeners(on: port) { kill(process.pid, SIGKILL) }
        }
        reapers.forEach { $0.cancel() }
        try? FileManager.default.removeItem(atPath: root)
    }
}
