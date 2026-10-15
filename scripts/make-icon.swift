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
    // Graphite body: near-black with a soft top-down falloff.
    NSGradient(colors: [NSColor(white: 0.20, alpha: 1), NSColor(white: 0.07, alpha: 1)])!.draw(in: body, angle: -90)

    // Faint sheen across the top third.
    let sheen = NSGradient(colors: [NSColor.white.withAlphaComponent(0.10), NSColor.white.withAlphaComponent(0)])!
    sheen.draw(in: NSBezierPath(ovalIn: CGRect(x: -80, y: 560, width: 1184, height: 620)), relativeCenterPosition: NSPoint(x: 0, y: 0.5))

    // Waveform: white, symmetric, quiet.
    let heights: [CGFloat] = [110, 210, 330, 440, 330, 210, 110]
    let w: CGFloat = 50, gap: CGFloat = 40
    let total = CGFloat(heights.count) * w + CGFloat(heights.count - 1) * gap
    var x = 512 - total / 2
    for h in heights {
        let bar = NSBezierPath(roundedRect: CGRect(x: x, y: 512 - h / 2, width: w, height: h), xRadius: w / 2, yRadius: w / 2)
        NSGradient(colors: [NSColor(white: 1, alpha: 1), NSColor(white: 0.82, alpha: 1)])!.draw(in: bar, angle: -90)
        x += w + gap
    }

    // Hairline edge.
    NSColor.white.withAlphaComponent(0.12).setStroke()
    path.lineWidth = 3
    path.stroke()

    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

for size in [16, 32, 128, 256, 512] {
    try! render(size).write(to: out.appendingPathComponent("icon_\(size)x\(size).png"))
    try! render(size * 2).write(to: out.appendingPathComponent("icon_\(size)x\(size)@2x.png"))
}
