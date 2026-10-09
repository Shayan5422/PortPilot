import XCTest
@testable import PortPilot

/// Process fixtures shared by the classifier and listener-builder tests.
struct ClassifierFixture {
    var basic: ProcessBasic
    var details: ProcessDetails?

    static let uid: UInt32 = 501

    init(pid: Int32, ppid: Int32 = 1, uid: UInt32 = ClassifierFixture.uid, comm: String? = nil, executable: String?,
         arguments: [String] = [], environment: [String: String] = [:], cwd: String? = "/", readable: Bool = true) {
        let name = comm ?? executable.map { String(($0 as NSString).lastPathComponent.prefix(16)) } ?? "?"
        basic = ProcessBasic(pid: pid, ppid: ppid, pgid: pid, uid: uid, comm: name, startTime: UInt64(pid) * 1_000)
        details = readable
            ? ProcessDetails(identity: basic.identity, executablePath: executable,
                             arguments: arguments.isEmpty ? [executable ?? name] : arguments,
                             environment: environment, cwd: cwd)
            : nil
    }
}

final class ClassifierTests: XCTestCase {
    private let uid = ClassifierFixture.uid
    private let pythonFramework =
        "/opt/homebrew/Cellar/python@3.12/3.12.12/Frameworks/Python.framework/Versions/3.12/Resources/Python.app/Contents/MacOS/Python"
    private let project = ProjectInfo(rootPath: "/Users/test/code/app", name: "app", subpath: nil, markers: [".git"])

    private func category(_ fixture: ClassifierFixture, project: ProjectInfo? = nil) -> ListenerCategory {
        Classifier.category(basic: fixture.basic, details: fixture.details, project: project, manager: .none,
                            currentUID: uid)
    }

    private func label(_ executable: String?, _ arguments: [String], comm: String? = nil) -> String {
        let fixture = ClassifierFixture(pid: 10, comm: comm, executable: executable, arguments: arguments)
        return Classifier.displayName(basic: fixture.basic, details: fixture.details)
    }

    private func frameworks(_ executable: String?, _ arguments: [String]) -> [String] {
        let fixture = ClassifierFixture(pid: 10, executable: executable, arguments: arguments)
        return Classifier.frameworks(details: fixture.details, comm: fixture.basic.comm)
    }

    // MARK: Category

    func testCategories() {
        XCTAssertEqual(category(ClassifierFixture(pid: 709, executable: "/usr/libexec/rapportd")), .system)
        XCTAssertEqual(category(ClassifierFixture(pid: 88, uid: 0, executable: "/usr/sbin/httpd")), .system)
        XCTAssertEqual(category(ClassifierFixture(pid: 89, uid: 0, executable: nil, readable: false)), .system)
        XCTAssertEqual(category(ClassifierFixture(pid: 90, comm: "rapportd", executable: nil, readable: false)), .system)
        XCTAssertEqual(category(ClassifierFixture(pid: 91, comm: "mystery", executable: nil, readable: false)), .service)
        XCTAssertEqual(category(ClassifierFixture(pid: 92, executable: "/Applications/Player.app/Contents/MacOS/Player")), .app)
        XCTAssertEqual(category(ClassifierFixture(
            pid: 93, executable: "/Applications/Visual Studio Code.app/Contents/Frameworks/Code Helper (Plugin).app/Contents/MacOS/Code Helper (Plugin)")), .app)
        XCTAssertEqual(category(ClassifierFixture(pid: 94, executable: "/Applications/Postgres.app/Contents/Versions/16/bin/postgres")),
                       .service, "servers shipped in an app bundle are services")
        XCTAssertEqual(category(ClassifierFixture(pid: 95, executable: pythonFramework, arguments: ["Python", "-m", "http.server"])),
                       .service, "a runtime inside Python.framework is not an app")
        XCTAssertEqual(category(ClassifierFixture(pid: 96, executable: "/opt/homebrew/opt/redis/bin/redis-server")), .service)
        XCTAssertEqual(category(ClassifierFixture(pid: 97, executable: "/opt/homebrew/bin/node"), project: project), .project)
        XCTAssertEqual(category(ClassifierFixture(pid: 98, executable: "/usr/bin/python3"), project: project), .project,
                       "dev runtimes in /usr/bin are not system processes")
        XCTAssertEqual(category(ClassifierFixture(pid: 99, executable: "/usr/sbin/sshd"), project: project), .system)
    }

    func testAppBundleUsesOutermostBundle() {
        let bundle = Classifier.appBundle(
            forExecutable: "/Applications/Imaginary Studio.app/Contents/Frameworks/Imaginary Helper (Plugin).app/Contents/MacOS/Imaginary Helper (Plugin)")
        XCTAssertEqual(bundle?.bundlePath, "/Applications/Imaginary Studio.app")
        XCTAssertEqual(bundle?.name, "Imaginary Studio")
        XCTAssertNil(Classifier.appBundle(forExecutable: "/opt/homebrew/bin/node"))
    }

    // MARK: Labels

    func testDisplayNames() {
        let node = "/opt/homebrew/bin/node"
        XCTAssertEqual(label(node, ["node", "/p/frontend/node_modules/vite/bin/vite.js", "--host", "127.0.0.1"]), "vite")
        XCTAssertEqual(label(node, ["node", "/p/node_modules/.bin/next", "dev", "-p", "3000"]), "next dev")
        XCTAssertEqual(label(node, ["node", "/p/node_modules/@nestjs/cli/bin/nest.js", "start", "--watch"]), "nest start")
        XCTAssertEqual(label(node, ["node", "server.js"]), "node server.js")
        XCTAssertEqual(label(node, ["node", "--watch", "--env-file", ".env", "/p/src/index.mjs"]), "node index.mjs")
        XCTAssertEqual(label(node, ["next-server (v15.0.3)", "", ""]), "next-server")
        XCTAssertEqual(label(pythonFramework, ["Python", "-m", "uvicorn", "app.main:app", "--host", "127.0.0.1", "--port", "8000"]),
                       "uvicorn app.main:app")
        XCTAssertEqual(label(pythonFramework, ["Python", "app.py"]), "python app.py")
        XCTAssertEqual(label("/usr/bin/python3", ["python3", "-m", "http.server", "8000"]), "python -m http.server")
        XCTAssertEqual(label(pythonFramework, ["python", "/p/.venv/bin/gunicorn", "-w", "4", "-b", "0.0.0.0:8000", "app:create_app()"]),
                       "gunicorn app:create_app()")
        XCTAssertEqual(label(pythonFramework, ["python", "manage.py", "runserver", "0.0.0.0:8000"]), "manage.py runserver")
        XCTAssertEqual(label(pythonFramework, ["python", "-m", "flask", "run", "--debug"]), "flask run")
        XCTAssertEqual(label(pythonFramework, ["python", "-c", "from multiprocessing.spawn import spawn_main"]), "python worker")
        XCTAssertEqual(label("/opt/homebrew/bin/nginx", ["nginx: master process /opt/homebrew/bin/nginx -c /x/nginx.conf", "", ""]), "nginx")
        XCTAssertEqual(label("/opt/homebrew/bin/nginx", ["nginx: worker process", ""]), "nginx worker")
        XCTAssertEqual(label("/opt/homebrew/bin/cloudflared", ["cloudflared", "tunnel", "run", "--token-file", "/x"]), "cloudflared tunnel")
        XCTAssertEqual(label("/opt/homebrew/opt/postgresql@16/bin/postgres", ["postgres", "-D", "/opt/homebrew/var/postgresql@16"]), "postgres")
        XCTAssertEqual(label("/opt/homebrew/opt/redis/bin/redis-server", ["redis-server 127.0.0.1:6379", ""]), "redis-server")
        XCTAssertEqual(label("/Users/test/.bun/bin/bun", ["bun", "run", "dev"]), "bun run dev")
        XCTAssertEqual(label("/usr/bin/java", ["java", "-Xmx1g", "-jar", "/p/target/app-0.1.jar"]), "java -jar app-0.1.jar")
        XCTAssertEqual(label("/opt/homebrew/bin/php", ["php", "-S", "localhost:8080", "-t", "public"]), "php -S localhost:8080")
        XCTAssertEqual(label(nil, [], comm: "launchd"), "launchd")
        let unreadable = ClassifierFixture(pid: 5, comm: "secretd", executable: nil, readable: false)
        XCTAssertEqual(Classifier.displayName(basic: unreadable.basic, details: nil), "secretd")
    }

    func testFrameworks() {
        let node = "/opt/homebrew/bin/node"
        XCTAssertEqual(frameworks(node, ["node", "/p/node_modules/vite/bin/vite.js"]), ["Vite"])
        XCTAssertEqual(frameworks(node, ["next-server (v14.2.1)"]), ["Next.js"])
        XCTAssertEqual(frameworks(node, ["node", "/p/node_modules/@angular/cli/bin/ng.js", "serve"]), ["Angular"])
        XCTAssertEqual(frameworks(node, ["node", "server.js"]), ["Node.js"])
        XCTAssertEqual(frameworks(node, ["node", "/p/next.js"]), ["Node.js"], "user scripts are not mistaken for tools")
        XCTAssertEqual(frameworks(pythonFramework, ["Python", "-m", "uvicorn", "main:app"]), ["uvicorn"])
        XCTAssertEqual(frameworks(pythonFramework, ["python", "manage.py", "runserver"]), ["Django"])
        XCTAssertEqual(frameworks(pythonFramework, ["python", "/p/.venv/bin/streamlit", "run", "app.py"]), ["Streamlit"])
        XCTAssertEqual(frameworks(pythonFramework, ["python", "app.py"]), ["Python"])
        XCTAssertEqual(frameworks("/opt/homebrew/opt/postgresql@16/bin/postgres", ["postgres"]), ["PostgreSQL"])
        XCTAssertEqual(frameworks("/opt/homebrew/bin/nginx", ["nginx: worker process"]), ["nginx"])
        XCTAssertEqual(frameworks("/Users/test/code/svc/target/debug/svc", ["./target/debug/svc"]), ["Rust"])
        XCTAssertEqual(frameworks("/Users/test/.bun/bin/bun", ["bun", "run", "dev"]), ["Bun"])
        XCTAssertEqual(frameworks("/usr/bin/java", ["java", "-jar", "spring-boot-app.jar"]), ["Spring"])
        XCTAssertEqual(frameworks("/Applications/Player.app/Contents/MacOS/Player", ["Player"]), [])
    }

    // MARK: Origin

    func testOriginFromNearestRecognizedAncestor() {
        let claude = ClassifierFixture(pid: 50, comm: "claude",
                                       executable: "/Users/test/Library/Application Support/Claude/claude-code/2.1/claude.app/Contents/MacOS/claude")
        let shell = ClassifierFixture(pid: 51, ppid: 50, executable: "/bin/zsh", arguments: ["/bin/zsh", "-c", "python app.py"])
        let server = ClassifierFixture(pid: 52, ppid: 51, executable: pythonFramework, arguments: ["Python", "app.py"],
                                       environment: ["TERM_PROGRAM": "Apple_Terminal"])
        let lookup = [claude, shell].reduce(into: [Int32: ProcessDetails]()) { $0[$1.basic.pid] = $1.details }
        let origin = Classifier.origin(details: server.details, ancestors: [shell.basic, claude.basic],
                                       ancestorDetails: { lookup[$0] }, launchdLabel: nil)
        XCTAssertEqual(origin, LaunchOrigin(kind: .claudeCode, name: "Claude Code"))
    }

    func testOriginFromTerminalAndIDEAncestors() {
        let terminal = ClassifierFixture(pid: 60, executable: "/System/Applications/Utilities/Terminal.app/Contents/MacOS/Terminal")
        let login = ClassifierFixture(pid: 61, ppid: 60, executable: "/usr/bin/login", arguments: ["login", "-pf", "test"])
        let zsh = ClassifierFixture(pid: 62, ppid: 61, executable: "/bin/zsh", arguments: ["-zsh"])
        let lookup = [terminal, login, zsh].reduce(into: [Int32: ProcessDetails]()) { $0[$1.basic.pid] = $1.details }
        XCTAssertEqual(Classifier.origin(details: nil, ancestors: [zsh.basic, login.basic, terminal.basic],
                                         ancestorDetails: { lookup[$0] }, launchdLabel: nil),
                       LaunchOrigin(kind: .terminal, name: "Terminal"))

        let helper = ClassifierFixture(pid: 70, comm: "Code Helper",
                                       executable: "/Applications/Visual Studio Code.app/Contents/Frameworks/Code Helper.app/Contents/MacOS/Code Helper")
        XCTAssertEqual(Classifier.origin(details: nil, ancestors: [helper.basic],
                                         ancestorDetails: { $0 == 70 ? helper.details : nil }, launchdLabel: nil),
                       LaunchOrigin(kind: .ide, name: "VS Code"))
    }

    func testOriginFromEnvironmentWhenReparented() {
        let launchd = ProcessBasic(pid: 1, ppid: 0, pgid: 1, uid: 0, comm: "launchd", startTime: 0)
        func origin(_ environment: [String: String]) -> LaunchOrigin? {
            let fixture = ClassifierFixture(pid: 80, executable: "/opt/homebrew/bin/node", environment: environment)
            return Classifier.origin(details: fixture.details, ancestors: [launchd], ancestorDetails: { _ in nil },
                                     launchdLabel: nil)
        }
        XCTAssertEqual(origin(["CODEX_SHELL": "1", "TERM": "dumb"]), LaunchOrigin(kind: .codex, name: "Codex"))
        XCTAssertEqual(origin(["CLAUDECODE": "1", "TERM_PROGRAM": "vscode"]), LaunchOrigin(kind: .claudeCode, name: "Claude Code"))
        XCTAssertEqual(origin(["TERM_PROGRAM": "iTerm.app"]), LaunchOrigin(kind: .terminal, name: "iTerm2"))
        XCTAssertEqual(origin(["TERM_PROGRAM": "vscode", "__CFBundleIdentifier": "com.todesktop.230313mzl4w4u92"]),
                       LaunchOrigin(kind: .ide, name: "Cursor"))
        XCTAssertEqual(origin(["CODEX_HOME": "/Users/test/.codex"]), nil, "CODEX_HOME alone is user configuration")
        XCTAssertNil(origin([:]))
    }

    func testLaunchdLabelWinsUnlessItIsAnAppInstance() {
        let fixture = ClassifierFixture(pid: 81, executable: "/opt/homebrew/bin/node", environment: ["CLAUDECODE": "1"])
        XCTAssertEqual(Classifier.origin(details: fixture.details, ancestors: [], ancestorDetails: { _ in nil },
                                         launchdLabel: "com.claude.monitor"),
                       LaunchOrigin(kind: .launchd, name: "launchd"))
        XCTAssertEqual(Classifier.origin(details: fixture.details, ancestors: [], ancestorDetails: { _ in nil },
                                         launchdLabel: "application.com.apple.Terminal.123")?.kind, .claudeCode)
    }

    // MARK: Watchers

    func testWatcherDetection() {
        let node = "/opt/homebrew/bin/node"
        let nodemon = ClassifierFixture(pid: 20, executable: node, arguments: ["node", "/p/node_modules/nodemon/bin/nodemon.js", "server.js"])
        let child = ClassifierFixture(pid: 21, ppid: 20, executable: node, arguments: ["node", "server.js"])
        XCTAssertEqual(Classifier.watcherName(for: child.basic, details: child.details, ancestors: [nodemon.basic],
                                              ancestorDetails: { $0 == 20 ? nodemon.details : nil }), "nodemon")

        let reloader = ClassifierFixture(pid: 30, executable: pythonFramework,
                                         arguments: ["Python", "-m", "uvicorn", "main:app", "--reload"])
        let worker = ClassifierFixture(pid: 31, ppid: 30, executable: pythonFramework,
                                       arguments: ["Python", "-c", "from multiprocessing.spawn import spawn_main"])
        XCTAssertEqual(Classifier.watcherName(for: worker.basic, details: worker.details, ancestors: [reloader.basic],
                                              ancestorDetails: { $0 == 30 ? reloader.details : nil }), "uvicorn --reload")
        XCTAssertEqual(Classifier.watcherName(for: reloader.basic, details: reloader.details, ancestors: [],
                                              ancestorDetails: { _ in nil }), "uvicorn --reload")

        let watchMode = ClassifierFixture(pid: 40, executable: node, arguments: ["node", "--watch", "server.js"])
        XCTAssertEqual(Classifier.watcherName(for: watchMode.basic, details: watchMode.details, ancestors: [],
                                              ancestorDetails: { _ in nil }), "node --watch")

        let tsx = ClassifierFixture(pid: 41, executable: node, arguments: ["node", "/p/node_modules/tsx/dist/cli.mjs", "watch", "src/index.ts"])
        let tsxChild = ClassifierFixture(pid: 42, ppid: 41, executable: node, arguments: ["node", "--import", "tsx", "src/index.ts"])
        XCTAssertEqual(Classifier.watcherName(for: tsxChild.basic, details: tsxChild.details, ancestors: [tsx.basic],
                                              ancestorDetails: { $0 == 41 ? tsx.details : nil }), "tsx watch")

        let django = ClassifierFixture(pid: 43, executable: pythonFramework, arguments: ["python", "manage.py", "runserver"],
                                       environment: ["RUN_MAIN": "true"])
        XCTAssertEqual(Classifier.watcherName(for: django.basic, details: django.details, ancestors: [],
                                              ancestorDetails: { _ in nil }), "Django autoreload")

        // An interactive shell between the server and nodemon means nodemon did not start it.
        let shell = ClassifierFixture(pid: 44, ppid: 20, executable: "/bin/zsh", arguments: ["-zsh"])
        let server = ClassifierFixture(pid: 45, ppid: 44, executable: node, arguments: ["node", "server.js"])
        let lookup = [nodemon, shell].reduce(into: [Int32: ProcessDetails]()) { $0[$1.basic.pid] = $1.details }
        XCTAssertNil(Classifier.watcherName(for: server.basic, details: server.details, ancestors: [shell.basic, nodemon.basic],
                                            ancestorDetails: { lookup[$0] }))
    }

    // MARK: Runtimes, boundaries, runners

    func testDevRuntimes() {
        for name in ["node", "nodejs", "python3", "python3.12", "Python", "bun", "deno", "ruby", "php", "java", "go",
                     "dotnet", "beam.smp", "perl"] {
            XCTAssertTrue(Classifier.isDevRuntime(name: name), name)
        }
        for name in ["nginx", "php-fpm", "postgres", "Spotify", "Code Helper", "zsh", ""] {
            XCTAssertFalse(Classifier.isDevRuntime(name: name), name)
        }
    }

    func testBoundaryProcesses() {
        func isBoundary(_ fixture: ClassifierFixture) -> Bool {
            Classifier.isBoundaryProcess(basic: fixture.basic, details: fixture.details)
        }
        XCTAssertTrue(isBoundary(ClassifierFixture(pid: 1, ppid: 0, uid: 0, executable: "/sbin/launchd")))
        XCTAssertTrue(isBoundary(ClassifierFixture(pid: 10, executable: "/bin/zsh", arguments: ["-zsh"])))
        XCTAssertTrue(isBoundary(ClassifierFixture(pid: 11, executable: "/bin/zsh", arguments: ["/bin/zsh", "-l"])))
        XCTAssertFalse(isBoundary(ClassifierFixture(pid: 12, executable: "/bin/sh", arguments: ["sh", "-c", "vite"])))
        XCTAssertFalse(isBoundary(ClassifierFixture(pid: 13, executable: "/bin/bash", arguments: ["bash", "start.sh"])))
        XCTAssertTrue(isBoundary(ClassifierFixture(pid: 14, comm: "zsh", executable: nil, readable: false)))
        XCTAssertTrue(isBoundary(ClassifierFixture(pid: 15, comm: "claude", executable: "/Users/test/.local/bin/claude")))
        XCTAssertTrue(isBoundary(ClassifierFixture(pid: 16, executable: "/opt/homebrew/bin/node",
                                                   arguments: ["node", "/opt/homebrew/lib/node_modules/@anthropic-ai/claude-code/cli.js"])))
        XCTAssertTrue(isBoundary(ClassifierFixture(pid: 17, executable: "/opt/homebrew/bin/tmux", arguments: ["tmux"])))
        XCTAssertTrue(isBoundary(ClassifierFixture(pid: 18, executable: "/opt/homebrew/bin/node",
                                                   arguments: ["PM2 v5.4.2: God Daemon (/Users/test/.pm2)"])))
        XCTAssertTrue(isBoundary(ClassifierFixture(pid: 19, executable: "/System/Applications/Utilities/Terminal.app/Contents/MacOS/Terminal")))
        XCTAssertTrue(isBoundary(ClassifierFixture(pid: 20, executable: "/Applications/Cursor.app/Contents/MacOS/Cursor")))
        XCTAssertTrue(isBoundary(ClassifierFixture(pid: 21, executable: "/usr/bin/ssh", arguments: ["ssh", "prod"])))
        XCTAssertFalse(isBoundary(ClassifierFixture(pid: 22, executable: "/usr/bin/ssh", arguments: ["ssh", "-N", "-L", "5432:db:5432", "bastion"])))
        XCTAssertFalse(isBoundary(ClassifierFixture(pid: 23, executable: "/Applications/Player.app/Contents/MacOS/Player")))
        XCTAssertFalse(isBoundary(ClassifierFixture(pid: 24, executable: "/opt/homebrew/bin/node",
                                                    arguments: ["node", "/p/node_modules/vite/bin/vite.js"])))
        XCTAssertTrue(isBoundary(ClassifierFixture(pid: 25, executable: "/usr/bin/vim", arguments: ["vim", "x"])))
    }

    func testRunnerProcesses() {
        func isRunner(_ executable: String, _ arguments: [String]) -> Bool {
            let fixture = ClassifierFixture(pid: 30, executable: executable, arguments: arguments)
            return Classifier.isRunnerProcess(basic: fixture.basic, details: fixture.details)
        }
        let node = "/opt/homebrew/bin/node"
        XCTAssertTrue(isRunner(node, ["node", "/opt/homebrew/lib/node_modules/npm/bin/npm-cli.js", "run", "dev"]))
        XCTAssertTrue(isRunner(node, ["node", "/p/node_modules/.bin/concurrently", "a", "b"]))
        XCTAssertTrue(isRunner(node, ["node", "/p/node_modules/tsx/dist/cli.mjs", "watch", "src/index.ts"]))
        XCTAssertTrue(isRunner("/opt/homebrew/bin/pnpm", ["pnpm", "dev"]))
        XCTAssertTrue(isRunner("/Users/test/.bun/bin/bun", ["bun", "run", "dev"]))
        XCTAssertFalse(isRunner("/Users/test/.bun/bin/bun", ["bun", "--hot", "server.ts"]))
        XCTAssertTrue(isRunner("/opt/homebrew/bin/deno", ["deno", "task", "dev"]))
        XCTAssertTrue(isRunner("/Users/test/.cargo/bin/cargo", ["cargo", "run", "--release"]))
        XCTAssertTrue(isRunner("/opt/homebrew/bin/go", ["go", "run", "."]))
        XCTAssertTrue(isRunner("/Users/test/.local/bin/uv", ["uv", "run", "main.py"]))
        XCTAssertTrue(isRunner(pythonFramework, ["python", "/Users/test/.local/bin/poetry", "run", "uvicorn", "main:app"]))
        XCTAssertTrue(isRunner("/usr/bin/make", ["make", "dev"]))
        XCTAssertTrue(isRunner("/usr/bin/ruby", ["ruby", "/usr/local/bin/bundle", "exec", "rails", "s"]))
        XCTAssertFalse(isRunner(node, ["node", "/p/node_modules/vite/bin/vite.js"]))
        XCTAssertFalse(isRunner(node, ["node", "server.js"]))
        XCTAssertFalse(isRunner(pythonFramework, ["python", "-m", "uvicorn", "main:app"]))
    }

    func testScriptShells() {
        let script = ClassifierFixture(pid: 31, executable: "/bin/sh", arguments: ["sh", "-c", "vite --port 5173"])
        let interactive = ClassifierFixture(pid: 32, executable: "/bin/zsh", arguments: ["-zsh"])
        XCTAssertTrue(Classifier.isScriptShell(basic: script.basic, details: script.details))
        XCTAssertFalse(Classifier.isScriptShell(basic: interactive.basic, details: interactive.details))
    }
}
