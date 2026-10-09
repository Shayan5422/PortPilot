import Darwin
import Foundation

/// Executes a `KillPlan`: SIGTERM → wait → SIGKILL, with PID-reuse protection.
///
/// Every signal is preceded by an identity check (`SysProc.basic(pid:)?.startTime == identity.startTime`) so a
/// recycled PID that now belongs to an unrelated process is never signalled. Negative PIDs (process groups) are
/// only used for the plan root's own job group after re-validating every member of that group.
final class ProcessKiller: Sendable {
    private let pollInterval: Duration
    private let killGracePeriod: TimeInterval
    private let ownPID: Int32

    /// - Parameters:
    ///   - pollInterval: how often liveness is re-checked while waiting (SPEC: 100 ms).
    ///   - killGracePeriod: how long to wait for survivors after SIGKILL (SPEC: 2 s).
    init(pollInterval: TimeInterval = 0.1, killGracePeriod: TimeInterval = 2, ownPID: Int32 = getpid()) {
        self.pollInterval = .milliseconds(max(10, Int((pollInterval * 1000).rounded())))
        self.killGracePeriod = max(0, killGracePeriod)
        self.ownPID = ownPID
    }

    /// Stops every target of `plan` (children first). Runs off the caller's actor.
    ///
    /// - graceful: SIGTERM to each target (+ SIGCONT if it was suspended), plus the root's process group when the
    ///   root leads its own job group and that group holds nothing protected; poll every 100 ms up to `timeout`;
    ///   SIGKILL survivors; poll up to 2 s more.
    /// - force: SIGKILL immediately, then poll up to 2 s.
    /// - EPERM: when `plan.requiresAdmin` and `allowAdmin`, the denied targets are signalled through
    ///   `Shell.runAsAdmin` with a start-time guard (the admin prompt can take a while; the PID must not be reused
    ///   by then). Otherwise they are reported as failures.
    ///
    /// With `escalate` false, a graceful stop never sends SIGKILL: targets still running after `timeout` are
    /// reported as failures ("Still running — use Force Kill"). Used for apps and macOS services, which should
    /// only be killed when the user explicitly picks Force Kill.
    ///
    /// `StopResult.stopped` lists every target confirmed gone (including ones that had already exited);
    /// `escalated` is true whenever SIGKILL was actually sent (graceful escalation, or `.force`).
    func stop(_ plan: KillPlan, mode: StopMode, timeout: TimeInterval, allowAdmin: Bool,
              escalate: Bool = true) async -> StopResult {
        await Task.detached(priority: .userInitiated) { [self] in
            await self.execute(plan, mode: mode, timeout: timeout, allowAdmin: allowAdmin, escalate: escalate)
        }.value
    }

    // MARK: - Orchestration

    private func execute(_ plan: KillPlan, mode: StopMode, timeout: TimeInterval, allowAdmin: Bool,
                         escalate: Bool) async -> StopResult {
        var seenPIDs = Set<Int32>()
        let requested = plan.targets.filter { seenPIDs.insert($0.pid).inserted }
        var failures: [Int32: String] = [:]
        // Last line of defence: the planner never targets the PM2 daemon or a Docker backend, and neither does the
        // killer, whoever built the plan. They are left out of `plannedIdentities` too, so the process-group signal
        // below refuses a group they belong to (pm2 cluster workers share the daemon's group).
        let targets = requested.filter { target in
            guard KillPlanner.isManagerDaemon(target, details: SysProc.details(for: target)) else { return true }
            failures[target.pid] = "Runs other apps (PM2 daemon or Docker) — not signalled"
            return false
        }
        let plannedIdentities = Set(targets.map(\.identity))
        let firstSignal = mode == .graceful ? SIGTERM : SIGKILL

        var exited = Set<Int32>()
        var waiting: [ProcessBasic] = []
        var denied: [ProcessBasic] = []
        var escalated = false

        for target in targets {
            switch deliver(firstSignal, to: target) {
            case .delivered: waiting.append(target)
            case .alreadyGone: exited.insert(target.pid)
            case .permissionDenied: denied.append(target)
            case .refused(let reason): failures[target.pid] = reason
            case .failed(let code): failures[target.pid] = "Couldn't signal: \(Self.describe(errno: code))"
            }
        }
        let groupSignalled = signalProcessGroupIfSafe(plan.root, signal: firstSignal, planned: plannedIdentities)
        if mode == .force && (!waiting.isEmpty || groupSignalled) { escalated = true }

        // Targets owned by another user.
        var adminTargets: [ProcessBasic] = []
        if !denied.isEmpty {
            if plan.requiresAdmin && allowAdmin {
                if let error = await adminSignal(firstSignal, to: denied) {
                    denied.forEach { failures[$0.pid] = error }
                } else {
                    adminTargets = denied
                    waiting.append(contentsOf: denied)
                    if mode == .force { escalated = true }
                }
            } else {
                let reason = plan.requiresAdmin ? "Owned by another user — administrator rights required"
                                                : "Permission denied"
                denied.forEach { failures[$0.pid] = reason }
            }
        }

        if mode == .graceful {
            let boundedTimeout = min(max(timeout, 0), 120)
            let afterTerm = await waitForExit(waiting, upTo: boundedTimeout)
            exited.formUnion(afterTerm.exited)
            waiting = afterTerm.remaining

            let groupLeftovers = groupSignalled && processGroupHasMembers(plan.root)
            if !escalate {
                for survivor in waiting where failures[survivor.pid] == nil {
                    failures[survivor.pid] = "Still running — use Force Kill"
                }
                waiting = []
            } else if !waiting.isEmpty || groupLeftovers {
                escalated = true
                let adminPIDs = Set(adminTargets.map(\.pid))
                var adminSurvivors: [ProcessBasic] = []
                for survivor in waiting {
                    if adminPIDs.contains(survivor.pid) { adminSurvivors.append(survivor); continue }
                    switch deliver(SIGKILL, to: survivor) {
                    case .alreadyGone: exited.insert(survivor.pid)
                    case .delivered, .permissionDenied, .refused, .failed: break   // judged by the final poll
                    }
                }
                if groupSignalled {
                    _ = signalProcessGroupIfSafe(plan.root, signal: SIGKILL, planned: plannedIdentities)
                }
                if !adminSurvivors.isEmpty, let error = await adminSignal(SIGKILL, to: adminSurvivors) {
                    adminSurvivors.forEach { failures[$0.pid] = error }
                }
            }
        }

        let final = await waitForExit(waiting, upTo: killGracePeriod)
        exited.formUnion(final.exited)
        for survivor in final.remaining where failures[survivor.pid] == nil {
            failures[survivor.pid] = "Still running after SIGKILL"
        }

        let stopped = requested.map(\.pid).filter { exited.contains($0) }
        let failureList = requested.compactMap { target in
            failures[target.pid].map { StopFailure(pid: target.pid, reason: $0) }
        }
        return StopResult(requested: requested.map(\.identity), stopped: stopped, failures: failureList,
                          escalated: escalated)
    }

    // MARK: - Signalling

    private enum Delivery {
        case delivered, alreadyGone, permissionDenied
        case refused(String)
        case failed(Int32)
    }

    /// Re-verifies the target's identity, then signals it.
    private func deliver(_ signal: Int32, to target: ProcessBasic) -> Delivery {
        guard target.pid > 1, target.pid != ownPID else { return .refused("Protected process — not signalled") }
        guard let current = SysProc.basic(pid: target.pid), current.startTime == target.startTime else {
            return .alreadyGone   // exited, or the PID now belongs to a different process
        }
        if Self.runState(of: target.pid) == .zombie { return .alreadyGone }
        guard kill(target.pid, signal) == 0 else {
            let code = errno
            switch code {
            case ESRCH: return .alreadyGone
            case EPERM: return .permissionDenied
            default: return .failed(code)
            }
        }
        // A suspended process (Ctrl-Z, SIGSTOP) only acts on SIGTERM once continued.
        if signal == SIGTERM, Self.runState(of: target.pid) == .stopped { _ = kill(target.pid, SIGCONT) }
        return .delivered
    }

    /// Signals the plan root's process group when that is provably safe:
    /// the root is pid > 1, leads its own group (pgid == pid), is still the same process (or gone entirely — a
    /// group id cannot be reused while the group exists), PortPilot is not in that group, and every live member is
    /// same-user, not younger-than-possible, and either a planned target or not protected.
    @discardableResult
    private func signalProcessGroupIfSafe(_ root: ProcessBasic, signal: Int32, planned: Set<ProcessIdentity>) -> Bool {
        guard root.pid > 1, root.pid != ownPID, root.pgid == root.pid, getpgrp() != root.pid else { return false }
        if let leader = SysProc.basic(pid: root.pid) {
            guard leader.startTime == root.startTime, leader.pgid == root.pid else { return false }
        }
        let members = SysProc.allProcesses().filter { $0.pgid == root.pid }
        guard !members.isEmpty else { return false }
        for member in members {
            guard member.pid > 1, member.pid != ownPID, member.uid == root.uid,
                  member.startTime >= root.startTime else { return false }
            if planned.contains(member.identity) { continue }
            if KillPlanner.isProtected(member, details: SysProc.details(for: member)) { return false }
        }
        let groupTarget = -root.pid
        guard groupTarget < -1 else { return false }   // never kill(-1, …) / kill(0, …)
        return kill(groupTarget, signal) == 0
    }

    /// True when processes (other than zombies) are still in the root's job group.
    private func processGroupHasMembers(_ root: ProcessBasic) -> Bool {
        guard root.pid > 1 else { return false }
        return SysProc.allProcesses().contains { $0.pgid == root.pid && Self.runState(of: $0.pid) != .zombie }
    }

    // MARK: - Waiting

    private func waitForExit(_ processes: [ProcessBasic], upTo seconds: TimeInterval) async
        -> (remaining: [ProcessBasic], exited: Set<Int32>) {
        var remaining = processes
        var exited = Set<Int32>()
        let clock = ContinuousClock()
        let deadline = clock.now + .milliseconds(Int((max(0, seconds) * 1000).rounded()))
        // Signals land within a few ms: check again quickly once, then settle into the regular poll interval.
        var interval = min(pollInterval, .milliseconds(20))
        while true {
            remaining.removeAll { process in
                guard Self.hasExited(process) else { return false }
                exited.insert(process.pid)
                return true
            }
            if remaining.isEmpty || clock.now >= deadline { return (remaining, exited) }
            try? await Task.sleep(for: interval)
            interval = pollInterval
        }
    }

    /// Gone, recycled, or a zombie waiting to be reaped by its parent.
    private static func hasExited(_ process: ProcessBasic) -> Bool {
        guard let current = SysProc.basic(pid: process.pid), current.startTime == process.startTime else { return true }
        return runState(of: process.pid) == .zombie
    }

    private enum RunState { case running, stopped, zombie, gone }

    /// p_stat from `sysctl(KERN_PROC_PID)`.
    private static func runState(of pid: Int32) -> RunState {
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        let status = mib.withUnsafeMutableBufferPointer { name in
            sysctl(name.baseAddress, u_int(name.count), &info, &size, nil, 0)
        }
        guard status == 0, size >= MemoryLayout<kinfo_proc>.size, info.kp_proc.p_pid == pid else { return .gone }
        switch Int32(info.kp_proc.p_stat) {
        case SZOMB: return .zombie
        case SSTOP: return .stopped
        default: return .running
        }
    }

    // MARK: - Administrator path

    /// Signals other-user processes through an admin prompt. Returns an error message, or nil on success.
    private func adminSignal(_ signal: Int32, to targets: [ProcessBasic]) async -> String? {
        guard let command = Self.adminKillCommand(signalName: signal == SIGKILL ? "KILL" : "TERM", targets: targets) else {
            return "Couldn't verify the process identity for an administrator kill"
        }
        let outcome: (status: Int32, stderr: String) = await withCheckedContinuation { continuation in
            // The password dialog can stay up for a long time: keep it off the cooperative thread pool.
            DispatchQueue.global(qos: .userInitiated).async {
                let result = Shell.runAsAdmin(command)
                continuation.resume(returning: (result.status, result.stderr))
            }
        }
        if outcome.status == 0 { return nil }
        if outcome.stderr.contains("-128") { return "Administrator authorization was cancelled" }
        let detail = outcome.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
        return detail.isEmpty ? "Administrator kill failed (status \(outcome.status))" : "Administrator kill failed: \(detail)"
    }

    /// `/bin/sh` command that signals each pid only if its start time (as printed by `ps -o lstart=`, 1 s
    /// resolution) still matches the identity we planned for. nil when no target can be guarded.
    static func adminKillCommand(signalName: String, targets: [ProcessBasic]) -> String? {
        let guarded = targets.compactMap { target -> String? in
            guard target.pid > 1, let started = psStartString(forMicroseconds: target.startTime) else { return nil }
            // `echo $(…)` collapses ps' padding to single spaces, matching `started`.
            return "[ \"$(echo $(LC_ALL=C /bin/ps -o lstart= -p \(target.pid)))\" = '\(started)' ] && /bin/kill -\(signalName) \(target.pid)"
        }
        guard !guarded.isEmpty else { return nil }
        return (guarded + ["exit 0"]).joined(separator: "; ")
    }

    /// Formats a start time like `ps -o lstart=` in the C locale ("Fri Oct 9 15:36:58 2026", single-spaced).
    static func psStartString(forMicroseconds startTime: UInt64) -> String? {
        var seconds = time_t(startTime / 1_000_000)
        var parts = tm()
        guard startTime > 0, localtime_r(&seconds, &parts) != nil else { return nil }
        let weekdays = ["Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"]
        let months = ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"]
        guard weekdays.indices.contains(Int(parts.tm_wday)), months.indices.contains(Int(parts.tm_mon)) else { return nil }
        let time = String(format: "%02d:%02d:%02d", parts.tm_hour, parts.tm_min, parts.tm_sec)
        return "\(weekdays[Int(parts.tm_wday)]) \(months[Int(parts.tm_mon)]) \(parts.tm_mday) \(time) \(parts.tm_year + 1900)"
    }

    private static func describe(errno code: Int32) -> String {
        String(cString: strerror(code))
    }
}
