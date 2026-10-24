import AVFoundation
import CoreVideo
import XCTest
import WEFormat
import WEVideo
import WELibrary
import WEShader
import Metal
@testable import WERender

final class VideoTextureTests: XCTestCase {
    var fixture: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("regression/fixtures/videotexturetest")
    }

    func requireVideoCodecs() throws {
        if ProcessInfo.processInfo.environment["WE_TEST_SKIP_VIDEO_CODECS"] == "1" {
            throw XCTSkip("VideoToolbox services unavailable in this sandbox (explicit WE_TEST_SKIP_VIDEO_CODECS=1)")
        }
    }

    func testGeneratedVideoLayouts() async throws {
        try requireVideoCodecs()
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let mp4 = try await makeVideoTextureMP4(at: folder.appendingPathComponent("colors.mp4"))
        try assertLayouts(mp4)
    }

    func testFixtureLayouts() throws {
        try assertLayouts(fixtureMP4())
    }

    func fixtureMP4() throws -> Data {
        let tex = try Tex(data: Data(contentsOf: fixture.appendingPathComponent("materials/colors.tex")))
        return Data(try XCTUnwrap(tex.images.first?.first).bytes)
    }

    private func assertLayouts(_ mp4: Data) throws {
        for version in 1...4 {
            for flag in (version == 4 ? [false, true] : [true]) {
                let data = wrapVideoTexture(mp4, version: version, videoFlag: flag)
                let tex = try Tex(data: data)
                XCTAssertTrue(try Tex.isVideo(data: data))
                let mip = try XCTUnwrap(tex.images.first?.first)
                XCTAssertEqual(mip.payload, .mp4)
                XCTAssertEqual(Data(mip.bytes), mp4)
                XCTAssertEqual(mip.width, 16); XCTAssertEqual(mip.height, 16)
                if version == 3 { XCTAssertEqual(data.range(of: Data("ftyp".utf8))?.lowerBound, 0x5b) }
            }
        }
        let v4FlagOnly = wrapVideoTexture(mp4, version: 4, mp4Flag: false)
        XCTAssertEqual(try Tex(data: v4FlagOnly).images[0][0].payload, .mp4)
        XCTAssertTrue(try Tex.isVideo(data: v4FlagOnly))
    }

    func testNonVideoLayoutsRemainRaw() throws {
        for version in 1...4 {
            let data = wrapVideoTexture(Data(repeating: 255, count: 16 * 16 * 4),
                                        version: version, videoFlag: false, mp4Flag: false)
            XCTAssertFalse(try Tex.isVideo(data: data))
            XCTAssertEqual(try Tex(data: data).images[0][0].payload, .raw(.rgba8888))
        }
    }

    func testCacheReuse() throws {
        let mp4 = try fixtureMP4()
        let url = try VideoTextureCache.store(Array(mp4))
        XCTAssertEqual(try VideoTextureCache.store(Array(mp4)), url)
        XCTAssertEqual(try Data(contentsOf: url), mp4)
        XCTAssertThrowsError(try VideoTextureCache.store([]))
    }

    func testDeterministicDecode() throws {
        try requireVideoCodecs()
        let url = try VideoTextureCache.store(Array(fixtureMP4()))
        let source = try VideoSource.open(url)
        XCTAssertEqual(source.width, 16); XCTAssertEqual(source.height, 16)
        func pixel(_ time: Double) throws -> [UInt8] {
            let frame = try XCTUnwrap(source.frame(at: time))
            CVPixelBufferLockBaseAddress(frame, .readOnly)
            defer { CVPixelBufferUnlockBaseAddress(frame, .readOnly) }
            let p = CVPixelBufferGetBaseAddress(frame)!.assumingMemoryBound(to: UInt8.self)
            return Array(UnsafeBufferPointer(start: p, count: 4))
        }
        let red = try pixel(0), blue = try pixel(1)
        XCTAssertGreaterThan(Int(red[2]) - Int(red[0]), 200)
        XCTAssertGreaterThan(Int(blue[0]) - Int(blue[2]), 200)
        XCTAssertEqual(try pixel(0), red) // seek backwards
        XCTAssertEqual(try pixel(3), blue) // loop
        XCTAssertEqual(try pixel(2), red)
    }

    func testCompatibility() async throws {
        try requireVideoCodecs()
        let result = await CompatibilityChecker(assets: fixture).check(
            WallpaperEntry(folder: fixture, root: .userFolder), deep: false)
        XCTAssertEqual(result.status, .supported)
        XCTAssertNil(result.missing[.videoTexture])
        XCTAssertEqual(result.checkerVersion, CompatibilityChecker.version)
    }

    func testUnreadableVideoCompatibility() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.copyItem(at: fixture, to: folder)
        defer { try? FileManager.default.removeItem(at: folder) }
        try wrapVideoTexture(Data("invalid MP4".utf8), version: 3)
            .write(to: folder.appendingPathComponent("materials/colors.tex"))
        let result = await CompatibilityChecker(assets: folder).check(
            WallpaperEntry(folder: folder, root: .userFolder), deep: false)
        XCTAssertEqual(result.missing[.videoTexture], 2)
        XCTAssertTrue(result.notes.contains { $0.contains("colors: video textures:") })
    }

    func testFixtureShadersCompile() throws {
        let locator = AssetLocator(project: fixture, assets: nil)
        let vertex = try XCTUnwrap(ShaderPreprocessor.process(locator.string("shaders/video.vert"),
            stage: .vertex, fileDirectory: "shaders", locator: locator, overrides: [:]))
        let fragment = try XCTUnwrap(ShaderPreprocessor.process(locator.string("shaders/video.frag"),
            stage: .fragment, fileDirectory: "shaders", locator: locator, overrides: [:]))
        _ = try ShaderCompiler.compile(vertex: vertex.source, fragment: fragment.source)
    }

    func testSceneVideoFramesAndSharing() throws {
        try requireVideoCodecs()
        guard MTLCreateSystemDefaultDevice() != nil else { throw XCTSkip("Metal unavailable") }
        let renderer = try SceneRenderer(project: fixture, assets: nil)
        func pixels(_ time: Float) throws -> Data {
            let image = try renderer.render(width: 64, height: 32, time: time)
            return image.dataProvider!.data! as Data
        }
        let first = try pixels(0), second = try pixels(1)
        XCTAssertNotEqual(first, second)
        XCTAssertEqual(try pixels(0), first)
        XCTAssertEqual(try pixels(2), first)
        XCTAssertEqual(renderer.videoTextures.count, 1)
        XCTAssertTrue(renderer.plans.values.allSatisfy(\.isDynamic))
        XCTAssertTrue(renderer.layerCaches.isEmpty)
        XCTAssertTrue(renderer.warnings.isEmpty, renderer.warnings.joined(separator: "\n"))
    }
}
