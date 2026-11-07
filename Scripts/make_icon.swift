// Renders the SwiftPulse app icon (rounded indigo gradient tile + white pulse line + prompt) into Resources/Assets.xcassets/AppIcon.appiconset.
// Run: swift Scripts/make_icon.swift
import AppKit

func draw(size: CGFloat) -> NSImage {
    let image = NSImage(size: NSSize(width: size, height: size))
    image.lockFocus()
    guard let ctx = NSGraphicsContext.current?.cgContext else { return image }
    let s = size
    // macOS icon grid: tile occupies ~80% with soft shadow
    let inset = s * 0.10
    let tile = CGRect(x: inset, y: inset, width: s - 2 * inset, height: s - 2 * inset)
    let radius = tile.width * 0.225
    let path = NSBezierPath(roundedRect: tile, xRadius: radius, yRadius: radius)

    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -s * 0.012), blur: s * 0.03, color: NSColor.black.withAlphaComponent(0.35).cgColor)
    NSColor(calibratedRed: 0.36, green: 0.31, blue: 0.91, alpha: 1).setFill()
    path.fill()
    ctx.restoreGState()

    // gradient fill
    path.addClip()
    let gradient = NSGradient(colors: [
        NSColor(calibratedRed: 0.47, green: 0.40, blue: 1.00, alpha: 1),
        NSColor(calibratedRed: 0.33, green: 0.27, blue: 0.86, alpha: 1),
        NSColor(calibratedRed: 0.20, green: 0.16, blue: 0.55, alpha: 1),
    ])!
    gradient.draw(in: tile, angle: -60)

    // subtle top highlight
    let highlight = NSGradient(colors: [NSColor.white.withAlphaComponent(0.18), NSColor.white.withAlphaComponent(0)])!
    highlight.draw(in: CGRect(x: tile.minX, y: tile.midY, width: tile.width, height: tile.height / 2), angle: 90)

    // faint grid lines (monitoring feel)
    NSColor.white.withAlphaComponent(0.07).setStroke()
    for i in 1..<6 {
        let y = tile.minY + tile.height * CGFloat(i) / 6
        let line = NSBezierPath(); line.move(to: CGPoint(x: tile.minX, y: y)); line.line(to: CGPoint(x: tile.maxX, y: y))
        line.lineWidth = s * 0.004; line.stroke()
    }

    // pulse waveform
    let w = tile.width, h = tile.height, x0 = tile.minX, midY = tile.midY + h * 0.02
    let pts: [(CGFloat, CGFloat)] = [
        (0.08, 0), (0.28, 0), (0.34, 0.06), (0.40, -0.06), (0.46, 0.30), (0.53, -0.34), (0.59, 0.10), (0.64, 0), (0.92, 0),
    ]
    let pulse = NSBezierPath()
    pulse.lineCapStyle = .round; pulse.lineJoinStyle = .round
    for (i, p) in pts.enumerated() {
        let pt = CGPoint(x: x0 + w * p.0, y: midY + h * p.1)
        i == 0 ? pulse.move(to: pt) : pulse.line(to: pt)
    }
    ctx.saveGState()
    ctx.setShadow(offset: .zero, blur: s * 0.03, color: NSColor.white.withAlphaComponent(0.7).cgColor)
    NSColor.white.setStroke()
    pulse.lineWidth = s * 0.055
    pulse.stroke()
    ctx.restoreGState()

    // terminal prompt glyph bottom-left: "›_"
    let prompt = NSBezierPath()
    let px = x0 + w * 0.16, py = tile.minY + h * 0.20, ps = h * 0.09
    prompt.move(to: CGPoint(x: px, y: py + ps)); prompt.line(to: CGPoint(x: px + ps * 0.8, y: py + ps * 0.5)); prompt.line(to: CGPoint(x: px, y: py))
    prompt.move(to: CGPoint(x: px + ps * 1.15, y: py)); prompt.line(to: CGPoint(x: px + ps * 2.0, y: py))
    prompt.lineWidth = s * 0.03; prompt.lineCapStyle = .round; prompt.lineJoinStyle = .round
    NSColor.white.withAlphaComponent(0.85).setStroke()
    prompt.stroke()

    image.unlockFocus()
    return image
}

func png(_ image: NSImage, pixels: Int) -> Data {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels, bitsPerSample: 8, samplesPerPixel: 4,
                               hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    rep.size = NSSize(width: pixels, height: pixels)
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    NSGraphicsContext.current?.imageInterpolation = .high
    image.draw(in: NSRect(x: 0, y: 0, width: pixels, height: pixels))
    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

let dir = URL(fileURLWithPath: "Resources/Assets.xcassets/AppIcon.appiconset")
try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
let sizes = [16, 32, 128, 256, 512]
var images: [[String: String]] = []
for base in sizes {
    for scale in [1, 2] {
        let px = base * scale
        let name = "icon_\(base)x\(base)\(scale == 2 ? "@2x" : "").png"
        let img = draw(size: CGFloat(px))
        try png(img, pixels: px).write(to: dir.appendingPathComponent(name))
        images.append(["idiom": "mac", "scale": "\(scale)x", "size": "\(base)x\(base)", "filename": name])
    }
}
let json = try JSONSerialization.data(withJSONObject: ["images": images, "info": ["author": "xcode", "version": 1]], options: [.prettyPrinted, .sortedKeys])
try json.write(to: dir.appendingPathComponent("Contents.json"))
try png(draw(size: 1024), pixels: 1024).write(to: URL(fileURLWithPath: "Scripts/assets/icon-1024.png"))
print("icon set written")
