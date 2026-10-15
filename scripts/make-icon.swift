// Renders the Fala app icon into an .iconset. Usage: swift make-icon.swift <out.iconset>
import AppKit

let out = URL(fileURLWithPath: CommandLine.arguments[1])
try? FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)

func render(_ px: Int) -> Data {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px, bitsPerSample: 8, samplesPerPixel: 4,
                               hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let s = CGFloat(px) / 1024
    let ctx = NSGraphicsContext.current!.cgContext
    ctx.scaleBy(x: s, y: s)

    // Squircle body following the macOS icon grid (824pt body, 100pt margin).
    let body = CGRect(x: 100, y: 100, width: 824, height: 824)
    let path = NSBezierPath(roundedRect: body, xRadius: 185, yRadius: 185)

    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -12), blur: 28, color: NSColor.black.withAlphaComponent(0.35).cgColor)
    NSColor.black.setFill(); path.fill()
    ctx.restoreGState()

    path.addClip()
    let gradient = NSGradient(colors: [
        NSColor(red: 0.30, green: 0.32, blue: 0.98, alpha: 1),
        NSColor(red: 0.58, green: 0.36, blue: 0.98, alpha: 1),
        NSColor(red: 0.96, green: 0.40, blue: 0.72, alpha: 1),
    ])!
    gradient.draw(in: body, angle: -55)

    // Soft glass highlight.
    let glow = NSGradient(colors: [NSColor.white.withAlphaComponent(0.38), NSColor.white.withAlphaComponent(0)])!
    glow.draw(in: NSBezierPath(ovalIn: CGRect(x: 40, y: 520, width: 944, height: 560)), relativeCenterPosition: NSPoint(x: 0, y: 0.4))

    // Waveform bars.
    let heights: [CGFloat] = [150, 270, 420, 300, 470, 330, 200]
    let w: CGFloat = 58, gap: CGFloat = 34
    let total = CGFloat(heights.count) * w + CGFloat(heights.count - 1) * gap
    var x = 512 - total / 2
    ctx.setShadow(offset: CGSize(width: 0, height: -6), blur: 18, color: NSColor(red: 0.2, green: 0.1, blue: 0.5, alpha: 0.35).cgColor)
    NSColor.white.setFill()
    for h in heights {
        NSBezierPath(roundedRect: CGRect(x: x, y: 512 - h / 2, width: w, height: h), xRadius: w / 2, yRadius: w / 2).fill()
        x += w + gap
    }

    // Hairline edge.
    NSColor.white.withAlphaComponent(0.25).setStroke()
    path.lineWidth = 4
    path.stroke()

    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

for size in [16, 32, 128, 256, 512] {
    try! render(size).write(to: out.appendingPathComponent("icon_\(size)x\(size).png"))
    try! render(size * 2).write(to: out.appendingPathComponent("icon_\(size)x\(size)@2x.png"))
}
