import CoreVideo
import Foundation
import Metal
import WEVideo

/// One decoder per cached payload, owned by the scene renderer.
final class VideoTexture {
    let source: VideoSource
    private let cache: CVMetalTextureCache

    init(url: URL, device: MTLDevice) throws {
        source = try VideoSource.open(url)
        var cache: CVMetalTextureCache?
        let status = CVMetalTextureCacheCreate(nil, nil, device, nil, &cache)
        guard status == kCVReturnSuccess, let cache else { throw VideoError.decode("texture cache (\(status))") }
        self.cache = cache
    }

    func frame(at time: Double, clamp: Bool, commandBuffer: MTLCommandBuffer?) throws -> LoadedTexture {
        guard let buffer = try source.frame(at: time) else { throw VideoError.decode("empty video texture") }
        var mapped: CVMetalTexture?
        let width = CVPixelBufferGetWidth(buffer), height = CVPixelBufferGetHeight(buffer)
        let status = CVMetalTextureCacheCreateTextureFromImage(nil, cache, buffer, nil, .bgra8Unorm,
                                                               width, height, 0, &mapped)
        guard status == kCVReturnSuccess, let mapped, let texture = CVMetalTextureGetTexture(mapped) else {
            throw VideoError.decode("video texture import (\(status))")
        }
        commandBuffer?.addCompletedHandler { _ in withExtendedLifetime((mapped, buffer)) {} }
        let size = SIMD2(Float(width), Float(height))
        return LoadedTexture(texture: texture, textureSize: size, imageSize: size, clamp: clamp,
                             video: self, videoFrame: VideoTextureFrame(mapped: mapped, buffer: buffer))
    }
}

/// Keep the imported surface alive even when loaded before a command buffer exists.
final class VideoTextureFrame {
    let mapped: CVMetalTexture
    let buffer: CVPixelBuffer
    init(mapped: CVMetalTexture, buffer: CVPixelBuffer) { self.mapped = mapped; self.buffer = buffer }
}
