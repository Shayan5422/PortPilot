import AppKit
import SwiftUI

/// One listening process inside an expanded group.
///
///     vite  frontend  :5330                         2.4% · 260 MB  ⊗
///     PID 48211  node …/node_modules/.bin/vite --port 5330
///
/// Hovering shows the full command line. The stop button ends this process's kill plan (runner + children);
/// ⌥-click force-kills it (SIGKILL), exactly like the group's stop button. "Stop Only This Process" in the
/// context menu ends just this PID. Apps, macOS services and other users' processes need a second click
/// (see `StopSafety`).
struct ProcessRow: View {
    let process: ListenerProcess
    let store: AppStore
    var isGroupBusy = false

    @State private var isHovering = false

    var body: some View {
        HStack(alignment: .top, spacing: 6) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(alignment: .center, spacing: 6) {
                    nameAndSubpath
                        .layoutPriority(1) // the Spacer gives way first; the capped port chips never shrink
                    if process.isRestricted {
                        Image(systemName: "lock.fill")
                            .font(.system(size: 9))
                            .foregroundStyle(.tertiary)
                            .help("Owned by another user — details unavailable, stopping may ask for an administrator password")
                            .accessibilityLabel("Owned by another user")
                    }
                    CappedPortChips(ports: process.ports, spacing: 3) { port in
                        PortChip(port: port,
                                 isExposed: process.sockets.contains { $0.port == port && $0.isExposed },
                                 compact: true,
                                 store: store)
                    } overflow: { hidden in
                        HiddenPortsMenu(ports: hidden, compact: true, store: store)
                    }
                    Spacer(minLength: 6)
                    UsagePill(usage: process.treeUsage,
                              cpuIsHeavy: process.treeUsage.cpuPercent >= store.settings.heavyCPUThreshold,
                              memoryIsHeavy: process.treeUsage.memoryBytes >= store.settings.heavyMemoryBytes)
                }
                HStack(spacing: 6) {
                    Text(verbatim: "PID \(process.basic.pid)")
                        .font(.system(size: 10.5).monospacedDigit())
                        .foregroundStyle(.tertiary)
                        .fixedSize()
                    if case .watcher(let name) = process.manager {
                        Label(name, systemImage: "eye")
                            .labelStyle(CompactLabelStyle())
                            .font(.system(size: 10.5, weight: .medium))
                            .foregroundStyle(.secondary)
                            .fixedSize()
                            .help(Self.watcherHelp(for: name))
                    }
                    Text(DisplayText.command(process.commandLine))
                        .font(.command)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }

            stopButton
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 4)
        .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(isHovering ? Theme.hoverFill : .clear))
        .contentShape(Rectangle())
        .onHover { isHovering = $0 }
        .help(process.commandLine)
        .contextMenu { menu }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(process.displayName), PID \(String(process.basic.pid))")
    }

    /// Name plus the package folder ("frontend"); the folder is dropped rather than clipped to a sliver.
    @ViewBuilder
    private var nameAndSubpath: some View {
        let name = Text(process.displayName)
            .font(.system(size: 12, weight: .medium))
            .lineLimit(1)
            .truncationMode(.tail)
        if let subpath = process.project?.subpath, !subpath.isEmpty {
            NameAndDetail(spacing: 6, name: name,
                          detail: Text(subpath)
                              .font(.system(size: 11))
                              .foregroundStyle(.secondary)
                              .lineLimit(1))
        } else {
            name
        }
    }

    private var stopHelp: String { "Stop this process and its runner — ⌥-click to force kill" }

    /// Tooltip for the watcher label. supervisord runs many programs, so Stop never ends it (KillPlanner).
    static func watcherHelp(for name: String) -> String {
        if name == "supervisord" {
            return "Run by supervisord, which may start it again — use supervisorctl to stop it for good"
        }
        return "Reloaded on file changes by \(name) — Stop ends the watcher too"
    }

    @ViewBuilder
    private var stopButton: some View {
        switch StopSafety.forProcess(process) {
        case .unavailable:
            // Keeps the usage column aligned with the other process rows.
            Color.clear
                .frame(width: 22, height: 22)
                .accessibilityHidden(true)
        case .oneClick:
            IconButton(systemImage: "xmark.circle",
                       label: "Stop \(process.displayName)",
                       help: stopHelp,
                       size: 12.5,
                       foreground: AnyShapeStyle(.tertiary),
                       hoverTint: Theme.destructive,
                       action: stopFromButton)
                .disabled(isGroupBusy)
                .padding(.top, -1)
        case .confirm(let reason):
            ConfirmButton(title: "", confirmTitle: "Stop?", systemImage: "xmark.circle",
                          foreground: AnyShapeStyle(.tertiary),
                          help: stopHelp + " (asks to confirm)",
                          armedHelp: reason.armedHelp(title: process.displayName),
                          accessibilityName: "Stop \(process.displayName)",
                          iconSize: 12.5,
                          action: stopFromButton)
                .fixedSize()
                .disabled(isGroupBusy)
                .padding(.top, -1)
        }
    }

    private func stopFromButton() {
        store.stop(process, mode: NSEvent.modifierFlags.contains(.option) ? .force : .graceful)
    }

    @ViewBuilder
    private var menu: some View {
        if let port = process.ports.first {
            Button("Open localhost:\(String(port))") { store.openInBrowser(port: port) }
            Divider()
        }
        Button("Copy Command") { store.copy(process.commandLine) }
        Button("Copy PID") { store.copy(String(process.basic.pid)) }
        if let cwd = process.details?.cwd, cwd != "/" {
            Button("Reveal Working Directory") { store.revealInFinder(cwd) }
        }
        let safety = StopSafety.forProcess(process)
        if safety.isAvailable {
            Divider()
            if let reason = safety.reason {
                Menu("Stop") {
                    Text(reason.menuNote)
                    Divider()
                    stopItems
                }
            } else {
                stopItems
            }
        }
    }

    @ViewBuilder
    private var stopItems: some View {
        Button("Stop") { store.stop(process, mode: .graceful) }
            .disabled(isGroupBusy)
        Button("Stop Only This Process") { store.stop(process, mode: .graceful, onlyThisProcess: true) }
            .disabled(isGroupBusy)
        Button("Force Kill") { store.stop(process, mode: .force) }
            .disabled(isGroupBusy)
    }
}
