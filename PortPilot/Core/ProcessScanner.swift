import Darwin
import Foundation

/// Raw result of one scan: the process table plus every listening TCP socket we could attribute.
struct RawScan {
    let table: ProcessTable
    /// pid → listening sockets (deduped by port+address+family).
    let socketsByPID: [Int32: [ListeningSocket]]
    /// Other-user listener pids discovered through netstat (no details available).
    let restrictedPIDs: Set<Int32>
}

/// Collects the process table and listening sockets, and keeps the per-process caches
/// (details, CPU samples) that make repeated scans cheap.
///
/// Designed to be driven from one background serial context, but every method is safe to call
/// from any thread: the descriptor scratch buffer and the caches are guarded by separate locks,
/// so `details(for:)` / `usage(for:)` never wait for a running scan.
final class ProcessScanner {
    /// Supplies every listening TCP socket on the system from the kernel PCB list
    /// (nil when unavailable). Injectable for tests.
    typealias SystemListenerProvider = () -> [ListeningSocket]?
    /// Supplies `netstat -anv -p tcp` output (nil on failure). Injectable for tests.
    typealias NetstatProvider = () -> String?

    private let systemListenerProvider: SystemListenerProvider
    private let netstatProvider: NetstatProvider
    private let currentUID: UInt32

    /// Guards `fdBuffer` (reused by every libproc descriptor listing).
    private let scanLock = NSLock()
    private var fdBuffer: [proc_fdinfo] = []

    /// Guards `detailsCache` and `cpuSamples`.
    private let cacheLock = NSLock()
    private var detailsCache: [ProcessIdentity: CachedDetails] = [:]
    private var cpuSamples: [ProcessIdentity: CPUSample] = [:]

    /// Samples closer together than this reuse the previous CPU% instead of producing a noisy
    /// value from a tiny interval.
    private static let minimumSampleIntervalNanos: UInt64 = 250_000_000

    private struct CachedDetails {
        /// p_comm when cached; a change means the process exec'd and the details are stale.
        let comm: String
        let details: ProcessDetails
    }

    private struct CPUSample {
        let cpuNanos: UInt64
        let timestampNanos: UInt64
        let percent: Double
    }

    init(systemListenerProvider: @escaping SystemListenerProvider = SysProc.systemTCPListeners,
         netstatProvider: @escaping NetstatProvider = ProcessScanner.runNetstat,
         currentUID: UInt32 = SysProc.currentUID) {
        self.systemListenerProvider = systemListenerProvider
        self.netstatProvider = netstatProvider
        self.currentUID = currentUID
    }

    // MARK: - Scanning

    func scan(includeOtherUsers: Bool) -> RawScan {
        let processes = SysProc.allProcesses()
        let table = ProcessTable(processes: processes)
        let isRoot = currentUID == 0

        var socketsByPID: [Int32: [ListeningSocket]] = [:]
        // Same-uid processes libproc refused (rare, e.g. exiting); the system-wide listener list
        // may still attribute sockets to them.
        var uninspectedPIDs = Set<Int32>()

        scanLock.lock()
        for process in processes where isRoot || process.uid == currentUID {
            guard let sockets = SysProc.listeningTCPSockets(pid: process.pid, fdBuffer: &fdBuffer) else {
                uninspectedPIDs.insert(process.pid)
                continue
            }
            if !sockets.isEmpty { socketsByPID[process.pid] = sockets }
        }
        scanLock.unlock()

        var restrictedPIDs = Set<Int32>()
        if includeOtherUsers, let systemListeners = otherUserListenerCandidates() {
            for socket in systemListeners {
                guard let owner = table[socket.pid] else { continue }   // exited since the table was read
                let wasInspected = (isRoot || owner.uid == currentUID) && !uninspectedPIDs.contains(owner.pid)
                guard !wasInspected else { continue }
                var list = socketsByPID[socket.pid] ?? []
                if !list.contains(socket) { list.append(socket) }
                socketsByPID[socket.pid] = list
                restrictedPIDs.insert(socket.pid)
            }
            for pid in restrictedPIDs {
                socketsByPID[pid]?.sort(by: SysProc.socketOrder)
            }
        }

        prune(keepingAliveIn: table)
        return RawScan(table: table, socketsByPID: socketsByPID, restrictedPIDs: restrictedPIDs)
    }

    // MARK: - Details

    /// Cached by ProcessIdentity; cache entries for dead identities are pruned on each scan.
    func details(for basic: ProcessBasic) -> ProcessDetails? {
        let identity = basic.identity
        let cached: CachedDetails? = cacheLock.withLock { detailsCache[identity] }
        if let cached, cached.comm == basic.comm { return cached.details }

        guard let fresh = SysProc.details(for: basic) else { return nil }
        // Empty argv for a process we are allowed to read means we caught it mid-exec or it is
        // shutting down; retry next time instead of caching a useless entry. Other users' processes
        // never expose argv, so their partial details are final.
        let isFinal = !fresh.arguments.isEmpty || (currentUID != 0 && basic.uid != currentUID)
        if isFinal {
            cacheLock.withLock { detailsCache[identity] = CachedDetails(comm: basic.comm, details: fresh) }
        }
        return fresh
    }

    // MARK: - Resource usage

    /// CPU% since the previous sample of the same identity (0 on first sample) + footprint.
    /// Processes that cannot be sampled (gone, other users) are absent from the result.
    func usage(for basics: [ProcessBasic]) -> [Int32: ResourceUsage] {
        struct Reading {
            let identity: ProcessIdentity
            let cpuNanos: UInt64
            let footprint: UInt64
            let timestamp: UInt64
        }

        // Syscalls happen outside the lock.
        var readings: [Reading] = []
        readings.reserveCapacity(basics.count)
        var seen = Set<Int32>()
        for basic in basics where seen.insert(basic.pid).inserted {
            guard let sample = SysProc.resourceSample(pid: basic.pid) else { continue }
            readings.append(Reading(identity: basic.identity, cpuNanos: sample.cpuNanos,
                                    footprint: sample.footprintBytes,
                                    timestamp: clock_gettime_nsec_np(CLOCK_MONOTONIC_RAW)))
        }

        var result: [Int32: ResourceUsage] = [:]
        result.reserveCapacity(readings.count)
        cacheLock.lock()
        defer { cacheLock.unlock() }
        for reading in readings {
            var percent = 0.0
            var newSample = CPUSample(cpuNanos: reading.cpuNanos, timestampNanos: reading.timestamp, percent: 0)
            if let previous = cpuSamples[reading.identity],
               reading.timestamp > previous.timestampNanos,
               reading.cpuNanos >= previous.cpuNanos {
                let wallDelta = reading.timestamp - previous.timestampNanos
                if wallDelta < Self.minimumSampleIntervalNanos {
                    percent = previous.percent
                    newSample = previous   // keep the older baseline so the next interval is long enough
                } else {
                    percent = Double(reading.cpuNanos - previous.cpuNanos) / Double(wallDelta) * 100
                    newSample = CPUSample(cpuNanos: reading.cpuNanos, timestampNanos: reading.timestamp,
                                          percent: percent)
                }
            }
            cpuSamples[reading.identity] = newSample
            result[reading.identity.pid] = ResourceUsage(cpuPercent: percent, memoryBytes: reading.footprint)
        }
        return result
    }

    // MARK: - Cache maintenance

    private func prune(keepingAliveIn table: ProcessTable) {
        cacheLock.lock()
        defer { cacheLock.unlock() }
        detailsCache = detailsCache.filter { table.isAlive($0.key) }
        cpuSamples = cpuSamples.filter { table.isAlive($0.key) }
    }

    // MARK: - Other users' listeners

    /// All listening sockets on the system, from the kernel PCB list or — when that is unavailable —
    /// from one `netstat -anv -p tcp` run. Only entries for processes libproc could not inspect
    /// are used by `scan`.
    private func otherUserListenerCandidates() -> [ListeningSocket]? {
        if let listeners = systemListenerProvider() { return listeners }
        return netstatProvider().map(Self.parseNetstatListeners)
    }

    /// Runs `/usr/sbin/netstat -anv -p tcp` with a 3 s timeout. Returns nil on failure or timeout.
    static func runNetstat() -> String? {
        runCapturingOutput("/usr/sbin/netstat", ["-anv", "-p", "tcp"], timeout: 3)
    }

    /// Runs an executable directly (no shell) and returns its stdout when it exits with status 0
    /// within `timeout`; otherwise terminates it (only this child) and returns nil.
    static func runCapturingOutput(_ executable: String, _ arguments: [String], timeout seconds: TimeInterval) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.environment = ["LC_ALL": "C", "PATH": "/usr/bin:/bin:/usr/sbin:/sbin"]
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            return nil
        }

        // Only ever signals the child started above.
        let timeout = DispatchWorkItem { [weak process] in
            if let process, process.isRunning { process.terminate() }
        }
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + seconds, execute: timeout)
        // Draining the pipe until EOF avoids a deadlock on large outputs; EOF also arrives when the
        // timeout terminates the child.
        let data = output.fileHandleForReading.readDataToEndOfFile()
        timeout.cancel()
        process.waitUntilExit()

        guard process.terminationReason == .exit, process.terminationStatus == 0 else { return nil }
        return String(decoding: data, as: UTF8.self)
    }

    /// Parses LISTEN rows of `netstat -anv -p tcp` into sockets.
    ///
    /// Row shape (columns are whitespace separated; the process name may itself contain spaces):
    ///
    ///     tcp4  0  0  127.0.0.1.8014  *.*  LISTEN  0  0  131072  131072  Code Helper (Plu:82075  00100 ...
    ///
    /// The local address ends in ".<port>"; the owner is the last field after the state column
    /// that ends in ":<digits>" (the trailing hex columns never contain ':').
    static func parseNetstatListeners(_ output: String) -> [ListeningSocket] {
        var sockets: [ListeningSocket] = []
        for line in output.split(separator: "\n", omittingEmptySubsequences: true) {
            let fields = line.split(whereSeparator: { $0 == " " || $0 == "\t" })
            guard fields.count > 6, fields[0].hasPrefix("tcp"), fields[5] == "LISTEN" else { continue }

            let family: IPFamily = fields[0] == "tcp4" ? .ipv4 : .ipv6   // tcp6 and dual-stack tcp46
            let local = fields[3]
            guard let dot = local.lastIndex(of: "."),
                  let port = UInt16(local[local.index(after: dot)...])
            else { continue }
            var address = String(local[..<dot])
            if address == "*" || address == "0.0.0.0" || address == "::" { address = "*" }

            guard let pid = fields[6...].reversed().lazy.compactMap(Self.trailingPID).first, pid > 0 else {
                continue
            }
            sockets.append(ListeningSocket(port: port, address: address, family: family, pid: pid))
        }
        return sockets
    }

    /// "name:1234" → 1234; nil when the field does not end in ':' followed by digits.
    private static func trailingPID(_ field: Substring) -> Int32? {
        guard let colon = field.lastIndex(of: ":") else { return nil }
        let digits = field[field.index(after: colon)...]
        guard !digits.isEmpty, digits.allSatisfy({ $0.isASCII && $0.isNumber }) else { return nil }
        return Int32(digits)
    }
}
