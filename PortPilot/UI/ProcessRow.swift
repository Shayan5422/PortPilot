import AppKit
import SwiftUI

/// One listening process inside an expanded group.
///
///     vite  frontend  :5330                         2.4% · 260 MB  ⊗
///     PID 48211  node …/node_modules/.bin/vite --port 5330
///
/// Hovering shows the full command line. ⌥-click on the stop button kills only this PID
/// (instead of the whole kill plan: runner + children).
struct ProcessRow: View {
    let process: ListenerProcess
    let store: AppStore
    var isGroupBusy = false

    @State private var isHovering = false

    var body: some View {
        HStack(alignment: .top, spacing: 6) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(alignment: .center, spacing: 6) {
                    Text(process.displayName)
                        .font(.system(size: 12, weight: .medium))
                        .lineLimit(1)
                        .truncationMode(.tail)
                    if let subpath = process.project?.subpath, !subpath.isEmpty {
                        Text(subpath)
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    if process.isRestricted {
                        Image(systemName: "lock.fill")
                            .font(.system(size: 9))
                            .foregroundStyle(.tertiary)
                            .help("Owned by another user — details unavailable, stopping may ask for an administrator password")
                            .accessibilityLabel("Owned by another user")
                    }
                    HStack(spacing: 3) {
                        ForEach(process.ports, id: \.self) { port in
                            PortChip(port: port,
                                     isExposed: process.sockets.contains { $0.port == port && $0.isExposed },
                                     compact: true,
                                     store: store)
                        }
                    }
                    .fixedSize()
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
                            .help("Reloaded on file changes by \(name) — Stop ends the watcher too")
                    }
                    Text(DisplayText.command(process.commandLine))
                        .font(.command)
                        .foregroundStyle(.tertiary)
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

    @ViewBuilder
    private var stopButton: some View {
        IconButton(systemImage: "xmark.circle",
                   label: "Stop \(process.displayName)",
                   help: "Stop this process and its runner — ⌥-click to stop only PID \(process.basic.pid)",
                   size: 12.5,
                   foreground: AnyShapeStyle(.tertiary),
                   hoverTint: Theme.destructive) {
            let onlyThis = NSEvent.modifierFlags.contains(.option)
            store.stop(process, mode: .graceful, onlyThisProcess: onlyThis)
        }
        .disabled(isGroupBusy)
        .padding(.top, -1)
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
        Divider()
        Button("Stop") { store.stop(process, mode: .graceful) }
            .disabled(isGroupBusy)
        Button("Stop Only This Process") { store.stop(process, mode: .graceful, onlyThisProcess: true) }
            .disabled(isGroupBusy)
        Button("Force Kill") { store.stop(process, mode: .force) }
            .disabled(isGroupBusy)
    }
}
