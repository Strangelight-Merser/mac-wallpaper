import XCTest
import simd
import WEFormat
@testable import WERender

final class ParticleDescriptionTests: ParticleTestCase {
    func testPathInlineAndDefaults() throws {
        let inline = try description()
        try json("particle.json", ["material": "material.json"])
        let path = try description(object: ["particle": "particle.json"])
        XCTAssertEqual(path.maxCount, inline.maxCount)
        XCTAssertEqual(path.maxCount, 100)
        XCTAssertEqual(path.startTime, 0)
        XCTAssertEqual(path.scale, .one)
        XCTAssertEqual(path.origin, .zero)
        XCTAssertEqual(path.animationMode, "sequence")
        XCTAssertEqual(path.sequenceMultiplier, 1)
        XCTAssertEqual(path.renderers.count, 1)
        XCTAssertFalse(path.renderers[0].trail)
        XCTAssertTrue(path.notes.isEmpty)
    }

    func testPropertyBindingsAndOverrides() throws {
        let props = UserProperties(project: ["general": ["properties": ["position": ["value": "3 4 5"], "alpha": ["value": 0.25]]]])
        let p = try ParticleSystemDescription(object: ["particle": ["maxcount": 80], "origin": ["user": "position"],
            "scale": [2, 3, 4], "angles": "0 0 1", "visible": false,
            "instanceoverride": ["count": 0.5, "rate": 2, "size": 3, "alpha": ["user": "alpha"],
                                  "colorn": "0.5 0.6 0.7", "color": "0.1 0.2 0.3", "lifetime": 4, "speed": 5]], locator: locator, properties: props)
        XCTAssertEqual(p.origin, [3, 4, 5]); XCTAssertEqual(p.scale, [2, 3, 4]); XCTAssertFalse(p.visible)
        XCTAssertEqual(p.maxCount, 40); XCTAssertEqual(p.overrides.rate, 2); XCTAssertEqual(p.overrides.size, 3)
        XCTAssertEqual(p.overrides.alpha, 0.25); XCTAssertEqual(p.overrides.lifetime, 4); XCTAssertEqual(p.overrides.speed, 5)
        XCTAssertEqual(p.overrides.colorn, [0.5, 0.6, 0.7]); XCTAssertEqual(p.overrides.color, [0.1, 0.2, 0.3])
        let disabled = try description(object: ["instanceoverride": ["enabled": false, "count": 0, "rate": 0, "controlpoint1": "9 9 9"]])
        XCTAssertEqual(disabled.maxCount, 100); XCTAssertEqual(disabled.overrides.rate, 1); XCTAssertTrue(disabled.controlPoints.isEmpty)
        XCTAssertEqual(try description(object: ["instanceoverride": ["count": 0]]).maxCount, 0)
    }

    func testControlPointsAndStaticChildren() throws {
        let d = try description(["controlpoint": [["id": 1, "offset": [1, 2, 3], "flags": 1], ["id": 2, "offset": "4 5 6", "flags": 2]],
            "children": [["name": "child", "particle": ["material": "material.json"], "origin": "3 0 0", "controlpointstartindex": 1],
                         ["name": "event", "type": "death", "particle": "not-read.json"]]],
            object: ["origin": "10 20 0", "scale": "2 2 2", "instanceoverride": ["controlpoint1": "7 8 9"]])
        XCTAssertEqual(d.controlPoints[0].offset, [7, 8, 9]); XCTAssertEqual(d.controlPoints[0].flags, 1)
        XCTAssertEqual(d.children.count, 1); XCTAssertNotEqual(d.seed, d.children[0].seed)
        let child = d.children[0]
        let model = child.parentTransform * particleTransform(origin: child.origin, angles: child.angles, scale: child.scale)
        XCTAssertEqual(model.columns.3, [16, 20, 0, 1])
        XCTAssertEqual(child.controlPoints.first(where: { $0.id == 0 })?.flags, 1)
        XCTAssertTrue(d.notes.contains("test: particle event child death not supported"))
    }

    func testUnknownElementsAndRopeSupport() throws {
        let d = try description(["emitter": [["name": "unknownE"]], "initializer": [["name": "unknownI"]],
            "operator": [["name": "unknownO"]], "renderer": [["name": "ropetrail"], ["name": "unknownR"]]])
        XCTAssertTrue(d.emitters.isEmpty); XCTAssertTrue(d.initializers.isEmpty); XCTAssertTrue(d.operators.isEmpty)
        XCTAssertTrue(d.canRender)
        for name in ["unknownE", "unknownI", "unknownO", "unknownR"] {
            XCTAssertTrue(d.notes.contains(where: { $0.contains(name) && $0.hasSuffix("not supported") }))
        }
    }

    func testInitializerDefaultsAndByteColors() throws {
        let d = try description(["initializer": [["name": "sizerandom"], ["name": "velocityrandom"],
            ["name": "rotationrandom"], ["name": "angularvelocityrandom"], ["name": "alpharandom"],
            ["name": "colorrandom", "min": "255 128 0", "max": "1.0 0.5 0.0"]]])
        XCTAssertEqual(d.initializers[0].max, SIMD3(repeating: 20)); XCTAssertEqual(d.initializers[0].exponent, 1)
        XCTAssertEqual(d.initializers[1].min, SIMD3(repeating: -32))
        XCTAssertEqual(d.initializers[2].max.z, 2 * .pi)
        XCTAssertEqual(d.initializers[3].min.z, -5); XCTAssertEqual(d.initializers[4].min.x, 0.05)
        XCTAssertEqual(d.initializers[5].min, [1, Float(128) / 255, 0]); XCTAssertEqual(d.initializers[5].max, [1, 0.5, 0])
    }

    func testSceneOrderAndImageDependencies() throws {
        try json("project.json", ["type": "scene", "file": "scene.json"])
        try json("image.json", ["material": "image-material.json", "width": 10, "height": 20])
        try json("image-material.json", ["passes": [["shader": "genericimage", "blending": "translucent"]]])
        try json("scene.json", ["objects": [
            ["id": 1, "image": "image.json", "dependencies": [3]],
            ["id": 2, "particle": ["material": "material.json", "children": [["particle": ["material": "material.json"]]]]],
            ["id": 3, "image": "image.json", "visible": false]]])
        let scene = try SceneDescription(project: folder, locator: locator)
        XCTAssertEqual(scene.drawOrder, [.image(0), .particle(0), .particle(1), .image(1)])
        XCTAssertEqual(scene.orderedObjects(), [.image(1), .image(0), .particle(0), .particle(1)])
        XCTAssertEqual(scene.layers.count, 2); XCTAssertFalse(scene.layers[1].visible)
        XCTAssertEqual(scene.layers[0].size, [10, 20]); XCTAssertEqual(scene.layers[0].passes[0].blending, "translucent")
        XCTAssertTrue(scene.notes.isEmpty)
    }

    func testCyclesAreReported() throws {
        try json("cycle.json", ["children": [["particle": "cycle.json"]]])
        XCTAssertThrowsError(try description(object: ["particle": "cycle.json"]))
    }
}
