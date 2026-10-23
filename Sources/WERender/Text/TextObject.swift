import CoreGraphics
import CoreText
import Foundation
import WEFormat

/// A scene text object (`"text"` in scene.json). Rendered by WE as glyph coverage drawn with the `font`
/// shader into a box that fits the text; effects then run on that box like on an image layer.
public struct TextObject {
    public enum Align { case start, center, end }

    public var value: String
    /// `fonts/...` path (project or assets), or `systemfont_sansserif` / `_serif` / `_monospace`.
    public let font: String
    public let pointSize: Float
    public let padding: Float
    public let horizontal: Align
    public let vertical: Align
    /// Wrap width in pixels when `limitwidth` is set.
    public let maxWidth: Float?
    /// Row limit when `limitrows` is set; overflow ends with "…" if `limituseellipsis`.
    public let maxRows: Int?
    public let ellipsis: Bool

    init(object o: [String: Any], properties: UserProperties) {
        let text = o["text"]
        value = (properties.resolve(text) as? String) ?? (text as? String) ?? ""
        font = (properties.resolve(o["font"]) as? String) ?? "systemfont_sansserif"
        func f(_ k: String, _ d: Float) -> Float { parseFloats(properties.resolve(o[k]))?.first ?? d }
        pointSize = f("pointsize", 32)
        padding = f("padding", 0)
        func align(_ k: String, start: String, end: String) -> Align {
            switch (properties.resolve(o[k]) as? String)?.lowercased() {
            case start: .start
            case end: .end
            default: .center
            }
        }
        horizontal = align("horizontalalign", start: "left", end: "right")
        vertical = align("verticalalign", start: "top", end: "bottom")
        maxWidth = properties.bool(o["limitwidth"], default: false) ? f("maxwidth", 500) : nil
        maxRows = properties.bool(o["limitrows"], default: false) ? max(1, Int(f("maxrows", 1))) : nil
        ellipsis = properties.bool(o["limituseellipsis"], default: false)
    }

    /// WE rasterizes fonts at 300 DPI: one point is 300/72 scene pixels. Measured against the stored
    /// `size` of 49 text objects in real wallpapers (box = lines × (ascent + descent + leading) and the
    /// widest line, plus `padding` on every side).
    static let pixelsPerPoint: Float = 300.0 / 72.0

    /// Offset of the box centre from the object's origin, in object space. Inferred from real layouts
    /// (e.g. a song title above an artist name, both right-aligned to a thumbnail): `right` ends the
    /// text at the origin, `left` starts it there; `top` puts the text above the origin, `bottom` below.
    func boxOffset(_ size: SIMD2<Float>) -> SIMD2<Float> {
        let x: Float = switch horizontal { case .start: size.x / 2; case .center: 0; case .end: -size.x / 2 }
        let y: Float = switch vertical { case .start: size.y / 2; case .center: 0; case .end: -size.y / 2 }
        return SIMD2(x, y)
    }
}

/// Lays out and rasterizes a text object with CoreText into 8-bit coverage.
final class TextRasterizer {
    let object: TextObject
    private let font: CTFont

    init(_ object: TextObject, locator: AssetLocator) {
        self.object = object
        let size = CGFloat(object.pointSize * TextObject.pixelsPerPoint)
        font = Self.font(object.font, size: size, locator: locator)
    }

    static func font(_ name: String, size: CGFloat, locator: AssetLocator) -> CTFont {
        let system: CTFontUIFontType? = switch name.lowercased() {
            case "", "systemfont_sansserif", "systemfont_arial": .system
            case "systemfont_monospace": .userFixedPitch
            case "systemfont_serif": nil
            default: nil
        }
        if name.lowercased() == "systemfont_serif" { return CTFontCreateWithName("Times New Roman" as CFString, size, nil) }
        if let system, let f = CTFontCreateUIFontForLanguage(system, size, nil) { return f }
        if let data = try? locator.data(name), let desc = CTFontManagerCreateFontDescriptorFromData(data as CFData) {
            return CTFontCreateWithFontDescriptor(desc, size, nil)
        }
        return CTFontCreateUIFontForLanguage(.system, size, nil)!
    }

    struct Raster {
        let width: Int, height: Int
        /// Row-major coverage, top row first.
        let coverage: [UInt8]
    }

    func layoutLines(_ string: String) -> [CTLine] {
        let attrs: [NSAttributedString.Key: Any] = [
            NSAttributedString.Key(kCTFontAttributeName as String): font,
            NSAttributedString.Key(kCTForegroundColorFromContextAttributeName as String): true,
        ]
        // Rows as (paragraph, character range), so the last kept row can be re-set with the rest of its text.
        var rows: [(NSAttributedString, CFRange)] = []
        for paragraph in string.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n") {
            let attributed = NSAttributedString(string: paragraph, attributes: attrs)
            guard let maxWidth = object.maxWidth, !paragraph.isEmpty else {
                rows.append((attributed, CFRange(location: 0, length: attributed.length))); continue
            }
            let typesetter = CTTypesetterCreateWithAttributedString(attributed)
            var start = 0
            while start < attributed.length {
                let count = max(1, CTTypesetterSuggestLineBreak(typesetter, start, Double(maxWidth)))
                rows.append((attributed, CFRange(location: start, length: count)))
                start += count
            }
        }
        func line(_ row: (NSAttributedString, CFRange)) -> CTLine {
            CTLineCreateWithAttributedString(row.0.attributedSubstring(from: NSRange(location: row.1.location, length: row.1.length)))
        }
        guard let limit = object.maxRows, rows.count > limit else { return rows.map(line) }
        var lines = rows.prefix(limit).map(line)
        if object.ellipsis {
            // The last row takes the rest of its paragraph, cut to fit with "…" (also when a later
            // paragraph is what overflows).
            let (paragraph, range) = rows[limit - 1]
            let rest = paragraph.attributedSubstring(from: NSRange(location: range.location, length: paragraph.length - range.location))
            let full = NSMutableAttributedString(attributedString: rest)
            if rows[limit].0 !== paragraph { full.append(NSAttributedString(string: " …", attributes: attrs)) }
            let token = CTLineCreateWithAttributedString(NSAttributedString(string: "…", attributes: attrs))
            let width = object.maxWidth.map(Double.init) ?? CTLineGetTypographicBounds(lines[limit - 1], nil, nil, nil) + 1
            // CoreText can overshoot the width by up to the token's width; tighten until it fits.
            let source = CTLineCreateWithAttributedString(full)
            var target = width
            for _ in 0..<4 {
                guard let t = CTLineCreateTruncatedLine(source, target, .end, token) else { break }
                lines[limit - 1] = t
                let over = CTLineGetTypographicBounds(t, nil, nil, nil) - width
                if over <= 0 { break }
                target -= over + 0.5
            }
        }
        return lines
    }

    func render(_ string: String) -> Raster {
        let lines = layoutLines(string)
        let ascent = CTFontGetAscent(font), descent = CTFontGetDescent(font), leading = CTFontGetLeading(font)
        let lineHeight = ascent + descent + leading
        let widths = lines.map { CTLineGetTypographicBounds($0, nil, nil, nil) - CTLineGetTrailingWhitespaceWidth($0) }
        let pad = CGFloat(object.padding)
        let textWidth = max(1, (widths.max() ?? 0).rounded(.up))
        let w = Int(textWidth + 2 * pad), h = Int((lineHeight * CGFloat(max(lines.count, 1)) + 2 * pad).rounded(.up))
        var coverage = [UInt8](repeating: 0, count: w * h)
        coverage.withUnsafeMutableBytes { buffer in
            guard let ctx = CGContext(data: buffer.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w,
                                      space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return }
            ctx.setFillColor(gray: 1, alpha: 1)
            ctx.setAllowsFontSmoothing(false)
            for (i, line) in lines.enumerated() {
                let x: CGFloat = switch object.horizontal {
                    case .start: pad
                    case .center: pad + (textWidth - widths[i]) / 2
                    case .end: pad + textWidth - widths[i]
                }
                // CoreGraphics is y-up: line i's baseline sits `ascent` below the top of its row.
                ctx.textPosition = CGPoint(x: x, y: CGFloat(h) - pad - lineHeight * CGFloat(i) - ascent)
                CTLineDraw(line, ctx)
            }
        }
        // A bitmap context stores its top row first, so the buffer is already in texture order.
        return Raster(width: w, height: h, coverage: coverage)
    }
}
