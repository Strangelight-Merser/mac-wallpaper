import Foundation
import ImageIO
import Metal
import UniformTypeIdentifiers
import WEFormat

/// A user picture: a still image, or an animated GIF/APNG whose frames follow scene time. Frames are decoded once,
/// in order (ImageIO composites each on the previous one), and kept as textures sized so that all of them fit the
/// memory budget.
final class AnimatedImageTexture {
    let source: CGImageSource
    let delays: [Double]
    let maxPixelSize: Int
    private var frames: [MTLTexture?]

    init(url: URL, memoryBudget: Int = 128 * 1024 * 1024) throws {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              CGImageSourceGetCount(source) > 0 else { throw WEFormatError.corrupt("user image") }
        self.source = source
        let type = CGImageSourceGetType(source) as String?
        let count = type == UTType.gif.identifier || type == UTType.png.identifier ? CGImageSourceGetCount(source) : 1
        delays = (0..<count).map { index in
            let properties = CGImageSourceCopyPropertiesAtIndex(source, index, nil) as? [String: Any] ?? [:]
            let gif = properties[kCGImagePropertyGIFDictionary as String] as? [String: Any]
            let png = properties[kCGImagePropertyPNGDictionary as String] as? [String: Any]
            let delay = (gif?[kCGImagePropertyGIFUnclampedDelayTime as String] as? NSNumber)?.doubleValue
                ?? (gif?[kCGImagePropertyGIFDelayTime as String] as? NSNumber)?.doubleValue
                ?? (png?[kCGImagePropertyAPNGUnclampedDelayTime as String] as? NSNumber)?.doubleValue
                ?? (png?[kCGImagePropertyAPNGDelayTime as String] as? NSNumber)?.doubleValue ?? 0.1
            return Self.normalizedDelay(delay)
        }
        // Square frames of maxPixelSize² RGBA8 pixels, all of them within the budget.
        maxPixelSize = max(1, Int(sqrt(Double(max(4, memoryBudget) / (4 * delays.count)))))
        frames = Array(repeating: nil, count: delays.count)
    }

    static func normalizedDelay(_ delay: Double) -> Double { delay.isFinite && delay > 0.01 ? delay : 0.1 }

    static func frameIndex(at time: Double, delays: [Double]) -> Int {
        let duration = delays.reduce(0, +)
        guard time.isFinite, duration > 0 else { return 0 }
        var position = time.truncatingRemainder(dividingBy: duration)
        if position < 0 { position += duration }
        for (index, delay) in delays.enumerated() {
            if position < delay { return index }
            position -= delay
        }
        return 0
    }

    func frame(at time: Double, device: MTLDevice) throws -> LoadedTexture {
        let index = Self.frameIndex(at: time, delays: delays)
        // Decode up to the frame needed, in order, so ImageIO never restarts from the first frame.
        for i in 0...index where frames[i] == nil { frames[i] = try Self.upload(decodedImage(at: i), device: device) }
        guard let texture = frames[index] else { throw WEFormatError.corrupt("user image frame \(index)") }
        let size = SIMD2(Float(texture.width), Float(texture.height))
        return LoadedTexture(texture: texture, textureSize: size, imageSize: size, clamp: true,
                             animation: delays.count > 1 ? self : nil)
    }

    func decodedImage(at index: Int) throws -> CGImage {
        let options: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize]
        let decoded = delays.count == 1
            ? CGImageSourceCreateImageAtIndex(source, index, nil)
            : CGImageSourceCreateThumbnailAtIndex(source, index, options as CFDictionary)
        guard let image = decoded else { throw WEFormatError.corrupt("user image frame \(index)") }
        return image
    }

    static func upload(_ image: CGImage, device: MTLDevice) throws -> MTLTexture {
        let (pixels, width, height) = try TextureLoader.decodeImage(image)
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba8Unorm,
            width: width, height: height, mipmapped: false)
        descriptor.usage = .shaderRead
        guard let texture = device.makeTexture(descriptor: descriptor) else { throw WEFormatError.unsupported("texture alloc") }
        pixels.withUnsafeBytes {
            texture.replace(region: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0,
                            withBytes: $0.baseAddress!, bytesPerRow: width * 4)
        }
        return texture
    }
}
