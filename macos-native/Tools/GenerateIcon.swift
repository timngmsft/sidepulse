import AppKit
import Foundation

guard CommandLine.arguments.count == 2 else { fatalError("Pass the iconset output directory.") }
let directory = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
for points in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let pixels = points * scale
        let size = CGFloat(pixels)
        guard let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels,
                                             bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                                             isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
              let context = NSGraphicsContext(bitmapImageRep: bitmap) else { fatalError("Could not create icon bitmap.") }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        let inset = size * 0.075
        let body = NSBezierPath(roundedRect: NSRect(x: inset, y: inset, width: size - 2 * inset, height: size - 2 * inset),
                                xRadius: size * 0.19, yRadius: size * 0.19)
        let gradient = NSGradient(starting: NSColor(srgbRed: 0.09, green: 0.14, blue: 0.23, alpha: 1),
                                  ending: NSColor(srgbRed: 0.025, green: 0.045, blue: 0.08, alpha: 1))!
        gradient.draw(in: body, angle: -90)
        for index in 0..<4 {
            let x = size * (0.23 + Double(index) * 0.145)
            let rect = NSRect(x: x, y: size * 0.32, width: size * 0.095, height: size * 0.36)
            let alpha = index == 1 ? 1.0 : 0.36 + Double(index) * 0.1
            NSColor(srgbRed: 0, green: 0.9, blue: 1, alpha: alpha).setFill()
            NSBezierPath(roundedRect: rect, xRadius: size * 0.025, yRadius: size * 0.025).fill()
        }
        NSGraphicsContext.restoreGraphicsState()
        guard let data = bitmap.representation(using: .png, properties: [:]) else { fatalError("Could not encode icon.") }
        let suffix = scale == 2 ? "@2x" : ""
        try data.write(to: directory.appendingPathComponent("icon_\(points)x\(points)\(suffix).png"))
    }
}
