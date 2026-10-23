import Foundation

/// Wallpaper Engine `.tex` texture (TEXV0005 / TEXI0001 / TEXBxxxx [/ TEXSxxxx]).
/// Layout ported from RePKG (MIT).
public struct Tex {
    public enum Format: Int32 {
        case rgba8888 = 0, dxt5 = 4, dxt3 = 6, dxt1 = 7, rg88 = 8, r8 = 9
    }

    public struct Flags: OptionSet {
        public let rawValue: UInt32
        public init(rawValue: UInt32) { self.rawValue = rawValue }
        public static let noInterpolation = Flags(rawValue: 1)
        public static let clampUVs = Flags(rawValue: 2)
        public static let isGif = Flags(rawValue: 4)
        public static let isVideo = Flags(rawValue: 32)
        /// 3D volume texture (color-grading LUTs): extra header u32 and per-mipmap depth.
        public static let isVolume = Flags(rawValue: 64)
    }

    /// Payload kind of a mipmap after LZ4 has been undone.
    public enum Payload: Equatable {
        case raw(Format)                 // pixel data in `format`
        case encodedImage(freeImage: Int32) // PNG/JPEG/... file bytes (FreeImage format id)
        case mp4
    }

    public struct Mipmap {
        public let width: Int
        public let height: Int
        /// Depth for volume textures (slices stacked vertically in the payload), else 1.
        public let depth: Int
        public let payload: Payload
        public let bytes: [UInt8]
    }

    public struct Frame {
        public let imageIndex: Int
        public let frameTime: Float
        public let x, y, width, widthY, heightX, height: Float
    }

    public let format: Format
    public let flags: Flags
    public let textureWidth, textureHeight: Int
    public let imageWidth, imageHeight: Int
    public let containerVersion: Int
    /// Unknown u32 present on volume textures; looks like an average RGBA color.
    public let extra: UInt32?
    /// images[i] = mipmaps from largest to smallest.
    public let images: [[Mipmap]]
    public let frames: [Frame]
    public let gifSize: (width: Int, height: Int)?

    /// Inspect the video flag/container without copying or decompressing texture payloads.
    public static func isVideo(data: Data) throws -> Bool {
        var reader = BinaryReader(Array(data.prefix(128)))
        let magic = try reader.cString(maxLength: 16)
        guard magic == "TEXV0005" else { throw WEFormatError.badMagic(magic, expected: "TEXV0005") }
        let imageMagic = try reader.cString(maxLength: 16)
        guard imageMagic == "TEXI0001" else { throw WEFormatError.badMagic(imageMagic, expected: "TEXI0001") }
        _ = try reader.i32()
        let flags = Flags(rawValue: try reader.u32())
        if flags.contains(.isVideo) { return true }
        for _ in 0..<5 { _ = try reader.i32() }
        if flags.contains(.isVolume) { _ = try reader.i32() }
        let container = try reader.cString(maxLength: 16)
        _ = try reader.i32()
        switch container {
        case "TEXB0001", "TEXB0002": return false
        case "TEXB0003": return try reader.i32() == 35
        case "TEXB0004":
            let format = try reader.i32(), mp4 = try reader.i32() == 1
            return format == 35 || mp4
        default: throw WEFormatError.badMagic(container, expected: "TEXB000[1-4]")
        }
    }

    public init(data: Data) throws { try self.init(bytes: [UInt8](data)) }

    public init(bytes: [UInt8]) throws {
        var r = BinaryReader(bytes)
        let m1 = try r.cString(maxLength: 16)
        guard m1 == "TEXV0005" else { throw WEFormatError.badMagic(m1, expected: "TEXV0005") }
        let m2 = try r.cString(maxLength: 16)
        guard m2 == "TEXI0001" else { throw WEFormatError.badMagic(m2, expected: "TEXI0001") }

        let rawFormat = try r.i32()
        guard let format = Format(rawValue: rawFormat) else {
            throw WEFormatError.unsupported("tex format \(rawFormat)")
        }
        self.format = format
        flags = Flags(rawValue: try r.u32())
        textureWidth = try r.int(); textureHeight = try r.int()
        imageWidth = try r.int(); imageHeight = try r.int()
        _ = try r.u32()
        extra = flags.contains(.isVolume) ? try r.u32() : nil

        let cm = try r.cString(maxLength: 16)
        let imageCount = try r.int()
        guard (0...4096).contains(imageCount) else { throw WEFormatError.corrupt("image count \(imageCount)") }
        var freeImage: Int32 = -1
        var version: Int
        switch cm {
        case "TEXB0001": version = 1
        case "TEXB0002": version = 2
        case "TEXB0003": version = 3; freeImage = try r.i32()
        case "TEXB0004":
            freeImage = try r.i32()
            let isMp4 = try r.i32() == 1
            if isMp4 { freeImage = 35 }
            version = freeImage == 35 ? 4 : 3
        default: throw WEFormatError.badMagic(cm, expected: "TEXB000[1-4]")
        }
        containerVersion = version

        let payload: Payload
        switch flags.contains(.isVideo) ? 35 : freeImage {
        case -1: payload = .raw(format)
        case 35: payload = .mp4
        default: payload = .encodedImage(freeImage: freeImage)
        }

        var images: [[Mipmap]] = []
        for _ in 0..<imageCount {
            let mipCount = try r.int()
            guard (0...32).contains(mipCount) else { throw WEFormatError.corrupt("mipmap count \(mipCount)") }
            var mips: [Mipmap] = []
            for _ in 0..<mipCount {
                if version == 4 {
                    _ = try r.i32(); _ = try r.i32()
                    _ = try r.cString()
                    _ = try r.i32()
                }
                let w = try r.int(), h = try r.int()
                let d = flags.contains(.isVolume) ? try r.int() : 1
                var lz4 = false, decompressed = 0
                if version >= 2 {
                    lz4 = try r.i32() == 1
                    decompressed = try r.int()
                }
                let n = try r.int()
                let raw = try r.bytes(n)
                let bytes = lz4 ? try LZ4.decompressBlock(raw, decompressedSize: decompressed) : [UInt8](raw)
                mips.append(Mipmap(width: w, height: h, depth: d, payload: payload, bytes: bytes))
            }
            images.append(mips)
        }
        self.images = images

        var frames: [Frame] = []
        var gif: (Int, Int)? = nil
        if flags.contains(.isGif) {
            let sm = try r.cString(maxLength: 16)
            let count = try r.int()
            if sm == "TEXS0003" { gif = (try r.int(), try r.int()) }
            guard ["TEXS0001", "TEXS0002", "TEXS0003"].contains(sm) else {
                throw WEFormatError.badMagic(sm, expected: "TEXS000[1-3]")
            }
            for _ in 0..<count {
                let idx = try r.int(), t = try r.f32()
                var v = [Float]()
                for _ in 0..<6 { v.append(sm == "TEXS0001" ? Float(try r.i32()) : try r.f32()) }
                frames.append(Frame(imageIndex: idx, frameTime: t, x: v[0], y: v[1],
                                    width: v[2], widthY: v[3], heightX: v[4], height: v[5]))
            }
            if gif == nil || gif!.0 == 0, let f = frames.first { gif = (Int(f.width), Int(f.height)) }
        }
        self.frames = frames
        gifSize = gif.map { (width: $0.0, height: $0.1) }
    }

    /// Decode a mipmap to tightly packed RGBA8 (raw formats only).
    /// Channel mapping follows RePKG: R8 → (r,r,r,255), RG88 → (g,g,g,r).
    public static func rgba(_ m: Mipmap) throws -> [UInt8] {
        guard case .raw(let f) = m.payload else { throw WEFormatError.unsupported("not raw pixels") }
        let n = m.width * m.height
        switch f {
        case .rgba8888:
            guard m.bytes.count >= n * 4 else { throw WEFormatError.truncated(at: m.bytes.count) }
            return Array(m.bytes.prefix(n * 4))
        case .dxt1: return try DXT.decode(m.bytes[...], width: m.width, height: m.height, kind: .dxt1)
        case .dxt3: return try DXT.decode(m.bytes[...], width: m.width, height: m.height, kind: .dxt3)
        case .dxt5: return try DXT.decode(m.bytes[...], width: m.width, height: m.height, kind: .dxt5)
        case .r8:
            guard m.bytes.count >= n else { throw WEFormatError.truncated(at: m.bytes.count) }
            var out = [UInt8](repeating: 255, count: n * 4)
            for i in 0..<n { let v = m.bytes[i]; out[i*4] = v; out[i*4+1] = v; out[i*4+2] = v }
            return out
        case .rg88:
            guard m.bytes.count >= n * 2 else { throw WEFormatError.truncated(at: m.bytes.count) }
            var out = [UInt8](repeating: 0, count: n * 4)
            for i in 0..<n {
                let r = m.bytes[i*2], g = m.bytes[i*2+1]
                out[i*4] = g; out[i*4+1] = g; out[i*4+2] = g; out[i*4+3] = r
            }
            return out
        }
    }
}
