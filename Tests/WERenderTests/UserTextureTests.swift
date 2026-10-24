import Foundation
import ImageIO
import Metal
import simd
import UniformTypeIdentifiers
import XCTest
import WEFormat
@testable import WERender

final class UserTextureTests: XCTestCase {
    private func folder() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    private func image(_ color: [UInt8], size: Int = 16) throws -> CGImage {
        let pixels = Array(repeating: color, count: size * size).flatMap { $0 }
        let provider = try XCTUnwrap(CGDataProvider(data: Data(pixels) as CFData))
        return try XCTUnwrap(CGImage(width: size, height: size, bitsPerComponent: 8, bitsPerPixel: 32,
            bytesPerRow: size * 4, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.last.rawValue), provider: provider,
            decode: nil, shouldInterpolate: false, intent: .defaultIntent))
    }

    private func writeImage(_ url: URL, animated: Bool = false, apng: Bool = false) throws {
        let type = animated && !apng ? UTType.gif.identifier : UTType.png.identifier
        let destination = try XCTUnwrap(CGImageDestinationCreateWithURL(url as CFURL, type as CFString,
                                                                      animated ? 3 : 1, nil))
        let colors: [[UInt8]] = [[255, 0, 0, 255], [0, 255, 0, 255], [0, 0, 255, 255]]
        for i in 0..<(animated ? 3 : 1) {
            let delay = [0.125, 0.25, 0.5][i]
            let properties: [CFString: Any] = apng
                ? [kCGImagePropertyPNGDictionary: [kCGImagePropertyAPNGDelayTime: delay]]
                : [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFDelayTime: delay]]
            CGImageDestinationAddImage(destination, try image(colors[i]), properties as CFDictionary)
        }
        XCTAssertTrue(CGImageDestinationFinalize(destination))
    }

    private func scene(at root: URL, userTextures: Any = ["picture"]) throws {
        func json(_ name: String, _ object: Any) throws {
            let url = root.appendingPathComponent(name)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try JSONSerialization.data(withJSONObject: object, options: .sortedKeys).write(to: url)
        }
        try json("project.json", ["type": "scene", "file": "scene.json", "general": ["properties": [
            "picture": ["type": "scenetexture", "value": ""], "other": ["type": "textinput", "value": ""]]]])
        try json("scene.json", ["general": ["orthogonalprojection": ["width": 32, "height": 16]],
            "objects": [["id": 1, "image": "model.json", "origin": "8 8 0", "size": "16 16"],
                        ["id": 2, "image": "model.json", "origin": "24 8 0", "size": "16 16"]]])
        try json("model.json", ["material": "materials/image.json"])
        try json("materials/image.json", ["passes": [["shader": "image", "textures": ["original"],
                                                        "usertextures": userTextures]]])
        try wrapVideoTexture(Data(repeating: 255, count: 16 * 16 * 4), version: 1,
                             videoFlag: false, mp4Flag: false).write(to: root.appendingPathComponent("materials/original.tex"))
        try FileManager.default.createDirectory(at: root.appendingPathComponent("shaders"), withIntermediateDirectories: true)
        try """
        attribute vec3 a_Position;
        attribute vec2 a_TexCoord;
        uniform mat4 g_ModelViewProjectionMatrix;
        varying vec2 v_UV;
        void main() { gl_Position = g_ModelViewProjectionMatrix * vec4(a_Position, 1.0); v_UV = a_TexCoord; }
        """.write(to: root.appendingPathComponent("shaders/image.vert"), atomically: true, encoding: .utf8)
        try """
        uniform sampler2D g_Texture0;
        varying vec2 v_UV;
        void main() { gl_FragColor = texSample2D(g_Texture0, v_UV); }
        """.write(to: root.appendingPathComponent("shaders/image.frag"), atomically: true, encoding: .utf8)
    }

    func testStraightAlphaImageDecode() throws {
        let (pixels, width, height) = try TextureLoader.decodeImage(image([240, 100, 20, 128]))
        XCTAssertEqual(width, 16)
        XCTAssertEqual(height, 16)
        for (actual, expected) in zip(pixels.prefix(4), [240, 100, 20, 128]) {
            XCTAssertEqual(Int(actual), expected, accuracy: 1)
        }
    }

    func testEveryTextureMapFormAndOverrides() {
        typealias Pass = SceneDescription.Pass
        let array: [Any] = ["first", NSNull(), "", ["name": "fourth"], ["name": ""], [:], 12]
        XCTAssertEqual(Pass.textureMap(array), [0: "first", 3: "fourth"])
        XCTAssertEqual(Pass.textureMap(["0": "first", "3": ["name": "fourth"], "4": NSNull(),
                                       "5": "", "-1": "bad", "bad": "bad"] as [String: Any]), [0: "first", 3: "fourth"])
        XCTAssertEqual(Pass.textureMap(NSNull()), [:])
        XCTAssertEqual(Pass.textureMap("invalid"), [:])
        var pass = Pass(material: ["usertextures": array], label: "test")
        pass.apply(override: ["usertextures": ["0": ["name": "override"], "2": "extra"]],
                   properties: UserProperties(project: [:]))
        XCTAssertEqual(pass.userTextures, [0: "override", 2: "extra", 3: "fourth"])
        pass.apply(override: ["textures": ["explicit"]], properties: UserProperties(project: [:]))
        XCTAssertNil(pass.userTextures[0])
        pass.apply(override: ["textures": ["explicit"], "usertextures": ["final"]],
                   properties: UserProperties(project: [:]))
        XCTAssertEqual(pass.userTextures[0], "final")
    }

    func testPathResolutionAndFallback() throws {
        let root = try folder()
        try scene(at: root)
        let picture = root.appendingPathComponent("picture with space.png")
        try writeImage(picture)
        let locator = AssetLocator(project: root, assets: nil)
        func load(_ value: String) throws -> SceneDescription {
            try SceneDescription(project: root, locator: locator, overrides: ["picture": value])
        }
        XCTAssertEqual(try load("").layers[0].passes[0].textures, ["original"])
        for path in [picture.path, picture.absoluteString, picture.lastPathComponent] {
            let loaded = try load(path)
            XCTAssertEqual(loaded.layers[0].passes[0].textures, ["$file:" + picture.resolvingSymlinksInPath().path])
            XCTAssertTrue(loaded.notes.isEmpty)
        }
        let missing = try load("missing.png")
        XCTAssertEqual(missing.layers[0].passes[0].textures, ["original"])
        XCTAssertEqual(missing.notes.count, 1)
        XCTAssertEqual(try load(root.path).layers[0].passes[0].textures, ["original"])
    }

    func testInstanceAndEffectOverrides() throws {
        let root = try folder()
        try scene(at: root, userTextures: [])
        let object: [String: Any] = ["id": 1, "image": "model.json", "size": "16 16",
            "instance": ["usertextures": [["name": "picture"]]],
            "effects": [["file": "effect.json", "passes": [["usertextures": ["0": "other"]]]]]]
        try JSONSerialization.data(withJSONObject: ["objects": [object]])
            .write(to: root.appendingPathComponent("scene.json"))
        try JSONSerialization.data(withJSONObject: ["passes": [["material": "materials/image.json"]]])
            .write(to: root.appendingPathComponent("effect.json"))
        let loaded = try SceneDescription(project: root, locator: AssetLocator(project: root, assets: nil))
        XCTAssertEqual(loaded.layers[0].passes.map(\.userTextures), [[0: "picture"], [0: "other"]])
    }

    func testAnimationTimelineAndBudget() throws {
        let root = try folder(), gif = root.appendingPathComponent("animation.gif")
        try writeImage(gif, animated: true)
        let animation = try AnimatedImageTexture(url: gif, memoryBudget: 12 * 8 * 8)
        XCTAssertEqual(animation.delays, [0.13, 0.25, 0.5])
        XCTAssertEqual(animation.maxPixelSize, 8)
        for index in [0, 1, 2, 0] {
            let (pixels, width, height) = try TextureLoader.decodeImage(animation.decodedImage(at: index))
            XCTAssertEqual(width, 8)
            XCTAssertEqual(height, 8)
            XCTAssertEqual(pixels[index], 255)
            XCTAssertEqual(pixels[(index + 1) % 3], 0)
        }
        for (time, expected) in [(0.0, 0), (0.125, 1), (0.374, 1), (0.375, 2), (0.875, 0), (1.0, 1), (-0.1, 2)] {
            XCTAssertEqual(AnimatedImageTexture.frameIndex(at: time, delays: [0.125, 0.25, 0.5]), expected)
        }
        for delay in [0, 0.001, 0.01, -1, Double.nan] {
            XCTAssertEqual(AnimatedImageTexture.normalizedDelay(delay), 0.1)
        }
        XCTAssertEqual(AnimatedImageTexture.normalizedDelay(0.02), 0.02)
        let png = root.appendingPathComponent("animation.png")
        try writeImage(png, animated: true, apng: true)
        XCTAssertEqual(try AnimatedImageTexture(url: png).delays, [0.125, 0.25, 0.5])
    }

    func testCLIAbsoluteAndRelativeProperties() throws {
        guard MTLCreateSystemDefaultDevice() != nil else { throw XCTSkip("Metal unavailable") }
        let root = try folder()
        try scene(at: root)
        let png = root.appendingPathComponent("picture with spaces.png")
        try writeImage(png)
        for (index, path) in [png.path, png.lastPathComponent].enumerated() {
            let output = root.appendingPathComponent("output\(index).png")
            let process = Process()
            process.executableURL = Bundle(for: Self.self).bundleURL.deletingLastPathComponent().appendingPathComponent("wecli")
            process.arguments = ["render", root.path, "--prop", "picture=" + path,
                                 "--size", "32x16", "--out", output.path]
            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = pipe
            try process.run()
            let log = pipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            XCTAssertEqual(process.terminationStatus, 0, String(decoding: log, as: UTF8.self))
            let (pixels, _, _) = try TextureLoader.decodeImage(Array(Data(contentsOf: output)))
            XCTAssertEqual(Array(pixels[(8 * 32 + 8) * 4..<(8 * 32 + 8) * 4 + 4]), [255, 0, 0, 255])
        }
    }

    func testDirectVideoFileSharing() async throws {
        guard MTLCreateSystemDefaultDevice() != nil else { throw XCTSkip("Metal unavailable") }
        if ProcessInfo.processInfo.environment["WE_TEST_SKIP_VIDEO_CODECS"] == "1" {
            throw XCTSkip("VideoToolbox unavailable in this sandbox")
        }
        let root = try folder()
        try scene(at: root)
        let video = root.appendingPathComponent("colors.mp4")
        _ = try await makeVideoTextureMP4(at: video)
        let renderer = try SceneRenderer(project: root, assets: nil, properties: ["picture": video.lastPathComponent])
        let first = try TextureLoader.decodeImage(renderer.render(width: 32, height: 16, time: 0)).0
        let second = try TextureLoader.decodeImage(renderer.render(width: 32, height: 16, time: 1)).0
        XCTAssertNotEqual(first, second)
        XCTAssertEqual(try TextureLoader.decodeImage(renderer.render(width: 32, height: 16, time: 0)).0, first)
        XCTAssertEqual(Set(renderer.videoTextures.keys), [video.resolvingSymlinksInPath()])
        XCTAssertTrue(renderer.plans.values.allSatisfy(\.isDynamic))
        XCTAssertTrue(renderer.warnings.isEmpty)
    }

    func testOfflinePixelsSharingReloadAndInvalidImageFallback() throws {
        guard MTLCreateSystemDefaultDevice() != nil else { throw XCTSkip("Metal unavailable") }
        let root = try folder()
        try scene(at: root)
        let png = root.appendingPathComponent("picture.png"), gif = root.appendingPathComponent("animation.gif")
        try writeImage(png)
        try writeImage(gif, animated: true)
        func renderer(_ value: String) throws -> SceneRenderer {
            try SceneRenderer(project: root, assets: nil, properties: ["picture": value])
        }
        func pixels(_ renderer: SceneRenderer, _ time: Float = 0) throws -> [UInt8] {
            try TextureLoader.decodeImage(renderer.render(width: 32, height: 16, time: time)).0
        }
        let original = try renderer("")
        let white = try pixels(original)
        let still = try renderer(png.path)
        let red = try pixels(still)
        XCTAssertNotEqual(red, white)
        XCTAssertEqual(Array(red[(8 * 32 + 8) * 4..<(8 * 32 + 8) * 4 + 4]), [255, 0, 0, 255])
        XCTAssertFalse(still.setUserProperties(["picture": ""]))
        XCTAssertEqual(still.scene.properties.values["picture"] as? String, png.path)
        XCTAssertTrue(still.setUserProperties(["picture": png.path]))
        XCTAssertEqual(try pixels(renderer(png.lastPathComponent)), red)
        XCTAssertEqual(try pixels(renderer("missing.png")), white)
        let invalid = root.appendingPathComponent("invalid.png")
        try Data("not an image".utf8).write(to: invalid)
        let fallback = try renderer(invalid.path)
        XCTAssertEqual(try pixels(fallback), white)
        XCTAssertEqual(fallback.warnings.count, 1)
        let moving = try renderer(gif.path)
        XCTAssertEqual(try pixels(moving), red)
        XCTAssertNotEqual(try pixels(moving, 0.2), red)
        XCTAssertEqual(try pixels(moving, 0.9), red)
        XCTAssertEqual(try pixels(moving), red)
        XCTAssertEqual(moving.textures.values.filter { $0.animation != nil }.count, 1)
        XCTAssertTrue(moving.plans.values.allSatisfy(\.isDynamic))
        XCTAssertTrue(moving.layerCaches.isEmpty)
        XCTAssertTrue(moving.warnings.isEmpty)
        let loaded = try XCTUnwrap(still.textures.values.first)
        XCTAssertEqual(loaded.textureSize, SIMD2(16, 16))
        XCTAssertEqual(loaded.imageSize, loaded.textureSize)
        XCTAssertEqual(loaded.formatCode, 0)
        XCTAssertTrue(loaded.clamp)
        let key = try XCTUnwrap(original.plans.keys.first)
        let oldPlan = try XCTUnwrap(original.plans[key])
        var pass = original.scene.layers[0].passes[0]
        pass.textures = ["$file:" + png.path]
        let changed = try original.plan(key, pass: pass, layer: original.scene.layers[0],
                                        model: matrix_identity_float4x4, hasPrevious: false)
        XCTAssertFalse(changed === oldPlan)
        XCTAssertEqual(changed.textureKey, pass.textures)
        let small = try AnimatedImageTexture(url: gif, memoryBudget: 12 * 8 * 8).frame(at: 0, device: still.device)
        XCTAssertEqual(small.imageSize, SIMD2(8, 8))
    }
}
