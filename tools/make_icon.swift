// Renders the app icon: a sheet of washi paper with a single vermilion hair.
// usage: swift tools/make_icon.swift <out-dir>   (writes AppIcon.iconset + icon-1024.png)
import AppKit
let out = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "."
func render(_ px: Int) -> Data {
    let s = CGFloat(px)
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px, bitsPerSample: 8, samplesPerPixel: 4,
                               hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let inset = s * 0.1, r = NSRect(x: inset, y: inset, width: s - 2 * inset, height: s - 2 * inset)
    let shadow = NSShadow(); shadow.shadowColor = .black.withAlphaComponent(0.18); shadow.shadowBlurRadius = s * 0.03
    shadow.shadowOffset = NSSize(width: 0, height: -s * 0.012); shadow.set()
    let bg = NSBezierPath(roundedRect: r, xRadius: s * 0.18, yRadius: s * 0.18)
    NSColor(srgbRed: 0.976, green: 0.957, blue: 0.918, alpha: 1).setFill(); bg.fill()
    NSShadow().set()
    bg.addClip()
    // the hair: one fine vermilion stroke
    let hair = NSBezierPath()
    hair.move(to: NSPoint(x: r.minX + r.width * 0.16, y: r.minY + r.height * 0.22))
    hair.curve(to: NSPoint(x: r.minX + r.width * 0.86, y: r.minY + r.height * 0.80),
               controlPoint1: NSPoint(x: r.minX + r.width * 0.62, y: r.minY + r.height * 0.10),
               controlPoint2: NSPoint(x: r.minX + r.width * 0.30, y: r.minY + r.height * 0.92))
    hair.lineWidth = max(s * 0.014, 1); hair.lineCapStyle = .round
    NSColor(srgbRed: 0.85, green: 0.27, blue: 0.18, alpha: 1).setStroke(); hair.stroke()
    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}
let set = "\(out)/AppIcon.iconset"
try? FileManager.default.createDirectory(atPath: set, withIntermediateDirectories: true)
for b in [16, 32, 128, 256, 512] {
    try! render(b).write(to: URL(fileURLWithPath: "\(set)/icon_\(b)x\(b).png"))
    try! render(b * 2).write(to: URL(fileURLWithPath: "\(set)/icon_\(b)x\(b)@2x.png"))
}
try! render(1024).write(to: URL(fileURLWithPath: "\(out)/icon-1024.png"))
