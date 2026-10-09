import AppKit
import SwiftUI

// MARK: - Theme

/// Shared metrics and colours so every row lines up and accents stay consistent.
/// Accent colours are used sparingly: orange = auto-restart, red = destructive (hover only),
/// purple/blue = origin badges, yellow = heavy resource usage.
enum Theme {
    static let panelWidth: CGFloat = 440
    /// The scrolling list never grows beyond this; header + search + footer add ~130 pt (panel ≈ 620 pt max).
    static let maxListHeight: CGFloat = 490

    /// Panel edge → row background.
    static let listInset: CGFloat = 8
    /// Row background → row content.
    static let rowPadding: CGFloat = 8
    static let chevronWidth: CGFloat = 10
    static let iconSize: CGFloat = 26
    /// Leading offset of a group row's text column (chevron + icon + gaps); nested content aligns to it.
    static let textColumnInset: CGFloat = chevronWidth + 6 + iconSize + 9

    static let autoRestart = Color.orange
    static let destructive = Color.red
    static let agentOrigin = Color.purple
    static let toolOrigin = Color.blue
    /// Yellow that stays legible on light backgrounds (systemYellow is too pale on white).
    static let heavy = Color(nsColor: NSColor(name: NSColor.Name("PortPilot.heavy")) { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor.systemYellow
            : NSColor(srgbRed: 0.72, green: 0.52, blue: 0.0, alpha: 1)
    })

    static let hoverFill = Color.primary.opacity(0.06)
    static let pressedFill = Color.primary.opacity(0.11)
    static let chipFill = Color.primary.opacity(0.07)
    static let cardFill = Color.primary.opacity(0.045)
    static let hairline = Color.primary.opacity(0.09)
    /// Opaque stand-in for the menu material, used when rendering snapshots offscreen.
    static let snapshotBackground = Color(nsColor: .windowBackgroundColor)
    /// Opaque base for things that float over the list (the banner).
    static let floatingBackground = Color(nsColor: .windowBackgroundColor)
}

extension Font {
    static let rowTitle = Font.system(size: 13, weight: .semibold)
    static let rowBody = Font.system(size: 12)
    static let rowCaption = Font.system(size: 11)
    static let badge = Font.system(size: 10.5, weight: .medium)
    static let metric = Font.system(size: 11).monospacedDigit()
    static let command = Font.system(size: 10.5, design: .monospaced)
}

// MARK: - Buttons

/// Plain button with a rounded highlight on hover/press, like the toolbar buttons of first-party utilities.
struct HoverButtonStyle: ButtonStyle {
    var cornerRadius: CGFloat = 6
    var padding = EdgeInsets(top: 3, leading: 7, bottom: 3, trailing: 7)
    /// Resting foreground; nil inherits the surrounding style.
    var foreground: AnyShapeStyle? = nil
    /// Foreground + tinted highlight while hovered (e.g. red for destructive buttons). nil = neutral highlight.
    var hoverTint: Color? = nil
    /// Keeps the tinted highlight on without hovering (armed confirm button, active toggle).
    var isEmphasized = false

    func makeBody(configuration: Configuration) -> some View {
        HoverButtonBody(configuration: configuration, style: self)
    }

    private struct HoverButtonBody: View {
        let configuration: ButtonStyleConfiguration
        let style: HoverButtonStyle
        @State private var isHovering = false
        @Environment(\.isEnabled) private var isEnabled

        var body: some View {
            let shape = RoundedRectangle(cornerRadius: style.cornerRadius, style: .continuous)
            configuration.label
                .padding(style.padding)
                .modifier(OptionalForeground(style: currentForeground))
                .background(shape.fill(background))
                .contentShape(shape)
                .opacity(isEnabled ? 1 : 0.4)
                .onHover { isHovering = $0 }
                .animation(.easeOut(duration: 0.12), value: isHovering)
        }

        private var isHighlighted: Bool { isEnabled && (isHovering || configuration.isPressed) }

        private var currentForeground: AnyShapeStyle? {
            if let tint = style.hoverTint, isHighlighted || style.isEmphasized { return AnyShapeStyle(tint) }
            return style.foreground
        }

        private var background: Color {
            if let tint = style.hoverTint, style.isEmphasized {
                return tint.opacity(configuration.isPressed ? 0.26 : isHovering ? 0.2 : 0.14)
            }
            if style.isEmphasized { return configuration.isPressed ? Theme.pressedFill : Color.primary.opacity(0.09) }
            guard isHighlighted else { return .clear }
            if let tint = style.hoverTint { return tint.opacity(configuration.isPressed ? 0.2 : 0.12) }
            return configuration.isPressed ? Theme.pressedFill : Theme.hoverFill
        }
    }
}

/// Applies a foreground style only when one is given, so labels keep their inherited colour otherwise.
private struct OptionalForeground: ViewModifier {
    let style: AnyShapeStyle?

    func body(content: Content) -> some View {
        if let style { content.foregroundStyle(style) } else { content }
    }
}

/// Square icon-only button with tooltip + accessibility label (icon buttons must always be labelled).
struct IconButton: View {
    let systemImage: String
    let label: String
    var help: String? = nil
    var size: CGFloat = 13
    var weight: Font.Weight = .medium
    var foreground: AnyShapeStyle? = AnyShapeStyle(.secondary)
    var hoverTint: Color? = nil
    var isActive = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: size, weight: weight))
                .frame(width: 18, height: 18)
        }
        .buttonStyle(HoverButtonStyle(
            cornerRadius: 6,
            padding: EdgeInsets(top: 2, leading: 2, bottom: 2, trailing: 2),
            foreground: isActive ? AnyShapeStyle(.primary) : foreground,
            hoverTint: hoverTint,
            isEmphasized: isActive))
        .help(help ?? label)
        .accessibilityLabel(label)
    }
}

/// Click logic of `ConfirmButton`, kept free of UI so it can be unit tested.
///
/// The first click arms. A later click confirms only once the system double-click interval has passed since
/// arming, and never as the second click of a double-click: SwiftUI fires a Button on every mouse-up, so without
/// this guard a habitual double-click would arm *and* confirm before the "Confirm" label is even drawn.
struct ConfirmGate: Equatable {
    enum Outcome: Equatable {
        case armed
        /// Too soon after arming (or part of a double-click): stays armed, nothing runs.
        case ignored
        case confirmed
    }

    private(set) var armedAt: Date?
    var isArmed: Bool { armedAt != nil }

    /// - Parameters:
    ///   - clickCount: click count of the mouse event behind this activation (1 for keyboard / VoiceOver).
    ///   - doubleClickInterval: `NSEvent.doubleClickInterval` in the app; injectable for tests.
    mutating func click(at now: Date, clickCount: Int = 1, doubleClickInterval: TimeInterval) -> Outcome {
        guard let armedAt else {
            self.armedAt = now
            return .armed
        }
        if clickCount > 1 || now.timeIntervalSince(armedAt) < doubleClickInterval {
            return .ignored
        }
        self.armedAt = nil
        return .confirmed
    }

    mutating func disarm() {
        armedAt = nil
    }

    /// Click count of the event being handled; 1 for anything that isn't a mouse click (asking a key event for
    /// its `clickCount` raises an exception).
    @MainActor
    static var currentClickCount: Int {
        guard let event = NSApp?.currentEvent else { return 1 }
        switch event.type {
        case .leftMouseDown, .leftMouseUp, .rightMouseDown, .rightMouseUp, .otherMouseDown, .otherMouseUp:
            return event.clickCount
        default:
            return 1
        }
    }
}

/// Inline two-step confirmation for destructive actions. Alerts and sheets would dismiss the
/// MenuBarExtra window, so the first click arms the button for `timeout` and a second click runs `action`
/// (see `ConfirmGate` for the double-click guard).
///
/// With an empty `title` and a `systemImage` it rests as an icon-only button that looks like `IconButton`
/// and expands to "! <confirmTitle>" while armed.
struct ConfirmButton: View {
    let title: String
    var confirmTitle = "Confirm"
    var systemImage: String? = nil
    var tint: Color = Theme.destructive
    /// Resting foreground; nil inherits (the armed state always uses `tint`).
    var foreground: AnyShapeStyle? = nil
    var timeout: Duration = .seconds(3)
    var font: Font = .system(size: 12, weight: .medium)
    /// Resting tooltip; defaults to `title`.
    var help: String? = nil
    /// Tooltip while armed: say what the second click will do.
    var armedHelp = "Click again to confirm"
    /// Resting VoiceOver label; defaults to `title` (required for icon-only buttons).
    var accessibilityName: String? = nil
    /// Point size of the resting icon of an icon-only button (matches `IconButton`'s `size`).
    var iconSize: CGFloat = 13
    let action: () -> Void

    @State private var gate = ConfirmGate()
    @State private var disarmTask: Task<Void, Never>?

    private var isArmed: Bool { gate.isArmed }
    private var isIconOnly: Bool { title.isEmpty && systemImage != nil }

    var body: some View {
        Button(action: handleClick) {
            if isIconOnly && !isArmed, let systemImage {
                Image(systemName: systemImage)
                    .font(.system(size: iconSize, weight: .medium))
                    .frame(width: 18, height: 18)
            } else {
                HStack(spacing: 5) {
                    if let systemImage {
                        Image(systemName: isArmed ? "exclamationmark.circle.fill" : systemImage)
                            .font(.system(size: 11.5, weight: .semibold))
                    }
                    Text(isArmed ? confirmTitle : title)
                        .lineLimit(1)
                }
                .font(font)
            }
        }
        .buttonStyle(HoverButtonStyle(
            padding: isIconOnly && !isArmed ? EdgeInsets(top: 2, leading: 2, bottom: 2, trailing: 2)
                                            : EdgeInsets(top: 3, leading: 7, bottom: 3, trailing: 7),
            foreground: foreground, hoverTint: tint, isEmphasized: isArmed))
        .help(isArmed ? armedHelp : (help ?? title))
        .accessibilityLabel(isArmed ? confirmTitle : (accessibilityName ?? title))
        .accessibilityHint(isArmed ? armedHelp : "Asks to confirm first")
        .onDisappear { disarm() }
    }

    private func handleClick() {
        var gate = self.gate
        let outcome = gate.click(at: Date(), clickCount: ConfirmGate.currentClickCount,
                                 doubleClickInterval: NSEvent.doubleClickInterval)
        switch outcome {
        case .armed:
            withAnimation(.easeOut(duration: 0.15)) { self.gate = gate }
            scheduleDisarm()
        case .ignored:
            break
        case .confirmed:
            disarm()
            action()
        }
    }

    private func scheduleDisarm() {
        disarmTask?.cancel()
        disarmTask = Task { @MainActor in
            try? await Task.sleep(for: timeout)
            guard !Task.isCancelled else { return }
            withAnimation(.easeOut(duration: 0.2)) { gate.disarm() }
        }
    }

    private func disarm() {
        disarmTask?.cancel()
        disarmTask = nil
        gate.disarm()
    }
}

// MARK: - Badges & chips

/// Small capsule label: frameworks, managers, origins, "Network".
struct Badge: View {
    let text: String
    var systemImage: String? = nil
    /// nil = neutral grey badge.
    var tint: Color? = nil

    var body: some View {
        HStack(spacing: 3) {
            if let systemImage {
                Image(systemName: systemImage)
                    .font(.system(size: 8.5, weight: .bold))
            }
            Text(text)
                .lineLimit(1)
        }
        .font(.badge)
        .foregroundStyle(tint.map { AnyShapeStyle($0) } ?? AnyShapeStyle(.secondary))
        .padding(.horizontal, 6)
        .padding(.vertical, 2)
        .background(Capsule(style: .continuous).fill(tint?.opacity(0.14) ?? Theme.chipFill))
        .fixedSize()
    }
}

/// Clickable ":PORT" chip → opens http://localhost:PORT. Context menu copies the URL or port.
struct PortChip: View {
    let port: UInt16
    var isExposed = false
    var compact = false
    let store: AppStore

    @State private var isHovering = false

    private var url: String { "http://localhost:\(port)" }

    var body: some View {
        Button {
            store.openInBrowser(port: port)
        } label: {
            Text(verbatim: ":\(port)")
                .font(.system(size: compact ? 10.5 : 11, weight: .semibold).monospacedDigit())
                .foregroundStyle(isHovering ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(.primary.opacity(0.85)))
                .padding(.horizontal, compact ? 5 : 6)
                .padding(.vertical, compact ? 1.5 : 2.5)
                .background(
                    RoundedRectangle(cornerRadius: 5, style: .continuous)
                        .fill(isHovering ? Color.accentColor.opacity(0.15) : Theme.chipFill))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .fixedSize()
        .onHover { isHovering = $0 }
        .help(isExposed ? "Open \(url) — listening on all interfaces (reachable from your network)" : "Open \(url)")
        .accessibilityLabel("Port \(String(port))")
        .accessibilityHint("Opens \(url) in your browser")
        .contextMenu {
            Button("Open in Browser") { store.openInBrowser(port: port) }
            Divider()
            Button("Copy URL") { store.copy(url) }
            Button("Copy Port") { store.copy(String(port)) }
        }
    }
}

/// A name followed by a secondary detail on one line, without ever drawing the detail as a clipped one-glyph
/// sliver: the full detail when both fit, else the full name plus a truncated detail of at least
/// `minDetailWidth`, else the name alone (truncated as the caller set up). Both views should be single-line.
struct NameAndDetail<Name: View, Detail: View>: View {
    var spacing: CGFloat = 5
    var minDetailWidth: CGFloat = 36
    var alignment: VerticalAlignment = .firstTextBaseline
    let name: Name
    let detail: Detail

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: alignment, spacing: spacing) {
                name.fixedSize()
                detail.fixedSize()
            }
            HStack(alignment: alignment, spacing: spacing) {
                name.fixedSize()
                detail.frame(minWidth: minDetailWidth, idealWidth: minDetailWidth, alignment: .leading)
            }
            name
        }
    }
}

/// How many port chips a row shows before the rest collapse into "+N". Pure, so it is unit tested.
enum PortChipOverflow {
    /// Chip slots per row: wide enough for the common 1–3 ports, small enough that a row never grows past the panel.
    static let defaultLimit = 3

    /// Up to `limit` ports show as chips; with more, the last slot becomes "+N"
    /// (e.g. limit 3: [a, b, c] → a b c, [a, b, c, d] → a b +2).
    static func split(_ ports: [UInt16], limit: Int = defaultLimit) -> (shown: [UInt16], hidden: [UInt16]) {
        let limit = max(1, limit)
        let shownCount = ports.count > limit ? limit - 1 : ports.count
        return (Array(ports.prefix(shownCount)), Array(ports.dropFirst(shownCount)))
    }

    /// ":3000  :3001" for tooltips.
    static func list(_ ports: [UInt16]) -> String {
        ports.map { ":\($0)" }.joined(separator: "  ")
    }
}

/// A row's port chips, capped by `PortChipOverflow` so any number of ports takes bounded width: the chips are
/// `.fixedSize()` (never squeezed), which is only safe because the count is capped.
struct CappedPortChips<Chip: View, Overflow: View>: View {
    let ports: [UInt16]
    var limit = PortChipOverflow.defaultLimit
    var spacing: CGFloat = 4
    @ViewBuilder let chip: (UInt16) -> Chip
    /// The "+N" element for the ports that didn't fit (receives them).
    @ViewBuilder let overflow: ([UInt16]) -> Overflow

    var body: some View {
        let split = PortChipOverflow.split(ports, limit: limit)
        HStack(spacing: spacing) {
            ForEach(split.shown, id: \.self) { port in
                chip(port)
            }
            if !split.hidden.isEmpty {
                overflow(split.hidden)
            }
        }
        .fixedSize()
    }
}

/// The "+N" chip face.
struct OverflowChipLabel: View {
    let count: Int
    var compact = false

    var body: some View {
        Text(verbatim: "+\(count)")
            .font(.system(size: compact ? 10.5 : 11, weight: .semibold).monospacedDigit())
            .foregroundStyle(.secondary)
            .padding(.horizontal, compact ? 4 : 5)
            .padding(.vertical, compact ? 1.5 : 2.5)
            .background(RoundedRectangle(cornerRadius: 5, style: .continuous).fill(Theme.chipFill))
            .contentShape(Rectangle())
    }
}

/// "+N" chip that opens a menu of the hidden ports, so every port stays one click from the browser.
struct HiddenPortsMenu: View {
    let ports: [UInt16]
    var compact = false
    let store: AppStore

    var body: some View {
        Menu {
            ForEach(ports, id: \.self) { port in
                Button("Open localhost:\(String(port))") { store.openInBrowser(port: port) }
            }
            Divider()
            Button(ports.count == 1 ? "Copy Port" : "Copy Ports") {
                store.copy(ports.map { String($0) }.joined(separator: " "))
            }
        } label: {
            OverflowChipLabel(count: ports.count, compact: compact)
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Also listening on " + PortChipOverflow.list(ports))
        .accessibilityLabel("\(ports.count) more \(ports.count == 1 ? "port" : "ports")")
    }
}

/// "3.2% · 412 MB" with monospaced digits. Turns into a yellow pill when a metric crosses its threshold.
struct UsagePill: View {
    let usage: ResourceUsage
    var cpuIsHeavy = false
    var memoryIsHeavy = false

    private var isHeavy: Bool { cpuIsHeavy || memoryIsHeavy }

    var body: some View {
        HStack(spacing: 4) {
            if isHeavy {
                Image(systemName: "flame.fill")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(Theme.heavy)
            }
            Text(Format.cpu(usage.cpuPercent))
                .foregroundStyle(cpuIsHeavy ? AnyShapeStyle(Theme.heavy) : AnyShapeStyle(.secondary))
            Text(verbatim: "·")
                .foregroundStyle(.tertiary)
            Text(Format.bytes(usage.memoryBytes))
                .foregroundStyle(memoryIsHeavy ? AnyShapeStyle(Theme.heavy) : AnyShapeStyle(.secondary))
        }
        .font(isHeavy ? .system(size: 11, weight: .semibold).monospacedDigit() : .metric)
        .lineLimit(1)
        .padding(.horizontal, isHeavy ? 6 : 0)
        .padding(.vertical, isHeavy ? 1.5 : 0)
        .background {
            if isHeavy { Capsule(style: .continuous).fill(Theme.heavy.opacity(0.16)) }
        }
        .fixedSize()
        .help(isHeavy ? "Heavy: CPU \(Format.cpu(usage.cpuPercent)) of one core, memory \(Format.bytes(usage.memoryBytes))"
                      : "CPU (% of one core) · memory, including child processes")
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("CPU \(Format.cpu(usage.cpuPercent)), memory \(Format.bytes(usage.memoryBytes))\(isHeavy ? ", heavy" : "")")
    }
}

/// Icon + title with a tight gap, for inline status labels ("↻ KeepAlive").
struct CompactLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 2.5) {
            configuration.icon
                .imageScale(.small)
            configuration.title
        }
    }
}

/// Coloured dot used for status (startup items).
struct StatusDot: View {
    let color: Color
    var isHollow = false

    var body: some View {
        Group {
            if isHollow {
                Circle().strokeBorder(color, lineWidth: 1.5)
            } else {
                Circle().fill(color)
                    .overlay(Circle().strokeBorder(Color.black.opacity(0.08), lineWidth: 0.5))
            }
        }
        .frame(width: 7, height: 7)
    }
}

/// Disclosure chevron that rotates when expanded.
struct DisclosureChevron: View {
    let isExpanded: Bool

    var body: some View {
        Image(systemName: "chevron.right")
            .font(.system(size: 9, weight: .bold))
            .foregroundStyle(.tertiary)
            .rotationEffect(.degrees(isExpanded ? 90 : 0))
    }
}

// MARK: - Section header

/// "PROJECTS 5 ›" — collapsible list section header with an optional trailing accessory (e.g. "Clear").
struct SectionHeader<Accessory: View>: View {
    let title: String
    var count: Int? = nil
    @Binding var isCollapsed: Bool
    @ViewBuilder var accessory: Accessory

    @State private var isHovering = false

    var body: some View {
        HStack(spacing: 6) {
            Button {
                withAnimation(.snappy(duration: 0.22)) { isCollapsed.toggle() }
            } label: {
                HStack(spacing: 5) {
                    Text(title.uppercased())
                        .font(.system(size: 10.5, weight: .semibold))
                        .tracking(0.5)
                        .foregroundStyle(.secondary)
                    if let count {
                        Text(verbatim: "\(count)")
                            .font(.system(size: 10, weight: .semibold).monospacedDigit())
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 0.5)
                            .background(Capsule().fill(Theme.chipFill))
                    }
                    Image(systemName: "chevron.down")
                        .font(.system(size: 8, weight: .bold))
                        .foregroundStyle(.tertiary)
                        .rotationEffect(.degrees(isCollapsed ? -90 : 0))
                        .opacity(isHovering || isCollapsed ? 1 : 0.6)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("\(title), \(count.map(String.init) ?? "")")
            .accessibilityValue(isCollapsed ? "Collapsed" : "Expanded")
            .accessibilityHint(isCollapsed ? "Shows this section" : "Hides this section")

            Spacer(minLength: 0)
            accessory
        }
        .frame(height: 22)
        .padding(.horizontal, Theme.rowPadding)
        .padding(.top, 8)
        .padding(.bottom, 2)
        .onHover { isHovering = $0 }
    }
}

extension SectionHeader where Accessory == EmptyView {
    init(title: String, count: Int? = nil, isCollapsed: Binding<Bool>) {
        self.init(title: title, count: count, isCollapsed: isCollapsed) { EmptyView() }
    }
}

// MARK: - Text helpers

enum DisplayText {
    /// Command line for display: home-directory paths shortened to "~/…" (tooltips keep the full text).
    static func command(_ commandLine: String) -> String {
        let home = Format.displayHome
        guard home.count > 1 else { return commandLine }
        return commandLine.replacingOccurrences(of: home + "/", with: "~/")
    }
}

// MARK: - Relative time

/// Self-updating relative time ("4m ago"). Ticks on its own so the rest of the panel doesn't re-render.
struct TimeAgoText: View {
    let date: Date
    var interval: TimeInterval = 1
    var format: (TimeInterval) -> String = TimeAgoText.defaultFormat

    var body: some View {
        TimelineView(.periodic(from: Date(), by: interval)) { context in
            Text(format(context.date.timeIntervalSince(date)))
        }
    }

    nonisolated static func defaultFormat(_ elapsed: TimeInterval) -> String {
        if elapsed < 5 { return "just now" }
        return Format.uptime(since: Date(timeIntervalSinceNow: -elapsed)) + " ago"
    }
}

// MARK: - Flow layout

/// Left-aligned wrapping layout for badge rows (wraps instead of clipping when a row is crowded).
struct FlowLayout: Layout {
    var spacing: CGFloat = 4
    var lineSpacing: CGFloat = 4

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        arrange(maxWidth: proposal.width ?? .infinity, subviews: subviews).size
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let arrangement = arrange(maxWidth: bounds.width, subviews: subviews)
        for (index, frame) in arrangement.frames.enumerated() {
            subviews[index].place(at: CGPoint(x: bounds.minX + frame.minX, y: bounds.minY + frame.minY),
                                  proposal: ProposedViewSize(frame.size))
        }
    }

    /// Greedy line breaking; items are vertically centred within their line.
    private func arrange(maxWidth: CGFloat, subviews: Subviews) -> (size: CGSize, frames: [CGRect]) {
        var frames: [CGRect] = []
        frames.reserveCapacity(subviews.count)
        var lineStart = 0
        var x: CGFloat = 0
        var y: CGFloat = 0
        var lineHeight: CGFloat = 0
        var usedWidth: CGFloat = 0

        func finishLine(upTo end: Int) {
            for i in lineStart..<end {
                frames[i].origin.y = y + (lineHeight - frames[i].height) / 2
            }
        }

        for (index, subview) in subviews.enumerated() {
            var size = subview.sizeThatFits(.unspecified)
            if maxWidth.isFinite { size.width = min(size.width, maxWidth) }
            if x > 0, x + size.width > maxWidth {
                finishLine(upTo: index)
                y += lineHeight + lineSpacing
                x = 0
                lineHeight = 0
                lineStart = index
            }
            frames.append(CGRect(x: x, y: y, width: size.width, height: size.height))
            x += size.width + spacing
            lineHeight = max(lineHeight, size.height)
            usedWidth = max(usedWidth, x - spacing)
        }
        finishLine(upTo: frames.count)
        let height = frames.isEmpty ? 0 : y + lineHeight
        return (CGSize(width: usedWidth, height: height), frames)
    }
}

// MARK: - App glyph & icons

/// The PortPilot mark used in the header and About section.
struct AppGlyph: View {
    var size: CGFloat = 28

    /// The app icon in miniature: the "PP" logo on a white continuous-corner tile.
    var body: some View {
        RoundedRectangle(cornerRadius: size * 0.27, style: .continuous)
            .fill(LinearGradient(colors: [.white, Color(red: 0.93, green: 0.94, blue: 0.96)],
                                 startPoint: .top, endPoint: .bottom))
            .overlay(
                Image("Logo")
                    .resizable()
                    .interpolation(.high)
                    .aspectRatio(contentMode: .fit)
                    .padding(size * 0.12))
            .overlay(
                RoundedRectangle(cornerRadius: size * 0.27, style: .continuous)
                    .strokeBorder(Color.black.opacity(0.10), lineWidth: 0.5))
            .shadow(color: .black.opacity(0.12), radius: 1, y: 0.5)
            .frame(width: size, height: size)
            .accessibilityHidden(true)
    }
}

/// Caches app bundle icons (NSWorkspace lookups hit the disk).
@MainActor
enum AppIconCache {
    private static var icons: [String: NSImage] = [:]
    private static var misses: Set<String> = []

    static func icon(forBundleAt path: String) -> NSImage? {
        if let cached = icons[path] { return cached }
        if misses.contains(path) { return nil }
        guard path.hasSuffix(".app"), FileManager.default.fileExists(atPath: path) else {
            misses.insert(path)
            return nil
        }
        let image = NSWorkspace.shared.icon(forFile: path)
        icons[path] = image
        return image
    }
}

/// Leading icon of a group row: the real app icon for apps, otherwise a tinted SF Symbol tile.
struct GroupIcon: View {
    let group: ListenerGroup

    var body: some View {
        Group {
            if group.category == .app, let path = group.path, let image = AppIconCache.icon(forBundleAt: path) {
                Image(nsImage: image)
                    .resizable()
                    .interpolation(.high)
                    .aspectRatio(contentMode: .fit)
                    .padding(-1.5) // app icons have transparent margins
            } else {
                let tint = Self.tint(for: group.category)
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(tint.opacity(0.15))
                    .overlay(
                        Image(systemName: Self.symbol(for: group))
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(tint))
            }
        }
        .frame(width: Theme.iconSize, height: Theme.iconSize)
        .accessibilityHidden(true)
    }

    static func tint(for category: ListenerCategory) -> Color {
        switch category {
        case .project: return .blue
        case .service: return .teal
        case .app: return .indigo
        case .system: return .gray
        }
    }

    /// Picks a symbol from the detected frameworks, falling back to the category.
    static func symbol(for group: ListenerGroup) -> String {
        let names = group.frameworks.map { $0.lowercased() }
        func has(_ needles: String...) -> Bool {
            names.contains { name in needles.contains { name.contains($0) } }
        }
        if has("postgres", "mysql", "mongo", "redis", "sqlite", "mariadb") { return "cylinder.split.1x2" }
        if has("cloudflared", "ngrok", "tailscale", "tunnel") { return "point.3.filled.connected.trianglepath.dotted" }
        if has("nginx", "caddy", "traefik") { return "arrow.triangle.branch" }
        if has("ollama") { return "brain" }
        if has("jupyter") { return "book.closed" }
        if has("docker") { return "shippingbox" }
        if has("vite", "next", "nuxt", "astro", "remix", "svelte", "webpack", "parcel", "storybook", "angular",
               "expo", "metro", "hugo", "jekyll") { return "macwindow" }
        if has("uvicorn", "gunicorn", "fastapi", "flask", "django", "express", "nest", "rails", "puma", "php",
               "laravel", "streamlit", "gradio", "spring", "java", ".net", "go", "rust", "bun", "deno", "http.server") {
            return "server.rack"
        }
        switch group.category {
        case .project: return "chevron.left.forwardslash.chevron.right"
        case .service: return "gearshape.2"
        case .app: return "app"
        case .system: return "gearshape"
        }
    }
}

// MARK: - Badge helpers

extension LaunchOrigin {
    /// Purple for AI agents, blue for IDEs/terminals, neutral for supervisors.
    var badgeTint: Color? {
        switch kind {
        case .claudeCode, .codex, .aiAgent: return Theme.agentOrigin
        case .ide, .terminal, .shell: return Theme.toolOrigin
        case .launchd, .pm2, .docker, .app, .unknown: return nil
        }
    }

    var badgeSymbol: String {
        switch kind {
        case .claudeCode, .codex, .aiAgent: return "sparkles"
        case .ide: return "chevron.left.forwardslash.chevron.right"
        case .terminal, .shell: return "terminal"
        case .launchd: return "gearshape"
        case .pm2: return "arrow.triangle.2.circlepath"
        case .docker: return "shippingbox"
        case .app: return "app"
        case .unknown: return "questionmark"
        }
    }
}

extension ListenerGroup {
    /// The manager that will bring this group back after a plain stop (launchd KeepAlive/RunAtLoad, pm2, Docker).
    /// Looks at every process: `manager` returns the first non-`.none` one, which may be a mere watcher.
    var autoRestartManager: ProcessManager? {
        processes.lazy.map(\.manager).first { $0.isAutoRestarting }
    }

    /// Manager shown as the row's badge: an auto-restarting one first, else any non-watcher supervisor.
    var supervisingManager: ProcessManager? {
        autoRestartManager ?? processes.lazy.map(\.manager).first { $0 != .none && !$0.isWatcher }
    }
}

extension ProcessManager {
    var isWatcher: Bool {
        if case .watcher = self { return true }
        return false
    }

    /// "launchd · auto-start" / "brew services · auto-start" / "nodemon".
    var badgeText: String? {
        guard let badge else { return nil }
        return isAutoRestarting ? "\(badge) · auto-start" : badge
    }

    var badgeSymbol: String {
        switch self {
        case .none: return "circle"
        case .launchd, .pm2, .docker: return isAutoRestarting ? "arrow.clockwise" : "gearshape"
        case .watcher: return "eye"
        }
    }

    /// One-line explanation shown in the expanded row when stopping alone won't stick.
    var autoRestartExplanation: String? {
        switch self {
        case .launchd(let job):
            if job.keepAlive { return "launchd restarts this automatically (KeepAlive)." }
            if job.runAtLoad { return "launchd starts this again at every login." }
            return nil
        case .pm2(_, let name): return "pm2 restarts “\(name)” automatically."
        case .docker(let container):
            return "Docker restarts “\(container.name)” (policy: \(container.restartPolicy ?? "unknown"))."
        case .none, .watcher: return nil
        }
    }
}

// MARK: - Window visibility

/// Reports whether the hosting window is on screen. MenuBarExtra(.window) keeps its content alive between
/// openings (onAppear/onDisappear are unreliable there), so we watch the NSWindow's occlusion state instead.
/// Becoming key also counts as visible: it is posted synchronously while the panel opens, before the first
/// frame is drawn, whereas the occlusion notification arrives a moment later. PanelView only builds its list
/// while visible, so reporting early avoids an empty first frame.
struct WindowVisibilityReader: NSViewRepresentable {
    let onChange: (Bool) -> Void

    func makeNSView(context: Context) -> ObserverView {
        let view = ObserverView()
        view.onChange = onChange
        return view
    }

    func updateNSView(_ nsView: ObserverView, context: Context) {
        nsView.onChange = onChange
    }

    final class ObserverView: NSView {
        var onChange: ((Bool) -> Void)?
        private var tokens: [NSObjectProtocol] = []

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            removeObservers()
            guard let window else {
                onChange?(false)
                return
            }
            let center = NotificationCenter.default
            tokens.append(center.addObserver(forName: NSWindow.didChangeOcclusionStateNotification,
                                             object: window, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.report() }
            })
            for name in [NSWindow.didBecomeKeyNotification, NSWindow.didResignKeyNotification] {
                tokens.append(center.addObserver(forName: name, object: window, queue: .main) { [weak self] _ in
                    MainActor.assumeIsolated { self?.report() }
                })
            }
            tokens.append(center.addObserver(forName: NSWindow.willCloseNotification,
                                             object: window, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.onChange?(false) }
            })
            report()
        }

        private func report() {
            guard let window else { return }
            onChange?(Self.isOnScreen(isVisible: window.isVisible, isKey: window.isKeyWindow,
                                      occlusionVisible: window.occlusionState.contains(.visible)))
        }

        /// Ordered in, and either reported visible by the window server or key (the panel is opening).
        nonisolated static func isOnScreen(isVisible: Bool, isKey: Bool, occlusionVisible: Bool) -> Bool {
            isVisible && (occlusionVisible || isKey)
        }

        private func removeObservers() {
            tokens.forEach(NotificationCenter.default.removeObserver)
            tokens.removeAll()
        }

        deinit {
            tokens.forEach(NotificationCenter.default.removeObserver)
        }
    }
}

// MARK: - Switches

/// The native switch. In offscreen snapshots (README screenshots) AppKit draws an "on" switch in the grey of an
/// inactive window, because that window is never key, so there an accent-coloured face is drawn over the native
/// switch's own frame to show it as it looks in the open panel.
struct PanelSwitchStyle: ToggleStyle {
    @Environment(\.isSnapshotRendering) private var isSnapshotRendering

    func makeBody(configuration: Configuration) -> some View {
        if isSnapshotRendering && configuration.isOn {
            SnapshotSwitchFace()
        } else {
            Toggle(configuration)
                .toggleStyle(.switch)
        }
    }
}

/// An "on" switch: accent capsule with a white knob on the trailing side, at the native switch's track size.
private struct SnapshotSwitchFace: View {
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.controlSize) private var controlSize

    private var trackSize: CGSize {
        switch controlSize {
        case .mini: return CGSize(width: 36, height: 16)
        case .small: return CGSize(width: 42, height: 19)
        case .large, .extraLarge: return CGSize(width: 58, height: 26)
        default: return CGSize(width: 50, height: 22)
        }
    }

    var body: some View {
        let size = trackSize
        ZStack(alignment: .trailing) {
            Capsule().fill(Color.accentColor)
            Circle()
                .fill(.white)
                .shadow(color: .black.opacity(0.22), radius: 0.6, y: 0.5)
                .padding(max(1, size.height * 0.08))
        }
        .frame(width: size.width, height: size.height)
        .opacity(isEnabled ? 1 : 0.45)
    }
}

private struct SnapshotRenderingKey: EnvironmentKey {
    static let defaultValue = false
}

extension EnvironmentValues {
    /// True while SnapshotRenderer draws a view offscreen.
    var isSnapshotRendering: Bool {
        get { self[SnapshotRenderingKey.self] }
        set { self[SnapshotRenderingKey.self] = newValue }
    }
}
