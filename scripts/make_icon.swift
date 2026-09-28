// Renders the app icon into an .iconset directory: swift make_icon.swift <out.iconset>
import AppKit

let out = CommandLine.arguments[1]
let colors: [NSColor] = [0x2A78D6, 0xEB6834, 0x1BAF7A, 0xEDA100].map {
    NSColor(srgbRed: CGFloat(($0 >> 16) & 0xFF) / 255, green: CGFloat(($0 >> 8) & 0xFF) / 255, blue: CGFloat($0 & 0xFF) / 255, alpha: 1)
}

func render(_ px: Int) -> Data {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px, bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                               bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let s = CGFloat(px)
    let inset = s * 0.1
    let rect = NSRect(x: inset, y: inset, width: s - 2 * inset, height: s - 2 * inset)
    let bg = NSBezierPath(roundedRect: rect, xRadius: rect.width * 0.225, yRadius: rect.width * 0.225)
    NSGradient(starting: NSColor(white: 0.16, alpha: 1), ending: NSColor(white: 0.06, alpha: 1))!.draw(in: bg, angle: -90)
    // Four rising stacked bars
    let heights: [CGFloat] = [0.28, 0.42, 0.36, 0.58]
    let barW = rect.width * 0.13, gap = rect.width * 0.06
    let total = 4 * barW + 3 * gap
    var x = rect.midX - total / 2
    let base = rect.minY + rect.height * 0.2
    for (i, h) in heights.enumerated() {
        let full = rect.height * h
        var y = base
        for (j, frac) in [0.5, 0.3, 0.2].enumerated() {
            let seg = full * frac
            let r = NSRect(x: x, y: y, width: barW, height: seg - s * 0.006)
            colors[(i + j) % colors.count].setFill()
            NSBezierPath(roundedRect: r, xRadius: barW * 0.18, yRadius: barW * 0.18).fill()
            y += seg
        }
        x += barW + gap
    }
    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

for size in [16, 32, 128, 256, 512] {
    try! render(size).write(to: URL(fileURLWithPath: "\(out)/icon_\(size)x\(size).png"))
    try! render(size * 2).write(to: URL(fileURLWithPath: "\(out)/icon_\(size)x\(size)@2x.png"))
}
