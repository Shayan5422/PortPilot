import XCTest
@testable import PortPilot

/// In-memory file tree for resolver tests. Adding a file implicitly creates its parent directories.
final class ResolverTestFS {
    private(set) var directories: Set<String> = ["/"]
    private(set) var files: [String: Data] = [:]
    /// Paths probed through `fileExists`, to check caching.
    private(set) var probeCount = 0

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

    func fileExists(_ path: String) -> Bool {
        probeCount += 1
        return files[path] != nil || directories.contains(path)
    }

    func readFile(_ path: String) -> Data? { files[path] }

    func listDirectory(_ path: String) -> [String]? {
        guard directories.contains(path) else { return nil }
        let prefix = path == "/" ? "/" : path + "/"
        var names = Set<String>()
        for entry in Array(files.keys) + Array(directories) where entry.hasPrefix(prefix) && entry != path {
            if let name = entry.dropFirst(prefix.count).split(separator: "/").first { names.insert(String(name)) }
        }
        return names.sorted()
    }

    func makeResolver(home: String = ResolverTestFS.home, now: @escaping () -> Date = Date.init) -> ProjectResolver {
        ProjectResolver(homeDirectory: home,
                        fileExists: { [unowned self] in self.fileExists($0) },
                        readFile: { [unowned self] in self.readFile($0) },
                        listDirectory: { [unowned self] in self.listDirectory($0) },
                        now: now)
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
        let root = home + "/Downloads/Institut de mai"
        fs.addDirectory(root + "/.git")
        fs.addFile(root + "/backend/pyproject.toml", "[project]\nname = \"idm-planning\"\n")
        fs.addFile(root + "/frontend/package.json", #"{"name": "idm-planification-front"}"#)
        let resolver = fs.makeResolver()

        let backend = resolver.project(forDirectory: root + "/backend")
        let frontend = resolver.project(forDirectory: root + "/frontend")
        XCTAssertEqual(backend?.rootPath, root)
        XCTAssertEqual(frontend?.rootPath, root)
        XCTAssertEqual(backend?.name, "Institut de mai")
        XCTAssertEqual(backend?.subpath, "backend")
        XCTAssertEqual(frontend?.subpath, "frontend")
        XCTAssertEqual(backend?.markers, [".git", "pyproject.toml"])
    }

    func testSiblingManifestRuleWithoutGit() {
        let fs = ResolverTestFS()
        let root = home + "/Downloads/Institut de mai"
        fs.addFile(root + "/backend/pyproject.toml", "[project]\nname = \"idm-planning\"\n")
        fs.addFile(root + "/frontend/package.json", #"{"name": "idm-planification-front"}"#)
        let resolver = fs.makeResolver()

        let backend = resolver.project(forDirectory: root + "/backend")
        let frontend = resolver.project(forDirectory: root + "/frontend/src")
        XCTAssertEqual(backend?.rootPath, root)
        XCTAssertEqual(frontend?.rootPath, root)
        XCTAssertEqual(backend?.name, "Institut de mai")
        XCTAssertEqual(frontend?.subpath, "frontend")
    }

    func testGenericRootFolderIsPrefixedWithParent() {
        let fs = ResolverTestFS()
        let release = home + "/.codex/idm-public-deployment-20261008/release"
        fs.addFile(release + "/README.md")
        fs.addFile(release + "/backend/pyproject.toml", "[project]\nname = \"idm-planning\"\n")
        fs.addFile(release + "/frontend/package.json", #"{"name": "idm-front"}"#)
        let info = fs.makeResolver().project(forDirectory: release + "/backend")

        XCTAssertEqual(info?.rootPath, release)
        XCTAssertEqual(info?.name, "idm-public-deployment-20261008/release")
        XCTAssertEqual(info?.subpath, "backend")
        XCTAssertEqual(info?.markers, ["pyproject.toml"])
    }

    func testRootWrappingSinglePackageTakesPackageName() {
        let fs = ResolverTestFS()
        let wrapper = home + "/Downloads/claude check"
        fs.addDirectory(wrapper + "/.git")
        fs.addFile(wrapper + "/claude-monitor/package.json", #"{"name": "claude-monitor", "private": true}"#)
        let info = fs.makeResolver().project(forDirectory: wrapper + "/claude-monitor")

        XCTAssertEqual(info?.rootPath, wrapper)
        XCTAssertEqual(info?.name, "claude-monitor")
        XCTAssertEqual(info?.subpath, "claude-monitor")
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
        let container = home + "/Downloads/NODES"
        fs.addFile(container + "/PortPilot/Package.swift")
        fs.addFile(container + "/dashboard-kit/package.json", #"{"name": "dashboard-kit"}"#)
        let resolver = fs.makeResolver()

        XCTAssertEqual(resolver.project(forDirectory: container + "/PortPilot")?.rootPath, container + "/PortPilot")
        XCTAssertEqual(resolver.project(forDirectory: container + "/dashboard-kit")?.name, "dashboard-kit")
    }

    func testDistinctSiblingsMergeWhenParentLooksLikeARepository() {
        let fs = ResolverTestFS()
        let shop = home + "/Downloads/shop"
        fs.addFile(shop + "/README.md")
        fs.addFile(shop + "/shop-api/requirements.txt")
        fs.addFile(shop + "/shop-web/package.json", #"{"name": "shop-web"}"#)
        let info = fs.makeResolver().project(forDirectory: shop + "/shop-api")
        XCTAssertEqual(info?.rootPath, shop)
        XCTAssertEqual(info?.subpath, "shop-api")
    }

    func testDistinctSingleSubprojectIsItsOwnRoot() {
        let fs = ResolverTestFS()
        let folder = home + "/Downloads/Heyclicky"
        fs.addFile(folder + "/cliquette-backend/requirements.txt")
        fs.addFile(folder + "/cliquette-backend/app.py")
        fs.addFile(folder + "/Cliquette/project.yml")
        let info = fs.makeResolver().project(forDirectory: folder + "/cliquette-backend")
        XCTAssertEqual(info?.rootPath, folder + "/cliquette-backend")
        XCTAssertEqual(info?.name, "cliquette-backend")
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
        fs.addFile(home + "/Library/Application Support/claude-monitor/package.json")
        fs.addFile(home + "/.vscode/extensions/ext/package.json")
        fs.addFile("/opt/homebrew/var/postgresql@16/postgresql.conf")
        fs.addFile("/Applications/Tool.app/Contents/Resources/app/package.json")
        let resolver = fs.makeResolver()

        XCTAssertNil(resolver.project(forDirectory: home + "/.npm/_npx/abc123"))
        XCTAssertNil(resolver.project(forDirectory: home + "/Library/Application Support/claude-monitor"))
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
        fs.addFile(home + "/Downloads/claude check/claude-monitor/package.json", #"{"name": "claude-monitor"}"#)
        let details = ResolverTestProcess.details(
            executable: "/opt/homebrew/bin/node",
            arguments: ["/opt/homebrew/bin/node", home + "/Downloads/claude check/claude-monitor/server.js"],
            cwd: home + "/Downloads/claude check/claude-monitor")
        XCTAssertEqual(fs.makeResolver().resolve(details: details)?.name, "claude-monitor")
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
        fs.addDirectory(home + "/Downloads/Heyclicky/.claude")
        fs.addFile(home + "/Downloads/photos/index.html")
        let resolver = fs.makeResolver()

        let mcp = ResolverTestProcess.details(executable: home + "/.local/bin/codebase-memory-mcp",
                                              arguments: [home + "/.local/bin/codebase-memory-mcp"],
                                              cwd: home + "/Downloads/Heyclicky")
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
