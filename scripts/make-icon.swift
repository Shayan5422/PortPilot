#!/usr/bin/env swift
// make-icon.swift — renders the PortPilot app icon with CoreGraphics and writes a complete
// macOS AppIcon.appiconset (10 PNGs + Contents.json).
//
// Usage:
//   swift scripts/make-icon.swift [OUTPUT_DIR] [--preview PREVIEW.png]
//
//   OUTPUT_DIR  the .appiconset folder to write
//               (default: PortPilot/Resources/Assets.xcassets/AppIcon.appiconset next to this script's repo)
//   --preview   also writes a contact sheet (every size at 1x plus 8x/4x pixel-exact zooms of the
//               16 px and 32 px renders, on light and dark backgrounds) for eyeballing the result.
//
// Every size is drawn from vectors at its own pixel size (not downscaled from 1024 px), and the
// two smallest sizes use a simplified, heavier glyph so they stay legible in Finder lists and
// notification banners.

import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

// MARK: - Errors

struct IconError: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
}

// MARK: - AppIcon slots

/// One entry of a macOS AppIcon set: a point size at a given scale.
struct IconSlot {
    let points: Int
    let scale: Int

    var pixels: Int { points * scale }
    var filename: String {
        scale == 1 ? "icon_\(points)x\(points).png" : "icon_\(points)x\(points)@\(scale)x.png"
    }
}

/// The ten images Xcode expects for a macOS app icon (16 … 512 pt at 1x and 2x → 16 … 1024 px).
let slots: [IconSlot] = [16, 32, 128, 256, 512].flatMap { points in
    [IconSlot(points: points, scale: 1), IconSlot(points: points, scale: 2)]
}

// MARK: - Design

/// All colours are sRGB.
enum Palette {
    static func rgb(_ hex: UInt32, alpha: CGFloat = 1) -> CGColor {
        CGColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
                green: CGFloat((hex >> 8) & 0xFF) / 255,
                blue: CGFloat(hex & 0xFF) / 255,
                alpha: alpha)
    }

    /// Background gradient, top → bottom: bright azure into deep indigo.
    static let backgroundTop = rgb(0x4F9DFF)
    static let backgroundMid = rgb(0x3F6BF0)
    static let backgroundBottom = rgb(0x3A2DB8)
    /// Glyph colour.
    static let glyph = rgb(0xFFFFFF)
    /// "Live port" accent in the centre of the top node.
    static let live = rgb(0x3EE6A0)
    static let liveRim = rgb(0x1FAF78)
}

/// Apple's macOS icon grid (Big Sur and later), in 1024-px design units: the body is an 824 × 824
/// continuous-corner rounded square centred on the canvas, corner radius 185.4.
enum Grid {
    static let canvas: CGFloat = 1024
    static let bodyInset: CGFloat = 100
    static let cornerRadiusRatio: CGFloat = 185.4 / 824
}

/// Glyph geometry in body-relative units (0…1 across the rounded square, y pointing up).
struct GlyphMetrics {
    /// Node centres: top, bottom-left, bottom-right (an equilateral triangle).
    let nodes: [CGPoint]
    let nodeRadius: CGFloat
    let linkWidth: CGFloat
    /// Radius of the hollow "socket" punched into the bottom nodes (0 → solid disks).
    let socketRadius: CGFloat
    /// Radius of the green "live" dot in the top node (0 → none).
    let liveRadius: CGFloat
    /// Snap strokes and nodes to whole pixels (only worthwhile at 16 px and 32 px).
    let snapsToPixels: Bool
    /// Soft shadow under the glyph (pointless below 64 px).
    let hasShadow: Bool

    /// Full-detail glyph for 64 px and up.
    static let regular = GlyphMetrics(
        nodes: [CGPoint(x: 0.5, y: 0.73), CGPoint(x: 0.265, y: 0.322), CGPoint(x: 0.735, y: 0.322)],
        nodeRadius: 0.108,
        linkWidth: 0.06,
        socketRadius: 0.05,
        liveRadius: 0.05,
        snapsToPixels: false,
        hasShadow: true
    )

    /// 32 px: heavier strokes, solid bottom nodes, the live dot survives.
    static let small = GlyphMetrics(
        nodes: [CGPoint(x: 0.5, y: 0.77), CGPoint(x: 0.22, y: 0.27), CGPoint(x: 0.78, y: 0.27)],
        nodeRadius: 0.15,
        linkWidth: 0.085,
        socketRadius: 0,
        liveRadius: 0.07,
        snapsToPixels: true,
        hasShadow: false
    )

    /// 16 px: just the white silhouette — sub-pixel details only add blur.
    static let tiny = GlyphMetrics(
        nodes: [CGPoint(x: 0.5, y: 0.77), CGPoint(x: 0.22, y: 0.27), CGPoint(x: 0.78, y: 0.27)],
        nodeRadius: 0.15,
        linkWidth: 0.1,
        socketRadius: 0,
        liveRadius: 0,
        snapsToPixels: true,
        hasShadow: false
    )

    static func forPixels(_ pixels: Int) -> GlyphMetrics {
        switch pixels {
        case ...16: return .tiny
        case ...32: return .small
        default: return .regular
        }
    }
}

/// Glyph geometry resolved to pixel coordinates for one body rectangle.
struct GlyphGeometry {
    /// Node centres: top, bottom-left, bottom-right.
    var nodes: [CGPoint]
    var nodeRadius: CGFloat
    var linkWidth: CGFloat
    /// y of the horizontal bottom link (equals the bottom nodes' y unless hinted).
    var bottomLinkY: CGFloat
    var socketRadius: CGFloat
    var liveRadius: CGFloat

    init(metrics m: GlyphMetrics, body: CGRect) {
        let side = body.width
        nodes = m.nodes.map { CGPoint(x: body.minX + $0.x * side, y: body.minY + $0.y * side) }
        nodeRadius = m.nodeRadius * side
        linkWidth = m.linkWidth * side
        bottomLinkY = nodes[1].y
        socketRadius = m.socketRadius * side
        liveRadius = m.liveRadius * side
        if m.snapsToPixels { snapToPixels(centerX: body.midX) }
    }

    /// Light hinting for tiny sizes: whole-pixel node diameters and stroke width, with node centres
    /// and the horizontal bottom link placed so their edges land on pixel boundaries.
    private mutating func snapToPixels(centerX: CGFloat) {
        let diameter = max(2, (nodeRadius * 2).rounded())
        let width = max(1, linkWidth.rounded())
        // Even extents are centred on a pixel boundary, odd ones on a pixel centre.
        func snap(_ value: CGFloat, extent: CGFloat) -> CGFloat {
            Int(extent) % 2 == 0 ? value.rounded() : (value - 0.5).rounded() + 0.5
        }
        let bottomY = snap(nodes[1].y, extent: diameter)
        let leftX = snap(nodes[1].x, extent: diameter)
        bottomLinkY = snap(nodes[1].y, extent: width)
        nodes = [
            CGPoint(x: centerX, y: snap(nodes[0].y, extent: diameter)),
            CGPoint(x: leftX, y: bottomY),
            CGPoint(x: 2 * centerX - leftX, y: bottomY),
        ]
        nodeRadius = diameter / 2
        linkWidth = width
        liveRadius = liveRadius > 0 ? max(1, liveRadius.rounded()) : 0
    }
}

// MARK: - Geometry helpers

/// Rounded rectangle with continuous ("squircle") corners, like `RoundedRectangle(style: .continuous)`.
/// Control points from PaintCode's reverse-engineering of the iOS 7 / macOS 11 corner curve,
/// expressed in multiples of the corner radius measured from the corner.
func continuousRoundedRect(_ rect: CGRect, cornerRadius: CGFloat) -> CGPath {
    let limit = min(rect.width, rect.height) / 2 / 1.52866483
    let r = min(cornerRadius, limit)
    let path = CGMutablePath()

    // One corner, walking from the first edge (u axis) to the second edge (v axis).
    // (u, v) are distances from the corner along the two edges, in units of r.
    typealias Segment = (end: (CGFloat, CGFloat), c1: (CGFloat, CGFloat)?, c2: (CGFloat, CGFloat)?)
    let corner: [Segment] = [
        ((0.66993427, 0.06549600), (1.08849323, 0.0), (0.86840689, 0.0)),
        ((0.63149399, 0.07491100), nil, nil),
        ((0.07491176, 0.63149399), (0.37282392, 0.16905899), (0.16906013, 0.37282401)),
        ((0.0, 1.52866483), (0.0, 0.86840701), (0.0, 1.08849299)),
    ]
    // Each corner: its position and unit vectors pointing back along the incoming edge (u) and
    // forward along the outgoing edge (v). Order: walk the rectangle counter-clockwise (y up).
    let corners: [(origin: CGPoint, u: CGVector, v: CGVector)] = [
        (CGPoint(x: rect.maxX, y: rect.minY), CGVector(dx: -1, dy: 0), CGVector(dx: 0, dy: 1)),
        (CGPoint(x: rect.maxX, y: rect.maxY), CGVector(dx: 0, dy: -1), CGVector(dx: -1, dy: 0)),
        (CGPoint(x: rect.minX, y: rect.maxY), CGVector(dx: 1, dy: 0), CGVector(dx: 0, dy: -1)),
        (CGPoint(x: rect.minX, y: rect.minY), CGVector(dx: 0, dy: 1), CGVector(dx: 1, dy: 0)),
    ]

    for (index, c) in corners.enumerated() {
        func map(_ p: (CGFloat, CGFloat)) -> CGPoint {
            CGPoint(x: c.origin.x + (p.0 * c.u.dx + p.1 * c.v.dx) * r,
                    y: c.origin.y + (p.0 * c.u.dy + p.1 * c.v.dy) * r)
        }
        let start = map((1.52866483, 0))
        if index == 0 { path.move(to: start) } else { path.addLine(to: start) }
        for segment in corner {
            if let c1 = segment.c1, let c2 = segment.c2 {
                path.addCurve(to: map(segment.end), control1: map(c1), control2: map(c2))
            } else {
                path.addLine(to: map(segment.end))
            }
        }
    }
    path.closeSubpath()
    return path
}

func circle(_ center: CGPoint, _ radius: CGFloat) -> CGRect {
    CGRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2)
}

// MARK: - Rendering

func makeBitmapContext(width: Int, height: Int) throws -> CGContext {
    guard let space = CGColorSpace(name: CGColorSpace.sRGB) else { throw IconError("sRGB colour space unavailable") }
    guard let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                              space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
        throw IconError("could not create a \(width)×\(height) bitmap context")
    }
    ctx.setShouldAntialias(true)
    ctx.setAllowsAntialiasing(true)
    ctx.interpolationQuality = .high
    return ctx
}

func makeGradient(_ colors: [CGColor], _ locations: [CGFloat]) throws -> CGGradient {
    guard let space = CGColorSpace(name: CGColorSpace.sRGB),
          let gradient = CGGradient(colorsSpace: space, colors: colors as CFArray, locations: locations) else {
        throw IconError("could not create gradient")
    }
    return gradient
}

/// Draws the whole icon into a `pixels × pixels` image.
func renderIcon(pixels: Int) throws -> CGImage {
    let ctx = try makeBitmapContext(width: pixels, height: pixels)
    let size = CGFloat(pixels)
    let unit = size / Grid.canvas            // 1 design unit in pixels
    let isSmall = pixels <= 32

    // Snap the body to whole pixels so its straight edges stay crisp at small sizes. At 16 px the
    // nominal 1.56 px margin is trimmed to 1 px: a 14 px body reads much better than a 12 px one.
    let inset = pixels <= 16 ? 1 : (Grid.bodyInset * unit).rounded()
    let body = CGRect(x: inset, y: inset, width: size - 2 * inset, height: size - 2 * inset)
    let bodyPath = continuousRoundedRect(body, cornerRadius: body.width * Grid.cornerRadiusRatio)

    // 1. Drop shadow under the body (Apple template: ~10 px down, soft, ~30 % black).
    if pixels > 16 {
        ctx.saveGState()
        ctx.setShadow(offset: CGSize(width: 0, height: -10 * unit), blur: max(1, 22 * unit),
                      color: Palette.rgb(0x000000, alpha: 0.30))
        ctx.addPath(bodyPath)
        ctx.setFillColor(Palette.backgroundBottom)
        ctx.fillPath()
        ctx.restoreGState()
    }

    // 2. Body: vertical azure → indigo gradient with a soft sheen across the top.
    ctx.saveGState()
    ctx.addPath(bodyPath)
    ctx.clip()
    let background = try makeGradient([Palette.backgroundTop, Palette.backgroundMid, Palette.backgroundBottom],
                                      [0, 0.45, 1])
    ctx.drawLinearGradient(background, start: CGPoint(x: body.midX, y: body.maxY),
                           end: CGPoint(x: body.midX, y: body.minY), options: [])
    let sheen = try makeGradient([Palette.rgb(0xFFFFFF, alpha: 0.22), Palette.rgb(0xFFFFFF, alpha: 0)], [0, 1])
    ctx.drawRadialGradient(sheen,
                           startCenter: CGPoint(x: body.midX, y: body.maxY + body.height * 0.15), startRadius: 0,
                           endCenter: CGPoint(x: body.midX, y: body.maxY + body.height * 0.15),
                           endRadius: body.height * 0.85, options: [])

    // 3. Glyph: three linked nodes — a tiny network of ports.
    let metrics = GlyphMetrics.forPixels(pixels)
    try drawGlyph(in: ctx, geometry: GlyphGeometry(metrics: metrics, body: body),
                  shadowUnit: metrics.hasShadow ? unit : nil)

    // 4. Hairline inner rim so the edge reads on both light and dark backgrounds.
    if !isSmall {
        ctx.addPath(bodyPath)
        ctx.setStrokeColor(Palette.rgb(0xFFFFFF, alpha: 0.16))
        ctx.setLineWidth(max(1, 4 * unit))   // half of it is clipped away → ~2 design units visible
        ctx.strokePath()
    }
    ctx.restoreGState()

    guard let image = ctx.makeImage() else { throw IconError("could not snapshot the \(pixels) px bitmap") }
    return image
}

/// Draws three linked nodes — a tiny network of ports. `shadowUnit` (pixels per design unit)
/// enables the soft drop shadow under the glyph.
func drawGlyph(in ctx: CGContext, geometry g: GlyphGeometry, shadowUnit: CGFloat?) throws {
    let nodes = g.nodes
    let nodeRadius = g.nodeRadius

    // Everything white is drawn inside one transparency layer so the shadow is cast once,
    // by the combined silhouette, instead of stacking up where links meet nodes.
    ctx.saveGState()
    if let unit = shadowUnit {
        ctx.setShadow(offset: CGSize(width: 0, height: -8 * unit), blur: 18 * unit,
                      color: Palette.rgb(0x10095A, alpha: 0.35))
    }
    ctx.beginTransparencyLayer(auxiliaryInfo: nil)

    // Links: a closed triangle between node centres, ending just inside the node rims
    // (never reaching a socket or the live dot).
    ctx.setStrokeColor(Palette.glyph)
    ctx.setLineWidth(g.linkWidth)
    ctx.setLineCap(.butt)
    for (a, b) in [(0, 1), (1, 2), (2, 0)] {
        var p = nodes[a], q = nodes[b]
        if a == 1 && b == 2 { p.y = g.bottomLinkY; q.y = g.bottomLinkY }
        let dx = q.x - p.x, dy = q.y - p.y
        let length = (dx * dx + dy * dy).squareRoot()
        guard length > 2 * nodeRadius else { continue }
        let ux = dx / length, uy = dy / length
        // Overlap a little into each node so anti-aliasing never leaves a seam.
        let trim = nodeRadius * 0.7
        ctx.move(to: CGPoint(x: p.x + ux * trim, y: p.y + uy * trim))
        ctx.addLine(to: CGPoint(x: q.x - ux * trim, y: q.y - uy * trim))
        ctx.strokePath()
    }

    // Nodes: white disks with a hollow socket (regular) or solid (small).
    ctx.setFillColor(Palette.glyph)
    for node in nodes {
        ctx.addEllipse(in: circle(node, nodeRadius))
    }
    ctx.fillPath()
    if g.socketRadius > 0 {
        // Punch the sockets out of the bottom nodes; the background gradient shows through.
        ctx.setBlendMode(.clear)
        for node in nodes.dropFirst() {
            ctx.addEllipse(in: circle(node, g.socketRadius))
        }
        ctx.fillPath()
        ctx.setBlendMode(.normal)
    }
    ctx.endTransparencyLayer()
    ctx.restoreGState()

    // The top node carries a green "live" dot: an open, listening port.
    if g.liveRadius > 0 {
        let live = circle(nodes[0], g.liveRadius)
        ctx.saveGState()
        ctx.addEllipse(in: live)
        ctx.clip()
        let gradient = try makeGradient([Palette.live, Palette.liveRim], [0, 1])
        ctx.drawRadialGradient(gradient,
                               startCenter: CGPoint(x: live.midX, y: live.midY + live.height * 0.15), startRadius: 0,
                               endCenter: CGPoint(x: live.midX, y: live.midY), endRadius: live.width / 2,
                               options: [.drawsAfterEndLocation])
        ctx.restoreGState()
    }
}

// MARK: - Output

func writePNG(_ image: CGImage, to url: URL, scale: Int) throws {
    guard let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else {
        throw IconError("cannot create PNG at \(url.path)")
    }
    let dpi = 72 * scale
    let properties: [CFString: Any] = [kCGImagePropertyDPIWidth: dpi, kCGImagePropertyDPIHeight: dpi]
    CGImageDestinationAddImage(destination, image, properties as CFDictionary)
    guard CGImageDestinationFinalize(destination) else { throw IconError("failed to write \(url.path)") }
}

/// Xcode-style Contents.json for a macOS AppIcon set.
func contentsJSON() -> String {
    let entries = slots.map { slot in
        """
            {
              "filename" : "\(slot.filename)",
              "idiom" : "mac",
              "scale" : "\(slot.scale)x",
              "size" : "\(slot.points)x\(slot.points)"
            }
        """
    }
    return """
    {
      "images" : [
    \(entries.joined(separator: ",\n"))
      ],
      "info" : {
        "author" : "xcode",
        "version" : 1
      }
    }

    """
}

/// Light/dark contact sheet: every distinct size at 1x (1024 px shown at 512), plus pixel-exact
/// nearest-neighbour zooms of the 16 px and 32 px renders.
func writePreview(images: [Int: CGImage], to url: URL) throws {
    let sizes = images.keys.sorted()
    let gap = 24
    let zoomed: [(pixels: Int, factor: Int)] = [(16, 8), (32, 4)]
    let shownSize = { (pixels: Int) in min(pixels, 512) }
    let topRow = (sizes.map(shownSize).max() ?? 0) + gap
    let bottomRow = (zoomed.map { $0.pixels * $0.factor }.max() ?? 0) + gap
    let blockHeight = gap + topRow + bottomRow
    let width = max(sizes.reduce(gap) { $0 + shownSize($1) + gap },
                    zoomed.reduce(gap) { $0 + $1.pixels * $1.factor + gap })
    let ctx = try makeBitmapContext(width: width, height: 2 * blockHeight)

    for (index, background) in [Palette.rgb(0xF2F2F5), Palette.rgb(0x1E1E22)].enumerated() {
        // Light block on top, dark block below (CoreGraphics' y axis points up).
        let blockTop = (2 - index) * blockHeight
        ctx.setFillColor(background)
        ctx.fill(CGRect(x: 0, y: blockTop - blockHeight, width: width, height: blockHeight))

        var x = gap
        ctx.interpolationQuality = .high
        for pixels in sizes {
            guard let image = images[pixels] else { continue }
            let shown = shownSize(pixels)
            ctx.draw(image, in: CGRect(x: x, y: blockTop - gap - shown, width: shown, height: shown))
            x += shown + gap
        }
        x = gap
        ctx.interpolationQuality = .none
        for (pixels, factor) in zoomed {
            guard let image = images[pixels] else { continue }
            let shown = pixels * factor
            ctx.draw(image, in: CGRect(x: x, y: blockTop - gap - topRow - shown, width: shown, height: shown))
            x += shown + gap
        }
    }
    guard let image = ctx.makeImage() else { throw IconError("could not snapshot the preview") }
    try writePNG(image, to: url, scale: 1)
}

// MARK: - Main

func defaultOutputDirectory() -> URL {
    // scripts/make-icon.swift → <repo>/PortPilot/Resources/Assets.xcassets/AppIcon.appiconset
    let script = URL(fileURLWithPath: #filePath, relativeTo: URL(fileURLWithPath: FileManager.default.currentDirectoryPath))
    return script.standardizedFileURL
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .appendingPathComponent("PortPilot/Resources/Assets.xcassets/AppIcon.appiconset", isDirectory: true)
}

func run() throws {
    var arguments = Array(CommandLine.arguments.dropFirst())
    var previewURL: URL?
    if let index = arguments.firstIndex(of: "--preview") {
        guard index + 1 < arguments.count else { throw IconError("--preview needs a file path") }
        previewURL = URL(fileURLWithPath: arguments[index + 1])
        arguments.removeSubrange(index...(index + 1))
    }
    if arguments.contains(where: { $0 == "-h" || $0 == "--help" }) {
        print("usage: swift scripts/make-icon.swift [OUTPUT_APPICONSET_DIR] [--preview PREVIEW.png]")
        return
    }
    guard arguments.count <= 1 else { throw IconError("unexpected arguments: \(arguments.joined(separator: " "))") }
    let output = arguments.first.map { URL(fileURLWithPath: $0, isDirectory: true) } ?? defaultOutputDirectory()

    try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)

    // Render each distinct pixel size once; 32/256/512 px are shared by two slots.
    var images: [Int: CGImage] = [:]
    for pixels in Set(slots.map(\.pixels)).sorted() {
        images[pixels] = try renderIcon(pixels: pixels)
    }
    for slot in slots {
        guard let image = images[slot.pixels] else { throw IconError("missing \(slot.pixels) px render") }
        try writePNG(image, to: output.appendingPathComponent(slot.filename), scale: slot.scale)
    }
    try contentsJSON().write(to: output.appendingPathComponent("Contents.json"), atomically: true, encoding: .utf8)
    print("Wrote \(slots.count) icons + Contents.json to \(output.path)")

    if let previewURL {
        try writePreview(images: images, to: previewURL)
        print("Wrote preview to \(previewURL.path)")
    }
}

do {
    try run()
} catch {
    FileHandle.standardError.write(Data("make-icon: \(error)\n".utf8))
    exit(1)
}
