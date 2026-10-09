import AppKit
import SwiftUI

/// Headless modes used for scripting and verification:
///   PortPilot --dump                      JSON of the grouped scan
///   PortPilot --plan <pid>                what Stop would signal for a listener pid (nothing is sent)
///   PortPilot --snapshot <out.png> [--dark] [--settings] [--expand-all]
///                                         render the panel with live data to a PNG
enum CommandLineMode {
    /// Returns an exit code when the invocation was a CLI mode, nil to continue launching the app.
    @MainActor
    static func runIfRequested(arguments: [String] = CommandLine.arguments) -> Int32? {
        let args = Array(arguments.dropFirst())
        if args.contains("--dump") { return dump() }
        if let index = args.firstIndex(of: "--plan") {
            guard index + 1 < args.count, let pid = Int32(args[index + 1]) else {
                printError("usage: PortPilot --plan <pid>")
                return 2
            }
            return plan(pid: pid)
        }
        if let index = args.firstIndex(of: "--snapshot") {
            guard index + 1 < args.count else {
                printError("usage: PortPilot --snapshot <out.png> [--dark] [--settings] [--expand-all]")
                return 2
            }
            return snapshot(to: URL(fileURLWithPath: args[index + 1]), dark: args.contains("--dark"),
                            settingsPane: args.contains("--settings"), expandAll: args.contains("--expand-all"),
                            showAll: args.contains("--all"))
        }
        return nil
    }

    // MARK: Modes

    /// Two scans one second apart so CPU% is meaningful.
    private static func warmScan(engine: ScanEngine, includeOtherUsers: Bool) -> ScanOutput {
        _ = engine.scanBlocking(includeOtherUsers: includeOtherUsers)
        Thread.sleep(forTimeInterval: 1)
        return engine.scanBlocking(includeOtherUsers: includeOtherUsers)
    }

    private static func dump() -> Int32 {
        let engine = ScanEngine()
        let output = warmScan(engine: engine, includeOtherUsers: CommandLine.arguments.contains("--all"))
        let groups: [[String: Any]] = output.snapshot.groups.map { group -> [String: Any] in
            var entry: [String: Any] = [:]
            entry["id"] = group.id
            entry["category"] = group.category.rawValue
            entry["title"] = group.title
            entry["subtitle"] = group.subtitle ?? NSNull()
            entry["path"] = group.path ?? NSNull()
            entry["ports"] = group.ports.map(Int.init)
            entry["manager"] = group.manager.badge ?? NSNull()
            entry["origin"] = group.origin?.name ?? NSNull()
            entry["frameworks"] = group.frameworks
            entry["cpuPercent"] = (group.usage.cpuPercent * 10).rounded() / 10
            entry["memoryMB"] = Int(group.usage.memoryBytes / 1_000_000)
            entry["processes"] = group.processes.map { process in processEntry(process, plans: output.plans) }
            return entry
        }
        let root: [String: Any] = [
            "scannedAt": ISO8601DateFormatter().string(from: output.snapshot.date),
            "scanMilliseconds": (output.snapshot.duration * 10_000).rounded() / 10,
            "restrictedCount": output.snapshot.restrictedCount,
            "groups": groups,
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .sortedKeys]) else {
            printError("failed to encode JSON")
            return 1
        }
        FileHandle.standardOutput.write(data)
        FileHandle.standardOutput.write(Data("\n".utf8))
        return 0
    }

    private static func processEntry(_ process: ListenerProcess, plans: [ProcessIdentity: KillPlan]) -> [String: Any] {
        var entry: [String: Any] = [:]
        entry["pid"] = Int(process.basic.pid)
        entry["ppid"] = Int(process.basic.ppid)
        entry["name"] = process.displayName
        entry["command"] = process.commandLine
        entry["cwd"] = process.details?.cwd ?? NSNull()
        entry["ports"] = process.ports.map(Int.init)
        entry["addresses"] = process.sockets.map { "\($0.address):\($0.port)" }
        entry["cpuPercent"] = (process.treeUsage.cpuPercent * 10).rounded() / 10
        entry["memoryMB"] = Int(process.treeUsage.memoryBytes / 1_000_000)
        entry["restricted"] = process.isRestricted
        entry["category"] = process.category.rawValue
        entry["origin"] = process.origin?.name ?? NSNull()
        entry["manager"] = process.manager.badge ?? NSNull()
        if let plan = plans[process.id] {
            entry["stopPlan"] = plan.summary
            entry["stopWarnings"] = plan.warnings
        }
        if case .launchd(let job) = process.manager {
            entry["launchdLabel"] = job.label
            entry["keepAlive"] = job.keepAlive
            entry["runAtLoad"] = job.runAtLoad
        }
        return entry
    }

    private static func plan(pid: Int32) -> Int32 {
        let engine = ScanEngine()
        let output = engine.scanBlocking(includeOtherUsers: false)
        guard let listener = output.snapshot.groups.flatMap(\.processes).first(where: { $0.basic.pid == pid }),
              let plan = output.plans[listener.id] else {
            printError("pid \(pid) is not a listening process owned by you")
            return 1
        }
        print("Listener: \(listener.displayName) (pid \(pid)) ports \(listener.ports.map { ":\($0)" }.joined(separator: ", "))")
        print("Manager:  \(listener.manager.badge ?? "none")")
        print("Root:     \(plan.root.comm) (pid \(plan.root.pid))")
        print("Stop would signal \(plan.targets.count) process(es):")
        for line in plan.summary { print("  • \(line)") }
        for warning in plan.warnings { print("  ⚠︎ \(warning)") }
        if plan.requiresAdmin { print("  (requires administrator password)") }
        return 0
    }

    @MainActor
    private static func snapshot(to url: URL, dark: Bool, settingsPane: Bool, expandAll: Bool, showAll: Bool) -> Int32 {
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.prohibited)
        let engine = ScanEngine()
        let output = warmScan(engine: engine, includeOtherUsers: showAll)
        var settings = AppSettings()
        settings.showApps = showAll
        settings.showSystem = showAll
        let store = AppStore(previewSnapshot: output.snapshot, startupItems: engine.launchd.startupItems(),
                             recentlyStopped: [], settings: settings)
        if expandAll { store.expandedGroupIDs = Set(output.snapshot.groups.map(\.id)) }
        SnapshotRenderer.render(store: store, to: url, width: 440, colorScheme: dark ? .dark : .light,
                                showSettings: settingsPane)
        print(url.path)
        return 0
    }

    private static func printError(_ message: String) {
        FileHandle.standardError.write(Data((message + "\n").utf8))
    }
}

/// Keeps a single PortPilot instance (the LaunchAgent copy and a double-clicked copy must not both run).
enum SingleInstance {
    /// True if another instance with our bundle id is already running.
    static var anotherInstanceIsRunning: Bool {
        guard let bundleID = Bundle.main.bundleIdentifier else { return false }
        let me = ProcessInfo.processInfo.processIdentifier
        return NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
            .contains { $0.processIdentifier != me && !$0.isTerminated }
    }
}
