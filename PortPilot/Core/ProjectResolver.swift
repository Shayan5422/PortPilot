import Darwin
import Foundation

/// Maps a process to the project folder it belongs to (the grouping key in the panel).
///
/// Thread-safe: all mutable state is behind `lock`; file-system probes run outside the lock. Directory lookups are
/// cached for 60 s so a scan tick normally costs a few dictionary lookups. The file system is injectable so the
/// heuristics can be unit-tested against a fake tree.
///
/// `resolve(details:)` never stalls its caller for long. The first read inside a privacy-protected folder
/// (~/Downloads, ~/Documents, ~/Desktop, iCloud Drive, cloud storage, other volumes) can block until the user answers
/// the macOS folder-access prompt, so probes run on one serial queue per protected folder and the caller waits at
/// most `probeDeadline`. A late probe keeps running; the caller gets a provisional answer (the working folder) and
/// the real one is kept for the next scan.
final class ProjectResolver: @unchecked Sendable {

    /// Files whose presence marks a directory as a code root.
    static let manifestFiles: [String] = [
        "package.json", "pyproject.toml", "requirements.txt", "Pipfile", "setup.py", "setup.cfg", "manage.py",
        "Cargo.toml", "go.mod", "Gemfile", "composer.json", "pom.xml", "build.gradle", "build.gradle.kts",
        "deno.json", "deno.jsonc", "bun.lockb", "bun.lock", "Package.swift", "mix.exs", "Makefile",
        "docker-compose.yml", "docker-compose.yaml", "compose.yml", "compose.yaml", "Procfile", "CMakeLists.txt",
        "pubspec.yaml", "build.sbt", "deps.edn", "project.clj", "config.ru", "hugo.toml", "Justfile", "justfile",
    ]

    /// Manifests that identify a standalone package (used when counting sub-projects of a folder).
    static let primaryManifestFiles: [String] = [
        "package.json", "pyproject.toml", "requirements.txt", "Pipfile", "setup.py", "manage.py", "Cargo.toml",
        "go.mod", "Gemfile", "composer.json", "pom.xml", "build.gradle", "build.gradle.kts", "deno.json",
        "Package.swift", "mix.exs",
    ]

    /// How long directory lookups are cached.
    static let cacheLifetime: TimeInterval = 60
    /// Manifests are read only up to this size (a huge package.json must never stall a scan).
    static let maxManifestBytes = 256 * 1024
    /// How long `resolve(details:)` waits for file-system probes before it answers provisionally.
    static let defaultProbeDeadline: TimeInterval = 0.2

    private let home: String
    private let homeComponents: [String]
    private let fileExistsAt: (String) -> Bool
    private let readFileAt: (String) -> Data?
    private let listDirectoryAt: (String) -> [String]?
    private let now: () -> Date
    private let probeDeadline: TimeInterval

    private let lock = NSLock()
    private var projectCache: [String: CacheEntry<ProjectInfo?>] = [:]
    private var markerCache: [String: CacheEntry<DirectoryMarkers>] = [:]
    private var nameCache: [String: CacheEntry<String>] = [:]
    private var workspaceCache: [String: CacheEntry<Bool>] = [:]
    private var derivedDataCache: [String: CacheEntry<String?>] = [:]

    /// Probe queues by protected folder ("" = everything else).
    private var lanes: [String: ProbeLane] = [:]
    /// Probes queued or running, so repeated scans never pile up duplicates behind a blocked probe.
    private var pendingProbes: [ResolutionKey: ProbeJob] = [:]
    /// Answers of probes that finished after their caller had moved on.
    private var lateResults: [ResolutionKey: CacheEntry<ProjectInfo?>] = [:]

    /// - Parameters:
    ///   - fileExists / readFile / listDirectory: file-system access, injectable for tests. Each defaults to the real
    ///     disk; `listDirectory` defaults to "no listing" when `fileExists` is injected so a fake tree stays hermetic.
    ///   - now: clock used for cache expiry.
    ///   - probeDeadline: longest time `resolve(details:)` blocks its caller.
    init(homeDirectory: String = NSHomeDirectory(),
         fileExists: ((String) -> Bool)? = nil,
         readFile: ((String) -> Data?)? = nil,
         listDirectory: ((String) -> [String]?)? = nil,
         now: @escaping () -> Date = Date.init,
         probeDeadline: TimeInterval = ProjectResolver.defaultProbeDeadline) {
        let normalizedHome = ProjectResolver.normalize(homeDirectory)
        home = normalizedHome
        homeComponents = ProjectResolver.components(of: normalizedHome)
        fileExistsAt = fileExists ?? ProjectResolver.diskFileExists
        readFileAt = readFile ?? { ProjectResolver.diskReadPrefix(path: $0, limit: ProjectResolver.maxManifestBytes) }
        if let listDirectory {
            listDirectoryAt = listDirectory
        } else if fileExists != nil {
            listDirectoryAt = { _ in nil }
        } else {
            listDirectoryAt = { try? FileManager.default.contentsOfDirectory(atPath: $0) }
        }
        self.now = now
        self.probeDeadline = max(0, probeDeadline)
    }

    // MARK: - Public API

    /// Determines the project for a process. Order: cwd (if not "/" and not inside an .app bundle or a system dir)
    /// → script path inferred from argv (first existing absolute file arg; stripped at node_modules/.venv/venv/
    /// site-packages/.bin) → $VIRTUAL_ENV → executable path if it lives in a project
    /// (e.g. ~/code/foo/target/debug/server).
    ///
    /// A folder without any marker (no .git, no manifest) only counts for language runtimes (`python -m http.server`
    /// in ~/Sites/demo) or binaries living in that folder — never for tools like an MCP server that merely
    /// inherited a cwd. GUI applications only belong to a project when the user builds them there: the bundle sits
    /// inside a project folder (`build/`, `dist/mac-arm64/`) or is an Xcode build product whose DerivedData names the
    /// project. Installed apps (/Applications, ~/Applications, downloads) never do, whatever their cwd.
    /// Returns nil for things outside $HOME (except /opt, /srv, /var/www, /Volumes style code dirs that have markers)
    /// and for $HOME itself / ~/Downloads / ~/Desktop / ~/Documents roots.
    ///
    /// Blocks for at most `probeDeadline`. When the probes take longer (a folder-access prompt is up), it returns
    /// `provisionalProject(for:)` and a later call returns the real answer once it is known.
    func resolve(details: ProcessDetails?) -> ProjectInfo? {
        guard let details else { return nil }
        let key = ResolutionKey(details)
        let laneKey = probeLaneKey(for: details)

        lock.lock()
        if let late = lateResults[key], late.expires > now() {
            lock.unlock()
            return late.value
        }
        let lane = probeLane(laneKey)
        let job: ProbeJob
        if let pending = pendingProbes[key] {
            job = pending
        } else {
            job = ProbeJob()
            pendingProbes[key] = job
            lane.queue.async(flags: [.assignCurrentContext, .enforceQoS]) { [self] in
                runProbe(job, key: key, details: details, lane: lane)
            }
        }
        if lane.isStalled {
            // An earlier probe in this folder is still blocked: answer now instead of waiting once per process.
            job.isAbandoned = true
            lock.unlock()
            return provisionalProject(for: details)
        }
        lock.unlock()

        let finishedInTime = job.done.wait(timeout: .now() + probeDeadline) == .success
        lock.lock()
        defer { lock.unlock() }
        if finishedInTime || job.isFinished { return job.result }
        job.isAbandoned = true
        lane.isStalled = true
        return provisionalProject(for: details)
    }

    /// Answer used while the real probes are still blocked: the working folder (or, for a runtime started
    /// elsewhere, its script's folder) named after itself, without touching the file system. Only language runtimes
    /// and binaries that live in that folder get one, the same processes that may form a marker-less project; GUI
    /// apps and tools that merely inherited a cwd get nil until the real answer arrives.
    func provisionalProject(for details: ProcessDetails) -> ProjectInfo? {
        if let executable = details.executablePath, Classifier.isApplicationExecutable(executable) { return nil }
        let isRuntime = Classifier.isDevRuntime(name: details.executableName)
        var candidates: [String] = []
        if let cwd = details.cwd, cwd.hasPrefix("/") { candidates.append(cwd) }
        if isRuntime, let script = details.arguments.dropFirst().prefix(16).first(where: { $0.hasPrefix("/") }) {
            candidates.append(ProjectResolver.parent(of: ProjectResolver.normalize(script)))
        }
        let executable = details.executablePath.flatMap { $0.hasPrefix("/") ? ProjectResolver.normalize($0) : nil }
        for candidate in candidates {
            let directory = ProjectResolver.strippingDependencyFolders(ProjectResolver.normalize(candidate))
            guard directory != "/", let scope = scope(for: directory), scope.allowsMarkerless,
                  isStrictlyInside(directory, scope.boundary) else { continue }
            if !isRuntime {
                guard let executable, executable.hasPrefix(directory + "/"),
                      ProjectResolver.lastComponent(of: ProjectResolver.parent(of: executable)) != "bin" else { continue }
            }
            return ProjectInfo(rootPath: directory, name: fallbackName(forRoot: directory, scope: scope),
                               subpath: nil, markers: [])
        }
        return nil
    }

    /// Protected folders whose probes are blocked right now, most likely behind a macOS folder-access prompt
    /// (e.g. ["/Users/me/Downloads"]). Empty in normal operation.
    func foldersAwaitingAccess() -> [String] {
        lock.lock()
        defer { lock.unlock() }
        return lanes.filter { !$0.key.isEmpty && $0.value.isStalled }.map { $0.key }.sorted()
    }

    /// Waits until every queued probe has finished, at most `timeout`. Returns false on timeout.
    /// For tests and headless modes that want final answers.
    func waitForPendingProbes(timeout: TimeInterval) -> Bool {
        lock.lock()
        let jobs = Array(pendingProbes.values)
        lock.unlock()
        let deadline = DispatchTime.now() + timeout
        return jobs.allSatisfy { $0.done.wait(timeout: deadline) == .success }
    }

    /// Number of probes queued or running (diagnostics and tests).
    var pendingProbeCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return pendingProbes.count
    }

    /// Walks up from `directory` (stops at $HOME, a top-level container such as ~/Downloads, or "/"):
    /// rootPath = nearest ancestor with `.git` (dir or file), else the manifest folder grouped per
    /// `groupingRoot(forManifestDirectory:scope:)` (declared workspaces, compose files, generic parts), else
    /// `directory`. `subpath` = nearest manifest dir relative to rootPath (nil when same). Returns nil for excluded
    /// locations (system dirs, tool caches, app bundles, container roots).
    ///
    /// Synchronous: it probes the disk on the calling thread (`resolve(details:)` calls it from a probe queue).
    func project(forDirectory directory: String) -> ProjectInfo? {
        let key = ProjectResolver.normalize(directory)
        lock.lock()
        if let cached = projectCache[key], cached.expires > now() {
            lock.unlock()
            return cached.value
        }
        lock.unlock()

        let info = computeProject(startingAt: key)
        store(info, for: key, in: \.projectCache)
        return info
    }

    // MARK: - Probing

    /// Inputs that decide a process's project; processes with equal keys share one probe.
    private struct ResolutionKey: Hashable {
        let cwd: String?
        let arguments: [String]
        let virtualEnvironment: String?
        let executablePath: String?

        init(_ details: ProcessDetails) {
            cwd = details.cwd
            arguments = Array(details.arguments.prefix(17))
            virtualEnvironment = details.environment["VIRTUAL_ENV"]
            executablePath = details.executablePath
        }
    }

    /// A serial queue for the probes of one protected folder. Guarded by `lock`.
    private final class ProbeLane: @unchecked Sendable {
        let queue: DispatchQueue
        /// A probe overran its deadline and has not finished yet.
        var isStalled = false

        init(label: String) {
            queue = DispatchQueue(label: label, qos: .utility)
        }
    }

    /// One queued probe. `result`, `isFinished` and `isAbandoned` are guarded by `lock`.
    private final class ProbeJob: @unchecked Sendable {
        /// Entered on creation and left once when the probe finishes, so any number of callers can wait on it.
        let done = DispatchGroup()
        var result: ProjectInfo?
        var isFinished = false
        /// Some caller gave up waiting, so the answer must be kept for the next scan.
        var isAbandoned = false

        init() { done.enter() }
    }

    /// Caller must hold `lock`.
    private func probeLane(_ key: String) -> ProbeLane {
        if let lane = lanes[key] { return lane }
        let lane = ProbeLane(label: "eu.shhshm.PortPilot.resolver.\(lanes.count)")
        lanes[key] = lane
        return lane
    }

    private func runProbe(_ job: ProbeJob, key: ResolutionKey, details: ProcessDetails, lane: ProbeLane) {
        let result = resolveNow(details)
        lock.lock()
        job.result = result
        job.isFinished = true
        if pendingProbes[key] === job { pendingProbes[key] = nil }
        if job.isAbandoned {
            let time = now()
            Self.prune(&lateResults, at: time)
            lateResults[key] = CacheEntry(value: result, expires: time.addingTimeInterval(Self.cacheLifetime))
        }
        // The lane is serial: whatever blocked it has finished.
        lane.isStalled = false
        lock.unlock()
        job.done.leave()
    }

    /// The protected folder whose prompt a process's probes could wait on, or "" when none applies. Pure string work,
    /// except for an Xcode build product outside protected folders, whose cached DerivedData info.plist names it.
    private func probeLaneKey(for details: ProcessDetails) -> String {
        var paths: [String] = []
        if let cwd = details.cwd { paths.append(cwd) }
        paths += details.arguments.dropFirst().prefix(16)
        if let venv = details.environment["VIRTUAL_ENV"] { paths.append(venv) }
        if let executable = details.executablePath { paths.append(executable) }
        for path in paths where path.hasPrefix("/") {
            if let folder = protectedFolder(containing: ProjectResolver.normalize(path)) { return folder }
        }
        // An Xcode build product in ~/Library/Developer is probed in its workspace folder. The info.plist read is
        // tiny, cached and in a local folder no prompt guards.
        if let executable = details.executablePath, executable.hasPrefix(home + "/"),
           let workspace = xcodeWorkspace(forBuildProduct: ProjectResolver.components(
            of: ProjectResolver.normalize(executable))),
           let folder = protectedFolder(containing: workspace.directory) {
            return folder
        }
        return ""
    }

    /// Folder macOS guards with a privacy prompt that contains `path`: ~/Desktop, ~/Documents, ~/Downloads,
    /// iCloud Drive, a File Provider (Dropbox, Google Drive...) or a removable/network volume. Pure.
    func protectedFolder(containing path: String) -> String? {
        let parts = ProjectResolver.components(of: path)
        if parts.count > homeComponents.count, Array(parts.prefix(homeComponents.count)) == homeComponents {
            let relative = Array(parts.dropFirst(homeComponents.count))
            if ProjectResolver.protectedHomeFolders.contains(relative[0]) {
                return ProjectResolver.join(home, relative[0])
            }
            guard relative[0] == "Library", relative.count >= 3 else { return nil }
            if relative[1] == "Mobile Documents" { return ProjectResolver.join(home, "Library/Mobile Documents") }
            if relative[1] == "CloudStorage" { return ProjectResolver.join(home, "Library/CloudStorage/" + relative[2]) }
            return nil
        }
        if parts.count >= 2, parts[0] == "Volumes" { return "/Volumes/" + parts[1] }
        return nil
    }

    /// The synchronous resolution behind `resolve(details:)`.
    private func resolveNow(_ details: ProcessDetails) -> ProjectInfo? {
        if let executable = details.executablePath, Classifier.isApplicationExecutable(executable) {
            return applicationProject(executable: executable)
        }
        let isRuntime = Classifier.isDevRuntime(name: details.executableName)

        var markerless: ProjectInfo?
        func consider(_ directory: String?, allowMarkerless: Bool) -> ProjectInfo? {
            guard let directory, let info = project(forDirectory: directory) else { return nil }
            if !info.markers.isEmpty { return info }
            if allowMarkerless, markerless == nil { markerless = info }
            return nil
        }

        if let cwd = details.cwd, ProjectResolver.normalize(cwd) != "/",
           let found = consider(cwd, allowMarkerless: isRuntime) {
            return found
        }
        if let found = consider(scriptDirectory(arguments: details.arguments), allowMarkerless: isRuntime) {
            return found
        }
        if let venv = details.environment["VIRTUAL_ENV"], venv.hasPrefix("/"),
           let found = consider(venv, allowMarkerless: false) {
            return found
        }
        if let executable = details.executablePath, executable.hasPrefix("/") {
            let path = ProjectResolver.normalize(executable)
            // A server built and run by Xcode (Vapor, Hummingbird...) lives in DerivedData.
            if let found = xcodeProject(forBuildProduct: ProjectResolver.components(of: path)) { return found }
            let directory = ProjectResolver.parent(of: path)
            let inBinFolder = ProjectResolver.lastComponent(of: directory) == "bin"
            if let found = consider(directory, allowMarkerless: !isRuntime && !inBinFolder) { return found }
        }
        return markerless
    }

    // MARK: - Apps the user builds

    /// Project of a GUI app the user builds, or nil for an installed app. The outermost bundle must either be an
    /// Xcode build product whose DerivedData folder names the workspace (`<DerivedData>/<X>/info.plist`
    /// WorkspacePath), or sit inside a folder with project markers (`MyTool/build/Debug/MyTool.app`). The process's
    /// cwd is never used: an editor opened from a terminal inherits the project folder without belonging to it.
    private func applicationProject(executable: String) -> ProjectInfo? {
        let parts = ProjectResolver.components(of: ProjectResolver.normalize(executable))
        guard let index = parts.firstIndex(where: { $0.hasSuffix(".app") && $0.count > 4 }) else { return nil }
        let bundleParts = Array(parts[...index])

        if xcodeWorkspace(forBuildProduct: bundleParts) != nil {
            return xcodeProject(forBuildProduct: bundleParts)
        }
        let bundleFolder = "/" + bundleParts.dropLast().joined(separator: "/")
        guard let info = project(forDirectory: bundleFolder), !info.markers.isEmpty else { return nil }
        return info
    }

    /// Project of an Xcode build product (app bundle or command-line tool), resolved through DerivedData.
    private func xcodeProject(forBuildProduct parts: [String]) -> ProjectInfo? {
        guard let workspace = xcodeWorkspace(forBuildProduct: parts),
              let info = project(forDirectory: workspace.directory) else { return nil }
        if !info.markers.isEmpty { return info }
        // An Xcode project folder has no manifest of its own; the .xcodeproj is its marker.
        return ProjectInfo(rootPath: info.rootPath, name: info.name, subpath: info.subpath,
                           markers: [workspace.fileName])
    }

    /// Workspace of an Xcode build product: `<DerivedData>/Build/Products/<Config>/App.app` (or a tool next to it,
    /// or a preview under `Build/Intermediates.noindex`), with `<DerivedData>/info.plist` naming WorkspacePath.
    /// Works for the default ~/Library/Developer/Xcode/DerivedData/<X> and for custom `-derivedDataPath` folders.
    private func xcodeWorkspace(forBuildProduct parts: [String]) -> (directory: String, fileName: String)? {
        guard let build = parts.lastIndex(of: "Build"), build >= 1, build + 1 < parts.count - 1,
              parts[build + 1] == "Products" || parts[build + 1] == "Intermediates.noindex" else {
            return nil
        }
        let derivedData = "/" + parts[..<build].joined(separator: "/")
        guard let workspacePath = derivedDataWorkspacePath(derivedData) else { return nil }
        return ProjectResolver.workspaceLocation(forWorkspacePath: workspacePath)
    }

    /// WorkspacePath from `<derivedData>/info.plist`, cached.
    private func derivedDataWorkspacePath(_ derivedData: String) -> String? {
        lock.lock()
        if let cached = derivedDataCache[derivedData], cached.expires > now() {
            lock.unlock()
            return cached.value
        }
        lock.unlock()

        var workspace: String?
        if let data = readFileAt(ProjectResolver.join(derivedData, "info.plist")),
           let plist = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil)
            as? [String: Any],
           let path = plist["WorkspacePath"] as? String, path.hasPrefix("/") {
            workspace = ProjectResolver.normalize(path)
        }
        store(workspace, for: derivedData, in: \.derivedDataCache)
        return workspace
    }

    /// Project folder for an Xcode WorkspacePath: the folder holding `X.xcodeproj` / `X.xcworkspace` (also through
    /// `X.xcodeproj/project.xcworkspace` and a package's `.swiftpm/xcode/package.xcworkspace`), or the package
    /// folder itself. `fileName` labels the project when its folder has no other marker.
    static func workspaceLocation(forWorkspacePath path: String) -> (directory: String, fileName: String)? {
        let parts = components(of: path)
        guard !parts.isEmpty else { return nil }
        let isProjectFile: (String) -> Bool = { $0.hasSuffix(".xcodeproj") || $0.hasSuffix(".xcworkspace") }
        if let index = parts.firstIndex(where: { isProjectFile($0) || $0 == ".swiftpm" }) {
            guard index >= 1 else { return nil }
            let directory = "/" + parts[..<index].joined(separator: "/")
            return (directory, parts[index] == ".swiftpm" ? "Package.swift" : parts[index])
        }
        return ("/" + parts.joined(separator: "/"), "Package.swift")
    }

    // MARK: - Walking

    private func computeProject(startingAt start: String) -> ProjectInfo? {
        let directory = ProjectResolver.strippingDependencyFolders(start)
        guard let scope = scope(for: directory), isStrictlyInside(directory, scope.boundary) else { return nil }

        var gitRoot: String?
        var nearestManifest: String?
        var current = directory
        var depth = 0
        while isStrictlyInside(current, scope.boundary), depth < 40 {
            let found = markers(at: current)
            if nearestManifest == nil, !found.manifests.isEmpty { nearestManifest = current }
            if found.hasGit {
                gitRoot = current
                break
            }
            current = ProjectResolver.parent(of: current)
            depth += 1
        }

        let root: String
        if let gitRoot {
            root = gitRoot
        } else if let nearestManifest {
            if nearestManifest != directory,
               !belongsToEnclosingManifest(directory, manifestDirectory: nearestManifest, scope: scope) {
                // A folder of its own below a folder of tools (or a stray package.json): it is its own project.
                guard scope.allowsMarkerless else { return nil }
                let own = ProjectResolver.childOnPath(from: nearestManifest, to: directory)
                return ProjectInfo(rootPath: own, name: projectName(forRoot: own, scope: scope), subpath: nil,
                                   markers: [])
            }
            root = groupingRoot(forManifestDirectory: nearestManifest, scope: scope)
        } else {
            guard scope.allowsMarkerless else { return nil }
            return ProjectInfo(rootPath: directory, name: projectName(forRoot: directory, scope: scope),
                               subpath: nil, markers: [])
        }

        var subpath: String?
        if let nearestManifest, nearestManifest != root, nearestManifest.hasPrefix(root + "/") {
            subpath = String(nearestManifest.dropFirst(root.count + 1))
        }
        return ProjectInfo(rootPath: root, name: projectName(forRoot: root, scope: scope), subpath: subpath,
                           markers: combinedMarkers(root: root, nearestManifest: nearestManifest))
    }

    /// Without a git root, a package joins an enclosing folder only on real evidence:
    /// 1. it lies inside a folder that declares a workspace (the outermost one wins);
    /// 2. a manifest folder above takes it in when one of its compose files builds or mounts it, or when the package
    ///    folder is just a generic part ("backend") — also across workspace folders such as `packages/`;
    /// 3. a generic part whose parent holds no manifest is grouped under that parent ("Harbor Notes/backend").
    /// A stray package.json, a Makefile or a README in a folder of unrelated tools never merges them.
    private func groupingRoot(forManifestDirectory manifestDirectory: String, scope: Scope) -> String {
        var root = enclosingWorkspace(of: manifestDirectory, scope: scope) ?? manifestDirectory
        while true {
            let parent = ProjectResolver.parent(of: root)
            guard isStrictlyInside(parent, scope.boundary) else { break }
            let isPart = ProjectResolver.isGenericPartName(ProjectResolver.lastComponent(of: root))
            if !markers(at: parent).manifests.isEmpty {
                if composeFileUses(root, in: parent)
                    || (isPart && isEligibleGroupingParent(parent, scope: scope)) {
                    root = parent
                    continue
                }
                break
            }
            if ProjectResolver.workspaceFolderNames.contains(ProjectResolver.lastComponent(of: parent).lowercased()) {
                let grandparent = ProjectResolver.parent(of: parent)
                if isStrictlyInside(grandparent, scope.boundary), !markers(at: grandparent).manifests.isEmpty,
                   composeFileUses(root, in: grandparent)
                    || (isPart && isEligibleGroupingParent(grandparent, scope: scope)) {
                    root = grandparent
                    continue
                }
            }
            break
        }

        // Sibling rule: "Harbor Notes/backend" + "Harbor Notes/frontend" → "Harbor Notes". Distinctly named
        // folders stay apart: a README or .gitignore next to them is too weak a sign that they form one project.
        let parent = ProjectResolver.parent(of: root)
        if ProjectResolver.isGenericPartName(ProjectResolver.lastComponent(of: root)),
           isEligibleGroupingParent(parent, scope: scope) {
            return parent
        }
        return root
    }

    /// Whether a folder without markers (`directory`) belongs to the nearest enclosing manifest folder. Sources,
    /// build output, hidden tool folders and anything inside a declared workspace do (`myapp/src`,
    /// `svc/target/debug`). A distinctly named folder only does when the enclosing folder is a real project that
    /// holds no other projects: a loose tool next to other tools, or under a package.json that only lists
    /// dependencies, is a project of its own.
    private func belongsToEnclosingManifest(_ directory: String, manifestDirectory: String, scope: Scope) -> Bool {
        let child = ProjectResolver.childOnPath(from: manifestDirectory, to: directory)
        let name = ProjectResolver.lastComponent(of: child)
        if name.hasPrefix(".") || ProjectResolver.isProjectSubfolderName(name) { return true }
        if enclosingWorkspace(of: manifestDirectory, scope: scope) != nil { return true }
        if hasOnlyIncidentalManifests(manifestDirectory) { return false }
        let others = manifestChildren(of: manifestDirectory, limit: 1) { candidate in
            candidate != child && !ProjectResolver.isGenericName(ProjectResolver.lastComponent(of: candidate))
        }
        return others.isEmpty
    }

    private func isEligibleGroupingParent(_ parent: String, scope: Scope) -> Bool {
        guard isStrictlyInside(parent, scope.boundary) else { return false }
        let name = ProjectResolver.lastComponent(of: parent)
        if ProjectResolver.containerFolderNames.contains(name.lowercased()) { return false }
        // Never group under a hidden top-level folder of $HOME (~/.codex, ~/.config...).
        if ProjectResolver.parent(of: parent) == home, name.hasPrefix(".") { return false }
        return true
    }

    /// Immediate sub-folders that contain a primary manifest (at most `limit`, scanning at most 64 entries) and pass
    /// `include` (checked before probing).
    private func manifestChildren(of directory: String, limit: Int,
                                  where include: (String) -> Bool = { _ in true }) -> [String] {
        guard let entries = listDirectoryAt(directory) else { return [] }
        var found: [String] = []
        for entry in entries.sorted().prefix(64) {
            guard !entry.hasPrefix("."), !ProjectResolver.dependencyFolderNames.contains(entry),
                  !ProjectResolver.buildOutputFolderNames.contains(entry) else { continue }
            let child = ProjectResolver.join(directory, entry)
            guard include(child) else { continue }
            if ProjectResolver.primaryManifestFiles.contains(where: { fileExistsAt(ProjectResolver.join(child, $0)) }) {
                found.append(child)
                if found.count >= limit { break }
            }
        }
        return found
    }

    private func combinedMarkers(root: String, nearestManifest: String?) -> [String] {
        let rootMarkers = markers(at: root)
        var result = rootMarkers.hasGit ? [".git"] : []
        result += rootMarkers.manifests
        if let nearestManifest, nearestManifest != root {
            for manifest in markers(at: nearestManifest).manifests where !result.contains(manifest) {
                result.append(manifest)
            }
        }
        return result
    }

    // MARK: - Workspaces

    /// Outermost folder from `directory` up (inside the scope) that declares a workspace, if any.
    private func enclosingWorkspace(of directory: String, scope: Scope) -> String? {
        var found: String?
        var current = directory
        var depth = 0
        while isStrictlyInside(current, scope.boundary), depth < 40 {
            if declaresWorkspace(current) { found = current }
            current = ProjectResolver.parent(of: current)
            depth += 1
        }
        return found
    }

    /// True when `directory` declares a multi-package workspace: package.json "workspaces", pnpm-workspace.yaml,
    /// lerna.json, nx.json, turbo.json, rush.json, go.work, Cargo.toml `[workspace]`, a multi-project Gradle build,
    /// a Maven aggregator (`<modules>`), a uv workspace, a Deno workspace or a Mix umbrella. Cached.
    private func declaresWorkspace(_ directory: String) -> Bool {
        lock.lock()
        if let cached = workspaceCache[directory], cached.expires > now() {
            lock.unlock()
            return cached.value
        }
        lock.unlock()

        let result = computeDeclaresWorkspace(directory)
        store(result, for: directory, in: \.workspaceCache)
        return result
    }

    private func computeDeclaresWorkspace(_ directory: String) -> Bool {
        if ProjectResolver.workspaceMarkerFiles.contains(where: { fileExistsAt(ProjectResolver.join(directory, $0)) }) {
            return true
        }
        func text(_ file: String) -> String? {
            readManifest(ProjectResolver.join(directory, file)).flatMap(ProjectResolver.decodeText)
        }
        let manifests = Set(markers(at: directory).manifests)
        if manifests.contains("package.json"), let data = readManifest(ProjectResolver.join(directory, "package.json")),
           ProjectResolver.packageJSONDeclaresWorkspaces(data) {
            return true
        }
        if manifests.contains("Cargo.toml"), let data = readManifest(ProjectResolver.join(directory, "Cargo.toml")),
           ProjectResolver.tomlDeclaresTable(data, named: "workspace") {
            return true
        }
        if manifests.contains("pyproject.toml"),
           let data = readManifest(ProjectResolver.join(directory, "pyproject.toml")),
           ProjectResolver.tomlDeclaresTable(data, named: "tool.uv.workspace") {
            return true
        }
        if manifests.contains("pom.xml"), text("pom.xml")?.contains("<modules>") == true { return true }
        if manifests.contains("mix.exs"), text("mix.exs")?.contains("apps_path") == true { return true }
        for deno in ["deno.json", "deno.jsonc"] where manifests.contains(deno) {
            if text(deno)?.contains("\"workspace\"") == true { return true }
        }
        for settings in ["settings.gradle", "settings.gradle.kts"]
        where fileExistsAt(ProjectResolver.join(directory, settings)) {
            if let content = text(settings), ProjectResolver.gradleSettingsIncludeProjects(content) { return true }
        }
        return false
    }

    /// True when a compose file in `directory` builds or mounts `member` (a folder below it).
    private func composeFileUses(_ member: String, in directory: String) -> Bool {
        guard member.hasPrefix(directory + "/") else { return false }
        let relative = String(member.dropFirst(directory.count + 1))
        let present = markers(at: directory).manifests
        for file in ProjectResolver.composeFileNames where present.contains(file) {
            if let data = readManifest(ProjectResolver.join(directory, file)),
               ProjectResolver.composeFile(data, references: relative) {
                return true
            }
        }
        return false
    }

    /// True when every manifest in `directory` is incidental: a package.json without a name, scripts or entry
    /// point (what a bare `npm install x` leaves behind) or a Bun lockfile.
    private func hasOnlyIncidentalManifests(_ directory: String) -> Bool {
        for manifest in markers(at: directory).manifests {
            switch manifest {
            case "bun.lockb", "bun.lock":
                continue
            case "package.json":
                guard let data = readManifest(ProjectResolver.join(directory, manifest)),
                      !ProjectResolver.packageJSONDescribesProject(data) else { return false }
            default:
                return false
            }
        }
        return true
    }

    /// `"workspaces"` in a package.json (npm, Yarn, Bun). Falls back to a textual check when the JSON is truncated.
    static func packageJSONDeclaresWorkspaces(_ data: Data) -> Bool {
        if let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            if let list = object["workspaces"] as? [Any] { return !list.isEmpty }
            return object["workspaces"] is [String: Any]
        }
        return decodeText(data)?.contains("\"workspaces\"") == true
    }

    /// A package.json that describes a package (name, scripts, entry point or workspaces) rather than only
    /// listing dependencies. Unreadable JSON counts as a project.
    static func packageJSONDescribesProject(_ data: Data) -> Bool {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return true }
        return !projectPackageKeys.isDisjoint(with: object.keys)
    }

    /// A `[table]` header (or `[table.sub]`) in a TOML file, e.g. `[workspace]` in Cargo.toml.
    static func tomlDeclaresTable(_ data: Data, named table: String) -> Bool {
        guard let text = decodeText(data) else { return false }
        for rawLine in text.split(whereSeparator: { $0 == "\n" || $0 == "\r" }) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard line.hasPrefix("["), !line.hasPrefix("[[") else { continue }
            let header = line.prefix { $0 != "]" }.dropFirst().trimmingCharacters(in: .whitespaces)
            if header == table || header.hasPrefix(table + ".") { return true }
        }
        return false
    }

    /// `include ...` / `include(...)` / `includeBuild` in settings.gradle(.kts): a multi-project build.
    static func gradleSettingsIncludeProjects(_ text: String) -> Bool {
        text.split(whereSeparator: { $0 == "\n" || $0 == "\r" }).contains { line in
            line.trimmingCharacters(in: .whitespaces).hasPrefix("include")
        }
    }

    /// True when a compose file builds or mounts `folder` (a path relative to the compose file):
    /// `build: ./api`, `context: api`, `- ./api:/app`, `source: ./api/data`.
    static func composeFile(_ data: Data, references folder: String) -> Bool {
        guard !folder.isEmpty, let text = decodeText(data) else { return false }
        func matches(_ value: Substring) -> Bool {
            var path = value
            while path.hasPrefix("./") { path = path.dropFirst(2) }
            return path == folder || path == folder + "/" || path.hasPrefix(folder + "/") || path.hasPrefix(folder + ":")
        }
        for rawLine in text.split(whereSeparator: { $0 == "\n" || $0 == "\r" }) {
            let line = rawLine.prefix { $0 != "#" }
            // Explicit relative paths anywhere (volumes, build, env_file...).
            for token in line.split(whereSeparator: { " \t\"',[]{}=".contains($0) }) where token.hasPrefix("./") {
                if matches(token) { return true }
            }
            // `build: api` / `context: api` without "./".
            var trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("- ") { trimmed = String(trimmed.dropFirst(2)) }
            for key in ["build:", "context:"] where trimmed.hasPrefix(key) {
                let value = trimmed.dropFirst(key.count).trimmingCharacters(in: CharacterSet(charactersIn: " \t\"'"))
                if !value.isEmpty, matches(Substring(value)) { return true }
            }
        }
        return false
    }

    // MARK: - Naming

    /// Name rule: `name` from package.json / pyproject.toml ([project] or [tool.poetry]) / Cargo.toml ([package]) at
    /// the root; when it is missing, generic ("app", "backend"...), a template default ("vite-project") or scoped
    /// ("@org/x"): a root that only wraps a single package takes that package's name ("uptime check/uptime-monitor"
    /// → "uptime-monitor"); otherwise the root folder name, prefixed with its parent when generic
    /// ("acme-deploy/release").
    private func projectName(forRoot root: String, scope: Scope) -> String {
        lock.lock()
        if let cached = nameCache[root], cached.expires > now() {
            lock.unlock()
            return cached.value
        }
        lock.unlock()

        let name = computeProjectName(forRoot: root, scope: scope)
        store(name, for: root, in: \.nameCache)
        return name
    }

    private func computeProjectName(forRoot root: String, scope: Scope) -> String {
        if let name = manifestName(in: root), ProjectResolver.isUsableName(name) { return name }

        // A root that merely wraps one distinctively named package is titled after that package. A wrapped generic
        // part ("myrepo/backend") keeps the repository's folder name instead.
        if markers(at: root).manifests.isEmpty {
            let children = manifestChildren(of: root, limit: 2)
            if children.count == 1, let child = children.first {
                let folder = ProjectResolver.lastComponent(of: child)
                if !ProjectResolver.isGenericName(folder) {
                    if let name = manifestName(in: child), ProjectResolver.isUsableName(name) { return name }
                    return folder
                }
            }
        }
        return fallbackName(forRoot: root, scope: scope)
    }

    /// The root folder name, prefixed with its parent when generic ("acme-deploy/release"). Pure.
    private func fallbackName(forRoot root: String, scope: Scope) -> String {
        let folder = ProjectResolver.lastComponent(of: root)
        if ProjectResolver.isGenericName(folder) {
            let parent = ProjectResolver.parent(of: root)
            if isStrictlyInside(parent, scope.boundary) {
                return ProjectResolver.lastComponent(of: parent) + "/" + folder
            }
        }
        return folder
    }

    /// Package name declared by the manifests in `directory`, if any.
    private func manifestName(in directory: String) -> String? {
        let present = markers(at: directory).manifests
        if present.contains("package.json"), let data = readManifest(ProjectResolver.join(directory, "package.json")),
           let name = ProjectResolver.packageJSONName(data) {
            return name
        }
        if present.contains("pyproject.toml"),
           let data = readManifest(ProjectResolver.join(directory, "pyproject.toml")),
           let name = ProjectResolver.tomlName(data, tables: ["project", "tool.poetry"]) {
            return name
        }
        if present.contains("Cargo.toml"), let data = readManifest(ProjectResolver.join(directory, "Cargo.toml")),
           let name = ProjectResolver.tomlName(data, tables: ["package"]) {
            return name
        }
        return nil
    }

    private func readManifest(_ path: String) -> Data? {
        guard let data = readFileAt(path) else { return nil }
        return data.count > Self.maxManifestBytes ? data.prefix(Self.maxManifestBytes) : data
    }

    private static func decodeText(_ data: Data) -> String? {
        String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1)
    }

    /// `"name"` of a package.json. Falls back to a textual scan when the JSON is truncated or malformed.
    static func packageJSONName(_ data: Data) -> String? {
        if let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            return (object["name"] as? String).flatMap(cleanedName)
        }
        guard let text = decodeText(data), let key = text.range(of: "\"name\"") else { return nil }
        var rest = text[key.upperBound...].drop { $0 == " " || $0 == "\t" || $0 == "\n" || $0 == "\r" }
        guard rest.first == ":" else { return nil }
        rest = rest.dropFirst().drop { $0 == " " || $0 == "\t" || $0 == "\n" || $0 == "\r" }
        guard rest.first == "\"" else { return nil }
        let value = rest.dropFirst().prefix { $0 != "\"" && $0 != "\n" }
        return cleanedName(String(value))
    }

    /// `name = "..."` inside one of the given TOML tables (minimal line-based reader; no full TOML parser needed).
    static func tomlName(_ data: Data, tables: Set<String>) -> String? {
        guard let text = decodeText(data) else { return nil }
        var inTable = false
        for rawLine in text.split(whereSeparator: { $0 == "\n" || $0 == "\r" }) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("[") {
                let header = line.trimmingCharacters(in: CharacterSet(charactersIn: "[] \t"))
                inTable = tables.contains(header)
                continue
            }
            guard inTable, line.hasPrefix("name") else { continue }
            let afterKey = line.dropFirst(4).drop { $0 == " " || $0 == "\t" }
            guard afterKey.first == "=" else { continue }
            let value = afterKey.dropFirst().trimmingCharacters(in: .whitespaces)
            guard let quote = value.first, quote == "\"" || quote == "'" else { continue }
            let inner = value.dropFirst().prefix { $0 != quote }
            return cleanedName(String(inner))
        }
        return nil
    }

    private static func cleanedName(_ raw: String) -> String? {
        let name = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return name.isEmpty || name.count > 80 ? nil : name
    }

    static func isUsableName(_ name: String) -> Bool {
        !name.isEmpty && !name.hasPrefix("@") && !isGenericName(name)
    }

    static func isGenericName(_ name: String) -> Bool {
        genericNames.contains(name.lowercased())
    }

    static func isGenericPartName(_ name: String) -> Bool {
        genericPartNames.contains(name.lowercased())
    }

    /// Folder names that are a part of the project around them: sources, build output, tool and workspace folders.
    static func isProjectSubfolderName(_ name: String) -> Bool {
        let lower = name.lowercased()
        return genericNames.contains(lower) || workspaceFolderNames.contains(lower)
            || buildOutputFolderNames.contains(lower) || projectSubfolderNames.contains(lower)
    }

    // MARK: - Argument inference

    /// Directory of the first existing absolute file argument (the script a runtime executes), skipping
    /// arguments in excluded locations. Dependency folders are stripped by `project(forDirectory:)`.
    private func scriptDirectory(arguments: [String]) -> String? {
        for argument in arguments.dropFirst().prefix(16) {
            guard argument.hasPrefix("/"), argument.count > 1 else { continue }
            let path = ProjectResolver.normalize(argument)
            let directory = ProjectResolver.parent(of: path)
            let stripped = ProjectResolver.strippingDependencyFolders(directory)
            guard let scope = scope(for: stripped), isStrictlyInside(stripped, scope.boundary) else { continue }
            if fileExistsAt(path) { return directory }
        }
        return nil
    }

    // MARK: - Scope

    private struct Scope {
        /// The walk never reaches this directory (exclusive upper bound).
        let boundary: String
        /// Folders without markers may still count as a project (ordinary user folders, not hidden tool dirs).
        let allowsMarkerless: Bool
    }

    /// Where `path` may form a project, or nil when the location is excluded. Pure.
    private func scope(for path: String) -> Scope? {
        let parts = ProjectResolver.components(of: path)
        if parts.contains(where: { ProjectResolver.isBundleComponent($0) }) { return nil }

        if parts.count > homeComponents.count, Array(parts.prefix(homeComponents.count)) == homeComponents {
            let relative = Array(parts.dropFirst(homeComponents.count))
            let first = relative[0]
            if first == "Library" { return libraryScope(relative) }
            if ProjectResolver.excludedHomeEntries.contains(first) { return nil }
            if ProjectResolver.excludedHomeSubpaths.contains(where: { relative.starts(with: $0) }) { return nil }
            if ProjectResolver.topLevelContainers.contains(first) {
                guard relative.count >= 2 else { return nil }
                return Scope(boundary: ProjectResolver.join(home, first), allowsMarkerless: true)
            }
            return Scope(boundary: home, allowsMarkerless: !first.hasPrefix("."))
        }
        return externalScope(parts)
    }

    /// iCloud Drive and File Provider folders (Dropbox, Google Drive...) behave like $HOME; the rest of
    /// ~/Library is application data.
    private func libraryScope(_ relative: [String]) -> Scope? {
        guard relative.count >= 4, relative[1] == "Mobile Documents" || relative[1] == "CloudStorage" else {
            return nil
        }
        let base = ProjectResolver.join(home, relative.prefix(3).joined(separator: "/"))
        if ProjectResolver.topLevelContainers.contains(relative[3]) {
            guard relative.count >= 5 else { return nil }
            return Scope(boundary: ProjectResolver.join(base, relative[3]), allowsMarkerless: true)
        }
        return Scope(boundary: base, allowsMarkerless: true)
    }

    /// Code directories outside $HOME; these only count with markers.
    private func externalScope(_ parts: [String]) -> Scope? {
        guard let first = parts.first else { return nil }
        switch first {
        case "Volumes":
            guard parts.count >= 3 else { return nil }
            return Scope(boundary: "/Volumes/" + parts[1], allowsMarkerless: false)
        case "opt":
            guard parts.count >= 2, !ProjectResolver.excludedOptEntries.contains(parts[1]) else { return nil }
            return Scope(boundary: "/opt", allowsMarkerless: false)
        case "srv":
            return Scope(boundary: "/srv", allowsMarkerless: false)
        case "tmp":
            return Scope(boundary: "/tmp", allowsMarkerless: false)
        case "var" where parts.count >= 2 && parts[1] == "www":
            return Scope(boundary: "/var/www", allowsMarkerless: false)
        case "Users" where parts.count >= 2 && parts[1] == "Shared":
            return Scope(boundary: "/Users/Shared", allowsMarkerless: false)
        case "private":
            if parts.count >= 2, parts[1] == "tmp" { return Scope(boundary: "/private/tmp", allowsMarkerless: false) }
            if parts.count >= 3, parts[1] == "var", parts[2] == "www" {
                return Scope(boundary: "/private/var/www", allowsMarkerless: false)
            }
            return nil
        default:
            return nil
        }
    }

    private func isStrictlyInside(_ path: String, _ boundary: String) -> Bool {
        if boundary == "/" { return path != "/" && path.hasPrefix("/") }
        return path.count > boundary.count + 1 && path.hasPrefix(boundary + "/")
    }

    // MARK: - Markers

    private struct DirectoryMarkers {
        let hasGit: Bool
        let manifests: [String]
    }

    private func markers(at directory: String) -> DirectoryMarkers {
        lock.lock()
        if let cached = markerCache[directory], cached.expires > now() {
            lock.unlock()
            return cached.value
        }
        lock.unlock()

        let hasGit = fileExistsAt(ProjectResolver.join(directory, ".git"))
        let manifests = ProjectResolver.manifestFiles.filter { fileExistsAt(ProjectResolver.join(directory, $0)) }
        let result = DirectoryMarkers(hasGit: hasGit, manifests: manifests)
        store(result, for: directory, in: \.markerCache)
        return result
    }

    // MARK: - Cache

    private struct CacheEntry<Value> {
        let value: Value
        let expires: Date
    }

    /// Caches `value`, valid for `cacheLifetime` from now. The lifetime starts when the probe finishes, so an answer
    /// that took long (a folder-access prompt) is not already stale when it lands.
    private func store<Value>(_ value: Value, for key: String,
                              in cache: ReferenceWritableKeyPath<ProjectResolver, [String: CacheEntry<Value>]>) {
        lock.lock()
        defer { lock.unlock() }
        let time = now()
        Self.prune(&self[keyPath: cache], at: time)
        self[keyPath: cache][key] = CacheEntry(value: value, expires: time.addingTimeInterval(Self.cacheLifetime))
    }

    /// Keeps caches bounded: drops expired entries once a cache grows large, everything if still too large.
    private static func prune<Key, Value>(_ cache: inout [Key: CacheEntry<Value>], at time: Date) {
        guard cache.count >= 2048 else { return }
        cache = cache.filter { $0.value.expires > time }
        if cache.count >= 2048 { cache.removeAll(keepingCapacity: true) }
    }

    // MARK: - Path helpers (pure, no file-system access)

    /// Absolute, slash-collapsed path without "." / ".." components or a trailing slash. Symlinks are not resolved
    /// (the kernel already reports real paths for cwd/executables).
    static func normalize(_ path: String) -> String {
        var result: [Substring] = []
        for part in path.split(separator: "/", omittingEmptySubsequences: true) {
            if part == "." { continue }
            if part == ".." {
                if !result.isEmpty { result.removeLast() }
                continue
            }
            result.append(part)
        }
        return "/" + result.joined(separator: "/")
    }

    static func components(of path: String) -> [String] {
        path.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
    }

    static func parent(of path: String) -> String {
        guard let slash = path.lastIndex(of: "/"), slash != path.startIndex else { return "/" }
        return String(path[..<slash])
    }

    static func lastComponent(of path: String) -> String {
        guard let slash = path.lastIndex(of: "/") else { return path }
        return String(path[path.index(after: slash)...])
    }

    static func join(_ directory: String, _ name: String) -> String {
        directory == "/" ? "/" + name : directory + "/" + name
    }

    /// The direct child of `ancestor` on the way to `path` ("/a" + "/a/b/c" → "/a/b"); `path` when not below it.
    static func childOnPath(from ancestor: String, to path: String) -> String {
        let prefix = ancestor == "/" ? "/" : ancestor + "/"
        guard path.hasPrefix(prefix), path.count > prefix.count,
              let first = path.dropFirst(prefix.count).split(separator: "/").first else { return path }
        return join(ancestor, String(first))
    }

    /// Cuts a path at the first dependency folder: ".../app/node_modules/vite/bin" → ".../app",
    /// ".../api/.venv/bin" → ".../api".
    static func strippingDependencyFolders(_ path: String) -> String {
        let parts = components(of: path)
        for (index, part) in parts.enumerated() {
            let isDependency = dependencyFolderNames.contains(part)
                || (part == "env" && index + 1 < parts.count && (parts[index + 1] == "bin" || parts[index + 1] == "lib"))
            if isDependency {
                return "/" + parts[..<index].joined(separator: "/")
            }
        }
        return path
    }

    private static func isBundleComponent(_ component: String) -> Bool {
        component.hasSuffix(".app") || component.hasSuffix(".framework") || component.hasSuffix(".appex")
            || component.hasSuffix(".xpc") || component.hasSuffix(".bundle")
    }

    // MARK: - Default file system

    private static func diskFileExists(_ path: String) -> Bool {
        path.withCString { access($0, F_OK) == 0 }
    }

    /// Reads at most `limit` bytes of a regular file without blocking on FIFOs/devices.
    private static func diskReadPrefix(path: String, limit: Int) -> Data? {
        let descriptor = path.withCString { open($0, O_RDONLY | O_NONBLOCK | O_CLOEXEC) }
        guard descriptor >= 0 else { return nil }
        defer { close(descriptor) }
        var info = stat()
        guard fstat(descriptor, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG else { return nil }
        let capacity = max(0, min(limit, Int(info.st_size)))
        var data = Data(count: capacity)
        var total = 0
        let ok: Bool = data.withUnsafeMutableBytes { (buffer: UnsafeMutableRawBufferPointer) -> Bool in
            guard let base = buffer.baseAddress else { return true }   // empty file
            while total < capacity {
                let count = read(descriptor, base + total, capacity - total)
                if count > 0 {
                    total += count
                } else if count == 0 {
                    break
                } else if errno != EINTR {
                    return false
                }
            }
            return true
        }
        guard ok else { return nil }
        return total == capacity ? data : data.prefix(total)
    }

    // MARK: - Tables

    /// Folder names that describe a part of a project rather than the project itself.
    static let genericPartNames: Set<String> = [
        "frontend", "backend", "server", "client", "web", "api", "app", "ui", "admin", "worker", "www", "site",
        "website", "front", "back", "front-end", "back-end", "webapp", "web-app", "mobile", "service", "services",
        "dashboard", "docs",
    ]

    /// Names too generic to title a project (manifest names and folder names alike), incl. template defaults.
    static let genericNames: Set<String> = genericPartNames.union([
        "src", "code", "main", "master", "release", "releases", "current", "dist", "build", "deploy", "deployment",
        "prod", "production", "staging", "live", "project", "repo", "workspace", "root", "test", "tmp", "temp",
        "demo", "example", "html", "public", "public_html", "core", "apps", "packages", "my-app", "my-project",
        "vite-project", "react-app", "my-react-app", "vue-project", "svelte-app", "nuxt-app", "next-app",
        "my-next-app", "astro-project", "remix-app", "untitled", "starter", "template",
    ])

    /// Usual sub-folders of a project (in addition to generic, workspace and build-output names).
    static let projectSubfolderNames: Set<String> = [
        "source", "sources", "lib", "bin", "pkg", "static", "assets", "resources", "res", "scripts", "script",
        "tests", "spec", "specs", "e2e", "samples", "doc", "config", "configs", "templates", "views", "routes",
        "pages", "components", "data", "db", "migrations", "notebooks", "output", "debug", "logs", "storage",
        "fixtures", "include", "priv", "bench", "benches", "benchmarks",
    ]

    /// Folders that typically hold many unrelated projects; never a grouping parent.
    static let containerFolderNames: Set<String> = [
        "code", "projects", "project", "dev", "developer", "development", "src", "repos", "repositories", "git",
        "github", "gitlab", "sites", "workspace", "workspaces", "work", "sandbox", "playground", "experiments",
        "downloads", "desktop", "documents", "tmp", "temp", "archive", "old", "clones", "forks", "programming",
        "coding", "tools", "scripts", "apps",
    ]

    /// Direct children of $HOME that are containers: the walk stops below them and they are never a project.
    static let topLevelContainers: Set<String> = [
        "Downloads", "Desktop", "Documents", "Developer", "Projects", "projects", "Code", "code", "src", "dev", "Dev",
        "repos", "Repos", "git", "GitHub", "Github", "github", "Sites", "workspace", "Workspace", "workspaces",
        "Development", "Programming",
    ]

    /// Direct children of $HOME behind a macOS privacy prompt (Files & Folders).
    static let protectedHomeFolders: Set<String> = ["Desktop", "Documents", "Downloads"]

    /// Monorepo folders that sit between a package and its workspace root.
    static let workspaceFolderNames: Set<String> = [
        "packages", "apps", "services", "libs", "modules", "crates", "workspaces", "plugins", "examples", "tools",
        "cmd", "internal",
    ]

    /// Files whose presence alone declares a multi-package workspace.
    static let workspaceMarkerFiles: [String] = [
        "pnpm-workspace.yaml", "lerna.json", "nx.json", "turbo.json", "rush.json", "go.work",
    ]

    static let composeFileNames: [String] = [
        "docker-compose.yml", "docker-compose.yaml", "compose.yml", "compose.yaml",
    ]

    /// package.json keys that make it describe a package rather than only list dependencies.
    private static let projectPackageKeys: Set<String> = [
        "name", "scripts", "main", "module", "bin", "exports", "workspaces",
    ]

    static let dependencyFolderNames: Set<String> = [
        "node_modules", ".venv", "venv", "site-packages", "dist-packages", ".bin", "__pypackages__", ".tox", ".nox",
    ]

    private static let buildOutputFolderNames: Set<String> = [
        "dist", "build", "target", "out", ".next", ".nuxt", "__pycache__", "vendor", "coverage",
    ]

    /// Tool installs and caches under $HOME (they contain package.json files but are not the user's projects).
    static let excludedHomeEntries: Set<String> = [
        "Applications", ".Trash", ".npm", ".cache", ".bun", ".deno", ".nvm", ".fnm", ".volta", ".asdf", ".pyenv",
        ".rbenv", ".rustup", ".cargo", ".local", ".vscode", ".vscode-insiders", ".vscode-server", ".windsurf",
        ".antigravity", ".antigravity-ide", ".gradle", ".m2", ".pnpm-store", ".yarn", ".docker", ".conda",
        ".anaconda", ".gem", ".pub-cache", ".dotnet", ".nuget", ".ollama", ".lmstudio", ".node-gyp", ".expo",
        ".cocoapods", ".android", ".sdkman", ".jenv", ".pm2", ".colima", ".orbstack", ".lima", ".swiftpm",
        ".kiro", ".cursor-server", "miniconda3", "anaconda3", "miniforge3", "mambaforge", "Pictures", "Music",
        "Movies",
    ]

    static let excludedHomeSubpaths: [[String]] = [
        [".cursor", "extensions"], [".claude", "plugins"], [".claude", "local"], [".codex", "plugins"],
        ["go", "pkg"], [".config", "yarn"],
    ]

    private static let excludedOptEntries: Set<String> = [
        "homebrew", "local", "X11", "miniconda3", "anaconda3", "miniforge3", "conda",
    ]
}
