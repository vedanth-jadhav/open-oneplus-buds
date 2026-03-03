import AppKit
import Foundation

let outDir = URL(fileURLWithPath: CommandLine.arguments.dropFirst().first ?? "")
guard !outDir.path.isEmpty else {
    fputs("Usage: render_app_icon.swift <path-to-iconset-dir>\n", stderr)
    exit(2)
}

struct RGB {
    let r: CGFloat
    let g: CGFloat
    let b: CGFloat
    let a: CGFloat

    init(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat, _ a: CGFloat = 1.0) {
        self.r = r; self.g = g; self.b = b; self.a = a
    }

    var color: NSColor { NSColor(srgbRed: r, green: g, blue: b, alpha: a) }
}

func writePNG(_ image: NSImage, to url: URL) throws {
    guard let tiff = image.tiffRepresentation,
          let rep = NSBitmapImageRep(data: tiff),
          let png = rep.representation(using: .png, properties: [:]) else {
        throw NSError(domain: "IconRender", code: 1)
    }
    try png.write(to: url, options: .atomic)
}

func renderIcon(size: Int) throws -> NSImage {
    let image = NSImage(size: NSSize(width: size, height: size))
    image.lockFocusFlipped(false)
    defer { image.unlockFocus() }

    let rect = NSRect(x: 0, y: 0, width: size, height: size)
    let corner = CGFloat(size) * 0.223
    let path = NSBezierPath(roundedRect: rect.insetBy(dx: 2, dy: 2), xRadius: corner, yRadius: corner)

    NSGraphicsContext.current?.imageInterpolation = .high
    NSGraphicsContext.current?.shouldAntialias = true

    // Calm, slightly “glass” background: light gradient + soft highlight.
    let top = RGB(0.95, 0.96, 0.97).color
    let bottom = RGB(0.84, 0.86, 0.89).color
    NSGradient(starting: top, ending: bottom)?.draw(in: path, angle: 90)

    // Inner highlight
    let highlight = NSBezierPath(roundedRect: rect.insetBy(dx: 3.5, dy: 3.5), xRadius: corner * 0.92, yRadius: corner * 0.92)
    RGB(1, 1, 1, 0.35).color.setStroke()
    highlight.lineWidth = max(1, CGFloat(size) * 0.004)
    highlight.stroke()

    // Subtle outer stroke for definition on light wallpapers.
    RGB(0, 0, 0, 0.08).color.setStroke()
    path.lineWidth = max(1, CGFloat(size) * 0.004)
    path.stroke()

    // Foreground symbol
    let pointSize = CGFloat(size) * 0.56
    let config = NSImage.SymbolConfiguration(pointSize: pointSize, weight: .semibold)
    let symbolName = NSImage(systemSymbolName: "airpods", accessibilityDescription: nil) != nil ? "airpods" : "earbuds"
    let symbol = NSImage(systemSymbolName: symbolName, accessibilityDescription: nil)?
        .withSymbolConfiguration(config)

    if let symbol {
        let symbolRect = NSRect(
            x: (rect.width - pointSize) / 2,
            y: (rect.height - pointSize) / 2 - CGFloat(size) * 0.02,
            width: pointSize,
            height: pointSize
        )

        // Slight depth without looking “designed by AI”.
        let shadow = NSShadow()
        shadow.shadowOffset = NSSize(width: 0, height: -CGFloat(size) * 0.01)
        shadow.shadowBlurRadius = CGFloat(size) * 0.03
        shadow.shadowColor = RGB(0, 0, 0, 0.10).color

        NSGraphicsContext.saveGraphicsState()
        shadow.set()
        RGB(0.08, 0.10, 0.12, 0.88).color.set()
        symbol.draw(in: symbolRect)
        NSGraphicsContext.restoreGraphicsState()
    }

    return image
}

func writeIconFiles() throws {
    // Standard macOS iconset sizes:
    // 16, 32, 128, 256, 512 plus @2x variants.
    for base in [16, 32, 128, 256, 512] {
        let img1 = try renderIcon(size: base)
        try writePNG(img1, to: outDir.appendingPathComponent("icon_\(base)x\(base).png"))

        let img2 = try renderIcon(size: base * 2)
        try writePNG(img2, to: outDir.appendingPathComponent("icon_\(base)x\(base)@2x.png"))
    }
}

do {
    try FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)
    try writeIconFiles()
} catch {
    fputs("Failed to render iconset: \(error)\n", stderr)
    exit(1)
}
