import XCTest
@testable import PortPilot

/// In-memory file tree for resolver tests. Adding a file implicitly creates its parent directories.
/// Build the tree before handing it to a resolver; probes may then run on the resolver's probe queues.
final class ResolverTestFS: @unchecked Sendable {
    private(set) var directories: Set<String> = ["/"]
    private(set) var files: [String: Data] = [:]
    private let lock = NSLock()
    private var probes = 0
    /// Probes under this prefix wait until `releaseBlockedProbes()`, like a pending macOS folder-access prompt.
    private var blockedPrefix: String?
    private var isBlocked = false
    private let gate = DispatchGroup()

    /// Paths probed through `fileExists`, to check caching.
    var probeCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return probes
    }

    func addFile(_ path: String, _ contents: String = "") {
        files[path] = Data(contents.utf8)
        addDirectory(ProjectResolver.parent(of: path))
    }

    func addDirectory(_ path: String) {
        var current = path
        while current != "/", !directories.contains(current) {
            directories.insert(current)
            current = ProjectResolver.parent(of: current)
        }
    }

    /// Makes every probe under `prefix` block until `releaseBlockedProbes()`. Call before using a resolver.
    func blockProbes(under prefix: String) {
        lock.lock()
        defer { lock.unlock() }
        guard !isBlocked else { return }
        blockedPrefix = prefix
        isBlocked = true
        gate.enter()
    }

    /// Lets blocked probes continue. Safe to call more than once.
    func releaseBlockedProbes() {
        lock.lock()
        defer { lock.unlock() }
        guard isBlocked else { return }
        isBlocked = false
        gate.leave()
    }

    private func waitIfBlocked(_ path: String) {
        lock.lock()
        let blocks = isBlocked && blockedPrefix.map { path.hasPrefix($0) } == true
        lock.unlock()
        if blocks { gate.wait() }
    }

    func fileExists(_ path: String) -> Bool {
        waitIfBlocked(path)
        lock.lock()
        probes += 1
        lock.unlock()
        return files[path] != nil || directories.contains(path)
    }

    func readFile(_ path: String) -> Data? {
        waitIfBlocked(path)
        return files[path]
    }

    func listDirectory(_ path: String) -> [String]? {
        waitIfBlocked(path)
        guard directories.contains(path) else { return nil }
        let prefix = path == "/" ? "/" : path + "/"
        var names = Set<String>()
        for entry in Array(files.keys) + Array(directories) where entry.hasPrefix(prefix) && entry != path {
            if let name = entry.dropFirst(prefix.count).split(separator: "/").first { names.insert(String(name)) }
        }
        return names.sorted()
    }

    /// A resolver over this tree. The generous default deadline keeps answers final on a busy machine; the
    /// deadline tests pass a short one.
    func makeResolver(home: String = ResolverTestFS.home, now: @escaping () -> Date = Date.init,
                      probeDeadline: TimeInterval = 10) -> ProjectResolver {
        ProjectResolver(homeDirectory: home,
                        fileExists: { [unowned self] in self.fileExists($0) },
                        readFile: { [unowned self] in self.readFile($0) },
                        listDirectory: { [unowned self] in self.listDirectory($0) },
                        now: now,
                        probeDeadline: probeDeadline)
    }

    static let home = "/Users/test"
}

/// Builds ProcessDetails fixtures.
enum ResolverTestProcess {
    static func details(pid: Int32 = 100, executable: String?, arguments: [String], cwd: String?,
                        environment: [String: String] = [:]) -> ProcessDetails {
        ProcessDetails(identity: ProcessIdentity(pid: pid, startTime: 1), executablePath: executable,
                       arguments: arguments, environment: environment, cwd: cwd)
    }
}

final class ProjectResolverTests: XCTestCase {
    private let home = ResolverTestFS.home

    // MARK: Grouping roots

    func testGitRootGroupsSiblingPackagesUnderRootFolderName() {
        let fs = ResolverTestFS()
        let root = home + "/Downloads/Harbor Notes"
        fs.addDirectory(root + "/.git")
        fs.addFile(root + "/backend/pyproject.toml", "[project]\nname = \"harbor-api\"\n")
        fs.addFile(root + "/frontend/package.json", #"{"name": "harbor-web"}"#)
        let resolver = fs.makeResolver()

        let backend = resolver.project(forDirectory: root + "/backend")
        let frontend = resolver.project(forDirectory: root + "/frontend")
        XCTAssertEqual(backend?.rootPath, root)
        XCTAssertEqual(frontend?.rootPath, root)
        XCTAssertEqual(backend?.name, "Harbor Notes")
        XCTAssertEqual(backend?.subpath, "backend")
        XCTAssertEqual(frontend?.subpath, "frontend")
        XCTAssertEqual(backend?.markers, [".git", "pyproject.toml"])
    }

    func testSiblingManifestRuleWithoutGit() {
        let fs = ResolverTestFS()
        let root = home + "/Downloads/Harbor Notes"
        fs.addFile(root + "/backend/pyproject.toml", "[project]\nname = \"harbor-api\"\n")
        fs.addFile(root + "/frontend/package.json", #"{"name": "harbor-web"}"#)
        let resolver = fs.makeResolver()

        let backend = resolver.project(forDirectory: root + "/backend")
        let frontend = resolver.project(forDirectory: root + "/frontend/src")
        XCTAssertEqual(backend?.rootPath, root)
        XCTAssertEqual(frontend?.rootPath, root)
        XCTAssertEqual(backend?.name, "Harbor Notes")
        XCTAssertEqual(frontend?.subpath, "frontend")
    }

    func testGenericRootFolderIsPrefixedWithParent() {
        let fs = ResolverTestFS()
        let release = home + "/.codex/acme-public-deployment-20261008/release"
        fs.addFile(release + "/README.md")
        fs.addFile(release + "/backend/pyproject.toml", "[project]\nname = \"acme-api\"\n")
        fs.addFile(release + "/frontend/package.json", #"{"name": "acme-web"}"#)
        let info = fs.makeResolver().project(forDirectory: release + "/backend")

        XCTAssertEqual(info?.rootPath, release)
        XCTAssertEqual(info?.name, "acme-public-deployment-20261008/release")
        XCTAssertEqual(info?.subpath, "backend")
        XCTAssertEqual(info?.markers, ["pyproject.toml"])
    }

    func testRootWrappingSinglePackageTakesPackageName() {
        let fs = ResolverTestFS()
        let wrapper = home + "/Downloads/uptime check"
        fs.addDirectory(wrapper + "/.git")
        fs.addFile(wrapper + "/uptime-monitor/package.json", #"{"name": "uptime-monitor", "private": true}"#)
        let info = fs.makeResolver().project(forDirectory: wrapper + "/uptime-monitor")

        XCTAssertEqual(info?.rootPath, wrapper)
        XCTAssertEqual(info?.name, "uptime-monitor")
        XCTAssertEqual(info?.subpath, "uptime-monitor")
    }

    func testWrappedGenericPartKeepsRepositoryName() {
        let fs = ResolverTestFS()
        let repo = home + "/code/shop"
        fs.addDirectory(repo + "/.git")
        fs.addFile(repo + "/backend/pyproject.toml", "[project]\nname = \"shop-api\"\n")
        XCTAssertEqual(fs.makeResolver().project(forDirectory: repo + "/backend")?.name, "shop")
    }

    func testUnrelatedProjectsInPlainFolderStaySeparate() {
        let fs = ResolverTestFS()
        let container = home + "/Downloads/hacks"
        fs.addFile(container + "/PortPilot/Package.swift")
        fs.addFile(container + "/dashboard-kit/package.json", #"{"name": "dashboard-kit"}"#)
        let resolver = fs.makeResolver()

        XCTAssertEqual(resolver.project(forDirectory: container + "/PortPilot")?.rootPath, container + "/PortPilot")
        XCTAssertEqual(resolver.project(forDirectory: container + "/dashboard-kit")?.name, "dashboard-kit")
    }

    func testReadmeOnlyParentKeepsDistinctToolsSeparate() {
        let fs = ResolverTestFS()
        let shop = home + "/Downloads/shop"
        fs.addFile(shop + "/README.md", "# my tools")
        fs.addFile(shop + "/.gitignore")
        fs.addFile(shop + "/.editorconfig")
        fs.addFile(shop + "/shop-api/requirements.txt")
        fs.addFile(shop + "/shop-web/package.json", #"{"name": "shop-web"}"#)
        let resolver = fs.makeResolver()

        let api = resolver.project(forDirectory: shop + "/shop-api")
        XCTAssertEqual(api?.rootPath, shop + "/shop-api", "a README is no reason to merge distinct tools")
        XCTAssertNil(api?.subpath)
        XCTAssertEqual(resolver.project(forDirectory: shop + "/shop-web")?.rootPath, shop + "/shop-web")
        XCTAssertEqual(resolver.project(forDirectory: shop + "/shop-web")?.name, "shop-web")
    }

    func testDistinctSingleSubprojectIsItsOwnRoot() {
        let fs = ResolverTestFS()
        let folder = home + "/Downloads/Pixelpost"
        fs.addFile(folder + "/sunbeam-backend/requirements.txt")
        fs.addFile(folder + "/sunbeam-backend/app.py")
        fs.addFile(folder + "/Sunbeam/project.yml")
        let info = fs.makeResolver().project(forDirectory: folder + "/sunbeam-backend")
        XCTAssertEqual(info?.rootPath, folder + "/sunbeam-backend")
        XCTAssertEqual(info?.name, "sunbeam-backend")
        XCTAssertNil(info?.subpath)
    }

    func testWorkspaceRootWithoutGit() {
        let fs = ResolverTestFS()
        let mono = home + "/code/mono"
        fs.addFile(mono + "/package.json", #"{"name": "mono", "workspaces": ["packages/*"]}"#)
        fs.addFile(mono + "/packages/web/package.json", #"{"name": "@mono/web"}"#)
        let info = fs.makeResolver().project(forDirectory: mono + "/packages/web")
        XCTAssertEqual(info?.rootPath, mono)
        XCTAssertEqual(info?.name, "mono")
        XCTAssertEqual(info?.subpath, "packages/web")
    }

    // MARK: Names

    func testManifestNames() {
        let fs = ResolverTestFS()
        fs.addFile(home + "/code/a/package.json", #"{"name": "storefront"}"#)
        fs.addFile(home + "/code/b/package.json", #"{"name": "@acme/web"}"#)
        fs.addFile(home + "/code/c/package.json", #"{"name": "vite-project"}"#)
        fs.addFile(home + "/code/d/pyproject.toml", "[build-system]\nrequires = []\n\n[tool.poetry]\nname = 'poetry-app'\n")
        fs.addFile(home + "/code/e/Cargo.toml", "[package]\nname = \"rusty\"\nversion = \"0.1.0\"\n")
        fs.addFile(home + "/code/f/Cargo.toml", "[workspace]\nmembers = [\"x\"]\n")
        fs.addFile(home + "/code/g/pyproject.toml", "[tool.black]\nnamespace = 'x'\n[project]\nname = \"api\"\n")
        let resolver = fs.makeResolver()

        XCTAssertEqual(resolver.project(forDirectory: home + "/code/a")?.name, "storefront")
        XCTAssertEqual(resolver.project(forDirectory: home + "/code/b")?.name, "b", "scoped names keep the folder name")
        XCTAssertEqual(resolver.project(forDirectory: home + "/code/c")?.name, "c", "template defaults are generic")
        XCTAssertEqual(resolver.project(forDirectory: home + "/code/d")?.name, "poetry-app")
        XCTAssertEqual(resolver.project(forDirectory: home + "/code/e")?.name, "rusty")
        XCTAssertEqual(resolver.project(forDirectory: home + "/code/f")?.name, "f")
        XCTAssertEqual(resolver.project(forDirectory: home + "/code/g")?.name, "g", "generic manifest names are ignored")
    }

    func testTruncatedPackageJSONStillYieldsName() {
        let fs = ResolverTestFS()
        let padding = String(repeating: "x", count: 300 * 1024)
        fs.addFile(home + "/code/big/package.json", "{\n  \"name\" : \"big-app\",\n  \"blob\": \"\(padding)\"\n}")
        XCTAssertEqual(fs.makeResolver().project(forDirectory: home + "/code/big")?.name, "big-app")
    }

    func testTomlNameParser() {
        let toml = Data("[tool.poetry]\nname=\"spaced\"\n".utf8)
        XCTAssertEqual(ProjectResolver.tomlName(toml, tables: ["tool.poetry"]), "spaced")
        XCTAssertNil(ProjectResolver.tomlName(toml, tables: ["project"]))
    }

    // MARK: Exclusions

    func testHomeAndContainerRootsAreNeverProjects() {
        let fs = ResolverTestFS()
        fs.addFile(home + "/package.json", #"{"name": "dotfiles"}"#)
        fs.addFile(home + "/Downloads/package.json", #"{"name": "stray"}"#)
        fs.addDirectory(home + "/Desktop")
        fs.addDirectory(home + "/Documents")
        let resolver = fs.makeResolver()

        XCTAssertNil(resolver.project(forDirectory: home))
        XCTAssertNil(resolver.project(forDirectory: home + "/"))
        XCTAssertNil(resolver.project(forDirectory: home + "/Downloads"))
        XCTAssertNil(resolver.project(forDirectory: home + "/Desktop"))
        XCTAssertNil(resolver.project(forDirectory: home + "/Documents"))
        XCTAssertNil(resolver.project(forDirectory: "/"))
    }

    func testDotfilesRepositoryInHomeIsIgnored() {
        let fs = ResolverTestFS()
        fs.addDirectory(home + "/.git")
        fs.addFile(home + "/Downloads/notes/serve.py")
        let info = fs.makeResolver().project(forDirectory: home + "/Downloads/notes")
        XCTAssertEqual(info?.rootPath, home + "/Downloads/notes")
        XCTAssertEqual(info?.markers, [])
    }

    func testToolCachesLibraryAndSystemLocationsAreExcluded() {
        let fs = ResolverTestFS()
        fs.addFile(home + "/.npm/_npx/abc123/package.json", #"{"name": "mcp"}"#)
        fs.addFile(home + "/Library/Application Support/uptime-monitor/package.json")
        fs.addFile(home + "/.vscode/extensions/ext/package.json")
        fs.addFile("/opt/homebrew/var/postgresql@16/postgresql.conf")
        fs.addFile("/Applications/Tool.app/Contents/Resources/app/package.json")
        let resolver = fs.makeResolver()

        XCTAssertNil(resolver.project(forDirectory: home + "/.npm/_npx/abc123"))
        XCTAssertNil(resolver.project(forDirectory: home + "/Library/Application Support/uptime-monitor"))
        XCTAssertNil(resolver.project(forDirectory: home + "/.vscode/extensions/ext"))
        XCTAssertNil(resolver.project(forDirectory: "/opt/homebrew/var/postgresql@16"))
        XCTAssertNil(resolver.project(forDirectory: "/Applications/Tool.app/Contents/Resources/app"))
        XCTAssertNil(resolver.project(forDirectory: "/usr/local/lib"))
    }

    func testCodeDirectoriesOutsideHomeNeedMarkers() {
        let fs = ResolverTestFS()
        fs.addFile("/opt/myapp/package.json", #"{"name": "myapp"}"#)
        fs.addDirectory("/opt/empty")
        fs.addDirectory("/Volumes/SSD/code/tool/.git")
        fs.addFile(home + "/Library/Mobile Documents/com~apple~CloudDocs/site/index.html")
        let resolver = fs.makeResolver()

        XCTAssertEqual(resolver.project(forDirectory: "/opt/myapp/src")?.rootPath, "/opt/myapp")
        XCTAssertNil(resolver.project(forDirectory: "/opt/empty"))
        XCTAssertEqual(resolver.project(forDirectory: "/Volumes/SSD/code/tool")?.name, "tool")
        XCTAssertEqual(resolver.project(forDirectory: home + "/Library/Mobile Documents/com~apple~CloudDocs/site")?.name,
                       "site", "iCloud Drive folders behave like home folders")
    }

    // MARK: resolve(details:)

    func testResolveUsesCwdFirst() {
        let fs = ResolverTestFS()
        fs.addFile(home + "/Downloads/uptime check/uptime-monitor/package.json", #"{"name": "uptime-monitor"}"#)
        let details = ResolverTestProcess.details(
            executable: "/opt/homebrew/bin/node",
            arguments: ["/opt/homebrew/bin/node", home + "/Downloads/uptime check/uptime-monitor/server.js"],
            cwd: home + "/Downloads/uptime check/uptime-monitor")
        XCTAssertEqual(fs.makeResolver().resolve(details: details)?.name, "uptime-monitor")
    }

    func testResolveFallsBackToScriptPathAndStripsNodeModules() {
        let fs = ResolverTestFS()
        let app = home + "/code/app"
        fs.addDirectory(app + "/.git")
        fs.addFile(app + "/frontend/package.json", #"{"name": "app-frontend"}"#)
        fs.addFile(app + "/frontend/node_modules/vite/package.json", #"{"name": "vite"}"#)
        fs.addFile(app + "/frontend/node_modules/vite/bin/vite.js")
        let details = ResolverTestProcess.details(
            executable: "/opt/homebrew/bin/node",
            arguments: ["node", app + "/frontend/node_modules/vite/bin/vite.js", "--port", "5173"], cwd: "/")
        let info = fs.makeResolver().resolve(details: details)
        XCTAssertEqual(info?.rootPath, app)
        XCTAssertEqual(info?.subpath, "frontend")
    }

    func testResolveSkipsMissingAndExcludedArguments() {
        let fs = ResolverTestFS()
        fs.addFile(home + "/Library/Application Support/tunnel/config.yml")
        let details = ResolverTestProcess.details(
            executable: "/opt/homebrew/bin/cloudflared",
            arguments: ["cloudflared", "tunnel", "--config", home + "/Library/Application Support/tunnel/config.yml"],
            cwd: home + "/Library/Application Support/tunnel")
        XCTAssertNil(fs.makeResolver().resolve(details: details))
    }

    func testMarkerlessFolderCountsOnlyForRuntimes() {
        let fs = ResolverTestFS()
        fs.addDirectory(home + "/Downloads/Pixelpost/.claude")
        fs.addFile(home + "/Downloads/photos/index.html")
        let resolver = fs.makeResolver()

        let mcp = ResolverTestProcess.details(executable: home + "/.local/bin/codebase-memory-mcp",
                                              arguments: [home + "/.local/bin/codebase-memory-mcp"],
                                              cwd: home + "/Downloads/Pixelpost")
        XCTAssertNil(resolver.resolve(details: mcp), "a native tool that inherited a cwd is not a project")

        let server = ResolverTestProcess.details(executable: "/usr/bin/python3",
                                                 arguments: ["python3", "-m", "http.server", "8000"],
                                                 cwd: home + "/Downloads/photos")
        let info = resolver.resolve(details: server)
        XCTAssertEqual(info?.name, "photos")
        XCTAssertEqual(info?.markers, [])
    }

    func testResolveUsesExecutableInsideProject() {
        let fs = ResolverTestFS()
        fs.addFile(home + "/code/svc/Cargo.toml", "[package]\nname = \"svc\"\n")
        fs.addFile(home + "/code/svc/target/debug/server")
        let details = ResolverTestProcess.details(executable: home + "/code/svc/target/debug/server",
                                                  arguments: ["./target/debug/server"], cwd: "/")
        let info = fs.makeResolver().resolve(details: details)
        XCTAssertEqual(info?.rootPath, home + "/code/svc")
        XCTAssertEqual(info?.name, "svc")
    }

    func testResolveUsesVirtualEnvironment() {
        let fs = ResolverTestFS()
        fs.addFile(home + "/code/api/requirements.txt")
        let details = ResolverTestProcess.details(
            executable: "/opt/homebrew/Cellar/python@3.12/3.12.1/Frameworks/Python.framework/Versions/3.12/Resources/Python.app/Contents/MacOS/Python",
            arguments: ["python", "-m", "uvicorn", "main:app"], cwd: "/",
            environment: ["VIRTUAL_ENV": home + "/code/api/.venv"])
        XCTAssertEqual(fs.makeResolver().resolve(details: details)?.rootPath, home + "/code/api")
    }

    func testGUIApplicationsNeverGetAProject() {
        let fs = ResolverTestFS()
        fs.addDirectory(home + "/code/site/.git")
        let helper = ResolverTestProcess.details(
            executable: "/Applications/Visual Studio Code.app/Contents/Frameworks/Code Helper (Plugin).app/Contents/MacOS/Code Helper (Plugin)",
            arguments: ["Code Helper (Plugin)", "--type=utility"], cwd: home + "/code/site")
        XCTAssertNil(fs.makeResolver().resolve(details: helper))

        let electronDev = ResolverTestProcess.details(
            executable: home + "/code/site/node_modules/electron/dist/Electron.app/Contents/MacOS/Electron",
            arguments: ["Electron", "."], cwd: home + "/code/site")
        XCTAssertEqual(fs.makeResolver().resolve(details: electronDev)?.name, "site",
                       "Electron apps under development belong to their project")
    }

    func testNilDetailsAndRootCwd() {
        let fs = ResolverTestFS()
        let resolver = fs.makeResolver()
        XCTAssertNil(resolver.resolve(details: nil))
        let details = ResolverTestProcess.details(executable: "/usr/libexec/rapportd", arguments: ["rapportd"], cwd: "/")
        XCTAssertNil(resolver.resolve(details: details))
    }

    // MARK: Caching

    func testDirectoryLookupsAreCachedForSixtySeconds() {
        let fs = ResolverTestFS()
        var clock = Date(timeIntervalSince1970: 1_000)
        let resolver = fs.makeResolver(now: { clock })
        let folder = home + "/code/late"
        fs.addFile(folder + "/requirements.txt")

        XCTAssertEqual(resolver.project(forDirectory: folder)?.markers, ["requirements.txt"])
        let probes = fs.probeCount
        fs.addDirectory(folder + "/.git")

        clock += 30
        XCTAssertEqual(resolver.project(forDirectory: folder)?.markers, ["requirements.txt"])
        XCTAssertEqual(fs.probeCount, probes, "cached lookups must not touch the file system")

        clock += 31
        XCTAssertEqual(resolver.project(forDirectory: folder)?.markers, [".git", "requirements.txt"])
    }

    func testConcurrentLookupsAreSafe() {
        let resolver = ProjectResolver(homeDirectory: home, fileExists: { $0.hasSuffix("/code/x/package.json") },
                                       readFile: { _ in Data(#"{"name": "x"}"#.utf8) })
        DispatchQueue.concurrentPerform(iterations: 200) { index in
            let info = resolver.project(forDirectory: home + "/code/x/sub\(index % 7)")
            XCTAssertEqual(info?.name, "x")
        }
    }

    // MARK: Path helpers

    func testPathHelpers() {
        XCTAssertEqual(ProjectResolver.normalize("/a//b/./c/../d/"), "/a/b/d")
        XCTAssertEqual(ProjectResolver.normalize(""), "/")
        XCTAssertEqual(ProjectResolver.parent(of: "/a"), "/")
        XCTAssertEqual(ProjectResolver.strippingDependencyFolders("/u/p/node_modules/.pnpm/vite@5/node_modules/vite/bin"), "/u/p")
        XCTAssertEqual(ProjectResolver.strippingDependencyFolders("/u/p/.venv/bin"), "/u/p")
        XCTAssertEqual(ProjectResolver.strippingDependencyFolders("/u/p/env/bin"), "/u/p")
        XCTAssertEqual(ProjectResolver.strippingDependencyFolders("/u/p/env/config"), "/u/p/env/config")
    }
}

/// Grouping without git: only real evidence (declared workspaces, compose files, generic parts) merges folders.
final class ProjectResolverGroupingTests: XCTestCase {
    private let home = ResolverTestFS.home

    private func node(cwd: String) -> ProcessDetails {
        ResolverTestProcess.details(executable: "/opt/homebrew/bin/node", arguments: ["node", "server.js"], cwd: cwd)
    }

    private func python(cwd: String) -> ProcessDetails {
        ResolverTestProcess.details(executable: "/usr/bin/python3", arguments: ["python3", "-m", "http.server"],
                                    cwd: cwd)
    }

    func testStrayPackageJSONParentKeepsToolsSeparate() {
        let fs = ResolverTestFS()
        let tools = home + "/Downloads/odds-and-ends"
        fs.addFile(tools + "/package.json", #"{"dependencies": {"left-pad": "^1.3.0"}}"#)
        fs.addFile(tools + "/porttool/package.json", #"{"name": "porttool"}"#)
        fs.addFile(tools + "/bunthing/bun.lockb")
        fs.addFile(tools + "/gosvc/go.mod", "module gosvc\n")
        fs.addFile(tools + "/looptool/pyproject.toml", "[project]\nname = \"looptool\"\n")
        fs.addFile(tools + "/loose/serve.py")
        fs.addFile(tools + "/loose/public/index.html")
        let resolver = fs.makeResolver()

        XCTAssertEqual(resolver.resolve(details: node(cwd: tools + "/porttool"))?.rootPath, tools + "/porttool")
        XCTAssertEqual(resolver.resolve(details: node(cwd: tools + "/porttool"))?.name, "porttool")
        XCTAssertEqual(resolver.resolve(details: node(cwd: tools + "/bunthing"))?.rootPath, tools + "/bunthing")
        XCTAssertEqual(resolver.project(forDirectory: tools + "/gosvc")?.rootPath, tools + "/gosvc")
        XCTAssertEqual(resolver.resolve(details: python(cwd: tools + "/looptool"))?.name, "looptool")

        let loose = resolver.resolve(details: python(cwd: tools + "/loose"))
        XCTAssertEqual(loose?.rootPath, tools + "/loose", "a marker-less tool does not adopt a stray package.json")
        XCTAssertEqual(loose?.name, "loose")
        XCTAssertEqual(loose?.markers, [])
        XCTAssertEqual(resolver.resolve(details: python(cwd: tools + "/loose/public"))?.rootPath, tools + "/loose",
                       "sub-folders of a loose tool stay with that tool")
        XCTAssertNil(resolver.resolve(details: ResolverTestProcess.details(
            executable: home + "/.local/bin/mcp-tool", arguments: ["mcp-tool"], cwd: tools + "/loose")),
                     "a native tool that inherited the cwd still has no project")
    }

    func testNamedParentProjectDoesNotAbsorbDistinctChildren() {
        let fs = ResolverTestFS()
        let parent = home + "/Downloads/umbrella"
        fs.addFile(parent + "/package.json", #"{"name": "umbrella", "scripts": {"dev": "vite"}}"#)
        fs.addFile(parent + "/porttool/package.json", #"{"name": "porttool"}"#)
        fs.addFile(parent + "/api/package.json", #"{"name": "umbrella-api"}"#)
        fs.addFile(parent + "/side-script/run.py")
        let resolver = fs.makeResolver()

        XCTAssertEqual(resolver.project(forDirectory: parent + "/porttool")?.rootPath, parent + "/porttool")
        let api = resolver.project(forDirectory: parent + "/api")
        XCTAssertEqual(api?.rootPath, parent, "generic parts still join the project around them")
        XCTAssertEqual(api?.subpath, "api")
        XCTAssertEqual(api?.name, "umbrella")
        XCTAssertEqual(resolver.resolve(details: python(cwd: parent + "/side-script"))?.rootPath,
                       parent + "/side-script", "a folder that holds other projects is a container")
    }

    func testMarkerlessFoldersInsideAProjectStillBelongToIt() {
        let fs = ResolverTestFS()
        let app = home + "/Downloads/myapp"
        fs.addFile(app + "/package.json", #"{"name": "myapp"}"#)
        fs.addFile(app + "/src/server.js")
        fs.addFile(app + "/tooling-x/gen.py")
        fs.addFile(app + "/.build/debug/server")
        let resolver = fs.makeResolver()

        XCTAssertEqual(resolver.resolve(details: node(cwd: app + "/src"))?.rootPath, app)
        XCTAssertEqual(resolver.resolve(details: python(cwd: app + "/tooling-x"))?.rootPath, app,
                       "a lone project keeps its distinctly named sub-folders")
        let binary = ResolverTestProcess.details(executable: app + "/.build/debug/server",
                                                 arguments: ["./.build/debug/server"], cwd: "/")
        XCTAssertEqual(resolver.resolve(details: binary)?.rootPath, app)
        XCTAssertEqual(resolver.resolve(details: binary)?.name, "myapp")
    }

    func testDeclaredWorkspacesGroupTheirPackages() {
        let fs = ResolverTestFS()
        let code = home + "/code"
        fs.addFile(code + "/pn/package.json", #"{"name": "pn"}"#)
        fs.addFile(code + "/pn/pnpm-workspace.yaml", "packages:\n  - 'packages/*'\n")
        fs.addFile(code + "/pn/packages/ui-kit/package.json", #"{"name": "ui-kit"}"#)
        fs.addFile(code + "/rs/Cargo.toml", "[workspace]\nmembers = [\"crates/*\"]\n")
        fs.addFile(code + "/rs/crates/parser/Cargo.toml", "[package]\nname = \"parser\"\n")
        fs.addFile(code + "/gw/go.work", "go 1.22\nuse ./svc-a\n")
        fs.addFile(code + "/gw/svc-a/go.mod", "module svc-a\n")
        fs.addFile(code + "/gr/settings.gradle.kts", "rootProject.name = \"gr\"\ninclude(\":app-core\")\n")
        fs.addFile(code + "/gr/build.gradle.kts")
        fs.addFile(code + "/gr/app-core/build.gradle.kts")
        fs.addFile(code + "/uv/pyproject.toml", "[project]\nname = \"uvroot\"\n[tool.uv.workspace]\nmembers = [\"pkgs/*\"]\n")
        fs.addFile(code + "/uv/pkgs/etl/pyproject.toml", "[project]\nname = \"etl\"\n")
        fs.addFile(code + "/mvn/pom.xml", "<project><modules><module>billing</module></modules></project>")
        fs.addFile(code + "/mvn/billing/pom.xml", "<project/>")
        fs.addFile(code + "/tb/package.json", #"{"name": "tb", "workspaces": {"packages": ["apps/*"]}}"#)
        fs.addFile(code + "/tb/apps/storefront/package.json", #"{"name": "storefront"}"#)
        fs.addFile(code + "/tb/apps/storefront/e2e-suite/package.json", #"{"name": "storefront-e2e"}"#)
        let resolver = fs.makeResolver()

        XCTAssertEqual(resolver.project(forDirectory: code + "/pn/packages/ui-kit")?.rootPath, code + "/pn")
        XCTAssertEqual(resolver.project(forDirectory: code + "/rs/crates/parser")?.rootPath, code + "/rs")
        XCTAssertEqual(resolver.project(forDirectory: code + "/gw/svc-a")?.rootPath, code + "/gw",
                       "go.work declares a workspace without a manifest of its own")
        XCTAssertEqual(resolver.project(forDirectory: code + "/gr/app-core")?.rootPath, code + "/gr")
        XCTAssertEqual(resolver.project(forDirectory: code + "/uv/pkgs/etl")?.rootPath, code + "/uv")
        XCTAssertEqual(resolver.project(forDirectory: code + "/mvn/billing")?.rootPath, code + "/mvn")
        let e2e = resolver.project(forDirectory: code + "/tb/apps/storefront/e2e-suite")
        XCTAssertEqual(e2e?.rootPath, code + "/tb", "nested packages reach the outermost workspace")
        XCTAssertEqual(e2e?.subpath, "apps/storefront/e2e-suite")
        XCTAssertEqual(e2e?.name, "tb")
    }

    func testComposeFileThatBuildsChildrenGroupsThem() {
        let fs = ResolverTestFS()
        let stack = home + "/Downloads/stack"
        fs.addFile(stack + "/docker-compose.yml", """
            services:
              api:
                build: ./shop-api
              web:
                build:
                  context: shop-web
                volumes:
                  - ./shop-web/src:/app/src
            """)
        fs.addFile(stack + "/shop-api/requirements.txt")
        fs.addFile(stack + "/shop-web/package.json", #"{"name": "shop-web"}"#)
        let other = home + "/Downloads/devtools"
        fs.addFile(other + "/compose.yaml", "services:\n  db:\n    image: postgres:16\n    volumes:\n      - ./pgdata:/var/lib/postgresql/data\n")
        fs.addFile(other + "/alpha/package.json", #"{"name": "alpha-tool"}"#)
        fs.addFile(other + "/beta/package.json", #"{"name": "beta-tool"}"#)
        let resolver = fs.makeResolver()

        XCTAssertEqual(resolver.project(forDirectory: stack + "/shop-api")?.rootPath, stack)
        XCTAssertEqual(resolver.project(forDirectory: stack + "/shop-api")?.subpath, "shop-api")
        XCTAssertEqual(resolver.project(forDirectory: stack + "/shop-web")?.rootPath, stack)
        XCTAssertEqual(resolver.project(forDirectory: other + "/alpha")?.rootPath, other + "/alpha",
                       "a compose file that does not use a folder does not claim it")
        XCTAssertEqual(resolver.project(forDirectory: other + "/beta")?.name, "beta-tool")
    }

    func testGenericPartDoesNotClimbIntoAContainerFolder() {
        let fs = ResolverTestFS()
        let projects = home + "/Downloads/projects"
        fs.addFile(projects + "/package.json", #"{"name": "scratch"}"#)
        fs.addFile(projects + "/api/package.json", #"{"name": "api"}"#)
        let info = fs.makeResolver().project(forDirectory: projects + "/api")
        XCTAssertEqual(info?.rootPath, projects + "/api")
        XCTAssertEqual(info?.name, "projects/api")
    }

    func testComposeReferenceParser() {
        func refs(_ yaml: String, _ folder: String) -> Bool {
            ProjectResolver.composeFile(Data(yaml.utf8), references: folder)
        }
        XCTAssertTrue(refs("    build: ./api\n", "api"))
        XCTAssertTrue(refs("    build: api\n", "api"))
        XCTAssertTrue(refs("      context: \"./api/\"\n", "api"))
        XCTAssertTrue(refs("      - ./api:/app\n", "api"))
        XCTAssertTrue(refs("      - \"./packages/web/dist:/usr/share/nginx/html\"\n", "packages/web"))
        XCTAssertTrue(refs("    env_file: ./api/.env\n", "api"))
        XCTAssertFalse(refs("      - ./api-old:/app\n", "api"))
        XCTAssertFalse(refs("    image: api\n", "api"))
        XCTAssertFalse(refs("  # build: ./api\n", "api"))
        XCTAssertFalse(refs("    build: ./api\n", ""))
    }

    func testWorkspaceManifestParsers() {
        XCTAssertTrue(ProjectResolver.packageJSONDeclaresWorkspaces(Data(#"{"workspaces": ["packages/*"]}"#.utf8)))
        XCTAssertTrue(ProjectResolver.packageJSONDeclaresWorkspaces(Data(#"{"workspaces": {"packages": []}}"#.utf8)))
        XCTAssertFalse(ProjectResolver.packageJSONDeclaresWorkspaces(Data(#"{"workspaces": []}"#.utf8)))
        XCTAssertFalse(ProjectResolver.packageJSONDeclaresWorkspaces(Data(#"{"name": "x"}"#.utf8)))
        XCTAssertTrue(ProjectResolver.packageJSONDeclaresWorkspaces(Data(#"{"name": "x", "workspaces": ["a"#.utf8)),
                      "truncated JSON falls back to a textual check")

        XCTAssertTrue(ProjectResolver.packageJSONDescribesProject(Data(#"{"name": "x"}"#.utf8)))
        XCTAssertTrue(ProjectResolver.packageJSONDescribesProject(Data(#"{"scripts": {"dev": "vite"}}"#.utf8)))
        XCTAssertFalse(ProjectResolver.packageJSONDescribesProject(Data(#"{"dependencies": {"a": "1"}}"#.utf8)))
        XCTAssertTrue(ProjectResolver.packageJSONDescribesProject(Data("{ broken".utf8)))

        let cargo = { (text: String) in ProjectResolver.tomlDeclaresTable(Data(text.utf8), named: "workspace") }
        XCTAssertTrue(cargo("[workspace]\nmembers = []\n"))
        XCTAssertTrue(cargo("[package]\nname = \"a\"\n\n[workspace.dependencies]\nserde = \"1\"\n"))
        XCTAssertFalse(cargo("[package]\nname = \"a\"\n[[bin]]\nname = \"workspace\"\n"))
        XCTAssertFalse(cargo("[workspaces]\n"))

        XCTAssertTrue(ProjectResolver.gradleSettingsIncludeProjects("rootProject.name = 'x'\ninclude 'app', 'lib'\n"))
        XCTAssertFalse(ProjectResolver.gradleSettingsIncludeProjects("rootProject.name = 'x'\n"))
    }
}

/// GUI apps the user builds belong to their project; installed apps never do.
final class ProjectResolverAppTests: XCTestCase {
    private let home = ResolverTestFS.home

    private func app(_ executable: String, cwd: String = "/") -> ProcessDetails {
        ResolverTestProcess.details(executable: executable, arguments: [executable], cwd: cwd)
    }

    private func derivedDataPlist(workspace: String) -> String {
        """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0"><dict>
        <key>LastAccessedDate</key><date>2026-10-09T10:28:32Z</date>
        <key>WorkspacePath</key><string>\(workspace)</string>
        </dict></plist>
        """
    }

    func testAppBuiltInsideAProjectBelongsToIt() {
        let fs = ResolverTestFS()
        let tool = home + "/Downloads/odds-and-ends/MyMacTool"
        fs.addDirectory(tool + "/.git")
        fs.addFile(tool + "/Package.swift")
        let executable = tool + "/build/Debug/MyMacTool.app/Contents/MacOS/MyMacTool"
        fs.addFile(executable)
        let electron = home + "/code/desk"
        fs.addFile(electron + "/package.json", #"{"name": "desk"}"#)
        let helper = electron + "/dist/mac-arm64/Desk.app/Contents/Frameworks/Desk Helper.app/Contents/MacOS/Desk Helper"
        let resolver = fs.makeResolver()

        let details = app(executable, cwd: tool)
        let info = resolver.resolve(details: details)
        XCTAssertEqual(info?.rootPath, tool)
        XCTAssertEqual(info?.name, "MyMacTool")
        let basic = ProcessBasic(pid: 100, ppid: 1, pgid: 100, uid: 501, comm: "MyMacTool", startTime: 1)
        XCTAssertEqual(Classifier.category(basic: basic, details: details, project: info, manager: .none,
                                           currentUID: 501), .project)
        XCTAssertEqual(resolver.resolve(details: app(helper))?.rootPath, electron,
                       "helpers of a packaged build resolve through the outermost bundle")
    }

    func testXcodeBuildProductsResolveThroughDerivedData() {
        let fs = ResolverTestFS()
        let derived = home + "/Library/Developer/Xcode/DerivedData"
        let myApp = home + "/code/MyApp"
        fs.addDirectory(myApp + "/.git")
        fs.addFile(derived + "/MyApp-abc/info.plist", derivedDataPlist(workspace: myApp + "/MyApp.xcodeproj"))
        let package = home + "/Downloads/swift sketches/MenuTimer"
        fs.addFile(package + "/Package.swift")
        fs.addFile(derived + "/MenuTimer-def/info.plist", derivedDataPlist(workspace: package))
        let bare = home + "/Downloads/Field Notes/Field Notes"
        fs.addDirectory(bare + "/Field Notes.xcodeproj")
        fs.addFile(derived + "/Field_Notes-ghi/info.plist",
                   derivedDataPlist(workspace: bare + "/Field Notes.xcodeproj/project.xcworkspace"))
        let custom = "/private/tmp/dd"
        let tmpProject = "/private/tmp/work/Tool"
        fs.addDirectory(tmpProject + "/.git")
        fs.addFile(custom + "/info.plist", derivedDataPlist(workspace: tmpProject + "/Tool.xcodeproj"))
        let resolver = fs.makeResolver()

        let product = derived + "/MyApp-abc/Build/Products/Debug/MyApp.app/Contents/MacOS/MyApp"
        XCTAssertEqual(resolver.resolve(details: app(product))?.rootPath, myApp)
        XCTAssertEqual(resolver.resolve(details: app(product))?.name, "MyApp")

        let packageProduct = derived + "/MenuTimer-def/Build/Products/Release/MenuTimer.app/Contents/MacOS/MenuTimer"
        XCTAssertEqual(resolver.resolve(details: app(packageProduct))?.rootPath, package)

        let bareInfo = resolver.resolve(details: app(
            derived + "/Field_Notes-ghi/Build/Products/Debug/Field Notes.app/Contents/MacOS/Field Notes"))
        XCTAssertEqual(bareInfo?.rootPath, bare)
        XCTAssertEqual(bareInfo?.markers, ["Field Notes.xcodeproj"], "the Xcode project is the marker")

        XCTAssertEqual(resolver.resolve(details: app(custom + "/Build/Products/Debug/Tool.app/Contents/MacOS/Tool"))?
                        .rootPath, tmpProject, "custom -derivedDataPath folders work too")

        XCTAssertNil(resolver.resolve(details: app(derived + "/Gone-xyz/Build/Products/Debug/Gone.app/Contents/MacOS/Gone")),
                     "without info.plist the build product stays an app")
    }

    func testXcodeCommandLineServerResolvesThroughDerivedData() {
        let fs = ResolverTestFS()
        let derived = home + "/Library/Developer/Xcode/DerivedData/vapor-api-abc"
        let package = home + "/Downloads/vapor-api"
        fs.addFile(package + "/Package.swift")
        fs.addFile(derived + "/info.plist", derivedDataPlist(workspace: package))
        let server = ResolverTestProcess.details(executable: derived + "/Build/Products/Debug/App",
                                                 arguments: [derived + "/Build/Products/Debug/App", "serve"], cwd: "/")
        let info = fs.makeResolver().resolve(details: server)
        XCTAssertEqual(info?.rootPath, package)
        XCTAssertEqual(info?.markers, ["Package.swift"])
    }

    func testInstalledAppsNeverGetAProject() {
        let fs = ResolverTestFS()
        let project = home + "/code/site"
        fs.addDirectory(project + "/.git")
        fs.addFile(project + "/package.json", #"{"name": "site"}"#)
        fs.addFile(home + "/Downloads/Tool-1.2/README.txt")
        let resolver = fs.makeResolver()

        let installed = [
            "/Applications/Tool.app/Contents/MacOS/Tool",
            home + "/Applications/Tool.app/Contents/MacOS/Tool",
            home + "/Downloads/Tool.app/Contents/MacOS/Tool",
            home + "/Downloads/Tool-1.2/Tool.app/Contents/MacOS/Tool",
            home + "/Library/Application Support/Vendor/Agent.app/Contents/MacOS/Agent",
            "/opt/homebrew/Caskroom/tool/1.0/Tool.app/Contents/MacOS/Tool",
        ]
        for executable in installed {
            XCTAssertNil(resolver.resolve(details: app(executable, cwd: project)), executable)
        }
    }

    func testWorkspaceLocation() {
        XCTAssertEqual(ProjectResolver.workspaceLocation(forWorkspacePath: "/u/a/App.xcodeproj")?.directory, "/u/a")
        XCTAssertEqual(ProjectResolver.workspaceLocation(forWorkspacePath: "/u/a/App.xcodeproj")?.fileName,
                       "App.xcodeproj")
        XCTAssertEqual(ProjectResolver.workspaceLocation(forWorkspacePath: "/u/a/App.xcworkspace")?.directory, "/u/a")
        XCTAssertEqual(ProjectResolver.workspaceLocation(
            forWorkspacePath: "/u/a/App.xcodeproj/project.xcworkspace")?.directory, "/u/a")
        XCTAssertEqual(ProjectResolver.workspaceLocation(
            forWorkspacePath: "/u/pkg/.swiftpm/xcode/package.xcworkspace")?.directory, "/u/pkg")
        XCTAssertEqual(ProjectResolver.workspaceLocation(forWorkspacePath: "/u/pkg")?.directory, "/u/pkg")
        XCTAssertNil(ProjectResolver.workspaceLocation(forWorkspacePath: "/"))
    }
}

/// `resolve(details:)` must not stall the scan while macOS shows a folder-access prompt.
final class ProjectResolverDeadlineTests: XCTestCase {
    private let home = ResolverTestFS.home

    private func node(cwd: String, script: String = "server.js") -> ProcessDetails {
        ResolverTestProcess.details(executable: "/opt/homebrew/bin/node", arguments: ["node", script], cwd: cwd)
    }

    func testBlockedProbeAnswersProvisionallyThenCachesTheRealAnswer() {
        let fs = ResolverTestFS()
        let project = home + "/Downloads/slowproj"
        fs.addDirectory(project + "/.git")
        fs.addFile(project + "/web/package.json", #"{"name": "slow-web"}"#)
        fs.blockProbes(under: project)
        defer { fs.releaseBlockedProbes() }
        let resolver = fs.makeResolver(probeDeadline: 0.5)
        let server = node(cwd: project + "/web")

        var started = Date()
        let provisional = resolver.resolve(details: server)
        XCTAssertLessThan(Date().timeIntervalSince(started), 2, "the caller waits about one deadline, not the prompt")
        XCTAssertEqual(provisional?.rootPath, project + "/web")
        XCTAssertEqual(provisional?.name, "slowproj/web")
        XCTAssertEqual(provisional?.markers, [])
        XCTAssertEqual(resolver.foldersAwaitingAccess(), [home + "/Downloads"])

        started = Date()
        XCTAssertEqual(resolver.resolve(details: server)?.rootPath, project + "/web")
        XCTAssertLessThan(Date().timeIntervalSince(started), 0.25, "a stalled folder answers at once")
        XCTAssertEqual(resolver.pendingProbeCount, 1, "repeated scans share the blocked probe")

        fs.releaseBlockedProbes()
        XCTAssertTrue(resolver.waitForPendingProbes(timeout: 5))
        XCTAssertEqual(resolver.foldersAwaitingAccess(), [])
        XCTAssertEqual(resolver.pendingProbeCount, 0)

        let real = resolver.resolve(details: server)
        XCTAssertEqual(real?.rootPath, project)
        XCTAssertEqual(real?.name, "slowproj")
        XCTAssertEqual(real?.subpath, "web")
    }

    func testStalledFolderDoesNotDelayOtherFolders() {
        let fs = ResolverTestFS()
        let slow = home + "/Downloads/slowproj"
        fs.addFile(slow + "/package.json", #"{"name": "slow"}"#)
        let fast = home + "/code/fast"
        fs.addFile(fast + "/package.json", #"{"name": "fast"}"#)
        let documents = home + "/Documents/notes"
        fs.addFile(documents + "/requirements.txt")
        fs.blockProbes(under: slow)
        defer { fs.releaseBlockedProbes() }
        let resolver = fs.makeResolver(probeDeadline: 0.5)

        XCTAssertEqual(resolver.resolve(details: node(cwd: slow))?.markers, [], "provisional")

        var started = Date()
        XCTAssertEqual(resolver.resolve(details: node(cwd: fast))?.name, "fast")
        XCTAssertEqual(resolver.resolve(details: node(cwd: documents))?.markers, ["requirements.txt"])
        XCTAssertLessThan(Date().timeIntervalSince(started), 0.25, "other folders keep their own probe queues")

        started = Date()
        let tool = ResolverTestProcess.details(executable: home + "/.local/bin/indexer", arguments: ["indexer"],
                                               cwd: slow + "/sub")
        XCTAssertNil(resolver.resolve(details: tool), "no provisional project for a tool that inherited the cwd")
        XCTAssertLessThan(Date().timeIntervalSince(started), 0.25)

        fs.releaseBlockedProbes()
        XCTAssertTrue(resolver.waitForPendingProbes(timeout: 5))
        XCTAssertEqual(resolver.resolve(details: node(cwd: slow))?.markers, ["package.json"])
        XCTAssertEqual(resolver.resolve(details: tool)?.rootPath, slow,
                       "the real answer: its cwd lies inside a project with markers")
    }

    func testBuildProductsAreProbedInTheirWorkspaceFolder() {
        let fs = ResolverTestFS()
        let derived = home + "/Library/Developer/Xcode/DerivedData/Sunbeam-abc"
        let project = home + "/Downloads/Pixelpost/Sunbeam"
        fs.addDirectory(project + "/.git")
        fs.addFile(derived + "/info.plist", """
            <?xml version="1.0" encoding="UTF-8"?>
            <plist version="1.0"><dict><key>WorkspacePath</key>\
            <string>\(project)/Sunbeam.xcodeproj</string></dict></plist>
            """)
        fs.blockProbes(under: project)
        defer { fs.releaseBlockedProbes() }
        let resolver = fs.makeResolver(probeDeadline: 0.3)
        let app = ResolverTestProcess.details(
            executable: derived + "/Build/Products/Debug/Sunbeam.app/Contents/MacOS/Sunbeam",
            arguments: ["Sunbeam"], cwd: "/")

        XCTAssertNil(resolver.resolve(details: app), "apps get no provisional project")
        XCTAssertEqual(resolver.foldersAwaitingAccess(), [home + "/Downloads"],
                       "the probe waits in the workspace's folder, not in the shared queue")
        fs.releaseBlockedProbes()
        XCTAssertTrue(resolver.waitForPendingProbes(timeout: 5))
        XCTAssertEqual(resolver.resolve(details: app)?.rootPath, project)
    }

    func testFastProbesAnswerDirectly() {
        let fs = ResolverTestFS()
        fs.addFile(home + "/Downloads/quick/package.json", #"{"name": "quick"}"#)
        let resolver = fs.makeResolver(probeDeadline: ProjectResolver.defaultProbeDeadline)
        XCTAssertEqual(resolver.resolve(details: node(cwd: home + "/Downloads/quick"))?.markers, ["package.json"])
        XCTAssertEqual(resolver.pendingProbeCount, 0)
        XCTAssertEqual(resolver.foldersAwaitingAccess(), [])
    }

    func testProvisionalProjectRules() {
        let resolver = ProjectResolver(homeDirectory: home, fileExists: { _ in
            XCTFail("provisional answers must not touch the disk")
            return false
        }, readFile: { _ in nil })

        let runtime = resolver.provisionalProject(for: node(cwd: home + "/Downloads/a/b"))
        XCTAssertEqual(runtime?.rootPath, home + "/Downloads/a/b")
        XCTAssertEqual(runtime?.name, "b")
        XCTAssertEqual(resolver.provisionalProject(for: node(cwd: "/", script: home + "/Sites/demo/server.js"))?
                        .rootPath, home + "/Sites/demo")
        XCTAssertEqual(resolver.provisionalProject(for: node(cwd: home + "/code/app/node_modules/.bin"))?.rootPath,
                       home + "/code/app")
        XCTAssertEqual(resolver.provisionalProject(for: ResolverTestProcess.details(
            executable: home + "/code/svc/server", arguments: ["./server"], cwd: home + "/code/svc"))?.rootPath,
                       home + "/code/svc", "a binary that lives in its working folder")

        XCTAssertNil(resolver.provisionalProject(for: ResolverTestProcess.details(
            executable: home + "/code/svc/bin/tool", arguments: ["tool"], cwd: home + "/code/svc")))
        XCTAssertNil(resolver.provisionalProject(for: ResolverTestProcess.details(
            executable: home + "/.local/bin/tool", arguments: ["tool"], cwd: home + "/Downloads/x")))
        XCTAssertNil(resolver.provisionalProject(for: ResolverTestProcess.details(
            executable: home + "/Downloads/x/build/X.app/Contents/MacOS/X", arguments: ["X"], cwd: home + "/Downloads/x")))
        XCTAssertNil(resolver.provisionalProject(for: node(cwd: home + "/Library/Application Support/x")))
        XCTAssertNil(resolver.provisionalProject(for: node(cwd: "/opt/app")), "outside $HOME only with markers")
        XCTAssertNil(resolver.provisionalProject(for: node(cwd: home + "/Downloads")))
    }

    func testProtectedFolders() {
        let resolver = ResolverTestFS().makeResolver()
        XCTAssertEqual(resolver.protectedFolder(containing: home + "/Downloads/a/b"), home + "/Downloads")
        XCTAssertEqual(resolver.protectedFolder(containing: home + "/Documents/x"), home + "/Documents")
        XCTAssertEqual(resolver.protectedFolder(containing: home + "/Desktop/x"), home + "/Desktop")
        XCTAssertEqual(resolver.protectedFolder(containing: home + "/Library/Mobile Documents/com~apple~CloudDocs/x"),
                       home + "/Library/Mobile Documents")
        XCTAssertEqual(resolver.protectedFolder(containing: home + "/Library/CloudStorage/Dropbox/x"),
                       home + "/Library/CloudStorage/Dropbox")
        XCTAssertEqual(resolver.protectedFolder(containing: "/Volumes/SSD/code/x"), "/Volumes/SSD")
        XCTAssertNil(resolver.protectedFolder(containing: home + "/code/x"))
        XCTAssertNil(resolver.protectedFolder(containing: home + "/Library/Developer/Xcode/DerivedData/x"))
        XCTAssertNil(resolver.protectedFolder(containing: "/opt/homebrew/bin/node"))
    }
}
