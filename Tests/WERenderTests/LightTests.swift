import XCTest
import Metal
import simd
import WEFormat
import WEShader
import WELibrary
@testable import WERender

final class LightTests: XCTestCase {
    func fixture(_ objects: [[String: Any]], general: [String: Any] = [:]) throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir.appendingPathComponent("shaders"), withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        func json(_ name: String, _ value: [String: Any]) throws {
            try JSONSerialization.data(withJSONObject: value).write(to: dir.appendingPathComponent(name))
        }
        try json("project.json", ["type": "scene", "file": "scene.json", "general": ["properties": ["power": ["value": 2]]]])
        try json("scene.json", ["general": general.merging(["orthogonalprojection": ["width": 64, "height": 64]]) { a, _ in a }, "objects": objects])
        try json("model.json", ["material": "material.json", "width": 64, "height": 64])
        try json("material.json", ["passes": [["shader": "testlit", "combos": ["LIGHTING": 1]]]])
        try json("effect.json", ["passes": [["material": "shape.json"]]])
        try json("shape.json", ["passes": [["shader": "testshape", "combos": ["DIRECTDRAW": 1]]]])
        let vertex = """
        uniform mat4 g_ModelViewProjectionMatrix;
        attribute vec3 a_Position;
        attribute vec2 a_TexCoord;
        varying vec2 uv;
        void main() { uv = a_TexCoord; gl_Position = mul(vec4(a_Position, 1.0), g_ModelViewProjectionMatrix); }
        """
        let litVertex = """
        uniform mat4 g_ModelMatrix;
        uniform mat4 g_ViewProjectionMatrix;
        attribute vec3 a_Position;
        varying vec3 world;
        void main() { vec4 p = mul(vec4(a_Position, 1.0), g_ModelMatrix); world = p.xyz; gl_Position = mul(p, g_ViewProjectionMatrix); }
        """
        let litFragment = """
        varying vec3 world;
        uniform vec4 g_LPoint_Origin[LIGHTS_POINT];
        uniform vec4 g_LPoint_Color[LIGHTS_POINT];
        void main() { float a = max(0.0, 1.0 - length(world - g_LPoint_Origin[0].xyz) / g_LPoint_Color[0].w); gl_FragColor = vec4(g_LPoint_Color[0].rgb * a, 1.0); }
        """
        let copy = "varying vec2 uv; uniform sampler2D g_Texture0; void main() { gl_FragColor = texSample2D(g_Texture0, uv); }"
        // Self-authored blur for the offline fixture; stock blur compilation has a separate test.
        let blur = """
        varying vec2 uv; uniform sampler2D g_Texture0; uniform vec4 g_Texture0Resolution;
        void main() {
        #if VERTICAL
        vec2 d = vec2(0.0, 1.0 / g_Texture0Resolution.y);
        #else
        vec2 d = vec2(1.0 / g_Texture0Resolution.x, 0.0);
        #endif
        gl_FragColor = texSample2D(g_Texture0, uv) * 0.5 + (texSample2D(g_Texture0, uv + d) + texSample2D(g_Texture0, uv - d)) * 0.25;
        }
        """
        for (name, vs, fs) in [("testlit", litVertex, litFragment), ("testshape", vertex, "varying vec2 uv; void main() { gl_FragColor = vec4(0.2, 0.0, 0.0, 1.0); }"), ("blur_k3", vertex, blur), ("passthrough", vertex, copy)] {
            try vs.write(to: dir.appendingPathComponent("shaders/\(name).vert"), atomically: true, encoding: .utf8)
            try fs.write(to: dir.appendingPathComponent("shaders/\(name).frag"), atomically: true, encoding: .utf8)
        }
        return dir
    }

    func testKindsDefaultsBindingsAndShape() throws {
        let dir = try fixture([
            ["id": 10, "origin": "10 20 0"],
            ["id": 1, "light": "lpoint", "parent": 10, "origin": "1 2 3", "intensity": ["user": "power", "value": 1]],
            ["id": 2, "light": "lspot", "angles": "0 1.5707963 0"],
            ["id": 3, "light": "ltube", "length": 20], ["id": 4, "light": "ldirectional"],
            ["id": 5, "shape": "quad", "origin": "12 15 0", "scale": "2 3 1", "size": "8 10", "effects": [["file": "effect.json"]]],
            ["id": 6, "shape": "quad"], ["id": 7, "shape": "circle"]
        ], general: ["lightconfig": ["point": 10], "ambientcolor": "0.1 0.2 0.3"])
        let s = try SceneDescription(project: dir, locator: AssetLocator(project: dir, assets: nil))
        XCTAssertEqual(s.lights.map(\.kind), [.point, .spot, .tube, .directional])
        XCTAssertEqual(s.lights[0].intensity, 2); XCTAssertEqual(s.lights[0].radius, 500)
        XCTAssertFalse(s.lights[0].castVolumetrics)
        XCTAssertEqual(s.nodes[1]?.parent, 10); XCTAssertEqual(s.nodes[1]?.origin, [1, 2, 3])
        XCTAssertEqual(s.lightCombos["LIGHTS_POINT"], 10); XCTAssertEqual(s.lightCombos["LIGHTS_SPOT"], 1)
        XCTAssertEqual(s.ambientColor, [0.1, 0.2, 0.3])
        XCTAssertEqual(s.layers[0].size, [8, 10]); XCTAssertEqual(s.layers[0].origin, [12, 15, 0]); XCTAssertEqual(s.layers[0].scale, [2, 3, 1])
        XCTAssertTrue(s.layers[0].isShape); XCTAssertEqual(s.layers[1].size, [64, 64])
        XCTAssertEqual(s.layers[0].passes[0].combos["DIRECTDRAW"], 1)
        XCTAssertEqual(s.notes.count, 1); XCTAssertTrue(s.notes[0].contains("unsupported shape"))
        XCTAssertTrue(try XCTUnwrap(s.userBindings.first { $0.path == "intensity" }).supportsLive)
    }

    func testPackingOrderingPaddingAndTransforms() throws {
        let props = UserProperties(project: [:])
        let frames = try (0..<6).map { i -> FrameLight in
            let light = try XCTUnwrap(SceneLight(["id": i, "light": "lpoint", "color": "1 2 3", "radius": 100, "intensity": 2], properties: props))
            return light.transformed(translation([Float(i * 10), 0, 5]))
        }
        let u = LightUniforms(lights: frames, ambient: [0.1, 0.2, 0.3], skylight: [0.4, 0.5, 0.6])
        XCTAssertEqual(u.values("g_LightsPosition", count: 4, reference: [50, 0, 0]).map { $0[0] }, [50, 40, 30, 20])
        XCTAssertEqual(u.values("g_LightsColorRadius", count: 4, reference: .zero)[0], [2, 4, 6, 100])
        XCTAssertEqual(u.values("g_LightsColorPremultiplied", count: 3, reference: .zero), [[20000, 40000, 60000, 20000], [20000, 40000, 60000, 40000], [20000, 40000, 60000, 60000]])
        XCTAssertEqual(u.values("g_LPoint_Color", count: 8, reference: .zero)[6], [0, 0, 0, 1])
        XCTAssertEqual(u.values("g_LPoint_Color", count: 6, reference: .zero, premultiplyTyped: true)[0], [20000, 40000, 60000, 100])
        let spot = try XCTUnwrap(SceneLight(["id": 7, "light": "lspot", "coneangle": 30, "coneangleouter": 60], properties: props))
        let tube = try XCTUnwrap(SceneLight(["id": 8, "light": "ltube", "length": 20], properties: props))
        let typed = LightUniforms(lights: [spot.transformed(translation([1, 2, 3])), tube.transformed(translation([10, 20, 30]) * rotationZ(.pi / 2))], ambient: .zero, skylight: .zero)
        XCTAssertEqual(typed.values("g_LSpot_Direction", count: 1, reference: .zero)[0][3], 0.5, accuracy: 0.0001)
        XCTAssertEqual(typed.values("g_LTube_OriginA", count: 1, reference: .zero)[0][1], 10, accuracy: 0.0001)
        XCTAssertEqual(typed.values("g_LTube_OriginB", count: 1, reference: .zero)[0][1], 30, accuracy: 0.0001)
    }

    func testLitPixelsAndLiveLight() throws {
        guard MTLCreateSystemDefaultDevice() != nil else { throw XCTSkip("Metal unavailable") }
        let dir = try fixture([["id": 1, "image": "model.json"], ["id": 2, "light": "lpoint", "origin": "16 32 8", "radius": 40, "intensity": ["user": "power", "value": 1]]])
        let r = try SceneRenderer(project: dir, assets: nil)
        let image = try r.render(width: 64, height: 64, time: 0)
        XCTAssertGreaterThan(try red(image, 16, 32), try red(image, 60, 32))
        XCTAssertTrue(r.setUserProperties(["power": "0"]))
        let off = try r.render(width: 64, height: 64, time: 1)
        XCTAssertEqual(try red(off, 16, 32), 0)
        r.setValue(.vec3([48, 32, 8]), object: 2, property: "origin")
        r.setValue(.number(1), object: 2, property: "intensity")
        let moved = try r.render(width: 64, height: 64, time: 2)
        XCTAssertGreaterThan(try red(moved, 48, 32), try red(moved, 4, 32))
        XCTAssertTrue(r.warnings.isEmpty, r.warnings.joined(separator: "\n"))
    }

    func testVolumetricPixelsAndShapePlacement() throws {
        guard MTLCreateSystemDefaultDevice() != nil else { throw XCTSkip("Metal unavailable") }
        let dir = try fixture([["id": 1, "light": "lpoint", "origin": "32 32 12", "radius": 20, "intensity": 3, "castvolumetrics": true],
                               ["id": 2, "shape": "quad", "origin": "8 8 0", "size": "8 8", "effects": [["file": "effect.json"]]]])
        let r = try SceneRenderer(project: dir, assets: nil)
        r.enableApproximateVolumetrics = false
        let off = try r.render(width: 64, height: 64, time: 0)
        XCTAssertGreaterThan(try red(off, 8, 56), try red(off, 20, 56))
        r.enableApproximateVolumetrics = true
        let on = try r.render(width: 64, height: 64, time: 0)
        XCTAssertGreaterThan(try red(on, 32, 32), try red(off, 32, 32))
        XCTAssertEqual(try red(on, 60, 4), try red(off, 60, 4))
        XCTAssertTrue(r.warnings.isEmpty, r.warnings.joined(separator: "\n"))
    }

    func red(_ image: CGImage, _ x: Int, _ y: Int) throws -> UInt8 {
        let data = try XCTUnwrap(image.dataProvider?.data) as Data
        return data[y * image.bytesPerRow + x * 4]
    }

    func testCompatibilityAndScriptFields() async throws {
        let dir = try fixture(SceneLight.Kind.allCases.enumerated().map { ["id": $0.offset, "light": $0.element.rawValue, "castvolumetrics": true] })
        let result = await CompatibilityChecker(assets: dir).check(WallpaperEntry(folder: dir, root: .userFolder), deep: false)
        XCTAssertNil(result.missing[.light]); XCTAssertEqual(result.status, .supported)
        var light = try XCTUnwrap(SceneLight(["id": 1, "light": "lpoint"], properties: UserProperties(project: [:])))
        XCTAssertTrue(light.setScriptValue(.number(3), "intensity"))
        XCTAssertTrue(light.setScriptValue(.vec3([0.2, 0.4, 0.6]), "color"))
        XCTAssertEqual(light.intensity, 3); XCTAssertEqual(light.color, [0.2, 0.4, 0.6])
        XCTAssertTrue(light.setScriptValue(.bool(true), "castvolumetrics")); XCTAssertTrue(light.castVolumetrics)
        if case .number(let value) = light.scriptValue("intensity") { XCTAssertEqual(value, 3) } else { XCTFail("missing script value") }
    }

    func testStockLitPixels() throws {
        guard MTLCreateSystemDefaultDevice() != nil else { throw XCTSkip("Metal unavailable") }
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let assets = root.appendingPathComponent("samples/wallpaper_engine/assets")
        guard FileManager.default.fileExists(atPath: assets.path) else { throw XCTSkip("WE assets unavailable") }
        let dir = try fixture([["id": 1, "image": "model.json"], ["id": 2, "light": "lpoint", "origin": "16 32 8", "radius": 40, "intensity": 2]], general: ["ambientcolor": "0 0 0"])
        let material: [String: Any] = ["passes": [["shader": "genericimage4", "textures": ["util/white"], "combos": ["LIGHTING": 1]]]]
        try JSONSerialization.data(withJSONObject: material).write(to: dir.appendingPathComponent("material.json"))
        let renderer = try SceneRenderer(project: dir, assets: assets)
        let image = try renderer.render(width: 64, height: 64, time: 0)
        XCTAssertGreaterThan(try red(image, 16, 32), try red(image, 60, 32))
        XCTAssertTrue(renderer.warnings.isEmpty, renderer.warnings.joined(separator: "\n"))
    }

    func testStockLitShaderCompilation() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let assets = root.appendingPathComponent("samples/wallpaper_engine/assets")
        guard FileManager.default.fileExists(atPath: assets.path) else { throw XCTSkip("WE assets unavailable") }
        let locator = AssetLocator(project: root, assets: assets)
        for shader in ["genericimage2", "genericimage3", "genericimage4", "generic2", "generic3", "generic4", "genericparticle", "blur_k3"] {
            for normals in [0, 1] {
                let combos = ["LIGHTING": 1, "NORMALMAP": normals, "PBRMASKS": normals, "LIGHTS_POINT": 6, "LIGHTS_SPOT": 1, "LIGHTS_TUBE": 1, "LIGHTS_DIRECTIONAL": 1]
                func source(_ ext: String, _ stage: ShaderPreprocessor.Stage) throws -> String {
                    let raw = SceneRenderer.prepareLightingShader(try locator.string("shaders/\(shader).\(ext)"))
                    return try XCTUnwrap(ShaderPreprocessor.process(raw, stage: stage, fileDirectory: "shaders", locator: locator, overrides: combos)).source
                }
                do { _ = try ShaderCompiler.compile(vertex: source("vert", .vertex), fragment: source("frag", .fragment)) }
                catch { XCTFail("\(shader) NORMALMAP=\(normals): \(error)") }
            }
        }
    }
}
