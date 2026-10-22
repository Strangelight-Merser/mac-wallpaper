import CoreGraphics
import Foundation
import Metal
import WEFormat

/// Anything the app and `wecli` can draw: scene wallpapers (`SceneRenderer`) and video wallpapers
/// (`VideoRenderer`).
public protocol WallpaperRenderer: AnyObject {
    var device: MTLDevice { get }
    var queue: MTLCommandQueue { get }
    /// Human-readable notes about anything skipped or approximated.
    var warnings: [String] { get }
    /// Encode one frame at `time` seconds into `output` (any size / 8-bit format, e.g. a drawable).
    func encodeFrame(into output: MTLTexture, commandBuffer: MTLCommandBuffer, time: Float)
    /// Offscreen render of one frame (used by `wecli` and the regression suite).
    func render(width: Int, height: Int, time: Float) throws -> CGImage
    /// One-line description for logs ("scene, 17 layers", "video, vp9 1280x720 4.0s").
    var summary: String { get }
}

public enum Wallpaper {
    /// Open a wallpaper folder (one containing project.json) with the renderer its `type` needs.
    public static func open(project: URL, assets: URL?, properties: [String: String] = [:]) throws -> WallpaperRenderer {
        let locator = AssetLocator(project: project, assets: assets)
        let json = try locator.json("project.json")
        let type = (json["type"] as? String)?.lowercased()
        let file = json["file"] as? String ?? ""
        switch type {
        case "video"?:
            guard let url = locator.url(file) else { throw WEFormatError.unsupported("video file \(file) not found") }
            return try VideoRenderer(url: url)
        case "web"?, "application"?:
            throw WEFormatError.unsupported("\(type!) wallpapers are not supported yet")
        default:
            return try SceneRenderer(project: project, assets: assets, properties: properties)
        }
    }
}

/// Copy a (possibly private, possibly HDR) texture into an opaque 8-bit sRGB-tagged CGImage.
func readbackImage(_ t: MTLTexture, device: MTLDevice, queue: MTLCommandQueue) throws -> CGImage {
    let w = t.width, h = t.height
    let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: t.pixelFormat, width: w, height: h, mipmapped: false)
    d.storageMode = .shared
    let staging = device.makeTexture(descriptor: d)!
    let cmd = queue.makeCommandBuffer()!
    let blit = cmd.makeBlitCommandEncoder()!
    blit.copy(from: t, to: staging)
    blit.endEncoding()
    cmd.commit()
    cmd.waitUntilCompleted()

    var px = [UInt8](repeating: 255, count: w * h * 4)
    switch t.pixelFormat {
    case .rgba16Float:
        var half = [Float16](repeating: 0, count: w * h * 4)
        staging.getBytes(&half, bytesPerRow: w * 8, from: MTLRegionMake2D(0, 0, w, h), mipmapLevel: 0)
        for i in 0..<half.count where i % 4 != 3 {
            px[i] = UInt8(max(0, min(1, Float(half[i]))) * 255 + 0.5)
        }
    case .bgra8Unorm:
        staging.getBytes(&px, bytesPerRow: w * 4, from: MTLRegionMake2D(0, 0, w, h), mipmapLevel: 0)
        for i in stride(from: 0, to: px.count, by: 4) { px.swapAt(i, i + 2); px[i + 3] = 255 }
    default:
        staging.getBytes(&px, bytesPerRow: w * 4, from: MTLRegionMake2D(0, 0, w, h), mipmapLevel: 0)
        for i in stride(from: 3, to: px.count, by: 4) { px[i] = 255 }
    }
    let provider = CGDataProvider(data: Data(px) as CFData)!
    guard let img = CGImage(width: w, height: h, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: w * 4,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!,
                            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
                            provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent) else {
        throw WEFormatError.unsupported("readback")
    }
    return img
}
