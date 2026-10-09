import AppKit
import SwiftUI

/// The menu bar panel: header, search, banner, sectioned list (or Settings in place), footer.
///
/// `snapshotMode` renders the full height without a ScrollView, with an opaque background and without
/// window observers, so `SnapshotRenderer` can draw it offscreen.
struct PanelView: View {
    @Bindable var store: AppStore
    let snapshotMode: Bool

    @State private var showingSettings: Bool
    @State private var listContentHeight: CGFloat = 320
    @FocusState private var isSearchFocused: Bool
    /// Comma-separated keys of collapsed sections (category raw values, "startup", "stopped").
    @AppStorage("PortPilot.collapsedSections") private var collapsedSectionsStorage = "startup"

    init(store: AppStore, snapshotMode: Bool = false, initiallyShowingSettings: Bool = false) {
        self.store = store
        self.snapshotMode = snapshotMode
        _showingSettings = State(initialValue: initiallyShowingSettings)
    }

    var body: some View {
        VStack(spacing: 0) {
            PanelHeader(store: store, showingSettings: $showingSettings)

            if showingSettings {
                Hairline()
                scrollable {
                    SettingsView(store: store) { closeSettings() }
                }
            } else {
                SearchField(text: $store.searchText, isFocused: $isSearchFocused)
                    .padding(.horizontal, 12)
                    .padding(.bottom, 8)

                if let banner = store.banner {
                    BannerView(banner: banner, store: store)
                        .padding(.horizontal, 12)
                        .padding(.bottom, 8)
                        .transition(.move(edge: .top).combined(with: .opacity))
                }

                Hairline()
                scrollable { listContent }
                Hairline()
                PanelFooter(store: store)
            }
        }
        .frame(width: Theme.panelWidth)
        .background {
            if snapshotMode { Theme.snapshotBackground }
        }
        .background { keyboardShortcuts }
        .background {
            if !snapshotMode {
                WindowVisibilityReader { visible in panelVisibilityChanged(visible) }
            }
        }
        .animation(snapshotMode ? nil : .snappy(duration: 0.22), value: store.banner)
        .animation(snapshotMode ? nil : .snappy(duration: 0.2), value: showingSettings)
        .onExitCommand(perform: exitCommand)
        .onAppear {
            // Polling normally starts from the menu bar label at launch; this is an idempotent fallback.
            if !snapshotMode { store.start() }
        }
    }

    // MARK: List

    private var listContent: some View {
        VStack(alignment: .leading, spacing: 2) {
            let sections = store.sections
            if sections.isEmpty {
                EmptyStateView(searchText: store.searchText, hiddenCount: store.hiddenCount)
            }
            ForEach(sections, id: \.category) { section in
                let key = section.category.rawValue
                SectionHeader(title: section.category.title, count: section.groups.count,
                              isCollapsed: collapsedBinding(key))
                if !isCollapsed(key) {
                    ForEach(section.groups) { group in
                        GroupRow(group: group, store: store)
                    }
                }
            }
            if store.searchText.isEmpty && !StartupItemsView.visibleItems(in: store).isEmpty {
                StartupItemsView(store: store, isCollapsed: collapsedBinding("startup"))
            }
            if !store.recentlyStopped.isEmpty && store.searchText.isEmpty {
                RecentlyStoppedView(store: store, isCollapsed: collapsedBinding("stopped"))
            }
        }
        .padding(.horizontal, Theme.listInset)
        .padding(.top, 2)
        .padding(.bottom, 8)
    }

    /// Wraps content in a ScrollView whose height follows the content up to `Theme.maxListHeight`, so the
    /// MenuBarExtra window hugs short lists and scrolls long ones. Snapshot mode renders everything.
    @ViewBuilder
    private func scrollable<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        if snapshotMode {
            content()
        } else {
            ScrollView(.vertical) {
                content()
                    .background {
                        GeometryReader { proxy in
                            Color.clear.preference(key: ContentHeightKey.self, value: proxy.size.height)
                        }
                    }
            }
            .scrollBounceBehavior(.basedOnSize)
            .frame(height: min(max(listContentHeight, 60), Theme.maxListHeight))
            .onPreferenceChange(ContentHeightKey.self) { height in
                if abs(height - listContentHeight) > 0.5 { listContentHeight = height }
            }
        }
    }

    // MARK: Section collapse state

    private var collapsedSections: Set<String> {
        // Snapshots always show everything.
        guard !snapshotMode else { return [] }
        return Set(collapsedSectionsStorage.split(separator: ",").map(String.init))
    }

    private func isCollapsed(_ key: String) -> Bool { collapsedSections.contains(key) }

    private func collapsedBinding(_ key: String) -> Binding<Bool> {
        Binding(
            get: { isCollapsed(key) },
            set: { collapsed in
                var keys = collapsedSections
                if collapsed { keys.insert(key) } else { keys.remove(key) }
                collapsedSectionsStorage = keys.sorted().joined(separator: ",")
            })
    }

    // MARK: Keyboard

    /// Invisible buttons that own the panel's shortcuts (⌘R, ⌘F, ⌘,, ⌘Q) regardless of what is on screen.
    private var keyboardShortcuts: some View {
        ZStack {
            Button("Refresh") { store.refreshNow() }
                .keyboardShortcut("r", modifiers: .command)
            Button("Find") {
                if showingSettings {
                    closeSettings()
                    // The search field only exists once the list is back on screen; focus it on the next turn.
                    Task { @MainActor in isSearchFocused = true }
                } else {
                    isSearchFocused = true
                }
            }
            .keyboardShortcut("f", modifiers: .command)
            Button("Settings") { showingSettings.toggle() }
                .keyboardShortcut(",", modifiers: .command)
            Button("Quit PortPilot") { store.quit() }
                .keyboardShortcut("q", modifiers: .command)
        }
        .buttonStyle(.plain)
        .opacity(0)
        .frame(width: 0, height: 0)
        .accessibilityHidden(true)
    }

    /// Esc: leave Settings, then clear the search; otherwise let the window handle it (closes the panel).
    private var exitCommand: (() -> Void)? {
        if showingSettings { return { closeSettings() } }
        if !store.searchText.isEmpty { return { store.searchText = "" } }
        return nil
    }

    private func closeSettings() {
        showingSettings = false
    }

    private func panelVisibilityChanged(_ visible: Bool) {
        guard store.isPanelVisible != visible else { return }
        store.isPanelVisible = visible
        // Fresh numbers the moment the panel opens instead of waiting for the next tick.
        if visible { store.refreshNow() }
    }
}

private struct ContentHeightKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

/// 0.5 pt separator that adapts to light/dark.
private struct Hairline: View {
    var body: some View {
        Rectangle()
            .fill(Theme.hairline)
            .frame(height: 0.5)
    }
}

// MARK: - Header

private struct PanelHeader: View {
    let store: AppStore
    @Binding var showingSettings: Bool

    @State private var refreshRotation: Double = 0

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            AppGlyph(size: 28)

            VStack(alignment: .leading, spacing: 1) {
                HStack(alignment: .firstTextBaseline, spacing: 7) {
                    Text("PortPilot")
                        .font(.system(size: 13.5, weight: .semibold))
                    UpdatedText(lastUpdated: store.lastUpdated)
                        .font(.system(size: 10.5).monospacedDigit())
                        .foregroundStyle(.tertiary)
                        .fixedSize()
                }
                Text(summary)
                    .font(.system(size: 11).monospacedDigit())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }

            Spacer(minLength: 4)

            IconButton(systemImage: "arrow.clockwise", label: "Refresh", help: "Refresh now (⌘R)") {
                withAnimation(.easeInOut(duration: 0.6)) { refreshRotation += 360 }
                store.refreshNow()
            }
            .rotationEffect(.degrees(refreshRotation))
            .task(id: store.isScanning) { await spinWhileScanning() }

            IconButton(systemImage: "gearshape", label: showingSettings ? "Close Settings" : "Settings",
                       help: "Settings (⌘,)", isActive: showingSettings) {
                showingSettings.toggle()
            }
        }
        .padding(.leading, 14)
        .padding(.trailing, 10)
        .padding(.top, 12)
        .padding(.bottom, 10)
    }

    /// "7 ports · 4 projects · 1.2 GB · 6% CPU" for projects + background services.
    private var summary: String {
        let devGroups = store.snapshot.groups.filter { $0.category == .project || $0.category == .service }
        let portCount = Set(devGroups.flatMap(\.ports)).count
        guard portCount > 0 else { return store.lastUpdated == nil ? "Scanning…" : "No dev ports open" }
        let projectCount = devGroups.filter { $0.category == .project }.count
        let usage = store.devUsage
        var parts = [Self.plural(portCount, "port")]
        if projectCount > 0 { parts.append(Self.plural(projectCount, "project")) }
        parts.append(Format.bytes(usage.memoryBytes))
        parts.append("\(Format.cpu(usage.cpuPercent)) CPU")
        return parts.joined(separator: " · ")
    }

    private static func plural(_ count: Int, _ noun: String) -> String {
        "\(count) \(noun)\(count == 1 ? "" : "s")"
    }

    /// Scans take a few ms; only spin when one is visibly slow so the icon doesn't twitch every tick.
    private func spinWhileScanning() async {
        guard store.isScanning else { return }
        try? await Task.sleep(for: .milliseconds(250))
        while !Task.isCancelled && store.isScanning {
            withAnimation(.linear(duration: 0.8)) { refreshRotation += 360 }
            try? await Task.sleep(for: .milliseconds(800))
        }
    }
}

/// "Updated 2s ago", ticking every second on its own.
private struct UpdatedText: View {
    let lastUpdated: Date?

    var body: some View {
        if let lastUpdated {
            TimelineView(.periodic(from: Date(), by: 1)) { context in
                let elapsed = max(0, context.date.timeIntervalSince(lastUpdated))
                Text(elapsed < 1.5 ? "Updated just now" : "Updated \(Format.uptime(since: lastUpdated, now: context.date)) ago")
            }
        } else {
            Text("Not updated yet")
        }
    }
}

// MARK: - Search

private struct SearchField: View {
    @Binding var text: String
    var isFocused: FocusState<Bool>.Binding

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            TextField("Search ports, projects, paths, commands", text: $text)
                .textFieldStyle(.plain)
                .font(.system(size: 12.5))
                .focused(isFocused)
                .accessibilityLabel("Search")
            if text.isEmpty {
                Text(verbatim: "⌘F")
                    .font(.system(size: 10.5, weight: .medium))
                    .foregroundStyle(.tertiary)
                    .accessibilityHidden(true)
            } else {
                Button {
                    text = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 12))
                        .foregroundStyle(.tertiary)
                }
                .buttonStyle(.plain)
                .help("Clear search (Esc)")
                .accessibilityLabel("Clear search")
            }
        }
        .padding(.horizontal, 9)
        .frame(height: 28)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.primary.opacity(0.06)))
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(isFocused.wrappedValue ? Color.accentColor.opacity(0.55) : Theme.hairline,
                              lineWidth: isFocused.wrappedValue ? 1 : 0.5))
    }
}

// MARK: - Banner

private struct BannerView: View {
    let banner: Banner
    let store: AppStore

    var body: some View {
        HStack(alignment: .center, spacing: 8) {
            Image(systemName: symbol)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(tint)
                .accessibilityHidden(true)
            Text(banner.message)
                .font(.system(size: 12))
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
            if banner.action != nil, let title = banner.actionTitle {
                Button(title) { store.performBannerAction(banner) }
                    .buttonStyle(HoverButtonStyle(padding: EdgeInsets(top: 3, leading: 8, bottom: 3, trailing: 8),
                                                  hoverTint: tint, isEmphasized: true))
                    .font(.system(size: 11.5, weight: .semibold))
                    .fixedSize()
            }
            IconButton(systemImage: "xmark", label: "Dismiss", size: 10, weight: .bold) {
                store.dismissBanner()
            }
        }
        .padding(.leading, 10)
        .padding(.trailing, 5)
        .padding(.vertical, 6)
        .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(tint.opacity(0.12)))
        .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous).strokeBorder(tint.opacity(0.25), lineWidth: 0.5))
        .accessibilityElement(children: .contain)
    }

    private var tint: Color {
        switch banner.style {
        case .info: return .blue
        case .success: return .green
        case .warning: return .orange
        case .error: return .red
        }
    }

    private var symbol: String {
        switch banner.style {
        case .info: return "info.circle.fill"
        case .success: return "checkmark.circle.fill"
        case .warning: return "exclamationmark.triangle.fill"
        case .error: return "xmark.octagon.fill"
        }
    }
}

// MARK: - Empty state

private struct EmptyStateView: View {
    let searchText: String
    let hiddenCount: Int

    var body: some View {
        VStack(spacing: 6) {
            Image(systemName: searchText.isEmpty ? "antenna.radiowaves.left.and.right.slash" : "magnifyingglass")
                .font(.system(size: 26, weight: .light))
                .foregroundStyle(.tertiary)
                .padding(.bottom, 6)
                .accessibilityHidden(true)
            Text(searchText.isEmpty ? "No dev servers running" : "No matches")
                .font(.system(size: 13.5, weight: .semibold))
            Text(message)
                .font(.system(size: 11.5))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 40)
        .padding(.top, 30)
        .padding(.bottom, 26)
    }

    private var message: String {
        if !searchText.isEmpty {
            return "Nothing listening matches “\(searchText)”. Search by port, project, path or command."
        }
        var text = "Start a project and its ports show up here within a few seconds."
        if hiddenCount > 0 {
            text += " \(hiddenCount) app or system \(hiddenCount == 1 ? "item is" : "items are") hidden."
        }
        return text
    }
}

// MARK: - Footer

private struct PanelFooter: View {
    @Bindable var store: AppStore

    var body: some View {
        HStack(spacing: 6) {
            let projectCount = store.snapshot.groups.filter { $0.category == .project }.count
            if projectCount > 0 {
                ConfirmButton(title: "Stop All Projects",
                              confirmTitle: projectCount == 1 ? "Stop 1 Project?" : "Stop \(projectCount) Projects?",
                              systemImage: "stop.circle",
                              foreground: AnyShapeStyle(.secondary)) {
                    store.stopAllProjects()
                }
            }

            Spacer(minLength: 4)

            if store.hiddenCount > 0 && store.searchText.isEmpty {
                hiddenMenu
            }

            Spacer(minLength: 4)

            Button {
                store.quit()
            } label: {
                HStack(spacing: 5) {
                    Text("Quit")
                    Text(verbatim: "⌘Q").foregroundStyle(.tertiary)
                }
                .font(.system(size: 12, weight: .medium))
            }
            .buttonStyle(HoverButtonStyle(foreground: AnyShapeStyle(.secondary)))
            .help("Quit PortPilot (⌘Q)")
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
    }

    private var hiddenMenu: some View {
        Menu {
            Toggle("Show Apps", isOn: $store.settings.showApps)
            Toggle("Show System", isOn: $store.settings.showSystem)
            let ignored = store.settings.ignoredGroupIDs.count + store.settings.ignoredPorts.count
            if ignored > 0 {
                Divider()
                Button("Unhide \(ignored) Hidden \(ignored == 1 ? "Item" : "Items")") { store.unignoreAll() }
            }
        } label: {
            HStack(spacing: 4) {
                Image(systemName: "eye.slash")
                    .font(.system(size: 10.5, weight: .medium))
                Text(verbatim: "\(store.hiddenCount) hidden")
            }
            .font(.system(size: 12, weight: .medium))
        }
        .menuStyle(.button)
        .buttonStyle(HoverButtonStyle(foreground: AnyShapeStyle(.secondary)))
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Show apps, system processes or items you hid")
        .accessibilityLabel("\(store.hiddenCount) hidden items")
    }
}
