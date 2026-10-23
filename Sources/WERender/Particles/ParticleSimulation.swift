// Emitters, initializers and operators ported from linux-wallpaperengine CParticle.cpp.
import Foundation
import simd

struct ParticleRandom {
    var state: UInt64
    mutating func unit() -> Float {
        state &+= 0x9E3779B97F4A7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
        z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
        return Float((z ^ (z >> 31)) >> 40) / 16_777_216
    }
    mutating func value(_ a: Float, _ b: Float, exponent: Float = 1) -> Float {
        min(a, b) + pow(unit(), exponent) * abs(b - a)
    }
    mutating func value(_ range: SIMD2<Float>) -> Float { value(range.x, range.y) }
    mutating func vector(_ a: SIMD3<Float>, _ b: SIMD3<Float>, exponent: Float = 1) -> SIMD3<Float> {
        SIMD3(value(a.x, b.x, exponent: exponent), value(a.y, b.y, exponent: exponent), value(a.z, b.z, exponent: exponent))
    }
}

struct ParticleState: Equatable {
    var position = SIMD3<Float>.zero
    var velocity = SIMD3<Float>.zero
    var rotation = SIMD3<Float>.zero
    var angularVelocity = SIMD3<Float>.zero
    var color = SIMD3<Float>.one
    var alpha: Float = 1
    var size: Float = 20
    var lifetime: Float = 1
    var age: Float = 0
    var initialColor = SIMD3<Float>.one
    var initialAlpha: Float = 1
    var initialSize: Float = 20
    var random: Float = 0
    var seed: UInt64 = 0
    var life: Float { lifetime > 0 ? age / lifetime : 1 }
}

/// Contiguous CPU particle state, with fixed-step offline seeks and elapsed-time live updates.
final class ParticleSimulation {
    let description: ParticleSystemDescription
    private(set) var particles: [ParticleState] = []
    private(set) var time: Double = 0
    private var tick = 0
    private var requestedTime: Float = -.infinity
    private var liveTime: Float?
    private var random: ParticleRandom
    private var emitterStates: [EmitterState]
    private var turbulenceValues: [SIMD2<Float>] = []
    var controlPoints = [SIMD3<Float>](repeating: .zero, count: 8)

    private struct EmitterState {
        var fraction: Double = 0
        var burst = false
        var periodicRemaining: Float = 0
        var emitting = false
    }

    init(_ description: ParticleSystemDescription) {
        self.description = description
        random = ParticleRandom(state: description.seed)
        emitterStates = Array(repeating: EmitterState(), count: description.emitters.count)
        particles.reserveCapacity(description.maxCount)
        reset()
        let model = description.parentTransform * particleTransform(origin: description.origin, angles: description.angles, scale: description.scale)
        updateControlPoints(model: model, pointer: .zero)
    }

    func reset() {
        particles.removeAll(keepingCapacity: true)
        random = ParticleRandom(state: description.seed)
        emitterStates = Array(repeating: EmitterState(), count: description.emitters.count)
        turbulenceValues = description.operators.map { op in
            if case .turbulence(let t) = op { return SIMD2(random.value(t.phase), random.value(t.speed)) }
            return .zero
        }
        tick = 0; time = 0; requestedTime = -.infinity; liveTime = nil
    }

    /// Seek from zero when time moves backwards; starttime uses the same fixed steps.
    func advance(to seconds: Float) {
        guard seconds.isFinite else { return }
        if liveTime != nil || seconds < requestedTime { reset() }
        requestedTime = seconds
        let target = max(0, Double(seconds)) + Double(description.startTime)
        let targetTick = Int(floor(target * 30 + 0.00001))
        while tick < targetTick {
            step(1 / 30)
            tick += 1
            time = Double(tick) / 30
        }
    }

    /// Live frames use their elapsed time, dropping pause gaps beyond 100 ms.
    func advanceLive(to seconds: Float) {
        guard seconds.isFinite else { return }
        if let previous = liveTime, seconds >= previous {
            let dt = min(0.1, seconds - previous)
            step(dt)
            time += Double(dt)
        } else {
            let target = liveTime == nil ? Float(0) : seconds
            advance(to: target)
        }
        liveTime = seconds
    }

    /// Resolve world and pointer control points into the complete object's local coordinate system.
    func updateControlPoints(model: simd_float4x4, pointer: SIMD3<Float>) {
        for cp in description.controlPoints where controlPoints.indices.contains(cp.id) {
            if cp.flags & 3 != 0 {
                let world = cp.offset + (cp.flags & 1 != 0 ? pointer : .zero)
                let local = model.inverse * SIMD4(world, 1)
                controlPoints[cp.id] = SIMD3(local.x, local.y, local.z)
            } else { controlPoints[cp.id] = cp.offset }
        }
    }

    func step(_ delta: Float) {
        let dt = max(0, min(0.1, delta))
        guard dt > 0 else { return }
        for (i, emitter) in description.emitters.enumerated() {
            let age = Float(time) - emitter.delay
            guard age + dt > 0, emitter.duration <= 0 || age < emitter.duration else { continue }
            let active = min(dt, age + dt, emitter.duration > 0 ? emitter.duration - max(0, age) : dt)
            var state = emitterStates[i]
            if emitter.flags & 4 != 0 {
                state.periodicRemaining -= active
                if state.periodicRemaining <= 0 {
                    state.emitting.toggle()
                    state.periodicRemaining = random.value(state.emitting ? emitter.periodicDuration : emitter.periodicDelay)
                }
                if !state.emitting { emitterStates[i] = state; continue }
            }
            state.fraction += Double(active) * Double(emitter.rate * description.overrides.rate)
            let whole = Int(floor(state.fraction + 0.000001))
            state.fraction = max(0, state.fraction - Double(whole))
            var count = emitter.flags & 2 != 0 ? min(1, whole) : whole
            if !state.burst { count += emitter.instantaneous; state.burst = true }
            emitterStates[i] = state
            count = min(count, description.maxCount - particles.count)
            for _ in 0..<max(0, count) { particles.append(spawn(emitter)) }
        }
        for i in particles.indices {
            particles[i].age += dt
            particles[i].alpha = particles[i].initialAlpha
            particles[i].size = particles[i].initialSize
            particles[i].color = particles[i].initialColor
        }
        for (index, op) in description.operators.enumerated() {
            for i in particles.indices {
                Self.apply(op, to: &particles[i], dt: dt, time: Float(time) + dt, speed: description.overrides.speed,
                           controlPoints: controlPoints, random: turbulenceValues[index], operatorIndex: index)
            }
        }
        var write = 0
        for read in particles.indices where particles[read].age < particles[read].lifetime {
            if write != read { particles[write] = particles[read] }
            write += 1
        }
        particles.removeLast(particles.count - write)
    }

    private func spawn(_ e: ParticleEmitter) -> ParticleState {
        var p = ParticleState()
        var offset = SIMD3<Float>.zero
        switch e.kind {
        case .boxrandom:
            for axis in 0..<3 {
                offset[axis] = random.value(e.distanceMin[axis], e.distanceMax[axis]) * (random.unit() < 0.5 ? -1 : 1)
            }
        case .sphererandom:
            let angle = random.value(0, 2 * .pi)
            let lo = e.distanceMin.x, hi = e.distanceMax.x
            if description.flags & 4 == 0 {
                let radius = sqrt(random.value(lo * lo, hi * hi))
                offset = [radius * cos(angle), radius * sin(angle), random.value(-hi, hi)]
            } else {
                let z = random.value(-1, 1), r = sqrt(max(0, 1 - z * z))
                offset = SIMD3(r * cos(angle), r * sin(angle), z) * cbrt(random.value(lo * lo * lo, hi * hi * hi))
            }
        }
        offset *= e.directions
        for axis in 0..<3 {
            if e.sign[axis] > 0 { offset[axis] = abs(offset[axis]) }
            if e.sign[axis] < 0 { offset[axis] = -abs(offset[axis]) }
        }
        p.position = e.origin + offset + (controlPoints[safe: e.controlPoint] ?? .zero)
        if e.kind == .sphererandom {
            p.velocity = particleNormalized(offset, fallback: [0, 1, 0]) * random.value(e.speedMin, e.speedMax)
        }
        for initializer in description.initializers {
            let lo = initializer.min, hi = initializer.max
            switch initializer.kind {
            case .lifetimerandom: p.lifetime = random.value(lo.x, hi.x)
            case .sizerandom: p.size = random.value(lo.x, hi.x, exponent: initializer.exponent) / 2
            case .colorrandom: p.color = random.vector(lo, hi)
            case .velocityrandom: p.velocity += random.vector(lo, hi)
            case .rotationrandom: p.rotation = random.vector(lo, hi)
            case .alpharandom: p.alpha = random.value(lo.x, hi.x)
            case .angularvelocityrandom: p.angularVelocity = random.vector(lo, hi, exponent: initializer.exponent)
            case .turbulentvelocityrandom:
                let t = initializer.turbulence!
                let phase = random.value(t.phase)
                let sample = p.position * 0.1 + SIMD3<Float>(repeating: Float(time) * t.timeScale) + SIMD3(phase, phase * 0.7, phase * 1.3)
                let forward = particleNormalized(t.forward, fallback: [0, 1, 0])
                var direction = particleNormalized(ParticleNoise.curl(sample), fallback: forward)
                let angle = acos(max(-1, min(1, simd_dot(direction, forward))))
                let limit = max(0, t.scale) * .pi / 2
                if angle > limit, t.scale < 2 {
                    let axis = particleNormalized(simd_cross(direction, forward), fallback: particleNormalized(simd_cross(direction, [1, 0, 0]), fallback: [0, 0, 1]))
                    direction = simd_quatf(angle: angle - limit, axis: axis).act(direction)
                }
                direction = simd_quatf(angle: -t.offset, axis: particleNormalized(t.right, fallback: [1, 0, 0])).act(direction)
                if description.flags & 4 == 0 { direction.z = 0; direction = particleNormalized(direction, fallback: [0, 1, 0]) }
                p.velocity += direction * random.value(t.speed)
            }
        }
        let o = description.overrides
        p.size *= o.size; p.lifetime *= o.lifetime; p.alpha *= o.alpha
        p.velocity *= o.speed; p.angularVelocity *= o.speed
        p.color = (o.color ?? p.color) * o.colorn
        p.initialSize = p.size; p.initialAlpha = p.alpha; p.initialColor = p.color
        p.random = random.unit(); p.seed = random.state
        return p
    }

    static func apply(_ op: ParticleOperator, to p: inout ParticleState, dt: Float, time: Float, speed: Float = 1,
                      controlPoints: [SIMD3<Float>] = [], random: SIMD2<Float> = .zero, operatorIndex: Int = 0) {
        switch op {
        case .movement(let drag, let gravity):
            p.position += p.velocity * dt
            p.velocity = (p.velocity + gravity * dt * speed) * max(0, 1 - drag * dt)
        case .angularMovement(let drag, let force):
            p.rotation += p.angularVelocity * dt
            p.angularVelocity = (p.angularVelocity + force * dt * speed) * max(0, 1 - drag * dt)
            for i in 0..<3 { p.rotation[i] = remainder(p.rotation[i], 2 * .pi) }
        case .alphaFade(let fadeIn, let fadeOut):
            let factor = p.life <= fadeIn ? particleFade(p.life, 0, fadeIn, 0, 1)
                : p.life > fadeOut ? particleFade(p.life, fadeOut, 1, 1, 0) : 1
            p.alpha = p.initialAlpha * factor
        case .sizeChange(let start, let end, let from, let to):
            p.size = p.initialSize * particleFade(p.life, start, end, from, to)
        case .alphaChange(let start, let end, let from, let to):
            p.alpha = p.initialAlpha * particleFade(p.life, start, end, from, to)
        case .colorChange(let start, let end, let from, let to):
            p.color = p.initialColor * (from + (to - from) * particleFade(p.life, start, end, 0, 1))
        case .attract(let cp, let origin, let scale, let radius):
            guard let point = controlPoints[safe: cp] else { return }
            let delta = point + origin - p.position, distance = simd_length(delta)
            if distance > 0.001, distance < radius { p.velocity += delta / distance * scale * dt * speed }
        case .oscillateAlpha(let o), .oscillateSize(let o):
            var rng = ParticleRandom(state: p.seed &+ UInt64(operatorIndex))
            let frequency = rng.value(o.frequency), phase = rng.value(o.phase)
            let factor = o.scale.x + (o.scale.y - o.scale.x) * (cos(frequency * p.age + phase) + 1) / 2
            if case .oscillateAlpha = op { p.alpha *= factor } else { p.size *= factor }
        case .oscillatePosition(let o):
            var rng = ParticleRandom(state: p.seed &+ UInt64(operatorIndex))
            for axis in 0..<3 {
                let frequency = rng.value(o.frequency), scale = rng.value(o.scale), phase = rng.value(o.phase)
                p.position[axis] -= scale * frequency * sin(frequency * p.age + phase) * dt * o.mask[axis] * speed
            }
        case .turbulence(let t):
            var sample = p.position
            sample.x += random.x + t.timeScale * time
            let direction = particleNormalized(ParticleNoise.curl(sample * t.scale * 2), fallback: .zero)
            p.velocity += direction * random.y * t.mask * dt * speed
        case .vortex(let v):
            let center = (controlPoints[safe: v.controlPoint] ?? .zero) + v.offset
            let axis = particleNormalized(v.axis, fallback: [0, 0, 1])
            var radial = p.position - center
            if v.flags & 1 != 0 { radial -= axis * simd_dot(radial, axis) }
            let distance = simd_length(radial)
            let tangent = particleNormalized(simd_cross(axis, radial), fallback: .zero)
            guard simd_length_squared(tangent) > 0 else { return }
            var spin: Float, force = SIMD3<Float>.zero
            if v.flags & 4 != 0 {
                let inner = v.ringRadius - v.ringWidth / 2, outer = v.ringRadius + v.ringWidth / 2
                if distance < inner { spin = 0 }
                else if distance <= outer { spin = particleFade(distance, inner, outer, v.speedInner, v.speedOuter) }
                else if distance <= outer + v.pullDistance, v.pullDistance > 0 {
                    let f = (distance - outer) / v.pullDistance
                    spin = v.speedOuter * (1 - f); force = -radial / distance * v.pullForce * f
                } else { spin = 0 }
            } else { spin = particleFade(distance, v.inner, v.outer + 0.1, v.speedInner, v.speedOuter) }
            if v.flags & 2 != 0, distance > 0.001 { force -= radial / distance * v.centerForce }
            p.velocity += (tangent * spin + force) * dt * speed
        }
    }
}

func particleFade(_ value: Float, _ start: Float, _ end: Float, _ from: Float, _ to: Float) -> Float {
    if value <= start { return from }
    if value >= end { return to }
    return from + (to - from) * (value - start) / (end - start)
}

func particleNormalized(_ v: SIMD3<Float>, fallback: SIMD3<Float>) -> SIMD3<Float> {
    let length = simd_length(v)
    return length > 0.0001 ? v / length : fallback
}
