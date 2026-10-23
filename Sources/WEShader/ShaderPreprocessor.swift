import Foundation
import WEFormat

/// Metadata from a `uniform T name; // {json}` annotation.
public struct UniformAnnotation {
    public let type: String
    public let name: String
    /// Material key used by `constantshadervalues` (e.g. "Bright").
    public let material: String?
    /// UI label (e.g. "ui_editor_properties_tint_high"); legacy scenes key constants by the old label.
    public let label: String?
    public let defaultValue: Any?
    public let combo: String?
}

/// Turns WE shader source into plain GLSL 330 that glslang accepts.
/// Ported from scripts/shader_batch.py (itself modelled on linux-wallpaperengine's ShaderUnit).
public enum ShaderPreprocessor {
    public enum Stage: String { case vertex = "vert", fragment = "frag" }

    static let header = """
    #version 330
    precision highp float;
    \(compatFunctions)
    #define mul(x, y) ((y) * (x))
    #define max(x, y) WE_max (y, x)
    #define lerp mix
    #define frac fract
    #define CAST2(x) (vec2(x))
    #define CAST3(x) (vec3(x))
    #define CAST4(x) (vec4(x))
    #define CAST3X3(x) (mat3(x))
    #define float2 vec2
    #define float3 vec3
    #define float4 vec4
    #define int2 ivec2
    #define int3 ivec3
    #define int4 ivec4
    #define saturate(x) (clamp(x, 0.0, 1.0))
    #define texSample2D texture
    #define texSample2DLod textureLod
    #define log10(x) (log2(x) * 0.301029995663981)
    #define atan2 atan
    #define fmod(x, y) ((x)-(y)*trunc((x)/(y)))
    #define ddx dFdx
    #define ddy(x) dFdy(-(x))
    #define GLSL 1
    #define CASTF(x) (float(x))
    #define sampler2DBackBuffer sampler2D
    #define texSample2DBackBuffer(t, uv, res) texture(t, uv)
    #define sampler2DComparison sampler2DShadow

    """

    /// WE accepts HLSL-style scalar broadcast (pow(vec3, float), max(float, vec2), ...). A user
    /// overload would hide the GLSL built-ins, so route through WE_* wrappers. Placed before the
    /// `max` swap macro, which would otherwise rewrite their signatures.
    static let compatFunctions: String = {
        var out: [String] = []
        let types = [("float", "float"), ("vec2", "float"), ("vec3", "float"), ("vec4", "float"),
                     ("int", "int"), ("ivec2", "int"), ("ivec3", "int"), ("ivec4", "int")]
        for (t, sc) in types {
            for fn in ["max", "min"] {
                out.append("\(t) WE_\(fn)(\(t) a, \(t) b) { return \(fn)(a, b); }")
                if t != sc {
                    out.append("\(t) WE_\(fn)(\(t) a, \(sc) b) { return \(fn)(a, \(t)(b)); }")
                    out.append("\(t) WE_\(fn)(\(sc) a, \(t) b) { return \(fn)(\(t)(a), b); }")
                }
            }
            if sc == "float" {
                out.append("\(t) WE_pow(\(t) a, \(t) b) { return pow(a, b); }")
                if t != sc { out.append("\(t) WE_pow(\(t) a, float b) { return pow(a, \(t)(b)); }") }
            }
        }
        return out.joined(separator: "\n") + "\n#define pow WE_pow\n#define min WE_min"
    }()

    static let stageDefines: [Stage: String] = [
        .fragment: "out vec4 out_FragColor;\n#define varying in\n",
        .vertex: "#define attribute in\n#define varying out\n",
    ]

    static let lightingV1 = """
    vec3 PerformLighting_V1(vec3 worldPos, vec3 albedo, vec3 normal, vec3 viewDir,
        vec3 specularTint, vec3 baseReflectance, float roughness, float metallic) { return vec3(0.0); }
    """

    /// Runtime-provided constants used when the shader doesn't define them.
    static let runtimeDefaults = ["INSTANCECOUNT": 1, "BLENDROWCOUNT": 1]

    public struct Result {
        public let source: String
        public let combos: [String: Int]
        public let uniforms: [UniformAnnotation]
    }

    /// Parse annotations and [COMBO] defaults without producing compilable output.
    public static func scan(_ src: String) -> (combos: [String: Int], uniforms: [UniformAnnotation]) {
        var combos: [String: Int] = [:]
        var uniforms: [UniformAnnotation] = []
        // Many WE shaders have CRLF line ends, and Swift treats "\r\n" as one Character, so splitting on "\n"
        // would see a single line: every annotation (e.g. the MASK combo a mask texture turns on) was lost.
        let src = src.replacingOccurrences(of: "\r\n", with: "\n")
        for line in src.split(separator: "\n", omittingEmptySubsequences: false) {
            let l = String(line)
            if let r = l.range(of: "[COMBO]"), let j = jsonObject(String(l[r.upperBound...])),
               let c = j["combo"] as? String {
                combos[c.uppercased()] = (j["default"] as? NSNumber)?.intValue ?? 0
                continue
            }
            if let m = firstMatch(#"^\s*uniform\s+(\w+)\s+(\w+)\s*(\[[^\]]*\])?\s*;\s*//\s*(\{.*\})\s*$"#, l),
               let j = jsonObject(m[4]) {
                uniforms.append(UniformAnnotation(type: m[1], name: m[2], material: j["material"] as? String,
                                                  label: j["label"] as? String, defaultValue: j["default"], combo: j["combo"] as? String))
                if m[1].hasPrefix("sampler2D"), (j["formatcombo"] as? Bool) == true,
                   m[2].hasPrefix("g_Texture"), let n = Int(m[2].dropFirst("g_Texture".count)) {
                    combos["TEX\(n)FORMAT"] = combos["TEX\(n)FORMAT"] ?? 0
                }
            }
        }
        return (combos, uniforms)
    }

    /// - Parameters:
    ///   - overrides: combos from the material pass (`"combos"`), uppercased.
    public static func process(_ raw: String, stage: Stage, fileDirectory: String,
                               locator: AssetLocator, overrides: [String: Int]) -> Result? {
        var src = raw.replacingOccurrences(of: "\r\n", with: "\n")
        var seen = Set<String>()
        var includes = ""
        for m in allMatches(#"(?m)^\s*#include\s+"([^"]+)""#, src) {
            includes += readInclude(m[1], fileDirectory: fileDirectory, locator: locator, seen: &seen) + "\n"
        }
        src = replace(#"(?m)^(\s*)#include"#, in: src, with: "$1// #include")
        src = replace(#"(?m)^\s*#require\s+LightingV1\s*$"#, in: src, with: lightingV1)
        if !includes.isEmpty {
            guard let hoisted = hoist(includes, into: src) else { return nil }
            src = hoisted
        }
        src = applyYFlips(src)
        src = src.replacingOccurrences(of: "gl_FragColor", with: "out_FragColor")
        src = replace(#"(?m)^\s*(in|out|varying)\s+uint\s+gl_(InstanceID|ViewportIndex)\s*;"#, in: src, with: "")

        includes = applyYFlips(includes)
        let scanned = scan(includes + src)
        var combos = scanned.combos
        for (k, v) in overrides { combos[k.uppercased()] = v }
        for (k, v) in runtimeDefaults where combos[k] == nil {
            if src.range(of: "\\b\(k)\\b", options: .regularExpression) != nil,
               (includes + src).range(of: "#define\\s+\(k)\\b", options: .regularExpression) == nil {
                combos[k] = v
            }
        }
        let defs = combos.sorted { $0.key < $1.key }.map { "#define \($0.key) \($0.value)\n" }.joined()
        return Result(source: header + stageDefines[stage]! + defs + src, combos: combos, uniforms: scanned.uniforms)
    }

    // MARK: - helpers

    /// Metal, like D3D, has its texture origin at the top-left, so WE's HLSL-only screen-space
    /// y flips (`#ifdef HLSL  v.y = -v.y;  #endif`) must apply. Other HLSL-gated code (polyfills)
    /// stays disabled.
    static func applyYFlips(_ s: String) -> String {
        // Blocks whose every statement is a y flip: `v.y = -v.y;` or `v.y = 1.0 - v.y;`.
        let flip = #"[ \t]*[\w.]+\.y\s*=\s*(?:-\s*[\w.]+\.y|1(?:\.0)?\s*-\s*[\w.]+\.y)\s*;[ \t]*\n"#
        return replace(#"(?m)^[ \t]*#ifdef HLSL[ \t]*\n((?:"# + flip + #")+)[ \t]*#endif"#, in: s, with: "$1")
    }

    static func readInclude(_ name: String, fileDirectory: String, locator: AssetLocator, seen: inout Set<String>) -> String {
        let candidates = [fileDirectory + "/" + name, "shaders/" + name]
        for c in candidates {
            guard locator.exists(c), let path = locator.resolvedPath(c) else { continue }
            if seen.contains(path) { return "" }
            seen.insert(path)
            guard let text = try? locator.string(c) else { continue }
            var out = text
            for m in allMatches(#"(?m)^\s*#include\s+"([^"]+)""#, text) {
                let nested = readInclude(m[1], fileDirectory: fileDirectory, locator: locator, seen: &seen)
                out = out.replacingOccurrences(of: m[0], with: "\n" + nested)
            }
            return out
        }
        return "// include \(name) not found\n"
    }

    /// Insert includes before the first top-level function definition, moved above any enclosing #if.
    static func hoist(_ includes: String, into src: String) -> String? {
        var lines = src.components(separatedBy: "\n")
        let funcDef = try! NSRegularExpression(pattern: #"^[A-Za-z_]\w*(\s+[A-Za-z_]\w*)+\s*\([^;]*$"#)
        guard let fn = lines.firstIndex(where: { l in
            let t = l.trimmingCharacters(in: .whitespaces)
            return funcDef.firstMatch(in: l, range: NSRange(l.startIndex..., in: l)) != nil
                && !t.hasPrefix("uniform") && !t.hasPrefix("return") && !t.hasPrefix("else")
        }) else { return nil }
        var stack: [Int] = []
        for i in 0..<fn {
            let t = lines[i].trimmingCharacters(in: .whitespaces)
            if t.hasPrefix("#if") { stack.append(i) } else if t.hasPrefix("#endif"), !stack.isEmpty { stack.removeLast() }
        }
        lines.insert(includes, at: stack.first ?? fn)
        return lines.joined(separator: "\n")
    }

    static func jsonObject(_ s: String) -> [String: Any]? {
        guard let start = s.firstIndex(of: "{"), let end = s.lastIndex(of: "}") else { return nil }
        return (try? JSONSerialization.jsonObject(with: Data(s[start...end].utf8))) as? [String: Any]
    }

    static func allMatches(_ pattern: String, _ s: String) -> [[String]] {
        let re = try! NSRegularExpression(pattern: pattern)
        return re.matches(in: s, range: NSRange(s.startIndex..., in: s)).map { m in
            (0..<m.numberOfRanges).map { i in Range(m.range(at: i), in: s).map { String(s[$0]) } ?? "" }
        }
    }

    static func firstMatch(_ pattern: String, _ s: String) -> [String]? { allMatches(pattern, s).first }

    static func replace(_ pattern: String, in s: String, with template: String) -> String {
        let re = try! NSRegularExpression(pattern: pattern)
        return re.stringByReplacingMatches(in: s, range: NSRange(s.startIndex..., in: s),
                                           withTemplate: NSRegularExpression.escapedTemplate(for: template)
                                               .replacingOccurrences(of: "\\$1", with: "$1"))
    }
}
