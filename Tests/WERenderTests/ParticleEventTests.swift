import XCTest
import simd
import Metal
import WEFormat
@testable import WERender

final class ParticleEventTests: ParticleTestCase {
    func system(_ type: String, probability: Float = 1, limit: Int = 20, childOverrides: [String: Any] = [:], movement: Bool = false) throws -> ParticleSimulation {
        try json("child.json", ["material": "material.json", "maxcount": 100,
            "emitter": [["name": "boxrandom", "rate": 10, "instantaneous": 1, "distancemax": 0]],
            "initializer": [["name": "lifetimerandom", "min": 10, "max": 10]],
            "operator": movement ? [["name": "movement"]] : []])
        return ParticleSimulation(try description(["maxcount": 10,
            "emitter": [["name": "boxrandom", "rate": 0, "instantaneous": 2, "origin": "3 4 0", "distancemax": 0]],
            "initializer": [["name": "lifetimerandom", "min": 0.2, "max": 0.2],
                            ["name": "velocityrandom", "min": "10 0 0", "max": "10 0 0"]],
            "operator": [["name": "movement"]],
            "children": [["name": "child.json", "type": type, "maxcount": limit, "probability": probability,
                          "instanceoverride": childOverrides]]]))
    }

    func testParsingAndSpawnDeathPositions() throws {
        for type in ["eventspawn", "eventdeath", "eventfollow"] {
            let s = try system(type)
            XCTAssertEqual(s.description.children.first?.childType.rawValue, type)
            XCTAssertTrue(s.description.notes.isEmpty)
        }
        let spawn = try system("eventspawn")
        spawn.step(0.1)
        XCTAssertEqual(spawn.children[0].particles.count, 2)
        XCTAssertEqual(spawn.children[0].particles[0].position, [3, 4, 0])
        spawn.step(0.1)
        XCTAssertEqual(spawn.children[0].particles.count, 2)
        let death = try system("eventdeath")
        death.step(0.1)
        XCTAssertTrue(death.children[0].particles.isEmpty)
        death.step(0.1)
        XCTAssertEqual(death.children[0].particles.count, 2)
        XCTAssertEqual(death.children[0].particles[0].position, [5, 4, 0])
    }

    func testFollowTracksPositionVelocityAndStopsAtDeath() throws {
        let s = try system("eventfollow")
        s.step(0.1)
        let child = s.children[0]
        XCTAssertEqual(child.particles.count, 4) // two parents, each burst 1 + rate 10 * 0.1
        XCTAssertTrue(child.particles.allSatisfy { $0.position == SIMD3(4, 4, 0) && $0.velocity == SIMD3(10, 0, 0) })
        s.step(0.1)
        XCTAssertEqual(child.particles.count, 4)
        s.step(0.1)
        XCTAssertEqual(child.particles.count, 4)
    }

    func testProbabilityLimitDeterminismAndSeek() throws {
        let off = try system("eventspawn", probability: 0)
        off.advance(to: 1)
        XCTAssertTrue(off.children[0].particles.isEmpty)
        let limited = try system("eventspawn", limit: 1)
        limited.advance(to: 1)
        XCTAssertEqual(limited.children[0].particles.count, 1)
        let a = try system("eventfollow", probability: 0.7)
        let b = try system("eventfollow", probability: 0.7)
        a.advance(to: 0.1); b.advance(to: 0.1)
        let expected = a.children[0].particles
        XCTAssertEqual(expected, b.children[0].particles)
        a.advance(to: 2); a.advance(to: 0.1)
        XCTAssertEqual(expected, a.children[0].particles)
    }

    func testRuntimeRateCountAndVertexOverrides() throws {
        let s = try simulation(["maxcount": 100])
        s.advance(to: 1)
        XCTAssertEqual(s.particles.count, 10)
        XCTAssertTrue(s.setOverride("rate", [2]))
        XCTAssertEqual(s.overrideValue("rate"), [2])
        s.advance(to: 2)
        XCTAssertEqual(s.particles.count, 30)
        s.setOverride("count", [0.05]); s.setOverride("alpha", [0.25]); s.setOverride("colorn", [0.2, 0.3, 0.4])
        XCTAssertEqual(s.particles.count, 30) // pending until the next step
        s.step(0.1)
        XCTAssertEqual(s.particles.count, 5)
        var vertices: [Float] = []
        ParticleVertices.build(s.particles, sheet: nil, mode: "sequence", multiplier: 1, trail: false, into: &vertices)
        XCTAssertEqual(Array(vertices[7..<11]), [0.2, 0.3, 0.4, 0.25])
        s.setOverride("count", [2]); s.step(0.1)
        XCTAssertEqual(s.maxCount, 200); XCTAssertEqual(s.particles.count, 7)
        XCTAssertFalse(s.setOverride("rate", [.nan])); XCTAssertFalse(s.setOverride("colorn", [1]))
        XCTAssertFalse(s.setOverride("unknown", [1]))
    }

    func testOverrideInheritanceAndZeroCountRecovery() throws {
        let s = try system("eventspawn", childOverrides: ["alpha": 0.7])
        s.setOverride("alpha", [0.2]); s.setOverride("size", [2])
        XCTAssertEqual(s.children[0].overrideValue("alpha"), [0.7])
        XCTAssertEqual(s.children[0].overrideValue("size"), [2])
        let zero = try simulation(overrides: ["count": 0])
        zero.step(0.1); XCTAssertTrue(zero.particles.isEmpty)
        zero.setOverride("count", [1]); zero.step(0.1)
        XCTAssertEqual(zero.particles.count, 1)
    }
    func testSizeLifetimeSpeedAndColorChangesIncludingZero() throws {
        let s = try simulation(["emitter": [["name": "boxrandom", "instantaneous": 1, "rate": 0, "distancemax": 0]],
                               "initializer": [["name": "lifetimerandom", "min": 10, "max": 10],
                                               ["name": "velocityrandom", "min": "10 0 0", "max": "10 0 0"]],
                               "operator": [["name": "movement"]]])
        s.step(0.1)
        s.setOverride("size", [2]); s.setOverride("lifetime", [3]); s.setOverride("speed", [0])
        s.setOverride("color", [0.1, 0.2, 0.3]); s.step(0.1)
        XCTAssertEqual(s.particles[0].size, 40); XCTAssertEqual(s.particles[0].lifetime, 30)
        XCTAssertEqual(s.particles[0].position.x, 1, accuracy: 0.0001)
        XCTAssertEqual(s.particles[0].color, [0.1, 0.2, 0.3])
        s.setOverride("speed", [2]); s.step(0.1)
        XCTAssertEqual(s.particles[0].position.x, 3, accuracy: 0.0001)
        XCTAssertEqual(s.particles[0].velocity.x, 20)
    }

    func testEventCoordinatesIncludeChildTransform() throws {
        let d = try description(["emitter": [["name": "boxrandom", "rate": 0, "instantaneous": 1,
                                              "origin": "10 0 0", "distancemax": 0]],
            "children": [["type": "eventspawn", "origin": "4 0 0", "scale": "2 2 2",
                          "particle": ["material": "material.json", "emitter": [["name": "boxrandom", "rate": 0,
                                                                                  "instantaneous": 1, "distancemax": 0]]]]]])
        let s = ParticleSimulation(d); s.step(0.1)
        let child = s.children[0]
        let model = particleTransform(origin: child.description.origin, angles: .zero, scale: child.description.scale)
        XCTAssertEqual((model * SIMD4(child.particles[0].position, 1)).x, 14, accuracy: 0.0001)
    }

    func testScriptHostReadWriteAndFlattenedStateIdentity() throws {
        guard MTLCreateSystemDefaultDevice() != nil else { throw XCTSkip("Metal unavailable: reviewer checks SceneScript host and flattened render states") }
        try json("project.json", ["type": "scene", "file": "scene.json"])
        try json("scene.json", ["objects": [["id": 7, "particle": ["material": "material.json",
            "children": [["type": "eventfollow", "particle": ["material": "material.json"]]]]]]])
        let renderer = try SceneRenderer(project: folder, assets: nil)
        renderer.setValue(.number(3), object: 7, property: "instanceoverride.rate")
        guard case .number(let value) = renderer.value(object: 7, property: "instanceoverride.rate") else {
            return XCTFail("missing override readback")
        }
        XCTAssertEqual(value, 3)
        XCTAssertTrue(renderer.particleState(0).simulation.children[0] === renderer.particleState(1).simulation)
        XCTAssertEqual(renderer.particleState(1).simulation.overrideValue("rate"), [3])
    }

    func testFollowBirthDoesNotAdvancePastParent() throws {
        let s = try system("eventfollow", movement: true)
        s.step(0.1)
        XCTAssertTrue(s.children[0].particles.allSatisfy { $0.position == s.particles[0].position })
        XCTAssertTrue(s.children[0].particles.allSatisfy { $0.age == 0 })
        s.step(0.1)
        XCTAssertTrue(s.children[0].particles.allSatisfy { $0.position == SIMD3(5, 4, 0) })
    }

}
