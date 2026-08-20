#!/usr/bin/env swift
// Renders Resources/AppIcon.icns from code.
//
// Kept as a script rather than a checked-in binary so the artwork can be
// tweaked and regenerated: run `swift Scripts/make-icon.swift`.

import AppKit
import Foundation

let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
let iconset = root.appendingPathComponent("build/AppIcon.iconset")
try? FileManager.default.removeItem(at: iconset)
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)

/// macOS icons are a superellipse ("squircle"), not a rounded rectangle — a plain
/// corner radius reads subtly wrong next to the system's own icons.
func squircle(in rect: CGRect) -> NSBezierPath {
    let path = NSBezierPath()
    let n = 5.0
    let a = rect.width / 2, b = rect.height / 2
    let cx = rect.midX, cy = rect.midY
    let steps = 720
    for step in 0...steps {
        let t = Double(step) / Double(steps) * 2 * .pi
        let cosT = cos(t), sinT = sin(t)
        let x = cx + a * pow(abs(cosT), 2 / n) * (cosT < 0 ? -1 : 1)
        let y = cy + b * pow(abs(sinT), 2 / n) * (sinT < 0 ? -1 : 1)
        if step == 0 { path.move(to: CGPoint(x: x, y: y)) } else { path.line(to: CGPoint(x: x, y: y)) }
    }
    path.close()
    return path
}

func card(_ rect: CGRect, radius: CGFloat) -> NSBezierPath {
    NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius)
}

func render(size: CGFloat) -> NSImage {
    let image = NSImage(size: NSSize(width: size, height: size))
    image.lockFocus()
    guard let ctx = NSGraphicsContext.current?.cgContext else { fatalError("no context") }
    ctx.setShouldAntialias(true)
    NSGraphicsContext.current?.imageInterpolation = .high

    let u = size / 1024  // design in 1024pt units, scale down

    // Apple leaves the outer ~10% clear so icons optically match in a row.
    let body = CGRect(x: 100 * u, y: 90 * u, width: 824 * u, height: 824 * u)
    let shape = squircle(in: body)

    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -14 * u), blur: 34 * u,
                  color: NSColor.black.withAlphaComponent(0.34).cgColor)
    NSColor.black.setFill()
    shape.fill()
    ctx.restoreGState()

    ctx.saveGState()
    shape.addClip()

    let gradient = NSGradient(colors: [
        NSColor(srgbRed: 0.36, green: 0.53, blue: 1.00, alpha: 1),
        NSColor(srgbRed: 0.22, green: 0.31, blue: 0.86, alpha: 1),
        NSColor(srgbRed: 0.16, green: 0.18, blue: 0.55, alpha: 1)
    ], atLocations: [0, 0.55, 1], colorSpace: .sRGB)!
    gradient.draw(in: body, angle: -90)

    // Soft top-left sheen, the cue that reads as "glass" at small sizes.
    let sheen = NSGradient(starting: NSColor.white.withAlphaComponent(0.30),
                           ending: NSColor.white.withAlphaComponent(0.0))!
    sheen.draw(in: CGRect(x: body.minX, y: body.midY, width: body.width, height: body.height / 2),
               angle: -90)

    // The product itself: a strip of window previews down the left edge, and the
    // focused window brought forward beside it.
    let stripX = body.minX + 92 * u
    let stripW = 150 * u
    let cardH = 116 * u
    let gap = 34 * u
    let stackH = cardH * 3 + gap * 2
    var y = body.midY + stackH / 2 - cardH

    for index in 0..<3 {
        let rect = CGRect(x: stripX, y: y, width: stripW, height: cardH)
        ctx.saveGState()
        ctx.setShadow(offset: CGSize(width: 0, height: -4 * u), blur: 12 * u,
                      color: NSColor.black.withAlphaComponent(0.25).cgColor)
        NSColor.white.withAlphaComponent(index == 1 ? 0.95 : 0.55).setFill()
        card(rect, radius: 26 * u).fill()
        ctx.restoreGState()
        y -= cardH + gap
    }

    let focused = CGRect(x: stripX + stripW + 74 * u, y: body.midY - 214 * u,
                         width: 344 * u, height: 428 * u)
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -18 * u), blur: 40 * u,
                  color: NSColor.black.withAlphaComponent(0.42).cgColor)
    NSColor.white.withAlphaComponent(0.97).setFill()
    card(focused, radius: 48 * u).fill()
    ctx.restoreGState()

    // Title bar, so the shape reads as a window rather than a blank slab.
    ctx.saveGState()
    card(focused, radius: 48 * u).addClip()
    NSColor(srgbRed: 0.86, green: 0.88, blue: 0.94, alpha: 1).setFill()
    CGRect(x: focused.minX, y: focused.maxY - 74 * u, width: focused.width, height: 74 * u).fill()
    let dots: [NSColor] = [
        NSColor(srgbRed: 0.99, green: 0.37, blue: 0.34, alpha: 1),
        NSColor(srgbRed: 0.99, green: 0.74, blue: 0.18, alpha: 1),
        NSColor(srgbRed: 0.23, green: 0.79, blue: 0.25, alpha: 1)
    ]
    for (index, colour) in dots.enumerated() {
        colour.setFill()
        let d = 24 * u
        let rect = CGRect(x: focused.minX + 26 * u + CGFloat(index) * (d + 14 * u),
                          y: focused.maxY - 49 * u, width: d, height: d)
        NSBezierPath(ovalIn: rect).fill()
    }
    ctx.restoreGState()

    // Hairline rim: the edge definition system icons have against dark wallpaper.
    NSColor.white.withAlphaComponent(0.22).setStroke()
    shape.lineWidth = 3 * u
    shape.stroke()

    ctx.restoreGState()
    image.unlockFocus()
    return image
}

func write(_ image: NSImage, to url: URL, pixels: Int) throws {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels,
                              bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                              isPlanar: false, colorSpaceName: .deviceRGB,
                              bytesPerRow: 0, bitsPerPixel: 0)!
    rep.size = NSSize(width: pixels, height: pixels)
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    image.draw(in: CGRect(x: 0, y: 0, width: pixels, height: pixels))
    NSGraphicsContext.restoreGraphicsState()
    try rep.representation(using: .png, properties: [:])!.write(to: url)
}

// Each size is rendered fresh rather than downscaled from 1024, so small sizes
// keep crisp edges instead of turning to mush.
for (points, scale) in [(16, 1), (16, 2), (32, 1), (32, 2), (128, 1), (128, 2),
                        (256, 1), (256, 2), (512, 1), (512, 2)] {
    let pixels = points * scale
    let image = render(size: CGFloat(pixels))
    let suffix = scale == 2 ? "@2x" : ""
    let url = iconset.appendingPathComponent("icon_\(points)x\(points)\(suffix).png")
    try write(image, to: url, pixels: pixels)
}

let convert = Process()
convert.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
convert.arguments = ["-c", "icns", iconset.path,
                     "-o", root.appendingPathComponent("Resources/AppIcon.icns").path]
try convert.run()
convert.waitUntilExit()
guard convert.terminationStatus == 0 else { exit(convert.terminationStatus) }
print("==> Wrote Resources/AppIcon.icns")
