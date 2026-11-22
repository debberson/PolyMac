// Draws the PolyMac app icon: three kymograph traces (breathing, skin, pulse) on a dark card.
// Usage: swift scripts/make-icon.swift <output.icns>
// Rerun only when the design changes; the result is committed as Resources/AppIcon.icns.
import AppKit

let output = URL(fileURLWithPath: CommandLine.arguments.dropFirst().first ?? "AppIcon.icns")

func drawIcon(size: CGFloat) -> NSBitmapImageRep {
    let pixels = Int(size)
    let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels, bitsPerSample: 8,
        samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
        bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let ctx = NSGraphicsContext.current!.cgContext
    let s = size / 1024  // design on a 1024 grid

    // macOS icon grid: 824pt card centred in 1024, continuous-corner radius ~185.
    let card = CGRect(x: 100 * s, y: 100 * s, width: 824 * s, height: 824 * s)
    let cardPath = CGPath(roundedRect: card, cornerWidth: 185 * s, cornerHeight: 185 * s, transform: nil)

    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -10 * s), blur: 28 * s, color: NSColor.black.withAlphaComponent(0.35).cgColor)
    ctx.addPath(cardPath)
    ctx.setFillColor(NSColor.black.cgColor)
    ctx.fillPath()
    ctx.restoreGState()

    ctx.saveGState()
    ctx.addPath(cardPath)
    ctx.clip()
    let background = CGGradient(
        colorsSpace: CGColorSpaceCreateDeviceRGB(),
        colors: [NSColor(red: 0.11, green: 0.13, blue: 0.19, alpha: 1).cgColor,
                 NSColor(red: 0.04, green: 0.05, blue: 0.08, alpha: 1).cgColor] as CFArray,
        locations: [0, 1])!
    ctx.drawLinearGradient(background, start: CGPoint(x: 0, y: card.maxY), end: CGPoint(x: 0, y: card.minY), options: [])

    // Faint chart-paper grid.
    ctx.setStrokeColor(NSColor.white.withAlphaComponent(0.06).cgColor)
    ctx.setLineWidth(3 * s)
    for i in 1..<8 {
        let x = card.minX + card.width * CGFloat(i) / 8
        ctx.move(to: CGPoint(x: x, y: card.minY)); ctx.addLine(to: CGPoint(x: x, y: card.maxY))
        let y = card.minY + card.height * CGFloat(i) / 8
        ctx.move(to: CGPoint(x: card.minX, y: y)); ctx.addLine(to: CGPoint(x: card.maxX, y: y))
    }
    ctx.strokePath()

    func trace(centerY: CGFloat, color: NSColor, _ wave: (CGFloat) -> CGFloat) {
        let path = CGMutablePath()
        let left = card.minX + 60 * s, right = card.maxX - 60 * s
        for step in 0...400 {
            let u = CGFloat(step) / 400
            let point = CGPoint(x: left + (right - left) * u, y: (centerY + wave(u)) * s)
            step == 0 ? path.move(to: point) : path.addLine(to: point)
        }
        ctx.saveGState()
        ctx.setShadow(offset: .zero, blur: 22 * s, color: color.withAlphaComponent(0.7).cgColor)
        ctx.addPath(path)
        ctx.setStrokeColor(color.cgColor)
        ctx.setLineWidth(30 * s)
        ctx.setLineCap(.round)
        ctx.setLineJoin(.round)
        ctx.strokePath()
        ctx.restoreGState()
    }

    // Breathing: slow sine.
    trace(centerY: 720, color: NSColor(red: 0.30, green: 0.62, blue: 1.00, alpha: 1)) { u in
        55 * sin(u * 2 * .pi * 2.2)
    }
    // Skin conductance: flat, then a skin response that rises and recovers.
    trace(centerY: 500, color: NSColor(red: 0.25, green: 0.85, blue: 0.48, alpha: 1)) { u in
        let t = u - 0.42
        return t < 0 ? -40 : -40 + 130 * (1 - exp(-t / 0.05)) * exp(-t / 0.28)
    }
    // Pulse: sharp systolic peaks.
    trace(centerY: 270, color: NSColor(red: 1.00, green: 0.33, blue: 0.36, alpha: 1)) { u in
        let beat = (u * 4.0).truncatingRemainder(dividingBy: 1)
        return -35 + 140 * exp(-pow((beat - 0.35) / 0.045, 2)) + 35 * exp(-pow((beat - 0.58) / 0.07, 2))
    }
    ctx.restoreGState()

    NSGraphicsContext.restoreGraphicsState()
    return rep
}

let iconset = FileManager.default.temporaryDirectory.appending(path: "PolyMac-\(UUID().uuidString).iconset")
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)
defer { try? FileManager.default.removeItem(at: iconset) }

for base in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let name = scale == 1 ? "icon_\(base)x\(base).png" : "icon_\(base)x\(base)@2x.png"
        let png = drawIcon(size: CGFloat(base * scale)).representation(using: .png, properties: [:])!
        try png.write(to: iconset.appending(path: name))
    }
}

let iconutil = Process()
iconutil.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
iconutil.arguments = ["-c", "icns", iconset.path, "-o", output.path]
try iconutil.run()
iconutil.waitUntilExit()
guard iconutil.terminationStatus == 0 else { fatalError("iconutil failed") }
print("Wrote \(output.path)")
