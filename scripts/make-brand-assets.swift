#!/usr/bin/env swift
// Generates every PortPilot brand asset from the master logo (Design/logo.png, transparent PNG):
//   • AppIcon.appiconset   — macOS app icon (Big Sur grid squircle, 16–1024 px)
//   • Logo.imageset        — full-colour logo for the About screen and panel header
//   • MenuBarIcon.imageset — monochrome template glyph for the menu bar (adapts to light/dark)
//   • docs/images/icon.png, docs/images/logo.png — README artwork
//   • Design/dmg-background(@2x).png — installer window background
//
// Usage: swift scripts/make-brand-assets.swift [--preview <sheet.png>]
// Output is deterministic; re-run after changing Design/logo.png.

import AppKit
import CoreGraphics
import Foundation

struct BrandError: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
}

// MARK: - Paths

let repoRoot: URL = {
    let script = URL(fileURLWithPath: CommandLine.arguments[0]).standardizedFileURL
    return script.deletingLastPathComponent().deletingLastPathComponent()
}()
let masterLogoURL = repoRoot.appendingPathComponent("Design/logo.png")
let assetsURL = repoRoot.appendingPathComponent("PortPilot/Resources/Assets.xcassets")
let docsImagesURL = repoRoot.appendingPathComponent("docs/images")

// MARK: - Design constants

/// Apple's macOS icon grid in 1024-px design units: an 824 × 824 continuous-corner body, radius 185.4.
enum Grid {
    static let canvas: CGFloat = 1024
    static let bodyInset: CGFloat = 100
    static let cornerRadiusRatio: CGFloat = 185.4 / 824
    /// Logo height as a fraction of the body height (optically balanced for the tall "PP" mark).
    static let logoHeightRatio: CGFloat = 0.64
}

func rgb(_ hex: UInt32, alpha: CGFloat = 1) -> CGColor {
    CGColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255, alpha: alpha)
}

// MARK: - Geometry

/// Rounded rectangle with continuous ("squircle") corners, like `RoundedRectangle(style: .continuous)`.
func continuousRoundedRect(_ rect: CGRect, cornerRadius: CGFloat) -> CGPath {
    let limit = min(rect.width, rect.height) / 2 / 1.52866483
    let r = min(cornerRadius, limit)
    let path = CGMutablePath()
    typealias Segment = (end: (CGFloat, CGFloat), c1: (CGFloat, CGFloat)?, c2: (CGFloat, CGFloat)?)
    let corner: [Segment] = [
        ((0.66993427, 0.06549600), (1.08849323, 0.0), (0.86840689, 0.0)),
        ((0.63149399, 0.07491100), nil, nil),
        ((0.07491176, 0.63149399), (0.37282392, 0.16905899), (0.16906013, 0.37282401)),
        ((0.0, 1.52866483), (0.0, 0.86840701), (0.0, 1.08849299)),
    ]
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

// MARK: - Bitmap helpers

func makeContext(_ width: Int, _ height: Int) throws -> CGContext {
    guard let space = CGColorSpace(name: CGColorSpace.sRGB),
          let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                              space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
        throw BrandError("could not create a \(width)×\(height) bitmap")
    }
    ctx.interpolationQuality = .high
    ctx.setShouldAntialias(true)
    return ctx
}

func loadImage(_ url: URL) throws -> CGImage {
    guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
          let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
        throw BrandError("could not read \(url.path)")
    }
    return image
}

/// Bounding box (in image pixel coordinates, origin top-left) of pixels with meaningful alpha.
func opaqueBounds(of image: CGImage, threshold: UInt8 = 8) throws -> CGRect {
    let w = image.width, h = image.height
    let ctx = try makeContext(w, h)
    ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
    guard let data = ctx.data else { throw BrandError("no bitmap data") }
    let bytes = data.bindMemory(to: UInt8.self, capacity: ctx.bytesPerRow * h)
    var minX = w, minY = h, maxX = -1, maxY = -1
    for row in 0..<h {
        let base = row * ctx.bytesPerRow
        for col in 0..<w where bytes[base + col * 4 + 3] > threshold {
            minX = min(minX, col); maxX = max(maxX, col)
            minY = min(minY, row); maxY = max(maxY, row)
        }
    }
    guard maxX >= minX else { throw BrandError("logo is fully transparent") }
    // Bitmap memory is laid out top row first, which matches CGImage.cropping(to:)'s top-left origin.
    return CGRect(x: minX, y: minY, width: maxX - minX + 1, height: maxY - minY + 1)
}

func writePNG(_ image: CGImage, to url: URL, dpi: Int = 72) throws {
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    guard let dest = CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil) else {
        throw BrandError("could not write \(url.path)")
    }
    CGImageDestinationAddImage(dest, image, [kCGImagePropertyDPIWidth: dpi, kCGImagePropertyDPIHeight: dpi] as CFDictionary)
    guard CGImageDestinationFinalize(dest) else { throw BrandError("could not finalize \(url.path)") }
}

func writeJSON(_ text: String, to url: URL) throws {
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try text.write(to: url, atomically: true, encoding: .utf8)
}

// MARK: - Renderers

/// The logo cropped to its opaque bounds.
func trimmedLogo() throws -> CGImage {
    let logo = try loadImage(masterLogoURL)
    let bounds = try opaqueBounds(of: logo)
    guard let cropped = logo.cropping(to: bounds) else { throw BrandError("crop failed") }
    return cropped
}

/// Draws `logo` scaled to `height`, centred at `center` (y-up context coordinates).
func draw(_ logo: CGImage, in ctx: CGContext, height: CGFloat, center: CGPoint) {
    let width = height * CGFloat(logo.width) / CGFloat(logo.height)
    ctx.draw(logo, in: CGRect(x: center.x - width / 2, y: center.y - height / 2, width: width, height: height))
}

func renderAppIcon(pixels: Int, logo: CGImage) throws -> CGImage {
    let ctx = try makeContext(pixels, pixels)
    let size = CGFloat(pixels)
    let unit = size / Grid.canvas
    let inset = pixels <= 16 ? 1 : (Grid.bodyInset * unit).rounded()
    let body = CGRect(x: inset, y: inset, width: size - 2 * inset, height: size - 2 * inset)
    let bodyPath = continuousRoundedRect(body, cornerRadius: body.width * Grid.cornerRadiusRatio)

    // Drop shadow (Apple template: ~10 units down, soft, ~28 % black).
    if pixels > 16 {
        ctx.saveGState()
        ctx.setShadow(offset: CGSize(width: 0, height: -10 * unit), blur: max(1, 24 * unit), color: rgb(0x0B1530, alpha: 0.28))
        ctx.addPath(bodyPath)
        ctx.setFillColor(rgb(0xF2F4F8))
        ctx.fillPath()
        ctx.restoreGState()
    }

    ctx.saveGState()
    ctx.addPath(bodyPath)
    ctx.clip()
    // Body: clean white → cool light grey, the logo's native background.
    let space = CGColorSpace(name: CGColorSpace.sRGB)!
    let gradient = CGGradient(colorsSpace: space, colors: [rgb(0xFFFFFF), rgb(0xF4F6FA), rgb(0xE6EAF2)] as CFArray,
                              locations: [0, 0.55, 1])!
    ctx.drawLinearGradient(gradient, start: CGPoint(x: body.midX, y: body.maxY), end: CGPoint(x: body.midX, y: body.minY),
                           options: [])

    // Logo with a whisper of depth.
    let logoHeight = body.height * Grid.logoHeightRatio
    ctx.saveGState()
    if pixels >= 128 {
        ctx.setShadow(offset: CGSize(width: 0, height: -6 * unit), blur: 18 * unit, color: rgb(0x0B1530, alpha: 0.16))
    }
    draw(logo, in: ctx, height: logoHeight, center: CGPoint(x: body.midX, y: body.midY))
    ctx.restoreGState()

    // Hairline rim so the white body reads on white desktops/Finder backgrounds.
    if pixels >= 32 {
        ctx.addPath(bodyPath)
        ctx.setStrokeColor(rgb(0x0B1530, alpha: 0.10))
        ctx.setLineWidth(max(1, 4 * unit))
        ctx.strokePath()
    }
    ctx.restoreGState()
    guard let image = ctx.makeImage() else { throw BrandError("icon snapshot failed") }
    return image
}

/// Logo on a transparent square canvas with even padding.
func renderLogo(pixels: Int, logo: CGImage, padding: CGFloat = 0.06) throws -> CGImage {
    let ctx = try makeContext(pixels, pixels)
    let size = CGFloat(pixels)
    draw(logo, in: ctx, height: size * (1 - 2 * padding), center: CGPoint(x: size / 2, y: size / 2))
    guard let image = ctx.makeImage() else { throw BrandError("logo snapshot failed") }
    return image
}

/// Template glyph: the logo silhouette in solid black on a menu-bar sized canvas (height 18 pt).
func renderMenuBarGlyph(scale: Int, logo: CGImage) throws -> CGImage {
    let glyphHeight: CGFloat = 15 * CGFloat(scale)
    let glyphWidth = (glyphHeight * CGFloat(logo.width) / CGFloat(logo.height)).rounded(.up)
    let height = 18 * scale
    let width = Int(glyphWidth) + 2 * scale
    let ctx = try makeContext(width, height)
    let rect = CGRect(x: (CGFloat(width) - glyphWidth) / 2, y: (CGFloat(height) - glyphHeight) / 2,
                      width: glyphWidth, height: glyphHeight)
    ctx.clip(to: rect, mask: logo)
    ctx.setFillColor(rgb(0x000000))
    ctx.fill(rect)
    guard let image = ctx.makeImage() else { throw BrandError("glyph snapshot failed") }
    return image
}

/// DMG window background (660 × 400 pt): soft gradient, the logo, and an arrow from the app icon slot
/// (x = 180) to the Applications slot (x = 480), both at y = 205 from the top.
func renderDMGBackground(scale: Int, logo: CGImage) throws -> CGImage {
    let width = 660 * scale, height = 400 * scale
    let s = CGFloat(scale)
    let ctx = try makeContext(width, height)
    let space = CGColorSpace(name: CGColorSpace.sRGB)!
    let gradient = CGGradient(colorsSpace: space, colors: [rgb(0xFFFFFF), rgb(0xF1F4FA), rgb(0xE4E9F3)] as CFArray,
                              locations: [0, 0.6, 1])!
    ctx.drawLinearGradient(gradient, start: CGPoint(x: 0, y: CGFloat(height)), end: CGPoint(x: 0, y: 0), options: [])

    // Brand mark, top-left.
    draw(logo, in: ctx, height: 30 * s, center: CGPoint(x: 42 * s, y: CGFloat(height) - 40 * s))
    let title = NSAttributedString(string: "PortPilot", attributes: [
        .font: NSFont.systemFont(ofSize: 17 * s, weight: .semibold),
        .foregroundColor: NSColor(srgbRed: 0.11, green: 0.13, blue: 0.19, alpha: 1)])
    let caption = NSAttributedString(string: "Drag PortPilot into Applications to install", attributes: [
        .font: NSFont.systemFont(ofSize: 13 * s, weight: .regular),
        .foregroundColor: NSColor(srgbRed: 0.33, green: 0.36, blue: 0.44, alpha: 1)])
    let graphics = NSGraphicsContext(cgContext: ctx, flipped: false)
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = graphics
    title.draw(at: CGPoint(x: 66 * s, y: CGFloat(height) - 51 * s))
    let captionSize = caption.size()
    caption.draw(at: CGPoint(x: (CGFloat(width) - captionSize.width) / 2, y: 62 * s))
    NSGraphicsContext.restoreGraphicsState()

    // Arrow between the two icon slots (y measured from the top in Finder → flip).
    let y = CGFloat(height) - 205 * s
    ctx.setStrokeColor(rgb(0x1D5BFF, alpha: 0.85))
    ctx.setLineWidth(5 * s)
    ctx.setLineCap(.round)
    ctx.setLineJoin(.round)
    ctx.move(to: CGPoint(x: 268 * s, y: y))
    ctx.addLine(to: CGPoint(x: 386 * s, y: y))
    ctx.strokePath()
    ctx.move(to: CGPoint(x: 370 * s, y: y + 15 * s))
    ctx.addLine(to: CGPoint(x: 390 * s, y: y))
    ctx.addLine(to: CGPoint(x: 370 * s, y: y - 15 * s))
    ctx.strokePath()
    guard let image = ctx.makeImage() else { throw BrandError("dmg background snapshot failed") }
    return image
}

// MARK: - Main

func run() throws {
    let logo = try trimmedLogo()
    let previewIndex = CommandLine.arguments.firstIndex(of: "--preview")

    // 1. App icon.
    let iconDir = assetsURL.appendingPathComponent("AppIcon.appiconset")
    if let old = try? FileManager.default.contentsOfDirectory(at: iconDir, includingPropertiesForKeys: nil) {
        for file in old where file.pathExtension == "png" { try FileManager.default.removeItem(at: file) }
    }
    let slots: [(points: Int, scale: Int)] = [(16, 1), (16, 2), (32, 1), (32, 2), (128, 1), (128, 2),
                                              (256, 1), (256, 2), (512, 1), (512, 2)]
    var rendered: [Int: CGImage] = [:]
    var images: [String] = []
    for slot in slots {
        let pixels = slot.points * slot.scale
        let image = try rendered[pixels] ?? renderAppIcon(pixels: pixels, logo: logo)
        rendered[pixels] = image
        let name = "icon_\(slot.points)x\(slot.points)\(slot.scale == 2 ? "@2x" : "").png"
        try writePNG(image, to: iconDir.appendingPathComponent(name), dpi: 72 * slot.scale)
        images.append("""
            { "filename" : "\(name)", "idiom" : "mac", "scale" : "\(slot.scale)x", "size" : "\(slot.points)x\(slot.points)" }
        """)
    }
    try writeJSON("{\n  \"images\" : [\n" + images.joined(separator: ",\n") +
                  "\n  ],\n  \"info\" : { \"author\" : \"xcode\", \"version\" : 1 }\n}\n",
                  to: iconDir.appendingPathComponent("Contents.json"))

    // 2. Full-colour logo (128 pt nominal).
    let logoDir = assetsURL.appendingPathComponent("Logo.imageset")
    for scale in 1...3 {
        try writePNG(try renderLogo(pixels: 128 * scale, logo: logo),
                     to: logoDir.appendingPathComponent("logo@\(scale)x.png"), dpi: 72 * scale)
    }
    try writeJSON("""
    {
      "images" : [
        { "filename" : "logo@1x.png", "idiom" : "universal", "scale" : "1x" },
        { "filename" : "logo@2x.png", "idiom" : "universal", "scale" : "2x" },
        { "filename" : "logo@3x.png", "idiom" : "universal", "scale" : "3x" }
      ],
      "info" : { "author" : "xcode", "version" : 1 }
    }

    """, to: logoDir.appendingPathComponent("Contents.json"))

    // 3. Menu bar template glyph.
    let glyphDir = assetsURL.appendingPathComponent("MenuBarIcon.imageset")
    for scale in 1...3 {
        try writePNG(try renderMenuBarGlyph(scale: scale, logo: logo),
                     to: glyphDir.appendingPathComponent("menubar@\(scale)x.png"), dpi: 72 * scale)
    }
    try writeJSON("""
    {
      "images" : [
        { "filename" : "menubar@1x.png", "idiom" : "universal", "scale" : "1x" },
        { "filename" : "menubar@2x.png", "idiom" : "universal", "scale" : "2x" },
        { "filename" : "menubar@3x.png", "idiom" : "universal", "scale" : "3x" }
      ],
      "info" : { "author" : "xcode", "version" : 1 },
      "properties" : { "template-rendering-intent" : "template" }
    }

    """, to: glyphDir.appendingPathComponent("Contents.json"))

    // 4. README artwork.
    if let icon = rendered[1024] {
        try writePNG(icon, to: docsImagesURL.appendingPathComponent("icon.png"))
    }
    try writePNG(try renderLogo(pixels: 512, logo: logo, padding: 0.02), to: docsImagesURL.appendingPathComponent("logo.png"))

    // 5. DMG background (1x + 2x; release.sh combines them into a HiDPI TIFF).
    let designURL = repoRoot.appendingPathComponent("Design")
    try writePNG(try renderDMGBackground(scale: 1, logo: logo), to: designURL.appendingPathComponent("dmg-background.png"))
    try writePNG(try renderDMGBackground(scale: 2, logo: logo), to: designURL.appendingPathComponent("dmg-background@2x.png"),
                 dpi: 144)

    // Optional contact sheet for eyeballing every size.
    if let index = previewIndex, index + 1 < CommandLine.arguments.count {
        let sizes = [1024, 512, 256, 128, 64, 32, 16]
        let sheetWidth = sizes.reduce(0) { $0 + $1 + 40 } + 40
        let ctx = try makeContext(sheetWidth, 1104)
        ctx.setFillColor(rgb(0xD8DCE3)); ctx.fill(CGRect(x: 0, y: 0, width: sheetWidth, height: 552))
        ctx.setFillColor(rgb(0x1E1F24)); ctx.fill(CGRect(x: 0, y: 552, width: sheetWidth, height: 552))
        var x = 40
        for pixels in sizes {
            let image = try rendered[pixels] ?? renderAppIcon(pixels: pixels, logo: logo)
            let shown = min(pixels, 472)
            ctx.draw(image, in: CGRect(x: x, y: 40, width: shown, height: shown))
            ctx.draw(image, in: CGRect(x: x, y: 592, width: shown, height: shown))
            x += shown + 40
        }
        let glyph = try renderMenuBarGlyph(scale: 2, logo: logo)
        ctx.draw(glyph, in: CGRect(x: x, y: 40, width: glyph.width * 4, height: glyph.height * 4))
        guard let sheet = ctx.makeImage() else { throw BrandError("sheet snapshot failed") }
        try writePNG(sheet, to: URL(fileURLWithPath: CommandLine.arguments[index + 1]))
    }
    print("Brand assets written to \(assetsURL.path) and \(docsImagesURL.path)")
}

do { try run() } catch {
    FileHandle.standardError.write(Data("make-brand-assets: \(error)\n".utf8))
    exit(1)
}
