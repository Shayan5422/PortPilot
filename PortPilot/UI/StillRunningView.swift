import AppKit
import SwiftUI

/// Collapsible "Still running · no open port" section: tools whose ports closed while some of their processes kept
/// running (a crashed server under `npm run dev` with its worker, a tool that closed its socket but never exited),
/// with their CPU and memory and a Stop button. Each entry goes away on its own once its processes exit.
struct StillRunningView: View {
    let store: AppStore
    @Binding var isCollapsed: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            SectionHeader(title: "Still Running · No Open Port", count: store.stillRunning.count,
                          isCollapsed: $isCollapsed)
            if !isCollapsed {
                VStack(spacing: 1) {
                    ForEach(store.stillRunning) { item in
                        StillRunningRow(item: item, store: store)
                    }
                }
                .transition(.opacity)
            }
        }
    }
}

private struct StillRunningRow: View {
    let item: StillRunningItem
    let store: AppStore

    @State private var isHovering = false

    private var isBusy: Bool { store.busyGroupIDs.contains(item.busyID) }

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(Theme.autoRestart.opacity(0.13))
                .overlay(
                    Image(systemName: "antenna.radiowaves.left.and.right.slash")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(Theme.autoRestart))
                .frame(width: Theme.iconSize, height: Theme.iconSize)
                .padding(.leading, Theme.chevronWidth + 6)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 2) {
                HStack(alignment: .center, spacing: 6) {
                    Text(item.title)
                        .font(.system(size: 12.5, weight: .medium))
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .layoutPriority(1)
                    CappedPortChips(ports: item.formerPorts, spacing: 3) { port in
                        Text(verbatim: ":\(port)")
                            .font(.system(size: 10.5, weight: .semibold).monospacedDigit())
                            .foregroundStyle(.tertiary)
                            .strikethrough(true, color: .secondary.opacity(0.6))
                    } overflow: { hidden in
                        Text(verbatim: "+\(hidden.count)")
                            .font(.system(size: 10.5, weight: .semibold).monospacedDigit())
                            .foregroundStyle(.tertiary)
                    }
                    .help("Was listening on " + PortChipOverflow.list(item.formerPorts))
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel("Was on port \(item.formerPorts.map { String($0) }.joined(separator: ", "))")
                    Spacer(minLength: 6)
                    UsagePill(usage: item.usage,
                              cpuIsHeavy: item.usage.cpuPercent >= store.settings.heavyCPUThreshold,
                              memoryIsHeavy: item.usage.memoryBytes >= store.settings.heavyMemoryBytes)
                }
                HStack(spacing: 5) {
                    Text(DisplayText.command(item.processSummary))
                        .font(.command)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .layoutPriority(-1)
                    Text(verbatim: "·").foregroundStyle(.quaternary)
                    TimeAgoText(date: item.closedAt, interval: 15, format: Self.closedAgo)
                        .font(.metric)
                        .foregroundStyle(.tertiary)
                        .fixedSize()
                }
                .help(processHelp)
            }
            .padding(.leading, 9)
            .padding(.trailing, 6)

            stopControl
                .frame(height: 20)
        }
        .padding(.horizontal, Theme.rowPadding)
        .padding(.vertical, 6)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(isHovering ? Theme.hoverFill : .clear))
        .onHover { isHovering = $0 }
        .contextMenu { menu }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(item.title), still running without an open port")
    }

    @ViewBuilder
    private var stopControl: some View {
        if isBusy {
            ProgressView()
                .controlSize(.small)
                .scaleEffect(0.75)
                .frame(width: 22, height: 22)
                .accessibilityLabel("Stopping \(item.title)")
        } else {
            IconButton(systemImage: "xmark.circle.fill",
                       label: "Stop \(item.title)",
                       help: "Stop what is still running of \(item.title) — ⌥-click to force kill",
                       size: 15,
                       foreground: AnyShapeStyle(.tertiary),
                       hoverTint: Theme.destructive) {
                store.stopStillRunning(item, mode: NSEvent.modifierFlags.contains(.option) ? .force : .graceful)
            }
        }
    }

    @ViewBuilder
    private var menu: some View {
        Button("Stop") { store.stopStillRunning(item) }
        Button("Force Kill") { store.stopStillRunning(item, mode: .force) }
        Divider()
        if let path = item.path, path != "/" {
            Button("Reveal in Finder") { store.revealInFinder(path) }
        }
        Button("Copy PIDs") { store.copy(item.processes.map { String($0.pid) }.joined(separator: " ")) }
    }

    /// One line per process: "npm run dev (pid 1200)".
    private var processHelp: String {
        let lines = item.processes.reversed().map { "\(item.labels[$0.pid] ?? $0.comm) (pid \($0.pid))" }
        return "Ports closed, but still running:\n" + lines.joined(separator: "\n")
    }

    /// "closed just now", "closed 4m ago".
    nonisolated static func closedAgo(_ elapsed: TimeInterval) -> String {
        "closed " + TimeAgoText.defaultFormat(elapsed)
    }
}
