import SwiftUI

/// Status item content: the network glyph plus the number of ports your projects hold open.
/// MenuBarExtra renders only an Image + Text from this view (it becomes the status item's image and title).
struct MenuBarLabel: View {
    let store: AppStore

    var body: some View {
        let count = store.menuBarCount
        let showsCount = store.settings.showCountInMenuBar && count > 0
        HStack(spacing: 3) {
            Image(systemName: "network")
            if showsCount {
                Text(verbatim: "\(count)")
                    .monospacedDigit()
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("PortPilot")
        .accessibilityValue(count == 1 ? "1 project port open" : "\(count) project ports open")
        .help("PortPilot — \(count) project port\(count == 1 ? "" : "s") open")
    }
}
