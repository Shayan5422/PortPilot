import XCTest
@testable import PortPilot

final class ListenerBuilderTests: XCTestCase {
    private let uid = ClassifierFixture.uid
    private let home = ResolverTestFS.home
    private let node = "/opt/homebrew/bin/node"
    private let python =
        "/opt/homebrew/Cellar/python@3.12/3.12.12/Frameworks/Python.framework/Versions/3.12/Resources/Python.app/Contents/MacOS/Python"

    /// A fake machine: processes, their details, listening sockets and usage.
    private final class World {
        var fixtures: [ClassifierFixture] = [
            ClassifierFixture(pid: 1, ppid: 0, uid: 0, executable: "/sbin/launchd", arguments: ["/sbin/launchd"]),
        ]
        var sockets: [Int32: [ListeningSocket]] = [:]
        var restricted: Set<Int32> = []
        var usage: [Int32: ResourceUsage] = [:]
        var maps = ManagerMaps()
        let fs = ResolverTestFS()

        @discardableResult
        func add(_ fixture: ClassifierFixture, ports: [UInt16] = [], address: String = "127.0.0.1",
                 memory: UInt64 = 1_000) -> ClassifierFixture {
            fixtures.append(fixture)
            let pid = fixture.basic.pid
            if !ports.isEmpty {
                sockets[pid] = ports.map { ListeningSocket(port: $0, address: address, family: .ipv4, pid: pid) }
            }
            usage[pid] = ResourceUsage(cpuPercent: 1, memoryBytes: memory)
            return fixture
        }

        func build() -> [ListenerGroup] {
            let table = ProcessTable(processes: fixtures.map(\.basic))
            let details = fixtures.reduce(into: [Int32: ProcessDetails]()) { $0[$1.basic.pid] = $1.details }
            let raw = RawScan(table: table, socketsByPID: sockets, restrictedPIDs: restricted)
            return ListenerBuilder.build(raw: raw, details: { details[$0.pid] }, usage: usage,
                                         resolver: fs.makeResolver(), maps: maps, currentUID: ClassifierFixture.uid)
        }
    }

    // MARK: Projects

    func testSiblingPackagesFormOneProjectGroup() {
        let world = World()
        let root = home + "/Downloads/Institut de mai"
        world.fs.addDirectory(root + "/.git")
        world.fs.addFile(root + "/backend/pyproject.toml", "[project]\nname = \"idm-planning\"\n")
        world.fs.addFile(root + "/frontend/package.json", #"{"name": "idm-front"}"#)
        world.add(ClassifierFixture(pid: 200, executable: python,
                                    arguments: ["Python", "-m", "uvicorn", "app.main:app", "--port", "8014"],
                                    environment: ["CODEX_SHELL": "1"], cwd: root + "/backend"), ports: [8014])
        world.add(ClassifierFixture(pid: 201, executable: node,
                                    arguments: ["node", root + "/frontend/node_modules/vite/bin/vite.js", "--port", "5330"],
                                    environment: ["CODEX_SHELL": "1"], cwd: root + "/frontend"), ports: [5330])

        let groups = world.build()
        XCTAssertEqual(groups.count, 1)
        let group = groups[0]
        XCTAssertEqual(group.id, "project:" + root)
        XCTAssertEqual(group.category, .project)
        XCTAssertEqual(group.title, "Institut de mai")
        XCTAssertEqual(group.subtitle, "frontend, backend")
        XCTAssertEqual(group.path, root)
        XCTAssertEqual(group.ports, [5330, 8014])
        XCTAssertEqual(group.processes.map(\.basic.pid), [201, 200], "processes are sorted by first port")
        XCTAssertEqual(group.processes.map(\.displayName), ["vite", "uvicorn app.main:app"])
        XCTAssertEqual(group.frameworks, ["Vite", "uvicorn"])
        XCTAssertEqual(group.origin, LaunchOrigin(kind: .codex, name: "Codex"))
        XCTAssertEqual(group.manager, .none)
    }

    func testLaunchdManagedProjectKeepsProjectGrouping() {
        let world = World()
        let folder = home + "/Downloads/claude check"
        world.fs.addDirectory(folder + "/.git")
        world.fs.addFile(folder + "/claude-monitor/package.json", #"{"name": "claude-monitor"}"#)
        world.add(ClassifierFixture(pid: 964, executable: node,
                                    arguments: ["node", folder + "/claude-monitor/server.js"],
                                    cwd: folder + "/claude-monitor"), ports: [4180], address: "*")
        let job = LaunchdJob(label: "com.claude.monitor", domain: "gui/501", plistPath: nil, keepAlive: true,
                             runAtLoad: true, pid: 964)
        world.maps.launchdLabelsByPID = [964: "com.claude.monitor"]
        world.maps.launchdJobs = ["com.claude.monitor": job]

        let group = world.build()[0]
        XCTAssertEqual(group.title, "claude-monitor")
        XCTAssertEqual(group.subtitle, "node server.js", "a subpath equal to the title is not repeated")
        XCTAssertEqual(group.manager, .launchd(job))
        XCTAssertTrue(group.manager.isAutoRestarting)
        XCTAssertEqual(group.origin, LaunchOrigin(kind: .launchd, name: "launchd"))
        XCTAssertTrue(group.isExposedToNetwork)
    }

    // MARK: Services

    func testLaunchdServiceGroupWithWorkersDoesNotDoubleCountUsage() {
        let world = World()
        let nginx = "/opt/homebrew/Cellar/nginx/1.27.0/bin/nginx"
        world.add(ClassifierFixture(pid: 300, comm: "nginx", executable: nginx,
                                    arguments: ["nginx: master process /opt/homebrew/bin/nginx -c /x/nginx.conf", "", ""],
                                    cwd: home + "/.codex/deploy"), ports: [4173], memory: 100)
        world.add(ClassifierFixture(pid: 301, ppid: 300, comm: "nginx", executable: nginx,
                                    arguments: ["nginx: worker process", ""], cwd: home + "/.codex/deploy"),
                  ports: [4173], memory: 10)
        world.add(ClassifierFixture(pid: 302, ppid: 300, comm: "nginx", executable: nginx,
                                    arguments: ["nginx: worker process", ""], cwd: home + "/.codex/deploy"),
                  ports: [4173], memory: 10)
        world.maps.launchdLabelsByPID = [300: "com.acme.planning-frontend"]

        let groups = world.build()
        XCTAssertEqual(groups.count, 1)
        let group = groups[0]
        XCTAssertEqual(group.id, "launchd:com.acme.planning-frontend")
        XCTAssertEqual(group.category, .service)
        XCTAssertEqual(group.title, "planning-frontend")
        XCTAssertEqual(group.subtitle, "nginx, nginx worker")
        XCTAssertEqual(group.path, home + "/.codex/deploy")
        XCTAssertEqual(group.usage.memoryBytes, 120, "workers are listeners themselves and must not be counted twice")
        guard case .launchd(let job) = group.manager else { return XCTFail("expected launchd manager") }
        XCTAssertTrue(job.runAtLoad, "unknown jobs are assumed to start at login")
    }

    func testHomebrewServiceTitle() {
        let world = World()
        world.add(ClassifierFixture(pid: 993, executable: "/opt/homebrew/Cellar/postgresql@16/16.4/bin/postgres",
                                    arguments: ["/opt/homebrew/opt/postgresql@16/bin/postgres", "-D", "/opt/homebrew/var/postgresql@16"],
                                    cwd: "/opt/homebrew/var/postgresql@16"), ports: [5432])
        world.maps.launchdLabelsByPID = [993: "sh.brew.postgresql@16"]
        let group = world.build()[0]
        XCTAssertEqual(group.title, "postgresql@16")
        XCTAssertEqual(group.subtitle, "postgres")
        XCTAssertEqual(group.frameworks, ["PostgreSQL"])
        XCTAssertEqual(group.manager.badge, "brew services")
    }

    func testAppInstanceAndAppleLabelsAreNotManagers() {
        let world = World()
        world.add(ClassifierFixture(pid: 400, executable: home + "/.local/bin/tool-server", cwd: "/"), ports: [9000])
        world.add(ClassifierFixture(pid: 401, executable: "/usr/libexec/rapportd"), ports: [49152], address: "*")
        world.maps.launchdLabelsByPID = [400: "application.com.example.Tool.123.456", 401: "com.apple.rapportd"]

        let groups = world.build()
        XCTAssertEqual(groups.map(\.manager), [.none, .none])
        XCTAssertEqual(groups.first { $0.processes[0].basic.pid == 401 }?.category, .system)
        XCTAssertTrue(groups.allSatisfy { $0.id.hasPrefix("pid:") })
    }

    func testLaunchdJobAboveAnInteractiveShellIsNotTheManager() {
        let world = World()
        world.add(ClassifierFixture(pid: 500, executable: home + "/.local/bin/web-terminal"))
        world.add(ClassifierFixture(pid: 501, ppid: 500, executable: "/bin/zsh", arguments: ["-zsh"]))
        world.add(ClassifierFixture(pid: 502, ppid: 501, executable: node, arguments: ["node", "server.js"], cwd: "/"),
                  ports: [3000])
        world.maps.launchdLabelsByPID = [500: "com.example.web-terminal"]
        let group = world.build()[0]
        XCTAssertEqual(group.manager, .none)
    }

    // MARK: Other managers

    func testPM2AppsGroupByName() {
        let world = World()
        world.add(ClassifierFixture(pid: 600, executable: node, arguments: ["PM2 v5.4.2: God Daemon (/Users/test/.pm2)"]))
        world.add(ClassifierFixture(pid: 601, ppid: 600, executable: node, arguments: ["node", "/srv-less/api.js"], cwd: "/"),
                  ports: [7001])
        world.add(ClassifierFixture(pid: 602, ppid: 600, executable: node, arguments: ["node", "/srv-less/api.js"], cwd: "/"),
                  ports: [7002])
        world.maps.pm2ByPID = [601: (id: 0, name: "api"), 602: (id: 1, name: "api")]

        let groups = world.build()
        XCTAssertEqual(groups.count, 1)
        XCTAssertEqual(groups[0].id, "pm2:api")
        XCTAssertEqual(groups[0].title, "api")
        XCTAssertEqual(groups[0].manager, .pm2(id: 0, name: "api"))
        XCTAssertEqual(groups[0].origin, LaunchOrigin(kind: .pm2, name: "PM2"))
    }

    func testDockerPortsAreSplitPerContainer() {
        let world = World()
        world.add(ClassifierFixture(pid: 700, executable: "/Applications/Docker.app/Contents/MacOS/com.docker.backend"),
                  ports: [5432, 6379, 9999], address: "*")
        let postgres = DockerContainer(id: "c1", name: "db", image: "postgres:16-alpine", restartPolicy: "always")
        let redis = DockerContainer(id: "c2", name: "cache", image: "docker.io/library/redis:7", restartPolicy: "no")
        world.maps.dockerByPort = [5432: postgres, 6379: redis]

        let groups = world.build()
        XCTAssertEqual(groups.map(\.id), ["docker:c1", "docker:c2", "app:/Applications/Docker.app"])
        XCTAssertEqual(groups[0].title, "db")
        XCTAssertEqual(groups[0].subtitle, "postgres:16-alpine")
        XCTAssertEqual(groups[0].category, .service)
        XCTAssertEqual(groups[0].manager, .docker(postgres))
        XCTAssertEqual(groups[0].frameworks, ["PostgreSQL"])
        XCTAssertEqual(groups[1].frameworks, ["Redis"])
        XCTAssertEqual(groups[2].category, .app)
        XCTAssertEqual(groups[2].ports, [9999])
        XCTAssertEqual(groups[0].usage, .zero, "container usage lives in the VM, not the backend process")
    }

    func testWatcherBecomesManager() {
        let world = World()
        world.fs.addFile(home + "/code/api/package.json", #"{"name": "api"}"#)
        world.add(ClassifierFixture(pid: 800, executable: node, arguments: ["node", home + "/code/api/node_modules/nodemon/bin/nodemon.js"],
                                    cwd: home + "/code/api"))
        world.add(ClassifierFixture(pid: 801, ppid: 800, executable: node, arguments: ["node", "index.js"],
                                    cwd: home + "/code/api"), ports: [4000])
        XCTAssertEqual(world.build()[0].manager, .watcher(name: "nodemon"))
    }

    // MARK: Fallback grouping

    func testProjectlessListenersUnderOneRunnerShareAGroup() {
        let world = World()
        world.add(ClassifierFixture(pid: 900, executable: "/bin/zsh", arguments: ["-zsh"]))
        let npm = world.add(ClassifierFixture(pid: 901, ppid: 900, executable: node,
                                              arguments: ["node", "/opt/homebrew/lib/node_modules/npm/bin/npm-cli.js", "start"]))
        world.add(ClassifierFixture(pid: 902, ppid: 901, executable: "/bin/sh", arguments: ["sh", "-c", "concurrently a b"]))
        world.add(ClassifierFixture(pid: 903, ppid: 902, executable: node, arguments: ["node", "a.js"], cwd: "/"), ports: [8081])
        world.add(ClassifierFixture(pid: 904, ppid: 902, executable: node, arguments: ["node", "b.js"], cwd: "/"), ports: [8082])

        let groups = world.build()
        XCTAssertEqual(groups.count, 1)
        XCTAssertEqual(groups[0].id, "pid:" + npm.basic.identity.description)
        XCTAssertEqual(groups[0].title, "node a.js")
        XCTAssertEqual(groups[0].category, .service)
    }

    func testLoneProcessGroupUsesItsOwnIdentityAndCwd() {
        let world = World()
        world.add(ClassifierFixture(pid: 950, comm: "claude", executable: home + "/.local/bin/claude"))
        let mcp = world.add(ClassifierFixture(pid: 951, ppid: 950, executable: home + "/.local/bin/codebase-memory-mcp",
                                              environment: ["CLAUDECODE": "1"], cwd: home + "/Downloads/Heyclicky"),
                            ports: [9749])
        let group = world.build()[0]
        XCTAssertEqual(group.id, "pid:" + mcp.basic.identity.description)
        XCTAssertEqual(group.category, .service)
        XCTAssertEqual(group.title, "codebase-memory-mcp")
        XCTAssertEqual(group.subtitle, Format.abbreviatePath(home + "/Downloads/Heyclicky"))
        XCTAssertEqual(group.path, home + "/Downloads/Heyclicky")
        XCTAssertEqual(group.origin, LaunchOrigin(kind: .claudeCode, name: "Claude Code"))
    }

    func testBoundaryListenerIsNeverPartOfAProject() {
        let world = World()
        world.fs.addDirectory(home + "/code/app/.git")
        world.add(ClassifierFixture(pid: 960, comm: "claude", executable: home + "/.local/bin/claude",
                                    cwd: home + "/code/app"), ports: [61000])
        let group = world.build()[0]
        XCTAssertNil(group.processes[0].project)
        XCTAssertNotEqual(group.category, .project)
    }

    func testRestrictedOtherUserListenerIsSystem() {
        let world = World()
        world.add(ClassifierFixture(pid: 77, uid: 0, comm: "httpd", executable: nil, readable: false), ports: [80], address: "*")
        world.restricted = [77]
        let group = world.build()[0]
        XCTAssertEqual(group.category, .system)
        XCTAssertTrue(group.processes[0].isRestricted)
        XCTAssertEqual(group.title, "httpd")
        XCTAssertNil(group.processes[0].project)
        XCTAssertEqual(group.manager, .none)
    }

    func testAppGroupsUseBundle() {
        let world = World()
        world.add(ClassifierFixture(pid: 1000, executable: "/Applications/Player.app/Contents/MacOS/Player"),
                  ports: [7768, 57621])
        let group = world.build()[0]
        XCTAssertEqual(group.id, "app:/Applications/Player.app")
        XCTAssertEqual(group.title, "Player")
        XCTAssertEqual(group.processes[0].appName, "Player")
        XCTAssertNil(group.origin)
        XCTAssertNil(group.subtitle)
    }

    func testTreeUsageIncludesHelperDescendants() {
        let world = World()
        world.fs.addFile(home + "/code/web/package.json", #"{"name": "web"}"#)
        world.add(ClassifierFixture(pid: 1100, executable: node, arguments: ["node", home + "/code/web/node_modules/vite/bin/vite.js"],
                                    cwd: home + "/code/web"), ports: [5173], memory: 500)
        world.add(ClassifierFixture(pid: 1101, ppid: 1100, executable: home + "/code/web/node_modules/@esbuild/darwin-arm64/bin/esbuild",
                                    arguments: ["esbuild", "--service=0.21.5"], cwd: home + "/code/web"), memory: 50)
        let process = world.build()[0].processes[0]
        XCTAssertEqual(process.usage.memoryBytes, 500)
        XCTAssertEqual(process.treeUsage.memoryBytes, 550)
        XCTAssertEqual(process.treeUsage.cpuPercent, 2, accuracy: 0.001)
    }

    func testVanishedProcessesAndEmptySocketListsAreSkipped() {
        let world = World()
        world.sockets[4242] = [ListeningSocket(port: 1234, address: "*", family: .ipv4, pid: 4242)]
        world.add(ClassifierFixture(pid: 4243, executable: node))
        world.sockets[4243] = []
        XCTAssertTrue(world.build().isEmpty)
    }

    // MARK: Helpers

    func testLaunchdTitles() {
        XCTAssertEqual(ListenerBuilder.launchdTitle(for: "homebrew.mxcl.redis"), "redis")
        XCTAssertEqual(ListenerBuilder.launchdTitle(for: "sh.brew.postgresql@16"), "postgresql@16")
        XCTAssertEqual(ListenerBuilder.launchdTitle(for: "com.webzou.cloudflared"), "cloudflared")
        XCTAssertEqual(ListenerBuilder.launchdTitle(for: "com.claude.monitor.tunnel"), "monitor.tunnel")
        XCTAssertEqual(ListenerBuilder.launchdTitle(for: "local.myserver"), "myserver")
        XCTAssertEqual(ListenerBuilder.launchdTitle(for: "pm2.shayan"), "pm2.shayan")
        XCTAssertEqual(ListenerBuilder.launchdTitle(for: "worker"), "worker")
    }

    func testImageFrameworks() {
        XCTAssertEqual(ListenerBuilder.frameworks(forImage: "ghcr.io/acme/mongo:7@sha256:abc"), ["MongoDB"])
        XCTAssertEqual(ListenerBuilder.frameworks(forImage: "acme/api:latest"), [])
    }
}
