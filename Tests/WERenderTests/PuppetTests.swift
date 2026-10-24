import XCTest
import Metal
import simd
import WEFormat
import WEShader
@testable import WERender

private struct MDLFixture {
    var data = Data()
    mutating func u32(_ n: UInt32) { var n = n.littleEndian; data.append(withUnsafeBytes(of: &n) { Data($0) }) }
    mutating func u16(_ n: UInt16) { var n = n.littleEndian; data.append(withUnsafeBytes(of: &n) { Data($0) }) }
    mutating func byte(_ n: UInt8) { data.append(n) }
    mutating func string(_ s: String) { data.append(contentsOf: s.utf8); byte(0) }
    mutating func floats(_ values: [Float]) { for f in values { u32(f.bitPattern) } }
    mutating func tag(_ name: String, _ version: Int) { string(String(format: "%@%04d", name, version)) }
}

private func syntheticMDL(vertex: Int = 23, skeleton: Int = 4, animation: Int = 6,
                          extended: Bool = true, skinned: Bool = true, mode: String = "loop",
                          attachment: Bool = false, rotate: Bool = false, shiftedBase: Bool = false) -> Data {
    var f = MDLFixture()
    f.tag("MDLV", vertex); f.u32(skinned ? 0x01800009 : 9); f.u32(1); f.u32(1)
    f.string("material.json"); f.u32(0)
    if extended { for _ in 0..<6 { f.u32(0) }; f.u32(skinned ? 0x0180000f : 15) }
    else { f.u32(0x01800009) }
    f.u32(UInt32((extended ? (skinned ? 80 : 48) : (skinned ? 52 : 20)) * 3))
    for (p, uv) in [([-10, -5, 0] as [Float], [0, 1] as [Float]), ([10, -5, 0], [1, 1]), ([0, 15, 0], [0.5, 0])] {
        f.floats(p)
        if extended { f.floats([0, 0, 1, 1, 0, 0, 1]) }
        if skinned { for _ in 0..<4 { f.u32(0) }; f.floats([1, 0, 0, 0]) }
        f.floats(uv)
    }
    f.u32(6); f.u16(0); f.u16(1); f.u16(2)
    if vertex == 23 && extended {
        f.byte(1); f.u32(1); f.u32(36); f.floats(Array(repeating: 0, count: 9))
        f.byte(1); f.u32(16); for _ in 0..<4 { f.u32(0) }; f.u32(0)
    }
    if !skinned { return f.data }
    f.tag("MDLS", skeleton); let skeletonEndOffset = f.data.count; f.u32(0); f.u16(2); f.u16(0)
    for i in 0..<2 {
        f.string("bone\(i)"); f.u32(1); f.u32(i == 0 ? .max : 0); f.u32(64)
        f.floats([1,0,0,0, 0,1,0,0, 0,0,1,0, Float(i)*2,0,0,1]); f.string("")
    }
    if skeleton > 1 {
        f.u16(0); f.byte(1); f.floats(Array(repeating: 0, count: 32))
        f.u32(1); f.u32(0); f.u32(0); f.u32(0); f.u32(0)
        f.byte(1); f.floats(Array(repeating: 0, count: 38)); f.byte(1); f.u32(0); f.u32(1)
    }
    f.u32(100); f.u32(UInt32.max - 199)
    var sectionEnd = UInt32(f.data.count).littleEndian
    f.data.replaceSubrange(skeletonEndOffset..<skeletonEndOffset + 4, with: withUnsafeBytes(of: &sectionEnd) { Data($0) })
    f.byte(0)
    if attachment { f.tag("MDAT", 1); f.u32(0); f.u16(1); f.u16(0); f.string("attachment"); f.floats(Array(repeating: 0, count: 16)) }
    f.tag("MDLA", animation)
    if animation == 0 { return f.data }
    f.u32(0); f.u32(2)
    for id in 1...2 {
        f.u32(0); f.u32(UInt32(id)); f.u32(0); f.string("animation\(id)"); f.string(mode)
        f.floats([2]); f.u32(2); f.u32(0); f.u32(2)
        for bone in 0..<2 {
            f.u32(UInt32(bone)); f.u32(72)
            for frame in 0..<2 {
                f.floats([Float(bone)*2 + (bone == 0 && !rotate ? Float((frame + (shiftedBase ? 1 : 0)) * id * 10) : 0), 0, 0,
                          0, 0, rotate && bone == 0 ? Float(frame) * .pi/2 : 0, 1, 1, 1])
            }
        }
        if extended { f.u16(0) }
        else if animation == 3 { f.byte(0) }
        else { f.u32(1); f.floats([0]); f.string("event") }
    }
    return f.data
}

final class PuppetTests: ParticleTestCase {
    func testLayoutsAndVersions() throws {
        for v in [13, 23] {
            for s in 1...4 {
                for a in 0...6 {
                    for extended in [false, true] {
                        let m = try PuppetModel(data: syntheticMDL(vertex: v, skeleton: s, animation: a, extended: extended, attachment: true))
                        XCTAssertEqual(m.vertexVersion, v); XCTAssertEqual(m.skeletonVersion, s); XCTAssertEqual(m.animationVersion, a)
                        XCTAssertEqual(m.vertexStride, extended ? 80 : 52)
                        XCTAssertEqual(m.vertices.count, 3); XCTAssertEqual(m.indices, [0, 1, 2])
                        XCTAssertEqual(m.bones.count, 2); XCTAssertEqual(m.bones[1].parent, 0)
                        XCTAssertEqual(m.animations.count, a == 0 ? 0 : 2)
                    }
                }
            }
        }
        for extended in [false, true] {
            let m = try PuppetModel(data: syntheticMDL(extended: extended, skinned: false))
            XCTAssertEqual(m.vertexStride, extended ? 48 : 20); XCTAssertTrue(m.bones.isEmpty)
        }
    }

    func testMalformedDataAndUnknownVersions() throws {
        for bytes in [Data(), Data("MDLV9999\0".utf8), syntheticMDL().prefix(80)] {
            XCTAssertThrowsError(try PuppetModel(data: bytes))
        }
        let bytes = syntheticMDL()
        for section in ["MDLS0004", "MDLA0006"] {
            var unknown = bytes
            let range = try XCTUnwrap(unknown.range(of: Data(section.utf8)))
            unknown.replaceSubrange(range, with: Data((section.prefix(4) + "9999").utf8))
            XCTAssertThrowsError(try PuppetModel(data: unknown))
        }
        for end in stride(from: 100, to: bytes.count - 3, by: 31) {
            XCTAssertThrowsError(try PuppetModel(data: bytes.prefix(end)))
        }
    }

    func testInterpolationHierarchyAndDeterminism() throws {
        let m = try PuppetModel(data: syntheticMDL())
        let layers = [PuppetModel.Layer(animation: 1)]
        for (t, x) in [(0.0, Float(0)), (0.25, 5), (0.5, 10), (0.75, 5), (1, 0), (-0.25, 5)] {
            let pose = m.matrices(layers: layers, time: t)
            for bone in pose { XCTAssertEqual(bone.columns.3.x, x, accuracy: 0.0001) }
            _ = m.matrices(layers: layers, time: 123)
            XCTAssertEqual(pose[0], m.matrices(layers: layers, time: t)[0])
        }
        XCTAssertEqual(m.matrices(layers: [], time: 10)[1], matrix_identity_float4x4)
        XCTAssertEqual(m.matrices(layers: [.init(animation: 1, visible: false)], time: 0.5)[0], matrix_identity_float4x4)
        XCTAssertEqual(m.matrices(layers: [.init(animation: 1, rate: 2)], time: 0.25)[0].columns.3.x, 10, accuracy: 0.0001)
        XCTAssertEqual(m.matrices(layers: [.init(animation: 1, rate: 0)], time: 7)[0].columns.3.x, 0)
    }

    func testMirrorSingleAndBlending() throws {
        for (mode, cases) in [("mirror", [(0.75, Float(10)), (1.0, 10), (1.25, 5), (1.5, 0), (2.0, 0)]),
                              ("single", [(0.25, Float(5)), (0.5, 10), (9.0, 10)])] {
            let m = try PuppetModel(data: syntheticMDL(mode: mode))
            for (time, expected) in cases { XCTAssertEqual(m.matrices(layers: [.init(animation: 1)], time: time)[0].columns.3.x, expected, accuracy: 0.0001) }
        }
        let m = try PuppetModel(data: syntheticMDL())
        for blend: Float in [0.25, 0.5, 1] {
            let pose = m.matrices(layers: [.init(animation: 1, blend: blend), .init(animation: 2, blend: blend)], time: 0.5)
            XCTAssertEqual(pose[0].columns.3.x, 30 * blend, accuracy: 0.0001)
        }
        let shifted = try PuppetModel(data: syntheticMDL(shiftedBase: true))
        for (blend, initial, moved): (Float, Float, Float) in [(0.25, 6.875, 14.375), (1, 15, 45)] {
            let layers: [PuppetModel.Layer] = [.init(animation: 1, blend: blend), .init(animation: 2, blend: blend)]
            XCTAssertEqual(shifted.matrices(layers: layers, time: 0)[0].columns.3.x, initial, accuracy: 0.0001)
            XCTAssertEqual(shifted.matrices(layers: layers, time: 0.5)[0].columns.3.x, moved, accuracy: 0.0001)
        }
        let rotated = try PuppetModel(data: syntheticMDL(rotate: true))
        let pose = rotated.matrices(layers: [.init(animation: 1)], time: 0.25)
        let point = pose[1] * SIMD4<Float>(2, 0, 0, 1)
        XCTAssertEqual(point.x, sqrt(2), accuracy: 0.0001); XCTAssertEqual(point.y, sqrt(2), accuracy: 0.0001)
    }

    func testGenericImageSkinningCompilation() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let assets = root.appendingPathComponent("samples/wallpaper_engine/assets")
        let locator = AssetLocator(project: folder, assets: assets)
        guard FileManager.default.fileExists(atPath: assets.appendingPathComponent("shaders/genericimage2.vert").path) else { throw XCTSkip("WE shader assets unavailable") }
        let combos = ["SKINNING": 1, "BONECOUNT": 4]
        let v = try XCTUnwrap(ShaderPreprocessor.process(locator.string("shaders/genericimage2.vert"), stage: .vertex, fileDirectory: "shaders", locator: locator, overrides: combos))
        let f = try XCTUnwrap(ShaderPreprocessor.process(locator.string("shaders/genericimage2.frag"), stage: .fragment, fileDirectory: "shaders", locator: locator, overrides: combos))
        let program = try ShaderCompiler.compile(vertex: v.source, fragment: f.source)
        let bones = try XCTUnwrap(program.vertex.uniforms.first { $0.name == "g_Bones" })
        XCTAssertEqual(bones.type, "mat4x3"); XCTAssertEqual(bones.arrayCount, 4); XCTAssertEqual(bones.arrayStride, 64)
        XCTAssertNotNil(program.vertex.attributes["a_BlendIndices"])
        guard let device = MTLCreateSystemDefaultDevice() else { throw XCTSkip("Metal unavailable; GLSL/SPIR-V compilation passed") }
        XCTAssertNoThrow(try device.makeLibrary(source: program.vertex.msl, options: nil))
    }

    func testSceneLoadingAndFallbackWithoutMetal() throws {
        try json("project.json", ["file": "scene.json", "type": "scene"])
        try json("model.json", ["material": "material.json", "puppet": "puppet.mdl"])
        try json("scene.json", ["objects": [["id": 1, "image": "model.json", "animationlayers": [["animation": 2, "rate": 0.5, "blend": 0.25, "visible": false]]]]])
        try syntheticMDL().write(to: folder.appendingPathComponent("puppet.mdl"))
        var scene = try SceneDescription(project: folder, locator: locator)
        XCTAssertEqual(scene.layers[0].puppet?.bones.count, 2)
        XCTAssertEqual(scene.layers[0].animationLayers.first?.rate, 0.5)
        XCTAssertEqual(scene.layers[0].animationLayers.first?.blend, 0.25)
        XCTAssertEqual(scene.layers[0].animationLayers.first?.visible, false)
        try Data("MDLV9999\0".utf8).write(to: folder.appendingPathComponent("puppet.mdl"))
        scene = try SceneDescription(project: folder, locator: locator)
        XCTAssertNil(scene.layers[0].puppet)
        XCTAssertEqual(scene.notes.filter { $0.contains("MDLV9999") }.count, 1)
    }

    func testSyntheticRenderAndFallback() throws {
        guard MTLCreateSystemDefaultDevice() != nil else { throw XCTSkip("Metal unavailable") }
        try json("project.json", ["file": "scene.json", "type": "scene"])
        try json("model.json", ["material": "material.json", "puppet": "puppet.mdl"])
        try json("material.json", ["passes": [["shader": "puppet"]]])
        try json("scene.json", ["general": ["orthogonalprojection": ["width": 64, "height": 64]], "objects": [
            ["id": 1, "name": "puppet", "image": "model.json", "size": "64 64", "origin": "32 32 0", "animationlayers": [["animation": 1]]]]])
        try syntheticMDL(rotate: true).write(to: folder.appendingPathComponent("puppet.mdl"))
        let shaders = folder.appendingPathComponent("shaders")
        try FileManager.default.createDirectory(at: shaders, withIntermediateDirectories: true)
        try """
        uniform mat4 g_ModelViewProjectionMatrix;
        attribute vec3 a_Position;
        attribute vec2 a_TexCoord;
        #if SKINNING
        uniform mat4x3 g_Bones[BONECOUNT];
        attribute uvec4 a_BlendIndices;
        attribute vec4 a_BlendWeights;
        #endif
        void main() {
            vec3 p = a_Position;
        #if SKINNING
            p = g_Bones[a_BlendIndices.x] * vec4(p, 1.0);
        #endif
            gl_Position = g_ModelViewProjectionMatrix * vec4(p, 1.0);
        }
        """.write(to: shaders.appendingPathComponent("puppet.vert"), atomically: true, encoding: .utf8)
        try "void main() { gl_FragColor = vec4(1.0, 0.0, 0.0, 1.0); }".write(to: shaders.appendingPathComponent("puppet.frag"), atomically: true, encoding: .utf8)
        let renderer = try SceneRenderer(project: folder, assets: nil)
        func pixels(_ time: Float) throws -> Data { try XCTUnwrap(renderer.render(width: 64, height: 64, time: time).dataProvider?.data) as Data }
        let a = try pixels(0), b = try pixels(0.5)
        XCTAssertNotEqual(a, b); XCTAssertEqual(a, try pixels(0))
        XCTAssertTrue(renderer.plans.values.contains { $0.puppet != nil && $0.isDynamic })
        XCTAssertTrue(renderer.warnings.isEmpty, "\(renderer.warnings)")
        try Data("MDLV9999\0".utf8).write(to: folder.appendingPathComponent("puppet.mdl"))
        let fallback = try SceneRenderer(project: folder, assets: nil)
        _ = try fallback.render(width: 64, height: 64, time: 0)
        XCTAssertNil(fallback.scene.layers[0].puppet)
        XCTAssertEqual(fallback.warnings.filter { $0.contains("MDLV9999") }.count, 1)
    }
}
