import Darwin
import Foundation

/// Maps a process to the project folder it belongs to (the grouping key in the panel).
///
/// Thread-safe: all mutable state is behind `lock`; file-system probes run outside the lock. Directory lookups are
/// cached for 60 s so a scan tick normally costs a few dictionary lookups. The file system is injectable so the
/// heuristics can be unit-tested against a fake tree.
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

    private let home: String
    private let homeComponents: [String]
    private let fileExistsAt: (String) -> Bool
    private let readFileAt: (String) -> Data?
    private let listDirectoryAt: (String) -> [String]?
    private let now: () -> Date

    private let lock = NSLock()
    private var projectCache: [String: CacheEntry<ProjectInfo?>] = [:]
    private var markerCache: [String: CacheEntry<DirectoryMarkers>] = [:]
    private var nameCache: [String: CacheEntry<String>] = [:]

    /// - Parameters:
    ///   - fileExists / readFile / listDirectory: file-system access, injectable for tests. Each defaults to the real
    ///     disk; `listDirectory` defaults to "no listing" when `fileExists` is injected so a fake tree stays hermetic.
    ///   - now: clock used for cache expiry.
    init(homeDirectory: String = NSHomeDirectory(),
         fileExists: ((String) -> Bool)? = nil,
         readFile: ((String) -> Data?)? = nil,
         listDirectory: ((String) -> [String]?)? = nil,
         now: @escaping () -> Date = Date.init) {
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
    }

    // MARK: - Public API

    /// Determines the project for a process. Order: cwd (if not "/" and not inside an .app bundle or a system dir)
    /// → script path inferred from argv (first existing absolute file arg; stripped at node_modules/.venv/venv/
    /// site-packages/.bin) → $VIRTUAL_ENV → executable path if it lives in a project
    /// (e.g. ~/code/foo/target/debug/server).
    ///
    /// A folder without any marker (no .git, no manifest) only counts for language runtimes (`python -m http.server`
    /// in ~/Sites/demo) or binaries living in that folder — never for tools like an MCP server that merely
    /// inherited a cwd. GUI application processes never belong to a project.
    /// Returns nil for things outside $HOME (except /opt, /srv, /var/www, /Volumes style code dirs that have markers)
    /// and for $HOME itself / ~/Downloads / ~/Desktop / ~/Documents roots.
    func resolve(details: ProcessDetails?) -> ProjectInfo? {
        guard let details else { return nil }
        if let executable = details.executablePath, Classifier.isApplicationExecutable(executable) { return nil }
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
            let directory = ProjectResolver.parent(of: ProjectResolver.normalize(executable))
            let inBinFolder = ProjectResolver.lastComponent(of: directory) == "bin"
            if let found = consider(directory, allowMarkerless: !isRuntime && !inBinFolder) { return found }
        }
        return markerless
    }

    /// Walks up from `directory` (stops at $HOME, a top-level container such as ~/Downloads, or "/"):
    /// rootPath = nearest ancestor with `.git` (dir or file), else the outermost ancestor with a manifest that is
    /// still a direct code root (sibling-manifest rule: a generic part like "backend" whose parent also holds other
    /// parts is grouped under that parent), else `directory`. `subpath` = nearest manifest dir relative to rootPath
    /// (nil when same). Returns nil for excluded locations (system dirs, tool caches, app bundles, container roots).
    func project(forDirectory directory: String) -> ProjectInfo? {
        let key = ProjectResolver.normalize(directory)
        let time = now()
        lock.lock()
        if let cached = projectCache[key], cached.expires > time {
            lock.unlock()
            return cached.value
        }
        lock.unlock()

        let info = computeProject(startingAt: key)

        lock.lock()
        Self.prune(&projectCache, at: time)
        projectCache[key] = CacheEntry(value: info, expires: time.addingTimeInterval(Self.cacheLifetime))
        lock.unlock()
        return info
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

    /// Without a git root: climb through enclosing manifests (monorepo roots, also across workspace folders such as
    /// `packages/`), then apply the sibling-manifest rule.
    private func groupingRoot(forManifestDirectory manifestDirectory: String, scope: Scope) -> String {
        var root = manifestDirectory
        while true {
            let parent = ProjectResolver.parent(of: root)
            guard isStrictlyInside(parent, scope.boundary) else { break }
            if !markers(at: parent).manifests.isEmpty {
                root = parent
                continue
            }
            if ProjectResolver.workspaceFolderNames.contains(ProjectResolver.lastComponent(of: parent).lowercased()) {
                let grandparent = ProjectResolver.parent(of: parent)
                if isStrictlyInside(grandparent, scope.boundary), !markers(at: grandparent).manifests.isEmpty {
                    root = grandparent
                    continue
                }
            }
            break
        }

        // Sibling-manifest rule: "Institut de mai/backend" + "Institut de mai/frontend" → "Institut de mai".
        let parent = ProjectResolver.parent(of: root)
        guard isEligibleGroupingParent(parent, scope: scope) else { return root }
        if ProjectResolver.genericPartNames.contains(ProjectResolver.lastComponent(of: root).lowercased()) {
            return parent
        }
        // Distinctively named parts are only merged when the parent looks like a repository root (README,
        // .gitignore...) — a plain folder holding unrelated projects must never become one group.
        if hasRepositoryMarker(parent), manifestChildren(of: parent, limit: 2).count >= 2 {
            return parent
        }
        return root
    }

    private func isEligibleGroupingParent(_ parent: String, scope: Scope) -> Bool {
        guard isStrictlyInside(parent, scope.boundary) else { return false }
        let name = ProjectResolver.lastComponent(of: parent)
        if ProjectResolver.containerFolderNames.contains(name.lowercased()) { return false }
        // Never group under a hidden top-level folder of $HOME (~/.codex, ~/.config...).
        if ProjectResolver.parent(of: parent) == home, name.hasPrefix(".") { return false }
        return true
    }

    private func hasRepositoryMarker(_ directory: String) -> Bool {
        ProjectResolver.repositoryMarkerFiles.contains { fileExistsAt(ProjectResolver.join(directory, $0)) }
    }

    /// Immediate sub-folders that contain a primary manifest (at most `limit`, scanning at most 64 entries).
    private func manifestChildren(of directory: String, limit: Int) -> [String] {
        guard let entries = listDirectoryAt(directory) else { return [] }
        var found: [String] = []
        for entry in entries.sorted().prefix(64) {
            guard !entry.hasPrefix("."), !ProjectResolver.dependencyFolderNames.contains(entry),
                  !ProjectResolver.buildOutputFolderNames.contains(entry) else { continue }
            let child = ProjectResolver.join(directory, entry)
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

    // MARK: - Naming

    /// Name rule: `name` from package.json / pyproject.toml ([project] or [tool.poetry]) / Cargo.toml ([package]) at
    /// the root; when it is missing, generic ("app", "backend"...), a template default ("vite-project") or scoped
    /// ("@org/x"): a root that only wraps a single package takes that package's name ("claude check/claude-monitor"
    /// → "claude-monitor"); otherwise the root folder name, prefixed with its parent when generic
    /// ("idm-deploy/release").
    private func projectName(forRoot root: String, scope: Scope) -> String {
        let time = now()
        lock.lock()
        if let cached = nameCache[root], cached.expires > time {
            lock.unlock()
            return cached.value
        }
        lock.unlock()

        let name = computeProjectName(forRoot: root, scope: scope)

        lock.lock()
        Self.prune(&nameCache, at: time)
        nameCache[root] = CacheEntry(value: name, expires: time.addingTimeInterval(Self.cacheLifetime))
        lock.unlock()
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

    /// `"name"` of a package.json. Falls back to a textual scan when the JSON is truncated or malformed.
    static func packageJSONName(_ data: Data) -> String? {
        if let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            return (object["name"] as? String).flatMap(cleanedName)
        }
        guard let text = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1),
              let key = text.range(of: "\"name\"") else { return nil }
        var rest = text[key.upperBound...].drop { $0 == " " || $0 == "\t" || $0 == "\n" || $0 == "\r" }
        guard rest.first == ":" else { return nil }
        rest = rest.dropFirst().drop { $0 == " " || $0 == "\t" || $0 == "\n" || $0 == "\r" }
        guard rest.first == "\"" else { return nil }
        let value = rest.dropFirst().prefix { $0 != "\"" && $0 != "\n" }
        return cleanedName(String(value))
    }

    /// `name = "..."` inside one of the given TOML tables (minimal line-based reader; no full TOML parser needed).
    static func tomlName(_ data: Data, tables: Set<String>) -> String? {
        guard let text = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1) else {
            return nil
        }
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

    /// Where `path` may form a project, or nil when the location is excluded.
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
        let time = now()
        lock.lock()
        if let cached = markerCache[directory], cached.expires > time {
            lock.unlock()
            return cached.value
        }
        lock.unlock()

        let hasGit = fileExistsAt(ProjectResolver.join(directory, ".git"))
        let manifests = ProjectResolver.manifestFiles.filter { fileExistsAt(ProjectResolver.join(directory, $0)) }
        let result = DirectoryMarkers(hasGit: hasGit, manifests: manifests)

        lock.lock()
        Self.prune(&markerCache, at: time)
        markerCache[directory] = CacheEntry(value: result, expires: time.addingTimeInterval(Self.cacheLifetime))
        lock.unlock()
        return result
    }

    // MARK: - Cache

    private struct CacheEntry<Value> {
        let value: Value
        let expires: Date
    }

    /// Keeps caches bounded: drops expired entries once a cache grows large, everything if still too large.
    private static func prune<Value>(_ cache: inout [String: CacheEntry<Value>], at time: Date) {
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

    /// Monorepo folders that sit between a package and its workspace root.
    static let workspaceFolderNames: Set<String> = [
        "packages", "apps", "services", "libs", "modules", "crates", "workspaces", "plugins", "examples", "tools",
        "cmd", "internal",
    ]

    static let dependencyFolderNames: Set<String> = [
        "node_modules", ".venv", "venv", "site-packages", "dist-packages", ".bin", "__pypackages__", ".tox", ".nox",
    ]

    private static let buildOutputFolderNames: Set<String> = [
        "dist", "build", "target", "out", ".next", ".nuxt", "__pycache__", "vendor", "coverage",
    ]

    private static let repositoryMarkerFiles = [
        ".gitignore", "README.md", "README", "README.rst", "readme.md", ".editorconfig", "docker-compose.yml",
        "docker-compose.yaml", "compose.yml", "compose.yaml",
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
