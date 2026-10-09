import AppKit
import Observation
import SwiftUI

/// State of the welcome window: which step is showing, Move to Applications, and the folder-access request.
@MainActor
@Observable
final class WelcomeModel {
    enum Step: Equatable {
        /// What PortPilot does, Move to Applications, launch at login, notifications.
        case intro
        /// Explains the macOS folder-access prompts, then asks for them deliberately.
        case folderAccess
    }

    var step: Step
    /// Where PortPilot runs from when it should offer to move itself to Applications ("your Downloads folder"),
    /// nil when it is installed (or a developer build).
    let moveSource: String?
    private(set) var isMoving = false
    private(set) var moveError: String?
    /// The protected folders that exist, in prompt order.
    let folders: [String]
    /// "Continue" was pressed on the folder step and every prompt was answered.
    private(set) var didRequestAccess = false

    @ObservationIgnored let store: AppStore
    /// Snapshots and previews: buttons do nothing.
    @ObservationIgnored let isPreview: Bool
    /// Closes the window; `openPanel` asks to open the menu bar panel afterwards.
    @ObservationIgnored var onClose: (_ openPanel: Bool) -> Void = { _ in }

    init(store: AppStore, step: Step = .intro, moveSource: String? = WelcomeModel.currentMoveSource(),
         folders: [String] = FolderAccess.standardFolders().filter { FileManager.default.fileExists(atPath: $0) },
         isPreview: Bool = false, didRequestAccess: Bool = false) {
        self.store = store
        // Nothing to ask about (no Downloads, Documents or Desktop folder): there is no second step.
        self.step = folders.isEmpty ? .intro : step
        self.moveSource = moveSource
        self.folders = folders
        self.isPreview = isPreview
        self.didRequestAccess = didRequestAccess
    }

    /// "your Downloads folder" when this copy should be moved, else nil.
    nonisolated static func currentMoveSource(bundlePath: String = Bundle.main.bundlePath) -> String? {
        InstallLocation.needsMove(bundlePath) ? InstallLocation.sourceDescription(bundlePath) : nil
    }

    var deniedFolders: [String] {
        folders.filter { store.folderAccess.state(of: $0) == .denied }
    }

    // MARK: Actions

    func continueToFolderAccess() {
        if folders.isEmpty {
            finish()
        } else {
            step = .folderAccess
        }
    }

    func back() {
        step = .intro
    }

    /// Asks macOS for each folder in turn (one prompt at a time, off the main thread).
    func requestFolderAccess() {
        guard !isPreview, !store.folderAccess.isRequesting else { return }
        store.folderAccess.requestAccess(to: folders) { [weak self] in
            self?.didRequestAccess = true
        }
    }

    func finish(openPanel: Bool = true) {
        guard !isPreview else { return }
        onClose(openPanel)
    }

    /// Copies PortPilot to Applications, makes that copy the one that starts at login (when that's on), opens it
    /// on the folder-access step, and quits this copy.
    func moveToApplications() {
        guard !isPreview, !isMoving else { return }
        isMoving = true
        moveError = nil
        let source = Bundle.main.bundleURL
        // A copy that must be moved can't set up Launch at login, so its switch shows it off. The new copy gets the
        // user's stored choice, or the installed copy's default (on).
        let launchAtLogin = AppStore.canManageLoginItem ? store.settings.launchAtLogin
            : (AppStore.storedLaunchAtLoginChoice ?? AppSettings().launchAtLogin)
        Task.detached(priority: .userInitiated) {
            let result = Result { () throws -> URL in
                let destination: URL
                switch try AppMover.forCurrentApp().install(from: source) {
                case .installed(let url), .useExisting(let url): destination = url
                }
                if launchAtLogin, let name = Bundle.main.executableURL?.lastPathComponent {
                    let executable = destination.appendingPathComponent("Contents/MacOS/\(name)").path
                    let loginItem = LoginItemManager(executablePath: executable)
                    if !loginItem.isEnabled { try? loginItem.setEnabled(true) }
                }
                return destination
            }
            await MainActor.run { self.finishMove(result) }
        }
    }

    private func finishMove(_ result: Result<URL, Error>) {
        switch result {
        case .success(let destination):
            // The new copy continues this welcome on the folder-access step.
            UserDefaults.standard.set(true, forKey: WelcomeWindowController.Keys.resumeAtFolderAccess)
            if AppMover.relaunch(destination) {
                NSApp.terminate(nil)
            } else {
                UserDefaults.standard.removeObject(forKey: WelcomeWindowController.Keys.resumeAtFolderAccess)
                isMoving = false
                moveError = "PortPilot is in \(Format.abbreviatePath(destination.deletingLastPathComponent().path)) "
                    + "now. Quit this copy and open that one."
            }
        case .failure(let error):
            isMoving = false
            moveError = error.localizedDescription
        }
    }
}

/// The first-run window: what PortPilot does and where to find it, then the folder-access prompts.
struct WelcomeView: View {
    let model: WelcomeModel
    /// false lays the content out at its natural height (tests measure it against the fixed window size).
    var fixedSize = true

    static let width: CGFloat = 500

    /// Fixed per window so switching steps never resizes or moves it.
    static func height(hasMoveCallout: Bool) -> CGFloat {
        hasMoveCallout ? 700 : 620
    }

    var body: some View {
        Group {
            if fixedSize {
                content
                    .frame(width: Self.width, height: Self.height(hasMoveCallout: model.moveSource != nil),
                           alignment: .top)
            } else {
                content
                    .frame(width: Self.width)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .background { closeShortcuts }
    }

    @ViewBuilder
    private var content: some View {
        switch model.step {
        case .intro: WelcomeIntroStep(model: model, store: model.store)
        case .folderAccess: WelcomeFolderStep(model: model, folderAccess: model.store.folderAccess)
        }
    }

    /// Esc and ⌘W close the window (it has no menu of its own).
    private var closeShortcuts: some View {
        ZStack {
            Button("Close") { model.finish(openPanel: false) }
                .keyboardShortcut(.cancelAction)
            Button("Close Window") { model.finish(openPanel: false) }
                .keyboardShortcut("w", modifiers: .command)
        }
        .buttonStyle(.plain)
        .opacity(0)
        .frame(width: 0, height: 0)
        .accessibilityHidden(true)
    }
}

// MARK: - Step 1: intro

private struct WelcomeIntroStep: View {
    let model: WelcomeModel
    @Bindable var store: AppStore

    var body: some View {
        VStack(spacing: 0) {
            VStack(spacing: 8) {
                AppGlyph(size: 72)
                    .padding(.bottom, 6)
                Text("Welcome to PortPilot")
                    .font(.system(size: 22, weight: .bold))
                    .accessibilityAddTraits(.isHeader)
                Text(AppInfo.tagline)
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.top, 38)
            .padding(.horizontal, 40)

            VStack(alignment: .leading, spacing: 14) {
                FeatureRow(symbol: "menubar.arrow.up.rectangle", tint: .blue, title: "Lives in your menu bar",
                           text: "Look for its icon at the top right of your screen, next to Wi-Fi.") {
                    MenuBarIllustration()
                }
                FeatureRow(symbol: "folder.fill", tint: .orange, title: "Groups ports by project",
                           text: "Every server shows the project folder it comes from, with its CPU and memory.")
                FeatureRow(symbol: "stop.circle.fill", tint: .red, title: "One click to stop",
                           text: "Stops the whole dev server, and never your terminal, editor or AI agent.")
                FeatureRow(symbol: "power.circle.fill", tint: .green, title: "Turns off auto-start services",
                           text: "launchd, pm2 and Docker services can be stopped for good, not just until they restart.")
            }
            .padding(.horizontal, 40)
            .padding(.top, 24)

            if let source = model.moveSource {
                MoveCallout(source: source, isMoving: model.isMoving, error: model.moveError,
                            action: model.moveToApplications)
                    .padding(.horizontal, 28)
                    .padding(.top, 20)
            }

            VStack(spacing: 0) {
                SettingsRow(title: "Launch at login",
                            subtitle: store.canManageLaunchAtLogin
                                ? "Recommended: PortPilot is back in your menu bar after a restart."
                                : SettingsText.launchAtLoginSubtitle(canManage: false)) {
                    Toggle("Launch at login", isOn: $store.settings.launchAtLogin)
                        .labelsHidden()
                        .toggleStyle(PanelSwitchStyle())
                        .controlSize(.small)
                        .disabled(!store.canManageLaunchAtLogin)
                }
                SettingsRow(title: "Notify when a new port opens", showsDivider: false) {
                    Toggle("Notify when a new port opens", isOn: $store.settings.notifyOnNewPorts)
                        .labelsHidden()
                        .toggleStyle(PanelSwitchStyle())
                        .controlSize(.small)
                }
            }
            .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Theme.cardFill))
            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Theme.hairline, lineWidth: 0.5))
            .padding(.horizontal, 28)
            .padding(.top, model.moveSource == nil ? 22 : 12)

            Spacer(minLength: 12)

            WelcomeFooter(step: "1 of 2") {
                Button("Continue", action: model.continueToFolderAccess)
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .keyboardShortcut(.defaultAction)
            }
        }
    }
}

/// "Move PortPilot to Applications" callout for copies running from a disk image or Downloads.
private struct MoveCallout: View {
    let source: String
    let isMoving: Bool
    let error: String?
    let action: () -> Void

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 10, style: .continuous)
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .center, spacing: 10) {
                Image(systemName: "arrow.down.app.fill")
                    .font(.system(size: 22))
                    .foregroundStyle(Color.accentColor)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Move PortPilot to Applications")
                        .font(.system(size: 12.5, weight: .semibold))
                    Text("It’s running from \(source). Launch at login and updates need it in Applications.")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 6)
                if isMoving {
                    ProgressView()
                        .controlSize(.small)
                        .accessibilityLabel("Moving to Applications")
                } else {
                    Button("Move", action: action)
                        .controlSize(.regular)
                        .help("Copy PortPilot to Applications and open it from there")
                        .accessibilityLabel("Move PortPilot to Applications")
                }
            }
            if let error {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .font(.system(size: 11))
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(shape.fill(Color.accentColor.opacity(0.09)))
        .overlay(shape.strokeBorder(Color.accentColor.opacity(0.28), lineWidth: 0.5))
    }
}

/// A miniature menu bar with PortPilot's icon highlighted, so new users know where to look.
private struct MenuBarIllustration: View {
    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "wifi")
            Image("MenuBarIcon")
                .renderingMode(.template)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(height: 13)
                .padding(.horizontal, 4)
                .padding(.vertical, 2)
                .foregroundStyle(.white)
                .background(RoundedRectangle(cornerRadius: 4, style: .continuous).fill(Color.accentColor))
            Image(systemName: "battery.75percent")
            Text(verbatim: "9:41")
                .monospacedDigit()
        }
        .font(.system(size: 11, weight: .medium))
        .foregroundStyle(.primary.opacity(0.75))
        .padding(.horizontal, 9)
        .frame(height: 22)
        .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(Color.primary.opacity(0.07)))
        .overlay(alignment: .bottomLeading) {
            Image(systemName: "arrow.up.right")
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(Color.accentColor)
                .offset(x: 26, y: 13)
        }
        .padding(.bottom, 10)
        .accessibilityHidden(true)
    }
}

// MARK: - Step 2: folder access

private struct WelcomeFolderStep: View {
    let model: WelcomeModel
    let folderAccess: FolderAccessController

    var body: some View {
        VStack(spacing: 0) {
            // The step is shorter than the intro: keep it centred in the same window.
            Spacer(minLength: 0)
            VStack(spacing: 8) {
                Image(systemName: "folder.badge.person.crop")
                    .font(.system(size: 46, weight: .regular))
                    .foregroundStyle(Color.accentColor)
                    .frame(height: 72)
                    .padding(.bottom, 6)
                    .accessibilityHidden(true)
                Text("One quick permission")
                    .font(.system(size: 22, weight: .bold))
                    .accessibilityAddTraits(.isHeader)
                Text("macOS will ask once whether PortPilot may open your \(folderList) "
                     + "\(model.folders.count == 1 ? "folder" : "folders"). Click Allow so PortPilot can name the "
                     + "projects you keep there.")
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.top, 24)
            .padding(.horizontal, 40)

            VStack(spacing: 0) {
                ForEach(Array(model.folders.enumerated()), id: \.element) { index, folder in
                    FolderStatusRow(name: FolderAccess.displayName(for: folder),
                                    state: folderAccess.state(of: folder),
                                    showsDivider: index < model.folders.count - 1)
                }
            }
            .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Theme.cardFill))
            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Theme.hairline, lineWidth: 0.5))
            .padding(.horizontal, 28)
            .padding(.top, 24)

            HStack(alignment: .top, spacing: 9) {
                Image(systemName: "lock.fill")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
                Text("PortPilot reads project files such as package.json and .git to show which project each server "
                     + "comes from. It never changes your files, and nothing leaves your Mac.")
                    .font(.system(size: 11.5))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 32)
            .padding(.top, 14)

            if model.didRequestAccess, !model.deniedFolders.isEmpty {
                HStack(alignment: .center, spacing: 9) {
                    Text("\(FolderAccess.list(model.deniedFolders.map(FolderAccess.displayName))): projects there "
                         + "show by folder name. You can allow access any time.")
                        .font(.system(size: 11.5))
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 6)
                    Button("Open Privacy Settings") { folderAccess.openPrivacySettings() }
                        .controlSize(.small)
                }
                .padding(.horizontal, 32)
                .padding(.top, 12)
            }

            Spacer(minLength: 12)

            WelcomeFooter(step: "2 of 2", onBack: backAction) {
                if model.didRequestAccess {
                    Button("Open PortPilot") { model.finish() }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.large)
                        .keyboardShortcut(.defaultAction)
                } else {
                    Button("Not Now") { model.finish() }
                        .controlSize(.large)
                        .help("PortPilot asks when it first finds a project in one of these folders")
                    Button(folderAccess.isRequesting ? "Waiting for macOS…" : "Continue") {
                        model.requestFolderAccess()
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .keyboardShortcut(.defaultAction)
                    .disabled(folderAccess.isRequesting)
                }
            }
        }
    }

    private var folderList: String {
        FolderAccess.list(model.folders.map(FolderAccess.displayName))
    }

    /// Back to step 1, until the prompts have started.
    private var backAction: (() -> Void)? {
        guard !model.didRequestAccess, !folderAccess.isRequesting else { return nil }
        let model = self.model
        return { model.back() }
    }
}

private struct FolderStatusRow: View {
    let name: String
    let state: FolderAccessState
    let showsDivider: Bool

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: "folder.fill")
                    .font(.system(size: 14))
                    .foregroundStyle(Color.accentColor.opacity(0.85))
                    .frame(width: 20)
                    .accessibilityHidden(true)
                Text(name)
                    .font(.system(size: 12.5))
                Spacer(minLength: 8)
                status
            }
            .padding(.horizontal, 12)
            .frame(minHeight: 34)
            .accessibilityElement(children: .combine)

            if showsDivider {
                Rectangle()
                    .fill(Theme.hairline)
                    .frame(height: 0.5)
                    .padding(.leading, 42)
            }
        }
    }

    @ViewBuilder
    private var status: some View {
        switch state {
        case .notAsked:
            Text("Not asked yet").foregroundStyle(.tertiary).font(.system(size: 11.5))
        case .asking:
            HStack(spacing: 5) {
                ProgressView().controlSize(.mini)
                Text("Waiting…")
            }
            .font(.system(size: 11.5))
            .foregroundStyle(.secondary)
        case .allowed:
            Label("Allowed", systemImage: "checkmark.circle.fill")
                .font(.system(size: 11.5, weight: .medium))
                .foregroundStyle(.green)
        case .denied:
            Label("Not allowed", systemImage: "xmark.circle.fill")
                .font(.system(size: 11.5, weight: .medium))
                .foregroundStyle(.orange)
        case .missing:
            Text("Not found").foregroundStyle(.tertiary).font(.system(size: 11.5))
        }
    }
}

// MARK: - Building blocks

/// Icon tile, title and one line of explanation (+ an optional accessory on the right).
private struct FeatureRow<Accessory: View>: View {
    let symbol: String
    let tint: Color
    let title: String
    let text: String
    @ViewBuilder var accessory: Accessory

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(tint.gradient)
                .frame(width: 32, height: 32)
                .overlay(
                    Image(systemName: symbol)
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(.white))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 13, weight: .semibold))
                Text(text)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            accessory
        }
        .accessibilityElement(children: .combine)
    }
}

private extension FeatureRow where Accessory == EmptyView {
    init(symbol: String, tint: Color, title: String, text: String) {
        self.init(symbol: symbol, tint: tint, title: title, text: text) { EmptyView() }
    }
}

/// Step counter on the left, buttons on the right, hairline above.
private struct WelcomeFooter<Buttons: View>: View {
    let step: String
    /// Shows "Back" instead of the step counter.
    var onBack: (() -> Void)? = nil
    @ViewBuilder var buttons: Buttons

    var body: some View {
        VStack(spacing: 0) {
            Rectangle()
                .fill(Theme.hairline)
                .frame(height: 0.5)
            HStack(spacing: 10) {
                if let onBack {
                    Button(action: onBack) {
                        Label("Back", systemImage: "chevron.left")
                            .font(.system(size: 12, weight: .medium))
                    }
                    .buttonStyle(HoverButtonStyle(foreground: AnyShapeStyle(.secondary)))
                    .help("Back to step 1")
                } else {
                    Text("Step \(step)")
                        .font(.system(size: 11.5))
                        .foregroundStyle(.tertiary)
                }
                Spacer()
                buttons
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 16)
        }
    }
}

// MARK: - Window

/// Shows the welcome window: on the very first launch, right after Move to Applications relaunched PortPilot
/// (continuing at the folder step), and from About › Show Welcome Guide.
///
/// An AppKit-managed window (a SwiftUI Window scene could reopen on every launch). While it is open PortPilot is a
/// regular app, so the window comes to the front and appears in ⌘-Tab; closing it returns to menu bar–only mode
/// and opens (or briefly highlights) the menu bar item.
@MainActor
final class WelcomeWindowController: NSObject, NSWindowDelegate {
    /// UserDefaults keys. Listed so they can be cleared in one place.
    enum Keys {
        static let didShowWelcome = "firstRun.didShowWelcome"
        /// Set by Move to Applications so the relaunched copy continues at the folder step.
        static let resumeAtFolderAccess = "firstRun.resumeAtFolderAccess"
        static let all = [didShowWelcome, resumeAtFolderAccess]
    }

    private static var current: WelcomeWindowController?

    private let window: NSWindow
    private let model: WelcomeModel
    private var openPanelAfterClose = false

    private init(store: AppStore, step: WelcomeModel.Step) {
        model = WelcomeModel(store: store, step: step)
        let size = NSSize(width: WelcomeView.width, height: WelcomeView.height(hasMoveCallout: model.moveSource != nil))
        window = NSWindow(contentRect: NSRect(origin: .zero, size: size),
                          styleMask: [.titled, .closable, .fullSizeContentView], backing: .buffered, defer: false)
        super.init()
        window.title = "Welcome to PortPilot"
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.isMovableByWindowBackground = true
        window.isReleasedWhenClosed = false
        window.standardWindowButton(.miniaturizeButton)?.isHidden = true
        window.standardWindowButton(.zoomButton)?.isHidden = true
        // The content runs under the transparent title bar (its top padding clears the close button), so the
        // window is exactly the size of the content, like the README snapshot. The hosting view sits in a plain
        // container: as the window's own content view it would grow the window by the title bar's height.
        let container = NSView(frame: NSRect(origin: .zero, size: size))
        let hostingView = NSHostingView(rootView: WelcomeView(model: model).ignoresSafeArea())
        hostingView.sizingOptions = []
        hostingView.frame = container.bounds
        hostingView.autoresizingMask = [.width, .height]
        container.addSubview(hostingView)
        window.contentView = container
        window.setFrame(NSRect(origin: window.frame.origin, size: size), display: false)
        window.delegate = self
        window.center()
        model.onClose = { [weak self] openPanel in self?.close(openPanel: openPanel) }
    }

    /// Call once at launch. Does nothing in the XCTest host or once the welcome was shown.
    static func showOnFirstLaunch(store: AppStore, defaults: UserDefaults = .standard) {
        guard ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] == nil else { return }
        if defaults.bool(forKey: Keys.resumeAtFolderAccess) {
            defaults.removeObject(forKey: Keys.resumeAtFolderAccess)
            show(store: store, step: .folderAccess)
        } else if !defaults.bool(forKey: Keys.didShowWelcome) {
            show(store: store)
        }
    }

    /// Shows (or brings forward) the welcome window.
    static func show(store: AppStore, step: WelcomeModel.Step = .intro) {
        guard ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] == nil else { return }
        UserDefaults.standard.set(true, forKey: Keys.didShowWelcome)
        if let current {
            current.model.step = step
            current.present()
            return
        }
        let controller = WelcomeWindowController(store: store, step: step)
        current = controller
        controller.present()
    }

    private func present() {
        NSApp.setActivationPolicy(.regular)
        window.makeKeyAndOrderFront(nil)
        NSApp.activate()
    }

    private func close(openPanel: Bool) {
        openPanelAfterClose = openPanel
        window.close()
    }

    func windowWillClose(_ notification: Notification) {
        let openPanel = openPanelAfterClose
        Self.current = nil
        NSApp.setActivationPolicy(.accessory)
        // Let the window and the Dock icon go first, then point at the menu bar item.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
            if openPanel, StatusItemAccess.openPanel() { return }
            StatusItemAccess.flash()
        }
    }
}

/// The MenuBarExtra's status item button. SwiftUI has no API for it, so it is found through the status bar
/// window; every call degrades to doing nothing when it can't be found.
@MainActor
enum StatusItemAccess {
    static func button() -> NSStatusBarButton? {
        for window in NSApp.windows where window.className.contains("NSStatusBarWindow") {
            if let button = find(in: window.contentView) { return button }
        }
        return nil
    }

    /// Opens the panel as if the menu bar item was clicked. False when the item wasn't found.
    @discardableResult
    static func openPanel() -> Bool {
        guard let button = button() else { return false }
        button.performClick(nil)
        return true
    }

    /// Highlights the menu bar item twice, briefly, so the eye finds it.
    static func flash() {
        guard let button = button() else { return }
        for (index, on) in [true, false, true, false].enumerated() {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.22 * Double(index)) {
                button.highlight(on)
            }
        }
    }

    private static func find(in view: NSView?) -> NSStatusBarButton? {
        guard let view else { return nil }
        if let button = view as? NSStatusBarButton { return button }
        for subview in view.subviews {
            if let button = find(in: subview) { return button }
        }
        return nil
    }
}
