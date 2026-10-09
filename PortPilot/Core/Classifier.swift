import Foundation

/// Heuristics that turn raw process facts (executable, argv, environment, ancestry) into what the UI shows:
/// category, app name, framework badges, row label, launch origin, watcher, plus the two safety predicates the
/// kill planner relies on (`isBoundaryProcess`, `isRunnerProcess`).
///
/// Everything is pure string work except `appBundle(forExecutable:)`, which reads one Info.plist per bundle and
/// caches the result. All functions are safe to call from any thread.
enum Classifier {

    // MARK: - Category

    /// .system: other uid, or executable under /System, /usr/libexec, /usr/sbin, /sbin, /usr/bin (except dev
    ///          runtimes), /Library/Apple, or an Apple daemon we could not inspect (rapportd, sharingd...).
    /// .app:    executable inside a *.app bundle that is not a dev runtime and has no project
    ///          (VS Code helpers, Spotify, Antigravity language_server...). Well-known servers shipped inside an app
    ///          (Postgres.app, Ollama.app) are treated as services.
    /// .project: has a ProjectInfo.
    /// .service: everything else owned by the user (Homebrew postgres/redis, tunnels, launchd agents).
    static func category(basic: ProcessBasic, details: ProcessDetails?, project: ProjectInfo?,
                         manager: ProcessManager, currentUID: UInt32) -> ListenerCategory {
        if basic.uid != currentUID { return .system }
        guard let details else {
            if appleDaemonNames.contains(basic.comm) { return .system }
            return project == nil ? .service : .project
        }
        let exePath = details.executablePath ?? ""
        let exeName = details.executableName.isEmpty ? basic.comm : details.executableName
        if isSystemExecutable(exePath), !isDevRuntime(name: exeName) { return .system }
        if project != nil { return .project }
        if isApplicationExecutable(exePath) {
            return knownServerExecutables.contains(exeName.lowercased()) ? .service : .app
        }
        return .service
    }

    /// True for executables that belong to the OS (Apple-owned locations).
    static func isSystemExecutable(_ path: String) -> Bool {
        guard !path.isEmpty else { return false }
        return systemPrefixes.contains { path.hasPrefix($0) }
    }

    /// True when `path` runs from inside a GUI application bundle. Runtimes that merely live in an `.app`
    /// inside a framework (Homebrew/Xcode `Python.framework/.../Python.app`) and Electron builds under
    /// `node_modules` (apps being developed) do not count.
    static func isApplicationExecutable(_ path: String) -> Bool {
        guard path.contains(".app/") else { return false }
        if path.contains("/node_modules/") { return false }
        if path.contains(".framework/"), isDevRuntime(name: lastPathComponent(path)) { return false }
        return true
    }

    // MARK: - App bundles

    /// Outermost ".app" bundle in the path → its CFBundleDisplayName/CFBundleName (read Info.plist, cached) or
    /// folder name sans ".app". The folder name wins when it is a longer form of the plist name
    /// ("Visual Studio Code" over "Code") because that is what the user sees in Finder and Spotlight.
    static func appBundle(forExecutable path: String) -> (name: String, bundlePath: String)? {
        let components = path.split(separator: "/", omittingEmptySubsequences: true)
        guard let index = components.firstIndex(where: { $0.hasSuffix(".app") && $0.count > 4 }) else { return nil }
        let bundlePath = "/" + components[...index].joined(separator: "/")
        let folderName = String(components[index].dropLast(4))
        let name = bundleNames.value(for: bundlePath) {
            readBundleName(bundlePath: bundlePath, folderName: folderName)
        }
        return (name, bundlePath)
    }

    private static func readBundleName(bundlePath: String, folderName: String) -> String {
        let candidates = [bundlePath + "/Contents/Info.plist", bundlePath + "/Info.plist"]
        for plistPath in candidates {
            guard let data = FileManager.default.contents(atPath: plistPath),
                  let plist = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil)
                    as? [String: Any] else { continue }
            let raw = (plist["CFBundleDisplayName"] as? String) ?? (plist["CFBundleName"] as? String) ?? ""
            let plistName = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            if plistName.isEmpty || plistName.lowercased() == "electron" { return folderName }
            if folderName.localizedCaseInsensitiveContains(plistName) { return folderName }
            return plistName
        }
        return folderName
    }

    // MARK: - Frameworks

    /// Framework/tool hints from argv/exe: Vite, Next.js, Nuxt, Astro, Remix, SvelteKit, Webpack, Parcel, Storybook,
    /// Expo, Metro, Angular, NestJS, uvicorn, gunicorn, FastAPI, Flask, Django, Streamlit, Gradio, Jupyter,
    /// http.server, Rails, Puma, PHP, Laravel, Hugo, Jekyll, nginx, Caddy, PostgreSQL, Redis, MySQL, MongoDB,
    /// Ollama, cloudflared, ngrok, Bun, Deno, Go, Rust, Java/Spring, .NET. Falls back to the runtime
    /// ("Node.js", "Python", "Ruby") when nothing more specific is recognised.
    static func frameworks(details: ProcessDetails?, comm: String) -> [String] {
        let command = CommandAnalysis(details: details, comm: comm)
        var result: [String] = []
        func add(_ name: String) { if !result.contains(name) { result.append(name) } }

        for key in command.lookupKeys {
            if let name = toolFrameworks[key] { add(name) }
        }
        if command.runtime == "python", command.scriptStem == "manage" { add("Django") }

        switch command.runtime {
        case "bun": add("Bun")
        case "deno": add("Deno")
        case "go": add("Go")
        case "dotnet": add(".NET")
        case "php": add("PHP")
        case "java":
            add(command.argv.contains { $0.lowercased().contains("spring") } ? "Spring" : "Java")
        case "beam":
            add(command.argv.contains("phx.server") ? "Phoenix" : "Elixir")
        default: break
        }
        if command.exeKey == "cargo" || command.exePath.contains("/target/debug/")
            || command.exePath.contains("/target/release/") {
            add("Rust")
        }
        if command.exePath.contains("/go-build") { add("Go") }

        if result.isEmpty {
            switch command.runtime {
            case "node": add("Node.js")
            case "python": add("Python")
            case "ruby": add("Ruby")
            default: break
            }
        }
        return result
    }

    // MARK: - Display name

    /// Short row label: e.g. "vite", "next dev", "uvicorn app.main:app", "python app.py", "postgres",
    /// "node server.js", "cloudflared tunnel", "nginx worker".
    static func displayName(basic: ProcessBasic, details: ProcessDetails?) -> String {
        guard details != nil else { return basic.comm }
        let command = CommandAnalysis(details: details, comm: basic.comm)
        let label = command.label
        return label.isEmpty ? basic.comm : clamp(label, to: 60)
    }

    // MARK: - Launch origin

    /// Who started this tree — uses ancestor names/paths first (claude, codex, Terminal, iTerm2, Warp, Ghostty,
    /// kitty, WezTerm, Alacritty, Code Helper, Cursor, Zed, Xcode, tmux, PM2), then the environment inherited at
    /// exec time (CLAUDECODE=1 / CLAUDE_CODE_*, CODEX_*, TERM_PROGRAM, __CFBundleIdentifier, VSCODE_*, CURSOR_*,
    /// TMUX), which survives the process being re-parented to launchd. A real launchd job label wins over both.
    static func origin(details: ProcessDetails?, ancestors: [ProcessBasic],
                       ancestorDetails: (Int32) -> ProcessDetails?, launchdLabel: String?) -> LaunchOrigin? {
        if let label = launchdLabel, !label.isEmpty, !label.hasPrefix("application.") {
            return LaunchOrigin(kind: .launchd, name: "launchd")
        }
        for ancestor in ancestors where ancestor.pid > 1 {
            if let origin = originOfAncestor(ancestor, ancestorDetails: ancestorDetails) { return origin }
        }
        if let environment = details?.environment, let origin = originFromEnvironment(environment) {
            return origin
        }
        return nil
    }

    private static func originOfAncestor(_ ancestor: ProcessBasic,
                                         ancestorDetails: (Int32) -> ProcessDetails?) -> LaunchOrigin? {
        let comm = ancestor.comm
        if let agent = agentOrigin(forExecutableName: comm) { return agent }
        switch comm.lowercased() {
        case "tmux": return LaunchOrigin(kind: .terminal, name: "tmux")
        case "screen": return LaunchOrigin(kind: .terminal, name: "screen")
        case "zellij": return LaunchOrigin(kind: .terminal, name: "zellij")
        case "sshd", "sshd-session": return LaunchOrigin(kind: .terminal, name: "SSH")
        case "zsh", "bash", "sh", "fish", "dash", "login", "sudo", "env", "nohup", "disclaimer":
            return nil
        default: break
        }

        guard let details = ancestorDetails(ancestor.pid) else { return nil }
        let command = CommandAnalysis(details: details, comm: comm)
        if command.processTitle?.hasPrefix("PM2") == true { return LaunchOrigin(kind: .pm2, name: "PM2") }
        if command.runtime != nil, let agent = agentOrigin(forCommandLine: command.argv) { return agent }
        if let agent = agentOrigin(forExecutableName: command.exeName) { return agent }

        let exePath = details.executablePath ?? ""
        guard isApplicationExecutable(exePath), let bundle = appBundle(forExecutable: exePath) else { return nil }
        let folder = (bundle.bundlePath as NSString).lastPathComponent.replacingOccurrences(of: ".app", with: "")
        if let known = knownAppOrigin(folderName: folder) { return known }
        if isSystemExecutable(exePath) { return nil }
        return LaunchOrigin(kind: .app, name: bundle.name)
    }

    private static func agentOrigin(forExecutableName name: String) -> LaunchOrigin? {
        switch name.lowercased() {
        case "claude":
            // "claude" is the Claude Code CLI; the desktop app is "Claude" (capitalised).
            return name == "claude" ? LaunchOrigin(kind: .claudeCode, name: "Claude Code") : nil
        case "codex": return LaunchOrigin(kind: .codex, name: "Codex")
        case "gemini": return LaunchOrigin(kind: .aiAgent, name: "Gemini CLI")
        case "aider": return LaunchOrigin(kind: .aiAgent, name: "Aider")
        case "opencode": return LaunchOrigin(kind: .aiAgent, name: "opencode")
        case "goose": return LaunchOrigin(kind: .aiAgent, name: "Goose")
        case "amp": return LaunchOrigin(kind: .aiAgent, name: "Amp")
        case "cursor-agent": return LaunchOrigin(kind: .aiAgent, name: "Cursor Agent")
        case "crush": return LaunchOrigin(kind: .aiAgent, name: "Crush")
        case "qwen": return LaunchOrigin(kind: .aiAgent, name: "Qwen Code")
        case "droid": return LaunchOrigin(kind: .aiAgent, name: "Droid")
        default: return nil
        }
    }

    /// Agents distributed as node/python scripts show up as "node .../claude-code/cli.js" etc.
    private static func agentOrigin(forCommandLine argv: [String]) -> LaunchOrigin? {
        for argument in argv.prefix(3) {
            let lower = argument.lowercased()
            if lower.contains("claude-code") || lower.hasSuffix("/bin/claude") || lower.contains("@anthropic-ai/claude") {
                return LaunchOrigin(kind: .claudeCode, name: "Claude Code")
            }
            if lower.contains("@openai/codex") || lower.hasSuffix("/bin/codex") {
                return LaunchOrigin(kind: .codex, name: "Codex")
            }
            if lower.contains("gemini-cli") || lower.hasSuffix("/bin/gemini") {
                return LaunchOrigin(kind: .aiAgent, name: "Gemini CLI")
            }
            if lower.hasSuffix("/bin/aider") { return LaunchOrigin(kind: .aiAgent, name: "Aider") }
            if lower.contains("opencode") { return LaunchOrigin(kind: .aiAgent, name: "opencode") }
        }
        return nil
    }

    private static func knownAppOrigin(folderName: String) -> LaunchOrigin? {
        let lower = folderName.lowercased()
        for (prefix, name) in terminalApps where lower.hasPrefix(prefix) {
            return LaunchOrigin(kind: .terminal, name: name)
        }
        for (prefix, name) in ideApps where lower.hasPrefix(prefix) {
            return LaunchOrigin(kind: .ide, name: name ?? folderName)
        }
        if lower == "codex" { return LaunchOrigin(kind: .codex, name: "Codex") }
        return nil
    }

    private static func originFromEnvironment(_ env: [String: String]) -> LaunchOrigin? {
        if env["CLAUDECODE"] == "1" || env["CLAUDE_CODE_ENTRYPOINT"] != nil {
            return LaunchOrigin(kind: .claudeCode, name: "Claude Code")
        }
        if codexEnvironmentKeys.contains(where: { env[$0] != nil }) {
            return LaunchOrigin(kind: .codex, name: "Codex")
        }
        if env["GEMINI_CLI"] != nil { return LaunchOrigin(kind: .aiAgent, name: "Gemini CLI") }
        if let agent = env["AI_AGENT"]?.lowercased(), !agent.isEmpty {
            if agent.hasPrefix("claude") { return LaunchOrigin(kind: .claudeCode, name: "Claude Code") }
            if agent.hasPrefix("codex") { return LaunchOrigin(kind: .codex, name: "Codex") }
            if agent.hasPrefix("gemini") { return LaunchOrigin(kind: .aiAgent, name: "Gemini CLI") }
            if agent.hasPrefix("cursor") { return LaunchOrigin(kind: .aiAgent, name: "Cursor Agent") }
            return LaunchOrigin(kind: .aiAgent, name: "AI agent")
        }
        if env["CURSOR_TRACE_ID"] != nil || env["CURSOR_AGENT"] != nil {
            return LaunchOrigin(kind: .ide, name: "Cursor")
        }
        let bundleID = env["__CFBundleIdentifier"]
        if let program = env["TERM_PROGRAM"] {
            switch program {
            case "Apple_Terminal": return LaunchOrigin(kind: .terminal, name: "Terminal")
            case "iTerm.app": return LaunchOrigin(kind: .terminal, name: "iTerm2")
            case "WarpTerminal": return LaunchOrigin(kind: .terminal, name: "Warp")
            case "ghostty": return LaunchOrigin(kind: .terminal, name: "Ghostty")
            case "WezTerm": return LaunchOrigin(kind: .terminal, name: "WezTerm")
            case "Hyper": return LaunchOrigin(kind: .terminal, name: "Hyper")
            case "Tabby": return LaunchOrigin(kind: .terminal, name: "Tabby")
            case "tmux": return LaunchOrigin(kind: .terminal, name: "tmux")
            case "zed": return LaunchOrigin(kind: .ide, name: "Zed")
            case "vscode":
                if let bundleID, let known = bundleIdentifierOrigins[bundleID], known.kind == .ide { return known }
                return LaunchOrigin(kind: .ide, name: "VS Code")
            default: break
            }
        }
        if env["TMUX"] != nil { return LaunchOrigin(kind: .terminal, name: "tmux") }
        if env["KITTY_WINDOW_ID"] != nil { return LaunchOrigin(kind: .terminal, name: "kitty") }
        if env["ALACRITTY_WINDOW_ID"] != nil || env["ALACRITTY_SOCKET"] != nil {
            return LaunchOrigin(kind: .terminal, name: "Alacritty")
        }
        if env["WEZTERM_PANE"] != nil { return LaunchOrigin(kind: .terminal, name: "WezTerm") }
        if env["GHOSTTY_RESOURCES_DIR"] != nil { return LaunchOrigin(kind: .terminal, name: "Ghostty") }
        if env["TERMINAL_EMULATOR"]?.hasPrefix("JetBrains") == true {
            return LaunchOrigin(kind: .ide, name: "JetBrains")
        }
        if env["VSCODE_PID"] != nil || env["VSCODE_IPC_HOOK_CLI"] != nil {
            return LaunchOrigin(kind: .ide, name: "VS Code")
        }
        if let bundleID, let known = bundleIdentifierOrigins[bundleID] { return known }
        return nil
    }

    // MARK: - Watchers

    /// Watcher/supervisor detection among self + ancestors (nearest first, stopping at boundary processes):
    /// nodemon, tsx watch, ts-node-dev, node --watch, bun --watch/--hot, deno --watch, uvicorn/gunicorn --reload,
    /// Flask/Werkzeug and Django autoreloaders, watchfiles, cargo watch, air, reflex, entr, watchexec,
    /// concurrently, turbo, dotnet watch.
    static func watcherName(for basic: ProcessBasic, details: ProcessDetails?, ancestors: [ProcessBasic],
                            ancestorDetails: (Int32) -> ProcessDetails?) -> String? {
        let own = CommandAnalysis(details: details, comm: basic.comm)
        if let name = watcherSignature(own, environment: details?.environment ?? [:]) { return name }
        for ancestor in ancestors.prefix(8) where ancestor.pid > 1 {
            let ancestorInfo = ancestorDetails(ancestor.pid)
            if isBoundaryProcess(basic: ancestor, details: ancestorInfo) { break }
            let command = CommandAnalysis(details: ancestorInfo, comm: ancestor.comm)
            if let name = watcherSignature(command, environment: [:]) { return name }
        }
        return nil
    }

    private static func watcherSignature(_ command: CommandAnalysis, environment: [String: String]) -> String? {
        let tool = command.toolKey ?? command.exeKey
        let options = command.interpreterOptions
        switch tool {
        case "nodemon": return "nodemon"
        case "ts-node-dev", "tsnd": return "ts-node-dev"
        case "node-dev": return "node-dev"
        case "forever": return "forever"
        case "concurrently": return "concurrently"
        case "turbo": return "turbo"
        case "watchfiles": return "watchfiles"
        case "cargo-watch": return "cargo watch"
        case "air", "reflex", "entr", "watchexec", "supervisord": return tool
        case "tsx":
            if command.rest.contains("watch") { return "tsx watch" }
        case "@nestjs/cli", "nest":
            if command.rest.contains("--watch") || command.rest.contains("-w") { return "nest --watch" }
        case "uvicorn", "gunicorn", "hypercorn":
            if command.rest.contains(where: { $0 == "--reload" || $0.hasPrefix("--reload-") || $0.hasPrefix("--reload=") }) {
                return "\(tool) --reload"
            }
        case "flask":
            if command.rest.contains(where: { $0 == "--reload" || $0 == "--debug" }) { return "Flask reloader" }
        default: break
        }
        if environment["WERKZEUG_RUN_MAIN"] == "true" { return "Flask reloader" }
        if command.runtime == "python", command.scriptStem == "manage", command.rest.first == "runserver",
           !command.rest.contains("--noreload") {
            return "Django autoreload"
        }
        switch command.runtime {
        case "node":
            if options.contains(where: { $0 == "--watch" || $0.hasPrefix("--watch-path") || $0 == "--watch-preserve-output" }) {
                return "node --watch"
            }
        case "bun":
            if command.args.contains("--hot") { return "bun --hot" }
            if command.args.contains("--watch") { return "bun --watch" }
        case "deno":
            if command.args.contains(where: { $0 == "--watch" || $0.hasPrefix("--watch=") }) { return "deno --watch" }
        case "dotnet":
            if command.positionals.first == "watch" { return "dotnet watch" }
        default: break
        }
        if command.exeKey == "cargo", command.positionals.first == "watch" { return "cargo watch" }
        return nil
    }

    // MARK: - Runtimes, boundaries, runners

    /// Runtimes that make something a "dev" thing even when inside /usr/bin or an .app (node, python, bun, deno,
    /// ruby, php, java, go, dotnet, beam.smp, perl...). Version suffixes are ignored ("python3.12", "node22").
    static func isDevRuntime(name: String) -> Bool {
        runtimeKey(for: name) != nil
    }

    /// Normalised runtime family for an executable name, nil when it is not a language runtime.
    static func runtimeKey(for name: String) -> String? {
        var key = name.lowercased()
        while let last = key.last, last.isNumber || last == "." || last == "-" { key.removeLast() }
        switch key {
        case "node", "nodejs": return "node"
        case "python", "pythonw", "pypy": return "python"
        case "beam.smp", "erl", "elixir", "iex": return "beam"
        case "bun", "deno", "ruby", "php", "perl", "java", "go", "dotnet", "julia", "rscript", "lua", "luajit":
            return key
        default: return nil
        }
    }

    /// Interactive/terminal/IDE/agent processes that must NEVER be killed as part of a kill plan: interactive
    /// shells, terminal emulators, IDEs and their helpers, AI agent CLIs, multiplexers, SSH sessions, terminal
    /// editors, the PM2 daemon, container runtimes, OS processes, launchd and PortPilot itself.
    static func isBoundaryProcess(basic: ProcessBasic, details: ProcessDetails?) -> Bool {
        if basic.pid <= 1 { return true }
        let command = CommandAnalysis(details: details, comm: basic.comm)
        let name = command.exeKey

        if agentOrigin(forExecutableName: command.exeName) != nil || agentOrigin(forExecutableName: basic.comm) != nil {
            return true
        }
        if boundaryExecutables.contains(name) || boundaryExecutables.contains(basic.comm.lowercased()) { return true }
        if name == "ssh" { return !command.args.contains("-N") }   // `ssh -N -L ...` is a tunnel, not a session
        if shellNames.contains(normalizedShellName(name)) {
            return details == nil || isInteractiveShell(command)
        }
        if command.processTitle?.hasPrefix("PM2") == true { return true }
        if command.runtime != nil, agentOrigin(forCommandLine: command.argv) != nil { return true }
        if dockerBackendExecutables.contains(command.exeName) || command.exeName.hasPrefix("com.docker.") { return true }
        if name == "portpilot" || command.exePath.contains("/PortPilot.app/") { return true }

        let exePath = command.exePath
        if isSystemExecutable(exePath), !isDevRuntime(name: command.exeName) { return true }
        // Toolchain binaries inside Xcode.app/Contents/Developer (make, git, swift, clang — what the /usr/bin
        // shims exec into) are build tools, not the Xcode IDE.
        if isApplicationExecutable(exePath), !exePath.contains(".app/Contents/Developer/"),
           let bundle = exePath.split(separator: "/").first(where: { $0.hasSuffix(".app") }) {
            let folder = bundle.dropLast(4).lowercased()
            if boundaryAppPrefixes.contains(where: { folder.hasPrefix($0) }) { return true }
        }
        return false
    }

    /// npm, npx, pnpm, yarn, bun (run/x), deno task, node running npm-cli/yarn/pnpm/nodemon/concurrently/turbo/tsx,
    /// nodemon, concurrently, turbo, nx, tsx, ts-node-dev, make, just, foreman, overmind, honcho, poetry run,
    /// uv run, pipenv run, cargo run/watch, go run, air, mix, bundle exec, dotnet run/watch ...
    /// These only launch the real server, so the kill plan may climb through them.
    static func isRunnerProcess(basic: ProcessBasic, details: ProcessDetails?) -> Bool {
        let command = CommandAnalysis(details: details, comm: basic.comm)
        let name = command.exeKey
        if runnerExecutables.contains(name) { return true }
        let first = command.positionals.first
        switch name {
        case "cargo": return first == "run" || first == "watch"
        case "uv", "poetry", "pipenv", "hatch", "pdm", "rye": return first == "run"
        default: break
        }
        switch command.runtime {
        case "node":
            if let package = command.package, runnerPackages.contains(package) { return true }
            if let script = command.script,
               ["npm-cli.js", "npx-cli.js", "yarn.js", "yarn.cjs", "pnpm.cjs", "pnpm.mjs", "pnpx.cjs"]
                .contains((script as NSString).lastPathComponent) {
                return true
            }
        case "python":
            if let tool = command.toolKey {
                if ["poetry", "pipenv", "hatch", "pdm"].contains(tool) { return command.rest.first == "run" }
                if tool == "honcho" { return true }
            }
        case "ruby":
            if let tool = command.toolKey {
                if tool == "bundle" { return command.rest.first == "exec" }
                if ["foreman", "overmind"].contains(tool) { return true }
            }
        case "bun": return first == "run" || first == "x" || first == "exec"
        case "deno": return first == "task"
        case "go": return first == "run"
        case "dotnet": return first == "run" || first == "watch"
        default: break
        }
        return false
    }

    /// `sh/bash/zsh -c …` or a shell running a script file — not attached to a terminal.
    static func isScriptShell(basic: ProcessBasic, details: ProcessDetails?) -> Bool {
        guard let details else { return false }
        let command = CommandAnalysis(details: details, comm: basic.comm)
        guard shellNames.contains(normalizedShellName(command.exeKey)) else { return false }
        return !isInteractiveShell(command)
    }

    private static func isInteractiveShell(_ command: CommandAnalysis) -> Bool {
        if command.argv.isEmpty { return true }
        for argument in command.args {
            if argument == "--" { break }
            if argument.hasPrefix("-") && !argument.hasPrefix("--") && argument.dropFirst().contains("c") { return false }
            if !argument.hasPrefix("-") && !argument.hasPrefix("+") { return false }   // script file
        }
        return true
    }

    private static func normalizedShellName(_ name: String) -> String {
        name.hasPrefix("-") ? String(name.dropFirst()) : name
    }

    // MARK: - Helpers

    fileprivate static func lastPathComponent(_ path: String) -> String {
        guard let slash = path.lastIndex(of: "/") else { return path }
        return String(path[path.index(after: slash)...])
    }

    fileprivate static func clamp(_ text: String, to limit: Int) -> String {
        text.count <= limit ? text : String(text.prefix(limit - 1)) + "…"
    }

    // MARK: - Tables

    private static let systemPrefixes = [
        "/System/", "/usr/libexec/", "/usr/sbin/", "/sbin/", "/usr/bin/", "/bin/", "/Library/Apple/", "/usr/lib/",
    ]

    /// Apple daemons recognised by name when their details cannot be read.
    private static let appleDaemonNames: Set<String> = [
        "rapportd", "sharingd", "ControlCenter", "AirPlayXPCHelper", "identityservicesd", "remoted", "mDNSResponder",
        "launchd", "UserEventAgent", "WiFiAgent", "Finder", "Dock", "SystemUIServer", "loginwindow", "WindowServer",
        "airportd", "bluetoothd", "configd", "kdc", "netbiosd", "screensharingd", "ARDAgent", "cupsd", "sshd",
        "httpd", "smbd", "AMPDeviceDiscoveryAgent", "universalaccessd",
    ]

    /// Servers that stay "services" even when shipped inside an app bundle (Postgres.app, Ollama.app...).
    private static let knownServerExecutables: Set<String> = [
        "postgres", "postmaster", "mysqld", "mariadbd", "redis-server", "mongod", "ollama", "nginx", "httpd", "caddy",
        "memcached", "valkey-server", "clickhouse", "meilisearch", "typesense-server",
    ]

    fileprivate static let toolFrameworks: [String: String] = [
        // JavaScript
        "vite": "Vite", "next": "Next.js", "next-server": "Next.js", "nuxt": "Nuxt", "nuxi": "Nuxt",
        "astro": "Astro", "@remix-run/dev": "Remix", "remix": "Remix", "@sveltejs/kit": "SvelteKit",
        "svelte-kit": "SvelteKit", "webpack": "Webpack", "webpack-dev-server": "Webpack", "webpack-cli": "Webpack",
        "parcel": "Parcel", "storybook": "Storybook", "@storybook/cli": "Storybook", "start-storybook": "Storybook",
        "expo": "Expo", "@expo/cli": "Expo", "metro": "Metro", "react-native": "Metro",
        "@react-native-community/cli": "Metro", "@angular/cli": "Angular", "ng": "Angular", "@nestjs/cli": "NestJS",
        "nest": "NestJS", "gatsby": "Gatsby", "@docusaurus/core": "Docusaurus", "docusaurus": "Docusaurus",
        "vitepress": "VitePress", "wrangler": "Wrangler",
        // Python
        "uvicorn": "uvicorn", "gunicorn": "gunicorn", "hypercorn": "Hypercorn", "daphne": "Daphne",
        "fastapi": "FastAPI", "flask": "Flask", "django-admin": "Django", "streamlit": "Streamlit",
        "gradio": "Gradio", "jupyter": "Jupyter", "jupyter-lab": "Jupyter", "jupyter-notebook": "Jupyter",
        "jupyterlab": "Jupyter", "jupyter_server": "Jupyter", "http.server": "http.server", "mkdocs": "MkDocs",
        // Ruby / PHP
        "rails": "Rails", "puma": "Puma", "jekyll": "Jekyll", "artisan": "Laravel", "php-fpm": "PHP",
        // Servers & tools
        "hugo": "Hugo", "nginx": "nginx", "caddy": "Caddy", "postgres": "PostgreSQL", "postmaster": "PostgreSQL",
        "redis-server": "Redis", "valkey-server": "Redis", "mysqld": "MySQL", "mariadbd": "MySQL",
        "mongod": "MongoDB", "ollama": "Ollama", "cloudflared": "cloudflared", "ngrok": "ngrok",
    ]

    private static let codexEnvironmentKeys = [
        "CODEX_SHELL", "CODEX_SANDBOX", "CODEX_SANDBOX_NETWORK_DISABLED", "CODEX_THREAD_ID", "CODEX_SESSION_ID",
        "CODEX_CI", "CODEX_INTERNAL_ORIGINATOR_OVERRIDE",
    ]

    private static let bundleIdentifierOrigins: [String: LaunchOrigin] = [
        "com.apple.Terminal": LaunchOrigin(kind: .terminal, name: "Terminal"),
        "com.googlecode.iterm2": LaunchOrigin(kind: .terminal, name: "iTerm2"),
        "dev.warp.Warp-Stable": LaunchOrigin(kind: .terminal, name: "Warp"),
        "com.mitchellh.ghostty": LaunchOrigin(kind: .terminal, name: "Ghostty"),
        "net.kovidgoyal.kitty": LaunchOrigin(kind: .terminal, name: "kitty"),
        "com.github.wez.wezterm": LaunchOrigin(kind: .terminal, name: "WezTerm"),
        "org.alacritty": LaunchOrigin(kind: .terminal, name: "Alacritty"),
        "com.microsoft.VSCode": LaunchOrigin(kind: .ide, name: "VS Code"),
        "com.microsoft.VSCodeInsiders": LaunchOrigin(kind: .ide, name: "VS Code Insiders"),
        "com.todesktop.230313mzl4w4u92": LaunchOrigin(kind: .ide, name: "Cursor"),
        "com.exafunction.windsurf": LaunchOrigin(kind: .ide, name: "Windsurf"),
        "com.google.antigravity": LaunchOrigin(kind: .ide, name: "Antigravity"),
        "com.google.antigravity-ide": LaunchOrigin(kind: .ide, name: "Antigravity"),
        "dev.zed.Zed": LaunchOrigin(kind: .ide, name: "Zed"),
        "com.apple.dt.Xcode": LaunchOrigin(kind: .ide, name: "Xcode"),
        "com.anthropic.claudefordesktop": LaunchOrigin(kind: .app, name: "Claude"),
        "com.openai.codex": LaunchOrigin(kind: .codex, name: "Codex"),
    ]

    /// (lowercased folder-name prefix, display name)
    private static let terminalApps: [(String, String)] = [
        ("terminal", "Terminal"), ("iterm", "iTerm2"), ("warp", "Warp"), ("ghostty", "Ghostty"), ("kitty", "kitty"),
        ("wezterm", "WezTerm"), ("alacritty", "Alacritty"), ("hyper", "Hyper"), ("tabby", "Tabby"),
    ]

    /// (lowercased folder-name prefix, display name — nil keeps the folder name)
    private static let ideApps: [(String, String?)] = [
        ("visual studio code - insiders", "VS Code Insiders"), ("visual studio code", "VS Code"),
        ("vscodium", "VSCodium"), ("cursor", "Cursor"), ("windsurf", "Windsurf"), ("zed", "Zed"), ("xcode", "Xcode"),
        ("antigravity", "Antigravity"), ("intellij", nil), ("pycharm", nil), ("webstorm", nil), ("goland", nil),
        ("rubymine", nil), ("phpstorm", nil), ("clion", nil), ("rider", nil), ("rustrover", nil), ("datagrip", nil),
        ("android studio", "Android Studio"), ("nova", "Nova"), ("sublime text", "Sublime Text"), ("fleet", "Fleet"),
        ("kiro", "Kiro"), ("trae", "Trae"), ("void", "Void"), ("positron", "Positron"), ("bbedit", "BBEdit"),
    ]

    private static let boundaryAppPrefixes: [String] = {
        var prefixes = terminalApps.map(\.0) + ideApps.map(\.0)
        prefixes += ["claude", "codex", "chatgpt", "docker", "orbstack", "rancher desktop", "podman desktop", "finder"]
        return prefixes
    }()

    private static let shellNames: Set<String> = [
        "zsh", "bash", "sh", "fish", "dash", "ksh", "tcsh", "csh", "nu", "xonsh", "pwsh", "elvish",
    ]

    private static let boundaryExecutables: Set<String> = [
        "tmux", "screen", "zellij", "sshd", "sshd-session", "mosh-server", "login", "sudo", "su", "launchd",
        "launchctl", "vim", "nvim", "vi", "emacs", "nano", "hx", "helix", "micro", "kak", "kakoune", "portpilot",
        "limactl", "colima", "gvproxy", "vpnkit-bridge", "qemu-system-aarch64", "qemu-system-x86_64",
    ]

    private static let dockerBackendExecutables: Set<String> = [
        "com.docker.backend", "com.docker.vpnkit", "vpnkit-bridge", "Docker Desktop", "OrbStack Helper",
    ]

    private static let runnerExecutables: Set<String> = [
        "npm", "npx", "pnpm", "pnpx", "yarn", "yarnpkg", "bunx", "corepack", "nodemon", "concurrently", "turbo", "nx",
        "tsx", "ts-node-dev", "tsnd", "make", "gmake", "just", "foreman", "overmind", "honcho", "hivemind", "air",
        "entr", "watchexec", "cargo-watch", "mprocs", "task", "lerna", "mix",
    ]

    private static let runnerPackages: Set<String> = [
        "npm", "yarn", "pnpm", "corepack", "nodemon", "concurrently", "turbo", "nx", "tsx", "ts-node-dev",
        "npm-run-all", "npm-run-all2", "lerna", "@nestjs/cli", "wrangler", "dotenv-cli", "cross-env", "env-cmd",
        "node-dev", "forever",
    ]

    private static let bundleNames = BundleNameCache()
}

// MARK: - Bundle name cache

/// Info.plist lookups are cached for the life of the process (bundle names don't change while running).
private final class BundleNameCache: @unchecked Sendable {
    private let lock = NSLock()
    private var names: [String: String] = [:]

    func value(for bundlePath: String, compute: () -> String) -> String {
        lock.lock()
        if let cached = names[bundlePath] {
            lock.unlock()
            return cached
        }
        lock.unlock()
        let name = compute()
        lock.lock()
        if names.count > 512 { names.removeAll() }
        names[bundlePath] = name
        lock.unlock()
        return name
    }
}

// MARK: - Command line analysis

/// Parsed view of one command line, shared by the label, framework, runner and watcher heuristics.
private struct CommandAnalysis {
    let exePath: String
    /// Executable base name as reported ("Python", "node", "Code Helper (Plugin)").
    let exeName: String
    /// Lowercased `exeName`.
    let exeKey: String
    /// Runtime family ("node", "python", "bun", ...); nil for other executables.
    let runtime: String?
    let argv: [String]
    /// argv[0] when the process overwrote its arguments with a title ("nginx: master process ...",
    /// "PM2 v5.4.2: God Daemon (...)", "next-server (v15.0.3)").
    let processTitle: String?
    /// argv without argv[0] (empty for titled processes).
    let args: [String]
    /// Interpreter options that precede the script/module (e.g. "--watch" for `node --watch server.js`).
    let interpreterOptions: [String]
    /// `python -m <module>`.
    let module: String?
    /// First positional argument of a runtime (its script), as written.
    let script: String?
    /// Arguments following the script/module.
    let rest: [String]
    /// npm package that owns `script` (".../node_modules/vite/bin/vite.js" → "vite").
    let package: String?

    init(details: ProcessDetails?, comm: String) {
        exePath = details?.executablePath ?? ""
        let reportedName = details?.executableName ?? ""
        exeName = reportedName.isEmpty ? comm : reportedName
        exeKey = exeName.lowercased()
        argv = details?.arguments ?? []
        runtime = Classifier.runtimeKey(for: exeName)

        let first = argv.first ?? ""
        if CommandAnalysis.looksLikeProcessTitle(first, exeName: exeName, exePath: exePath) {
            processTitle = first.trimmingCharacters(in: .whitespaces)
            args = []
        } else {
            processTitle = nil
            args = Array(argv.dropFirst()).filter { !$0.isEmpty }
        }

        let parsed = CommandAnalysis.parse(runtime: processTitle == nil ? runtime : nil, args: args)
        interpreterOptions = parsed.options
        module = parsed.module
        script = parsed.script
        rest = parsed.rest
        package = parsed.script.flatMap(CommandAnalysis.packageName(inScriptPath:))
    }

    /// Positional (non-option) arguments, e.g. ["run", "dev"] for `bun run dev`.
    var positionals: [String] { args.filter { !$0.hasPrefix("-") } }

    /// Script file name without directory or extension ("server", "manage", "vite", "uvicorn").
    var scriptStem: String? {
        guard let script else { return nil }
        let base = Classifier.lastPathComponent(script)
        guard let dot = base.lastIndex(of: "."), dot != base.startIndex else { return base.lowercased() }
        return String(base[..<dot]).lowercased()
    }

    /// The tool being run, when it is a recognisable third-party tool rather than the user's own script:
    /// the bin/package name for node_modules scripts, the module for `python -m`, the bin name for venv/bin
    /// scripts, the executable for native binaries. nil for plain user scripts (`node server.js`).
    var toolKey: String? {
        guard let runtime else { return exeKey }
        if let module { return module.lowercased() }
        guard let script, let stem = scriptStem else { return nil }
        if let package {
            let generic: Set<String> = ["cli", "index", "main", "bin", "run", "start", "entry", "server"]
            if generic.contains(stem) || stem.isEmpty { return package.lowercased() }
            return stem
        }
        switch runtime {
        case "python", "ruby", "php":
            // Console scripts live in a bin directory and have no extension (".venv/bin/uvicorn", "bin/rails").
            let base = Classifier.lastPathComponent(script)
            if script.contains("/bin/") || !base.contains(".") { return stem }
            return nil
        default:
            return nil
        }
    }

    /// Keys used for framework lookups.
    var lookupKeys: [String] {
        var keys: [String] = []
        if let title = processTitle { keys.append(CommandAnalysis.titleKey(title)) }
        if let tool = toolKey { keys.append(tool) }
        if let package { keys.append(package.lowercased()) }
        if runtime == "ruby", toolKey == "bundle", rest.first == "exec", rest.count > 1 {
            keys.append(Classifier.lastPathComponent(rest[1]).lowercased())
        }
        return keys
    }

    // MARK: Label

    var label: String {
        if let title = processTitle { return CommandAnalysis.titleLabel(title, exeName: exeName) }
        switch runtime {
        case "node": return nodeLabel
        case "python": return pythonLabel
        case "ruby": return rubyLabel
        case "php": return phpLabel
        case "java": return javaLabel
        case "bun", "deno", "go", "dotnet":
            return ([runtime ?? exeName] + summarize(positionals, limit: 2)).joined(separator: " ")
        case "beam":
            return argv.contains("phx.server") ? "mix phx.server" : exeName
        default:
            return nativeLabel
        }
    }

    private var nodeLabel: String {
        guard let script else { return "node" }
        if package != nil, let tool = toolKey {
            // Scoped packages ("@acme/devserver") are shown by their unscoped name.
            let display = tool.hasPrefix("@") ? String(tool.split(separator: "/").last ?? Substring(tool)) : tool
            return ([display] + summarize(rest, limit: 1)).joined(separator: " ")
        }
        return "node " + Classifier.lastPathComponent(script)
    }

    private var pythonLabel: String {
        if let module {
            switch module {
            case "http.server": return "python -m http.server"
            case "uvicorn", "gunicorn", "hypercorn", "daphne":
                return [module, appSpecification].compactMap { $0 }.joined(separator: " ")
            case "flask", "streamlit", "jupyter", "fastapi", "mkdocs", "django", "celery", "gradio", "reflex":
                return ([module] + summarize(rest, limit: 2)).joined(separator: " ")
            default:
                return "python -m " + module
            }
        }
        if let script, let stem = scriptStem {
            if let tool = toolKey {
                if ["uvicorn", "gunicorn", "hypercorn", "daphne"].contains(tool) {
                    return [tool, appSpecification].compactMap { $0 }.joined(separator: " ")
                }
                return ([tool] + summarize(rest, limit: 2)).joined(separator: " ")
            }
            if stem == "manage" { return (["manage.py"] + summarize(rest, limit: 1)).joined(separator: " ") }
            return "python " + Classifier.lastPathComponent(script)
        }
        if args.contains("-c") {
            return argv.contains(where: { $0.contains("multiprocessing") }) ? "python worker" : "python -c"
        }
        return "python"
    }

    private var rubyLabel: String {
        guard let script else { return "ruby" }
        if let tool = toolKey {
            if tool == "bundle", rest.first == "exec", rest.count > 1 {
                let inner = Classifier.lastPathComponent(rest[1])
                return ([inner] + summarize(Array(rest.dropFirst(2)), limit: 1)).joined(separator: " ")
            }
            return ([tool] + summarize(rest, limit: 1)).joined(separator: " ")
        }
        return "ruby " + Classifier.lastPathComponent(script)
    }

    private var phpLabel: String {
        if let index = args.firstIndex(of: "-S"), index + 1 < args.count { return "php -S " + args[index + 1] }
        guard let script else { return "php" }
        if toolKey == "artisan" { return (["artisan"] + summarize(rest, limit: 1)).joined(separator: " ") }
        return "php " + Classifier.lastPathComponent(script)
    }

    private var javaLabel: String {
        guard let script else { return "java" }
        if script.hasSuffix(".jar") { return "java -jar " + Classifier.lastPathComponent(script) }
        let mainClass = script.split(separator: ".").last.map(String.init) ?? script
        return "java " + mainClass
    }

    private var nativeLabel: String {
        // Native binary: name plus a leading plain-word subcommand ("cloudflared tunnel", "ollama serve").
        var label = exeName
        if let first = args.first, CommandAnalysis.isPlainWord(first) { label += " " + first }
        return label
    }

    /// `module:attribute` argument of ASGI/WSGI servers ("app.main:app"), ignoring host:port values.
    private var appSpecification: String? {
        rest.first { argument in
            guard !argument.hasPrefix("-"), let colon = argument.firstIndex(of: ":") else { return false }
            let left = argument[..<colon], right = argument[argument.index(after: colon)...]
            guard let head = left.first, head.isLetter || head == "_",
                  let rightHead = right.first, rightHead.isLetter || rightHead == "_" else { return false }
            return left.allSatisfy { $0.isLetter || $0.isNumber || $0 == "_" || $0 == "." }
        }
    }

    /// Up to `limit` leading subcommands / file names, stopping at the first option.
    private func summarize(_ arguments: [String], limit: Int) -> [String] {
        var result: [String] = []
        for argument in arguments {
            if result.count >= limit || argument.hasPrefix("-") { break }
            if CommandAnalysis.isPlainWord(argument) {
                result.append(argument)
            } else if argument.contains("/") || argument.contains(".") {
                let base = Classifier.lastPathComponent(argument)
                if base.isEmpty || base.count > 40 { break }
                result.append(base)
            } else {
                break
            }
        }
        return result
    }

    // MARK: Parsing

    private static func looksLikeProcessTitle(_ first: String, exeName: String, exePath: String) -> Bool {
        guard first.contains(" "), !first.hasPrefix("/") else { return false }
        if first == exeName || exePath.hasSuffix("/" + first) { return false }
        return true
    }

    /// "nginx: master process ..." → "nginx", "next-server (v15)" → "next-server", "PM2 v5: God Daemon" → "pm2".
    private static func titleKey(_ title: String) -> String {
        if title.hasPrefix("PM2") { return "pm2" }
        let head = title.split(whereSeparator: { $0 == ":" || $0 == "(" || $0 == " " }).first ?? Substring(title)
        return head.lowercased()
    }

    private static func titleLabel(_ title: String, exeName: String) -> String {
        if title.hasPrefix("PM2") { return "PM2 daemon" }
        if title.hasPrefix("nginx:") {
            let role = title.dropFirst("nginx:".count).trimmingCharacters(in: .whitespaces)
            if role.hasPrefix("master") { return "nginx" }
            let words = role.split(separator: " ").filter { $0 != "process" }
            return (["nginx"] + words.prefix(2).map(String.init)).joined(separator: " ")
        }
        // "redis-server 127.0.0.1:6379" / "postgres: checkpointer": the executable plus an optional role word.
        let words = title.split(separator: " ")
        if let first = words.first, first.trimmingCharacters(in: CharacterSet(charactersIn: ":")) == exeName {
            if words.count > 1, isPlainWord(String(words[1])) { return exeName + " " + words[1] }
            return exeName
        }
        var head = Substring(title)
        if let cut = title.firstIndex(where: { $0 == ":" || $0 == "(" }) { head = title[..<cut] }
        let trimmed = head.trimmingCharacters(in: .whitespaces)
        return trimmed.isEmpty ? title : Classifier.clamp(trimmed, to: 40)
    }

    private static func isPlainWord(_ text: String) -> Bool {
        guard let first = text.first, first.isLetter, text.count <= 20 else { return false }
        return text.allSatisfy { ($0.isLetter && $0.isASCII) || $0.isNumber || $0 == "-" || $0 == "_" || $0 == ":" }
            && !text.contains("::")
    }

    /// npm package that contains a script path, handling `.bin` shims and scoped packages.
    private static func packageName(inScriptPath path: String) -> String? {
        let normalized = path.hasPrefix("node_modules/") ? "/" + path : path
        guard let range = normalized.range(of: "/node_modules/", options: .backwards) else { return nil }
        let parts = normalized[range.upperBound...].split(separator: "/")
        guard let first = parts.first else { return nil }
        if first == ".bin" { return parts.count > 1 ? String(parts[1]) : nil }
        if first.hasPrefix("@"), parts.count > 1 { return "\(first)/\(parts[1])" }
        return String(first)
    }

    private struct ParsedArguments {
        var options: [String] = []
        var module: String?
        var script: String?
        var rest: [String] = []
    }

    /// Splits interpreter options from the script/module and its own arguments.
    private static func parse(runtime: String?, args: [String]) -> ParsedArguments {
        var parsed = ParsedArguments()
        guard let runtime else {
            parsed.rest = args
            return parsed
        }
        let valueOptions: Set<String>
        let evalOptions: Set<String>
        switch runtime {
        case "node":
            valueOptions = ["-r", "--require", "--import", "--loader", "--experimental-loader", "--env-file",
                            "--title", "--inspect-port", "--conditions", "-C", "--watch-path", "--input-type"]
            evalOptions = ["-e", "--eval", "-p", "--print"]
        case "python":
            valueOptions = ["-W", "-X", "--check-hash-based-pycs"]
            evalOptions = ["-c"]
        case "ruby", "perl":
            valueOptions = ["-I", "-r", "-C", "-E", "-x", "-F"]
            evalOptions = ["-e"]
        case "php":
            valueOptions = ["-S", "-t", "-c", "-d", "-z"]
            evalOptions = ["-r"]
        case "java":
            valueOptions = ["-cp", "-classpath", "--class-path", "-p", "--module-path", "--add-opens",
                            "--add-exports", "--add-modules"]
            evalOptions = []
        default:
            // bun, deno, go, dotnet, ...: subcommand driven; keep everything as `rest`, pick a file-like script.
            parsed.rest = args
            parsed.script = args.first { !$0.hasPrefix("-") && $0.contains(".") && !$0.contains("=") }
            return parsed
        }

        var index = 0
        while index < args.count {
            let argument = args[index]
            if argument == "--" { index += 1; break }
            if evalOptions.contains(argument) {
                parsed.rest = Array(args[index...])
                return parsed
            }
            if runtime == "python" {
                if argument == "-m" {
                    parsed.module = index + 1 < args.count ? args[index + 1] : nil
                    parsed.rest = index + 2 < args.count ? Array(args[(index + 2)...]) : []
                    return parsed
                }
                if argument.hasPrefix("-m"), !argument.hasPrefix("--"), argument.count > 2 {
                    parsed.module = String(argument.dropFirst(2))
                    parsed.rest = Array(args[(index + 1)...])
                    return parsed
                }
            }
            if runtime == "php", argument == "-f", index + 1 < args.count {
                parsed.script = args[index + 1]
                parsed.rest = Array(args[(index + 2)...])
                return parsed
            }
            if runtime == "java", argument == "-jar", index + 1 < args.count {
                parsed.script = args[index + 1]
                parsed.rest = Array(args[(index + 2)...])
                return parsed
            }
            guard argument.hasPrefix("-"), argument != "-" else { break }
            parsed.options.append(argument)
            index += valueOptions.contains(argument) ? 2 : 1
        }
        if index < args.count {
            parsed.script = args[index]
            parsed.rest = Array(args[(index + 1)...])
        }
        return parsed
    }
}
