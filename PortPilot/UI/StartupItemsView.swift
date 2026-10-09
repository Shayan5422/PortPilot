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

    var body: some View {
        let items = Self.visibleItems(in: store)
        VStack(alignment: .leading, spacing: 0) {
            SectionHeader(title: "Startup Items", count: items.count, isCollapsed: $isCollapsed)
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
}

private struct StartupItemRow: View {
    let item: StartupItem
    let store: AppStore

    @State private var isHovering = false

    private var status: Status { Status(item) }

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            icon
                .padding(.leading, Theme.chevronWidth + 6) // aligns with group rows (no chevron here)
                .help(status.text)

            VStack(alignment: .leading, spacing: 2) {
                HStack(alignment: .center, spacing: 6) {
                    Text(Self.friendlyName(for: item.label))
                        .font(.system(size: 12.5, weight: .medium))
                        .foregroundStyle(item.isDisabled ? AnyShapeStyle(.secondary) : AnyShapeStyle(.primary))
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .help(item.label)
                    if item.isHomebrew {
                        Text("Homebrew")
                            .font(.system(size: 11))
                            .foregroundStyle(.tertiary)
                    }
                    Spacer(minLength: 6)
                    HStack(spacing: 3) {
                        ForEach(item.ports, id: \.self) { port in
                            PortChip(port: port, compact: true, store: store)
                        }
                    }
                    .fixedSize()
                }
                HStack(spacing: 5) {
                    Text(status.text)
                        .foregroundStyle(status.isProblem ? AnyShapeStyle(Theme.destructive) : AnyShapeStyle(.secondary))
                        .fixedSize()
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
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .help(item.command)
                }
                .font(.system(size: 11))
            }
            .padding(.leading, 9)
            .padding(.trailing, 6)

            HStack(spacing: 6) {
                if item.isLoaded && !item.isRunning && !item.isDisabled {
                    Button("Start") { store.startStartupItem(item) }
                        .buttonStyle(HoverButtonStyle(padding: EdgeInsets(top: 2, leading: 7, bottom: 2, trailing: 7),
                                                      isEmphasized: true))
                        .font(.system(size: 11, weight: .medium))
                        .help("Start \(item.label) now (launchctl kickstart)")
                }
                Toggle(isOn: Binding(
                    get: { !item.isDisabled },
                    set: { store.setStartupItem(item, enabled: $0) })
                ) {
                    Text(item.label)
                }
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.mini)
                .help(item.isDisabled ? "Enable — start at login again" : "Disable — stop it and keep it from starting at login")
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
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(item.label), \(status.text)")
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
                StatusDot(color: status.color, isHollow: status.isHollow)
                    .padding(3)
            }
            .accessibilityHidden(true)
    }

    /// "homebrew.mxcl.postgresql@16" → "postgresql@16", "com.acme.claude-monitor" → "claude-monitor".
    static func friendlyName(for label: String) -> String {
        for prefix in ["homebrew.mxcl.", "sh.brew."] where label.hasPrefix(prefix) {
            return String(label.dropFirst(prefix.count))
        }
        let parts = label.split(separator: ".")
        // Reverse-DNS labels: drop the "com.vendor." part when something meaningful remains.
        if parts.count >= 3, ["com", "org", "net", "io", "app", "dev", "me", "co"].contains(parts[0].lowercased()) {
            return parts.dropFirst(2).joined(separator: ".")
        }
        return label
    }

    /// Display status derived from launchd's view of the job.
    private struct Status {
        let text: String
        let color: Color
        var isHollow = false
        var isProblem = false

        init(_ item: StartupItem) {
            if item.isDisabled {
                text = "Disabled"
                color = .secondary
                isHollow = true
            } else if let pid = item.pid {
                text = "Running · PID \(pid)"
                color = .green
            } else if let exit = item.lastExitStatus, exit != 0 {
                text = "Exited with \(exit)"
                color = Theme.destructive
                isProblem = true
            } else if item.isLoaded {
                text = "Loaded · not running"
                color = .gray
            } else {
                text = "Not loaded"
                color = .gray
                isHollow = true
            }
        }
    }
}
