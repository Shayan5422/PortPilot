import Darwin
import XCTest
@testable import PortPilot

// ProcessKiller against real processes. Every process here is a `/bin/sleep` the test starts itself in its own
// session, and the test kills its whole process group before returning.

final class ProcessKillerTests: XCTestCase {

    /// Starts `/bin/sh -c <script>` as a session leader (pgid == pid), like a daemonized process manager. Its stdio
    /// is /dev/null and it inherits no other descriptors, so it never holds the test runner's output pipes.
    private func spawnSessionLeader(_ script: String) throws -> pid_t {
        var attributes: posix_spawnattr_t?
        guard posix_spawnattr_init(&attributes) == 0 else { throw XCTSkip("posix_spawnattr_init failed") }
        defer { posix_spawnattr_destroy(&attributes) }
        XCTAssertEqual(posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_SETSID | POSIX_SPAWN_CLOEXEC_DEFAULT)), 0)
        var fileActions: posix_spawn_file_actions_t?
        guard posix_spawn_file_actions_init(&fileActions) == 0 else { throw XCTSkip("posix_spawn_file_actions_init failed") }
        defer { posix_spawn_file_actions_destroy(&fileActions) }
        for descriptor in [STDIN_FILENO, STDOUT_FILENO, STDERR_FILENO] {
            XCTAssertEqual(posix_spawn_file_actions_addopen(&fileActions, descriptor, "/dev/null",
                                                            descriptor == STDIN_FILENO ? O_RDONLY : O_WRONLY, 0), 0)
        }
        let arguments: [String] = ["/bin/sh", "-c", script]
        let argv: [UnsafeMutablePointer<CChar>?] = arguments.map { strdup($0) } + [nil]
        defer { argv.forEach { free($0) } }
        var pid: pid_t = 0
        let status = posix_spawn(&pid, "/bin/sh", &fileActions, &attributes, argv, environ)
        guard status == 0, pid > 0 else { throw XCTSkip("posix_spawn failed: \(status)") }
        return pid
    }

    private func endGroup(_ pid: pid_t) {
        kill(-pid, SIGKILL)
        var status: Int32 = 0
        while waitpid(pid, &status, 0) == -1 && errno == EINTR {}
    }

    /// Finding #9: the PM2 God Daemon is the cluster primary, and pm2 daemonizes it, so it leads a process group
    /// that also holds the cluster workers. Even a plan that names it must neither signal it nor its group.
    func testKillerNeverSignalsAPM2DaemonOrItsProcessGroup() async throws {
        // The worker is a plain `sh -c` (not a protected process) that blocks opening a FIFO nobody writes to.
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("PortPilotTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let fifo = directory.appendingPathComponent("never-written").path
        XCTAssertEqual(mkfifo(fifo, 0o600), 0)

        let daemonPID = try spawnSessionLeader(
            "/bin/sh -c 'read line < \"\(fifo)\"; :' & "
                + "exec -a 'PM2 v5.4.3: God Daemon (/tmp/portpilot-tests)' /bin/sleep 30")
        defer { endGroup(daemonPID) }
        func groupMembers() -> [ProcessBasic] { SysProc.allProcesses().filter { $0.pgid == daemonPID } }   // no zombies

        var daemon: ProcessBasic?
        for _ in 0..<60 {
            if let basic = SysProc.basic(pid: daemonPID), PM2Service.isDaemon(basic, details: SysProc.details(for: basic)),
               groupMembers().count == 2 {
                daemon = basic
                break
            }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        let leader = try XCTUnwrap(daemon, "the stand-in daemon never took its title")
        XCTAssertEqual(leader.pgid, leader.pid)
        let worker = try XCTUnwrap(groupMembers().first { $0.pid != daemonPID })
        XCTAssertFalse(KillPlanner.isProtected(worker, details: SysProc.details(for: worker)),
                       "only the daemon itself may stop the group signal")

        let plan = KillPlan(root: leader, targets: [leader], summary: [], requiresAdmin: false, warnings: [])
        let result = await ProcessKiller().stop(plan, mode: .graceful, timeout: 0.5, allowAdmin: false)
        try await Task.sleep(nanoseconds: 200_000_000)

        XCTAssertEqual(result.stopped, [])
        XCTAssertEqual(result.failures.map(\.pid), [daemonPID])
        XCTAssertNotNil(SysProc.basic(pid: daemonPID), "the daemon is still running")
        XCTAssertEqual(groupMembers().map(\.pid).sorted(), [daemonPID, worker.pid].sorted(), "and so is its worker")
    }

    /// Apps and macOS services are stopped with `escalate: false`: a target that ignores SIGTERM is reported as
    /// still running and never gets SIGKILL (neither it nor its process group). The default still escalates.
    func testGracefulStopWithoutEscalationNeverSendsSIGKILL() async throws {
        // An ignored signal stays ignored across exec, so this `sleep` shrugs off SIGTERM.
        let pid = try spawnSessionLeader("trap '' TERM; exec /bin/sleep 30")
        defer { endGroup(pid) }
        var sleeper: ProcessBasic?
        for _ in 0..<60 {
            if let basic = SysProc.basic(pid: pid), basic.comm == "sleep" {
                sleeper = basic
                break
            }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        let target = try XCTUnwrap(sleeper, "the test process never exec'd into sleep")
        let plan = KillPlan(root: target, targets: [target], summary: [], requiresAdmin: false, warnings: [])

        let gentle = await ProcessKiller(killGracePeriod: 0.5)
            .stop(plan, mode: .graceful, timeout: 0.3, allowAdmin: false, escalate: false)
        XCTAssertFalse(gentle.escalated)
        XCTAssertEqual(gentle.stopped, [])
        XCTAssertEqual(gentle.failures, [StopFailure(pid: pid, reason: "Still running — use Force Kill")])
        XCTAssertEqual(SysProc.basic(pid: pid)?.startTime, target.startTime, "still the same, running process")

        let escalating = await ProcessKiller(killGracePeriod: 2)
            .stop(plan, mode: .graceful, timeout: 0.3, allowAdmin: false)
        XCTAssertTrue(escalating.escalated)
        XCTAssertEqual(escalating.stopped, [pid])
    }
}
