import Foundation

// What Stop, Stop All, Relaunch and Start did, and the banner that says so. Pure values and functions (no system
// calls), so the wording and the actions offered are unit tested. AppStore runs the actions and fills these in.

/// One Stop the user asked for: a group, one of its listeners, or one group of "Stop All Projects".
struct StopRequest: Sendable {
    let processes: [ListenerProcess]
    let groupID: String
    let title: String
    /// Category of the row. Apps are asked to quit; apps and macOS services are never force-killed by a plain Stop
    /// and never get a Recently Stopped record (relaunching a bare helper argv would be wrong).
    let category: ListenerCategory
    let mode: StopMode
    /// "Stop Only This Process": signal just the listener, never through its manager.
    let onlyThisProcess: Bool
    /// Stop & Disable Auto-Start.
    let disableAutoStart: Bool

    init(processes: [ListenerProcess], groupID: String, title: String, category: ListenerCategory, mode: StopMode,
         onlyThisProcess: Bool, disableAutoStart: Bool) {
        self.processes = processes
        self.groupID = groupID
        self.title = title
        self.category = category
        self.mode = mode
        self.onlyThisProcess = onlyThisProcess
        self.disableAutoStart = disableAutoStart
    }

    init(group: ListenerGroup, mode: StopMode, disableAutoStart: Bool) {
        self.init(processes: group.processes, groupID: group.id, title: group.title, category: group.category,
                  mode: mode, onlyThisProcess: false, disableAutoStart: disableAutoStart)
    }

    var isAppOrSystem: Bool { category == .app || category == .system }
}

/// What one Stop did.
struct StopOutcome: Sendable {
    let groupID: String
    let title: String
    /// Ports of the listeners the user asked to stop.
    let ports: [UInt16]
    var errors: [String] = []
    /// Short facts for the success message ("pm2 api removed", "auto-start turned off for com.acme.api").
    var notes: [String] = []
    /// Servers stopped by signal, for Recently Stopped.
    var records: [StoppedRecord] = []
    /// The records whose command is known well enough to start them again (Undo).
    var undoRecordIDs: [UUID] = []
    /// How many things were stopped: launchd jobs, pm2 apps, containers, kill plans, apps that quit.
    var stoppedCount = 0
    /// SIGKILL had to be used.
    var escalated = false
    /// launchd jobs that were unloaded (not disabled) and start again at next login, in a folder where Disable
    /// Auto-Start can switch them off (and Startup Items back on).
    var autoStartLabels: [String] = []
    /// A GUI app was asked to quit and did.
    var quitApp = false
    /// A GUI app was asked to quit but was still open at the deadline (it may be asking to save). Never force-quit.
    var stillQuitting = false
    /// Nothing was left to stop: the listeners had exited and nothing of theirs listens on their ports any more.
    var alreadyExited = false

    init(groupID: String, title: String, ports: [UInt16]) {
        self.groupID = groupID
        self.title = title
        self.ports = ports
    }

    var succeeded: Bool { errors.isEmpty }
}

/// A relaunch, checked beyond the spawn: the new process must stay up and, when the stopped server had ports,
/// listen on one of them again.
struct RelaunchResult: Sendable {
    enum State: Equatable, Sendable {
        /// Running and listening on `port` again.
        case listening(pid: Int32, port: UInt16)
        /// Running; the record had no port to check.
        case running(pid: Int32)
        /// Running, but none of the record's ports opened within the wait.
        case notListening(pid: Int32)
        /// Started, then exited while PortPilot waited for its port.
        case exited
        /// Couldn't start; the reason follows "Couldn't relaunch <title>: ".
        case failed(String)
    }

    let record: StoppedRecord
    let state: State
    /// Where its output goes (~/Library/Logs/PortPilot/<title>.log).
    let logPath: String

    /// The process is up: the record can leave Recently Stopped (relaunching it again would start a second copy).
    var isRunning: Bool {
        switch state {
        case .listening, .running, .notListening: return true
        case .exited, .failed: return false
        }
    }
}

/// The pm2 commands a Stop runs. A seam so tests never reach the user's own pm2 daemon.
struct PM2Commands {
    /// `pm2 stop` (a cluster-mode app as a whole).
    var stop: (_ id: Int) throws -> Void
    /// `pm2 delete` plus removing the app from pm2's saved list.
    var delete: (_ id: Int, _ name: String) throws -> PM2SavedListUpdate

    static func live(_ service: PM2Service) -> PM2Commands {
        PM2Commands(stop: { try service.stop(id: $0) }, delete: { try service.delete(id: $0, name: $1) })
    }
}

/// Banner texts and actions for stopping, relaunching and starting. Pure.
enum StopReport {
    /// Where to turn off a login item PortPilot can't manage.
    static let loginItemsSettings = "System Settings › General › Login Items"

    // MARK: Stop

    /// The banner after one Stop.
    static func banner(for outcome: StopOutcome) -> Banner {
        if !outcome.succeeded {
            return Banner(style: .error, message: "Couldn't fully stop \(outcome.title): "
                          + outcome.errors.prefix(3).joined(separator: "; "))
        }
        if outcome.alreadyExited && outcome.stoppedCount == 0 {
            return Banner(style: .info, message: "\(outcome.title) had already exited")
        }
        if outcome.stillQuitting {
            return Banner(style: .info, message: "Asked \(outcome.title) to quit. It's still open — "
                          + "it may be waiting for you to save something.")
        }
        var message = (outcome.quitApp ? "Quit " : "Stopped ") + outcome.title + portText(outcome.ports)
        if outcome.escalated { message += " — had to force-kill" }
        if !outcome.notes.isEmpty { message += " · " + outcome.notes.joined(separator: ", ") }
        if !outcome.autoStartLabels.isEmpty {
            return Banner(style: .success, message: message + ". It will start again at next login.",
                          action: .disableAutoStart(groupID: outcome.groupID, launchdLabels: outcome.autoStartLabels),
                          actionTitle: "Disable Auto-Start")
        }
        if let undo = undoAction(for: outcome.undoRecordIDs) {
            return Banner(style: .success, message: message, action: undo, actionTitle: "Undo")
        }
        return Banner(style: .success, message: message)
    }

    /// One banner for "Stop All Projects": how many stopped, the first failures, and one Disable Auto-Start or Undo
    /// covering every project. nil when nothing was stopped.
    static func summary(for outcomes: [StopOutcome]) -> Banner? {
        guard let first = outcomes.first else { return nil }
        guard outcomes.count > 1 else { return banner(for: first) }
        let total = outcomes.count
        let failed = outcomes.filter { !$0.succeeded }
        if !failed.isEmpty {
            let reasons = failed.prefix(2).map { "\($0.title): \($0.errors.first ?? "failed")" }
            let more = failed.count > 2 ? "; \(failed.count - 2) more failed" : ""
            return Banner(style: .error, message: "Stopped \(total - failed.count) of \(total) projects — "
                          + reasons.joined(separator: "; ") + more)
        }
        let ports = Array(Set(outcomes.flatMap(\.ports))).sorted()
        var message = "Stopped \(total) projects" + portText(ports, limit: 6)
        if outcomes.contains(where: \.escalated) { message += " — had to force-kill some" }
        var labels: [String] = []
        for label in outcomes.flatMap(\.autoStartLabels) where !labels.contains(label) { labels.append(label) }
        if !labels.isEmpty {
            message += labels.count == 1 ? ". \(labels[0]) starts again at next login."
                                         : ". \(labels.count) launchd jobs start again at next login."
            return Banner(style: .success, message: message,
                          action: .disableAutoStart(groupID: "", launchdLabels: labels),
                          actionTitle: "Disable Auto-Start")
        }
        if let undo = undoAction(for: outcomes.flatMap(\.undoRecordIDs)) {
            return Banner(style: .success, message: message, action: undo, actionTitle: "Undo")
        }
        return Banner(style: .success, message: message)
    }

    /// Armed tooltip of "Stop All Projects": which projects the second click stops.
    static func stopAllConfirmHelp(_ groups: [ListenerGroup]) -> String {
        let names = groups.map(\.title)
        let list = names.count <= 3 ? joinedList(names)
            : names.prefix(3).joined(separator: ", ") + " and \(names.count - 3) more"
        var text = "Click again to stop \(list)."
        let autoStart = groups.filter { group in
            if case .launchd(let job) = group.manager { return job.keepAlive || job.runAtLoad }
            return false
        }
        if autoStart.count == 1 {
            text += " \(autoStart[0].title) starts again at next login."
        } else if autoStart.count > 1 {
            text += " \(autoStart.count) of them start again at next login."
        }
        return text
    }

    /// Undo for the records a Stop created; nil when none can be relaunched.
    static func undoAction(for recordIDs: [UUID]) -> Banner.Action? {
        guard let first = recordIDs.first else { return nil }
        return .relaunch(recordID: first, moreRecordIDs: Array(recordIDs.dropFirst()))
    }

    // MARK: Relaunch

    /// True when Relaunch can start the record again: a plain server whose argv is a real command line, or a
    /// package-manager title PortPilot rebuilds ("npm run dev"). False for other titles (nginx's "master process …").
    static func canRelaunch(_ record: StoppedRecord) -> Bool {
        guard record.canRelaunch, let first = record.arguments.first else { return false }
        return !Relauncher.isTitleRewritten(record.arguments, executablePath: record.executablePath)
            || Relauncher.commandFromTitle(first) != nil
    }

    /// The banner after Relaunch / Undo. nil when nothing was relaunched.
    static func relaunchBanner(for results: [RelaunchResult]) -> Banner? {
        guard let first = results.first else { return nil }
        guard results.count > 1 else { return relaunchBanner(for: first) }
        let total = results.count
        let failed = results.filter { !$0.isRunning }
        if !failed.isEmpty {
            let reasons = failed.prefix(2).map { "\($0.record.title): \(failureReason($0))" }
            return Banner(style: .error, message: "Relaunched \(total - failed.count) of \(total) — "
                          + reasons.joined(separator: "; "))
        }
        let quiet = results.filter { if case .notListening = $0.state { return true } else { return false } }
        if !quiet.isEmpty {
            let names = joinedList(quiet.map(\.record.title))
            return Banner(style: .warning, message: "Relaunched \(total) servers, but \(names) "
                          + (quiet.count == 1 ? "isn't" : "aren't") + " listening yet. Logs are in "
                          + Format.abbreviatePath(Relauncher.logDirectory.path) + ".")
        }
        let ports = results.compactMap { result -> UInt16? in
            if case .listening(_, let port) = result.state { return port }
            return nil
        }
        return Banner(style: .success, message: "Relaunched \(total) servers" + portText(ports.sorted(), limit: 6))
    }

    private static func relaunchBanner(for result: RelaunchResult) -> Banner {
        let title = result.record.title
        let log = Format.abbreviatePath(result.logPath)
        switch result.state {
        case .listening(_, let port):
            return Banner(style: .success, message: "Relaunched \(title) — listening on :\(port) again")
        case .running(let pid):
            return Banner(style: .success, message: "Relaunched \(title) (pid \(pid)) — its output is in \(log)")
        case .notListening(let pid):
            let ports = result.record.ports.map { ":\($0)" }.joined(separator: ", ")
            return Banner(style: .warning, message: "Started \(title) (pid \(pid)), but \(ports) "
                          + (result.record.ports.count == 1 ? "isn't" : "aren't") + " open yet. Its output is in \(log).")
        case .exited, .failed:
            return Banner(style: .error, message: "Couldn't relaunch \(title): \(failureReason(result))")
        }
    }

    private static func failureReason(_ result: RelaunchResult) -> String {
        switch result.state {
        case .failed(let reason): return reason
        case .exited:
            return "it exited soon after starting. Its output is in \(Format.abbreviatePath(result.logPath))"
        case .listening, .running, .notListening: return "it is running"
        }
    }

    // MARK: Auto-start and Startup Items

    /// The banner after "Disable Auto-Start" for jobs a Stop already unloaded.
    /// - Parameters:
    ///   - disabled: labels whose auto-start was turned off.
    ///   - manual: labels PortPilot can't turn off (no plist in a LaunchAgents folder, e.g. an app's helper).
    static func autoStartBanner(disabled: [String], manual: [String], errors: [String]) -> Banner {
        if !errors.isEmpty {
            return Banner(style: .error, message: "Couldn't turn off auto-start: " + errors.prefix(2).joined(separator: "; "))
        }
        if !manual.isEmpty {
            let done = disabled.isEmpty ? "" : "Turned off auto-start for \(joinedList(disabled)). "
            return Banner(style: .warning, message: done + "PortPilot can't turn off auto-start for \(joinedList(manual)). "
                          + "Turn it off in \(loginItemsSettings).")
        }
        if disabled.count == 1 {
            return Banner(style: .success, message: "\(disabled[0]) won't start at login anymore. "
                          + "Turn it back on under Startup Items.")
        }
        return Banner(style: .success, message: "\(disabled.count) launchd jobs won't start at login anymore. "
                      + "Turn them back on under Startup Items.")
    }

    /// The banner after Start in Startup Items, from launchd's view of the job about a second later.
    /// - Parameter state: the job's `launchctl list` row; nil when it isn't loaded.
    static func startBanner(label: String, error: Error?, state: LaunchctlListEntry?) -> Banner {
        if let error {
            return Banner(style: .error, message: "\(label): \(error.localizedDescription)")
        }
        guard let state else {
            return Banner(style: .error, message: "\(label) didn't load. Check its plist.")
        }
        if let pid = state.pid {
            return Banner(style: .success, message: "Started \(label) (pid \(pid))")
        }
        if let exit = state.lastExitStatus, exit != 0 {
            return Banner(style: .error, message: "\(label) didn't keep running — it \(StartupItemStatus.endedPhrase(exit))")
        }
        if state.lastExitStatus == 0 {
            return Banner(style: .success, message: "Ran \(label). It has finished.")
        }
        return Banner(style: .warning, message: "\(label) is loaded but didn't start")
    }

    // MARK: Helpers

    /// " (:3000, :5173)", capped at `limit` ports ("… +3"); "" for none.
    static func portText(_ ports: [UInt16], limit: Int = .max) -> String {
        guard !ports.isEmpty else { return "" }
        let shown = ports.prefix(max(1, limit)).map { ":\($0)" }.joined(separator: ", ")
        let more = ports.count > limit ? " +\(ports.count - limit)" : ""
        return " (" + shown + more + ")"
    }

    /// "a", "a and b", "a, b and c".
    static func joinedList(_ items: [String]) -> String {
        guard items.count > 1, let last = items.last else { return items.first ?? "" }
        return items.dropLast().joined(separator: ", ") + " and " + last
    }
}
