import AppKit
import SwiftUI

/// One project / service / app in the list.
///
///     ›  [icon]  Institut de mai                      :5330 :8014   ⋯  ⊗
///                ~/Downloads/NODES/Institut de mai · 2h 14m   2.4% · 412 MB
///                [Vite] [uvicorn] [✦ Claude Code]
///
/// Clicking the row toggles the process list; the port chips, path, menu and stop button handle their own clicks.
struct GroupRow: View {
    let group: ListenerGroup
    let store: AppStore

    @State private var isHovering = false

    /// At most this many chips fit next to a title; beyond it the row shows `maxInlinePorts - 1` chips + "+N".
    private static let maxInlinePorts = 3

    private var isExpanded: Bool { store.expandedGroupIDs.contains(group.id) }
    private var isBusy: Bool { store.busyGroupIDs.contains(group.id) }
    private var exposedPorts: Set<UInt16> {
        Set(group.processes.flatMap { $0.sockets.filter(\.isExposed).map(\.port) })
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            summary
                .contentShape(Rectangle())
                .onTapGesture(perform: toggleExpanded) // only the summary: clicks in the process list must not collapse
            if isExpanded {
                GroupDetailView(group: group, store: store, isBusy: isBusy)
                    .padding(.leading, Theme.textColumnInset)
                    .padding(.top, 6)
                    .transition(.opacity)
            }
        }
        .padding(.horizontal, Theme.rowPadding)
        .padding(.vertical, 7)
        .background(
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .fill(isExpanded ? Color.primary.opacity(0.045) : isHovering ? Theme.hoverFill : .clear))
        .onHover { isHovering = $0 }
        .contextMenu { GroupActionsMenu(group: group, store: store, isBusy: isBusy) }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(accessibilitySummary)
        .accessibilityAction(named: isExpanded ? "Hide processes" : "Show processes", toggleExpanded)
    }

    // MARK: Summary

    private var summary: some View {
        HStack(alignment: .top, spacing: 0) {
            Button(action: toggleExpanded) {
                DisclosureChevron(isExpanded: isExpanded)
                    .frame(width: Theme.chevronWidth, height: Theme.iconSize)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(isExpanded ? "Hide processes" : "Show processes")

            GroupIcon(group: group)
                .padding(.leading, 6)
                .padding(.top, 1)

            VStack(alignment: .leading, spacing: 3) {
                titleLine
                detailLine
                if !badges.isEmpty {
                    FlowLayout(spacing: 4, lineSpacing: 4) {
                        ForEach(badges) { badge in
                            Badge(text: badge.text, systemImage: badge.symbol, tint: badge.tint)
                                .help(badge.help ?? badge.text)
                        }
                    }
                    .padding(.top, 2)
                }
            }
            .padding(.leading, 9)

            actions
                .padding(.leading, 6)
        }
    }

    private var titleLine: some View {
        HStack(alignment: .center, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 5) {
                Text(group.title)
                    .font(.rowTitle)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .layoutPriority(1) // the subtitle truncates first
                if let subtitle = group.subtitle, !subtitle.isEmpty, subtitle != group.title {
                    Text(subtitle)
                        .font(.rowBody)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
            }
            .help(group.title)

            Spacer(minLength: 6)

            portChips
                .layoutPriority(1)
        }
        .frame(minHeight: 20)
    }

    private var portChips: some View {
        let ports = group.ports
        let exposed = exposedPorts
        // Keep room for the title: 3 ports show as 3 chips, 4+ as 2 chips and "+N".
        let shown = ports.count > Self.maxInlinePorts ? Self.maxInlinePorts - 1 : ports.count
        let hidden = ports.dropFirst(shown)
        return HStack(spacing: 4) {
            ForEach(ports.prefix(shown), id: \.self) { port in
                PortChip(port: port, isExposed: exposed.contains(port), store: store)
            }
            if !hidden.isEmpty {
                Button(action: toggleExpanded) {
                    Text(verbatim: "+\(hidden.count)")
                        .font(.system(size: 11, weight: .semibold).monospacedDigit())
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 2.5)
                        .background(RoundedRectangle(cornerRadius: 5, style: .continuous).fill(Theme.chipFill))
                }
                .buttonStyle(.plain)
                .help("Also listening on " + hidden.map { ":\($0)" }.joined(separator: "  ") + " — click to show processes")
                .accessibilityLabel("\(hidden.count) more ports")
            }
        }
        .fixedSize()
    }

    private var detailLine: some View {
        HStack(spacing: 5) {
            if let path = locationPath {
                PathLink(path: path, store: store)
                    .layoutPriority(-1)
            } else if let command = group.processes.first?.commandLine {
                Text(DisplayText.command(command))
                    .font(.command)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .layoutPriority(-1)
            }
            if let started = group.oldestStart {
                Text(verbatim: "·").foregroundStyle(.quaternary)
                Text(Format.uptime(since: started))
                    .font(.metric)
                    .foregroundStyle(.tertiary)
                    .fixedSize()
                    .help("Running since \(started.formatted(date: .abbreviated, time: .shortened))")
            }
            Spacer(minLength: 8)
            UsagePill(usage: group.usage,
                      cpuIsHeavy: group.usage.cpuPercent >= store.settings.heavyCPUThreshold,
                      memoryIsHeavy: group.usage.memoryBytes >= store.settings.heavyMemoryBytes)
        }
        .font(.rowCaption)
    }

    /// Folder to show/reveal: the group's path, else the executable (services without a project folder).
    private var locationPath: String? {
        if let path = group.path, !path.isEmpty, path != "/" { return path }
        if let executable = group.processes.first?.details?.executablePath, executable.hasPrefix("/") {
            return executable
        }
        return nil
    }

    // MARK: Badges

    private struct BadgeModel: Identifiable {
        var id: String { text }
        let text: String
        var symbol: String? = nil
        var tint: Color? = nil
        var help: String? = nil
    }

    private var badges: [BadgeModel] {
        var result: [BadgeModel] = group.frameworks.prefix(3).map { BadgeModel(text: $0) }
        // Skip origins that only repeat what the row already says (an app launched itself; launchd shown as manager).
        if let origin = group.origin, origin.kind != .app,
           origin.kind != .launchd || group.supervisingManager == nil {
            result.append(BadgeModel(text: origin.name, symbol: origin.badgeSymbol, tint: origin.badgeTint,
                                     help: "Started from \(origin.name)"))
        }
        // Watchers (nodemon, uvicorn --reload…) are shown per process in the expanded list; here only
        // supervisors that matter for stopping (launchd / pm2 / Docker).
        if let manager = group.supervisingManager, let text = manager.badgeText {
            result.append(BadgeModel(text: text, symbol: manager.badgeSymbol,
                                     tint: manager.isAutoRestarting ? Theme.autoRestart : nil,
                                     help: manager.autoRestartExplanation ?? "Supervised by \(text)"))
        }
        if group.isExposedToNetwork {
            result.append(BadgeModel(text: "Network", symbol: "globe",
                                     help: "Listening on all interfaces — reachable from other devices on your network"))
        }
        // Distinct texts only (ForEach ids).
        var seen = Set<String>()
        return result.filter { seen.insert($0.text).inserted }
    }

    // MARK: Actions

    private var actions: some View {
        HStack(spacing: 0) {
            Menu {
                GroupActionsMenu(group: group, store: store, isBusy: isBusy)
            } label: {
                Image(systemName: "ellipsis")
                    .font(.system(size: 12, weight: .semibold))
                    .frame(width: 18, height: 18)
            }
            .menuStyle(.button)
            .buttonStyle(HoverButtonStyle(padding: EdgeInsets(top: 2, leading: 2, bottom: 2, trailing: 2),
                                          foreground: AnyShapeStyle(.secondary)))
            .menuIndicator(.hidden)
            .fixedSize()
            .help("More actions")
            .accessibilityLabel("More actions for \(group.title)")

            if isBusy {
                ProgressView()
                    .controlSize(.small)
                    .scaleEffect(0.75)
                    .frame(width: 22, height: 22)
                    .accessibilityLabel("Stopping \(group.title)")
            } else {
                IconButton(systemImage: "xmark.circle.fill",
                           label: "Stop \(group.title)",
                           help: "Stop \(group.title) — ⌥-click to force kill",
                           size: 15,
                           foreground: AnyShapeStyle(.tertiary),
                           hoverTint: Theme.destructive) {
                    store.stop(group, mode: NSEvent.modifierFlags.contains(.option) ? .force : .graceful)
                }
            }
        }
        .frame(height: 20)
    }

    private func toggleExpanded() {
        withAnimation(.snappy(duration: 0.22)) {
            if store.expandedGroupIDs.contains(group.id) {
                store.expandedGroupIDs.remove(group.id)
            } else {
                store.expandedGroupIDs.insert(group.id)
            }
        }
    }

    private var accessibilitySummary: String {
        let ports = group.ports.map { String($0) }.joined(separator: ", ")
        return "\(group.title), port\(group.ports.count == 1 ? "" : "s") \(ports), CPU \(Format.cpu(group.usage.cpuPercent)), memory \(Format.bytes(group.usage.memoryBytes))"
    }
}

// MARK: - Path link

/// Abbreviated path ("~/code/foo"); click reveals it in Finder.
private struct PathLink: View {
    let path: String
    let store: AppStore
    @State private var isHovering = false

    var body: some View {
        Button {
            store.revealInFinder(path)
        } label: {
            Text(Format.abbreviatePath(path))
                .font(.rowCaption)
                .foregroundStyle(isHovering ? AnyShapeStyle(.secondary) : AnyShapeStyle(.tertiary))
                .underline(isHovering, color: .secondary)
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .help("Reveal \(path) in Finder")
        .accessibilityLabel("Reveal \(Format.abbreviatePath(path)) in Finder")
    }
}

// MARK: - Expanded detail

/// Process list, kill-plan preview, auto-restart notice and quick actions shown under an expanded group.
private struct GroupDetailView: View {
    let group: ListenerGroup
    let store: AppStore
    let isBusy: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            VStack(alignment: .leading, spacing: 1) {
                ForEach(group.processes) { process in
                    ProcessRow(process: process, store: store, isGroupBusy: isBusy)
                }
            }
            .padding(.horizontal, -6) // process rows carry their own hover inset

            let plan = store.killPlanPreview(for: group)
            if !plan.isEmpty {
                KillPlanPreview(lines: plan)
            }

            if let manager = group.autoRestartManager {
                AutoRestartNotice(group: group, manager: manager, store: store, isBusy: isBusy)
            }

            quickActions
        }
        .padding(.bottom, 2)
    }

    private var quickActions: some View {
        HStack(spacing: 2) {
            if let port = group.ports.first {
                IconButton(systemImage: "safari", label: "Open localhost:\(String(port)) in Browser") {
                    store.openInBrowser(port: port)
                }
            }
            if let path = group.path, path != "/" {
                IconButton(systemImage: "folder", label: "Reveal in Finder") { store.revealInFinder(path) }
                if group.category == .project || group.category == .service {
                    IconButton(systemImage: "terminal", label: "Open in Terminal") { store.openInTerminal(path) }
                    if let editor = store.preferredEditorName {
                        IconButton(systemImage: "chevron.left.forwardslash.chevron.right", label: "Open in \(editor)") {
                            store.openInEditor(path)
                        }
                    }
                }
            }
            IconButton(systemImage: "doc.on.doc", label: "Copy Command") {
                store.copy(group.processes.map(\.commandLine).joined(separator: "\n"))
            }
            Spacer(minLength: 0)
        }
        .padding(.leading, -4)
    }
}

/// "Stop ends: npm run dev (pid 1200) → node vite (pid 1201)".
private struct KillPlanPreview: View {
    let lines: [String]

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Label("Stop will end", systemImage: "arrow.turn.down.right")
                .font(.system(size: 10.5, weight: .semibold))
                .foregroundStyle(.secondary)
            ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                Text(line)
                    .font(.command)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .help(line)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(Theme.cardFill))
    }
}

/// Orange notice for launchd / pm2 / Docker-managed groups with an inline-confirmed "Stop & Disable".
private struct AutoRestartNotice: View {
    let group: ListenerGroup
    let manager: ProcessManager
    let store: AppStore
    let isBusy: Bool

    var body: some View {
        HStack(alignment: .center, spacing: 8) {
            Image(systemName: "arrow.clockwise.circle.fill")
                .font(.system(size: 13))
                .foregroundStyle(Theme.autoRestart)
            Text(manager.autoRestartExplanation ?? "Restarts automatically.")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 4)
            ConfirmButton(title: "Stop & Disable", confirmTitle: "Confirm", tint: Theme.autoRestart,
                          foreground: AnyShapeStyle(Theme.autoRestart),
                          font: .system(size: 11, weight: .semibold)) {
                store.stopAndDisableAutoStart(group)
            }
            .disabled(isBusy)
            .fixedSize()
        }
        .padding(.leading, 8)
        .padding(.trailing, 4)
        .padding(.vertical, 4)
        .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(Theme.autoRestart.opacity(0.09)))
    }
}

// MARK: - Actions menu

/// Shared by the overflow (⋯) button and the row's context menu.
struct GroupActionsMenu: View {
    let group: ListenerGroup
    let store: AppStore
    var isBusy = false

    var body: some View {
        let ports = group.ports
        if ports.count == 1, let port = ports.first {
            Button("Open in Browser") { store.openInBrowser(port: port) }
        } else if ports.count > 1 {
            Menu("Open in Browser") {
                ForEach(ports, id: \.self) { port in
                    Button("localhost:\(String(port))") { store.openInBrowser(port: port) }
                }
            }
        }
        if let path = group.path, path != "/" {
            Button("Reveal in Finder") { store.revealInFinder(path) }
            if group.category == .project || group.category == .service {
                Button("Open in Terminal") { store.openInTerminal(path) }
                if let editor = store.preferredEditorName {
                    Button("Open in \(editor)") { store.openInEditor(path) }
                }
            }
        }

        Divider()

        Button("Copy Command") {
            store.copy(group.processes.map(\.commandLine).joined(separator: "\n"))
        }
        Button(group.processes.count > 1 ? "Copy PIDs" : "Copy PID") {
            store.copy(group.processes.map { String($0.basic.pid) }.joined(separator: " "))
        }

        Divider()

        Button("Stop") { store.stop(group, mode: .graceful) }
            .disabled(isBusy)
        Button("Force Kill") { store.stop(group, mode: .force) }
            .disabled(isBusy)
        if group.autoRestartManager != nil {
            Button("Stop & Disable Auto-Start") { store.stopAndDisableAutoStart(group) }
                .disabled(isBusy)
        }

        Divider()

        Button("Hide This Item") { store.ignore(group) }
    }
}
