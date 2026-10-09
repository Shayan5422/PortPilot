import AppKit
import SwiftUI

/// Renders the panel to a PNG without putting anything on screen (used by `--snapshot` and for visual checks;
/// needs no Screen Recording permission). Works from a plain executable as long as `NSApplication.shared`
/// exists — it is created here if needed.
@MainActor
enum SnapshotRenderer {
    /// Renders `PanelView(store:snapshotMode: true)` at its natural height.
    /// - Parameters:
    ///   - showSettings: render the Settings page instead of the list.
    ///   - scale: pixels per point of the output (2 = Retina).
    /// - Returns: true when the PNG was written.
    @discardableResult
    static func render(store: AppStore, to url: URL, width: CGFloat = 440, colorScheme: ColorScheme,
                       showSettings: Bool = false, scale: CGFloat = 2) -> Bool {
        _ = NSApplication.shared

        let appearance = NSAppearance(named: colorScheme == .dark ? .darkAqua : .aqua)
        let root = PanelView(store: store, snapshotMode: true, initiallyShowingSettings: showSettings)
            .frame(width: width)
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .environment(\.colorScheme, colorScheme)
            // Draw controls as in the (key) menu bar panel rather than an inactive background window.
            .environment(\.controlActiveState, .key)
            .transaction { $0.disablesAnimations = true }

        let hostingView = NSHostingView(rootView: root)
        hostingView.appearance = appearance

        // Borderless, transparent window far off screen: views need a window for AppKit-backed controls
        // (toggles, pickers, text fields) to draw, but it is never ordered in.
        let window = NSWindow(contentRect: NSRect(x: -30_000, y: -30_000, width: width, height: 400),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = appearance
        window.isOpaque = false
        window.backgroundColor = .clear
        window.contentView = hostingView
        defer { window.close() }

        // Two passes: the first lets SwiftUI resolve fonts/text layout, the second settles the final height.
        var size = CGSize(width: width, height: 400)
        for _ in 0..<2 {
            size = hostingView.fittingSize
            guard size.width > 0, size.height > 0 else { return false }
            size.height = min(size.height.rounded(.up), 8_000)
            window.setContentSize(size)
            hostingView.frame = NSRect(origin: .zero, size: size)
            hostingView.layoutSubtreeIfNeeded()
            RunLoop.current.run(until: Date().addingTimeInterval(0.12))
        }

        let bounds = hostingView.bounds
        let pixelsWide = Int((bounds.width * scale).rounded())
        let pixelsHigh = Int((bounds.height * scale).rounded())
        guard pixelsWide > 0, pixelsHigh > 0,
              let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixelsWide, pixelsHigh: pixelsHigh,
                                            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)
        else { return false }
        bitmap.size = bounds.size // point size → drawing is scaled to the pixel size
        hostingView.cacheDisplay(in: bounds, to: bitmap)

        guard let png = bitmap.representation(using: .png, properties: [:]) else { return false }
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try png.write(to: url, options: .atomic)
            return true
        } catch {
            return false
        }
    }
}
