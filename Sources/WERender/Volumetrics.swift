import Metal
import simd

extension SceneRenderer {
    func renderVolumetrics(projection: simd_float4x4) throws {
        let lights = frameLights.filter { $0.light.castVolumetrics && $0.light.intensity > 0 && $0.light.radius > 0 }
        guard !lights.isEmpty else { return }
        if volumetricPipeline == nil {
            let source = """
            #include <metal_stdlib>
            using namespace metal;
            struct Vertex { float4 position [[position]]; float2 clip; };
            struct Params { float4 originRadius, colorIntensity, directionKind, endAInner, endBOuter, densityExponent, bounds;
                            float4x4 inverseProjection, projection; };
            // A quad over the light's reach (bounds: scene-space min x, min y, max x, max y); directional lights
            // (bounds all zero) cover the screen.
            vertex Vertex volumeVertex(uint id [[vertex_id]], constant Params &p [[buffer(0)]]) {
                float2 corner = float2(id == 1 || id == 2 || id == 4, id == 2 || id == 4 || id == 5);
                if (all(p.bounds == 0)) { float2 c = corner * 2 - 1; return {float4(c, 0, 1), c}; }
                float4 clip = p.projection * float4(mix(p.bounds.xy, p.bounds.zw, corner), 0, 1);
                float2 c = clip.xy / clip.w;
                return {float4(c, 0, 1), c};
            }
            fragment float4 volumeFragment(Vertex in [[stage_in]], constant Params &p [[buffer(0)]]) {
                float4 world = p.inverseProjection * float4(in.clip, 0, 1);
                float2 xy = world.xy / world.w;
                float radius = p.originRadius.w;
                float3 origin = p.originRadius.xyz;
                float kind = p.directionKind.w;
                // Orthographic eye on +Z, opaque scene at Z=0. Tube bounds encompass both end caps.
                float lo = max(0.0f, origin.z - radius), hi = max(0.0f, origin.z + radius);
                if (kind == 2) { lo = max(0.0f, min(p.endAInner.z, p.endBOuter.z) - radius); hi = max(0.0f, max(p.endAInner.z, p.endBOuter.z) + radius); }
                if (hi <= lo) return float4(0);
                float sum = 0;
                constexpr int steps = 24;
                for (int i = 0; i < steps; ++i) {
                    float3 pos = float3(xy, mix(lo, hi, (float(i) + 1) / (steps + 1)));
                    float3 delta = pos - origin;
                    if (kind == 2) {
                        float3 segment = p.endBOuter.xyz - p.endAInner.xyz;
                        float t = saturate(dot(pos - p.endAInner.xyz, segment) / max(dot(segment, segment), 0.0001f));
                        delta = pos - (p.endAInner.xyz + segment * t);
                    }
                    float attenuation = pow(saturate(1 - length(delta) / radius), p.densityExponent.y);
                    if (kind == 1) attenuation *= smoothstep(p.endBOuter.w, p.endAInner.w, dot(normalize(delta), p.directionKind.xyz));
                    if (kind == 3) attenuation = 1;
                    sum += attenuation;
                }
                float pathScale = (hi - lo) / radius * (kind == 0 ? 0.5f : 1.0f);
                return float4(p.colorIntensity.rgb * p.colorIntensity.w * p.densityExponent.x * pathScale * (sum / steps) * 0.1f, 1);
            }
            """
            let library = try device.makeLibrary(source: source, options: nil)
            let descriptor = MTLRenderPipelineDescriptor()
            descriptor.vertexFunction = library.makeFunction(name: "volumeVertex")
            descriptor.fragmentFunction = library.makeFunction(name: "volumeFragment")
            descriptor.colorAttachments[0].pixelFormat = colorFormat
            let blend = descriptor.colorAttachments[0]!
            blend.isBlendingEnabled = true
            blend.sourceRGBBlendFactor = .one; blend.destinationRGBBlendFactor = .one
            blend.sourceAlphaBlendFactor = .zero; blend.destinationAlphaBlendFactor = .one
            volumetricPipeline = try device.makeRenderPipelineState(descriptor: descriptor)
        }
        // Resolution and depth reconstruction are not specified by the assets. Half resolution and a
        // Z=0 scene plane are the approximation guarded by enableApproximateVolumetrics.
        // The glow is soft and blurred anyway: quarter resolution is enough.
        let w = max(1, sceneTarget.width / 4), h = max(1, sceneTarget.height / 4)
        let a = wrap(pooledTarget("volumetrics.a", w, h)), b = wrap(pooledTarget("volumetrics.b", w, h))
        struct Parameters {
            var originRadius, colorIntensity, directionKind, endAInner, endBOuter, densityExponent, bounds: SIMD4<Float>
            var inverseProjection, projection: simd_float4x4
        }
        let parameters = lights.map { frame -> Parameters in
            let l = frame.light
            let kind: Float = l.kind == .point ? 0 : l.kind == .spot ? 1 : l.kind == .tube ? 2 : 3
            // Nothing contributes farther than the radius from the light (or from a tube's segment).
            let lo = simd_min(frame.endA, frame.endB), hi = simd_max(frame.endA, frame.endB)
            let reach = kind == 2 ? SIMD4(lo.x, lo.y, hi.x, hi.y) : SIMD4(frame.origin.x, frame.origin.y, frame.origin.x, frame.origin.y)
            let bounds = kind == 3 ? SIMD4<Float>(repeating: 0) : reach + SIMD4(-l.radius, -l.radius, l.radius, l.radius)
            // VAR_EXPONENT is assumed to be volumetricsexponent; exponent belongs to surface lighting.
            return Parameters(originRadius: SIMD4(frame.origin, l.radius), colorIntensity: SIMD4(l.color, l.intensity),
                              directionKind: SIMD4(frame.direction, kind), endAInner: SIMD4(frame.endA, cos(l.coneInner * .pi / 180)),
                              endBOuter: SIMD4(frame.endB, cos(l.coneOuter * .pi / 180)),
                              densityExponent: SIMD4(l.density, max(l.volumetricsExponent, 0), 0, 0), bounds: bounds,
                              inverseProjection: projection.inverse, projection: projection)
        }
        // Lights rarely move: reuse the blurred result until they (or the output size) change.
        let key = parameters.withUnsafeBytes { Array($0) } + withUnsafeBytes(of: (w, h)) { Array($0) }
        if key != volumetricKey {
            volumetricKey = key
            let enc = encoder(for: a.texture, clear: MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1))
            enc.setRenderPipelineState(volumetricPipeline!)
            for var p in parameters {
                enc.setVertexBytes(&p, length: MemoryLayout<Parameters>.stride, index: 0)
                enc.setFragmentBytes(&p, length: MemoryLayout<Parameters>.stride, index: 0)
                enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 6)
            }
            try blurVolumetrics(a, b)
        }
        let pass = SceneDescription.Pass(material: ["shader": "passthrough", "blending": "additive"], label: "volumetrics combine")
        let composite = try plan("volumetrics.combine", pass: pass, layer: nil, model: matrix_identity_float4x4, hasPrevious: true)
        try execute(composite, previous: a, target: sceneTarget, clear: false, mvp: matrix_identity_float4x4, half: [1, 1], first: false)
        fullFrameValid = false
    }

    private func blurVolumetrics(_ a: LoadedTexture, _ b: LoadedTexture) throws {
        for (i, vertical) in [0, 1].enumerated() {
            let pass = SceneDescription.Pass(material: ["shader": "blur_k3", "combos": ["VERTICAL": vertical]], label: "volumetrics blur")
            let plan = try plan("volumetrics.blur.\(i)", pass: pass, layer: nil, model: matrix_identity_float4x4, hasPrevious: true)
            try execute(plan, previous: i == 0 ? a : b, target: i == 0 ? b.texture : a.texture, clear: true,
                        mvp: matrix_identity_float4x4, half: [1, 1], first: false)
        }
    }
}
