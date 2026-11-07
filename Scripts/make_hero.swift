// Renders .github/images/hero.png: gradient backdrop, app icon, title/tagline and the dashboard screenshot.
// Run: swift Scripts/make_hero.swift   (after `swift Scripts/make_icon.swift`)
import AppKit

let W: CGFloat = 1600, H: CGFloat = 1000
let icon = NSImage(contentsOfFile: "Scripts/assets/icon-1024.png")!
let shot = NSImage(contentsOfFile: ".github/images/dashboard.png")!

let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(W), pixelsHigh: Int(H), bitsPerSample: 8, samplesPerPixel: 4,
                           hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
let ctx = NSGraphicsContext.current!.cgContext
ctx.setAllowsAntialiasing(true)

// backdrop
NSGradient(colors: [NSColor(srgbRed: 0.13, green: 0.11, blue: 0.32, alpha: 1), NSColor(srgbRed: 0.36, green: 0.31, blue: 0.91, alpha: 1), NSColor(srgbRed: 0.55, green: 0.47, blue: 1.0, alpha: 1)])!
    .draw(in: NSRect(x: 0, y: 0, width: W, height: H), angle: 35)
// soft light blobs
for (x, y, r, a) in [(1300.0, 850.0, 420.0, 0.18), (250.0, 120.0, 380.0, 0.12)] {
    let g = NSGradient(colors: [NSColor.white.withAlphaComponent(a), NSColor.white.withAlphaComponent(0)])!
    g.draw(in: NSBezierPath(ovalIn: NSRect(x: x - r, y: y - r, width: 2 * r, height: 2 * r)), relativeCenterPosition: .zero)
}
// faint pulse line across the top
let pulse = NSBezierPath(); pulse.lineWidth = 6; pulse.lineCapStyle = .round; pulse.lineJoinStyle = .round
let pts: [(CGFloat, CGFloat)] = [(0, 0), (0.30, 0), (0.33, 0.03), (0.36, -0.03), (0.39, 0.16), (0.42, -0.18), (0.45, 0.05), (0.47, 0), (1, 0)]
for (i, p) in pts.enumerated() { let pt = CGPoint(x: p.0 * W, y: 930 + p.1 * 200); i == 0 ? pulse.move(to: pt) : pulse.line(to: pt) }
NSColor.white.withAlphaComponent(0.25).setStroke(); pulse.stroke()

// icon + title
icon.draw(in: NSRect(x: 110, y: H - 290, width: 190, height: 190))
func text(_ s: String, size: CGFloat, weight: NSFont.Weight, color: NSColor, at p: CGPoint) {
    let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: size, weight: weight), .foregroundColor: color]
    NSAttributedString(string: s, attributes: attrs).draw(at: p)
}
text("SwiftPulse", size: 84, weight: .bold, color: .white, at: CGPoint(x: 320, y: H - 215))
text("Server monitoring, SSH terminal, SFTP and tunnels for macOS", size: 30, weight: .medium, color: NSColor.white.withAlphaComponent(0.85), at: CGPoint(x: 324, y: H - 265))
text("Live dashboards · Terminal · SFTP · Port forwarding · Docker · Snippets", size: 22, weight: .regular, color: NSColor.white.withAlphaComponent(0.7), at: CGPoint(x: 324, y: H - 305))

// screenshot card with shadow
let shotW: CGFloat = 1120
let shotRect = NSRect(x: (W - shotW) / 2, y: -220, width: shotW, height: shotW * shot.size.height / shot.size.width)
ctx.saveGState()
ctx.setShadow(offset: CGSize(width: 0, height: -12), blur: 40, color: NSColor.black.withAlphaComponent(0.45).cgColor)
NSBezierPath(roundedRect: shotRect, xRadius: 18, yRadius: 18).addClip()
shot.draw(in: shotRect)
ctx.restoreGState()

NSGraphicsContext.restoreGraphicsState()
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: ".github/images/hero.png"))
print("hero written")
