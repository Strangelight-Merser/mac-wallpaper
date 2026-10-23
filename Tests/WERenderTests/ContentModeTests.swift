import CoreGraphics
import Metal
import simd
import XCTest
@testable import WERender

final class ContentModeTests: XCTestCase {
    let canvas = SIMD2<Float>(1920, 1080)

    func testVisibleCanvasRectangles() {
        // 16:10 crops left/right in fill; 21:9 crops top/bottom.
        let cases: [(SIMD2<Float>, ContentMode, SIMD2<Float>)] = [
            ([1600, 1000], .fill, [1728, 1080]),
            ([2100, 900], .fill, [1920, 1920 * 3 / 7]),
            ([1600, 1000], .fit, [1920, 1200]),
            ([2100, 900], .fit, [2520, 1080]),
            ([1600, 1000], .stretch, [1920, 1080]),
            ([2100, 900], .stretch, [1920, 1080])]
        for (output, mode, visible) in cases {
            let projection = contentProjection(canvas: canvas, output: output, mode: mode)
            let lo = projection.inverse * SIMD4<Float>(-1, -1, 0, 1)
            let hi = projection.inverse * SIMD4<Float>(1, 1, 0, 1)
            XCTAssertEqual(lo.x, (canvas.x - visible.x) / 2, accuracy: 0.001)
            XCTAssertEqual(lo.y, (canvas.y - visible.y) / 2, accuracy: 0.001)
            XCTAssertEqual(hi.x - lo.x, visible.x, accuracy: 0.001)
            XCTAssertEqual(hi.y - lo.y, visible.y, accuracy: 0.001)
        }
    }

    func testFitBarLocations() {
        for (output, topLeft) in [(SIMD2<Float>(1600, 1000), SIMD2<Float>(0, 50)),
                                   (SIMD2<Float>(2100, 900), SIMD2<Float>(250, 0)),
                                   (SIMD2<Float>(1440, 932), SIMD2<Float>(0, 61))] {
            let p = contentProjection(canvas: canvas, output: output, mode: .fit)
            let corner = p * SIMD4<Float>(0, canvas.y, 0, 1)
            XCTAssertEqual((corner.x + 1) / 2 * output.x, topLeft.x, accuracy: 0.001)
            XCTAssertEqual((1 - corner.y) / 2 * output.y, topLeft.y, accuracy: 0.001)
        }
    }

    func testOutputPointerRoundTripsIncludingBars() {
        for output: SIMD2<Float> in [[1600, 1000], [2100, 900], [1440, 932]] {
            for mode in ContentMode.allCases {
                let p = contentProjection(canvas: canvas, output: output, mode: mode)
                for point: SIMD2<Float> in [[0, 0], [1, 1], [0.5, 0.5], [0.13, 0.84]] {
                    let world = p.inverse * SIMD4<Float>(point.x * 2 - 1, 1 - point.y * 2, 0, 1)
                    let clip = p * world
                    XCTAssertEqual((clip.x + 1) / 2, point.x, accuracy: 0.00001)
                    XCTAssertEqual((1 - clip.y) / 2, point.y, accuracy: 0.00001)
                    if point == [0.5, 0.5] {
                        XCTAssertEqual(world.x, 960, accuracy: 0.001)
                        XCTAssertEqual(world.y, 540, accuracy: 0.001)
                    }
                }
            }
        }
    }

    func testFillMatchesOriginalProjectionExactly() {
        for output: SIMD2<Float> in [[1600, 1000], [2100, 900], [1440, 932], [720, 1280]] {
            let scale = max(output.x / canvas.x, output.y / canvas.y)
            let visible = output / scale
            let lo = (canvas - visible) / 2, hi = lo + visible
            XCTAssertEqual(contentProjection(canvas: canvas, output: output, mode: .fill).flat,
                           ortho(left: lo.x, right: hi.x, bottom: lo.y, top: hi.y).flat)
        }
    }

    func testSceneBarsAndLiveModeChanges() throws {
        guard MTLCreateSystemDefaultDevice() != nil else { throw XCTSkip("No Metal device") }
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        try Data(#"{"file":"scene.json","type":"scene"}"#.utf8).write(to: folder.appendingPathComponent("project.json"))
        try Data(#"{"general":{"clearcolor":"1 0 0","orthogonalprojection":{"width":1920,"height":1080}},"objects":[]}"#.utf8)
            .write(to: folder.appendingPathComponent("scene.json"))
        let renderer = try SceneRenderer(project: folder, assets: nil)
        XCTAssertEqual(renderer.contentMode, .fill)
        XCTAssertEqual(renderer.barColor, .zero)
        renderer.barColor = [0, 1, 0]
        for (width, height, barPoint) in [(160, 100, (80, 0)), (210, 90, (0, 45))] {
            for mode in [ContentMode.fit, .stretch, .fill, .fit] {
                renderer.contentMode = mode
                let image = try renderer.render(width: width, height: height, time: 0)
                let data = image.dataProvider!.data! as Data
                func pixel(_ x: Int, _ y: Int) -> [UInt8] {
                    let offset = y * image.bytesPerRow + x * 4
                    return Array(data[offset..<(offset + 3)])
                }
                XCTAssertEqual(pixel(width / 2, height / 2), [255, 0, 0])
                XCTAssertEqual(pixel(barPoint.0, barPoint.1), mode == .fit ? [0, 255, 0] : [255, 0, 0])
            }
        }
        // An output-sized pass (as used by bloom/compositions) must retain bars, and
        // full-frame copies must preserve both the output dimensions and those pixels.
        let commandBuffer = renderer.queue.makeCommandBuffer()!
        renderer.commandBuffer = commandBuffer
        let encoder = renderer.encoder(for: renderer.sceneTarget, clear: nil)
        encoder.setRenderPipelineState(renderer.barPipeline!)
        var blue = SIMD3<Float>(0, 0, 1)
        encoder.setFragmentBytes(&blue, length: MemoryLayout<SIMD3<Float>>.stride, index: 0)
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        let copy = renderer.fullFrameCopy().texture
        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()
        XCTAssertNil(commandBuffer.error)
        renderer.commandBuffer = nil
        XCTAssertEqual(copy.width, 210)
        XCTAssertEqual(copy.height, 90)
        let image = try renderer.readback(copy)
        let bytes = image.dataProvider!.data! as Data
        XCTAssertEqual(Array(bytes[0..<3]), [0, 255, 0])
        let center = 45 * image.bytesPerRow + 105 * 4
        XCTAssertEqual(Array(bytes[center..<(center + 3)]), [0, 0, 255])
        XCTAssertTrue(renderer.warnings.isEmpty, "\(renderer.warnings)")
    }
}
