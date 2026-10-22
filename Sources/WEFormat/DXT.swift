/// BC1/BC2/BC3 (DXT1/3/5) software decoder to RGBA8. Used by wecli and tests;
/// the renderer should upload DXT directly as `.bc1_rgba` etc. on Apple Silicon.
enum DXT {
    enum Kind { case dxt1, dxt3, dxt5 }

    static func decode(_ src: ArraySlice<UInt8>, width: Int, height: Int, kind: Kind) throws -> [UInt8] {
        let blockSize = kind == .dxt1 ? 8 : 16
        let bw = (width + 3) / 4, bh = (height + 3) / 4
        guard src.count >= bw * bh * blockSize else {
            throw WEFormatError.truncated(at: src.count)
        }
        var out = [UInt8](repeating: 0, count: width * height * 4)
        var p = src.startIndex
        var rgba = [UInt8](repeating: 0, count: 64)
        for by in 0..<bh {
            for bx in 0..<bw {
                let colorAt = kind == .dxt1 ? p : p + 8
                decodeColors(src, colorAt, into: &rgba, isDXT1: kind == .dxt1)
                if kind == .dxt3 { decodeAlphaExplicit(src, p, into: &rgba) }
                if kind == .dxt5 { decodeAlphaInterpolated(src, p, into: &rgba) }
                p += blockSize
                for py in 0..<4 {
                    let y = by * 4 + py
                    if y >= height { break }
                    for px in 0..<4 {
                        let x = bx * 4 + px
                        if x >= width { break }
                        let s = (py * 4 + px) * 4, d = (y * width + x) * 4
                        out[d] = rgba[s]; out[d + 1] = rgba[s + 1]
                        out[d + 2] = rgba[s + 2]; out[d + 3] = rgba[s + 3]
                    }
                }
            }
        }
        return out
    }

    private static func unpack565(_ v: Int) -> (Int, Int, Int) {
        let r = (v >> 11) & 31, g = (v >> 5) & 63, b = v & 31
        return ((r << 3) | (r >> 2), (g << 2) | (g >> 4), (b << 3) | (b >> 2))
    }

    private static func decodeColors(_ s: ArraySlice<UInt8>, _ p: Int, into rgba: inout [UInt8], isDXT1: Bool) {
        let c0 = Int(s[p]) | Int(s[p + 1]) << 8
        let c1 = Int(s[p + 2]) | Int(s[p + 3]) << 8
        let a = unpack565(c0), b = unpack565(c1)
        var pal = [(Int, Int, Int, Int)](repeating: (0, 0, 0, 255), count: 4)
        pal[0] = (a.0, a.1, a.2, 255)
        pal[1] = (b.0, b.1, b.2, 255)
        if c0 > c1 || !isDXT1 {
            pal[2] = ((2 * a.0 + b.0) / 3, (2 * a.1 + b.1) / 3, (2 * a.2 + b.2) / 3, 255)
            pal[3] = ((a.0 + 2 * b.0) / 3, (a.1 + 2 * b.1) / 3, (a.2 + 2 * b.2) / 3, 255)
        } else {
            pal[2] = ((a.0 + b.0) / 2, (a.1 + b.1) / 2, (a.2 + b.2) / 2, 255)
            pal[3] = (0, 0, 0, 0)
        }
        for i in 0..<16 {
            let idx = (Int(s[p + 4 + i / 4]) >> ((i % 4) * 2)) & 3
            let c = pal[idx]
            rgba[i * 4] = UInt8(c.0); rgba[i * 4 + 1] = UInt8(c.1)
            rgba[i * 4 + 2] = UInt8(c.2); rgba[i * 4 + 3] = UInt8(c.3)
        }
    }

    private static func decodeAlphaExplicit(_ s: ArraySlice<UInt8>, _ p: Int, into rgba: inout [UInt8]) {
        for i in 0..<16 {
            let nib = (Int(s[p + i / 2]) >> ((i % 2) * 4)) & 15
            rgba[i * 4 + 3] = UInt8(nib | nib << 4)
        }
    }

    private static func decodeAlphaInterpolated(_ s: ArraySlice<UInt8>, _ p: Int, into rgba: inout [UInt8]) {
        let a0 = Int(s[p]), a1 = Int(s[p + 1])
        var pal = [a0, a1, 0, 0, 0, 0, 0, 0]
        if a0 > a1 {
            for i in 1...6 { pal[i + 1] = ((7 - i) * a0 + i * a1) / 7 }
        } else {
            for i in 1...4 { pal[i + 1] = ((5 - i) * a0 + i * a1) / 5 }
            pal[6] = 0; pal[7] = 255
        }
        var bits: UInt64 = 0
        for k in 0..<6 { bits |= UInt64(s[p + 2 + k]) << (8 * UInt64(k)) }
        for i in 0..<16 {
            rgba[i * 4 + 3] = UInt8(pal[Int((bits >> (3 * UInt64(i))) & 7)])
        }
    }
}
