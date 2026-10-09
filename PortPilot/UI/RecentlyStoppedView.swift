import SwiftUI

/// Collapsible "Recently Stopped" section so a server stopped by mistake can be relaunched
/// (same argv, env and cwd) or its command copied. Records live in memory only.
struct RecentlyStoppedView: View {
    let store: AppStore
    @Binding var isCollapsed: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            SectionHeader(title: "Recently Stopped", count: store.recentlyStopped.count, isCollapsed: $isCollapsed) {
                Button("Clear") { store.clearRecentlyStopped() }
                    .buttonStyle(HoverButtonStyle(padding: EdgeInsets(top: 1, leading: 6, bottom: 1, trailing: 6),
                                                  foreground: AnyShapeStyle(.secondary)))
                    .font(.system(size: 11, weight: .medium))
                    .help("Forget all recently stopped items")
            }
            if !isCollapsed {
                VStack(spacing: 1) {
                    ForEach(store.recentlyStopped) { record in
                        StoppedRecordRow(record: record, store: store)
                    }
                }
                .transition(.opacity)
            }
        }
    }
}

private struct StoppedRecordRow: View {
    let record: StoppedRecord
    let store: AppStore

    @State private var isHovering = false

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(Color.primary.opacity(0.07))
                .overlay(
                    Image(systemName: "stop.fill")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.tertiary))
                .frame(width: Theme.iconSize, height: Theme.iconSize)
                .padding(.leading, Theme.chevronWidth + 6)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 2) {
                HStack(alignment: .center, spacing: 6) {
                    Text(record.title)
                        .font(.system(size: 12.5, weight: .medium))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                    HStack(spacing: 3) {
                        ForEach(record.ports, id: \.self) { port in
                            Text(verbatim: ":\(port)")
                                .font(.system(size: 10.5, weight: .semibold).monospacedDigit())
                                .foregroundStyle(.tertiary)
                                .strikethrough(true, color: .secondary.opacity(0.6))
                        }
                    }
                    .fixedSize()
                    .accessibilityLabel("Was on port \(record.ports.map { String($0) }.joined(separator: ", "))")
                    Spacer(minLength: 6)
                    TimeAgoText(date: record.date, interval: 15)
                        .font(.metric)
                        .foregroundStyle(.tertiary)
                        .fixedSize()
                }
                Text(record.commandLine.isEmpty ? "Command unavailable" : DisplayText.command(record.commandLine))
                    .font(.command)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .help(record.commandLine)
            }
            .padding(.leading, 9)
            .padding(.trailing, 6)

            HStack(spacing: 0) {
                if record.canRelaunch {
                    Button {
                        store.relaunch(record)
                    } label: {
                        Label("Relaunch", systemImage: "arrow.clockwise")
                            .labelStyle(.titleAndIcon)
                    }
                    .buttonStyle(HoverButtonStyle(padding: EdgeInsets(top: 2, leading: 6, bottom: 2, trailing: 7),
                                                  isEmphasized: true))
                    .font(.system(size: 11, weight: .medium))
                    .help("Run the same command again in \(record.cwd.map(Format.abbreviatePath) ?? "its original folder")")
                    .padding(.trailing, 2)
                } else if let reason = relaunchUnavailableReason {
                    Image(systemName: "info.circle")
                        .font(.system(size: 11))
                        .foregroundStyle(.tertiary)
                        .frame(width: 22, height: 22)
                        .help(reason)
                        .accessibilityLabel(reason)
                }
                IconButton(systemImage: "doc.on.doc", label: "Copy Command", size: 11.5) {
                    store.copy(record.commandLine)
                }
                .disabled(record.commandLine.isEmpty)
                if let cwd = record.cwd {
                    IconButton(systemImage: "folder", label: "Reveal in Finder", size: 11.5) {
                        store.revealInFinder(cwd)
                    }
                }
            }
            .frame(height: 20)
        }
        .padding(.horizontal, Theme.rowPadding)
        .padding(.vertical, 6)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(isHovering ? Theme.hoverFill : .clear))
        .onHover { isHovering = $0 }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(record.title), stopped")
    }

    private var relaunchUnavailableReason: String? {
        switch record.manager {
        case .launchd(let job): return "Managed by launchd — turn it back on under Startup Items (\(job.label))."
        case .pm2(_, let name): return "Managed by pm2 — restart it with “pm2 restart \(name)”."
        case .docker(let container): return "Docker container — restart it with “docker start \(container.name)”."
        case .none, .watcher: return record.arguments.isEmpty ? "The original command could not be read." : nil
        }
    }
}
