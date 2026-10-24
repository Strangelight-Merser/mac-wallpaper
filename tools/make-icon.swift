// Draws the app icon (a dusk landscape inside the macOS squircle) and writes AppIcon.icns.
// Usage: swift tools/make-icon.swift <output folder>
import AppKit

let out = URL(fileURLWithPath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : ".")

func color(_ hex: UInt32, _ alpha: CGFloat = 1) -> CGColor {
    CGColor(srgbRed: CGFloat(hex >> 16 & 255) / 255, green: CGFloat(hex >> 8 & 255) / 255, blue: CGFloat(hex & 255) / 255, alpha: alpha)
}

/// The macOS icon shape on the 1024 grid: an 824 pt body with Apple's template corner radius.
func squircle(_ rect: CGRect) -> CGPath {
    CGPath(roundedRect: rect, cornerWidth: 185.4, cornerHeight: 185.4, transform: nil)
}

/// A mountain ridge across the body: smooth curve through the given heights (fractions of the body height).
func ridge(_ body: CGRect, _ heights: [CGFloat]) -> CGPath {
    let path = CGMutablePath()
    let points = heights.enumerated().map { i, h in
        CGPoint(x: body.minX + body.width * CGFloat(i) / CGFloat(heights.count - 1), y: body.minY + body.height * h)
    }
    path.move(to: CGPoint(x: body.minX - 10, y: body.minY - 10))
    path.addLine(to: CGPoint(x: body.minX - 10, y: points[0].y))
    path.addLine(to: points[0])
    for i in 1..<points.count {
        let p0 = points[i - 1], p1 = points[i]
        let mid = CGPoint(x: (p0.x + p1.x) / 2, y: (p0.y + p1.y) / 2)
        path.addQuadCurve(to: mid, control: p0)
        if i == points.count - 1 { path.addQuadCurve(to: p1, control: mid) }
    }
    path.addLine(to: CGPoint(x: body.maxX + 10, y: points.last!.y))
    path.addLine(to: CGPoint(x: body.maxX + 10, y: body.minY - 10))
    path.closeSubpath()
    return path
}

func draw(size: Int) -> CGImage {
    let s = CGFloat(size) / 1024
    let ctx = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0,
                        space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.scaleBy(x: s, y: s)
    let body = CGRect(x: 100, y: 100, width: 824, height: 824)
    let shape = squircle(body)

    // Soft drop shadow, as macOS icons carry their own.
    ctx.saveGState()
    // Shadow sizes are in device pixels, not affected by the scale.
    ctx.setShadow(offset: CGSize(width: 0, height: -10 * s), blur: 28 * s, color: color(0x000000, 0.35))
    ctx.addPath(shape); ctx.setFillColor(color(0x1a1240)); ctx.fillPath()
    ctx.restoreGState()

    ctx.saveGState()
    ctx.addPath(shape); ctx.clip()
    // Dusk sky: deep indigo at the top, violet, then warm at the horizon.
    let sky = CGGradient(colorsSpace: nil, colors: [color(0x120c3a), color(0x3b1f7a), color(0xb4457f), color(0xff9a62)] as CFArray,
                         locations: [0, 0.45, 0.78, 1])!
    ctx.drawLinearGradient(sky, start: CGPoint(x: 512, y: body.maxY), end: CGPoint(x: 512, y: body.minY + body.height * 0.32), options: [.drawsAfterEndLocation])

    // Stars.
    let stars: [(CGFloat, CGFloat, CGFloat, CGFloat)] = [(0.16, 0.86, 5, 0.9), (0.30, 0.74, 3.5, 0.7), (0.43, 0.90, 4, 0.8),
        (0.71, 0.88, 5.5, 0.95), (0.84, 0.76, 3.5, 0.7), (0.60, 0.80, 3, 0.6), (0.22, 0.66, 3, 0.5), (0.90, 0.92, 3, 0.6)]
    for (x, y, r, a) in stars {
        ctx.setFillColor(color(0xffffff, a))
        ctx.fillEllipse(in: CGRect(x: body.minX + body.width * x - r, y: body.minY + body.height * y - r, width: 2 * r, height: 2 * r))
    }

    // Sun with a glow, low over the ridges.
    let sun = CGPoint(x: body.minX + body.width * 0.62, y: body.minY + body.height * 0.43)
    let glow = CGGradient(colorsSpace: nil, colors: [color(0xffe2b0, 0.85), color(0xff9a62, 0.35), color(0xff9a62, 0)] as CFArray, locations: [0, 0.35, 1])!
    ctx.drawRadialGradient(glow, startCenter: sun, startRadius: 0, endCenter: sun, endRadius: 300, options: [])
    let disc = CGGradient(colorsSpace: nil, colors: [color(0xfff4d6), color(0xffc27a)] as CFArray, locations: [0, 1])!
    ctx.saveGState()
    ctx.addEllipse(in: CGRect(x: sun.x - 112, y: sun.y - 112, width: 224, height: 224)); ctx.clip()
    ctx.drawLinearGradient(disc, start: CGPoint(x: sun.x, y: sun.y + 112), end: CGPoint(x: sun.x, y: sun.y - 112), options: [])
    ctx.restoreGState()

    // Three ridges, far to near: the parallax layers of a live wallpaper.
    let layers: [([CGFloat], UInt32, UInt32)] = [
        ([0.46, 0.52, 0.44, 0.50, 0.41, 0.47, 0.43], 0x6b2f86, 0x8c3c88),
        ([0.33, 0.29, 0.38, 0.30, 0.35, 0.27, 0.32], 0x351a63, 0x4a2275),
        ([0.17, 0.24, 0.15, 0.21, 0.13, 0.20, 0.16], 0x150d33, 0x221548),
    ]
    for (heights, bottom, top) in layers {
        let path = ridge(body, heights)
        ctx.saveGState()
        ctx.addPath(path); ctx.clip()
        let fill = CGGradient(colorsSpace: nil, colors: [color(top), color(bottom)] as CFArray, locations: [0, 1])!
        ctx.drawLinearGradient(fill, start: CGPoint(x: 512, y: body.minY + body.height * (heights.max()! + 0.02)),
                               end: CGPoint(x: 512, y: body.minY), options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
        ctx.restoreGState()
    }

    // Glassy highlight along the top edge.
    let shine = CGGradient(colorsSpace: nil, colors: [color(0xffffff, 0.16), color(0xffffff, 0)] as CFArray, locations: [0, 1])!
    ctx.drawLinearGradient(shine, start: CGPoint(x: 512, y: body.maxY), end: CGPoint(x: 512, y: body.maxY - 220), options: [])
    ctx.restoreGState()

    // Hairline edge.
    ctx.addPath(shape); ctx.setStrokeColor(color(0xffffff, 0.10)); ctx.setLineWidth(2); ctx.strokePath()
    return ctx.makeImage()!
}

let iconset = out.appendingPathComponent("AppIcon.iconset")
try? FileManager.default.removeItem(at: iconset)
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)
for base in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let name = scale == 1 ? "icon_\(base)x\(base).png" : "icon_\(base)x\(base)@2x.png"
        let rep = NSBitmapImageRep(cgImage: draw(size: base * scale))
        try rep.representation(using: .png, properties: [:])!.write(to: iconset.appendingPathComponent(name))
    }
}
try NSBitmapImageRep(cgImage: draw(size: 1024)).representation(using: .png, properties: [:])!
    .write(to: out.appendingPathComponent("AppIcon-1024.png"))
let task = Process()
task.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
task.arguments = ["-c", "icns", iconset.path, "-o", out.appendingPathComponent("AppIcon.icns").path]
try task.run(); task.waitUntilExit()
try FileManager.default.removeItem(at: iconset)
print("wrote \(out.appendingPathComponent("AppIcon.icns").path)")
