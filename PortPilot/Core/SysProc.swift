import Darwin
import Foundation

/// Thin, memory-safe wrappers over the libproc / sysctl APIs PortPilot needs.
///
/// Every function is a pure query (no signals, no writes) and returns `nil` instead of
/// crashing when a process is gone, not inspectable, or the kernel hands back something
/// unexpected. All buffers are bounds-checked; nothing here force-unwraps a syscall result.
enum SysProc {

    // MARK: - Process table

    /// All processes via sysctl(CTL_KERN, KERN_PROC, KERN_PROC_ALL). Retries on ENOMEM with a bigger buffer.
    ///
    /// Skips pid 0 (kernel_task) and zombies: a zombie owns no resources, cannot be signalled
    /// and disappears once its parent reaps it, so for every caller it is already "gone".
    static func allProcesses() -> [ProcessBasic] {
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_ALL, 0]
        let stride = MemoryLayout<kinfo_proc>.stride

        for attempt in 0..<maxProcessTableAttempts {
            var probedSize = 0
            guard sysctl(&mib, u_int(mib.count), nil, &probedSize, nil, 0) == 0, probedSize > 0 else {
                return []
            }
            // Headroom for processes spawned between the size probe and the read; grows per retry.
            let probedCount = probedSize / stride
            let capacity = probedCount + probedCount / 8 + 64 * (attempt + 1)
            let buffer = UnsafeMutableBufferPointer<kinfo_proc>.allocate(capacity: capacity)
            defer { buffer.deallocate() }

            var byteCount = capacity * stride
            if sysctl(&mib, u_int(mib.count), buffer.baseAddress, &byteCount, nil, 0) != 0 {
                if errno == ENOMEM { continue }
                return []
            }

            // The kernel initialised exactly `byteCount` bytes; never read past them.
            let count = min(byteCount / stride, capacity)
            var result: [ProcessBasic] = []
            result.reserveCapacity(count)
            for index in 0..<count {
                if let basic = makeBasic(buffer[index]) {
                    result.append(basic)
                }
            }
            return result
        }
        return []
    }

    /// Single process via sysctl(KERN_PROC_PID); nil if gone (or a zombie).
    static func basic(pid: Int32) -> ProcessBasic? {
        guard pid > 0 else { return nil }
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        // A non-existent pid is not an error for this sysctl: it succeeds with size == 0.
        guard sysctl(&mib, u_int(mib.count), &info, &size, nil, 0) == 0,
              size >= MemoryLayout<kinfo_proc>.size,
              info.kp_proc.p_pid == pid
        else { return nil }
        return makeBasic(info)
    }

    static var currentUID: UInt32 { geteuid() }

    // MARK: - Per-process details

    /// proc_pidpath.
    static func executablePath(pid: Int32) -> String? {
        var buffer = [UInt8](repeating: 0, count: pidPathBufferSize)
        let length = buffer.withUnsafeMutableBytes { raw in
            proc_pidpath(pid, raw.baseAddress, UInt32(raw.count))
        }
        guard length > 0 else { return nil }
        let path = buffer.withUnsafeBytes { raw in
            decodeCString(UnsafeRawBufferPointer(rebasing: raw.prefix(Int(length))))
        }
        return path.isEmpty ? nil : path
    }

    /// KERN_PROCARGS2 parse → (argv, env). nil when not permitted / gone. Handles the exec-path + NUL padding layout.
    static func argumentsAndEnvironment(pid: Int32) -> (arguments: [String], environment: [String: String])? {
        guard pid > 0 else { return nil }
        var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
        let capacity = argumentBufferSize
        let buffer = UnsafeMutableRawBufferPointer.allocate(byteCount: capacity, alignment: MemoryLayout<Int32>.alignment)
        defer { buffer.deallocate() }

        var size = capacity
        guard sysctl(&mib, u_int(mib.count), buffer.baseAddress, &size, nil, 0) == 0 else { return nil }
        // Only the first `size` bytes were written by the kernel.
        let written = UnsafeRawBufferPointer(rebasing: buffer[0..<min(size, capacity)])
        return parseProcArgs(written)
    }

    /// Parses a KERN_PROCARGS2 buffer. Layout:
    ///
    ///     int32 argc | exec_path\0 | \0 padding... | argv[0]\0 ... argv[argc-1]\0 | env[0]\0 ... \0 | apple strings...
    ///
    /// The environment ends at the first empty string. Every read is bounds-checked, so truncated
    /// or garbage buffers produce a partial result instead of a crash. Strings that are not
    /// NUL-terminated within the buffer (truncated) are dropped. Returns nil if the buffer cannot
    /// even hold `argc`.
    static func parseProcArgs(_ buffer: UnsafeRawBufferPointer) -> (arguments: [String], environment: [String: String])? {
        let end = buffer.count
        guard end >= MemoryLayout<Int32>.size else { return nil }
        let argc = Int(buffer.loadUnaligned(fromByteOffset: 0, as: Int32.self))

        var offset = MemoryLayout<Int32>.size
        // Skip the exec path, then the NUL padding that aligns argv.
        guard let execPathEnd = indexOfNUL(in: buffer, from: offset) else { return ([], [:]) }
        offset = execPathEnd
        while offset < end, buffer[offset] == 0 { offset += 1 }

        // Each argument needs at least one byte, which bounds a garbage argc.
        let expectedArguments = max(0, min(argc, end - offset))
        var arguments: [String] = []
        arguments.reserveCapacity(expectedArguments)
        while arguments.count < expectedArguments, offset < end {
            guard let terminator = indexOfNUL(in: buffer, from: offset) else { break }
            arguments.append(decodeUTF8(buffer, offset..<terminator))
            offset = terminator + 1
        }
        // Without all of argv we cannot know where the environment starts.
        guard arguments.count == expectedArguments else { return (arguments, [:]) }

        var environment: [String: String] = [:]
        while offset < end {
            guard let terminator = indexOfNUL(in: buffer, from: offset) else { break }
            if terminator == offset { break }   // empty string terminates the environment block
            let entry = buffer[offset..<terminator]
            if let equals = entry.firstIndex(of: UInt8(ascii: "=")), equals > offset {
                let key = decodeUTF8(buffer, offset..<equals)
                if environment[key] == nil {   // getenv() semantics: the first definition wins
                    environment[key] = decodeUTF8(buffer, (equals + 1)..<terminator)
                }
            }
            offset = terminator + 1
        }
        return (arguments, environment)
    }

    /// PROC_PIDVNODEPATHINFO → pvi_cdir path.
    static func currentDirectory(pid: Int32) -> String? {
        var info = proc_vnodepathinfo()
        let size = Int32(MemoryLayout<proc_vnodepathinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDVNODEPATHINFO, 0, &info, size) == size else { return nil }
        let path = withUnsafeBytes(of: &info.pvi_cdir.vip_path) { decodeCString($0) }
        return path.isEmpty ? nil : path
    }

    /// Full ProcessDetails (path + args/env + cwd) for one process; nil if gone.
    ///
    /// For processes of other users only the executable path is usually readable; arguments and
    /// environment are then empty and `cwd` is nil. The identity is re-verified after all reads,
    /// so the result can never describe a different process that recycled the pid.
    static func details(for basic: ProcessBasic) -> ProcessDetails? {
        let pid = basic.pid
        guard pid > 0 else { return nil }
        let path = executablePath(pid: pid)
        let argumentsAndEnvironment = argumentsAndEnvironment(pid: pid)
        let cwd = currentDirectory(pid: pid)
        guard let current = SysProc.basic(pid: pid), current.startTime == basic.startTime else { return nil }
        return ProcessDetails(identity: basic.identity,
                              executablePath: path,
                              arguments: argumentsAndEnvironment?.arguments ?? [],
                              environment: argumentsAndEnvironment?.environment ?? [:],
                              cwd: cwd)
    }

    // MARK: - Sockets

    /// PROC_PIDLISTFDS + PROC_PIDFDSOCKETINFO; returns TCP sockets in LISTEN state (TSI_S_LISTEN).
    /// nil when the process can't be inspected (EPERM/ESRCH), [] when it has none.
    static func listeningTCPSockets(pid: Int32) -> [ListeningSocket]? {
        var fdBuffer: [proc_fdinfo] = []
        return listeningTCPSockets(pid: pid, fdBuffer: &fdBuffer)
    }

    /// Same as `listeningTCPSockets(pid:)` but reuses `fdBuffer` across calls (it is grown as
    /// needed and never shrunk), which keeps a full scan free of per-process allocations.
    /// Sockets are deduplicated (dup'ed descriptors) and sorted by port, family, address.
    static func listeningTCPSockets(pid: Int32, fdBuffer: inout [proc_fdinfo]) -> [ListeningSocket]? {
        guard let fdCount = listFileDescriptors(pid: pid, into: &fdBuffer) else { return nil }

        var sockets: [ListeningSocket] = []
        var info = socket_fdinfo()
        for index in 0..<fdCount where fdBuffer[index].proc_fdtype == socketFDType {
            guard let socket = listeningSocket(pid: pid, fd: fdBuffer[index].proc_fd, scratch: &info),
                  !sockets.contains(socket)
            else { continue }
            sockets.append(socket)
        }
        if sockets.count > 1 { sockets.sort(by: socketOrder) }
        return sockets
    }

    /// Every listening TCP socket on the system (all users) from sysctl `net.inet.tcp.pcblist_n`,
    /// attributed to the socket's `so_last_pid` — the same data `netstat -anv` prints, without
    /// spawning it. Returns nil when the list is unavailable or its layout is not the one this
    /// parser knows, so callers can fall back to running netstat.
    ///
    /// Why not only netstat: on macOS 27 a netstat spawned by a non-Apple process (even a signed
    /// .app launched from Finder) prints no TCP rows at all, while a code-signed process reading
    /// the sysctl itself still gets the full list. (Merely linker-signed binaries, e.g. a bare
    /// `swiftc` output, get an empty list; this function then returns nil.)
    ///
    /// The record structs (`xinpcb_n`, `xsocket_n`, `xtcpcb_n`) are not in the public SDK. They are
    /// declared in xnu's bsd/netinet/in_pcb.h, sys/socketvar.h and netinet/tcp_var.h under
    /// `#pragma pack(4)`; the offsets below follow those declarations, and every record's
    /// self-reported length must match the known size before any field is read.
    static func systemTCPListeners() -> [ListeningSocket]? {
        guard let data = readSysctl(named: "net.inet.tcp.pcblist_n") else { return nil }
        return data.withUnsafeBytes { parsePCBList($0) }
    }

    /// Parses a `net.inet.tcp.pcblist_n` buffer; see `systemTCPListeners()`. nil when the buffer
    /// is malformed, uses an unknown layout, or contains no PCBs at all (a filtered view).
    static func parsePCBList(_ buffer: UnsafeRawBufferPointer) -> [ListeningSocket]? {
        let end = buffer.count
        func u32(_ offset: Int) -> UInt32 { buffer.loadUnaligned(fromByteOffset: offset, as: UInt32.self) }
        func roundUp8(_ value: Int) -> Int { (value + 7) & ~7 }

        // struct xinpgen { u_int32_t xig_len; u_int xig_count; u_quad_t xig_gen, xig_sogen; } (24 bytes)
        guard end >= PCBLayout.generationHeaderSize,
              Int(u32(0)) == PCBLayout.generationHeaderSize
        else { return nil }

        var sockets: [ListeningSocket] = []
        var pcbCount = 0
        var inpcb: Int?, socket: Int?, tcpcb: Int?
        var offset = PCBLayout.generationHeaderSize

        while offset + 8 <= end {
            // Every record starts with struct xgen_n { u_int32_t xgn_len; u_int32_t xgn_kind; }.
            let length = Int(u32(offset))
            // The list is terminated by a trailing xinpgen (length 24).
            if length <= PCBLayout.generationHeaderSize { break }
            guard offset + length <= end else { return nil }

            // The records of one PCB are contiguous (the kernel emits inpcb, socket, buffers, stats,
            // tcpcb); seeing a kind that is already set means the next PCB has started.
            switch u32(offset + 4) {
            case PCBLayout.kindInpcb:
                guard length == PCBLayout.inpcbSize else { return nil }
                if inpcb != nil { socket = nil; tcpcb = nil }
                inpcb = offset
                pcbCount += 1
            case PCBLayout.kindSocket:
                guard length == PCBLayout.socketSize else { return nil }
                if socket != nil { inpcb = nil; tcpcb = nil }
                socket = offset
            case PCBLayout.kindTcpcb:
                guard length >= PCBLayout.tcpcbMinimumSize else { return nil }
                if tcpcb != nil { inpcb = nil; socket = nil }
                tcpcb = offset
            default:
                break   // socket buffers and stats are not needed
            }

            if let inp = inpcb, let so = socket, let tp = tcpcb {
                if let listener = pcbListener(buffer, inpcb: inp, socket: so, tcpcb: tp) {
                    sockets.append(listener)
                }
                inpcb = nil; socket = nil; tcpcb = nil
            }
            offset += roundUp8(length)
        }
        return pcbCount > 0 ? sockets : nil
    }

    /// Canonical socket ordering used everywhere a socket list is produced.
    static func socketOrder(_ lhs: ListeningSocket, _ rhs: ListeningSocket) -> Bool {
        if lhs.port != rhs.port { return lhs.port < rhs.port }
        if lhs.family != rhs.family { return lhs.family == .ipv4 }
        return lhs.address < rhs.address
    }

    // MARK: - Resource usage

    /// proc_pid_rusage(RUSAGE_INFO_V4): total CPU time in nanoseconds (user+system converted with
    /// mach_timebase_info) and ri_phys_footprint.
    static func resourceSample(pid: Int32) -> (cpuNanos: UInt64, footprintBytes: UInt64)? {
        guard pid > 0 else { return nil }
        var info = rusage_info_v4()
        // proc_pid_rusage takes `rusage_info_t *` (void **) but writes the struct itself into
        // that memory; the rebinding only satisfies the C signature.
        let status = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { rebound in
                proc_pid_rusage(pid, RUSAGE_INFO_V4, rebound)
            }
        }
        guard status == 0 else { return nil }
        let ticks = info.ri_user_time &+ info.ri_system_time
        return (machTicksToNanoseconds(ticks), info.ri_phys_footprint)
    }

    /// Converts mach absolute time units (what rusage reports on Apple Silicon) to nanoseconds
    /// without overflowing for large tick counts.
    static func machTicksToNanoseconds(_ ticks: UInt64) -> UInt64 {
        let numer = UInt64(timebase.numer)
        let denom = UInt64(timebase.denom)
        if numer == denom { return ticks }
        return (ticks / denom) &* numer &+ (ticks % denom) &* numer / denom
    }

    // MARK: - Private helpers

    /// Values from <sys/proc_info.h> / <sys/proc.h>, normalised to the field types they are compared with.
    private static let socketFDType = UInt32(PROX_FDTYPE_SOCKET)   // 2
    private static let socketInfoTCP = Int32(SOCKINFO_TCP)          // 2
    private static let tcpStateListen = Int32(TSI_S_LISTEN)         // 1
    private static let inetVersion4 = UInt8(INI_IPV4)               // 0x1
    private static let inetVersion6 = UInt8(INI_IPV6)               // 0x2
    private static let zombieState = Int8(SZOMB)                    // 5

    private static let maxProcessTableAttempts = 8
    /// PROC_PIDPATHINFO_MAXSIZE (4 * MAXPATHLEN) is a macro Swift cannot import.
    private static let pidPathBufferSize = 4 * Int(MAXPATHLEN)
    /// Upper bound on PROCARGS2 data (kern.argmax), queried once.
    private static let argumentBufferSize: Int = {
        var mib: [Int32] = [CTL_KERN, KERN_ARGMAX]
        var value: Int32 = 0
        var size = MemoryLayout<Int32>.size
        if sysctl(&mib, u_int(mib.count), &value, &size, nil, 0) == 0, value > 0 {
            return Int(value)
        }
        return 1 << 20
    }()

    private static let timebase: mach_timebase_info_data_t = {
        var info = mach_timebase_info_data_t()
        guard mach_timebase_info(&info) == KERN_SUCCESS, info.numer > 0, info.denom > 0 else {
            return mach_timebase_info_data_t(numer: 1, denom: 1)
        }
        return info
    }()

    private static func makeBasic(_ info: kinfo_proc) -> ProcessBasic? {
        let pid = info.kp_proc.p_pid
        guard pid > 0, info.kp_proc.p_stat != zombieState else { return nil }
        let start = info.kp_proc.p_starttime
        let seconds = UInt64(max(0, start.tv_sec))
        let micros = UInt64(max(0, start.tv_usec))
        let comm = withUnsafeBytes(of: info.kp_proc.p_comm) { decodeCString($0) }
        return ProcessBasic(pid: pid,
                            ppid: info.kp_eproc.e_ppid,
                            pgid: info.kp_eproc.e_pgid,
                            uid: info.kp_eproc.e_ucred.cr_uid,
                            comm: comm,
                            startTime: seconds &* 1_000_000 &+ micros)
    }

    /// Fills `buffer` with the process's descriptor table and returns the number of valid
    /// entries, or nil when the process cannot be inspected.
    ///
    /// PROC_PIDLISTFDS silently truncates to the buffer size, so a completely filled buffer is
    /// treated as "maybe truncated": the needed size is probed (nil buffer → bytes needed, which
    /// already includes kernel slack), the buffer grows, and the call is retried.
    private static func listFileDescriptors(pid: Int32, into buffer: inout [proc_fdinfo]) -> Int? {
        let entrySize = MemoryLayout<proc_fdinfo>.stride
        if buffer.isEmpty {
            guard let needed = probeFileDescriptorBytes(pid: pid) else { return nil }
            buffer = [proc_fdinfo](repeating: proc_fdinfo(), count: needed / entrySize + 32)
        }
        for _ in 0..<4 {
            errno = 0
            let written = buffer.withUnsafeMutableBytes { raw in
                proc_pidinfo(pid, PROC_PIDLISTFDS, 0, raw.baseAddress, Int32(clamping: raw.count))
            }
            // libproc returns 0 both for "no descriptors" and for errors; errno tells them apart.
            if written <= 0 { return errno == 0 && written == 0 ? 0 : nil }
            let count = Int(written) / entrySize
            if count < buffer.count { return count }

            guard let needed = probeFileDescriptorBytes(pid: pid) else { return nil }
            let grown = max(needed / entrySize + 64, buffer.count * 2)
            buffer = [proc_fdinfo](repeating: proc_fdinfo(), count: grown)
        }
        // Still growing after several attempts (fd storm): use what fits rather than failing.
        return buffer.count
    }

    private static func probeFileDescriptorBytes(pid: Int32) -> Int? {
        errno = 0
        let needed = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, nil, 0)
        if needed > 0 { return Int(needed) }
        return errno == 0 ? MemoryLayout<proc_fdinfo>.stride : nil
    }

    /// Returns the socket behind `fd` if it is a TCP socket in LISTEN state.
    private static func listeningSocket(pid: Int32, fd: Int32, scratch info: inout socket_fdinfo) -> ListeningSocket? {
        let size = Int32(MemoryLayout<socket_fdinfo>.size)
        guard proc_pidfdinfo(pid, fd, PROC_PIDFDSOCKETINFO, &info, size) == size,
              info.psi.soi_kind == socketInfoTCP
        else { return nil }
        let tcp = info.psi.soi_proto.pri_tcp
        guard tcp.tcpsi_state == tcpStateListen else { return nil }

        let inet = tcp.tcpsi_ini
        // insi_lport holds a network-order 16-bit port in an int.
        let port = UInt16(bigEndian: UInt16(truncatingIfNeeded: inet.insi_lport))

        let isIPv6: Bool
        switch info.psi.soi_family {
        case AF_INET6: isIPv6 = true
        case AF_INET: isIPv6 = false
        default: isIPv6 = inet.insi_vflag & inetVersion6 != 0 && inet.insi_vflag & inetVersion4 == 0
        }

        if isIPv6 {
            var address = inet.insi_laddr.ina_6
            if let mapped = ipv4Mapped(address) {
                return ListeningSocket(port: port, address: render(ipv4: mapped), family: .ipv4, pid: pid)
            }
            return ListeningSocket(port: port, address: render(ipv6: &address), family: .ipv6, pid: pid)
        }
        return ListeningSocket(port: port, address: render(ipv4: inet.insi_laddr.ina_46.i46a_addr4),
                               family: .ipv4, pid: pid)
    }

    /// Byte layout of the `net.inet.tcp.pcblist_n` records (xnu, `#pragma pack(4)`).
    private enum PCBLayout {
        static let generationHeaderSize = 24          // struct xinpgen
        static let kindSocket: UInt32 = 0x001         // XSO_SOCKET
        static let kindInpcb: UInt32 = 0x010          // XSO_INPCB
        static let kindTcpcb: UInt32 = 0x020          // XSO_TCPCB

        static let inpcbSize = 104                    // struct xinpcb_n
        static let inpcbLocalPort = 18                // u_short inp_lport (network order)
        static let inpcbLocalAddress = 64             // union { in_addr_4in6; in6_addr } inp_dependladdr
        static let inpcbLocalIPv4 = 64 + 12           // in_addr_4in6.ia46_addr4

        static let socketSize = 104                   // struct xsocket_n
        static let socketFamily = 40                  // int xso_family
        static let socketLastPID = 68                 // pid_t so_last_pid

        static let tcpcbMinimumSize = 40              // struct xtcpcb_n (only t_state is read)
        static let tcpcbState = 36                    // int t_state (after t_segq, t_dupacks, t_timer[4])
    }

    private static func pcbListener(_ buffer: UnsafeRawBufferPointer, inpcb: Int, socket: Int, tcpcb: Int) -> ListeningSocket? {
        guard buffer.loadUnaligned(fromByteOffset: tcpcb + PCBLayout.tcpcbState, as: Int32.self) == tcpStateListen else {
            return nil
        }
        let pid = buffer.loadUnaligned(fromByteOffset: socket + PCBLayout.socketLastPID, as: Int32.self)
        guard pid > 0 else { return nil }
        let rawPort = buffer.loadUnaligned(fromByteOffset: inpcb + PCBLayout.inpcbLocalPort, as: UInt16.self)
        let port = UInt16(bigEndian: rawPort)

        let family = buffer.loadUnaligned(fromByteOffset: socket + PCBLayout.socketFamily, as: Int32.self)
        if family == AF_INET6 {
            var address = in6_addr()
            withUnsafeMutableBytes(of: &address) { out in
                out.copyMemory(from: UnsafeRawBufferPointer(
                    rebasing: buffer[(inpcb + PCBLayout.inpcbLocalAddress)..<(inpcb + PCBLayout.inpcbLocalAddress + 16)]))
            }
            if let mapped = ipv4Mapped(address) {
                return ListeningSocket(port: port, address: render(ipv4: mapped), family: .ipv4, pid: pid)
            }
            return ListeningSocket(port: port, address: render(ipv6: &address), family: .ipv6, pid: pid)
        }
        let rawIPv4 = buffer.loadUnaligned(fromByteOffset: inpcb + PCBLayout.inpcbLocalIPv4, as: UInt32.self)
        return ListeningSocket(port: port, address: render(ipv4: in_addr(s_addr: rawIPv4)), family: .ipv4, pid: pid)
    }

    /// Reads a variable-size sysctl by name, growing the buffer while the kernel reports ENOMEM.
    private static func readSysctl(named name: String) -> [UInt8]? {
        for attempt in 0..<4 {
            var probed = 0
            guard sysctlbyname(name, nil, &probed, nil, 0) == 0, probed > 0 else { return nil }
            let capacity = probed + probed / 4 + 4096 * (attempt + 1)
            var data = [UInt8](repeating: 0, count: capacity)
            var written = capacity
            let status = data.withUnsafeMutableBytes { raw in
                sysctlbyname(name, raw.baseAddress, &written, nil, 0)
            }
            if status == 0 {
                data.removeSubrange(min(written, capacity)...)
                return data
            }
            if errno != ENOMEM { return nil }
        }
        return nil
    }

    /// The embedded IPv4 address of a v4-mapped IPv6 address (::ffff:a.b.c.d), else nil.
    private static func ipv4Mapped(_ address: in6_addr) -> in_addr? {
        withUnsafeBytes(of: address) { bytes -> in_addr? in
            guard bytes.count == 16,
                  bytes[0..<10].allSatisfy({ $0 == 0 }),
                  bytes[10] == 0xff, bytes[11] == 0xff
            else { return nil }
            return in_addr(s_addr: bytes.loadUnaligned(fromByteOffset: 12, as: UInt32.self))
        }
    }

    private static func render(ipv4 address: in_addr) -> String {
        guard address.s_addr != 0 else { return "*" }
        var address = address
        var text = [UInt8](repeating: 0, count: Int(INET_ADDRSTRLEN))
        let ok = text.withUnsafeMutableBufferPointer { out -> Bool in
            out.withMemoryRebound(to: CChar.self) { chars in
                inet_ntop(AF_INET, &address, chars.baseAddress, socklen_t(chars.count)) != nil
            }
        }
        return ok ? text.withUnsafeBytes { decodeCString($0) } : "?"
    }

    private static func render(ipv6 address: inout in6_addr) -> String {
        let isUnspecified = withUnsafeBytes(of: address) { $0.allSatisfy { $0 == 0 } }
        guard !isUnspecified else { return "*" }
        var text = [UInt8](repeating: 0, count: Int(INET6_ADDRSTRLEN))
        let ok = text.withUnsafeMutableBufferPointer { out -> Bool in
            out.withMemoryRebound(to: CChar.self) { chars in
                inet_ntop(AF_INET6, &address, chars.baseAddress, socklen_t(chars.count)) != nil
            }
        }
        return ok ? text.withUnsafeBytes { decodeCString($0) } : "?"
    }

    /// Decodes a C string stored in a fixed-size buffer; stops at the first NUL or the buffer end.
    static func decodeCString(_ bytes: UnsafeRawBufferPointer) -> String {
        let length = bytes.firstIndex(of: 0) ?? bytes.count
        return String(decoding: UnsafeRawBufferPointer(rebasing: bytes[0..<length]), as: UTF8.self)
    }

    private static func decodeUTF8(_ buffer: UnsafeRawBufferPointer, _ range: Range<Int>) -> String {
        String(decoding: UnsafeRawBufferPointer(rebasing: buffer[range]), as: UTF8.self)
    }

    /// Index of the first NUL byte at or after `start`, or nil if none before the end.
    private static func indexOfNUL(in buffer: UnsafeRawBufferPointer, from start: Int) -> Int? {
        guard let base = buffer.baseAddress, start >= 0, start < buffer.count else { return nil }
        guard let hit = memchr(base + start, 0, buffer.count - start) else { return nil }
        return base.distance(to: UnsafeRawPointer(hit))
    }
}
