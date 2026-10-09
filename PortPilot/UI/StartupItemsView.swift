import SwiftUI

/// Collapsible "Startup Items" section: every non-Apple LaunchAgent with its live status and an on/off switch.
/// Turning a switch off runs `launchctl bootout` + `disable` (the plist stays, so it can be turned back on).
struct StartupItemsView: View {
    let store: AppStore
    @Binding var isCollapsed: Bool

    /// PortPilot's own login agent is managed in Settings ("Launch at login"); switching it off here would
    /// `launchctl bootout` the running app itself, so it is never listed.
    static func visibleItems(in store: AppStore) -> [StartupItem] {
        store.startupItems.filter { $0.label != LoginItemManager.label }
    }

    /// Key AppStore puts in `busyGroupIDs` while it enables, disables or starts this item.
    static func busyID(for label: String) -> String { "startup:\(label)" }

    var body: some View {
        let items = Self.visibleItems(in: store)
        VStack(alignment: .leading, spacing: 0) {
            SectionHeader(title: "Startup Items", count: items.count, isCollapsed: $isCollapsed) {
                failingNote(count: StartupItemStatus.failingRepeatedlyCount(items))
            }
            if !isCollapsed {
                VStack(spacing: 1) {
                    ForEach(items) { item in
                        StartupItemRow(item: item, store: store)
                    }
                }
                .transition(.opacity)
            }
        }
    }

    /// "⚠ 1 keeps failing" next to the section title, so a crash-looping agent is visible even while the section
    /// is collapsed (the default). Clicking it shows the section.
    @ViewBuilder
    private func failingNote(count: Int) -> some View {
        if count > 0 {
            Button {
                withAnimation(.snappy(duration: 0.22)) { isCollapsed = false }
            } label: {
                Label(StartupItemStatus.failingRepeatedlyNote(count), systemImage: "exclamationmark.triangle.fill")
                    .font(.system(size: 10.5, weight: .medium))
                    .foregroundStyle(Theme.destructive)
                    .lineLimit(1)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .fixedSize()
            .help("launchd keeps restarting \(count == 1 ? "a startup item" : "\(count) startup items"), "
                  + "but \(count == 1 ? "it fails" : "they fail") every time. Click to show.")
        }
    }
}

private struct StartupItemRow: View {
    let item: StartupItem
    let store: AppStore

    @State private var isHovering = false
    /// The position the user just switched to, shown while launchctl runs and until launchd reports it.
    @State private var pendingEnabled: Bool?

    private var status: StartupItemStatus { StartupItemStatus(item) }
    private var isBusy: Bool { store.busyGroupIDs.contains(StartupItemsView.busyID(for: item.label)) }

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            icon
                .padding(.leading, Theme.chevronWidth + 6) // aligns with group rows (no chevron here)
                .help(status.help)

            VStack(alignment: .leading, spacing: 2) {
                HStack(alignment: .center, spacing: 6) {
                    nameLine
                        .help(item.label)
                        .layoutPriority(1) // never squeezed away by the port chips
                    Spacer(minLength: 6)
                    CappedPortChips(ports: item.ports, spacing: 3) { port in
                        PortChip(port: port, compact: true, store: store)
                    } overflow: { hidden in
                        HiddenPortsMenu(ports: hidden, compact: true, store: store)
                    }
                }
                HStack(spacing: 5) {
                    Text(status.text)
                        .foregroundStyle(status.isProblem ? AnyShapeStyle(Theme.destructive) : AnyShapeStyle(.secondary))
                        .fixedSize()
                        .help(status.help)
                    if item.keepAlive && !item.isDisabled {
                        Text(verbatim: "·").foregroundStyle(.quaternary)
                        Label("KeepAlive", systemImage: "arrow.clockwise")
                            .labelStyle(CompactLabelStyle())
                            .foregroundStyle(Theme.autoRestart)
                            .fixedSize()
                            .help("launchd restarts this job whenever it exits")
                    }
                    Text(verbatim: "·").foregroundStyle(.quaternary)
                    Text(DisplayText.command(item.command))
                        .font(.command)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .help(item.command)
                }
                .font(.system(size: 11))
            }
            .padding(.leading, 9)
            .padding(.trailing, 6)

            HStack(spacing: 6) {
                if isBusy {
                    ProgressView()
                        .controlSize(.mini)
                        .accessibilityLabel("Working on \(item.label)")
                } else if status.offersStart {
                    Button("Start") { store.startStartupItem(item) }
                        .buttonStyle(HoverButtonStyle(padding: EdgeInsets(top: 2, leading: 7, bottom: 2, trailing: 7),
                                                      isEmphasized: true))
                        .font(.system(size: 11, weight: .medium))
                        .help(item.isLoaded ? "Start \(item.label) now (launchctl kickstart)"
                                            : "Load \(item.label) into launchd and start it now")
                }
                Toggle(isOn: Binding(
                    get: { StartupToggleState.displayedEnabled(isDisabled: item.isDisabled, pending: pendingEnabled) },
                    set: { setEnabled($0) })
                ) {
                    Text(item.label)
                }
                .labelsHidden()
                .toggleStyle(PanelSwitchStyle())
                .controlSize(.mini)
                .disabled(isBusy)
                .help(toggleHelp)
            }
            .frame(height: 18)
        }
        .padding(.horizontal, Theme.rowPadding)
        .padding(.vertical, 6)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(isHovering ? Theme.hoverFill : .clear))
        .onHover { isHovering = $0 }
        .contextMenu {
            Button("Copy Label") { store.copy(item.label) }
            Button("Copy Command") { store.copy(item.command) }
            Button("Reveal Plist in Finder") { store.revealInFinder(item.plistPath) }
            if let directory = item.workingDirectory {
                Button("Reveal Working Directory") { store.revealInFinder(directory) }
            }
        }
        .onChange(of: item.isDisabled) { resolvePending() }
        .onChange(of: isBusy) { resolvePending() }
        .task(id: isBusy) { await settlePendingAfterAction() }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(item.label), \(status.text)")
    }

    /// Friendly name, plus "Homebrew" when there is room for it (dropped rather than clipped).
    @ViewBuilder
    private var nameLine: some View {
        let name = Text(Self.friendlyName(for: item.label))
            .font(.system(size: 12.5, weight: .medium))
            .foregroundStyle(item.isDisabled ? AnyShapeStyle(.secondary) : AnyShapeStyle(.primary))
            .lineLimit(1)
            .truncationMode(.middle)
        if item.isHomebrew {
            NameAndDetail(spacing: 6, name: name,
                          detail: Text("Homebrew")
                              .font(.system(size: 11))
                              .foregroundStyle(.tertiary)
                              .lineLimit(1))
        } else {
            name
        }
    }

    private var toggleHelp: String {
        if isBusy { return "Working…" }
        if item.isDisabled { return "Enable — start at login again" }
        if status.kind.isFailingRepeatedly { return "Disable — stop launchd from retrying it and keep it from starting at login" }
        return "Disable — stop it and keep it from starting at login"
    }

    private func setEnabled(_ enabled: Bool) {
        guard !isBusy else { return }
        pendingEnabled = enabled
        store.setStartupItem(item, enabled: enabled)
        // AppStore marks the item busy synchronously; if it didn't, the request was refused — show reality.
        if !isBusy { pendingEnabled = nil }
    }

    private func resolvePending() {
        if StartupToggleState.shouldClearPending(pending: pendingEnabled, isDisabled: item.isDisabled,
                                                 isBusy: isBusy, failed: actionFailed) {
            pendingEnabled = nil
        }
    }

    /// After launchctl returns, launchd's refreshed state normally lands with the next scan; if it never
    /// matches (the action failed), fall back to what launchd reports.
    private func settlePendingAfterAction() async {
        guard !isBusy, pendingEnabled != nil else { return }
        let delay = StartupToggleState.settleDelay(refreshInterval: store.settings.refreshInterval)
        try? await Task.sleep(for: .seconds(delay))
        guard !Task.isCancelled else { return }
        pendingEnabled = nil
    }

    /// AppStore reports a failed enable/disable as an error banner that starts with the label.
    private var actionFailed: Bool {
        guard let banner = store.banner, banner.style == .error else { return false }
        return banner.message.hasPrefix(item.label + ":")
    }

    /// Neutral tile (power / Homebrew mug) with the status dot in its corner.
    private var icon: some View {
        RoundedRectangle(cornerRadius: 7, style: .continuous)
            .fill(Color.primary.opacity(0.07))
            .overlay(
                Image(systemName: item.isHomebrew ? "mug.fill" : "power")
                    .font(.system(size: 11.5, weight: .semibold))
                    .foregroundStyle(item.isDisabled ? AnyShapeStyle(.tertiary) : AnyShapeStyle(.secondary)))
            .frame(width: Theme.iconSize, height: Theme.iconSize)
            .overlay(alignment: .bottomTrailing) {
                StatusDot(color: statusColor, isHollow: status.isHollow)
                    .padding(3)
            }
            .accessibilityHidden(true)
    }

    private var statusColor: Color {
        switch status.kind {
        case .disabled: return .secondary
        case .running: return .green
        case .failingRepeatedly, .exited: return Theme.destructive
        case .loaded, .notLoaded: return .gray
        }
    }

    /// "homebrew.mxcl.postgresql@16" → "postgresql@16", "com.acme.uptime-monitor" → "uptime-monitor",
    /// "com.northwind.app" → "northwind app". The same rule names launchd groups in the project list.
    static func friendlyName(for label: String) -> String {
        ListenerBuilder.launchdTitle(for: label)
    }
}

// MARK: - Status (pure)

/// What a startup item's status line says, derived from launchd's view of the job. Pure, so it is unit tested.
struct StartupItemStatus: Equatable {
    enum Kind: Equatable {
        case disabled
        case running(pid: Int32)
        /// KeepAlive job that isn't running and last exited with an error: launchd keeps respawning it and it
        /// keeps failing (e.g. "spawn failed" with exit 78 when its program or folder is missing).
        case failingRepeatedly(exit: Int32)
        case exited(Int32)
        case loaded
        case notLoaded

        var isFailingRepeatedly: Bool {
            if case .failingRepeatedly = self { return true }
            return false
        }
    }

    let kind: Kind
    /// Whether "Start" makes sense: not running, enabled, and not a job launchd is already retrying on its own
    /// (kickstarting a crash loop just fails again; turning it off is the fix). A job Stop unloaded is offered too:
    /// Start loads it again (bootstrap) and runs it.
    let offersStart: Bool

    init(_ item: StartupItem) {
        if item.isDisabled {
            kind = .disabled
        } else if let pid = item.pid {
            kind = .running(pid: pid)
        } else if let exit = item.lastExitStatus, exit != 0 {
            kind = item.keepAlive && item.isLoaded ? .failingRepeatedly(exit: exit) : .exited(exit)
        } else if item.isLoaded {
            kind = .loaded
        } else {
            kind = .notLoaded
        }
        offersStart = !item.isRunning && !item.isDisabled && !kind.isFailingRepeatedly
    }

    var text: String {
        switch kind {
        case .disabled: return "Disabled"
        case .running(let pid): return "Running · PID \(pid)"
        case .failingRepeatedly(let exit):
            return exit < 0 ? "Keeps crashing · \(Self.signalName(-exit))" : "Keeps failing · exit \(exit)"
        case .exited(let exit):
            return exit < 0 ? "Killed by \(Self.signalName(-exit))" : "Exited with \(exit)"
        case .loaded: return "Loaded · not running"
        case .notLoaded: return "Not loaded"
        }
    }

    /// Tooltip that explains the status in plain words.
    var help: String {
        switch kind {
        case .disabled:
            return "Turned off — it won't start at login."
        case .running(let pid):
            return "Running as PID \(pid)."
        case .failingRepeatedly(let exit):
            return "launchd keeps restarting this job (KeepAlive), but it \(Self.endedPhrase(exit)). "
                + "Turn it off to stop the retries, or fix its plist."
        case .exited(let exit):
            return "Its last run \(Self.endedPhrase(exit))."
        case .loaded:
            return "Loaded in launchd but not running. Start runs it now."
        case .notLoaded:
            return "Not loaded in launchd right now (for example after Stop). Start loads it and runs it."
        }
    }

    var isProblem: Bool {
        switch kind {
        case .failingRepeatedly, .exited: return true
        case .disabled, .running, .loaded, .notLoaded: return false
        }
    }

    var isHollow: Bool { kind == .disabled || kind == .notLoaded }

    /// How many of `items` launchd keeps restarting while they keep failing.
    static func failingRepeatedlyCount(_ items: [StartupItem]) -> Int {
        items.filter { StartupItemStatus($0).kind.isFailingRepeatedly }.count
    }

    /// "1 keeps failing", "3 keep failing".
    static func failingRepeatedlyNote(_ count: Int) -> String {
        count == 1 ? "1 keeps failing" : "\(count) keep failing"
    }

    /// "exits with code 78 (configuration error — often a missing program or working folder)",
    /// "was ended by SIGKILL".
    static func endedPhrase(_ status: Int32) -> String {
        if status < 0 { return "was ended by \(signalName(-status))" }
        if let meaning = exitMeaning(status) { return "exits with code \(status) (\(meaning))" }
        return "exits with code \(status)"
    }

    /// Plain meaning of common exit codes (sysexits.h, shell conventions); nil when there is no common one.
    static func exitMeaning(_ status: Int32) -> String? {
        switch status {
        case 1: return "a general error"
        case 2: return "wrong usage"
        case 64: return "wrong command-line arguments"
        case 65: return "bad input data"
        case 66: return "an input file is missing"
        case 67: return "unknown user"
        case 68: return "unknown host"
        case 69: return "a service it needs is unavailable"
        case 70: return "an internal error"
        case 71: return "a system error"
        case 72: return "a system file is missing"
        case 73: return "it can't create an output file"
        case 74: return "an input/output error"
        case 75: return "a temporary failure"
        case 76: return "a protocol error"
        case 77: return "permission denied"
        case 78: return "configuration error — often a missing program or working folder"
        case 126: return "the program can't be run"
        case 127: return "the program wasn't found"
        case 129...159: return "ended by \(signalName(status - 128))"
        default: return nil
        }
    }

    /// "SIGKILL" for 9; "signal 42" for unnamed ones.
    static func signalName(_ signal: Int32) -> String {
        let names: [Int32: String] = [1: "SIGHUP", 2: "SIGINT", 3: "SIGQUIT", 4: "SIGILL", 5: "SIGTRAP", 6: "SIGABRT",
                                      8: "SIGFPE", 9: "SIGKILL", 10: "SIGBUS", 11: "SIGSEGV", 13: "SIGPIPE",
                                      14: "SIGALRM", 15: "SIGTERM"]
        return names[signal] ?? "signal \(signal)"
    }
}

/// Optimistic state of a startup item's switch while launchctl applies a change. Pure, so it is unit tested.
enum StartupToggleState {
    /// The user's pending choice while it is being applied, else what launchd reports.
    static func displayedEnabled(isDisabled: Bool, pending: Bool?) -> Bool {
        pending ?? !isDisabled
    }

    /// The pending choice can go once launchd reports the same state, or once the action has finished with an error.
    static func shouldClearPending(pending: Bool?, isDisabled: Bool, isBusy: Bool, failed: Bool) -> Bool {
        guard let pending else { return false }
        if pending == !isDisabled { return true }
        return !isBusy && failed
    }

    /// How long to keep showing the pending choice after launchctl returned: long enough for the next scan
    /// (which refreshes startup items) to land.
    static func settleDelay(refreshInterval: Double) -> Double {
        max(1, refreshInterval) + 2
    }
}
