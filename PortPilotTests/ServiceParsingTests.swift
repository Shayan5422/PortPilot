import XCTest
@testable import PortPilot

// Pure-parser tests for the Control layer (launchctl, launchd plists, docker, pm2, Shell helpers).
// A few Shell.run tests spawn tiny local processes (/bin/echo, /bin/sh, /bin/sleep) that the test owns.

// MARK: - launchctl

final class LaunchctlParsingTests: XCTestCase {
    private let listOutput = """
    PID\tStatus\tLabel
    -\t0\tcom.apple.SafariHistoryServiceAgent
    1170\t0\tcom.apple.progressd
    50706\t-15\tcom.alasuitebench.planning-backend
    -\t78\tus.zoom.updater
    993\t0\tsh.brew.postgresql@16
    57752\t0\tapplication.alasuite.Compte-rendu.15940426.15940432
    this is not a row
    abc\t0\tbroken.pid

    """

    func testParseListSkipsHeaderAndMalformedRows() {
        let entries = LaunchdService.parseList(listOutput)
        XCTAssertEqual(entries.map(\.label), [
            "com.apple.SafariHistoryServiceAgent", "com.apple.progressd", "com.alasuitebench.planning-backend",
            "us.zoom.updater", "sh.brew.postgresql@16", "application.alasuite.Compte-rendu.15940426.15940432",
        ])
        XCTAssertEqual(entries[0], LaunchctlListEntry(pid: nil, lastExitStatus: 0, label: "com.apple.SafariHistoryServiceAgent"))
        XCTAssertEqual(entries[2], LaunchctlListEntry(pid: 50706, lastExitStatus: -15, label: "com.alasuitebench.planning-backend"))
        XCTAssertEqual(entries[3].lastExitStatus, 78)
        XCTAssertNil(entries[3].pid)
    }

    func testParseListStatusDash() {
        let entries = LaunchdService.parseList("PID\tStatus\tLabel\n-\t-\tcom.example.never-ran\n")
        XCTAssertEqual(entries, [LaunchctlListEntry(pid: nil, lastExitStatus: nil, label: "com.example.never-ran")])
    }

    func testRunningLabelsOnlyIncludesRunningJobsAndKeepsAppInstances() {
        let labels = LaunchdService.runningLabels(fromListOutput: listOutput)
        XCTAssertEqual(labels, [
            1170: "com.apple.progressd",
            50706: "com.alasuitebench.planning-backend",
            993: "sh.brew.postgresql@16",
            57752: "application.alasuite.Compte-rendu.15940426.15940432",
        ])
    }

    func testRunningLabelsEmptyOutput() {
        XCTAssertTrue(LaunchdService.runningLabels(fromListOutput: "").isEmpty)
        XCTAssertTrue(LaunchdService.runningLabels(fromListOutput: "PID\tStatus\tLabel\n").isEmpty)
    }

    func testParsePrintDisabledModernFormat() {
        let output = """
        \tdisabled services = {
        \t\t"org.pqrs.service.agent.Karabiner-Console-User-Server" => enabled
        \t\t"com.apple.ManagedClientAgent.enrollagent" => disabled
        \t\t"sh.brew.postgresql@16" => enabled
        \t\t"com.example.label with spaces" => disabled
        \t}

        """
        XCTAssertEqual(LaunchdService.parsePrintDisabled(output), [
            "org.pqrs.service.agent.Karabiner-Console-User-Server": false,
            "com.apple.ManagedClientAgent.enrollagent": true,
            "sh.brew.postgresql@16": false,
            "com.example.label with spaces": true,
        ])
    }

    func testParsePrintDisabledLegacyBooleanFormat() {
        let output = """
        disabled services = {
        \t"com.example.off" => true
        \t"com.example.on" => false
        \t"com.example.weird" => maybe
        }
        """
        XCTAssertEqual(LaunchdService.parsePrintDisabled(output), ["com.example.off": true, "com.example.on": false])
    }

    func testParsePrintOutputTakesTopLevelPathOnly() {
        let output = """
        gui/501/com.alasuitebench.planning-backend = {
        \tactive count = 1
        \tpath = /Users/me/Library/LaunchAgents/com.alasuitebench.planning-backend.plist
        \ttype = LaunchAgent
        \tstate = running

        \tprogram = /Users/me/backend/.venv/bin/python
        \targuments = {
        \t\t/Users/me/backend/.venv/bin/python
        \t\t-m
        \t\tuvicorn
        \t}

        \tstdout path = /Users/me/backend.log
        \tenvironment = {
        \t\tPATH => /opt/homebrew/bin:/usr/bin:/bin
        \t}

        \tendpoints = {
        \t\t"com.example.endpoint" = {
        \t\t\tpath = /nested/should/not/win
        \t\t}
        \t}

        \tproperties = keepalive | runatload | inferred program
        }
        """
        let info = LaunchdService.parsePrintOutput(output)
        XCTAssertEqual(info.path, "/Users/me/Library/LaunchAgents/com.alasuitebench.planning-backend.plist")
        XCTAssertEqual(info.properties, ["keepalive", "runatload", "inferred program"])
    }

    func testParsePrintOutputIgnoresNestedPathWhenTopLevelMissing() {
        let output = """
        gui/501/com.example.submitted = {
        \tstdout path = /tmp/out.log
        \tsockets = {
        \t\tpath = /tmp/socket
        \t}
        \tproperties = runatload
        }
        """
        let info = LaunchdService.parsePrintOutput(output)
        XCTAssertNil(info.path)
        XCTAssertEqual(info.properties, ["runatload"])
    }

    func testNotLoadedErrorDetection() {
        XCTAssertTrue(LaunchdService.isNotLoadedError(
            ShellResult(status: 3, stdout: "", stderr: "Boot-out failed: 3: No such process\n")))
        XCTAssertTrue(LaunchdService.isNotLoadedError(
            ShellResult(status: 113, stdout: "", stderr: "Could not find service \"x\" in domain for user gui: 501\n")))
        XCTAssertTrue(LaunchdService.isNotLoadedError(
            ShellResult(status: 1, stdout: "", stderr: "Could not find specified service\n")))
        XCTAssertFalse(LaunchdService.isNotLoadedError(
            ShellResult(status: 5, stdout: "", stderr: "Boot-out failed: 5: Input/output error\n")))
        XCTAssertFalse(LaunchdService.isNotLoadedError(ShellResult(status: 0, stdout: "", stderr: "")))
    }

    func testAppInstanceLabelsAndLabelValidation() {
        XCTAssertTrue(LaunchdService.isAppInstanceLabel("application.com.spotify.client.31973708.31974546"))
        XCTAssertFalse(LaunchdService.isAppInstanceLabel("homebrew.mxcl.redis"))
        XCTAssertTrue(LaunchdService.isValidLabel("sh.brew.postgresql@16"))
        XCTAssertFalse(LaunchdService.isValidLabel(""))
        XCTAssertFalse(LaunchdService.isValidLabel("gui/501/x"))
        XCTAssertFalse(LaunchdService.isValidLabel("a\nb"))
    }

    func testGuiDomainUsesUID() {
        XCTAssertEqual(LaunchdService(uid: 501).guiDomain, "gui/501")
    }
}

// MARK: - launchd plists

final class LaunchdPlistTests: XCTestCase {
    private let dir = "/Users/me/Library/LaunchAgents"

    func testProgramArgumentsPlist() throws {
        let plist: [String: Any] = [
            "Label": "com.claude.monitor",
            "ProgramArguments": ["/opt/homebrew/bin/node", "/Users/me/claude check/server.js"],
            "WorkingDirectory": "/Users/me/claude check",
            "RunAtLoad": true,
            "KeepAlive": true,
        ]
        let info = try XCTUnwrap(LaunchdService.parsePlist(plist, path: dir + "/com.claude.monitor.plist"))
        XCTAssertEqual(info.label, "com.claude.monitor")
        XCTAssertEqual(info.command, "/opt/homebrew/bin/node \"/Users/me/claude check/server.js\"")
        XCTAssertEqual(info.workingDirectory, "/Users/me/claude check")
        XCTAssertTrue(info.runAtLoad)
        XCTAssertTrue(info.keepAlive)
        XCTAssertFalse(info.disabledInPlist)
    }

    func testProgramWithArgumentsUsesProgramAsExecutable() throws {
        let plist: [String: Any] = ["Label": "com.example.y", "Program": "/usr/local/bin/y", "ProgramArguments": ["y", "--serve"]]
        let info = try XCTUnwrap(LaunchdService.parsePlist(plist, path: dir + "/y.plist"))
        XCTAssertEqual(info.command, "/usr/local/bin/y --serve")
        XCTAssertFalse(info.runAtLoad)
        XCTAssertFalse(info.keepAlive)
    }

    func testProgramOnly() throws {
        let plist: [String: Any] = ["Label": "io.sideloadly.daemon",
                                    "Program": "/Applications/Sideloadly.app/Contents/Resources/sideloadly-daemon",
                                    "KeepAlive": false, "RunAtLoad": true]
        let info = try XCTUnwrap(LaunchdService.parsePlist(plist, path: dir + "/io.sideloadly.daemon.plist"))
        XCTAssertEqual(info.command, "/Applications/Sideloadly.app/Contents/Resources/sideloadly-daemon")
        XCTAssertFalse(info.keepAlive)
        XCTAssertTrue(info.runAtLoad)
    }

    func testMissingLabelFallsBackToFileName() throws {
        let plist: [String: Any] = ["ProgramArguments": ["/bin/sleep", "1"]]
        let info = try XCTUnwrap(LaunchdService.parsePlist(plist, path: dir + "/com.example.nolabel.plist"))
        XCTAssertEqual(info.label, "com.example.nolabel")
    }

    func testEmptyPlaceholderPlistIsSkipped() {
        // Google ships empty `<dict/>` plists to block Keystone; they are not jobs.
        XCTAssertNil(LaunchdService.parsePlist([:], path: dir + "/com.google.keystone.agent.plist"))
    }

    func testSessionTypeLimits() throws {
        XCTAssertTrue(LaunchdService.loadsInGUISession(nil))
        XCTAssertTrue(LaunchdService.loadsInGUISession("Aqua"))
        XCTAssertTrue(LaunchdService.loadsInGUISession(["Aqua", "Background", "LoginWindow", "StandardIO", "System"]))
        XCTAssertFalse(LaunchdService.loadsInGUISession("LoginWindow"))
        XCTAssertFalse(LaunchdService.loadsInGUISession(["Background"]))
        let prelogin: [String: Any] = ["Label": "com.realvnc.rvncserver.prelogin", "ProgramArguments": ["/x/rvncagent", "service"],
                                       "LimitLoadToSessionType": "LoginWindow", "RunAtLoad": true]
        XCTAssertFalse(try XCTUnwrap(LaunchdService.parsePlist(prelogin, path: "/Library/LaunchAgents/p.plist")).loadsInGUISession)
    }

    func testDisabledKey() throws {
        let plist: [String: Any] = ["Label": "com.example.off", "Program": "/bin/true", "Disabled": true]
        XCTAssertTrue(try XCTUnwrap(LaunchdService.parsePlist(plist, path: dir + "/off.plist")).disabledInPlist)
    }

    func testKeepAliveInterpretation() {
        XCTAssertTrue(LaunchdService.keepAliveValue(true))
        XCTAssertFalse(LaunchdService.keepAliveValue(false))
        XCTAssertTrue(LaunchdService.keepAliveValue(["SuccessfulExit": false]))
        XCTAssertTrue(LaunchdService.keepAliveValue(["NetworkState": true, "Crashed": true]))
        XCTAssertFalse(LaunchdService.keepAliveValue([String: Any]()))
        XCTAssertTrue(LaunchdService.keepAliveValue(NSNumber(value: 1)))
        XCTAssertFalse(LaunchdService.keepAliveValue("yes"))
        XCTAssertFalse(LaunchdService.keepAliveValue(nil))
    }

    func testBinaryAndXMLPlistData() throws {
        let plist: [String: Any] = [
            "Label": "homebrew.mxcl.redis",
            "ProgramArguments": ["/opt/homebrew/opt/redis/bin/redis-server", "/opt/homebrew/etc/redis.conf"],
            "KeepAlive": ["SuccessfulExit": false],
            "RunAtLoad": true,
        ]
        for format in [PropertyListSerialization.PropertyListFormat.binary, .xml] {
            let data = try PropertyListSerialization.data(fromPropertyList: plist, format: format, options: 0)
            let info = try XCTUnwrap(LaunchdService.parsePlist(data: data, path: dir + "/homebrew.mxcl.redis.plist"))
            XCTAssertEqual(info.label, "homebrew.mxcl.redis")
            XCTAssertTrue(info.keepAlive)
            XCTAssertTrue(info.runAtLoad)
            XCTAssertEqual(info.command, "/opt/homebrew/opt/redis/bin/redis-server /opt/homebrew/etc/redis.conf")
        }
    }

    func testInvalidPlistDataIsRejected() {
        XCTAssertNil(LaunchdService.parsePlist(data: Data("not a plist".utf8), path: dir + "/bad.plist"))
        let arrayPlist = try? PropertyListSerialization.data(fromPropertyList: ["a"], format: .xml, options: 0)
        XCTAssertNil(LaunchdService.parsePlist(data: arrayPlist ?? Data(), path: dir + "/array.plist"))
    }

    func testReadPlistRejectsMissingFile() {
        XCTAssertNil(LaunchdService.readPlist(at: "/nonexistent/app.portpilot.test.plist"))
    }

    func testCommandSummaryQuoting() {
        XCTAssertEqual(LaunchdService.commandSummary(program: nil, arguments: ["/bin/zsh", "-lc", "cd '/a b' && npm start"]),
                       "/bin/zsh -lc \"cd '/a b' && npm start\"")
        XCTAssertEqual(LaunchdService.commandSummary(program: nil, arguments: []), "")
        XCTAssertEqual(LaunchdService.commandSummary(program: "/bin/x", arguments: []), "/bin/x")
    }

    func testSharedAgentFlag() {
        func item(_ path: String) -> StartupItem {
            StartupItem(label: "x", plistPath: path, command: "", workingDirectory: nil, runAtLoad: false,
                        keepAlive: false, isDisabled: false, isLoaded: false, pid: nil, lastExitStatus: nil, ports: [])
        }
        XCTAssertTrue(item("/Library/LaunchAgents/com.adobe.ccxprocess.plist").isSharedAgent)
        XCTAssertFalse(item("/Users/me/Library/LaunchAgents/com.claude.monitor.plist").isSharedAgent)
    }
}

// MARK: - Docker

final class DockerParsingTests: XCTestCase {
    func testHostPortsVariants() {
        XCTAssertEqual(DockerService.parseHostPorts("0.0.0.0:5432->5432/tcp, :::5432->5432/tcp"), [5432])
        XCTAssertEqual(DockerService.parseHostPorts("[::]:8080->80/tcp"), [8080])
        XCTAssertEqual(DockerService.parseHostPorts("127.0.0.1:8000-8002->8000-8002/tcp"), [8000, 8001, 8002])
        XCTAssertEqual(DockerService.parseHostPorts("6379/tcp"), [])
        XCTAssertEqual(DockerService.parseHostPorts("0.0.0.0:53->53/udp, 0.0.0.0:8443->443/tcp"), [8443])
        XCTAssertEqual(DockerService.parseHostPorts("0.0.0.0:3000->3000/tcp, 0.0.0.0:3001->3001/tcp, 9229/tcp"), [3000, 3001])
        XCTAssertEqual(DockerService.parseHostPorts(""), [])
        XCTAssertEqual(DockerService.parseHostPorts("0.0.0.0:1-65535->1-65535/tcp"), [], "huge ranges are ignored")
        XCTAssertEqual(DockerService.parseHostPorts("0.0.0.0:99999->80/tcp"), [], "out-of-range port")
    }

    private let psOutput = """
    {"Command":"\\"docker-entrypoint.s…\\"","CreatedAt":"2026-10-01 10:00:00 +0200 CEST","ID":"3f2a1b4c5d6e","Image":"postgres:16","Labels":"","LocalVolumes":"1","Mounts":"pgdata","Names":"db","Networks":"bridge","Ports":"0.0.0.0:5433->5432/tcp, [::]:5433->5432/tcp","RunningFor":"2 hours ago","Size":"0B","State":"running","Status":"Up 2 hours"}
    {"ID":"9a8b7c6d5e4f","Image":"redis:7","Names":"cache,app/redis","Ports":"6379/tcp","State":"running"}
    {"ID":"0011aabbccdd","Image":"nginx:latest","Names":"web","Ports":"127.0.0.1:8080->80/tcp, 127.0.0.1:5433->5432/tcp"}
    Cannot connect to the Docker daemon? (noise line)
    {"Names":"no-id"}

    """

    func testParsePSOutput() {
        let entries = DockerService.parsePSOutput(psOutput)
        XCTAssertEqual(entries, [
            DockerPSEntry(id: "3f2a1b4c5d6e", name: "db", image: "postgres:16", hostPorts: [5433]),
            DockerPSEntry(id: "9a8b7c6d5e4f", name: "cache", image: "redis:7", hostPorts: []),
            DockerPSEntry(id: "0011aabbccdd", name: "web", image: "nginx:latest", hostPorts: [8080, 5433]),
        ])
    }

    func testInspectRestartPolicies() {
        let output = """
        3f2a1b4c5d6e00000000000000000000000000000000000000000000000000aa unless-stopped
        9a8b7c6d5e4f00000000000000000000000000000000000000000000000000bb \("")
        0011aabbccdd00000000000000000000000000000000000000000000000000cc always
        Error: No such object: gone
        """
        let policies = DockerService.parseInspectRestartPolicies(output)
        XCTAssertEqual(policies.count, 3)
        XCTAssertEqual(policies["3f2a1b4c5d6e00000000000000000000000000000000000000000000000000aa"], "unless-stopped")
        XCTAssertEqual(policies["9a8b7c6d5e4f00000000000000000000000000000000000000000000000000bb"], "no")
        XCTAssertEqual(policies["0011aabbccdd00000000000000000000000000000000000000000000000000cc"], "always")
    }

    func testPortMapJoinsPoliciesByIDPrefixAndFirstContainerWins() {
        let entries = DockerService.parsePSOutput(psOutput)
        let policies = [
            "3f2a1b4c5d6e00000000000000000000000000000000000000000000000000aa": "unless-stopped",
            "0011aabbccdd00000000000000000000000000000000000000000000000000cc": "always",
        ]
        let map = DockerService.portMap(entries: entries, restartPolicies: policies)
        XCTAssertEqual(Set(map.keys), [5433, 8080])
        XCTAssertEqual(map[5433], DockerContainer(id: "3f2a1b4c5d6e", name: "db", image: "postgres:16", restartPolicy: "unless-stopped"))
        XCTAssertEqual(map[8080], DockerContainer(id: "0011aabbccdd", name: "web", image: "nginx:latest", restartPolicy: "always"))
        XCTAssertNil(DockerService.portMap(entries: entries, restartPolicies: [:])[5433]?.restartPolicy)
    }

    func testDockerBackendDetection() {
        func basic(_ comm: String) -> ProcessBasic {
            ProcessBasic(pid: 100, ppid: 1, pgid: 100, uid: 501, comm: comm, startTime: 0)
        }
        func details(_ path: String?, _ args: [String]) -> ProcessDetails {
            ProcessDetails(identity: ProcessIdentity(pid: 100, startTime: 0), executablePath: path,
                           arguments: args, environment: [:], cwd: nil)
        }
        XCTAssertTrue(DockerService.isDockerBackend(basic("com.docker.backe"), details: nil), "truncated p_comm")
        XCTAssertTrue(DockerService.isDockerBackend(basic("com.docker.backend"), details: nil))
        XCTAssertTrue(DockerService.isDockerBackend(basic("vpnkit-bridge"), details: nil))
        XCTAssertTrue(DockerService.isDockerBackend(basic("OrbStack Helper"), details: nil))
        XCTAssertTrue(DockerService.isDockerBackend(basic("gvproxy"), details: nil))
        XCTAssertTrue(DockerService.isDockerBackend(
            basic("backend"),
            details: details("/Applications/Docker.app/Contents/MacOS/com.docker.backend", ["com.docker.backend"])))
        XCTAssertTrue(DockerService.isDockerBackend(
            basic("ssh"), details: details("/usr/bin/ssh", ["ssh: /Users/me/.colima/_lima/colima/ssh.sock [mux]"])))
        XCTAssertTrue(DockerService.isDockerBackend(
            basic("limactl"), details: details("/opt/homebrew/bin/limactl", ["limactl", "hostagent", "--pidfile", "x", "default"])))
        XCTAssertFalse(DockerService.isDockerBackend(basic("ssh"), details: details("/usr/bin/ssh", ["/usr/bin/ssh", "-N", "dgx-vnc"])))
        XCTAssertFalse(DockerService.isDockerBackend(basic("limactl"), details: details("/opt/homebrew/bin/limactl", ["limactl", "list"])))
        XCTAssertFalse(DockerService.isDockerBackend(basic("node"), details: nil))
        XCTAssertFalse(DockerService.isDockerBackend(basic("com.docker"), details: nil), "short prefix must not match")
    }

    func testContainerReferenceValidation() {
        XCTAssertTrue(DockerService.isValidContainerReference("3f2a1b4c5d6e"))
        XCTAssertTrue(DockerService.isValidContainerReference("my_db.1-x"))
        XCTAssertFalse(DockerService.isValidContainerReference("--rm"))
        XCTAssertFalse(DockerService.isValidContainerReference(""))
        XCTAssertFalse(DockerService.isValidContainerReference("a b"))
        XCTAssertFalse(DockerService.isValidContainerReference("é"))
    }
}

// MARK: - PM2

final class PM2ParsingTests: XCTestCase {
    func testJListWithLeadingWarnings() {
        let output = """
        >>>> In-memory PM2 is out-of-date, do:
        >>>> $ pm2 update
        In memory PM2 version: 5.3.0
        Local PM2 version: 5.4.3
        [PM2][WARN] Current process list is not synchronized with saved list. Type 'pm2 save' to synchronize.
        [{"pid":4242,"name":"api","pm2_env":{"pm_id":0,"status":"online","NOTE":"has ] and [ in a string"},"pm_id":0,"monit":{"memory":1024,"cpu":1}},{"pid":0,"name":"worker","pm2_env":{"pm_id":1,"status":"stopped"},"pm_id":1},{"pid":4343,"name":"web","pm2_env":{"pm_id":2,"status":"online"}}]
        [PM2][WARN] trailing noise ]
        """
        let processes = PM2Service.parseJList(output)
        XCTAssertEqual(processes, [
            PM2Process(id: 0, name: "api", pid: 4242, status: "online"),
            PM2Process(id: 1, name: "worker", pid: 0, status: "stopped"),
            PM2Process(id: 2, name: "web", pid: 4343, status: "online"),
        ])
    }

    func testJListEmptyAndGarbage() {
        XCTAssertEqual(PM2Service.parseJList("[]"), [])
        XCTAssertEqual(PM2Service.parseJList("[]\n"), [])
        XCTAssertEqual(PM2Service.parseJList(""), [])
        XCTAssertEqual(PM2Service.parseJList("[PM2] Spawning PM2 daemon"), [])
        XCTAssertEqual(PM2Service.parseJList("[{\"name\":\"no id\"}]"), [])
    }

    func testMatchingBracket() {
        let bytes = Array(#"[1,"]",{"a":[2]}] tail]"#.utf8)
        XCTAssertEqual(PM2Service.matchingBracket(in: bytes, from: 0), 16)
        XCTAssertNil(PM2Service.matchingBracket(in: Array("[1,2".utf8), from: 0))
    }

    func testDaemonDetection() {
        let node = ProcessBasic(pid: 79220, ppid: 1, pgid: 79220, uid: 501, comm: "node", startTime: 0)
        func details(_ args: [String]) -> ProcessDetails {
            ProcessDetails(identity: node.identity, executablePath: "/opt/homebrew/Cellar/node/24.0.0/bin/node",
                           arguments: args, environment: [:], cwd: nil)
        }
        XCTAssertTrue(PM2Service.isDaemon(node, details: details(["PM2 v5.4.3: God Daemon (/Users/me/.pm2)"])))
        XCTAssertFalse(PM2Service.isDaemon(node, details: details(["node", "/opt/homebrew/bin/pm2", "jlist"])))
        XCTAssertFalse(PM2Service.isDaemon(node, details: details(["node", "/Users/me/app/server.js"])))
        XCTAssertFalse(PM2Service.isDaemon(node, details: nil))
        let titled = ProcessBasic(pid: 1, ppid: 1, pgid: 1, uid: 501, comm: "PM2 v6.0.0: God Daemon (/x/.pm2)", startTime: 0)
        XCTAssertTrue(PM2Service.isDaemon(titled, details: nil))
    }

    func testNoDaemonMeansNoProcessesAndNoSubprocess() {
        let service = PM2Service(pm2Home: "/nonexistent/app.portpilot.tests/.pm2")
        XCTAssertFalse(service.isDaemonRunning())
        XCTAssertTrue(service.processesByPID().isEmpty)
        XCTAssertThrowsError(try service.stop(id: 0))
    }
}

// MARK: - Shell

final class ShellServiceTests: XCTestCase {
    func testAppleScriptStringLiteralEscaping() {
        XCTAssertEqual(Shell.appleScriptStringLiteral(#"kill -TERM 123"#), #""kill -TERM 123""#)
        XCTAssertEqual(Shell.appleScriptStringLiteral(#"a"b\c"#), #""a\"b\\c""#)
        XCTAssertEqual(Shell.appleScriptStringLiteral(""), #""""#)
        XCTAssertEqual(Shell.doShellScript(#"echo "hi""#, administrator: true),
                       #"do shell script "echo \"hi\"" with administrator privileges"#)
        XCTAssertEqual(Shell.doShellScript("true", administrator: false), #"do shell script "true""#)
    }

    func testMergePATHDedupesKeepsOrderAndDropsRelativeEntries() {
        let merged = Shell.mergePATH([["/a", "/b/", "relative", ".", "~/bin", ""], ["/a", "/c", "/b"]],
                                     homeDirectory: "/Users/me")
        XCTAssertEqual(merged, "/a:/b:/Users/me/bin:/c")
    }

    func testParseLoginShellPATH() {
        XCTAssertEqual(Shell.parseLoginShellPATH("Welcome!\n\(Shell.pathMarker)/opt/homebrew/bin:/usr/bin"),
                       "/opt/homebrew/bin:/usr/bin")
        XCTAssertEqual(Shell.parseLoginShellPATH("\(Shell.pathMarker)/old\n\(Shell.pathMarker)/new:/bin\n"), "/new:/bin")
        XCTAssertEqual(Shell.parseLoginShellPATH("/usr/bin:/bin"), "/usr/bin:/bin")
        XCTAssertNil(Shell.parseLoginShellPATH("zsh: command not found: foo"))
        XCTAssertNil(Shell.parseLoginShellPATH(""))
    }

    func testFindExecutable() {
        let existing: Set<String> = ["/opt/homebrew/bin/pm2", "/usr/bin/pm2"]
        let found = Shell.findExecutable("pm2", searchPath: "/nope:/opt/homebrew/bin:/usr/bin",
                                         isExecutable: { existing.contains($0) })
        XCTAssertEqual(found, "/opt/homebrew/bin/pm2")
        XCTAssertNil(Shell.findExecutable("docker", searchPath: "/opt/homebrew/bin", isExecutable: { existing.contains($0) }))
        XCTAssertNil(Shell.findExecutable("../pm2", searchPath: "/usr/bin", isExecutable: { _ in true }))
    }

    func testRunCapturesStdoutStderrAndStatus() {
        let result = Shell.run("/bin/sh", ["-c", "echo out; echo err 1>&2; exit 3"])
        XCTAssertEqual(result.status, 3)
        XCTAssertFalse(result.ok)
        XCTAssertEqual(result.stdout, "out\n")
        XCTAssertEqual(result.stderr, "err\n")
        XCTAssertEqual(result.message, "err")
    }

    func testRunLargeOutputDoesNotDeadlock() {
        let result = Shell.run("/bin/sh", ["-c", "head -c 2000000 /dev/zero | tr '\\0' a; head -c 1000000 /dev/zero | tr '\\0' b 1>&2"],
                               timeout: 20)
        XCTAssertTrue(result.ok)
        XCTAssertEqual(result.stdout.utf8.count, 2_000_000)
        XCTAssertEqual(result.stderr.utf8.count, 1_000_000)
    }

    func testRunTimeoutKillsChild() {
        let start = Date()
        let result = Shell.run("/bin/sleep", ["10"], timeout: 0.3)
        XCTAssertEqual(result.status, Shell.timeoutStatus)
        XCTAssertLessThan(Date().timeIntervalSince(start), 3)
    }

    func testRunMissingExecutableAndTool() {
        XCTAssertEqual(Shell.run("/nonexistent/app.portpilot.tool", []).status, Shell.notFoundStatus)
        XCTAssertEqual(Shell.runTool("app-portpilot-definitely-missing-tool", []).status, Shell.notFoundStatus)
        XCTAssertNil(Shell.which("app-portpilot-definitely-missing-tool"))
    }

    func testRunUsesNullStdinEnvironmentAndDirectory() {
        XCTAssertEqual(Shell.run("/bin/cat", [], timeout: 5).stdout, "", "stdin must be /dev/null, not inherited")
        XCTAssertEqual(Shell.run("/usr/bin/env", [], environment: ["PORTPILOT_TEST": "1"]).stdout, "PORTPILOT_TEST=1\n")
        XCTAssertEqual(Shell.run("/bin/pwd", [], currentDirectory: "/usr").stdout, "/usr\n")
    }
}
