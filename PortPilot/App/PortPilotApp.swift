import SwiftUI

/// Menu bar–only app (LSUIElement = YES): a status item that opens the PortPilot panel.
@main
struct PortPilotApp: App {
    @State private var store: AppStore

    init() {
        // Headless modes (--dump / --plan / --snapshot) run and exit before any menu bar UI exists.
        if let status = CommandLineMode.runIfRequested() {
            exit(status)
        }
        // Started from a Terminal or an agent inside ~/Downloads (or Documents, Desktop), the launch folder is
        // protected: anything that touched it (getcwd, a child process starting there) would make macOS ask for
        // folder access again. The menu bar app never needs it, so leave it before anything else runs.
        FileManager.default.changeCurrentDirectoryPath("/")
        // The LaunchAgent copy and a double-clicked copy must not both live in the menu bar.
        // Exit 0 so launchd's KeepAlive {SuccessfulExit = false} doesn't respawn us.
        if SingleInstance.anotherInstanceIsRunning {
            exit(0)
        }
        _store = State(initialValue: AppStore())
    }

    var body: some Scene {
        MenuBarExtra {
            PanelView(store: store)
        } label: {
            // The label exists from launch, while the panel content is only built when first opened —
            // so polling starts here to keep the menu bar count live. `start()` is idempotent.
            MenuBarLabel(store: store)
                .task {
                    store.start()
                    // Update checks and folder-access tracking, then the welcome window on first launch.
                    store.startReleaseFeatures()
                    WelcomeWindowController.showOnFirstLaunch(store: store)
                }
        }
        .menuBarExtraStyle(.window)
    }
}
