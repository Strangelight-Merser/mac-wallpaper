import CoreGraphics
import CoreVideo
import Foundation
import Metal
import WEFormat
import WEVideo

/// Video wallpapers: decoded BGRA frames (VideoToolbox, via `VideoSource`) imported zero-copy into Metal
/// and cover-fitted to the output.
public final class VideoRenderer: WallpaperRenderer {
    public let device: MTLDevice
    public let queue: MTLCommandQueue
    public private(set) var warnings: [String] = []
    let source: VideoSource
    var textureCache: CVMetalTextureCache?
    var pipelines: [MTLPixelFormat: MTLRenderPipelineState] = [:]
    lazy var sampler: MTLSamplerState = {
        let d = MTLSamplerDescriptor()
        d.minFilter = .linear; d.magFilter = .linear
        d.sAddressMode = .clampToEdge; d.tAddressMode = .clampToEdge
        return device.makeSamplerState(descriptor: d)!
    }()

    public var summary: String {
        String(format: "video, %@ %dx%d %.1fs", source.codec, source.width, source.height, source.duration)
    }

    public init(url: URL) throws {
        guard let device = MTLCreateSystemDefaultDevice(), let queue = device.makeCommandQueue() else {
            throw WEFormatError.unsupported("no Metal device")
        }
        self.device = device
        self.queue = queue
        source = try VideoSource.open(url)
        CVMetalTextureCacheCreate(nil, nil, device, nil, &textureCache)
    }

    public func render(width: Int, height: Int, time: Float) throws -> CGImage {
        let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba8Unorm, width: width, height: height, mipmapped: false)
        d.usage = [.renderTarget, .shaderRead]
        d.storageMode = .private
        let output = device.makeTexture(descriptor: d)!
        let cb = queue.makeCommandBuffer()!
        encodeFrame(into: output, commandBuffer: cb, time: time)
        cb.commit()
        cb.waitUntilCompleted()
        if let e = cb.error { throw e }
        return try readbackImage(output, device: device, queue: queue)
    }

    public func encodeFrame(into output: MTLTexture, commandBuffer: MTLCommandBuffer, time: Float) {
        let rp = MTLRenderPassDescriptor()
        rp.colorAttachments[0].texture = output
        rp.colorAttachments[0].loadAction = .clear
        rp.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)
        rp.colorAttachments[0].storeAction = .store
        guard let enc = commandBuffer.makeRenderCommandEncoder(descriptor: rp) else { return }
        defer { enc.endEncoding() }

        let frame: CVPixelBuffer?
        do { frame = try source.frame(at: Double(time)) } catch {
            warn("\(error)")
            return
        }
        guard let frame, let cache = textureCache else { return }
        var cvTexture: CVMetalTexture?
        CVMetalTextureCacheCreateTextureFromImage(nil, cache, frame, nil, .bgra8Unorm,
                                                  CVPixelBufferGetWidth(frame), CVPixelBufferGetHeight(frame), 0, &cvTexture)
        guard let cvTexture, let texture = CVMetalTextureGetTexture(cvTexture), let pipeline = pipeline(for: output.pixelFormat) else {
            warn("could not map video frame to a Metal texture")
            return
        }
        // Cover-fit: scale the frame to fill the output, cropping the overflow (UV window around the centre).
        let videoAspect = Float(texture.width) / Float(texture.height)
        let outAspect = Float(output.width) / Float(output.height)
        var uvScale = SIMD2<Float>(1, 1)
        if outAspect > videoAspect { uvScale.y = videoAspect / outAspect } else { uvScale.x = outAspect / videoAspect }
        enc.setRenderPipelineState(pipeline)
        enc.setFragmentTexture(texture, index: 0)
        enc.setFragmentSamplerState(sampler, index: 0)
        enc.setFragmentBytes(&uvScale, length: MemoryLayout<SIMD2<Float>>.size, index: 0)
        enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        // The CVMetalTexture (and its pixel buffer) must outlive the GPU work.
        commandBuffer.addCompletedHandler { _ in withExtendedLifetime((cvTexture, frame)) {} }
    }

    func pipeline(for format: MTLPixelFormat) -> MTLRenderPipelineState? {
        if let p = pipelines[format] { return p }
        let src = """
        #include <metal_stdlib>
        using namespace metal;
        struct V { float4 pos [[position]]; float2 uv; };
        vertex V video_vs(uint id [[vertex_id]]) {
            float2 p = float2((id << 1) & 2, id & 2);
            return { float4(p * 2 - 1, 0, 1), float2(p.x, 1 - p.y) };
        }
        fragment float4 video_fs(V in [[stage_in]], texture2d<float> t [[texture(0)]], sampler s [[sampler(0)]],
                                 constant float2 &uvScale [[buffer(0)]]) {
            float2 uv = (in.uv - 0.5) * uvScale + 0.5;
            return float4(t.sample(s, uv).rgb, 1);
        }
        """
        guard let lib = try? device.makeLibrary(source: src, options: nil) else { return nil }
        let pd = MTLRenderPipelineDescriptor()
        pd.vertexFunction = lib.makeFunction(name: "video_vs")
        pd.fragmentFunction = lib.makeFunction(name: "video_fs")
        pd.colorAttachments[0].pixelFormat = format
        let p = try? device.makeRenderPipelineState(descriptor: pd)
        pipelines[format] = p
        return p
    }

    var warned = Set<String>()
    func warn(_ w: String) { if warned.insert(w).inserted { warnings.append(w) } }
}
