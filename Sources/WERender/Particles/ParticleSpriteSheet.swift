// Frame selection ported from linux-wallpaperengine CParticle.cpp.
import Foundation
import WEFormat

/// Frame timing and a regular atlas consumable by genericparticle's SPRITESHEET path.
struct ParticleSpriteSheet {
    let durations: [Float]
    var count: Int { durations.count }
    var duration: Float { durations.reduce(0, +) }

    func frame(age: Float, lifetime: Float, random: Float, mode: String, multiplier: Float) -> Float {
        guard count > 0 else { return 0 }
        if mode == "randomframe" { return Float(min(count - 1, Int(random * Float(count)))) }
        let speed = max(0, multiplier)
        if mode == "once" { return min(Float(count - 1), max(0, age / max(lifetime, 0.0001)) * Float(count) * speed) }
        let total = duration
        guard total > 0 else { return 0 }
        var time = max(0, age * speed).truncatingRemainder(dividingBy: total)
        for (i, d) in durations.enumerated() {
            if time < d { return Float(i) + time / d }
            time -= d
        }
        return Float(count - 1)
    }

    struct Atlas {
        let pixels: [UInt8]
        let width, height, columns, rows, frameWidth, frameHeight: Int
    }

    /// Repack TEXS affine frame rectangles, including rotated frames and separate images.
    /// RGBA as genericparticle would see the texture through `ConvertTexture0Format` (common_fragment.h):
    /// RG88 → (r, r, r, g), R8 → (1, 1, 1, r). The atlas is uploaded as RGBA (TEX0FORMAT 0), so the expansion
    /// happens here; `Tex.rgba` is a display conversion and must not be used for shading.
    static func shaderRGBA(_ mip: Tex.Mipmap, format: Tex.Format) throws -> [UInt8] {
        let n = mip.width * mip.height
        switch format {
        case .r8:
            guard mip.bytes.count >= n else { throw WEFormatError.truncated(at: mip.bytes.count) }
            var out = [UInt8](repeating: 255, count: n * 4)
            for i in 0..<n { out[i * 4 + 3] = mip.bytes[i] }
            return out
        case .rg88:
            guard mip.bytes.count >= n * 2 else { throw WEFormatError.truncated(at: mip.bytes.count) }
            var out = [UInt8](repeating: 0, count: n * 4)
            for i in 0..<n {
                let r = mip.bytes[i * 2], g = mip.bytes[i * 2 + 1]
                out[i * 4] = r; out[i * 4 + 1] = r; out[i * 4 + 2] = r; out[i * 4 + 3] = g
            }
            return out
        default:
            return try Tex.rgba(mip)
        }
    }

    static func atlas(_ tex: Tex) throws -> Atlas {
        guard let first = tex.frames.first else { throw WEFormatError.corrupt("particle atlas has no frames") }
        let fw = max(1, Int(hypot(first.width, first.widthY).rounded()))
        let fh = max(1, Int(hypot(first.heightX, first.height).rounded()))
        let columns = max(1, Int(ceil(sqrt(Double(tex.frames.count)))))
        let rows = (tex.frames.count + columns - 1) / columns
        let width = fw * columns, height = fh * rows
        var images: [Int: (pixels: [UInt8], width: Int, height: Int)] = [:]
        for index in Set(tex.frames.map(\.imageIndex)) {
            guard let mip = tex.images[safe: index]?.first else { throw WEFormatError.corrupt("particle atlas image \(index)") }
            switch mip.payload {
            case .raw: images[index] = (try Self.shaderRGBA(mip, format: tex.format), mip.width, mip.height)
            case .encodedImage:
                let (pixels, w, h) = try TextureLoader.decodeImage(mip.bytes)
                images[index] = (pixels, w, h)
            case .mp4: throw WEFormatError.unsupported("particle video textures")
            }
        }
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        for (index, frame) in tex.frames.enumerated() {
            let source = images[frame.imageIndex]!
            for y in 0..<fh { for x in 0..<fw {
                let u = (Float(x) + 0.5) / Float(fw), v = (Float(y) + 0.5) / Float(fh)
                let sx = min(source.width - 1, max(0, Int(floor(frame.x + u * frame.width + v * frame.heightX))))
                let sy = min(source.height - 1, max(0, Int(floor(frame.y + u * frame.widthY + v * frame.height))))
                let src = (sy * source.width + sx) * 4
                let dst = ((index / columns * fh + y) * width + index % columns * fw + x) * 4
                for c in 0..<4 { pixels[dst + c] = source.pixels[src + c] }
            } }
        }
        return Atlas(pixels: pixels, width: width, height: height, columns: columns, rows: rows, frameWidth: fw, frameHeight: fh)
    }
}
