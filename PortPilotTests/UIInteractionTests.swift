import AppKit
import SwiftUI
import XCTest
@testable import PortPilot

/// Drives a real `ConfirmButton` with synthetic mouse events in an offscreen window (never shown on screen).
/// A plain SwiftUI Button in the same harness is the control: it proves the events really reach SwiftUI (and
/// that a plain Button fires on every mouse-up, which is why ConfirmButton needs its guard).
@MainActor
final class ConfirmButtonInteractionTests: XCTestCase {
    private final class Counter { var runs = 0 }

    private var windows: [NSWindow] = []

    override func tearDown() async throws {
        windows.forEach { $0.close() }
        windows.removeAll()
    }

    /// Hosts `view` centred in a 260×80 borderless window far off screen.
    private func host<V: View>(_ view: V) -> NSWindow {
        let hosting = NSHostingView(rootView: view.frame(width: 260, height: 80))
        hosting.sizingOptions = [] // never resize the window to the content (would loop with the fixed frame)
        let window = NSWindow(contentRect: NSRect(x: -30_000, y: -30_000, width: 260, height: 80),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = hosting
        hosting.frame = NSRect(x: 0, y: 0, width: 260, height: 80)
        hosting.layoutSubtreeIfNeeded()
        // Ordered in (SwiftUI ignores clicks in a window that isn't), but 30 000 pt off screen: never visible,
        // never key, so nothing on the user's screen changes.
        window.orderFrontRegardless()
        windows.append(window)
        settle(0.3)
        return window
    }

    /// Mouse down + up at the window's centre (where the button sits).
    private func click(_ window: NSWindow, count: Int) {
        for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
            guard let event = NSEvent.mouseEvent(with: type, location: NSPoint(x: 130, y: 40), modifierFlags: [],
                                                 timestamp: ProcessInfo.processInfo.systemUptime,
                                                 windowNumber: window.windowNumber, context: nil,
                                                 eventNumber: 0, clickCount: count,
                                                 pressure: type == .leftMouseDown ? 1 : 0)
            else { return XCTFail("could not make a mouse event") }
            window.sendEvent(event)
            settle(0.03)
        }
    }

    /// Lets SwiftUI process state changes and tasks.
    private func settle(_ seconds: TimeInterval) {
        RunLoop.current.run(until: Date().addingTimeInterval(seconds))
    }

    private func confirmButton(_ counter: Counter) -> some View {
        ConfirmButton(title: "Stop All Projects", confirmTitle: "Stop 3 Projects?", systemImage: "stop.circle") {
            counter.runs += 1
        }
    }

    func testControlPlainButtonFiresOnEveryMouseUp() {
        let counter = Counter()
        let window = host(Button("Stop") { counter.runs += 1 })
        click(window, count: 1)
        XCTAssertEqual(counter.runs, 1, "synthetic clicks must reach SwiftUI, or the tests below prove nothing")
        click(window, count: 2)
        XCTAssertEqual(counter.runs, 2, "a plain Button fires again on the second click of a double-click")
    }

    func testDoubleClickArmsButNeverConfirms() {
        let counter = Counter()
        let window = host(confirmButton(counter))
        click(window, count: 1)
        click(window, count: 2) // second click of a habitual double-click, ~30 ms later
        XCTAssertEqual(counter.runs, 0, "a double-click must not pass the confirmation")
        // Still armed: a deliberate click after the double-click interval confirms.
        settle(NSEvent.doubleClickInterval + 0.1)
        click(window, count: 1)
        XCTAssertEqual(counter.runs, 1)
    }

    func testDeliberateSecondClickConfirmsOnceThenRests() {
        let counter = Counter()
        let window = host(confirmButton(counter))
        click(window, count: 1)
        XCTAssertEqual(counter.runs, 0, "the first click only arms")
        settle(NSEvent.doubleClickInterval + 0.1)
        click(window, count: 1)
        XCTAssertEqual(counter.runs, 1)
        // Back to resting: one more click only arms again.
        settle(NSEvent.doubleClickInterval + 0.1)
        click(window, count: 1)
        XCTAssertEqual(counter.runs, 1)
    }

    // MARK: Stop button of a group row

    /// Count of clearly red pixels in the top-right corner of the window (where a row's Stop button sits).
    private func redPixelsNearStopButton(_ window: NSWindow) throws -> Int {
        let view = try XCTUnwrap(window.contentView)
        let bounds = view.bounds
        let rep = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: bounds))
        view.cacheDisplay(in: bounds, to: rep)
        if let directory = ProcessInfo.processInfo.environment["PORTPILOT_UI_SNAPSHOT_DIR"],
           let png = rep.representation(using: .png, properties: [:]) {
            try? png.write(to: URL(fileURLWithPath: directory).appendingPathComponent("row-\(window.windowNumber).png"))
        }
        // Redraw into a known RGBA8 sRGB buffer (the cached bitmap's own format varies).
        let cgImage = try XCTUnwrap(rep.cgImage)
        let width = cgImage.width, height = cgImage.height
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        let drawn: Bool = pixels.withUnsafeMutableBytes { buffer in
            guard let context = CGContext(data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8,
                                          bytesPerRow: width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            context.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        XCTAssertTrue(drawn)
        let scale = CGFloat(width) / bounds.width
        var red = 0
        // Buffer rows run top-down: the first 34 pt are the row's title line.
        for y in 0..<min(height, Int(34 * scale)) {
            for x in max(0, Int((bounds.width - 110) * scale))..<width {
                let i = (y * width + x) * 4
                if pixels[i] > 190 && pixels[i + 1] < 115 && pixels[i + 2] < 115 { red += 1 }
            }
        }
        return red
    }

    /// Hosts a group row (424 pt wide, like in the panel) and clicks its Stop button once.
    private func clickStop(of group: ListenerGroup) throws -> NSWindow {
        let store = UIFixtures.worstCaseStore(expandAll: false)
        let width: CGFloat = 424, height: CGFloat = 90
        let hosting = NSHostingView(rootView: GroupRow(group: group, store: store)
            .frame(width: width, height: height, alignment: .top)
            .background(Color.white)
            .environment(\.colorScheme, .light))
        hosting.sizingOptions = []
        let window = NSWindow(contentRect: NSRect(x: -30_000, y: -30_000, width: width, height: height),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: .aqua)
        window.contentView = hosting
        hosting.frame = NSRect(x: 0, y: 0, width: width, height: height)
        window.orderFrontRegardless()
        windows.append(window)
        settle(0.3)
        XCTAssertEqual(try redPixelsNearStopButton(window), 0, "nothing is red before the click")
        // The Stop button: last control of the title line (row padding 8, button 22 wide; title line ~17 pt down).
        let point = NSPoint(x: width - 8 - 11, y: height - 7 - 10)
        for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
            let event = try XCTUnwrap(NSEvent.mouseEvent(with: type, location: point, modifierFlags: [],
                                                         timestamp: ProcessInfo.processInfo.systemUptime,
                                                         windowNumber: window.windowNumber, context: nil,
                                                         eventNumber: 0, clickCount: 1, pressure: 1))
            window.sendEvent(event)
            settle(0.05)
        }
        settle(0.3)
        return window
    }

    func testAppRowStopArmsInsteadOfStopping() throws {
        let app = try XCTUnwrap(UIFixtures.worstCaseGroups().first { $0.category == .app })
        let window = try clickStop(of: app)
        XCTAssertGreaterThan(try redPixelsNearStopButton(window), 40, "the first click shows the red “Stop?” confirmation")
    }

    func testProjectRowStopIsOneClick() throws {
        // A project stops on the first click (the preview store has no engine, so nothing is signalled) and
        // never shows the confirmation.
        let project = try XCTUnwrap(UIFixtures.worstCaseGroups().first { $0.category == .project && $0.ports.count == 1 })
        let window = try clickStop(of: project)
        XCTAssertEqual(try redPixelsNearStopButton(window), 0)
    }
}
