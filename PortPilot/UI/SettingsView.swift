import SwiftUI

/// Settings, shown in place of the list (sheets and separate windows would close the menu bar panel).
/// Every control binds straight to `store.settings`; AppStore persists and applies changes.
struct SettingsView: View {
    @Bindable var store: AppStore
    /// Opens the About page (the row at the bottom).
    var onShowAbout: () -> Void = {}
    var onDone: () -> Void = {}

    private static let cpuChoices: [Double] = [25, 50, 80, 100, 150, 200]
    private static let memoryChoices: [UInt64] = [500_000_000, 1_000_000_000, 1_500_000_000, 2_000_000_000, 4_000_000_000]

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .center) {
                Text("Settings")
                    .font(.system(size: 15, weight: .semibold))
                Spacer()
                Button("Done", action: onDone)
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                    .help("Back to the list (⌘,)")
            }

            SettingsSection(title: "General") {
                SettingsRow(title: "Launch at login", subtitle: SettingsText.launchAtLoginSubtitle(
                    canManage: store.canManageLaunchAtLogin)) {
                    switchToggle("Launch at login", isOn: $store.settings.launchAtLogin)
                        .disabled(!store.canManageLaunchAtLogin)
                }
                SettingsRow(title: "Refresh every") {
                    Picker("Refresh every", selection: $store.settings.refreshInterval) {
                        ForEach(AppSettings.refreshChoices, id: \.self) { seconds in
                            Text(verbatim: "\(Int(seconds)) s").tag(seconds)
                        }
                    }
                    .menuPicker()
                }
                SettingsRow(title: "Show port count in menu bar") {
                    switchToggle("Show port count in menu bar", isOn: $store.settings.showCountInMenuBar)
                }
                SettingsRow(title: "Notify when a new port opens") {
                    switchToggle("Notify when a new port opens", isOn: $store.settings.notifyOnNewPorts)
                }
                updatesRow
                folderAccessRow
            }

            SettingsSection(title: "List") {
                SettingsRow(title: "Show apps", subtitle: "Ports opened by apps like VS Code or Spotify.") {
                    switchToggle("Show apps", isOn: $store.settings.showApps)
                }
                SettingsRow(title: "Show system processes", subtitle: "macOS services and other users’ processes.") {
                    switchToggle("Show system processes", isOn: $store.settings.showSystem)
                }
                SettingsRow(title: "Sort by") {
                    Picker("Sort by", selection: $store.settings.sortOrder) {
                        ForEach(AppSettings.SortOrder.allCases) { order in
                            Text(order.title).tag(order)
                        }
                    }
                    .menuPicker()
                }
                SettingsRow(title: "Highlight CPU above", subtitle: "Percent of one core.") {
                    Picker("Highlight CPU above", selection: $store.settings.heavyCPUThreshold) {
                        ForEach(Self.choices(Self.cpuChoices, current: store.settings.heavyCPUThreshold), id: \.self) { value in
                            Text(verbatim: "\(Int(value))%").tag(value)
                        }
                    }
                    .menuPicker()
                }
                SettingsRow(title: "Highlight memory above") {
                    Picker("Highlight memory above", selection: $store.settings.heavyMemoryBytes) {
                        ForEach(Self.choices(Self.memoryChoices, current: store.settings.heavyMemoryBytes), id: \.self) { value in
                            Text(Format.bytes(value)).tag(value)
                        }
                    }
                    .menuPicker()
                }
                SettingsRow(title: "Hidden items", subtitle: hiddenItemsSummary, showsDivider: false) {
                    Button("Unhide All") { store.unignoreAll() }
                        .controlSize(.small)
                        .disabled(hiddenItemCount == 0)
                }
            }

            SettingsSection(title: "Stopping") {
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text("Wait before force-killing")
                            .font(.system(size: 12.5))
                        Spacer()
                        Text(verbatim: "\(Int(store.settings.gracefulTimeout.rounded())) s")
                            .font(.system(size: 12, weight: .medium).monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                    Slider(value: $store.settings.gracefulTimeout, in: 1...10, step: 1) {
                        Text("Wait before force-killing")
                    }
                    .labelsHidden()
                    .controlSize(.small)
                    Text("Stop sends SIGTERM so servers can shut down cleanly, then SIGKILL after this delay. Apps and macOS services ask to confirm first and are never force-killed after it. ⌥-click Stop to kill immediately.")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
            }

            aboutRow
        }
        .padding(.horizontal, 14)
        .padding(.top, 10)
        .padding(.bottom, 14)
        // Only re-reads folders already asked about, so opening Settings never shows a macOS prompt.
        .task { store.folderAccess.refresh() }
    }

    // MARK: Updates, folder access, About

    private var updatesRow: some View {
        let updates = store.updates
        return SettingsRow(title: "Check for updates automatically",
                           subtitle: updates.statusMessage ?? SettingsText.updatesSubtitle,
                           subtitleStyle: updates.lastCheckFailed ? AnyShapeStyle(Color.orange) : AnyShapeStyle(.secondary),
                           showsDivider: !store.folderAccess.denied.isEmpty) {
            HStack(spacing: 8) {
                if updates.isChecking {
                    ProgressView()
                        .controlSize(.mini)
                        .accessibilityLabel("Checking for updates")
                }
                Button("Check Now") { updates.checkNow() }
                    .controlSize(.small)
                    .disabled(updates.isChecking)
                    .help("Ask GitHub for the latest PortPilot release")
                switchToggle("Check for updates automatically", isOn: $store.settings.checkForUpdates)
            }
        }
    }

    @ViewBuilder
    private var folderAccessRow: some View {
        let denied = store.folderAccess.denied
        if !denied.isEmpty {
            SettingsRow(title: "Folder access",
                        subtitle: SettingsText.folderAccessSubtitle(denied: denied),
                        showsDivider: false) {
                Button("Open Privacy Settings") { store.folderAccess.openPrivacySettings() }
                    .controlSize(.small)
                    .help("System Settings › Privacy & Security › Files & Folders")
            }
        }
    }

    /// Bottom row: app glyph, version, and the way into About.
    private var aboutRow: some View {
        Button(action: onShowAbout) {
            HStack(spacing: 10) {
                AppGlyph(size: 30)
                VStack(alignment: .leading, spacing: 1) {
                    Text("About PortPilot")
                        .font(.system(size: 12.5, weight: .semibold))
                    Text(AppInfo.versionLine())
                        .font(.system(size: 11).monospacedDigit())
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 8)
                if let update = store.updates.availableUpdate {
                    Text(verbatim: "\(update.version) available")
                        .font(.system(size: 10.5, weight: .semibold))
                        .foregroundStyle(Color.accentColor)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Capsule().fill(Color.accentColor.opacity(0.14)))
                }
                Image(systemName: "chevron.right")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.tertiary)
                    .accessibilityHidden(true)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .contentShape(Rectangle())
        }
        .buttonStyle(HoverButtonStyle(cornerRadius: 10, padding: EdgeInsets()))
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Theme.cardFill))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Theme.hairline, lineWidth: 0.5))
        .help("Version, credits, links and updates")
        .accessibilityLabel("About PortPilot, \(AppInfo.versionLine())")
    }

    // MARK: Helpers

    private var hiddenItemCount: Int {
        store.settings.ignoredGroupIDs.count + store.settings.ignoredPorts.count
    }

    private var hiddenItemsSummary: String {
        switch hiddenItemCount {
        case 0: return "Nothing hidden. Use “Hide This Item” in a row’s menu."
        case 1: return "1 item you chose to hide."
        default: return "\(hiddenItemCount) items you chose to hide."
        }
    }

    private func switchToggle(_ title: String, isOn: Binding<Bool>) -> some View {
        Toggle(title, isOn: isOn)
            .labelsHidden()
            .toggleStyle(PanelSwitchStyle())
            .controlSize(.mini)
    }

    /// Keeps a custom persisted value selectable even when it isn't one of the presets.
    private static func choices<T: Comparable>(_ presets: [T], current: T) -> [T] {
        presets.contains(current) ? presets : (presets + [current]).sorted()
    }
}

/// Settings copy that depends on state, kept pure for tests.
enum SettingsText {
    static let updatesSubtitle = "Asks GitHub once a day for the latest version. Nothing about you is sent."

    static func launchAtLoginSubtitle(canManage: Bool) -> String {
        canManage ? "Starts at login and comes back if it ever crashes."
            : "Move PortPilot to Applications to start it at login"
    }

    /// "Downloads — Not allowed. Projects there show by folder name only."
    static func folderAccessSubtitle(denied: [String]) -> String {
        "\(FolderAccess.list(denied.map(FolderAccess.displayName))) — Not allowed. "
            + "Projects there show by folder name only."
    }
}

// MARK: - Building blocks

/// Grouped "card" like System Settings: uppercase caption above a rounded inset container.
struct SettingsSection<Content: View>: View {
    let title: String
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title.uppercased())
                .font(.system(size: 10.5, weight: .semibold))
                .tracking(0.5)
                .foregroundStyle(.secondary)
                .padding(.leading, 4)
                .accessibilityAddTraits(.isHeader)
            VStack(alignment: .leading, spacing: 0) {
                content
            }
            .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Theme.cardFill))
            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Theme.hairline, lineWidth: 0.5))
        }
    }
}

/// Title (+ optional explanation) on the left, a control on the right, hairline divider below.
struct SettingsRow<Control: View>: View {
    let title: String
    var subtitle: String? = nil
    var subtitleStyle = AnyShapeStyle(.secondary)
    var showsDivider = true
    @ViewBuilder var control: Control

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .center, spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.system(size: 12.5))
                    if let subtitle {
                        Text(subtitle)
                            .font(.system(size: 11))
                            .foregroundStyle(subtitleStyle)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                Spacer(minLength: 8)
                control
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .frame(minHeight: 36)

            if showsDivider {
                Rectangle()
                    .fill(Theme.hairline)
                    .frame(height: 0.5)
                    .padding(.leading, 12)
            }
        }
    }
}

private extension View {
    /// Compact pop-up button used for every picker in Settings.
    func menuPicker() -> some View {
        self
            .labelsHidden()
            .pickerStyle(.menu)
            .controlSize(.small)
            .fixedSize()
    }
}
