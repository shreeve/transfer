// Renders the Transfer app icon at every macOS size from the design in Support/AppIcon.svg: a page
// with a yellow badge whose arrow points up and out, on a cyan-to-deep-blue tile. Drawn from the
// same shapes as the SVG so the mark is reproducible from source. High contrast on purpose: a
// white page and a yellow badge survive at 16 pixels, where the pastel icon before it washed out.
//
// Usage: swift Support/render-icon.swift
// Writes Support/AppIcon.icns, the only icon file the app bundle needs. The iconset it is made
// from is drawn in a temporary folder.

import AppKit

let support = URL(fileURLWithPath: CommandLine.arguments[0]).deletingLastPathComponent()

func rgb(_ hex: UInt32, _ alpha: CGFloat = 1) -> NSColor {
    NSColor(srgbRed: CGFloat((hex >> 16) & 0xff) / 255, green: CGFloat((hex >> 8) & 0xff) / 255, blue: CGFloat(hex & 0xff) / 255, alpha: alpha)
}

let tileTop = rgb(0x00AADD)
let tileBottom = rgb(0x004499)
let page = rgb(0xF6F8FA)
let fold = rgb(0xC3D3E4)
let lines = rgb(0xAFC2D8)
let yellow = rgb(0xFFD61F)
let ink = rgb(0x0346A6)

/// A drop shadow as the SVG gives it: `dy` down and a Gaussian `sigma`, in SVG points. AppKit
/// takes shadows in device pixels, untouched by the drawing transform, so they are scaled here.
func shadow(dy: CGFloat, sigma: CGFloat, scale: CGFloat) {
    let shadow = NSShadow()
    shadow.shadowBlurRadius = sigma * 2 * scale
    shadow.shadowOffset = NSSize(width: 0, height: -dy * scale)
    shadow.shadowColor = NSColor.black.withAlphaComponent(0.25)
    shadow.set()
}

func p(_ x: CGFloat, _ y: CGFloat) -> NSPoint { NSPoint(x: x, y: y) }

func draw(_ s: CGFloat) {
    // Work in the SVG's points: the 824-point tile at (100, 100) on the 1024 canvas, y down.
    let scale = s / 1024
    let transform = NSAffineTransform()
    transform.translateX(by: 0, yBy: s)
    transform.scaleX(by: scale, yBy: -scale)
    transform.translateX(by: 100, yBy: 100)
    transform.concat()

    // The tile, with a faint sheen over its top half.
    let tile = NSBezierPath(roundedRect: NSRect(x: 0, y: 0, width: 824, height: 824), xRadius: 185.4, yRadius: 185.4)
    NSGraphicsContext.saveGraphicsState()
    tile.addClip()
    NSGradient(starting: tileTop, ending: tileBottom)?.draw(from: p(0, 0), to: p(0, 824), options: [])
    NSGradient(starting: rgb(0xFFFFFF, 0.08), ending: rgb(0xFFFFFF, 0))?.draw(from: p(0, 0), to: p(0, 412), options: [])
    NSGraphicsContext.restoreGraphicsState()

    // The page, its folded corner, and, where there is room for them, three lines of text.
    let sheet = NSBezierPath()
    sheet.move(to: p(245.64, 157))
    sheet.line(to: p(490.86, 157))
    sheet.line(to: p(609.52, 275.66))
    sheet.appendArc(from: p(609.52, 667.88), to: p(214, 667.88), radius: 31.64)
    sheet.appendArc(from: p(214, 667.88), to: p(214, 157), radius: 31.64)
    sheet.appendArc(from: p(214, 157), to: p(490.86, 157), radius: 31.64)
    sheet.close()
    NSGraphicsContext.saveGraphicsState()
    shadow(dy: 10, sigma: 15, scale: scale)
    page.setFill()
    sheet.fill()
    NSGraphicsContext.restoreGraphicsState()
    let flap = NSBezierPath()
    flap.move(to: p(490.86, 157))
    flap.line(to: p(490.86, 275.66))
    flap.line(to: p(609.52, 275.66))
    flap.close()
    fold.setFill()
    flap.fill()
    if s >= 128 {
        lines.setFill()
        for (y, width) in [(312.82, 221.49), (384.34, 221.49), (455.86, 150.30)] as [(CGFloat, CGFloat)] {
            NSBezierPath(roundedRect: NSRect(x: 277.28, y: y, width: width, height: 28.10), xRadius: 14.05, yRadius: 14.05).fill()
        }
    }

    // The badge: a yellow disc over the page's corner, its arrow pointing up and out.
    NSGraphicsContext.saveGraphicsState()
    shadow(dy: 20, sigma: 50, scale: scale)
    yellow.setFill()
    NSBezierPath(ovalIn: NSRect(x: 609.76 - 164.8, y: 591.52 - 164.8, width: 329.6, height: 329.6)).fill()
    NSGraphicsContext.restoreGraphicsState()
    ink.set()
    let shaft = NSBezierPath()
    shaft.move(to: p(537.253, 664.027))
    shaft.line(to: p(635.003, 566.276))
    shaft.lineWidth = 42.85
    shaft.lineCapStyle = .round
    shaft.stroke()
    let head = NSBezierPath()
    head.move(to: p(685.901, 515.379))
    head.line(to: p(561.825, 518.568))
    head.line(to: p(682.712, 639.455))
    head.close()
    head.lineWidth = 15
    head.lineJoinStyle = .round
    head.fill()
    head.stroke()
}

func png(_ px: Int) -> Data {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px, bitsPerSample: 8, samplesPerPixel: 4,
                               hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        .retagging(with: .sRGB)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    draw(CGFloat(px))
    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

let scratch = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
let iconset = scratch.appendingPathComponent("AppIcon.iconset", isDirectory: true)
defer { try? FileManager.default.removeItem(at: scratch) }
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)
for points in [16, 32, 128, 256, 512] {
    try png(points).write(to: iconset.appendingPathComponent("icon_\(points)x\(points).png"))
    try png(points * 2).write(to: iconset.appendingPathComponent("icon_\(points)x\(points)@2x.png"))
}

let icns = support.appendingPathComponent("AppIcon.icns")
let iconutil = Process()
iconutil.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
iconutil.arguments = ["-c", "icns", iconset.path, "-o", icns.path]
try iconutil.run()
iconutil.waitUntilExit()
guard iconutil.terminationStatus == 0 else { fatalError("iconutil failed") }
print("wrote \(icns.path)")
