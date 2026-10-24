import simd

extension PuppetModel {
    public func matrices(layers: [Layer], time: Double) -> [simd_float4x4] {
        var bind: [simd_float4x4] = []
        for bone in bones { bind.append((bone.parent.map { bind[$0] } ?? matrix_identity_float4x4) * bone.rest) }
        let active = layers.filter { $0.visible && $0.blend.isFinite && $0.rate.isFinite }
        let total = active.reduce(Float(0)) { $0 + $1.blend }
        var remaining: Float = 1
        var sampled: [(Layer, Float, Animation, Int, Int, Float)] = []
        for layer in active.reversed() {
            guard let animation = animations.first(where: { $0.id == layer.animation }) else { continue }
            let weight: Float
            if total > 1 { weight = layer.blend / total; remaining = 0 }
            else { weight = remaining * layer.blend; remaining = max(0, remaining * (1 - layer.blend)) }
            let n = animation.length
            let raw = (time.isFinite ? time : 0) * Double(layer.rate) * Double(animation.fps)
            let frame: Double
            if animation.mode == .single { frame = min(max(0, raw), Double(n - 1)) }
            else {
                let period = Double(animation.mode == .mirror ? n * 2 : n)
                frame = (raw.truncatingRemainder(dividingBy: period) + period).truncatingRemainder(dividingBy: period)
            }
            let a = Int(frame), t = Float(frame - Double(a))
            let b = animation.mode == .single ? min(a + 1, n - 1) : (a + 1) % (animation.mode == .mirror ? n * 2 : n)
            func reflected(_ i: Int) -> Int { i >= n ? 2 * n - 1 - i : i }
            sampled.append((layer, weight, animation, reflected(a), reflected(b), t))
        }
        if sampled.isEmpty { return bones.map { _ in matrix_identity_float4x4 } }
        var world: [simd_float4x4] = []
        let identity = simd_quatf(angle: 0, axis: [0, 0, 1])
        for (i, bone) in bones.enumerated() {
            var position = SIMD3(bone.rest.columns.3.x, bone.rest.columns.3.y, bone.rest.columns.3.z) * remaining
            var scale = SIMD3<Float>(repeating: remaining)
            var rotation = identity
            for (layer, weight, animation, a, b, t) in sampled.reversed() {
                let frames = animation.frames[i], base = frames[0], start = frames[a], end = frames[b]
                let positionDelta = simd_mix(start.position, end.position, SIMD3(repeating: t)) - base.position
                let scaleDelta = simd_mix(start.scale, end.scale, SIMD3(repeating: t)) - base.scale
                position += base.position * weight
                position += positionDelta * layer.blend
                scale += base.scale * weight
                scale += scaleDelta * layer.blend
                let delta = simd_slerp(start.rotation * base.rotation.inverse, end.rotation * base.rotation.inverse, t)
                rotation = rotation * simd_slerp(identity, delta, layer.blend) * simd_slerp(identity, base.rotation, weight)
            }
            var local = simd_float4x4(simd_slerp(rotation, identity, remaining))
            local.columns.0 *= scale.x; local.columns.1 *= scale.y; local.columns.2 *= scale.z
            local.columns.3 = SIMD4(position, 1)
            world.append((bone.parent.map { world[$0] } ?? matrix_identity_float4x4) * local)
        }
        return world.indices.map { world[$0] * bind[$0].inverse }
    }
}
