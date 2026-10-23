import CoreGraphics
import Foundation
import ImageIO
import Metal
import WEFormat
import WEVideo

/// GPU texture plus the sizes shaders see through `g_TextureNResolution`.
public struct LoadedTexture {
    public let texture: MTLTexture
    public let textureSize: SIMD2<Float>  // allocated (power-of-two padded) size
    public let imageSize: SIMD2<Float>    // meaningful image region
    public let clamp: Bool
    /// WE `FORMAT_*` code (common_fragment.h) shaders see as `TEX<n>FORMAT`: 0 RGBA8888, 4 DXT5,
    /// 6 DXT3, 7 DXT1, 8 RG88, 9 R8, 10 RG1616F, 11 R16F.
    public var formatCode: Int = 0
    var video: VideoTexture? = nil
    var videoFrame: VideoTextureFrame? = nil
}

enum TextureLoader {
    /// Load `materials/<name>.tex` via the locator and upload all mip levels.
    static func load(_ name: String, locator: AssetLocator, device: MTLDevice,
                     videos: inout [URL: VideoTexture], time: Double,
                     commandBuffer: MTLCommandBuffer?) throws -> LoadedTexture {
        let tex = try Tex(data: locator.data("materials/\(name).tex"))
        guard let mips = tex.images.first, let top = mips.first else { throw WEFormatError.corrupt("\(name): no images") }

        let texture: MTLTexture
        // Raw payloads are padded to textureWidth×textureHeight; embedded images are stored unpadded.
        var allocated = SIMD2(Float(tex.textureWidth), Float(tex.textureHeight))
        switch top.payload {
        case .raw(let f):
            let (pf, bpr): (MTLPixelFormat, (Int) -> Int) = {
                switch f {
                case .rgba8888: return (.rgba8Unorm, { $0 * 4 })
                case .rg88: return (.rg8Unorm, { $0 * 2 })
                case .r8: return (.r8Unorm, { $0 })
                // BC formats are native on Apple Silicon; bytesPerRow counts 4x4 blocks.
                case .dxt1: return (.bc1_rgba, { max(1, ($0 + 3) / 4) * 8 })
                case .dxt3: return (.bc2_rgba, { max(1, ($0 + 3) / 4) * 16 })
                case .dxt5: return (.bc3_rgba, { max(1, ($0 + 3) / 4) * 16 })
                }
            }()
            let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: pf, width: top.width, height: top.height,
                                                             mipmapped: mips.count > 1)
            d.mipmapLevelCount = mips.count
            d.usage = .shaderRead
            d.storageMode = .shared
            guard let t = device.makeTexture(descriptor: d) else { throw WEFormatError.unsupported("texture alloc") }
            for (level, m) in mips.enumerated() {
                m.bytes.withUnsafeBytes { p in
                    t.replace(region: MTLRegionMake2D(0, 0, m.width, m.height), mipmapLevel: level,
                              withBytes: p.baseAddress!, bytesPerRow: bpr(m.width))
                }
            }
            texture = t
        case .encodedImage:
            let (px, w, h) = try decodeImage(top.bytes)
            let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba8Unorm, width: w, height: h, mipmapped: false)
            d.usage = .shaderRead
            guard let t = device.makeTexture(descriptor: d) else { throw WEFormatError.unsupported("texture alloc") }
            px.withUnsafeBytes { t.replace(region: MTLRegionMake2D(0, 0, w, h), mipmapLevel: 0, withBytes: $0.baseAddress!, bytesPerRow: w * 4) }
            texture = t
            allocated = SIMD2(Float(w), Float(h))
        case .mp4:
            let url = try VideoTextureCache.store(top.bytes)
            let video = try videos[url] ?? VideoTexture(url: url, device: device)
            videos[url] = video
            return try video.frame(at: time, clamp: tex.flags.contains(.clampUVs), commandBuffer: commandBuffer)
        }
        var formatCode = 0 // embedded PNG/JPEG decode to RGBA
        if case .raw(let f) = top.payload {
            switch f {
            case .rgba8888: formatCode = 0
            case .dxt5: formatCode = 4
            case .dxt3: formatCode = 6
            case .dxt1: formatCode = 7
            case .rg88: formatCode = 8
            case .r8: formatCode = 9
            }
        }
        return LoadedTexture(texture: texture,
                             textureSize: allocated,
                             imageSize: SIMD2(Float(tex.imageWidth), Float(tex.imageHeight)),
                             clamp: tex.flags.contains(.clampUVs), formatCode: formatCode)
    }

    /// Decode PNG/JPEG to straight-alpha RGBA8.
    static func decodeImage(_ bytes: [UInt8]) throws -> ([UInt8], Int, Int) {
        guard let src = CGImageSourceCreateWithData(Data(bytes) as CFData, nil),
              let img = CGImageSourceCreateImageAtIndex(src, 0, nil) else { throw WEFormatError.corrupt("embedded image") }
        let w = img.width, h = img.height
        var px = [UInt8](repeating: 0, count: w * h * 4)
        guard let ctx = CGContext(data: &px, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { throw WEFormatError.corrupt("cg") }
        ctx.draw(img, in: CGRect(x: 0, y: 0, width: w, height: h))
        for i in stride(from: 0, to: px.count, by: 4) where px[i + 3] != 0 && px[i + 3] != 255 {
            let a = Int(px[i + 3])
            for c in 0..<3 { px[i + c] = UInt8(min(255, (Int(px[i + c]) * 255 + a / 2) / a)) }
        }
        return (px, w, h)
    }
}
