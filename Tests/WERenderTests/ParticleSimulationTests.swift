import XCTest
import simd
@testable import WERender

final class ParticleSimulationTests: ParticleTestCase {
    func testEmissionCapacityExpiryAndZeroOverride() throws {
        let s = try simulation()
        s.advance(to: 1)
        XCTAssertEqual(s.particles.count, 10)
        let limited = try simulation(["maxcount": 5], overrides: ["count": 2, "rate": 10])
        limited.advance(to: 2)
        XCTAssertEqual(limited.particles.count, 10)
        let zero = try simulation(overrides: ["count": 0])
        zero.advance(to: 2); XCTAssertTrue(zero.particles.isEmpty)
        let burst = try simulation(["emitter": [["name": "boxrandom", "rate": 0, "instantaneous": 3]],
                                    "initializer": [["name": "lifetimerandom", "min": 0.5, "max": 0.5]]])
        burst.advance(to: 0.1); XCTAssertEqual(burst.particles.count, 3)
        burst.advance(to: 1); XCTAssertTrue(burst.particles.isEmpty)
    }

    func testDeterminismRewindCadenceAndPresimulation() throws {
        let definition: [String: Any] = ["emitter": [["name": "sphererandom", "rate": 25]],
            "initializer": [["name": "lifetimerandom", "min": 1, "max": 5], ["name": "velocityrandom"]],
            "operator": [["name": "movement", "gravity": "0 -10 0"], ["name": "turbulence"], ["name": "oscillatealpha"]]]
        let a = try simulation(definition), b = try simulation(definition)
        a.advance(to: 1)
        for t in [Float(0.17), 0.28, 0.51, 0.9, 1] { b.advance(to: t) }
        XCTAssertEqual(a.particles, b.particles)
        let snapshot = a.particles
        a.advance(to: 3); a.advance(to: 1)
        XCTAssertEqual(a.particles, snapshot)
        a.advance(to: 1); XCTAssertEqual(a.particles, snapshot)
        let pre = try simulation(definition.merging(["starttime": 1]) { _, b in b })
        pre.advance(to: 0)
        XCTAssertEqual(pre.particles, snapshot)
    }

    func testDelayDurationPeriodicAndOnePerStep() throws {
        for name in ["boxrandom", "sphererandom"] {
            let s = try simulation(["emitter": [["name": name, "rate": 30, "delay": 0.5, "duration": 0.5]]])
            s.advance(to: 0.5); XCTAssertTrue(s.particles.isEmpty)
            s.advance(to: 1); XCTAssertEqual(s.particles.count, 15)
            s.advance(to: 2); XCTAssertEqual(s.particles.count, 15)
            let periodic = try simulation(["emitter": [["name": name, "rate": 30, "flags": 4,
                "minperiodicduration": 0.1, "maxperiodicduration": 0.1, "minperiodicdelay": 0.1, "maxperiodicdelay": 0.1]]])
            periodic.advance(to: 1)
            XCTAssertGreaterThan(periodic.particles.count, 5); XCTAssertLessThan(periodic.particles.count, 25)
        }
        let s = try simulation(["emitter": [["name": "sphererandom", "rate": 3000, "flags": 2]]])
        s.advance(to: 1); XCTAssertEqual(s.particles.count, 30)
    }

    func testLiveCadencePauseAndRewind() throws {
        let live = try simulation(["operator": [["name": "movement"]]])
        live.advanceLive(to: 0)
        live.advanceLive(to: 0.05)
        XCTAssertEqual(live.time, 0.05, accuracy: 0.000001)
        live.advanceLive(to: 10)
        XCTAssertEqual(live.time, 0.15, accuracy: 0.000001)
        live.advanceLive(to: 1)
        let offline = try simulation(["operator": [["name": "movement"]]])
        offline.advance(to: 1)
        XCTAssertEqual(live.particles, offline.particles)
        live.advance(to: 2); offline.advance(to: 2)
        XCTAssertEqual(live.particles, offline.particles)
    }

    func testEmitterUsesLocalControlPoint() throws {
        let s = try simulation(["controlpoint": [["id": 0, "offset": "7 8 9"]]])
        s.advance(to: 0.1)
        XCTAssertEqual(s.particles[0].position, [7, 8, 9])
    }

    func testStepCap() throws {
        let s = try simulation()
        s.step(10)
        XCTAssertEqual(s.particles.count, 1)
        XCTAssertEqual(s.particles[0].age, 0.1)
    }

    func testBoxAndSphereDistributions() throws {
        for name in ["boxrandom", "sphererandom"] {
            let s = try simulation(["emitter": [["name": name, "instantaneous": 1000, "rate": 0,
                "distancemin": 2, "distancemax": 5, "directions": "1 1 0", "sign": [1, -1, 0], "speedmin": 3, "speedmax": 3]]])
            s.advance(to: 0.1)
            XCTAssertEqual(s.particles.count, 1000)
            var meanRadiusSquared: Float = 0
            for p in s.particles {
                XCTAssertGreaterThanOrEqual(p.position.x, 0); XCTAssertLessThanOrEqual(p.position.y, 0)
                XCTAssertEqual(p.position.z, 0)
                if name == "boxrandom" {
                    XCTAssertTrue((2...5).contains(p.position.x)); XCTAssertTrue((-5 ... -2).contains(p.position.y))
                    XCTAssertEqual(p.velocity, .zero)
                } else {
                    let squared = simd_length_squared(p.position)
                    XCTAssertTrue((3.999...25.001).contains(squared)); meanRadiusSquared += squared
                    XCTAssertEqual(simd_length(p.velocity), 3, accuracy: 0.0001)
                    XCTAssertGreaterThan(simd_dot(p.position, p.velocity), 0)
                }
            }
            if name == "sphererandom" { XCTAssertEqual(meanRadiusSquared / 1000, 14.5, accuracy: 0.6) }
        }
        let sphere = try simulation(["flags": 4, "emitter": [["name": "sphererandom", "instantaneous": 1000, "rate": 0,
            "distancemax": 5, "directions": "1 1 1"]]])
        sphere.advance(to: 0.1)
        var meanCube: Float = 0
        for p in sphere.particles {
            let radius = simd_length(p.position)
            XCTAssertLessThanOrEqual(radius, 5.001)
            meanCube += radius * radius * radius
        }
        XCTAssertEqual(meanCube / 1000, 62.5, accuracy: 3)
    }

    func testInitializersAndOverridesAppliedOnce() throws {
        let s = try simulation(["emitter": [["name": "sphererandom", "rate": 0, "instantaneous": 1,
            "distancemin": 1, "distancemax": 1, "directions": "1 0 0", "sign": [1, 0, 0], "speedmin": 2, "speedmax": 2]],
            "initializer": [["name": "sizerandom", "min": 8, "max": 8], ["name": "lifetimerandom", "min": 2, "max": 2],
                ["name": "alpharandom", "min": 0.5, "max": 0.5], ["name": "colorrandom", "min": "255 0 0", "max": "255 0 0"],
                ["name": "velocityrandom", "min": "1 2 3", "max": "1 2 3"],
                ["name": "rotationrandom", "min": "0 0 1", "max": "0 0 1"],
                ["name": "angularvelocityrandom", "min": "0 0 2", "max": "0 0 2"]]],
            overrides: ["size": 2, "lifetime": 3, "alpha": 0.5, "speed": 2, "colorn": "0.5 0.5 0.5"])
        s.advance(to: 1 / 30)
        let p = try XCTUnwrap(s.particles.first)
        XCTAssertEqual(p.size, 8); XCTAssertEqual(p.lifetime, 6); XCTAssertEqual(p.alpha, 0.25)
        XCTAssertEqual(p.color, [0.5, 0, 0]); XCTAssertEqual(p.velocity, [6, 4, 6])
        XCTAssertEqual(p.rotation, [0, 0, 1]); XCTAssertEqual(p.angularVelocity, [0, 0, 4])
        let replacement = try simulation(["initializer": [["name": "colorrandom", "min": "255 0 0", "max": "255 0 0"]]],
                                         overrides: ["color": "0.2 0.4 0.6", "colorn": "0.5 0.5 0.5"])
        replacement.advance(to: 0.1)
        XCTAssertEqual(replacement.particles[0].color, [0.1, 0.2, 0.3])
    }

    func testTurbulentVelocityBoundsAndDirection() throws {
        let s = try simulation(["emitter": [["name": "boxrandom", "instantaneous": 100, "rate": 0]],
            "initializer": [["name": "turbulentvelocityrandom", "speedmin": 5, "speedmax": 10, "scale": 0, "forward": "0 1 0"]]], overrides: ["speed": 2])
        s.advance(to: 1 / 30)
        for p in s.particles {
            XCTAssertTrue((9.999...20.001).contains(simd_length(p.velocity)))
            XCTAssertEqual(p.velocity.x, 0, accuracy: 0.0001); XCTAssertEqual(p.velocity.z, 0)
            XCTAssertGreaterThan(p.velocity.y, 0)
        }
    }

    func testMovementAngularMovementAndDrag() {
        var p = ParticleState(); p.velocity = [2, 4, 0]
        ParticleSimulation.apply(.movement(drag: 2, gravity: [0, -10, 0]), to: &p, dt: 0.1, time: 0.1)
        XCTAssertEqual(p.position, [0.2, 0.4, 0]); XCTAssertEqual(p.velocity.x, 1.6, accuracy: 0.00001)
        XCTAssertEqual(p.velocity.y, 2.4, accuracy: 0.00001)
        ParticleSimulation.apply(.movement(drag: 20, gravity: .zero), to: &p, dt: 0.1, time: 0.2)
        XCTAssertEqual(p.velocity, .zero)
        p.angularVelocity = [0, 0, 4]
        ParticleSimulation.apply(.angularMovement(drag: 2, force: [0, 0, 10]), to: &p, dt: 0.1, time: 0.1, speed: 2)
        XCTAssertEqual(p.rotation.z, 0.4, accuracy: 0.00001)
        XCTAssertEqual(p.angularVelocity.z, 4.8, accuracy: 0.00001)
    }

    func testFadeAndChangeWindows() {
        var p = ParticleState(); p.lifetime = 10; p.initialAlpha = 0.8; p.initialSize = 20
        let fade = ParticleOperator.alphaFade(fadeIn: 0.2, fadeOut: 0.8)
        for (age, expected): (Float, Float) in [(0, 0), (1, 0.4), (5, 0.8), (9, 0.4), (10, 0)] {
            p.age = age; ParticleSimulation.apply(fade, to: &p, dt: 0.1, time: age)
            XCTAssertEqual(p.alpha, expected, accuracy: 0.00001)
        }
        p.age = 5
        ParticleSimulation.apply(.sizeChange(start: 0.2, end: 0.8, from: 1, to: 3), to: &p, dt: 0.1, time: 5)
        XCTAssertEqual(p.size, 40, accuracy: 0.0001)
        ParticleSimulation.apply(.alphaChange(start: 0, end: 1, from: 1, to: 0), to: &p, dt: 0.1, time: 5)
        XCTAssertEqual(p.alpha, 0.4)
        p.initialColor = [0.5, 1, 0.2]
        ParticleSimulation.apply(.colorChange(start: 0, end: 1, from: [1, 0, 1], to: [0, 1, 1]), to: &p, dt: 0.1, time: 5)
        XCTAssertEqual(p.color, [0.25, 0.5, 0.2])
        XCTAssertEqual(particleFade(0.6, 0.5, 0.5, 1, 2), 2)
    }

    func testOscillatorsAndComposition() {
        var p = ParticleState(); p.age = .pi / 2; p.alpha = 0.4; p.size = 10
        let v = values(["frequencymin": 1, "frequencymax": 1, "scalemin": 0, "scalemax": 2, "phasemin": 0, "phasemax": 0])
        ParticleSimulation.apply(.oscillateAlpha(ParticleOscillator(v, kind: "oscillatealpha")), to: &p, dt: 0.1, time: 0)
        XCTAssertEqual(p.alpha, 0.4, accuracy: 0.00001)
        p.age = 0
        ParticleSimulation.apply(.oscillateSize(ParticleOscillator(v, kind: "oscillatesize")), to: &p, dt: 0.1, time: 0)
        XCTAssertEqual(p.size, 20)
        p.age = .pi / 2
        let pos = ParticleOscillator(values(["frequencymin": 1, "frequencymax": 1, "scalemin": 2, "scalemax": 2,
            "phasemin": 0, "phasemax": 0, "mask": "1 0 0"]), kind: "oscillateposition")
        ParticleSimulation.apply(.oscillatePosition(pos), to: &p, dt: 0.1, time: 0)
        XCTAssertEqual(p.position.x, -0.2, accuracy: 0.00001); XCTAssertEqual(p.position.y, 0)
    }

    func testAttractionRadiusAndTurbulenceBound() {
        let attraction = ParticleOperator.attract(controlPoint: 0, origin: .zero, scale: 20, radius: 5)
        var p = ParticleState(); p.position = [3, 0, 0]
        ParticleSimulation.apply(attraction, to: &p, dt: 0.1, time: 0, controlPoints: [.zero])
        XCTAssertEqual(p.velocity, [-2, 0, 0])
        p.position = [5, 0, 0]; p.velocity = .zero
        ParticleSimulation.apply(attraction, to: &p, dt: 0.1, time: 0, controlPoints: [.zero])
        XCTAssertEqual(p.velocity, .zero)
        let turbulence = ParticleOperator.turbulence(ParticleTurbulence(values(["mask": "1 1 0"])))
        ParticleSimulation.apply(turbulence, to: &p, dt: 0.1, time: 1, random: [0.5, 20])
        XCTAssertLessThanOrEqual(simd_length(p.velocity), 2.00001); XCTAssertEqual(p.velocity.z, 0)
        XCTAssertGreaterThan(simd_length(p.velocity), 0)
    }

    func testVortexModes() {
        var p = ParticleState(); p.position = [2, 0, 3]
        let v = ParticleVortex(values(["flags": 3, "distanceinner": 3, "speedinner": 10, "centerforce": 2]))
        ParticleSimulation.apply(.vortex(v), to: &p, dt: 0.1, time: 0, controlPoints: [.zero])
        XCTAssertEqual(p.velocity, [-0.2, 1, 0])
        p.position = [6, 0, 0]; p.velocity = .zero
        let ring = ParticleVortex(values(["flags": 4, "ringradius": 4, "ringwidth": 2, "ringpulldistance": 2,
            "ringpullforce": 4, "speedouter": 10]))
        ParticleSimulation.apply(.vortex(ring), to: &p, dt: 0.1, time: 0)
        XCTAssertEqual(p.velocity, [-0.2, 0.5, 0])
    }

    func testMouseAndWorldControlPointsUseInverseTransform() throws {
        let d = try description(["controlpoint": [["id": 0, "flags": 1, "offset": "2 0 0"],
            ["id": 1, "flags": 2, "offset": "20 30 0"], ["id": 2, "offset": "7 8 9"]]])
        let s = ParticleSimulation(d)
        let model = particleTransform(origin: [10, 20, 0], angles: .zero, scale: [2, 2, 2])
        s.updateControlPoints(model: model, pointer: [14, 24, 0])
        XCTAssertEqual(s.controlPoints[0], [3, 2, 0]); XCTAssertEqual(s.controlPoints[1], [5, 5, 0])
        XCTAssertEqual(s.controlPoints[2], [7, 8, 9])
    }

    func testCurlIsFiniteAndSpatiallyCoherent() {
        let a = ParticleNoise.curl([0.12, 0.34, 0.56])
        let b = ParticleNoise.curl([0.12001, 0.34001, 0.56001])
        XCTAssertTrue(a.x.isFinite && a.y.isFinite && a.z.isFinite)
        XCTAssertLessThan(simd_length(a - b), 0.01)
        XCTAssertEqual(a, ParticleNoise.curl([0.12, 0.34, 0.56]))
    }
}
