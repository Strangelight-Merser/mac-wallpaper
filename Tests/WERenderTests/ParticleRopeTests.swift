import XCTest
import simd
import WEShader
import WEFormat
@testable import WERender

final class ParticleRopeTests: ParticleTestCase {
    func testHistoryPackingUVAndCompaction() throws {
        let style = ParticleRenderStyle(values(["name": "ropetrail", "segments": 4, "length": 0.4, "uvsmoothing": false]))
        XCTAssertTrue(style.rope)
        let h = ParticleHistory(style: style)
        var p = ParticleState(); p.lifetime = 10; p.size = 2; p.color = [0.2, 0.3, 0.4]; p.alpha = 0.5
        h.insert(p, at: 0)
        for i in 1...3 { p.position.x = Float(i); h.record([p], dt: 0.1) }
        var vertices: [Float] = []
        ParticleRopeVertices.build([p], history: h, time: 0.3, into: &vertices)
        XCTAssertEqual(vertices.count, 3 * 4 * 26)
        XCTAssertEqual(Array(vertices[22..<26]), [0.2, 0.3, 0.4, 0.5])
        var last: Float = 1
        for q in 0..<3 {
            let base = q * 4 * 26
            let usable = vertices[base + 7] - 1
            let start = 1 - vertices[base + 11] / usable
            XCTAssertEqual(start, last, accuracy: 0.0001)
            last = start - 1 / usable
        }
        XCTAssertEqual(last, 0, accuracy: 0.0001)
        let expected = vertices
        h.insert(p, at: 1); h.move(from: 0, to: 1); h.move(from: 1, to: 0)
        ParticleRopeVertices.build([p], history: h, time: 0.3, into: &vertices)
        XCTAssertEqual(vertices, expected)
    }

    func testInvalidHistoryIsSkippedAndSeekRebuildsHistory() throws {
        let style = ParticleRenderStyle(values(["name": "ropetrail"]))
        let h = ParticleHistory(style: style)
        var p = ParticleState(); p.position.x = .nan
        h.insert(p, at: 0); h.record([p], dt: 0.1)
        var vertices: [Float] = []
        ParticleRopeVertices.build([p], history: h, time: 0, into: &vertices)
        XCTAssertTrue(vertices.isEmpty)
        let s = try simulation(["renderer": [["name": "ropetrail", "segments": 4, "length": 0.2]],
                               "initializer": [["name": "velocityrandom", "min": "10 0 0", "max": "10 0 0"]],
                               "operator": [["name": "movement"]]])
        s.advance(to: 0.5)
        ParticleRopeVertices.build(s.particles, history: s.histories[0]!, time: 0.5, into: &vertices)
        let expected = vertices
        XCTAssertFalse(expected.isEmpty)
        s.advance(to: 2); s.advance(to: 0.5)
        ParticleRopeVertices.build(s.particles, history: s.histories[0]!, time: 0.5, into: &vertices)
        XCTAssertEqual(vertices, expected)
    }

    func testStockRopeShaderCompilesWithoutMetal() throws {
        let assets = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("samples/wallpaper_engine/assets")
        let locator = AssetLocator(project: folder, assets: assets)
        guard locator.exists("shaders/genericropeparticle.vert") else { throw XCTSkip("stock shaders unavailable") }
        let vs = try locator.string("shaders/genericropeparticle.vert")
            .replacingOccurrences(of: "right * uvs.x * 2.0 - 1.0", with: "right * (uvs.x * 2.0 - 1.0)")
        let fs = try locator.string("shaders/genericropeparticle.frag")
        let combos = ["GS_ENABLED": 0, "THICKFORMAT": 1, "TRAILRENDERER": 0, "TRAILSCROLLALPHA": 0,
                      "LIGHTING": 0, "REFRACT": 0, "FOG": 0, "FOG_DIST": 0, "FOG_HEIGHT": 0]
        let v = try XCTUnwrap(ShaderPreprocessor.process(vs, stage: .vertex, fileDirectory: "shaders", locator: locator, overrides: combos))
        let f = try XCTUnwrap(ShaderPreprocessor.process(fs, stage: .fragment, fileDirectory: "shaders", locator: locator, overrides: combos))
        let program = try ShaderCompiler.compile(vertex: v.source, fragment: f.source)
        let descriptor = SceneRenderer.particleVertexDescriptor(attributes: program.vertex.attributes)
        XCTAssertEqual(descriptor.layouts[SceneRenderer.vertexBufferIndex].stride, 26 * 4)
        for (name, index) in program.vertex.attributes {
            let expected = try XCTUnwrap(ParticleRopeVertices.attributes.first { $0.name == name })
            XCTAssertEqual(descriptor.attributes[index].offset, expected.offset * 4)
        }
    }
    func testStockRegressionFixtureParsesAndSimulates() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let assets = root.appendingPathComponent("samples/wallpaper_engine/assets")
        guard FileManager.default.fileExists(atPath: assets.path) else { throw XCTSkip("stock assets unavailable") }
        let project = root.appendingPathComponent("regression/fixtures/particletest2")
        let scene = try SceneDescription(project: project, locator: AssetLocator(project: project, assets: assets))
        XCTAssertTrue(scene.notes.isEmpty, scene.notes.joined(separator: "\n"))
        XCTAssertEqual(scene.particles.count, 7)
        XCTAssertEqual(scene.scripts.first(where: { $0.object == 4 })?.properties.count, 3)
        for d in scene.particles where d.childType == .static {
            let simulation = ParticleSimulation(d)
            simulation.advance(to: 3)
            XCTAssertFalse(simulation.particles.isEmpty)
            for child in simulation.children { XCTAssertFalse(child.particles.isEmpty) }
        }
    }

}
