import Foundation
@testable import PortPilot

/// Synthetic listeners, startup items and stores for UI tests. Pure values: nothing here inspects or signals
/// real processes, and `AppStore(previewSnapshot:)` has no engine, so its actions are no-ops.
enum UIFixtures {
    static let home = NSHomeDirectory()

    static func process(pid: Int32, name: String = "node server.js", ports: [UInt16] = [3000],
                        category: ListenerCategory = .project, uid: UInt32 = 501, restricted: Bool = false,
                        cpu: Double = 0.4, memory: UInt64 = 48_000_000, project: ProjectInfo? = nil,
                        manager: ProcessManager = .none, address: String = "127.0.0.1") -> ListenerProcess {
        let basic = ProcessBasic(pid: pid, ppid: 1, pgid: pid, uid: uid, comm: String(name.prefix(16)),
                                 startTime: 1_760_000_000_000_000 + UInt64(pid))
        let details = restricted ? nil : ProcessDetails(identity: basic.identity, executablePath: "/opt/homebrew/bin/node",
                                                        arguments: name.split(separator: " ").map(String.init),
                                                        environment: [:], cwd: project?.rootPath ?? "/")
        let sockets = ports.map { ListeningSocket(port: $0, address: address, family: .ipv4, pid: pid) }
        let usage = ResourceUsage(cpuPercent: cpu, memoryBytes: memory)
        return ListenerProcess(basic: basic, details: details, sockets: sockets, usage: usage, treeUsage: usage,
                               category: category, project: project, displayName: name, frameworks: [],
                               origin: nil, manager: manager, appName: nil, isRestricted: restricted)
    }

    static func group(id: String, category: ListenerCategory, title: String, subtitle: String? = nil,
                      path: String? = nil, processes: [ListenerProcess]) -> ListenerGroup {
        ListenerGroup(id: id, category: category, title: title, subtitle: subtitle, path: path, processes: processes)
    }

    static func startupItem(label: String = "com.northwind.app", keepAlive: Bool, isLoaded: Bool, pid: Int32?,
                            lastExit: Int32?, isDisabled: Bool = false, ports: [UInt16] = [],
                            command: String = "/bin/zsh -lc \"cd ~/Website && npm start\"") -> StartupItem {
        StartupItem(label: label, plistPath: home + "/Library/LaunchAgents/\(label).plist", command: command,
                    workingDirectory: nil, runAtLoad: true, keepAlive: keepAlive, isDisabled: isDisabled,
                    isLoaded: isLoaded, pid: pid, lastExitStatus: lastExit, ports: ports)
    }

    // MARK: Worst-case panel

    /// Ports of a Firebase emulator suite: one java process owning many ports.
    static let manyPorts: [UInt16] = [4000, 4400, 4500, 5001, 8080, 8085, 9000, 9099, 9199, 9299]

    /// Groups that stress the row layout and every Stop rule: many ports on one process, a heavy usage pill,
    /// a path-like title, an app, a macOS service, another user's process and launchd itself.
    static func worstCaseGroups() -> [ListenerGroup] {
        let firebaseRoot = home + "/Developer/clients/firebase-emulator-suite-with-a-long-name"
        let firebase = process(pid: 51001, name: "java -jar cloud-firestore-emulator.jar", ports: manyPorts,
                               cpu: 143, memory: 2_400_000_000,
                               project: ProjectInfo(rootPath: firebaseRoot, name: "firebase-emulators",
                                                    subpath: "emulators/firestore", markers: [".git"]))
        let deployRoot = home + "/.codex/acme-public-deployment-20261008/release"
        let deploy = process(pid: 51002, name: "uvicorn app.main:app", ports: [8000],
                             project: ProjectInfo(rootPath: deployRoot, name: "acme-public-deployment-20261008/release",
                                                  subpath: "backend", markers: [".git"]))
        let docker = process(pid: 51003, name: "com.docker.backend", ports: [5432, 6379, 8081, 9200, 27017, 15672],
                             category: .service, address: "*")
        let ide = process(pid: 94297, name: "Electron", ports: [65384, 65385], category: .app)
        let rapportd = process(pid: 709, name: "rapportd", ports: [49152], category: .system, address: "*")
        let kdc = process(pid: 393, name: "kdc", ports: [88], category: .system, uid: 0, restricted: true, address: "*")
        let launchd = process(pid: 1, name: "launchd", ports: [49153], category: .system, uid: 0)
        return [
            group(id: "project:" + firebaseRoot, category: .project, title: "firebase-emulators",
                  subtitle: "java -jar cloud-firestore-emulator.jar", path: firebaseRoot, processes: [firebase]),
            group(id: "project:" + deployRoot, category: .project, title: "acme-public-deployment-20261008/release",
                  subtitle: "backend", path: deployRoot, processes: [deploy]),
            group(id: "pid:docker", category: .service, title: "Docker", subtitle: "com.docker.backend",
                  path: "/Applications/Docker.app", processes: [docker]),
            group(id: "app:/Applications/Antigravity IDE.app", category: .app, title: "Antigravity IDE",
                  path: "/Applications/Antigravity IDE.app", processes: [ide]),
            group(id: "pid:rapportd", category: .system, title: "rapportd", subtitle: "Continuity", processes: [rapportd]),
            group(id: "pid:kdc", category: .system, title: "kdc", processes: [kdc]),
            group(id: "pid:launchd", category: .system, title: "launchd", processes: [launchd]),
        ]
    }

    static func worstCaseStartupItems() -> [StartupItem] {
        [
            startupItem(label: "com.northwind.app", keepAlive: true, isLoaded: true, pid: nil, lastExit: 78),
            startupItem(label: "com.acme.firebase-emulators-with-a-long-label", keepAlive: true, isLoaded: true,
                        pid: 51001, lastExit: 0, ports: [4000, 4400, 4500, 5001, 8080, 8085, 9099],
                        command: "/opt/homebrew/bin/firebase emulators:start --project demo"),
            startupItem(label: "com.acme.nightly-sync", keepAlive: false, isLoaded: true, pid: nil, lastExit: 1,
                        command: "/usr/bin/python3 sync.py"),
        ]
    }

    static func worstCaseStopped(now: Date = Date()) -> [StoppedRecord] {
        [
            StoppedRecord(id: UUID(), date: now.addingTimeInterval(-90),
                          title: "firebase-emulator-suite-with-a-long-name · java -jar cloud-firestore-emulator.jar",
                          ports: [4000, 4400, 4500, 5001, 8080, 8085], cwd: home + "/Developer/clients/firebase",
                          arguments: ["java", "-jar", "cloud-firestore-emulator.jar"], environment: [:],
                          executablePath: "/usr/bin/java", manager: .none),
        ]
    }

    @MainActor
    static func worstCaseStore(banner: Banner? = nil, expandAll: Bool = true) -> AppStore {
        let groups = worstCaseGroups()
        var settings = AppSettings()
        settings.showApps = true
        settings.showSystem = true
        let snapshot = ScanSnapshot(date: Date().addingTimeInterval(-2), groups: groups,
                                    table: ProcessTable(processes: groups.flatMap { $0.processes.map(\.basic) }),
                                    duration: 0.01, restrictedCount: 1)
        let store = AppStore(previewSnapshot: snapshot, startupItems: worstCaseStartupItems(),
                             recentlyStopped: worstCaseStopped(), settings: settings, banner: banner)
        if expandAll { store.expandedGroupIDs = Set(groups.map(\.id)) }
        return store
    }

    static let longErrorBanner = Banner(
        style: .error,
        message: "Couldn't fully stop firebase-emulators: pid 51001: operation not permitted; pid 51004: still running after SIGKILL")
}
