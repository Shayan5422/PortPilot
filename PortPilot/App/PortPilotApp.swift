import SwiftUI

/// Menu bar–only app (LSUIElement = YES): a status item that opens the PortPilot panel.
@main
struct PortPilotApp: App {
    @State private var store = AppStore()

    init() {
        // Headless modes (--dump / --plan / --snapshot) run and exit before any menu bar UI exists.
        if let status = CommandLineMode.runIfRequested() {
            exit(status)
        }
        // The LaunchAgent copy and a double-clicked copy must not both live in the menu bar.
        // Exit 0 so launchd's KeepAlive {SuccessfulExit = false} doesn't respawn us.
        if SingleInstance.anotherInstanceIsRunning {
            exit(0)
        }
    }

    var body: some Scene {
        MenuBarExtra {
            PanelView(store: store)
        } label: {
            // The label exists from launch, while the panel content is only built when first opened —
            // so polling starts here to keep the menu bar count live. `start()` is idempotent.
            MenuBarLabel(store: store)
                .task { store.start() }
        }
        .menuBarExtraStyle(.window)
    }
}
