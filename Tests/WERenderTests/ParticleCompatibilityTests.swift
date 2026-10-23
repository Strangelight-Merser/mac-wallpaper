import XCTest
import WELibrary
@testable import WERender

final class ParticleCompatibilityTests: ParticleTestCase {
    func check(_ definition: [String: Any]) async throws -> Compatibility {
        try json("project.json", ["type": "scene", "file": "scene.json", "title": "Particle fixture"])
        try json("scene.json", ["objects": [["id": 1, "name": "p", "particle": definition]]])
        let shaders = folder.appendingPathComponent("shaders")
        try FileManager.default.createDirectory(at: shaders, withIntermediateDirectories: true)
        for ext in ["vert", "frag"] {
            for name in ["genericparticle", "genericropeparticle"] {
                try Data("void main() {}".utf8).write(to: shaders.appendingPathComponent("\(name).\(ext)"))
            }
        }
        return await CompatibilityChecker(assets: folder).check(WallpaperEntry(folder: folder, root: .userFolder), deep: false)
    }

    func testParticleOnlySceneSupportedAndVersionBumped() async throws {
        let result = try await check(["material": "material.json", "emitter": [["name": "sphererandom"]]])
        XCTAssertEqual(result.status, .supported); XCTAssertTrue(result.missing.isEmpty)
        XCTAssertEqual(result.checkerVersion, CompatibilityChecker.version); XCTAssertFalse(result.checkedDeep)
    }

    func testOnlyUnsupportedParticleFeaturesReported() async throws {
        let result = try await check(["material": "material.json", "operator": [["name": "unimplemented"]],
            "children": [["type": "death"]]])
        XCTAssertEqual(result.status, .partial); XCTAssertEqual(result.missing[.particles], 1)
        XCTAssertTrue(result.notes.contains(where: { $0.contains("unimplemented") }))
        XCTAssertTrue(result.notes.contains(where: { $0.contains("event child death") }))
        let rope = try await check(["material": "material.json", "renderer": [["name": "ropetrail"]]])
        XCTAssertEqual(rope.status, .supported); XCTAssertNil(rope.missing[.particles])
    }

    func testParticleTextureMissingReportedAsAsset() async throws {
        try json("material.json", ["passes": [["shader": "genericparticle", "textures": ["missing"]]]])
        let result = try await check(["material": "material.json"])
        XCTAssertEqual(result.status, .unsupported); XCTAssertEqual(result.missing[.missingAsset], 1)
        XCTAssertNil(result.missing[.particles])
    }
    func testEventChildrenAreSupported() async throws {
        let result = try await check(["material": "material.json", "children":
            ["eventspawn", "eventdeath", "eventfollow"].map { ["type": $0, "particle": ["material": "material.json"]] as [String: Any] }])
        XCTAssertEqual(result.status, .supported)
        XCTAssertNil(result.missing[.particles])
        XCTAssertTrue(result.notes.isEmpty)
    }

}
