// Renders the app icon PNGs into an .iconset directory: `swift Scripts/make_icon.swift <out.iconset>`.
import AppKit

let out = URL(fileURLWithPath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "AppIcon.iconset")
try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)

func render(_ px: Int) -> Data {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px, bitsPerSample: 8, samplesPerPixel: 4,
                               hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let s = CGFloat(px)
    let inset = s * 0.1
    let tile = NSRect(x: inset, y: inset, width: s - inset * 2, height: s - inset * 2)
    let gradient = NSGradient(starting: NSColor(srgbRed: 0.12, green: 0.13, blue: 0.17, alpha: 1),
                              ending: NSColor(srgbRed: 0.05, green: 0.05, blue: 0.07, alpha: 1))!
    gradient.draw(in: NSBezierPath(roundedRect: tile, xRadius: tile.width * 0.22, yRadius: tile.width * 0.22), angle: -90)
    // Two usage bars, like the menu bar title (5h on top, 7d below).
    let barW = tile.width * 0.62, barH = tile.height * 0.11, x = tile.midX - barW / 2
    let bars: [(CGFloat, NSColor)] = [(0.45, NSColor(srgbRed: 0.19, green: 0.82, blue: 0.35, alpha: 1)),
                                      (0.78, NSColor(srgbRed: 1.0, green: 0.62, blue: 0.04, alpha: 1))]
    for (i, (fill, color)) in bars.enumerated() {
        let y = tile.midY + (i == 0 ? barH * 0.6 : -barH * 1.6)
        NSColor.white.withAlphaComponent(0.18).setFill()
        NSBezierPath(roundedRect: NSRect(x: x, y: y, width: barW, height: barH), xRadius: barH / 2, yRadius: barH / 2).fill()
        color.setFill()
        NSBezierPath(roundedRect: NSRect(x: x, y: y, width: barW * fill, height: barH), xRadius: barH / 2, yRadius: barH / 2).fill()
    }
    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

for size in [16, 32, 128, 256, 512] {
    try render(size).write(to: out.appendingPathComponent("icon_\(size)x\(size).png"))
    try render(size * 2).write(to: out.appendingPathComponent("icon_\(size)x\(size)@2x.png"))
}
