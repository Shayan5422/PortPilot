import Darwin
import XCTest
@testable import PortPilot

final class SysProcTests: XCTestCase {

    // MARK: - Process table

    func testAllProcessesContainsSelfWithCorrectParent() throws {
        let processes = SysProc.allProcesses()
        XCTAssertGreaterThan(processes.count, 10)
        XCTAssertFalse(processes.contains { $0.pid == 0 }, "kernel_task (pid 0) must be skipped")

        let me = try XCTUnwrap(processes.first { $0.pid == getpid() })
        XCTAssertEqual(me.ppid, getppid())
        XCTAssertEqual(me.pgid, getpgrp())
        XCTAssertEqual(me.uid, geteuid())
        XCTAssertFalse(me.comm.isEmpty)
        XCTAssertLessThanOrEqual(me.comm.utf8.count, 16)
        XCTAssertLessThanOrEqual(me.startDate, Date())
        XCTAssertGreaterThan(me.startDate, Date(timeIntervalSinceNow: -86_400 * 30))
    }

    func testBasicMatchesProcessTableEntry() throws {
        let fromTable = try XCTUnwrap(SysProc.allProcesses().first { $0.pid == getpid() })
        let single = try XCTUnwrap(SysProc.basic(pid: getpid()))
        XCTAssertEqual(single, fromTable)
        XCTAssertNil(SysProc.basic(pid: Int32.max), "a pid that cannot exist must be reported as gone")
        XCTAssertNil(SysProc.basic(pid: 0))
    }

    func testCurrentUID() {
        XCTAssertEqual(SysProc.currentUID, geteuid())
    }

    // MARK: - Arguments, environment, cwd, path

    func testArgumentsAndEnvironmentOfSelf() throws {
        let result = try XCTUnwrap(SysProc.argumentsAndEnvironment(pid: getpid()))
        XCTAssertEqual(result.arguments, CommandLine.arguments)
        let path = try XCTUnwrap(result.environment["PATH"])
        XCTAssertFalse(path.isEmpty)
    }

    func testArgumentsOfOtherUsersProcessAreUnavailable() throws {
        try XCTSkipIf(geteuid() == 0, "running as root can read every process")
        XCTAssertNil(SysProc.argumentsAndEnvironment(pid: 1))
    }

    func testExecutablePathAndCurrentDirectoryOfSelf() throws {
        let path = try XCTUnwrap(SysProc.executablePath(pid: getpid()))
        let expected = try XCTUnwrap(Bundle.main.executablePath)
        XCTAssertEqual(resolved(path), resolved(expected))

        let cwd = try XCTUnwrap(SysProc.currentDirectory(pid: getpid()))
        XCTAssertEqual(resolved(cwd), resolved(FileManager.default.currentDirectoryPath))
    }

    func testDetailsOfSelf() throws {
        let me = try XCTUnwrap(SysProc.basic(pid: getpid()))
        let details = try XCTUnwrap(SysProc.details(for: me))
        XCTAssertEqual(details.identity, me.identity)
        XCTAssertEqual(details.arguments, CommandLine.arguments)
        XCTAssertNotNil(details.environment["PATH"])
        XCTAssertEqual(resolved(details.executablePath ?? ""), resolved(Bundle.main.executablePath ?? "-"))
        XCTAssertEqual(resolved(details.cwd ?? ""), resolved(FileManager.default.currentDirectoryPath))
    }

    func testDetailsRejectsRecycledIdentity() throws {
        let me = try XCTUnwrap(SysProc.basic(pid: getpid()))
        let stale = ProcessBasic(pid: me.pid, ppid: me.ppid, pgid: me.pgid, uid: me.uid,
                                 comm: me.comm, startTime: me.startTime &+ 1)
        XCTAssertNil(SysProc.details(for: stale), "details must never describe a different process on the same pid")
    }

    // MARK: - KERN_PROCARGS2 parsing

    func testParseProcArgsLayout() throws {
        let buffer = Self.procArgsBuffer(argc: 3,
                                         execPath: "/opt/homebrew/bin/node",
                                         padding: 5,
                                         arguments: ["node", "", "server.js"],
                                         environment: ["PATH=/usr/bin", "EQ=a=b", "PATH=/shadowed", "NOEQUALS"],
                                         trailer: ["executable_path=/opt/homebrew/bin/node", "ptr_munge="])
        let parsed = try XCTUnwrap(buffer.withUnsafeBytes { SysProc.parseProcArgs($0) })
        XCTAssertEqual(parsed.arguments, ["node", "", "server.js"])
        XCTAssertEqual(parsed.environment, ["PATH": "/usr/bin", "EQ": "a=b"])
    }

    func testParseProcArgsSurvivesTruncationAndGarbage() {
        let buffer = Self.procArgsBuffer(argc: 2, execPath: "/bin/x", padding: 3,
                                         arguments: ["x", "--flag"], environment: ["A=1", "B=2"], trailer: [])
        // Every truncation point must be handled without crashing or reading past the end.
        for length in 0...buffer.count {
            let prefix = Array(buffer.prefix(length))
            let parsed = prefix.withUnsafeBytes { SysProc.parseProcArgs($0) }
            if length < 4 { XCTAssertNil(parsed) }
            if let parsed {
                XCTAssertLessThanOrEqual(parsed.arguments.count, 2)
                XCTAssertTrue(parsed.environment.allSatisfy { ["A", "B"].contains($0.key) })
            }
        }

        for argc in [Int32.min, -1, 0, 1_000_000, Int32.max] {
            var garbage = buffer
            withUnsafeBytes(of: argc.littleEndian) { garbage.replaceSubrange(0..<4, with: $0) }
            _ = garbage.withUnsafeBytes { SysProc.parseProcArgs($0) }
        }
        var noise = [UInt8](repeating: 0, count: 512)
        for index in noise.indices { noise[index] = UInt8(truncatingIfNeeded: index &* 37 &+ 11) }
        _ = noise.withUnsafeBytes { SysProc.parseProcArgs($0) }
    }

    // MARK: - Listening sockets

    func testListeningTCPSocketsFindsOwnIPv4Socket() throws {
        let listener = try TestListener(family: AF_INET, address: "127.0.0.1")
        defer { listener.close() }

        let sockets = try XCTUnwrap(SysProc.listeningTCPSockets(pid: getpid()))
        XCTAssertTrue(sockets.contains(ListeningSocket(port: listener.port, address: "127.0.0.1",
                                                       family: .ipv4, pid: getpid())),
                      "expected 127.0.0.1:\(listener.port) in \(sockets)")
        let ours = try XCTUnwrap(sockets.first { $0.port == listener.port })
        XCTAssertTrue(ours.isLoopbackOnly)
    }

    func testListeningTCPSocketsFindsOwnIPv6Socket() throws {
        let listener: TestListener
        do {
            listener = try TestListener(family: AF_INET6, address: "::1")
        } catch {
            throw XCTSkip("IPv6 loopback unavailable: \(error)")
        }
        defer { listener.close() }

        let sockets = try XCTUnwrap(SysProc.listeningTCPSockets(pid: getpid()))
        XCTAssertTrue(sockets.contains(ListeningSocket(port: listener.port, address: "::1",
                                                       family: .ipv6, pid: getpid())),
                      "expected [::1]:\(listener.port) in \(sockets)")
    }

    /// Java NIO (Gradle, Spring, Netty, JetBrains) binds "127.0.0.1" through an AF_INET6 socket as ::ffff:127.0.0.1.
    /// The kernel turns that into a plain IPv4 PCB; it must be reported as loopback IPv4, not as exposed "::127.0.0.1".
    func testIPv4AddressOnIPv6SocketIsReportedAsIPv4() throws {
        let listener: TestListener
        do {
            listener = try TestListener(family: AF_INET6, address: "::ffff:127.0.0.1", v6Only: false)
        } catch {
            throw XCTSkip("v4-mapped bind unavailable: \(error)")
        }
        defer { listener.close() }

        let sockets = try XCTUnwrap(SysProc.listeningTCPSockets(pid: getpid()))
        let ours = try XCTUnwrap(sockets.first { $0.port == listener.port }, "\(sockets)")
        XCTAssertEqual(ours, ListeningSocket(port: listener.port, address: "127.0.0.1", family: .ipv4, pid: getpid()))
        XCTAssertTrue(ours.isLoopbackOnly)
        XCTAssertFalse(ours.isExposed)

        if let all = SysProc.systemTCPListeners() {
            XCTAssertTrue(all.contains(ours), "the kernel PCB list must agree with libproc: \(all.filter { $0.pid == getpid() })")
        }
    }

    func testDualStackWildcardSocketStaysIPv6() throws {
        let listener: TestListener
        do {
            listener = try TestListener(family: AF_INET6, address: "::", v6Only: false)
        } catch {
            throw XCTSkip("IPv6 unavailable: \(error)")
        }
        defer { listener.close() }
        let sockets = try XCTUnwrap(SysProc.listeningTCPSockets(pid: getpid()))
        XCTAssertTrue(sockets.contains(ListeningSocket(port: listener.port, address: "*", family: .ipv6, pid: getpid())),
                      "\(sockets)")
    }

    func testClosedSocketIsNoLongerReported() throws {
        let listener = try TestListener(family: AF_INET, address: "127.0.0.1")
        let port = listener.port
        listener.close()
        let sockets = try XCTUnwrap(SysProc.listeningTCPSockets(pid: getpid()))
        XCTAssertFalse(sockets.contains { $0.port == port })
    }

    func testListeningTCPSocketsOfOtherUsersProcessIsNil() throws {
        try XCTSkipIf(geteuid() == 0, "running as root can inspect every process")
        XCTAssertNil(SysProc.listeningTCPSockets(pid: 1))
        XCTAssertNil(SysProc.listeningTCPSockets(pid: Int32.max))
    }

    func testSystemTCPListenersIncludesOwnSocket() throws {
        let listener = try TestListener(family: AF_INET, address: "127.0.0.1")
        defer { listener.close() }
        guard let all = SysProc.systemTCPListeners() else {
            throw XCTSkip("kernel PCB list not readable from this test process")
        }
        XCTAssertTrue(all.contains(ListeningSocket(port: listener.port, address: "127.0.0.1",
                                                   family: .ipv4, pid: getpid())))
    }

    // MARK: - Kernel PCB list parsing

    func testParsePCBListDecodesListenerRecords() throws {
        var list = PCBListBuilder()
        list.append(port: 8080, family: AF_INET, ipv4: [127, 0, 0, 1], pid: 4242, state: 1)
        list.append(port: 443, family: AF_INET, ipv4: [10, 0, 0, 2], pid: 4243, state: 4)   // ESTABLISHED
        list.append(port: 5432, family: AF_INET6, ipv6: Array(repeating: 0, count: 15) + [1], pid: 77, state: 1)
        list.append(port: 3000, family: AF_INET6, ipv6: Array(repeating: 0, count: 16), pid: 78, state: 1)
        let bytes = list.finish()

        let sockets = try XCTUnwrap(bytes.withUnsafeBytes { SysProc.parsePCBList($0) })
        XCTAssertEqual(sockets, [
            ListeningSocket(port: 8080, address: "127.0.0.1", family: .ipv4, pid: 4242),
            ListeningSocket(port: 5432, address: "::1", family: .ipv6, pid: 77),
            ListeningSocket(port: 3000, address: "*", family: .ipv6, pid: 78),
        ])
    }

    func testParsePCBListUsesVersionFlagForIPv4OnIPv6Sockets() throws {
        let in4in6Loopback = Array(repeating: UInt8(0), count: 12) + [127, 0, 0, 1]
        var list = PCBListBuilder()
        // AF_INET6 socket bound to ::ffff:127.0.0.1: IPv4-only PCB (vflag 1), address stored as in4in6.
        list.append(port: 60237, family: AF_INET6, ipv6: in4in6Loopback, vflag: 0x1, pid: 16913, state: 1)
        // ::ffff:0.0.0.0 → IPv4 wildcard.
        list.append(port: 60238, family: AF_INET6, ipv6: Array(repeating: 0, count: 16), vflag: 0x1, pid: 16914, state: 1)
        // Dual-stack "::" (both flags) stays IPv6.
        list.append(port: 60239, family: AF_INET6, ipv6: Array(repeating: 0, count: 16), vflag: 0x3, pid: 16915, state: 1)
        // A real v4-mapped address on a dual-stack PCB still decodes as IPv4.
        list.append(port: 60240, family: AF_INET6, ipv6: Array(repeating: 0, count: 10) + [0xff, 0xff, 10, 0, 0, 7],
                    vflag: 0x3, pid: 16916, state: 1)
        let bytes = list.finish()

        let sockets = try XCTUnwrap(bytes.withUnsafeBytes { SysProc.parsePCBList($0) })
        XCTAssertEqual(sockets, [
            ListeningSocket(port: 60237, address: "127.0.0.1", family: .ipv4, pid: 16913),
            ListeningSocket(port: 60238, address: "*", family: .ipv4, pid: 16914),
            ListeningSocket(port: 60239, address: "*", family: .ipv6, pid: 16915),
            ListeningSocket(port: 60240, address: "10.0.0.7", family: .ipv4, pid: 16916),
        ])
        XCTAssertTrue(sockets[0].isLoopbackOnly)
    }

    // MARK: - Descriptor listing

    func testDescriptorListingUsesLastFillDuringAnFDStorm() throws {
        let entrySize = MemoryLayout<proc_fdinfo>.stride
        var buffer: [proc_fdinfo] = []
        var listCalls = 0
        var tableSize = 8
        // Every call fills the buffer completely with socket descriptors and the table keeps growing.
        let count = SysProc.listFileDescriptors(
            into: &buffer,
            list: { raw in
                listCalls += 1
                let entries = raw.bindMemory(to: proc_fdinfo.self)
                for index in entries.indices {
                    entries[index] = proc_fdinfo(proc_fd: Int32(index), proc_fdtype: UInt32(PROX_FDTYPE_SOCKET))
                }
                return Int32(entries.count * entrySize)
            },
            probe: {
                tableSize = tableSize * 3 + 100   // outgrows every regrow
                return tableSize * entrySize
            })
        let filled = try XCTUnwrap(count)
        XCTAssertEqual(listCalls, SysProc.maxDescriptorListAttempts)
        XCTAssertEqual(filled, buffer.count, "the last fill is used as is (truncated), never a freshly grown empty buffer")
        XCTAssertTrue(buffer.prefix(filled).allSatisfy { $0.proc_fdtype == UInt32(PROX_FDTYPE_SOCKET) },
                      "every reported entry must hold data written by the kernel")
        XCTAssertEqual(buffer[filled - 1].proc_fd, Int32(filled - 1))
    }

    func testDescriptorListingGrowsOnceAndReportsErrors() {
        let entrySize = MemoryLayout<proc_fdinfo>.stride
        var buffer = [proc_fdinfo](repeating: proc_fdinfo(), count: 4)
        var table = 10   // more descriptors than the buffer holds: one regrow, then complete
        let count = SysProc.listFileDescriptors(
            into: &buffer,
            list: { raw in
                let capacity = raw.count / entrySize
                return Int32(min(table, capacity) * entrySize)
            },
            probe: { (table + 20) * entrySize })
        XCTAssertEqual(count, 10)
        XCTAssertGreaterThan(buffer.count, 10)

        table = 0
        XCTAssertEqual(SysProc.listFileDescriptors(into: &buffer, list: { _ in 0 }, probe: { 0 }), 0, "no descriptors")
        XCTAssertNil(SysProc.listFileDescriptors(into: &buffer, list: { _ in errno = ESRCH; return 0 }, probe: { nil }),
                     "an error is 'cannot inspect', not 'no sockets'")
        var empty: [proc_fdinfo] = []
        XCTAssertNil(SysProc.listFileDescriptors(into: &empty, list: { _ in 0 }, probe: { nil }))
    }

    func testParsePCBListRejectsMalformedInput() {
        XCTAssertNil([UInt8]().withUnsafeBytes { SysProc.parsePCBList($0) })
        XCTAssertNil(PCBListBuilder().finish().withUnsafeBytes { SysProc.parsePCBList($0) },
                     "a list without PCBs is treated as unavailable")

        var list = PCBListBuilder()
        list.append(port: 1, family: AF_INET, ipv4: [127, 0, 0, 1], pid: 1, state: 1)
        let valid = list.finish()
        // Truncated anywhere: never crash; a cut inside a record is rejected.
        for length in 0..<valid.count {
            _ = Array(valid.prefix(length)).withUnsafeBytes { SysProc.parsePCBList($0) }
        }
        // Unknown record size (layout drift) must be rejected rather than misread.
        var drifted = valid
        drifted.replaceSubrange(24..<28, with: [100, 0, 0, 0])
        XCTAssertNil(drifted.withUnsafeBytes { SysProc.parsePCBList($0) })
    }

    // MARK: - Resource usage

    func testResourceSampleOfSelf() throws {
        let sample = try XCTUnwrap(SysProc.resourceSample(pid: getpid()))
        XCTAssertGreaterThan(sample.cpuNanos, 0)
        XCTAssertGreaterThan(sample.footprintBytes, 1_000_000)
        XCTAssertNil(SysProc.resourceSample(pid: Int32.max))
    }

    func testMachTicksConversionIsMonotonicAndOverflowSafe() {
        XCTAssertEqual(SysProc.machTicksToNanoseconds(0), 0)
        XCTAssertLessThan(SysProc.machTicksToNanoseconds(1_000), SysProc.machTicksToNanoseconds(2_000))
        _ = SysProc.machTicksToNanoseconds(UInt64.max)
    }

    // MARK: - netstat parsing

    func testParseNetstatListeners() {
        let output = """
        Active Internet connections (including servers)
        Proto Recv-Q Send-Q  Local Address          Foreign Address        (state)          rxbytes      txbytes  rhiwat  shiwat          process:pid    state  options           gencnt    flags   flags1 usecnt rtncnt fltrs
        tcp4       0      0  192.0.2.10.52082       203.0.113.7.443        ESTABLISHED        11162          713  131072  131600 com.avast.daemon:1050   00182 00000000 000000000082295c 20000081 04000900      3      0 000004
        tcp4       0      0  127.0.0.1.51790        *.*                    LISTEN                 0            0  131072  131072 Code Helper (Plu:82075  00100 00000106 000000000081822a 00000001 00000800      1      0 000000
        tcp4       0      0  *.57621                *.*                    LISTEN                 0            0  131072  131072          Spotify:17080  00100 00000002 00000000007a9ece 00000000 00000800      1      0 000000
        tcp4       0      0  127.0.0.1.8831         *.*                    LISTEN                 0            0  131072  131072 Antigravity IDE :86033  00100 00000106 000000000079a662 00000001 00000800      1      0 000000
        tcp6       0      0  ::1.6379               *.*                    LISTEN                 0            0  131072  131072     redis-server:972    00100 00000006 0000000000001bf0 00000000 00000800      1      0 000000
        tcp46      0      0  *.3091                 *.*                    LISTEN                 0            0  131072  131072             node:1392   00100 00000006 0000000000001bf1 00000000 00000800      1      0 000000
        tcp6       0      0  *.5900                 *.*                    LISTEN                 0            0  131072  131072          launchd:1      00180 00000006 0000000000000a41 00000000 00000800      1      0 000000
        tcp4       0      0  127.0.0.1.9999         *.*                    LISTEN                 0            0  131072  131072 00100 00000006 0000000000000a41 00000000 00000800      1      0 000000
        """
        XCTAssertEqual(ProcessScanner.parseNetstatListeners(output), [
            ListeningSocket(port: 51790, address: "127.0.0.1", family: .ipv4, pid: 82075),
            ListeningSocket(port: 57621, address: "*", family: .ipv4, pid: 17080),
            ListeningSocket(port: 8831, address: "127.0.0.1", family: .ipv4, pid: 86033),
            ListeningSocket(port: 6379, address: "::1", family: .ipv6, pid: 972),
            ListeningSocket(port: 3091, address: "*", family: .ipv6, pid: 1392),
            ListeningSocket(port: 5900, address: "*", family: .ipv6, pid: 1),
        ])
    }

    func testRunCapturingOutputReturnsStdoutAndEnforcesTimeout() {
        XCTAssertEqual(ProcessScanner.runCapturingOutput("/bin/echo", ["port", "pilot"], timeout: 3), "port pilot\n")
        XCTAssertNil(ProcessScanner.runCapturingOutput("/usr/bin/false", [], timeout: 3), "non-zero exit is a failure")
        XCTAssertNil(ProcessScanner.runCapturingOutput("/nonexistent/tool", [], timeout: 3))

        let start = Date()
        XCTAssertNil(ProcessScanner.runCapturingOutput("/bin/sleep", ["10"], timeout: 0.3))
        XCTAssertLessThan(Date().timeIntervalSince(start), 3, "the child must be terminated at the timeout")
    }

    // MARK: - ProcessScanner

    func testScannerFindsOwnListenerWithoutOtherUsers() throws {
        let listener = try TestListener(family: AF_INET, address: "127.0.0.1")
        defer { listener.close() }

        let scanner = ProcessScanner(systemListenerProvider: { XCTFail("must not run"); return nil },
                                     netstatProvider: { XCTFail("must not run"); return nil })
        let raw = scanner.scan(includeOtherUsers: false)
        XCTAssertNotNil(raw.table[getpid()])
        XCTAssertTrue(raw.restrictedPIDs.isEmpty)
        let mine = try XCTUnwrap(raw.socketsByPID[getpid()])
        XCTAssertTrue(mine.contains { $0.port == listener.port && $0.address == "127.0.0.1" })
        XCTAssertTrue(raw.socketsByPID.values.allSatisfy { !$0.isEmpty })
    }

    func testScannerAddsOnlyUninspectableOtherUserListeners() throws {
        try XCTSkipIf(geteuid() == 0, "running as root inspects every process")
        let listener = try TestListener(family: AF_INET, address: "127.0.0.1")
        defer { listener.close() }

        let fake = [
            ListeningSocket(port: 5900, address: "*", family: .ipv4, pid: 1),
            ListeningSocket(port: 5900, address: "*", family: .ipv4, pid: 1),          // duplicate
            ListeningSocket(port: listener.port, address: "127.0.0.1", family: .ipv4, pid: getpid()),
            ListeningSocket(port: 1, address: "*", family: .ipv4, pid: Int32.max),     // not in table
        ]
        let scanner = ProcessScanner(systemListenerProvider: { fake }, netstatProvider: { nil })
        let raw = scanner.scan(includeOtherUsers: true)
        XCTAssertEqual(raw.restrictedPIDs, [1])
        XCTAssertEqual(raw.socketsByPID[1], [ListeningSocket(port: 5900, address: "*", family: .ipv4, pid: 1)])
        XCTAssertNil(raw.socketsByPID[Int32.max])
        let mine = try XCTUnwrap(raw.socketsByPID[getpid()])
        XCTAssertEqual(mine.filter { $0.port == listener.port }.count, 1, "self was inspected via libproc; no duplicate")
    }

    func testScannerFallsBackToNetstatWhenKernelListIsUnavailable() throws {
        try XCTSkipIf(geteuid() == 0, "running as root inspects every process")
        let netstat = """
        tcp4       0      0  127.0.0.1.8021         *.*                    LISTEN                 0            0  131072  131072          launchd:1      00180 00000006 0000000000000a4e 00000000 00000800      1      0 000000
        """
        let scanner = ProcessScanner(systemListenerProvider: { nil }, netstatProvider: { netstat })
        let raw = scanner.scan(includeOtherUsers: true)
        XCTAssertEqual(raw.restrictedPIDs, [1])
        XCTAssertEqual(raw.socketsByPID[1]?.map(\.port), [8021])
    }

    func testScannerDetailsAreCachedPerIdentity() throws {
        let scanner = ProcessScanner()
        let raw = scanner.scan(includeOtherUsers: false)
        let me = try XCTUnwrap(raw.table[getpid()])
        let first = try XCTUnwrap(scanner.details(for: me))
        let second = try XCTUnwrap(scanner.details(for: me))
        XCTAssertEqual(first.identity, me.identity)
        XCTAssertEqual(first.arguments, second.arguments)
        XCTAssertEqual(first.cwd, second.cwd)

        let stale = ProcessBasic(pid: me.pid, ppid: me.ppid, pgid: me.pgid, uid: me.uid,
                                 comm: me.comm, startTime: me.startTime &+ 1)
        XCTAssertNil(scanner.details(for: stale))
    }

    func testScannerUsageIsZeroFirstThenMeasuresCPU() throws {
        let scanner = ProcessScanner()
        let me = try XCTUnwrap(SysProc.basic(pid: getpid()))

        let first = try XCTUnwrap(scanner.usage(for: [me])[me.pid])
        XCTAssertEqual(first.cpuPercent, 0)
        XCTAssertGreaterThan(first.memoryBytes, 0)

        // Burn CPU for ~400 ms so the next sample has a measurable delta.
        let deadline = Date().addingTimeInterval(0.4)
        var accumulator = 0.0
        while Date() < deadline { accumulator += sin(accumulator + 1) }
        XCTAssertFalse(accumulator.isNaN)

        let second = try XCTUnwrap(scanner.usage(for: [me])[me.pid])
        XCTAssertGreaterThan(second.cpuPercent, 5)
        XCTAssertLessThan(second.cpuPercent, 100 * Double(ProcessInfo.processInfo.activeProcessorCount) + 1)
        XCTAssertNil(scanner.usage(for: [ProcessBasic(pid: Int32.max, ppid: 1, pgid: 1, uid: 0,
                                                      comm: "gone", startTime: 1)])[Int32.max])
    }

    // MARK: - Helpers

    private func resolved(_ path: String) -> String {
        URL(fileURLWithPath: path).resolvingSymlinksInPath().standardizedFileURL.path
    }

    /// Builds a KERN_PROCARGS2-shaped buffer.
    private static func procArgsBuffer(argc: Int32, execPath: String, padding: Int, arguments: [String],
                                       environment: [String], trailer: [String]) -> [UInt8] {
        var bytes: [UInt8] = []
        withUnsafeBytes(of: argc.littleEndian) { bytes.append(contentsOf: $0) }
        bytes.append(contentsOf: Array(execPath.utf8) + [0])
        bytes.append(contentsOf: [UInt8](repeating: 0, count: padding))
        for string in arguments + environment { bytes.append(contentsOf: Array(string.utf8) + [0]) }
        bytes.append(0)   // empty string ends the environment
        for string in trailer { bytes.append(contentsOf: Array(string.utf8) + [0]) }
        return bytes
    }
}

/// A TCP socket listening on an ephemeral loopback port, opened with plain Darwin APIs.
private final class TestListener {
    struct SocketError: Error, CustomStringConvertible {
        let call: String
        let code: Int32
        var description: String { "\(call) failed: \(String(cString: strerror(code)))" }
    }

    let port: UInt16
    private var fd: Int32

    /// - Parameter v6Only: sets IPV6_V6ONLY on an AF_INET6 socket before binding (nil keeps the system default).
    init(family: Int32, address: String, v6Only: Bool? = nil) throws {
        let fd = socket(family, SOCK_STREAM, IPPROTO_TCP)
        guard fd >= 0 else { throw SocketError(call: "socket", code: errno) }
        do {
            if family == AF_INET6, let v6Only {
                var flag: Int32 = v6Only ? 1 : 0
                guard setsockopt(fd, IPPROTO_IPV6, IPV6_V6ONLY, &flag, socklen_t(MemoryLayout<Int32>.size)) == 0 else {
                    throw SocketError(call: "setsockopt", code: errno)
                }
            }
            port = try Self.bindAndListen(fd: fd, family: family, address: address)
        } catch {
            Darwin.close(fd)
            throw error
        }
        self.fd = fd
    }

    deinit { close() }

    func close() {
        if fd >= 0 {
            Darwin.close(fd)
            fd = -1
        }
    }

    private static func bindAndListen(fd: Int32, family: Int32, address: String) throws -> UInt16 {
        if family == AF_INET6 {
            var addr = sockaddr_in6()
            addr.sin6_len = UInt8(MemoryLayout<sockaddr_in6>.size)
            addr.sin6_family = sa_family_t(AF_INET6)
            addr.sin6_port = 0
            guard inet_pton(AF_INET6, address, &addr.sin6_addr) == 1 else { throw SocketError(call: "inet_pton", code: EINVAL) }
            try withSockaddr(&addr) { try bindListen(fd: fd, $0, $1) }
            var bound = sockaddr_in6()
            try withSockaddr(&bound) { try getName(fd: fd, $0, $1) }
            return UInt16(bigEndian: bound.sin6_port)
        } else {
            var addr = sockaddr_in()
            addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
            addr.sin_family = sa_family_t(AF_INET)
            addr.sin_port = 0
            guard inet_pton(AF_INET, address, &addr.sin_addr) == 1 else { throw SocketError(call: "inet_pton", code: EINVAL) }
            try withSockaddr(&addr) { try bindListen(fd: fd, $0, $1) }
            var bound = sockaddr_in()
            try withSockaddr(&bound) { try getName(fd: fd, $0, $1) }
            return UInt16(bigEndian: bound.sin_port)
        }
    }

    private static func withSockaddr<T>(_ value: inout T,
                                        _ body: (UnsafeMutablePointer<sockaddr>, socklen_t) throws -> Void) throws {
        try withUnsafeMutablePointer(to: &value) { pointer in
            try pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                try body($0, socklen_t(MemoryLayout<T>.size))
            }
        }
    }

    private static func bindListen(fd: Int32, _ address: UnsafeMutablePointer<sockaddr>, _ length: socklen_t) throws {
        guard bind(fd, address, length) == 0 else { throw SocketError(call: "bind", code: errno) }
        guard listen(fd, 8) == 0 else { throw SocketError(call: "listen", code: errno) }
    }

    private static func getName(fd: Int32, _ address: UnsafeMutablePointer<sockaddr>, _ length: socklen_t) throws {
        var length = length
        guard getsockname(fd, address, &length) == 0 else { throw SocketError(call: "getsockname", code: errno) }
    }
}

/// Builds a synthetic `net.inet.tcp.pcblist_n` buffer with the xnu record layout.
private struct PCBListBuilder {
    private var bytes: [UInt8] = []

    init() {
        bytes = Self.generationHeader(count: 0)
    }

    /// - Parameter vflag: inp_vflag (INP_IPV4 0x1, INP_IPV6 0x2); defaults to the family's usual value.
    mutating func append(port: UInt16, family: Int32, ipv4: [UInt8] = [], ipv6: [UInt8] = [], vflag: UInt8? = nil,
                         pid: Int32, state: Int32) {
        var inpcb = Self.record(kind: 0x10, length: 104)
        Self.write(port.bigEndian, at: 18, in: &inpcb)
        inpcb[44] = vflag ?? (family == AF_INET6 ? 0x2 : 0x1)
        if family == AF_INET6 {
            inpcb.replaceSubrange(64..<80, with: ipv6)
        } else {
            inpcb.replaceSubrange(76..<80, with: ipv4)
        }
        var socket = Self.record(kind: 0x1, length: 104)
        Self.write(family, at: 40, in: &socket)
        Self.write(UInt32(501), at: 64, in: &socket)
        Self.write(pid, at: 68, in: &socket)
        let receiveBuffer = Self.record(kind: 0x2, length: 32)
        let sendBuffer = Self.record(kind: 0x4, length: 32)
        let stats = Self.record(kind: 0x8, length: 44)          // not a multiple of 8: exercises rounding
        var tcpcb = Self.record(kind: 0x20, length: 40)
        Self.write(state, at: 36, in: &tcpcb)

        for record in [inpcb, socket, receiveBuffer, sendBuffer, stats, tcpcb] {
            bytes.append(contentsOf: record)
            bytes.append(contentsOf: [UInt8](repeating: 0, count: (8 - record.count % 8) % 8))
        }
    }

    func finish() -> [UInt8] {
        bytes + Self.generationHeader(count: 0)
    }

    private static func generationHeader(count: UInt32) -> [UInt8] {
        var header = [UInt8](repeating: 0, count: 24)
        write(UInt32(24), at: 0, in: &header)
        write(count, at: 4, in: &header)
        return header
    }

    private static func record(kind: UInt32, length: Int) -> [UInt8] {
        var record = [UInt8](repeating: 0, count: length)
        write(UInt32(length), at: 0, in: &record)
        write(kind, at: 4, in: &record)
        return record
    }

    private static func write<T: FixedWidthInteger>(_ value: T, at offset: Int, in bytes: inout [UInt8]) {
        withUnsafeBytes(of: value) { bytes.replaceSubrange(offset..<(offset + MemoryLayout<T>.size), with: $0) }
    }
}
