import Darwin
import Foundation

/// Runs blocking work (syscalls, subprocesses, waits) on a background queue and awaits its result, so the main actor
/// never blocks on it.
enum OffMain {
    static func run<T>(_ work: @escaping () -> T) async -> T {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async { continuation.resume(returning: work()) }
        }
    }
}

/// Checks that an action really happened: that processes are gone, that a relaunched server listens again, what
/// launchd says about a job it just started. Everything polls off the main actor and re-verifies process identities,
/// so a recycled pid never counts.
enum ProcessWatch {
    /// The identities still running after waiting up to `seconds` for all of them to exit. Zombies count as exited.
    static func survivors(of identities: [ProcessIdentity], waitingUpTo seconds: TimeInterval,
                          pollInterval: TimeInterval = 0.1) async -> [ProcessIdentity] {
        let deadline = Date().addingTimeInterval(max(0, seconds))
        var remaining = identities
        while true {
            remaining = remaining.filter(isRunning)
            if remaining.isEmpty || Date() >= deadline { return remaining }
            try? await Task.sleep(nanoseconds: UInt64(max(0.01, pollInterval) * 1_000_000_000))
        }
    }

    /// True while `identity` is the same live process (not exited, not recycled, not a zombie).
    static func isRunning(_ identity: ProcessIdentity) -> Bool {
        guard let current = SysProc.basic(pid: identity.pid), current.startTime == identity.startTime else { return false }
        return !isZombie(identity.pid)
    }

    /// How waiting for a relaunched server's port ended.
    enum ListenOutcome: Equatable, Sendable {
        case listening(UInt16)
        /// The relaunched process is gone.
        case exited
        /// Still running, none of the ports open.
        case timedOut
    }

    /// Waits up to `seconds` until `pid` or one of its descendants listens on one of `ports`.
    static func waitForListener(root pid: Int32, ports: Set<UInt16>, upTo seconds: TimeInterval,
                                pollInterval: TimeInterval = 0.2) async -> ListenOutcome {
        let deadline = Date().addingTimeInterval(max(0, seconds))
        let rootStart = SysProc.basic(pid: pid)?.startTime
        var fdBuffer: [proc_fdinfo] = []
        while true {
            let table = ProcessTable(processes: SysProc.allProcesses())
            guard let root = table[pid], rootStart.map({ $0 == root.startTime }) ?? true, !isZombie(pid) else {
                return .exited
            }
            for process in [root] + table.descendants(of: pid) where process.uid == root.uid {
                if let socket = SysProc.listeningTCPSockets(pid: process.pid, fdBuffer: &fdBuffer)?
                    .first(where: { ports.contains($0.port) }) {
                    return .listening(socket.port)
                }
            }
            if Date() >= deadline { return .timedOut }
            try? await Task.sleep(nanoseconds: UInt64(max(0.01, pollInterval) * 1_000_000_000))
        }
    }

    /// launchd's row for `label` (`launchctl list`) about `settle` seconds from now: running with a pid, or not
    /// running with its last exit status. nil when the job isn't loaded or launchctl failed.
    static func launchdJob(_ label: String, after settle: TimeInterval) async -> LaunchctlListEntry? {
        if settle > 0 { try? await Task.sleep(nanoseconds: UInt64(settle * 1_000_000_000)) }
        return await OffMain.run {
            let result = Shell.run("/bin/launchctl", ["list"], timeout: 5)
            guard result.ok else { return nil }
            return LaunchdService.parseList(result.stdout).first { $0.label == label }
        }
    }

    /// p_stat == SZOMB (exited, waiting for its parent to reap it).
    private static func isZombie(_ pid: Int32) -> Bool {
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        let status = mib.withUnsafeMutableBufferPointer { name in
            sysctl(name.baseAddress, u_int(name.count), &info, &size, nil, 0)
        }
        guard status == 0, size >= MemoryLayout<kinfo_proc>.size, info.kp_proc.p_pid == pid else { return false }
        return Int32(info.kp_proc.p_stat) == SZOMB
    }
}

extension Relauncher {
    /// Relaunches `record` and checks that it really runs: the spawn must survive `Relauncher.defaultSettleTime` and,
    /// when the record had ports, the new process tree must listen on one of them within `portTimeout`.
    static func relaunchAndVerify(_ record: StoppedRecord, logDirectory: URL,
                                  portTimeout: TimeInterval) async -> RelaunchResult {
        let logPath = logFileURL(forTitle: record.title, in: logDirectory).path
        let spawned: Result<Int32, Error> = await OffMain.run {
            Result { try relaunch(record, logDirectory: logDirectory) }
        }
        let pid: Int32
        switch spawned {
        case .failure(let error):
            return RelaunchResult(record: record, state: .failed(error.localizedDescription), logPath: logPath)
        case .success(let spawnedPID):
            pid = spawnedPID
        }
        guard !record.ports.isEmpty else {
            return RelaunchResult(record: record, state: .running(pid: pid), logPath: logPath)
        }
        let state: RelaunchResult.State
        switch await ProcessWatch.waitForListener(root: pid, ports: Set(record.ports), upTo: portTimeout) {
        case .listening(let port): state = .listening(pid: pid, port: port)
        case .exited: state = .exited
        case .timedOut: state = .notListening(pid: pid)
        }
        return RelaunchResult(record: record, state: state, logPath: logPath)
    }
}
