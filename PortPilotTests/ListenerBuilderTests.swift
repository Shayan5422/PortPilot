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

        func build(traits: ProcessTraitsCache? = nil,
                   sampleUsage: (([ProcessBasic]) -> [Int32: ResourceUsage])? = nil) -> [ListenerGroup] {
            let table = ProcessTable(processes: fixtures.map(\.basic))
            let details = fixtures.reduce(into: [Int32: ProcessDetails]()) { $0[$1.basic.pid] = $1.details }
            let raw = RawScan(table: table, socketsByPID: sockets, restrictedPIDs: restricted)
            return ListenerBuilder.build(raw: raw, details: { details[$0.pid] }, usage: usage,
                                         resolver: fs.makeResolver(), maps: maps, currentUID: ClassifierFixture.uid,
                                         traits: traits, sampleUsage: sampleUsage)
        }
    }

    // MARK: Projects

    func testSiblingPackagesFormOneProjectGroup() {
        let world = World()
        let root = home + "/Downloads/Harbor Notes"
        world.fs.addDirectory(root + "/.git")
        world.fs.addFile(root + "/backend/pyproject.toml", "[project]\nname = \"harbor-api\"\n")
        world.fs.addFile(root + "/frontend/package.json", #"{"name": "harbor-web"}"#)
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
        XCTAssertEqual(group.title, "Harbor Notes")
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
        let folder = home + "/Downloads/uptime check"
        world.fs.addDirectory(folder + "/.git")
        world.fs.addFile(folder + "/uptime-monitor/package.json", #"{"name": "uptime-monitor"}"#)
        world.add(ClassifierFixture(pid: 964, executable: node,
                                    arguments: ["node", folder + "/uptime-monitor/server.js"],
                                    cwd: folder + "/uptime-monitor"), ports: [4180], address: "*")
        let job = LaunchdJob(label: "com.example.uptime-monitor", domain: "gui/501", plistPath: nil, keepAlive: true,
                             runAtLoad: true, pid: 964)
        world.maps.launchdLabelsByPID = [964: "com.example.uptime-monitor"]
        world.maps.launchdJobs = ["com.example.uptime-monitor": job]

        let group = world.build()[0]
        XCTAssertEqual(group.title, "uptime-monitor")
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
        world.maps.launchdLabelsByPID = [300: "com.acme.docs-frontend"]

        let groups = world.build()
        XCTAssertEqual(groups.count, 1)
        let group = groups[0]
        XCTAssertEqual(group.id, "launchd:com.acme.docs-frontend")
        XCTAssertEqual(group.category, .service)
        XCTAssertEqual(group.title, "docs-frontend")
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
                                              environment: ["CLAUDECODE": "1"], cwd: home + "/Downloads/Pixelpost"),
                            ports: [9749])
        let group = world.build()[0]
        XCTAssertEqual(group.id, "pid:" + mcp.basic.identity.description)
        XCTAssertEqual(group.category, .service)
        XCTAssertEqual(group.title, "codebase-memory-mcp")
        XCTAssertEqual(group.subtitle, Format.abbreviatePath(home + "/Downloads/Pixelpost"))
        XCTAssertEqual(group.path, home + "/Downloads/Pixelpost")
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
        XCTAssertEqual(ListenerBuilder.launchdTitle(for: "com.northwind.cloudflared"), "cloudflared")
        XCTAssertEqual(ListenerBuilder.launchdTitle(for: "com.contoso.billing-backend"), "billing-backend")
        XCTAssertEqual(ListenerBuilder.launchdTitle(for: "local.myserver"), "myserver")
        XCTAssertEqual(ListenerBuilder.launchdTitle(for: "pm2.alex"), "pm2.alex")
        XCTAssertEqual(ListenerBuilder.launchdTitle(for: "worker"), "worker")
        // The vendor is usually the project's name: keep it when the rest is generic or several segments.
        XCTAssertEqual(ListenerBuilder.launchdTitle(for: "com.example.status.tunnel"), "example status tunnel")
        XCTAssertEqual(ListenerBuilder.launchdTitle(for: "com.example.monitor"), "example monitor")
        XCTAssertEqual(ListenerBuilder.launchdTitle(for: "com.northwind.app"), "northwind app")
        XCTAssertEqual(ListenerBuilder.launchdTitle(for: "io.fabrikam.daemon"), "fabrikam daemon")
        XCTAssertEqual(ListenerBuilder.launchdTitle(for: "ai.tinybot.gateway"), "tinybot gateway")
        XCTAssertEqual(ListenerBuilder.launchdTitle(for: "ai.relaybot.gateway"), "relaybot gateway")
        XCTAssertEqual(ListenerBuilder.launchdTitle(for: "com.northwind.cloudflared", keepingVendor: true), "northwind cloudflared")
        XCTAssertEqual(ListenerBuilder.launchdTitle(for: "homebrew.mxcl.redis", keepingVendor: true), "redis")
        XCTAssertEqual(ListenerBuilder.launchdTitle(for: "com."), "com.")
    }

    func testLaunchdJobsWithTheSameShortTitleKeepTheirVendor() {
        let world = World()
        let cloudflared = "/opt/homebrew/Cellar/cloudflared/2025.8.1/bin/cloudflared"
        world.add(ClassifierFixture(pid: 1200, executable: cloudflared, arguments: ["cloudflared", "tunnel", "run"]),
                  ports: [20241])
        world.add(ClassifierFixture(pid: 1201, executable: cloudflared, arguments: ["cloudflared", "tunnel", "run"]),
                  ports: [20242])
        world.maps.launchdLabelsByPID = [1200: "com.northwind.cloudflared", 1201: "com.acme.cloudflared"]
        XCTAssertEqual(world.build().map(\.title), ["northwind cloudflared", "acme cloudflared"])
    }

    // MARK: Service folders

    func testLaunchdServiceInRootFolderNeverUsesThePlistAsPath() {
        let world = World()
        let cloudflared = "/opt/homebrew/Cellar/cloudflared/2025.8.1/bin/cloudflared"
        world.add(ClassifierFixture(pid: 1300, executable: cloudflared, arguments: ["cloudflared", "tunnel", "run"],
                                    cwd: "/"), ports: [20241])
        let plist = home + "/Library/LaunchAgents/com.northwind.cloudflared.plist"
        world.maps.launchdLabelsByPID = [1300: "com.northwind.cloudflared"]
        world.maps.launchdJobs = ["com.northwind.cloudflared": LaunchdJob(
            label: "com.northwind.cloudflared", domain: "gui/501", plistPath: plist, keepAlive: true, runAtLoad: true,
            pid: 1300)]
        let group = world.build()[0]
        XCTAssertEqual(group.path, "/opt/homebrew/Cellar/cloudflared/2025.8.1/bin", "the program's folder, not \(plist)")
        XCTAssertNotEqual(group.path, plist)
    }

    func testServiceFolderRules() {
        func folder(_ executable: String?, _ arguments: [String], cwd: String? = "/") -> String? {
            ListenerBuilder.serviceFolder(for: ClassifierFixture(pid: 10, executable: executable, arguments: arguments,
                                                                 cwd: cwd).details)
        }
        XCTAssertEqual(folder(node, ["node", "server.js"], cwd: home + "/srv/api"), home + "/srv/api", "cwd wins")
        XCTAssertEqual(folder("/bin/bash", ["/bin/bash", home + "/tools/backup/run.sh"]), home + "/tools/backup",
                       "a script's folder, not /bin")
        XCTAssertEqual(folder(python, ["Python", "-u", home + "/bots/relay/main.py"]), home + "/bots/relay")
        XCTAssertNil(folder("/usr/bin/python3", ["python3", "-m", "http.server"]), "no script, interpreter folder is useless")
        XCTAssertNil(folder("/bin/sh", ["sh", "-c", "exec ./run"]))
        XCTAssertNil(folder("/usr/libexec/sharingd", ["/usr/libexec/sharingd"]), "system folders are not offered")
        XCTAssertNil(folder("/Applications/Ollama.app/Contents/Resources/ollama", ["ollama", "serve"]))
        XCTAssertEqual(folder(home + "/go/bin/gosvc", ["gosvc"]), home + "/go/bin")
        XCTAssertNil(ListenerBuilder.serviceFolder(for: nil))
    }

    // MARK: Group usage covers what Stop ends

    func testGroupUsageIncludesRunnerParentAndSiblingWorkers() {
        let world = World()
        let app = home + "/Downloads/fullstack"
        world.fs.addFile(app + "/package.json", #"{"name": "fullstack-app"}"#)
        world.add(ClassifierFixture(pid: 1400, executable: "/bin/zsh", arguments: ["-zsh"]), memory: 5)
        world.add(ClassifierFixture(pid: 1401, ppid: 1400, executable: node,
                                    arguments: ["node", "/opt/homebrew/lib/node_modules/npm/bin/npm-cli.js", "run", "dev"],
                                    cwd: app), memory: 26)
        world.add(ClassifierFixture(pid: 1402, ppid: 1401, executable: "/bin/sh",
                                    arguments: ["sh", "-c", "node server.js & node worker.js & wait"], cwd: app), memory: 1)
        world.add(ClassifierFixture(pid: 1403, ppid: 1402, executable: node, arguments: ["node", "server.js"], cwd: app),
                  ports: [53030], memory: 17)
        world.add(ClassifierFixture(pid: 1404, ppid: 1402, executable: node, arguments: ["node", "worker.js"], cwd: app),
                  memory: 133)
        world.add(ClassifierFixture(pid: 1405, ppid: 1403, executable: node, arguments: ["node", "child.js"], cwd: app),
                  memory: 3)
        // An agent the runner happened to start must not be counted (Stop never ends it).
        world.add(ClassifierFixture(pid: 1406, ppid: 1401, comm: "claude", executable: home + "/.local/bin/claude"),
                  memory: 400)

        let group = world.build()[0]
        XCTAssertEqual(group.processes.map(\.basic.pid), [1403])
        XCTAssertEqual(group.processes[0].treeUsage.memoryBytes, 20, "the listener row keeps its own tree")
        XCTAssertEqual(group.extraUsage.memoryBytes, 26 + 1 + 133, "npm, sh -c and the worker Stop also ends")
        XCTAssertEqual(group.usage.memoryBytes, 180)
        XCTAssertEqual(group.usage.cpuPercent, 5, accuracy: 0.001)
    }

    func testGroupUsageSamplesLaunchTreeProcessesOnDemand() {
        let world = World()
        world.add(ClassifierFixture(pid: 1500, executable: "/bin/zsh", arguments: ["-zsh"]))
        world.add(ClassifierFixture(pid: 1501, ppid: 1500, executable: node,
                                    arguments: ["node", "/opt/homebrew/lib/node_modules/npm/bin/npm-cli.js", "start"]))
        world.add(ClassifierFixture(pid: 1502, ppid: 1501, executable: node, arguments: ["node", "a.js"], cwd: "/"),
                  ports: [8081], memory: 10)
        world.add(ClassifierFixture(pid: 1503, ppid: 1501, executable: node, arguments: ["node", "b.js"], cwd: "/"),
                  ports: [8082], memory: 20)
        world.usage[1501] = nil   // the scan only sampled listeners and their descendants

        var requested: [[Int32]] = []
        let groups = world.build(sampleUsage: { basics in
            requested.append(basics.map(\.pid))
            return Dictionary(uniqueKeysWithValues: basics.map { ($0.pid, ResourceUsage(cpuPercent: 2, memoryBytes: 64)) })
        })
        XCTAssertEqual(requested, [[1501]], "only the missing runner is sampled, once")
        XCTAssertEqual(groups.count, 1, "both servers belong to the npm launch")
        XCTAssertEqual(groups[0].usage.memoryBytes, 10 + 20 + 64, "the runner is counted once for the group")
    }

    func testLaunchTreeSharedByTwoGroupsIsCountedOnce() {
        let world = World()
        world.fs.addDirectory(home + "/code/web/.git")
        world.fs.addDirectory(home + "/code/api/.git")
        world.add(ClassifierFixture(pid: 1600, executable: "/bin/zsh", arguments: ["-zsh"]))
        world.add(ClassifierFixture(pid: 1601, ppid: 1600, executable: node,
                                    arguments: ["node", home + "/code/node_modules/concurrently/dist/bin/concurrently.js"],
                                    cwd: home + "/code"), memory: 50)
        world.add(ClassifierFixture(pid: 1602, ppid: 1601, executable: node, arguments: ["node", "server.js"],
                                    cwd: home + "/code/web"), ports: [3000], memory: 1)
        world.add(ClassifierFixture(pid: 1603, ppid: 1601, executable: node, arguments: ["node", "server.js"],
                                    cwd: home + "/code/api"), ports: [4000], memory: 1)
        let groups = world.build()
        XCTAssertEqual(groups.map(\.id), ["project:" + home + "/code/web", "project:" + home + "/code/api"])
        XCTAssertEqual(groups.map(\.extraUsage.memoryBytes), [50, 0], "the shared runner goes to the first group only")
    }

    func testNoExtraUsageAboveProtectedParentsOrForManagedListeners() {
        let world = World()
        // claude → zsh -c → python: Stop ends only the listener, so nothing above it is counted.
        world.add(ClassifierFixture(pid: 1700, comm: "claude", executable: home + "/.local/bin/claude"), memory: 300)
        world.add(ClassifierFixture(pid: 1701, ppid: 1700, executable: "/bin/zsh",
                                    arguments: ["/bin/zsh", "-c", "python3 -m http.server 8765"]), memory: 2)
        world.add(ClassifierFixture(pid: 1702, ppid: 1701, executable: python,
                                    arguments: ["Python", "-m", "http.server", "8765"], cwd: home + "/Downloads/x"),
                  ports: [8765], memory: 9)
        // Docker rows carry no host usage at all.
        world.add(ClassifierFixture(pid: 1710, executable: "/Applications/Docker.app/Contents/MacOS/com.docker.backend"),
                  ports: [5432], address: "*", memory: 900)
        world.maps.dockerByPort = [5432: DockerContainer(id: "c1", name: "db", image: "postgres:16", restartPolicy: nil)]

        let groups = world.build()
        XCTAssertEqual(groups.count, 2)
        XCTAssertTrue(groups.allSatisfy { $0.extraUsage == .zero }, "\(groups.map { ($0.id, $0.extraUsage) })")
        XCTAssertEqual(groups.first { $0.ports == [8765] }?.usage.memoryBytes, 9)
    }

    // MARK: PM2 cluster mode

    private func clusterWorker(pid: Int32, daemon: Int32, name: String, id: Int, port: String?, cwd: String) -> ClassifierFixture {
        var env: [String: Any] = ["name": name, "pm_id": id, "exec_mode": "cluster_mode", "pm_cwd": cwd]
        if let port { env["PORT"] = port }
        let json = String(decoding: (try? JSONSerialization.data(withJSONObject: env)) ?? Data(), as: UTF8.self)
        return ClassifierFixture(pid: pid, ppid: daemon, executable: node,
                                 arguments: ["node", "/opt/homebrew/lib/node_modules/pm2/lib/ProcessContainer.js"],
                                 environment: ["NODE_UNIQUE_ID": String(id), "pm2_env": json, "PORT": "9"], cwd: cwd)
    }

    func testPM2ClusterAppOwnsTheDaemonSocket() {
        let world = World()
        let app = home + "/code/northwind-api"
        world.fs.addDirectory(app + "/.git")
        world.fs.addFile(app + "/package.json", #"{"name": "northwind-api"}"#)
        world.add(ClassifierFixture(pid: 1800, executable: node, arguments: ["PM2 v5.4.3: God Daemon (/Users/test/.pm2)"]),
                  ports: [3000], memory: 40)
        world.add(clusterWorker(pid: 1801, daemon: 1800, name: "northwind-api", id: 4, port: nil, cwd: app), memory: 100)
        world.add(clusterWorker(pid: 1802, daemon: 1800, name: "northwind-api", id: 3, port: nil, cwd: app), memory: 110)
        // A fork-mode app of the same daemon that does not listen: not part of the cluster app.
        world.add(ClassifierFixture(pid: 1803, ppid: 1800, executable: node, arguments: ["node", "cron.js"],
                                    environment: ["exec_mode": "fork_mode"], cwd: home + "/code/cron"), memory: 7)
        world.maps.pm2ByPID = [1801: (id: 4, name: "northwind-api"), 1802: (id: 3, name: "northwind-api"),
                               1803: (id: 9, name: "cron")]

        let groups = world.build()
        XCTAssertEqual(groups.map(\.id), ["pm2:northwind-api"])
        let group = groups[0]
        XCTAssertEqual(group.title, "northwind-api")
        XCTAssertEqual(group.manager, .pm2(id: 3, name: "northwind-api"), "lowest pm_id of the app")
        XCTAssertEqual(group.category, .project)
        XCTAssertEqual(group.path, app)
        XCTAssertEqual(group.origin, LaunchOrigin(kind: .pm2, name: "PM2"))
        XCTAssertEqual(group.processes.map(\.basic.pid), [1800], "the daemon holds the socket")
        XCTAssertEqual(group.processes[0].displayName, "pm2 cluster · 2 workers")
        XCTAssertEqual(group.usage.memoryBytes, 210, "the workers pm2 stop ends; not the daemon or other apps")
    }

    func testPM2ClusterAppsAreMatchedByPortAndUnknownSocketsStayWithTheDaemon() {
        let world = World()
        world.add(ClassifierFixture(pid: 1900, executable: node, arguments: ["PM2 v5.4.3: God Daemon (/Users/test/.pm2)"]),
                  ports: [3001, 3002, 3003], memory: 40)
        world.add(clusterWorker(pid: 1901, daemon: 1900, name: "api", id: 0, port: "3001", cwd: "/"), memory: 10)
        world.add(clusterWorker(pid: 1902, daemon: 1900, name: "public", id: 1, port: "3002", cwd: "/"), memory: 20)
        world.add(clusterWorker(pid: 1903, daemon: 1900, name: "admin", id: 2, port: nil, cwd: "/"), memory: 30)
        world.add(clusterWorker(pid: 1904, daemon: 1900, name: "docs", id: 5, port: nil, cwd: "/"), memory: 40)
        world.maps.pm2ByPID = [1901: (0, "api"), 1902: (1, "public"), 1903: (2, "admin"), 1904: (5, "docs")]

        let groups = world.build()
        XCTAssertEqual(groups.map(\.id).sorted(), ["pm2:api", "pm2:public", groups.first { $0.id.hasPrefix("pid:") }?.id ?? "?"].sorted())
        XCTAssertEqual(groups.first { $0.id == "pm2:api" }?.ports, [3001])
        XCTAssertEqual(groups.first { $0.id == "pm2:public" }?.ports, [3002])
        let daemon = groups.first { $0.id.hasPrefix("pid:") }
        XCTAssertEqual(daemon?.ports, [3003], "two apps without PORT: no guessing")
        XCTAssertEqual(daemon?.manager, ProcessManager.none)
        XCTAssertEqual(daemon?.title, "PM2 daemon")
        XCTAssertEqual(daemon?.usage.memoryBytes, 40 + 30 + 40, "workers of attributed apps are not counted twice")
    }

    func testPM2DaemonWithoutJListStaysUnattributed() {
        let world = World()
        world.add(ClassifierFixture(pid: 2000, executable: node, arguments: ["PM2 v5.4.3: God Daemon (/tmp/x)"]),
                  ports: [3000])
        world.add(clusterWorker(pid: 2001, daemon: 2000, name: "api", id: 0, port: "3000", cwd: "/"))
        let group = world.build()[0]
        XCTAssertEqual(group.manager, ProcessManager.none, "only pm2 jlist may name an app pm2 commands can stop")
        XCTAssertTrue(group.id.hasPrefix("pid:"))
    }

    func testClusterWorkerEnvironmentParsing() {
        XCTAssertNil(PM2ClusterWorker(environment: ["PATH": "/usr/bin"]))
        XCTAssertNil(PM2ClusterWorker(environment: ["pm2_env": #"{"exec_mode":"fork_mode","name":"x"}"#]))
        XCTAssertEqual(PM2ClusterWorker(environment: ["NODE_UNIQUE_ID": "1"]), PM2ClusterWorker(name: nil, id: nil, port: nil))
        XCTAssertEqual(PM2ClusterWorker(environment: ["NODE_UNIQUE_ID": "1",
                                                      "pm2_env": #"{"exec_mode":"cluster_mode","name":"api","pm_id":7,"env":{"PORT":3005}}"#]),
                       PM2ClusterWorker(name: "api", id: 7, port: 3005))
        XCTAssertEqual(PM2ClusterWorker(environment: ["NODE_UNIQUE_ID": "1", "pm2_env": "not json"]),
                       PM2ClusterWorker(name: nil, id: nil, port: nil))
        XCTAssertEqual(PM2ClusterWorker(environment: ["NODE_UNIQUE_ID": "1", "pm2_env": #"{"PORT":"99999"}"#])?.port, nil)
    }

    // MARK: Memoization

    func testSharedTraitsCacheGivesTheSameGroups() {
        let world = World()
        world.fs.addFile(home + "/code/api/package.json", #"{"name": "api"}"#)
        world.add(ClassifierFixture(pid: 2100, executable: node, arguments: ["node", home + "/code/api/node_modules/nodemon/bin/nodemon.js"],
                                    cwd: home + "/code/api"))
        world.add(ClassifierFixture(pid: 2101, ppid: 2100, executable: node, arguments: ["node", "index.js"],
                                    environment: ["TERM_PROGRAM": "Apple_Terminal"], cwd: home + "/code/api"), ports: [4000])
        let cache = ProcessTraitsCache()
        let fresh = world.build()
        let first = world.build(traits: cache)
        let second = world.build(traits: cache)
        for groups in [first, second] {
            XCTAssertEqual(groups.map(\.id), fresh.map(\.id))
            XCTAssertEqual(groups.map(\.manager), fresh.map(\.manager))
            XCTAssertEqual(groups.map(\.origin), fresh.map(\.origin))
            XCTAssertEqual(groups.map(\.title), fresh.map(\.title))
            XCTAssertEqual(groups.map(\.frameworks), fresh.map(\.frameworks))
        }
        XCTAssertEqual(second[0].manager, .watcher(name: "nodemon"))
        XCTAssertGreaterThan(cache.count, 0)
    }

    func testTraitsCacheRecomputesAfterExecAndPrunesDeadProcesses() {
        let cache = ProcessTraitsCache()
        let shell = ClassifierFixture(pid: 2200, comm: "sh", executable: "/bin/sh", arguments: ["sh", "-c", "exec vite"])
        let before = cache.traits(for: shell.basic, details: shell.details)
        // Same pid and start time after exec: p_comm changes, so the entry must not be reused.
        let execd = ClassifierFixture(pid: 2200, comm: "node", executable: node,
                                      arguments: ["node", home + "/w/node_modules/vite/bin/vite.js"])
        let traits = cache.traits(for: execd.basic, details: execd.details)
        XCTAssertEqual(traits.displayName, "vite")
        XCTAssertNotEqual(before.displayName, traits.displayName)
        // Details that were unreadable at first are picked up once readable.
        let unreadable = ClassifierFixture(pid: 2201, comm: "node", executable: node, readable: false)
        XCTAssertEqual(cache.traits(for: unreadable.basic, details: nil).displayName, "node")
        let readable = ClassifierFixture(pid: 2201, comm: "node", executable: node, arguments: ["node", "server.js"])
        XCTAssertEqual(cache.traits(for: readable.basic, details: readable.details).displayName, "node server.js")

        XCTAssertEqual(cache.count, 2)
        cache.prune(keepingAliveIn: ProcessTable(processes: [execd.basic]))
        XCTAssertEqual(cache.count, 1)
    }

    func testLineageAnswersAreReusedOnlyForTheSameAncestry() {
        let cache = ProcessTraitsCache()
        let a = ProcessBasic(pid: 10, ppid: 5, pgid: 10, uid: uid, comm: "node", startTime: 10)
        let parent = ProcessBasic(pid: 5, ppid: 1, pgid: 5, uid: uid, comm: "nodemon", startTime: 5)
        let other = ProcessBasic(pid: 6, ppid: 1, pgid: 6, uid: uid, comm: "zsh", startTime: 6)
        func lineage(_ chain: [ProcessBasic]) -> ProcessTraitsCache.Lineage {
            ProcessTraitsCache.Lineage(members: chain.map(\.identity),
                                       signatures: chain.map { ProcessTraitsCache.Signature($0, nil) })
        }
        var computed = 0
        let compute: () -> String? = { computed += 1; return "nodemon" }
        XCTAssertEqual(cache.watcherName(for: a.identity, lineage: lineage([a, parent]), compute: compute), "nodemon")
        XCTAssertEqual(cache.watcherName(for: a.identity, lineage: lineage([a, parent]), compute: compute), "nodemon")
        XCTAssertEqual(computed, 1)
        _ = cache.watcherName(for: a.identity, lineage: lineage([a, other]), compute: compute)
        XCTAssertEqual(computed, 2, "re-parented: recomputed")

        var origins = 0
        let origin: () -> LaunchOrigin? = { origins += 1; return LaunchOrigin(kind: .terminal, name: "Terminal") }
        _ = cache.origin(for: a.identity, lineage: lineage([a, parent]), launchdLabel: nil, compute: origin)
        _ = cache.origin(for: a.identity, lineage: lineage([a, parent]), launchdLabel: nil, compute: origin)
        _ = cache.origin(for: a.identity, lineage: lineage([a, parent]), launchdLabel: "com.x.y", compute: origin)
        XCTAssertEqual(origins, 2, "a different launchd label is a different answer")

        var roots = 0
        let root: () -> ProcessBasic = { roots += 1; return parent }
        XCTAssertEqual(cache.launchRoot(for: a.identity, lineage: lineage([a, parent]), projectRoot: "/p", compute: root),
                       parent)
        _ = cache.launchRoot(for: a.identity, lineage: lineage([a, parent]), projectRoot: "/p", compute: root)
        XCTAssertEqual(roots, 1)
        _ = cache.launchRoot(for: a.identity, lineage: lineage([a, parent]), projectRoot: nil, compute: root)
        XCTAssertEqual(roots, 2, "a different project is a different answer")
        _ = cache.launchRoot(for: a.identity, lineage: lineage([a, other]), projectRoot: nil, compute: root)
        XCTAssertEqual(roots, 3, "re-parented: recomputed")
        cache.prune(keepingAliveIn: ProcessTable(processes: [parent]))
        _ = cache.launchRoot(for: a.identity, lineage: lineage([a, other]), projectRoot: nil, compute: root)
        XCTAssertEqual(roots, 4, "pruned with the process")
    }

    /// Grouping and group usage use the very root KillPlanner signals from, whatever its rules are.
    func testProcessGroupIsKeyedByTheKillPlanRoot() {
        let world = World()
        world.add(ClassifierFixture(pid: 2400, executable: "/bin/zsh", arguments: ["-zsh"]))
        // /usr/bin/make is a shim that execs Xcode's make, so that is the executable a running make has.
        world.add(ClassifierFixture(pid: 2401, ppid: 2400, executable: "/Applications/Xcode.app/Contents/Developer/usr/bin/make",
                                    arguments: ["make", "serve"], cwd: "/"), memory: 4)
        world.add(ClassifierFixture(pid: 2402, ppid: 2401, executable: "/bin/sh",
                                    arguments: ["/bin/sh", "-c", "python3 -m http.server 8111"], cwd: "/"), memory: 2)
        world.add(ClassifierFixture(pid: 2403, ppid: 2402, executable: python, arguments: ["Python", "-m", "http.server", "8111"],
                                    cwd: "/"), ports: [8111], memory: 9)
        let cache = ProcessTraitsCache()
        let groups = world.build(traits: cache)
        let listener = groups[0].processes[0]
        let table = ProcessTable(processes: world.fixtures.map(\.basic))
        let details = world.fixtures.reduce(into: [Int32: ProcessDetails]()) { $0[$1.basic.pid] = $1.details }
        let plan = KillPlanner.plan(for: listener, table: table, details: { details[$0.pid] }, currentUID: uid)
        XCTAssertEqual(plan.root.pid, 2401)
        XCTAssertEqual(groups.map(\.id), ["pid:" + plan.root.identity.description])
        XCTAssertEqual(groups[0].extraUsage.memoryBytes, 4 + 2, "make and sh -c, which Stop also ends")
        XCTAssertEqual(world.build(traits: cache).map(\.id), groups.map(\.id), "same answer from the memo")
    }

    // MARK: Models

    func testGroupPortsStayInSyncWithProcesses() {
        let world = World()
        world.add(ClassifierFixture(pid: 2300, executable: node, arguments: ["node", "a.js"]), ports: [9002, 9001])
        var group = world.build()[0]
        XCTAssertEqual(group.ports, [9001, 9002])
        let extra = ListenerProcess(basic: ProcessBasic(pid: 2301, ppid: 1, pgid: 2301, uid: uid, comm: "x", startTime: 1),
                                    details: nil,
                                    sockets: [ListeningSocket(port: 80, address: "*", family: .ipv4, pid: 2301),
                                              ListeningSocket(port: 80, address: "::", family: .ipv6, pid: 2301)],
                                    usage: .zero, treeUsage: .zero, category: .service, project: nil, displayName: "x",
                                    frameworks: [], origin: nil, manager: .none, appName: nil, isRestricted: true)
        XCTAssertEqual(extra.ports, [80])
        group.processes.append(extra)
        XCTAssertEqual(group.ports, [80, 9001, 9002])
        group.processes.removeAll()
        XCTAssertEqual(group.ports, [])
    }

    func testCommandLineDropsTrailingEmptyArguments() {
        func line(_ arguments: [String]) -> String {
            ProcessDetails(identity: ProcessIdentity(pid: 1, startTime: 1), executablePath: nil, arguments: arguments,
                           environment: [:], cwd: nil).commandLine
        }
        XCTAssertEqual(line(["nginx: master process /opt/homebrew/bin/nginx -c /x/nginx.conf", "", ""]),
                       #""nginx: master process /opt/homebrew/bin/nginx -c /x/nginx.conf""#)
        XCTAssertEqual(line(["/opt/homebrew/opt/redis/bin/redis-server 127.0.0.1:6379", ""]),
                       #""/opt/homebrew/opt/redis/bin/redis-server 127.0.0.1:6379""#)
        XCTAssertEqual(line(["node", "", "server.js"]), #"node "" server.js"#, "empty arguments in the middle matter")
        XCTAssertEqual(line(["node", "server.js"]), "node server.js")
        XCTAssertEqual(line([]), "")
        let record = StoppedRecord(id: UUID(), date: Date(), title: "t", ports: [], cwd: nil,
                                   arguments: ["redis-server *:6379", ""], environment: [:], executablePath: nil,
                                   manager: .none)
        XCTAssertEqual(record.commandLine, #""redis-server *:6379""#)
    }

    func testImageFrameworks() {
        XCTAssertEqual(ListenerBuilder.frameworks(forImage: "ghcr.io/acme/mongo:7@sha256:abc"), ["MongoDB"])
        XCTAssertEqual(ListenerBuilder.frameworks(forImage: "acme/api:latest"), [])
    }
}
