// Run with: swift Scripts/make-icon.swift /tmp/Workbench.iconset
import AppKit
let directory = URL(fileURLWithPath: CommandLine.arguments[1])
try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
for size in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let pixels = size * scale
        let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels, bitsPerSample: 8,
            samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        NSGraphicsContext.current?.cgContext.scaleBy(x: CGFloat(pixels) / 128, y: CGFloat(pixels) / 128)
        let base = NSBezierPath(roundedRect: CGRect(x: 8, y: 8, width: 112, height: 112), xRadius: 26, yRadius: 26)
        NSGradient(
            starting: NSColor(srgbRed: 0.12, green: 0.16, blue: 0.23, alpha: 1),
            ending: NSColor(srgbRed: 0.25, green: 0.32, blue: 0.42, alpha: 1))!.draw(in: base, angle: 60)
        func pane(_ rect: CGRect, _ color: NSColor) {
            color.setFill()
            NSBezierPath(roundedRect: rect, xRadius: 4, yRadius: 4).fill()
        }
        pane(CGRect(x: 24, y: 30, width: 45, height: 57), .white)
        pane(CGRect(x: 75, y: 30, width: 29, height: 25), NSColor(srgbRed: 0.53, green: 0.72, blue: 1, alpha: 1))
        pane(CGRect(x: 75, y: 61, width: 29, height: 26), NSColor(srgbRed: 0.30, green: 0.53, blue: 0.98, alpha: 1))
        pane(CGRect(x: 24, y: 92, width: 45, height: 6), NSColor(srgbRed: 0.37, green: 0.60, blue: 1, alpha: 1))
        NSGraphicsContext.restoreGraphicsState()
        let name = "icon_\(size)x\(size)" + (scale == 2 ? "@2x" : "") + ".png"
        try rep.representation(using: .png, properties: [:])!.write(to: directory.appendingPathComponent(name))
    }
}
