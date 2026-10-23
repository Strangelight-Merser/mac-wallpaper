import CoreGraphics
import Foundation
import Metal
import WEFormat
import WEVideo

/// Mapping of content onto an output with a potentially different aspect ratio.
public enum ContentMode: String, CaseIterable, Sendable { case fill, fit, stretch }

/// Anything the app and `wecli` can draw: scene wallpapers (`SceneRenderer`) and video wallpapers
/// (`VideoRenderer`).
public protocol WallpaperRenderer: AnyObject {
    /// How content maps onto the output. Takes effect on the next frame; defaults to `.fill`.
    var contentMode: ContentMode { get set }
    /// Colour of the bars around `.fit` content; defaults to black.
    var barColor: SIMD3<Float> { get set }
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
    /// Applies a delta without reload; false leaves the current properties unchanged.
    func setUserProperties(_ values: [String: String]) -> Bool
}

public enum Wallpaper {
    public static func webProperties(project: [String: Any], values: [String: String]) -> [String: [String: Any]] {
        pageProperties(project, UserProperties(project: project, overrides: values))
    }
    /// Open a wallpaper folder (one containing project.json) with the renderer its `type` needs.
    public static func open(project: URL, assets: URL?, properties: [String: String] = [:]) throws -> WallpaperRenderer {
        let locator = AssetLocator(project: project, assets: assets)
        let json = try locator.json("project.json")
        let type = (json["type"] as? String)?.lowercased()
        let file = json["file"] as? String ?? ""
        switch type {
        case "video"?:
            guard let url = locator.url(file) else { throw WEFormatError.unsupported("video file \(file) not found") }
            do { return try VideoRenderer(url: url) } catch VideoError.needsWebKit(let url) {
                throw WallpaperError.needsWebKit(.video(url))
            }
        case "web"?:
            guard let index = locator.url(file) else { throw WEFormatError.unsupported("web page \(file) not found") }
            let props = UserProperties(project: json, overrides: properties)
            throw WallpaperError.needsWebKit(.page(index: index, root: project, properties: pageProperties(json, props)))
        case "application"?:
            throw WEFormatError.unsupported("application wallpapers (Windows programs) are not supported")
        default:
            return try SceneRenderer(project: project, assets: assets, properties: properties)
        }
    }
}

/// What WebKit must show instead of a Metal renderer (web wallpapers, VP8 videos).
public enum WebContentRequest {
    case page(index: URL, root: URL, properties: [String: [String: Any]])
    case video(URL)
}

public enum WallpaperError: Error, CustomStringConvertible {
    case needsWebKit(WebContentRequest)
    public var description: String {
        switch self {
        case .needsWebKit(.page(let index, _, _)): return "web wallpaper \(index.lastPathComponent) (WebKit)"
        case .needsWebKit(.video(let url)): return "\(url.lastPathComponent) (WebKit video)"
        }
    }
}

/// project.json properties as WE passes them to `applyUserProperties`: `{name: {type, value}}`, with
/// values converted to the declared type (project files often store booleans/numbers as strings, e.g.
/// `"value": "true"`, while pages test `value === true`) and user overrides applied.
func pageProperties(_ project: [String: Any], _ user: UserProperties) -> [String: [String: Any]] {
    let declared = (project["general"] as? [String: Any])?["properties"] as? [String: Any] ?? [:]
    var out: [String: [String: Any]] = [:]
    for (name, raw) in declared {
        guard let p = raw as? [String: Any] else { continue }
        let type = (p["type"] as? String ?? "").lowercased()
        out[name] = ["type": type, "value": typedValue(user.values[name] ?? p["value"] ?? NSNull(), type: type)]
    }
    return out
}

func typedValue(_ v: Any, type: String) -> Any {
    func isBoolean(_ x: Any) -> Bool { (x as? NSNumber).map { CFGetTypeID($0) == CFBooleanGetTypeID() } ?? false }
    switch type {
    case "bool":
        if isBoolean(v) { return v }
        if let n = v as? NSNumber { return n.doubleValue != 0 }
        if let s = v as? String { return s == "true" || s == "1" }
        return false
    case "slider":
        if let n = v as? NSNumber, !isBoolean(n) { return n }
        if let s = v as? String, let d = Double(s) { return d }
        return v
    default: // color ("r g b"), combo (option value), textinput, file, directory...
        if let n = v as? NSNumber, !isBoolean(n), type == "combo" { return n.stringValue }
        return v
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
