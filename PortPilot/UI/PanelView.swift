import AppKit
import SwiftUI

/// The menu bar panel: header, search, sectioned list (or Settings in place), footer, and a banner that floats
/// over the bottom of the list.
///
/// MenuBarExtra keeps this view alive while the panel is closed (even before it is first opened). So while the
/// panel is hidden the list (or Settings) is replaced by an empty frame of the same height and the header clock
/// stops ticking: nothing heavy stays in the view graph, and no scan or clock tick re-lays out a window nobody
/// sees. The list is rebuilt the moment the panel opens (`WindowVisibilityReader` reports it on key, before the
/// first frame).
///
/// `snapshotMode` renders the full height without a ScrollView, with an opaque background and without
/// window observers, so `SnapshotRenderer` can draw it offscreen; it always renders the list.
struct PanelView: View {
    @Bindable var store: AppStore
    let snapshotMode: Bool

    @State private var showingSettings: Bool
    /// About, shown over the list or Settings (Done returns to whichever was showing).
    @State private var showingAbout: Bool
    @State private var listContentHeight: CGFloat = 320
    @State private var bannerHeight: CGFloat = 0
    @State private var bannerHold = BannerHold()
    @State private var bannerReleaseTask: Task<Void, Never>?
    @FocusState private var isSearchFocused: Bool
    /// Comma-separated keys of collapsed sections (category raw values, "startup", "stopped").
    @AppStorage("PortPilot.collapsedSections") private var collapsedSectionsStorage = "startup"

    init(store: AppStore, snapshotMode: Bool = false, initiallyShowingSettings: Bool = false,
         initiallyShowingAbout: Bool = false) {
        self.store = store
        self.snapshotMode = snapshotMode
        _showingSettings = State(initialValue: initiallyShowingSettings)
        _showingAbout = State(initialValue: initiallyShowingAbout)
    }

    /// True when the list should exist: on screen, or rendering a snapshot.
    private var isLive: Bool { snapshotMode || store.isPanelVisible }
    /// AppStore's banner, or the one the pointer is resting on after AppStore auto-dismissed it.
    private var shownBanner: Banner? { bannerHold.shown(current: store.banner) }

    var body: some View {
        VStack(spacing: 0) {
            PanelHeader(store: store, showingSettings: $showingSettings, showingAbout: $showingAbout,
                        isOnScreen: store.isPanelVisible && !snapshotMode)

            if showingAbout {
                Hairline()
                panelBody {
                    AboutView(store: store) { showingAbout = false }
                }
            } else if showingSettings {
                Hairline()
                panelBody {
                    SettingsView(store: store, onShowAbout: { showingAbout = true }) { closeSettings() }
                }
            } else {
                SearchField(text: $store.searchText, isFocused: $isSearchFocused)
                    .padding(.horizontal, 12)
                    .padding(.bottom, 8)

                Hairline()
                panelBody { listContent }
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
        .animation(snapshotMode ? nil : .snappy(duration: 0.22), value: shownBanner)
        .animation(snapshotMode ? nil : .snappy(duration: 0.2), value: showingSettings)
        .animation(snapshotMode ? nil : .snappy(duration: 0.2), value: showingAbout)
        .onChange(of: store.banner) { _, banner in bannerHold.storeBannerChanged(to: banner) }
        .onExitCommand(perform: exitCommand)
        .onAppear {
            // Polling normally starts from the menu bar label at launch; this is an idempotent fallback.
            if !snapshotMode { store.start() }
        }
    }

    // MARK: Body (list or Settings)

    /// The scrolling list or Settings with the banner floating over its bottom edge, so a banner appearing or
    /// expiring never moves the rows under the cursor. While the panel is hidden: an empty frame of the same
    /// height (keeps the window size, so the next opening doesn't jump).
    @ViewBuilder
    private func panelBody<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        if isLive {
            scrollable(content)
                .overlay(alignment: .bottom) { bannerOverlay }
                .onPreferenceChange(BannerHeightKey.self) { height in
                    if abs(height - bannerHeight) > 0.5 { bannerHeight = height }
                }
        } else {
            Color.clear
                .frame(height: viewportHeight)
                .accessibilityHidden(true)
        }
    }

    // MARK: List

    private var listContent: some View {
        VStack(alignment: .leading, spacing: 2) {
            PanelNotices(store: store)
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
            // Tools whose ports closed while their processes kept running (collapse key "stillRunning").
            if store.searchText.isEmpty && !store.stillRunning.isEmpty {
                StillRunningView(store: store, isCollapsed: collapsedBinding("stillRunning"))
            }
            let trailing = TrailingSection.visible(searchText: store.searchText,
                                                   hasRecentlyStopped: !store.recentlyStopped.isEmpty,
                                                   hasStartupItems: !StartupItemsView.visibleItems(in: store).isEmpty)
            ForEach(trailing, id: \.self) { section in
                switch section {
                case .recentlyStopped:
                    RecentlyStoppedView(store: store, isCollapsed: collapsedBinding("stopped"))
                case .startupItems:
                    StartupItemsView(store: store, isCollapsed: collapsedBinding("startup"))
                }
            }
        }
        .padding(.horizontal, Theme.listInset)
        .padding(.top, 2)
        .padding(.bottom, 8)
    }

    /// Height of the scrolling area: follows the content, up to `Theme.maxListHeight`.
    private var viewportHeight: CGFloat {
        min(max(listContentHeight, 60), Theme.maxListHeight)
    }

    /// Extra scrollable space under the content while a banner covers the bottom of the list, so the last rows
    /// can still be scrolled into view.
    private var bannerInset: CGFloat {
        shownBanner == nil ? 0 : bannerHeight
    }

    /// Wraps content in a ScrollView whose height follows the content up to `Theme.maxListHeight`, so the
    /// MenuBarExtra window hugs short lists and scrolls long ones. Snapshot mode renders everything.
    @ViewBuilder
    private func scrollable<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        if snapshotMode {
            content()
                .padding(.bottom, bannerInset)
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
            .contentMargins(.bottom, bannerInset, for: .scrollContent)
            .frame(height: viewportHeight)
            .onPreferenceChange(ContentHeightKey.self) { height in
                if abs(height - listContentHeight) > 0.5 { listContentHeight = height }
            }
        }
    }

    // MARK: Banner

    @ViewBuilder
    private var bannerOverlay: some View {
        if let banner = shownBanner {
            BannerView(banner: banner,
                       onAction: { performBannerAction(banner) },
                       onDismiss: dismissBanner)
                .padding(.horizontal, 10)
                .padding(.bottom, 8)
                .background {
                    GeometryReader { proxy in
                        Color.clear.preference(key: BannerHeightKey.self, value: proxy.size.height)
                    }
                }
                .onHover(perform: bannerHoverChanged)
                .transition(.move(edge: .bottom).combined(with: .opacity))
        }
    }

    private func performBannerAction(_ banner: Banner) {
        releaseBanner()
        store.performBannerAction(banner)
    }

    private func dismissBanner() {
        releaseBanner()
        store.dismissBanner()
    }

    private func releaseBanner() {
        bannerReleaseTask?.cancel()
        bannerReleaseTask = nil
        bannerHold.release()
    }

    /// Holds the banner while the pointer rests on it; lets it go shortly after the pointer leaves.
    private func bannerHoverChanged(_ hovering: Bool) {
        bannerReleaseTask?.cancel()
        bannerReleaseTask = nil
        if hovering {
            bannerHold.pointerEntered(current: store.banner)
        } else {
            bannerHold.pointerExited()
            bannerReleaseTask = Task { @MainActor in
                try? await Task.sleep(for: .seconds(BannerHold.lingerAfterPointerLeaves))
                guard !Task.isCancelled else { return }
                bannerHold.releaseIfPointerOutside()
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
                if showingSettings || showingAbout {
                    closeSettings()
                    // The search field only exists once the list is back on screen; focus it on the next turn.
                    Task { @MainActor in isSearchFocused = true }
                } else {
                    isSearchFocused = true
                }
            }
            .keyboardShortcut("f", modifiers: .command)
            Button("Settings") { PanelPages.toggleSettings(settings: &showingSettings, about: &showingAbout) }
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
        if showingAbout { return { showingAbout = false } }
        if showingSettings { return { closeSettings() } }
        if !store.searchText.isEmpty { return { store.searchText = "" } }
        return nil
    }

    private func closeSettings() {
        showingSettings = false
        showingAbout = false
    }

    private func panelVisibilityChanged(_ visible: Bool) {
        guard store.isPanelVisible != visible else { return }
        if !visible { releaseBanner() }
        store.isPanelVisible = visible
        // Fresh numbers the moment the panel opens instead of waiting for the next tick.
        if visible { store.refreshNow() }
    }
}

/// Which page the panel shows in place of the list. Pure, unit tested.
enum PanelPages {
    /// The gear and ⌘,: from About go to Settings; otherwise toggle Settings.
    static func toggleSettings(settings: inout Bool, about: inout Bool) {
        if about {
            about = false
            settings = true
        } else {
            settings.toggle()
        }
    }
}

/// Sections shown below the live groups, in display order. Recently Stopped comes first so Relaunch stays near
/// the top even when the long Startup Items list is expanded. Both are hidden while searching.
enum TrailingSection: CaseIterable, Hashable {
    case recentlyStopped
    case startupItems

    static func visible(searchText: String, hasRecentlyStopped: Bool, hasStartupItems: Bool) -> [TrailingSection] {
        guard searchText.isEmpty else { return [] }
        return allCases.filter { section in
            switch section {
            case .recentlyStopped: return hasRecentlyStopped
            case .startupItems: return hasStartupItems
            }
        }
    }
}

/// Keeps a banner on screen while the pointer rests on it, even after AppStore's auto-dismiss timer cleared it,
/// so a message being read (or its button being aimed at) never vanishes under the cursor. Pure, unit tested.
struct BannerHold: Equatable {
    /// How long a held banner stays after the pointer leaves it.
    static let lingerAfterPointerLeaves: Double = 1.5

    private(set) var held: Banner?
    private(set) var isPointerInside = false

    /// AppStore's banner wins; the held one only fills in once AppStore has cleared its own.
    func shown(current: Banner?) -> Banner? {
        current ?? held
    }

    mutating func pointerEntered(current: Banner?) {
        isPointerInside = true
        if let current { held = current }
    }

    mutating func pointerExited() {
        isPointerInside = false
    }

    /// A newer banner replaces the held one; a cleared banner stays held only while the pointer is on it.
    mutating func storeBannerChanged(to current: Banner?) {
        if let current {
            held = isPointerInside ? current : nil
        } else if !isPointerInside {
            held = nil
        }
    }

    mutating func releaseIfPointerOutside() {
        if !isPointerInside { held = nil }
    }

    /// Closed or acted on: let go immediately.
    mutating func release() {
        held = nil
        isPointerInside = false
    }
}

private struct ContentHeightKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

private struct BannerHeightKey: PreferenceKey {
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
    @Binding var showingAbout: Bool
    /// The panel is open on screen (false while hidden and in snapshots): only then does anything tick or spin.
    let isOnScreen: Bool

    @State private var refreshRotation: Double = 0

    var body: some View {
        HStack(alignment: .center, spacing: 9) {
            HeaderGlyphButton(updates: store.updates) { showingAbout.toggle() }

            VStack(alignment: .leading, spacing: 1) {
                HStack(alignment: .firstTextBaseline, spacing: 7) {
                    Text("PortPilot")
                        .font(.system(size: 13.5, weight: .semibold))
                    // Fixed width: the once-a-second text change must never change the panel's size (a size
                    // change re-lays out every row, which was most of PortPilot's idle CPU).
                    UpdatedText(lastUpdated: store.lastUpdated, ticks: isOnScreen)
                        .font(.system(size: 10.5).monospacedDigit())
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .frame(width: PanelText.updatedLabelWidth, alignment: .leading)
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
            .task(id: isOnScreen && store.isScanning) { await spinWhileScanning() }

            let settingsActive = showingSettings && !showingAbout
            IconButton(systemImage: "gearshape", label: settingsActive ? "Close Settings" : "Settings",
                       help: "Settings (⌘,)", isActive: settingsActive) {
                PanelPages.toggleSettings(settings: &showingSettings, about: &showingAbout)
            }
        }
        .padding(.leading, 13)
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
    /// Never while the panel is hidden: an animation there would redraw a window nobody sees.
    private func spinWhileScanning() async {
        guard isOnScreen, store.isScanning else { return }
        try? await Task.sleep(for: .milliseconds(250))
        while !Task.isCancelled && isOnScreen && store.isScanning {
            withAnimation(.linear(duration: 0.8)) { refreshRotation += 360 }
            try? await Task.sleep(for: .milliseconds(800))
        }
    }
}

/// Header texts, kept pure for tests.
enum PanelText {
    /// Fixed width of the "Updated …" label; fits the longest label ("Updated 99d 23h ago") at 10.5 pt.
    static let updatedLabelWidth: CGFloat = 130

    /// "Updated just now", "Updated 12s ago", "Updated 3h 4m ago", "Not updated yet".
    static func updatedLabel(lastUpdated: Date?, now: Date) -> String {
        guard let lastUpdated else { return "Not updated yet" }
        let elapsed = max(0, now.timeIntervalSince(lastUpdated))
        return elapsed < 1.5 ? "Updated just now" : "Updated \(Format.uptime(since: lastUpdated, now: now)) ago"
    }
}

/// "Updated 2s ago": ticks every second on its own while the panel is on screen; a static label otherwise
/// (nobody sees it, and a ticking view keeps the hidden window busy).
private struct UpdatedText: View {
    let lastUpdated: Date?
    let ticks: Bool

    var body: some View {
        if ticks, lastUpdated != nil {
            TimelineView(.periodic(from: Date(), by: 1)) { context in
                Text(PanelText.updatedLabel(lastUpdated: lastUpdated, now: context.date))
            }
        } else {
            Text(PanelText.updatedLabel(lastUpdated: lastUpdated, now: Date()))
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

/// Floating banner card: opaque base + style tint, since it sits on top of the list.
private struct BannerView: View {
    let banner: Banner
    let onAction: () -> Void
    let onDismiss: () -> Void

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 9, style: .continuous)
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
                Button(title, action: onAction)
                    .buttonStyle(HoverButtonStyle(padding: EdgeInsets(top: 3, leading: 8, bottom: 3, trailing: 8),
                                                  hoverTint: tint, isEmphasized: true))
                    .font(.system(size: 11.5, weight: .semibold))
                    .fixedSize()
            }
            IconButton(systemImage: "xmark", label: "Dismiss", size: 10, weight: .bold, action: onDismiss)
        }
        .padding(.leading, 10)
        .padding(.trailing, 5)
        .padding(.vertical, 6)
        .background {
            shape.fill(Theme.floatingBackground)
            shape.fill(tint.opacity(0.12))
        }
        .overlay(shape.strokeBorder(tint.opacity(0.3), lineWidth: 0.5))
        .shadow(color: .black.opacity(0.14), radius: 6, y: 2)
        .contentShape(shape)
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
            // The same list Stop All stops (hidden projects excluded), so the count always matches.
            let projects = store.stoppableProjects
            if !projects.isEmpty {
                ConfirmButton(title: "Stop All Projects",
                              confirmTitle: projects.count == 1 ? "Stop 1 Project?" : "Stop \(projects.count) Projects?",
                              systemImage: "stop.circle",
                              foreground: AnyShapeStyle(.secondary),
                              armedHelp: StopReport.stopAllConfirmHelp(projects)) {
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
