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
    var stoppedVelocity = SIMD3<Float>.zero, stoppedAngularVelocity = SIMD3<Float>.zero
    var eventSlot: Int = -1
    var baseSize: Float = 20, baseAlpha: Float = 1, baseLifetime: Float = 1
    var baseColor = SIMD3<Float>.one
    var life: Float { lifetime > 0 ? age / lifetime : 1 }
}

/// Contiguous CPU particle state, with fixed-step offline seeks and elapsed-time live updates.
final class ParticleSimulation {
    let description: ParticleSystemDescription
    private(set) var particles: [ParticleState] = []
    private(set) var time: Double = 0
    let children: [ParticleSimulation]
    private(set) var overrides: ParticleOverrides
    private(set) var maxCount: Int
    let histories: [ParticleHistory?]
    private var pendingOverrides: [String: [Float]] = [:]
    private var events: [EventSource]
    private var eventEmitters: [EmitterState]
    private var eventOrder: UInt64 = 0
    private struct EventSource {
        var occupied = false, emitting = false
        var parent: UInt64 = 0
        var randomState: UInt64 = 0
        var position = SIMD3<Float>.zero, velocity = SIMD3<Float>.zero
        var age: Float = 0
    }
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
        overrides = description.overrides
        maxCount = description.maxCount
        children = description.children.map(ParticleSimulation.init)
        histories = description.renderers.map { $0.rope ? ParticleHistory(style: $0) : nil }
        events = Array(repeating: EventSource(), count: description.childType == .static ? 0 : description.eventMaxCount)
        eventEmitters = Array(repeating: EmitterState(), count: events.count * description.emitters.count)
        random = ParticleRandom(state: description.seed)
        emitterStates = Array(repeating: EmitterState(), count: description.emitters.count)
        particles.reserveCapacity(description.maxCount * max(1, events.count))
        histories.forEach { $0?.reserveCapacity(description.maxCount * max(1, events.count)) }
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
        for i in events.indices { events[i] = EventSource() }
        for i in eventEmitters.indices { eventEmitters[i] = EmitterState() }
        eventOrder = 0
        histories.forEach { $0?.reset() }
        children.forEach { $0.reset() }
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
        applyOverrides()
        if description.childType == .static { emit(dt, slot: -1) }
        for i in particles.indices {
            particles[i].age += dt
            particles[i].initialAlpha = particles[i].baseAlpha * overrides.alpha
            particles[i].initialSize = particles[i].baseSize * overrides.size
            particles[i].initialColor = (overrides.color ?? particles[i].baseColor) * overrides.colorn
            particles[i].lifetime = particles[i].baseLifetime * overrides.lifetime
            particles[i].alpha = particles[i].initialAlpha
            particles[i].size = particles[i].initialSize
            particles[i].color = particles[i].initialColor
        }
        for (index, op) in description.operators.enumerated() {
            for i in particles.indices {
                Self.apply(op, to: &particles[i], dt: dt, time: Float(time) + dt, speed: overrides.speed,
                           controlPoints: controlPoints, random: turbulenceValues[index], operatorIndex: index)
            }
        }
        for history in histories { history?.record(particles, dt: dt) }
        // Parent events describe this step's endpoints. Integrate existing child particles first,
        // then emit there; otherwise an inherited velocity advances a fresh follow child twice.
        if description.childType != .static {
            for slot in events.indices where events[slot].occupied && events[slot].emitting {
                emit(dt, slot: slot)
                events[slot].age += dt
                if description.childType != .eventfollow {
                    events[slot].emitting = description.emitters.indices.contains {
                        !eventEmitters[slot * description.emitters.count + $0].burst
                    }
                }
            }
        }
        for child in children where child.description.childType != .static {
            for p in particles {
                if p.age >= p.lifetime { child.receive(p, type: .eventdeath) }
                child.follow(p, alive: p.age < p.lifetime)
            }
            child.step(dt)
            child.time += Double(dt)
        }
        var write = 0
        for read in particles.indices where particles[read].age < particles[read].lifetime {
            if write != read {
                particles[write] = particles[read]
                histories.forEach { $0?.move(from: read, to: write) }
            }
            write += 1
        }
        particles.removeLast(particles.count - write)
        for slot in events.indices where events[slot].occupied && !events[slot].emitting {
            if !particles.contains(where: { $0.eventSlot == slot }) { events[slot].occupied = false }
        }
    }

    /// Event pools are contiguous; one slot per active child instance, never a class per parent particle.
    private func receive(_ parent: ParticleState, type: ParticleSystemDescription.ChildType) {
        let kind = description.childType
        guard kind == type || (kind == .eventfollow && type == .eventspawn) else { return }
        eventOrder &+= 1
        var rng = ParticleRandom(state: description.seed &+ parent.seed &+ eventOrder)
        guard rng.unit() < description.probability,
              let slot = events.firstIndex(where: { !$0.occupied }) else { return }
        events[slot] = EventSource(occupied: true, emitting: true, parent: parent.seed, randomState: rng.state,
                                  position: parent.position, velocity: parent.velocity)
        for i in description.emitters.indices { eventEmitters[slot * description.emitters.count + i] = EmitterState() }
    }

    private func follow(_ parent: ParticleState, alive: Bool) {
        guard description.childType == .eventfollow else { return }
        for slot in events.indices where events[slot].occupied && events[slot].parent == parent.seed {
            events[slot].position = parent.position; events[slot].velocity = parent.velocity
            events[slot].emitting = alive
        }
    }

    private func emit(_ dt: Float, slot: Int) {
        let savedRandom = random
        if slot >= 0 { random.state = events[slot].randomState }
        defer {
            if slot >= 0 { events[slot].randomState = random.state; random = savedRandom }
        }
        for (i, emitter) in description.emitters.enumerated() {
            let age = (slot < 0 ? Float(time) : events[slot].age) - emitter.delay
            guard age + dt > 0, emitter.duration <= 0 || age < emitter.duration else { continue }
            let active = min(dt, age + dt, emitter.duration > 0 ? emitter.duration - max(0, age) : dt)
            let stateIndex = max(0, slot) * description.emitters.count + i
            var state = slot < 0 ? emitterStates[i] : eventEmitters[stateIndex]
            if emitter.flags & 4 != 0 {
                state.periodicRemaining -= active
                if state.periodicRemaining <= 0 {
                    state.emitting.toggle()
                    state.periodicRemaining = random.value(state.emitting ? emitter.periodicDuration : emitter.periodicDelay)
                }
                if !state.emitting {
                    if slot < 0 { emitterStates[i] = state } else { eventEmitters[stateIndex] = state }
                    continue
                }
            }
            state.fraction += Double(active) * Double(emitter.rate * overrides.rate)
            let whole = Int(floor(state.fraction + 0.000001))
            state.fraction = max(0, state.fraction - Double(whole))
            var count = emitter.flags & 2 != 0 ? min(1, whole) : whole
            if slot >= 0 && description.childType != .eventfollow {
                count = state.burst ? 0 : max(1, emitter.instantaneous)
            } else if !state.burst { count += emitter.instantaneous }
            state.burst = true
            if slot < 0 { emitterStates[i] = state } else { eventEmitters[stateIndex] = state }
            let live = slot < 0 ? particles.count : particles.reduce(0) { $0 + ($1.eventSlot == slot ? 1 : 0) }
            count = min(count, maxCount - live)
            for _ in 0..<max(0, count) {
                var p = spawn(emitter)
                p.eventSlot = slot
                if slot >= 0 {
                    let local = particleTransform(origin: description.origin, angles: description.angles, scale: description.scale).inverse
                    let position = local * SIMD4(events[slot].position, 0)
                    p.position += SIMD3(position.x, position.y, position.z)
                    if description.childType == .eventfollow {
                        let velocity = local * SIMD4(events[slot].velocity, 0)
                        p.velocity += SIMD3(velocity.x, velocity.y, velocity.z)
                    }
                }
                histories.forEach { $0?.insert(p, at: particles.count) }
                particles.append(p)
                for child in children { child.receive(p, type: .eventspawn) }
            }
        }
    }

    func overrideValue(_ name: String) -> [Float]? {
        if let value = pendingOverrides[name] { return value }
        switch name {
        case "count": return [overrides.count]
        case "rate": return [overrides.rate]
        case "size": return [overrides.size]
        case "lifetime": return [overrides.lifetime]
        case "speed": return [overrides.speed]
        case "alpha": return [overrides.alpha]
        case "colorn": return [overrides.colorn.x, overrides.colorn.y, overrides.colorn.z]
        case "color": let c = overrides.color ?? .one; return [c.x, c.y, c.z]
        default: return nil
        }
    }

    @discardableResult func setOverride(_ name: String, _ value: [Float]) -> Bool {
        guard overrideValue(name) != nil, !value.isEmpty, value.allSatisfy(\.isFinite),
              (name != "color" && name != "colorn") || value.count == 3 else { return false }
        pendingOverrides[name] = value
        for child in children where !child.description.ownOverrideNames.contains(name) {
            child.setOverride(name, value)
        }
        return true
    }

    private func applyOverrides() {
        guard !pendingOverrides.isEmpty else { return }
        let resize = pendingOverrides["count"] != nil
        for (name, value) in pendingOverrides {
            let f = value[0]
            switch name {
            case "count": overrides.count = max(0, f)
            case "rate": overrides.rate = max(0, f)
            case "size": overrides.size = f
            case "lifetime": overrides.lifetime = f
            case "speed":
                for i in particles.indices {
                    if overrides.speed != 0 {
                        particles[i].stoppedVelocity = particles[i].velocity / overrides.speed
                        particles[i].stoppedAngularVelocity = particles[i].angularVelocity / overrides.speed
                    }
                    particles[i].velocity = particles[i].stoppedVelocity * f
                    particles[i].angularVelocity = particles[i].stoppedAngularVelocity * f
                }
                overrides.speed = f
            case "alpha": overrides.alpha = f
            case "colorn": overrides.colorn = SIMD3(value[0], value[1], value[2])
            case "color": overrides.color = SIMD3(value[0], value[1], value[2])
            default: break
            }
        }
        pendingOverrides.removeAll(keepingCapacity: true)
        guard resize else { return }
        maxCount = max(0, Int(Float(description.baseMaxCount) * overrides.count))
        let capacity = maxCount * max(1, events.count)
        particles.reserveCapacity(capacity)
        histories.forEach { $0?.reserveCapacity(capacity) }
        var write = 0
        var counts = [Int](repeating: 0, count: max(1, events.count))
        for read in particles.indices {
            let slot = max(0, particles[read].eventSlot)
            if counts[slot] < maxCount {
                counts[slot] += 1
                if read != write {
                    particles[write] = particles[read]
                    histories.forEach { $0?.move(from: read, to: write) }
                }
                write += 1
            } else {
                for child in children { child.follow(particles[read], alive: false) }
            }
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
        p.baseSize = p.size; p.baseAlpha = p.alpha; p.baseLifetime = p.lifetime; p.baseColor = p.color
        let o = overrides
        p.size *= o.size; p.lifetime *= o.lifetime; p.alpha *= o.alpha
        p.stoppedVelocity = p.velocity; p.stoppedAngularVelocity = p.angularVelocity
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
