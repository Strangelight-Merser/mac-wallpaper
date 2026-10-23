import XCTest
import Metal
import simd
import WEShader
@testable import WERender

final class ParticleRenderingTests: ParticleTestCase {
    func testSpriteFrameSelection() {
        let sheet = ParticleSpriteSheet(durations: [0.1, 0.2, 0.1, 0.4])
        XCTAssertEqual(sheet.frame(age: 0.2, lifetime: 1, random: 0, mode: "sequence", multiplier: 1), 1.5, accuracy: 0.00001)
        XCTAssertEqual(sheet.frame(age: 0.1, lifetime: 1, random: 0, mode: "sequence", multiplier: 2), 1.5, accuracy: 0.00001)
        XCTAssertEqual(sheet.frame(age: 1, lifetime: 1, random: 0, mode: "sequence", multiplier: 1), 1.5, accuracy: 0.00001)
        XCTAssertEqual(sheet.frame(age: 0.5, lifetime: 1, random: 0, mode: "once", multiplier: 2), 3)
        for age: Float in [0, 0.4, 10] {
            XCTAssertEqual(sheet.frame(age: age, lifetime: 1, random: 0.6, mode: "randomframe", multiplier: 3), 2)
        }
        XCTAssertEqual(sheet.frame(age: 10, lifetime: 1, random: 0, mode: "sequence", multiplier: 0), 0)
    }

    func testAtlasFollowsFrameTableAndSeparateImages() throws {
        let red: [UInt8] = [255, 0, 0, 255], blue: [UInt8] = [0, 0, 255, 255], green: [UInt8] = [0, 255, 0, 255]
        let tex = try particleTex(images: [red + blue, green + red], width: 2, height: 1,
            frames: [(0, 0.1, [1, 0, 1, 0, 0, 1]), (1, 0.2, [0, 0, 1, 0, 0, 1]), (0, 0.3, [0, 0, 1, 0, 0, 1])])
        let atlas = try ParticleSpriteSheet.atlas(tex)
        XCTAssertEqual(atlas.columns, 2); XCTAssertEqual(atlas.rows, 2)
        XCTAssertEqual(atlas.width, 2); XCTAssertEqual(atlas.height, 2)
        XCTAssertEqual(atlas.pixels, blue + green + red + [0, 0, 0, 0])
    }

    func testRotatedAtlasFrame() throws {
        let pixels: [UInt8] = [1,0,0,255, 2,0,0,255, 3,0,0,255, 4,0,0,255]
        let tex = try particleTex(images: [pixels], width: 2, height: 2,
                                  frames: [(0, 1, [2, 0, 0, 2, -2, 0])])
        let atlas = try ParticleSpriteSheet.atlas(tex)
        XCTAssertEqual(stride(from: 0, to: atlas.pixels.count, by: 4).map { atlas.pixels[$0] }, [2, 4, 1, 3])
    }

    func testVertexPackingAndNonFiniteParticles() {
        var p = ParticleState()
        p.position = [1, 2, 3]; p.velocity = [4, 5, 6]; p.rotation = [0.1, 0.2, 0.3]
        p.color = [0.4, 0.5, 0.6]; p.alpha = 0.7; p.size = 8; p.age = 0.25
        var invalid = p; invalid.velocity.x = .nan
        var vertices: [Float] = []
        ParticleVertices.build([p, invalid], sheet: nil, mode: "sequence", multiplier: 1, trail: false, into: &vertices)
        XCTAssertEqual(vertices.count, 4 * 17)
        XCTAssertEqual(Array(vertices.prefix(17)), [1,2,3, 0,1,0.3,8, 0.4,0.5,0.6,0.7, 4,5,6,0.25, 0.1,0.2])
        XCTAssertEqual([vertices[3], vertices[20], vertices[37], vertices[54]], [0, 1, 1, 0])
        invalid = p; invalid.color.z = .infinity
        ParticleVertices.build([invalid], sheet: nil, mode: "sequence", multiplier: 1, trail: false, into: &vertices)
        XCTAssertTrue(vertices.isEmpty)
        p.velocity = .zero
        ParticleVertices.build([p], sheet: nil, mode: "sequence", multiplier: 1, trail: true, into: &vertices)
        XCTAssertTrue(vertices.isEmpty)
    }

    func testSpritePhasePacking() {
        var p = ParticleState(); p.age = 0.25; p.random = 0.6
        var vertices: [Float] = []
        let sheet = ParticleSpriteSheet(durations: [0.1, 0.1, 0.1, 0.1])
        ParticleVertices.build([p], sheet: sheet, mode: "sequence", multiplier: 1, trail: false, into: &vertices)
        XCTAssertEqual(vertices[14], 0.625, accuracy: 0.00001)
        ParticleVertices.build([p], sheet: sheet, mode: "randomframe", multiplier: 1, trail: false, into: &vertices)
        XCTAssertEqual(vertices[14], 0.625)
    }

    func testPerspectiveCanvasCenterAndCoverFit() {
        let projection = particlePerspective(canvas: [1920, 1080], output: [1920, 1080], fov: 50, near: 0.01, far: 10000)
        let center = projection * SIMD4<Float>(960, 540, 0, 1)
        XCTAssertEqual(center.x, 0, accuracy: 0.0001); XCTAssertEqual(center.y, 0, accuracy: 0.0001)
        XCTAssertTrue((0...1).contains(center.z / center.w))
        let p = projection * SIMD4<Float>(1060, 640, 0, 1)
        XCTAssertGreaterThan(p.x, 0); XCTAssertGreaterThan(p.y, 0)
        let square = particlePerspective(canvas: [1920, 1080], output: [1080, 1080], fov: 50, near: 0.01, far: 10000)
        let q = square * SIMD4<Float>(1060, 640, 0, 1)
        XCTAssertEqual(q.x / p.x, 1920 / 1080, accuracy: 0.0001)
        XCTAssertEqual(q.y, p.y, accuracy: 0.0001)
    }

    func testAttributeBindingUsesReflectedNames() throws {
        let vertex = """
        #version 330
        layout(location=7) in vec3 a_Position;
        layout(location=1) in vec4 a_TexCoordVec4;
        layout(location=5) in vec4 a_Color;
        layout(location=3) in vec4 a_TexCoordVec4C1;
        layout(location=2) in vec2 a_TexCoordC2;
        out vec4 color;
        void main() {
            gl_Position = vec4(a_Position + a_TexCoordVec4.xyz + a_TexCoordVec4C1.xyz, 1);
            color = a_Color + vec4(a_TexCoordC2, 0, 0);
        }
        """
        let fragment = "#version 330\nin vec4 color;\nout vec4 outColor;\nvoid main() { outColor = color; }"
        let compiled = try ShaderCompiler.compile(vertex: vertex, fragment: fragment)
        let descriptor = SceneRenderer.particleVertexDescriptor(attributes: compiled.vertex.attributes)
        XCTAssertEqual(descriptor.layouts[30].stride, 68)
        for (name, offset, components) in ParticleVertices.attributes {
            let index = try XCTUnwrap(compiled.vertex.attributes[name])
            XCTAssertEqual(descriptor.attributes[index].offset, offset * 4)
            XCTAssertEqual(descriptor.attributes[index].bufferIndex, 30)
            XCTAssertEqual(descriptor.attributes[index].format, components == 2 ? .float2 : components == 3 ? .float3 : .float4)
        }
    }
}
