import Foundation
import simd
import WEFormat
import WEScript

public struct SceneLight {
    public enum Kind: String, CaseIterable { case point = "lpoint", spot = "lspot", tube = "ltube", directional = "ldirectional" }
    public let id: Int
    public let kind: Kind
    public internal(set) var color: SIMD3<Float>
    public internal(set) var intensity: Float
    public internal(set) var radius: Float
    public internal(set) var exponent: Float
    public internal(set) var density: Float
    public internal(set) var volumetricsExponent: Float
    public internal(set) var castVolumetrics: Bool
    public internal(set) var coneInner: Float
    public internal(set) var coneOuter: Float
    public internal(set) var length: Float
    public let parallaxDepth: SIMD2<Float>

    init?(_ object: [String: Any], properties: UserProperties) {
        guard let kind = Kind(rawValue: properties.resolve(object["light"]) as? String ?? "") else { return nil }
        self.kind = kind
        id = (object["id"] as? NSNumber)?.intValue ?? -1
        func f(_ key: String, _ fallback: Float) -> Float { parseFloats(properties.resolve(object[key]))?.first ?? fallback }
        let c = parseFloats(properties.resolve(object["color"])) ?? [1, 1, 1]
        color = SIMD3(c[0], c[safe: 1] ?? c[0], c[safe: 2] ?? c[0])
        intensity = f("intensity", 1); radius = f("radius", 500); exponent = f("exponent", 2)
        density = f("density", 1); volumetricsExponent = f("volumetricsexponent", 1)
        castVolumetrics = properties.bool(object["castvolumetrics"], default: false)
        // No spot/tube scene is shipped with the fixtures. Cone fields are degrees; tube length is local X.
        coneInner = f("coneangle", 30); coneOuter = f("coneangleouter", 45); length = f("length", 100)
        let depth = parseFloats(properties.resolve(object["parallaxDepth"])) ?? [0, 0]
        parallaxDepth = SIMD2(depth[0], depth[safe: 1] ?? depth[0])
    }

    func transformed(_ matrix: simd_float4x4) -> FrameLight {
        func point(_ p: SIMD3<Float>) -> SIMD3<Float> { let v = matrix * SIMD4(p, 1); return SIMD3(v.x, v.y, v.z) }
        let origin = point(.zero)
        let forward = point([0, 0, -1]) - origin
        return FrameLight(light: self, origin: origin, direction: simd_length_squared(forward) > 0 ? simd_normalize(forward) : [0, 0, -1],
                          endA: point([-length / 2, 0, 0]), endB: point([length / 2, 0, 0]))
    }
}

struct FrameLight {
    var light: SceneLight
    var origin: SIMD3<Float>
    var direction: SIMD3<Float>
    var endA: SIMD3<Float>
    var endB: SIMD3<Float>
}

struct LightUniforms {
    let lights: [FrameLight]
    let ambient: SIMD3<Float>
    let skylight: SIMD3<Float>

    static func handles(_ name: String) -> Bool {
        name.hasPrefix("g_Lights") || name.hasPrefix("g_LPoint_") || name.hasPrefix("g_LSpot_")
            || name.hasPrefix("g_LTube_") || name.hasPrefix("g_LDirectional_")
            || name == "g_LightAmbientColor" || name == "g_LightSkylightColor"
    }

    func values(_ name: String, count: Int, reference: SIMD3<Float>, premultiplyTyped: Bool = false) -> [[Float]] {
        func xyz(_ v: SIMD3<Float>, _ w: Float? = nil) -> [Float] { [v.x, v.y, v.z] + (w.map { [$0] } ?? []) }
        if name == "g_LightAmbientColor" { return [xyz(ambient)] }
        if name == "g_LightSkylightColor" { return [xyz(skylight)] }
        if name.hasPrefix("g_Lights") {
            let ranked = lights.sorted {
                func score(_ l: FrameLight) -> Float {
                    let attenuation = max(0, 1 - simd_distance(l.origin, reference) / max(l.light.radius, 0.001))
                    return l.light.intensity * max(l.light.color.x, max(l.light.color.y, l.light.color.z)) * attenuation * attenuation
                }
                let a = score($0), b = score($1)
                return a == b ? (simd_distance_squared($0.origin, reference) == simd_distance_squared($1.origin, reference)
                    ? $0.light.id < $1.light.id : simd_distance_squared($0.origin, reference) < simd_distance_squared($1.origin, reference)) : a > b
            }
            let chosen = Array(ranked.prefix(4))
            let premultiplied = (0..<4).map { i -> SIMD3<Float> in
                guard i < chosen.count else { return .zero }
                let l = chosen[i].light
                return l.color * l.intensity * l.radius * l.radius
            }
            return (0..<count).map { i in
                if name == "g_LightsColorPremultiplied", i < 3 { return xyz(premultiplied[i], premultiplied[3][i]) }
                guard i < chosen.count else { return name == "g_LightsPosition" ? [0, 0, 1] : [0, 0, 0, 1] }
                let l = chosen[i]
                return name == "g_LightsPosition" ? xyz(l.origin) : xyz(l.light.color * l.light.intensity, max(l.light.radius, 0.001))
            }
        }
        let prefixes: [(SceneLight.Kind, String)] = [(.point, "g_LPoint_"), (.spot, "g_LSpot_"), (.tube, "g_LTube_"), (.directional, "g_LDirectional_")]
        guard let (kind, prefix) = prefixes.first(where: { name.hasPrefix($0.1) }) else { return [] }
        let selected = lights.filter { $0.light.kind == kind }
        return (0..<count).map { i in
            guard i < selected.count else { return name.hasSuffix("Origin") || name.hasSuffix("Direction") ? [0, 0, 1, 1] : name.hasSuffix("Params") ? [1, 1, 0, 0] : [0, 0, 0, 1] }
            let f = selected[i], l = f.light
            switch String(name.dropFirst(prefix.count)) {
            case "Color": return xyz(l.color * l.intensity * (premultiplyTyped && l.kind != .directional ? l.radius * l.radius : 1), l.kind == .directional ? 1 : max(l.radius, 0.001))
            case "Origin": return xyz(f.origin, cos(l.coneInner * .pi / 180))
            case "Direction": return xyz(l.kind == .directional ? -f.direction : f.direction, cos(l.coneOuter * .pi / 180))
            case "OriginA": return xyz(f.endA, 0)
            case "OriginB": return xyz(f.endB, 0)
            case "Params": return [max(l.radius, 0.001), max(l.exponent, 0), 0, 0]
            default: return [0, 0, 0, 0]
            }
        }
    }
}

extension SceneDescription {
    /// Only the kinds the scene has: scenes without lights compile exactly as before.
    var lightCombos: [String: Int] {
        Dictionary(uniqueKeysWithValues: SceneLight.Kind.allCases.compactMap { kind in
            let key = String(kind.rawValue.dropFirst())
            let count = max(lightConfig[key] ?? 0, lights.filter { $0.kind == kind }.count)
            return count > 0 ? ("LIGHTS_" + key.uppercased(), count) : nil
        })
    }
}

extension SceneRenderer {
    func updateLights() {
        frameLights = scene.lights.filter { isVisible($0.id) }.map { light in
            // Preserve the renderer's parent convention, adding pitch/yaw for the light's own orientation.
            let node = scene.nodes[light.id]
            let a = node?.angles ?? .zero
            let rotation = simd_float4x4(simd_quatf(angle: a.z, axis: [0, 0, 1]))
                * simd_float4x4(simd_quatf(angle: a.y, axis: [0, 1, 0]))
                * simd_float4x4(simd_quatf(angle: a.x, axis: [1, 0, 0]))
            var transform = parentTransform(light.id) * translation(node?.origin ?? .zero) * rotation * scaling(node?.scale ?? SIMD3(repeating: 1))
            if scene.parallax.enabled {
                let d = (light.parallaxDepth + scene.parallax.amount) * pointer.parallax * scene.canvas.x
                transform = translation([d.x, d.y, 0]) * transform
            }
            return light.transformed(transform)
        }
    }

    var lightUniforms: LightUniforms { LightUniforms(lights: frameLights, ambient: scene.ambientColor, skylight: scene.skylightColor) }

    // LightingV1 is normally injected by WE, not present in the shipped shader assets.
    // Use their radius/exponent BRDF, without shadow maps or cookies.
    static func prepareLightingShader(_ source: String) -> String {
        var expanded = source.replacingOccurrences(of: "#require LightingV1", with: lightingSource)
        // generic3's varying declaration uses #ifdef while its consumer uses #if.
        if expanded.contains("PerformLighting_Deprecated") {
            expanded = expanded.replacingOccurrences(of: "#ifdef NORMALMAP", with: "#if NORMALMAP")
        }
        return expanded.contains("CASTU(") ? "#define CASTU(x) uint(x)\n" + expanded : expanded
    }

    static var lightingSource: String {
        var declarations = "", body = "vec3 result = vec3(0.0);\n"
        for (kind, prefix) in [("POINT", "LPoint"), ("SPOT", "LSpot"), ("TUBE", "LTube"), ("DIRECTIONAL", "LDirectional")] {
            let fields = kind == "TUBE" ? ["OriginA", "OriginB"] : kind == "DIRECTIONAL" ? ["Direction"] : kind == "SPOT" ? ["Origin", "Direction"] : ["Origin"]
            declarations += "#if LIGHTS_\(kind)\n" + (["Color", "Params"] + fields).map { "uniform vec4 g_\(prefix)_\($0)[LIGHTS_\(kind)];\n" }.joined() + "#endif\n"
            let delta = kind == "TUBE" ? "PointSegmentDelta(worldPos, g_\(prefix)_OriginA[i].xyz, g_\(prefix)_OriginB[i].xyz)" : kind == "DIRECTIONAL" ? "g_\(prefix)_Direction[i].xyz" : "g_\(prefix)_Origin[i].xyz - worldPos"
            let cookie = kind == "SPOT" ? "smoothstep(g_LSpot_Direction[i].w, g_LSpot_Origin[i].w, -dot(normalize(delta), g_LSpot_Direction[i].xyz))" : "1.0"
            let params = kind == "DIRECTIONAL" ? "1.0e20, 0.0" : "g_\(prefix)_Params[i].x, g_\(prefix)_Params[i].y"
            body += "#if LIGHTS_\(kind)\nfor (int i = 0; i < LIGHTS_\(kind); ++i) { vec3 delta = \(delta); result += ComputePBRLightShadow(normal, delta, viewDir, albedo, g_\(prefix)_Color[i].rgb * \(cookie), \(params), specularTint, baseReflectance, roughness, metallic, 1.0); }\n#endif\n"
        }
        return declarations + "vec3 PerformLighting_V1(vec3 worldPos, vec3 albedo, vec3 normal, vec3 viewDir, vec3 specularTint, vec3 baseReflectance, float roughness, float metallic) {\n" + body + "return result;\n}\n"
    }
}

extension SceneLight {
    private static let scalarFields: [String: WritableKeyPath<SceneLight, Float>] = [
        "intensity": \.intensity, "radius": \.radius, "exponent": \.exponent, "density": \.density,
        "volumetricsexponent": \.volumetricsExponent, "coneangle": \.coneInner, "coneangleouter": \.coneOuter, "length": \.length
    ]

    func scriptValue(_ property: String) -> ScriptValue? {
        if let key = Self.scalarFields[property] { return .number(Double(self[keyPath: key])) }
        if property == "color" { return .vec3(SIMD3<Double>(color)) }
        if property == "castvolumetrics" { return .bool(castVolumetrics) }
        return nil
    }

    mutating func setScriptValue(_ value: ScriptValue, _ property: String) -> Bool {
        if let key = Self.scalarFields[property], let number = SceneRenderer.floats(value)?.first { self[keyPath: key] = number; return true }
        if property == "color", let color = SceneRenderer.vec3(value) { self.color = color; return true }
        if property == "castvolumetrics", let number = SceneRenderer.floats(value)?.first { castVolumetrics = number != 0; return true }
        return false
    }
}
