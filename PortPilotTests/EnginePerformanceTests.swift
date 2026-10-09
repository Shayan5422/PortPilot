import Darwin
import XCTest
@testable import PortPilot

/// Keeps the per-tick cost of the scan pipeline honest (SPEC: a scan must cost < 15 ms CPU on ~800 processes).
/// Prints "PERF" lines so before/after numbers can be read from the test log.
///
/// The synthetic benchmark always runs. The live-system ones read the real process table (and the real
/// file system through ProjectResolver, which may wait on privacy prompts in a test host), so they only run when
/// `PORTPILOT_PERF=1` is set (`TEST_RUNNER_PORTPILOT_PERF=1 xcodebuild test …`).
final class EnginePerformanceTests: XCTestCase {

    /// CPU time of the calling thread in nanoseconds.
    private static func threadCPUNanos() -> UInt64 {
        clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID)
    }

    private static func milliseconds(_ nanos: UInt64, per iterations: Int) -> Double {
        Double(nanos) / Double(iterations) / 1_000_000
    }

    private func requireLiveBenchmarks() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["PORTPILOT_PERF"] == "1",
                          "set PORTPILOT_PERF=1 to benchmark against the live system")
    }

    // MARK: Synthetic

    /// ~80 listeners in realistic trees: Terminal → login → -zsh → npm → sh -c → node (+ esbuild helper), launchd
    /// services and app helpers.
    private func syntheticScan() -> (raw: RawScan, details: [Int32: ProcessDetails], usage: [Int32: ResourceUsage],
                                     fs: ResolverTestFS) {
        let home = ResolverTestFS.home
        let node = "/opt/homebrew/bin/node"
        let fs = ResolverTestFS()
        var fixtures = [ClassifierFixture(pid: 1, ppid: 0, uid: 0, executable: "/sbin/launchd", arguments: ["/sbin/launchd"])]
        var sockets: [Int32: [ListeningSocket]] = [:]
        func add(_ fixture: ClassifierFixture, port: UInt16? = nil) {
            fixtures.append(fixture)
            if let port {
                sockets[fixture.basic.pid] = [ListeningSocket(port: port, address: "127.0.0.1", family: .ipv4,
                                                              pid: fixture.basic.pid)]
            }
        }
        add(ClassifierFixture(pid: 100, executable: "/System/Applications/Utilities/Terminal.app/Contents/MacOS/Terminal"))
        for index in 0..<60 {
            let base = Int32(1_000 + index * 10)
            let folder = home + "/code/app\(index)"
            fs.addDirectory(folder + "/.git")
            fs.addFile(folder + "/package.json", #"{"name": "app\#(index)"}"#)
            add(ClassifierFixture(pid: base, ppid: 100, uid: 0, executable: "/usr/bin/login", arguments: ["login", "-pf", "me"]))
            add(ClassifierFixture(pid: base + 1, ppid: base, executable: "/bin/zsh", arguments: ["-zsh"], cwd: folder))
            add(ClassifierFixture(pid: base + 2, ppid: base + 1, executable: node,
                                  arguments: ["node", "/opt/homebrew/lib/node_modules/npm/bin/npm-cli.js", "run", "dev"],
                                  environment: ["TERM_PROGRAM": "Apple_Terminal"], cwd: folder))
            add(ClassifierFixture(pid: base + 3, ppid: base + 2, executable: "/bin/sh", arguments: ["sh", "-c", "vite"],
                                  cwd: folder))
            add(ClassifierFixture(pid: base + 4, ppid: base + 3, executable: node,
                                  arguments: ["node", folder + "/node_modules/vite/bin/vite.js", "--port", "\(5000 + index)"],
                                  environment: ["TERM_PROGRAM": "Apple_Terminal"], cwd: folder), port: UInt16(5000 + index))
            add(ClassifierFixture(pid: base + 5, ppid: base + 4,
                                  executable: folder + "/node_modules/@esbuild/darwin-arm64/bin/esbuild",
                                  arguments: ["esbuild", "--service=0.21.5"], cwd: folder))
        }
        for index in 0..<10 {
            add(ClassifierFixture(pid: Int32(3_000 + index), executable: "/opt/homebrew/Cellar/redis/7.2/bin/redis-server",
                                  arguments: ["redis-server 127.0.0.1:\(6_000 + index)", ""], cwd: "/opt/homebrew/var"),
                port: UInt16(6_000 + index))
        }
        for index in 0..<10 {
            add(ClassifierFixture(pid: Int32(4_000 + index),
                                  executable: "/Applications/Visual Studio Code.app/Contents/Frameworks/Code Helper (Plugin).app/Contents/MacOS/Code Helper (Plugin)"),
                port: UInt16(7_000 + index))
        }
        let table = ProcessTable(processes: fixtures.map(\.basic))
        let details = fixtures.reduce(into: [Int32: ProcessDetails]()) { $0[$1.basic.pid] = $1.details }
        let usage = fixtures.reduce(into: [Int32: ResourceUsage]()) {
            $0[$1.basic.pid] = ResourceUsage(cpuPercent: 1, memoryBytes: 1_000_000)
        }
        return (RawScan(table: table, socketsByPID: sockets, restrictedPIDs: []), details, usage, fs)
    }

    func testListenerBuilderCostOnSyntheticSystem() {
        let scan = syntheticScan()
        let resolver = scan.fs.makeResolver()
        let traits = ProcessTraitsCache()
        let details = scan.details
        func build(_ cache: ProcessTraitsCache?) -> [ListenerGroup] {
            ListenerBuilder.build(raw: scan.raw, details: { details[$0.pid] }, usage: scan.usage, resolver: resolver,
                                  maps: ManagerMaps(), currentUID: ClassifierFixture.uid, traits: cache)
        }
        let first = build(traits)   // first tick: fills the memo
        XCTAssertEqual(first.count, 71, "60 projects, 10 services, 1 app")

        let iterations = 30
        var start = Self.threadCPUNanos()
        for _ in 0..<iterations { _ = build(traits) }
        let warm = Self.milliseconds(Self.threadCPUNanos() - start, per: iterations)
        start = Self.threadCPUNanos()
        for _ in 0..<iterations { _ = build(nil) }
        let cold = Self.milliseconds(Self.threadCPUNanos() - start, per: iterations)
        // The part of each build spent in ProjectResolver.resolve (warm caches), for reading the numbers above.
        let resolvable = scan.raw.socketsByPID.keys.compactMap { details[$0] }
        start = Self.threadCPUNanos()
        for _ in 0..<iterations { for info in resolvable { _ = resolver.resolve(details: info) } }
        let resolving = Self.milliseconds(Self.threadCPUNanos() - start, per: iterations)
        print(String(format: "PERF synthetic ListenerBuilder.build (80 listeners): %.3f ms CPU with the tick-to-tick memo, %.3f ms without (resolver at most %.3f ms of each)",
                     warm, cold, resolving))
        XCTAssertLessThan(warm, cold, "the memo must make later ticks cheaper")
        XCTAssertLessThan(warm, 15, "building the snapshot must stay well inside the scan budget")
    }

    // MARK: Live system

    func testListenerBuilderCostOnLiveSystem() throws {
        try requireLiveBenchmarks()
        let scanner = ProcessScanner()
        let resolver = ProjectResolver()
        let traits = ProcessTraitsCache()
        let raw = scanner.scan(includeOtherUsers: true)
        let details: (ProcessBasic) -> ProcessDetails? = { scanner.details(for: $0) }
        var basics: [ProcessBasic] = []
        for pid in raw.socketsByPID.keys {
            guard let basic = raw.table[pid] else { continue }
            basics.append(basic)
            if pid > 1, basic.uid == SysProc.currentUID { basics += raw.table.descendants(of: pid) }
        }
        let usage = scanner.usage(for: basics)
        func build(_ cache: ProcessTraitsCache?) -> [ListenerGroup] {
            ListenerBuilder.build(raw: raw, details: details, usage: usage, resolver: resolver, maps: ManagerMaps(),
                                  currentUID: SysProc.currentUID, traits: cache,
                                  sampleUsage: { scanner.usage(for: $0) })
        }
        _ = build(traits)   // warm the details / resolver caches and the memo like a running app has them

        let iterations = 30
        var start = Self.threadCPUNanos()
        var groups: [ListenerGroup] = []
        for _ in 0..<iterations { groups = build(traits) }
        let warm = Self.milliseconds(Self.threadCPUNanos() - start, per: iterations)
        start = Self.threadCPUNanos()
        for _ in 0..<iterations { _ = build(nil) }
        let cold = Self.milliseconds(Self.threadCPUNanos() - start, per: iterations)
        print(String(format: "PERF live ListenerBuilder.build: %.3f ms CPU per tick (memo), %.3f ms without memo (%d listeners, %d groups)",
                     warm, cold, raw.socketsByPID.count, groups.count))
        XCTAssertLessThan(warm, 15)

        var phase = Self.threadCPUNanos()
        for _ in 0..<iterations { _ = scanner.scan(includeOtherUsers: true) }
        print(String(format: "PERF live ProcessScanner.scan: %.3f ms CPU", Self.milliseconds(Self.threadCPUNanos() - phase, per: iterations)))
        phase = Self.threadCPUNanos()
        for _ in 0..<iterations { _ = scanner.usage(for: basics) }
        print(String(format: "PERF live usage(%d processes): %.3f ms CPU", basics.count,
                     Self.milliseconds(Self.threadCPUNanos() - phase, per: iterations)))
        phase = Self.threadCPUNanos()
        for _ in 0..<iterations {
            for listener in groups.flatMap(\.processes) where !listener.isRestricted {
                _ = KillPlanner.plan(for: listener, table: raw.table, details: details, currentUID: SysProc.currentUID,
                                     socketsByPID: raw.socketsByPID)
            }
        }
        print(String(format: "PERF live KillPlanner.plan (all listeners): %.3f ms CPU",
                     Self.milliseconds(Self.threadCPUNanos() - phase, per: iterations)))
    }

    func testFullScanCostOnLiveSystem() throws {
        try requireLiveBenchmarks()
        let engine = ScanEngine()
        _ = engine.scanBlocking(includeOtherUsers: true)   // warm caches (launchctl list, details, resolver, memo)
        let iterations = 10
        var cpu: UInt64 = 0
        var output: ScanOutput?
        for _ in 0..<iterations {
            let measured: (UInt64, ScanOutput) = engine.queue.sync {
                let start = Self.threadCPUNanos()
                let result = engine.scanSyncForTesting(includeOtherUsers: true)
                return (Self.threadCPUNanos() - start, result)
            }
            cpu += measured.0
            output = measured.1
        }
        let perScan = Self.milliseconds(cpu, per: iterations)
        print(String(format: "PERF live ScanEngine.scan (all users): %.3f ms CPU per scan (%d groups)",
                     perScan, output?.snapshot.groups.count ?? 0))
        XCTAssertLessThan(perScan, 40, "a scan must stay cheap (SPEC budget: 15 ms on ~800 processes, release build)")
    }
}
