import AppKit
import SwiftTerm

/// Terminal palette + font settings (AppStorage keys: terminalFontName, terminalFontSize, terminalTheme).
struct TerminalTheme: Identifiable, Hashable {
    let name: String
    let background: NSColor, foreground: NSColor, cursor: NSColor
    let ansi: [NSColor] // 16 colors
    var id: String { name }
    var isDark: Bool { background.usingColorSpace(.deviceRGB).map { $0.brightnessComponent < 0.5 } ?? false }

    static let light = TerminalTheme(
        name: "SwiftPulse Light",
        background: NSColor(white: 1, alpha: 1), foreground: NSColor(white: 0.13, alpha: 1), cursor: NSColor(srgbRed: 0.36, green: 0.31, blue: 0.91, alpha: 1),
        ansi: hex(["1c1c1c", "d64545", "3aa655", "c9a000", "3d62d6", "8a4bd6", "1f9aa8", "e5e5e5",
                   "555555", "ff6b6b", "4fd66d", "ffd23f", "6d8dff", "b57bff", "3cc5d6", "ffffff"]))
    static let dark = TerminalTheme(
        name: "SwiftPulse Dark",
        background: NSColor(srgbRed: 0.11, green: 0.11, blue: 0.13, alpha: 1), foreground: NSColor(white: 0.92, alpha: 1), cursor: NSColor(srgbRed: 0.55, green: 0.5, blue: 1, alpha: 1),
        ansi: hex(["2b2b2f", "ff6b6b", "4fd66d", "ffd23f", "6d8dff", "b57bff", "3cc5d6", "d0d0d0",
                   "6b6b70", "ff8787", "7ee69a", "ffe27a", "9db2ff", "cfa3ff", "7fdbe6", "ffffff"]))
    static let all = [light, dark]

    static var current: TerminalTheme {
        let name = UserDefaults.standard.string(forKey: "terminalTheme")
        if let t = all.first(where: { $0.name == name }) { return t }
        return NSApp.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? dark : light
    }

    static func apply(to view: TerminalView) {
        let theme = current
        let size = CGFloat(UserDefaults.standard.object(forKey: "terminalFontSize") as? Double ?? 12)
        let fontName = UserDefaults.standard.string(forKey: "terminalFontName") ?? "Menlo"
        view.font = NSFont(name: fontName, size: size) ?? NSFont.monospacedSystemFont(ofSize: size, weight: .regular)
        view.nativeBackgroundColor = theme.background
        view.nativeForegroundColor = theme.foreground
        view.caretColor = theme.cursor
        view.installColors(theme.ansi.map { c in
            let rgb = c.usingColorSpace(.deviceRGB) ?? c
            return SwiftTerm.Color(red: UInt16(rgb.redComponent * 65535), green: UInt16(rgb.greenComponent * 65535), blue: UInt16(rgb.blueComponent * 65535))
        })
        switch UserDefaults.standard.string(forKey: "terminalCursor") ?? "block" {
        case "underline": view.getTerminal().setCursorStyle(.steadyUnderline)
        case "bar": view.getTerminal().setCursorStyle(.steadyBar)
        default: view.getTerminal().setCursorStyle(UserDefaults.standard.bool(forKey: "terminalCursorBlink") ? .blinkBlock : .steadyBlock)
        }
    }

    private static func hex(_ values: [String]) -> [NSColor] {
        values.map { h in
            let v = UInt32(h, radix: 16) ?? 0
            return NSColor(srgbRed: CGFloat((v >> 16) & 0xff) / 255, green: CGFloat((v >> 8) & 0xff) / 255, blue: CGFloat(v & 0xff) / 255, alpha: 1)
        }
    }
}
