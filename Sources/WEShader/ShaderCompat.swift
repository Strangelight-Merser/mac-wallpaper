import Foundation

/// Source rewrites for HLSL-style leniency that WE's own compiler accepts but GLSL does not.
/// They are heuristics (regex + a flat symbol table), so callers apply them only after a normal
/// compile failed.
extension ShaderPreprocessor {
    static let swizzles = ["", ".x", ".xy", ".xyz"]

    static func components(_ type: String) -> Int? {
        switch type {
        case "float": return 1
        case "vec2": return 2
        case "vec3": return 3
        case "vec4": return 4
        default: return nil
        }
    }

    /// Implicit vector truncation, e.g. `vec2 uv = v_TexCoord;` with a `vec4 v_TexCoord`,
    /// `float m = texSample2D(...);` or passing a vec4 to a `vec2` parameter.
    public static func fixImplicitTruncation(_ src: String) -> String {
        // Flat symbol table: declared name → component count (globals, locals and parameters).
        var types: [String: Int] = [:]
        for m in allMatches(#"\b(float|vec2|vec3|vec4)\s+(\w+)\s*(?=[;=,)\[])"#, src) {
            if let n = components(m[1]) { types[m[2]] = n }
        }
        // User functions → parameter component counts.
        var functions: [String: [Int?]] = [:]
        for m in allMatches(#"(?m)^\s*(?:float|vec[234]|void|mat[34]|int)\s+(\w+)\s*\(([^)]*)\)\s*\{?\s*$"#, src) {
            functions[m[1]] = m[2].split(separator: ",").map { p in
                p.split(separator: " ").compactMap { components(String($0)) }.first
            }
        }

        func truncate(_ expr: String, to n: Int) -> String {
            guard let have = types[expr], have > n else { return expr }
            return expr + swizzles[n]
        }

        var lines = src.components(separatedBy: "\n")
        for (i, line) in lines.enumerated() {
            var l = line
            // A) `vecN x = ident;`
            if let m = firstMatch(#"^(\s*)(float|vec2|vec3)\s+(\w+)\s*=\s*(\w+)\s*;(.*)$"#, l), let n = components(m[2]) {
                l = "\(m[1])\(m[2]) \(m[3]) = \(truncate(m[4], to: n));\(m[5])"
            }
            // B) `x = ident;`, `x.rgb *= ident;`
            else if let m = firstMatch(#"^(\s*)(\w+)(\.[xyzwrgba]{1,4})?\s*(=|\+=|-=|\*=|/=)\s*(\w+)\s*;(.*)$"#, l),
                    let n = m[3].isEmpty ? types[m[2]] : m[3].count - 1, n < 4 {
                l = "\(m[1])\(m[2])\(m[3]) \(m[4]) \(truncate(m[5], to: n));\(m[6])"
            }
            // C) `float x = texSample2D(...);` (the whole right-hand side is one sample call)
            if let m = firstMatch(#"^(\s*)(float|vec2|vec3)\s+(\w+)\s*=\s*((?:texSample2D|texSample2DLod|texture)\s*\(.*\))\s*;(.*)$"#, l),
               let n = components(m[2]), balancedCall(m[4]) {
                l = "\(m[1])\(m[2]) \(m[3]) = \(m[4])\(swizzles[n]);\(m[5])"
            }
            // D) arguments to user functions
            for (name, params) in functions where l.contains(name + "(") {
                l = rewriteCalls(of: name, in: l) { args in
                    args.enumerated().map { j, a in
                        let t = a.trimmingCharacters(in: .whitespaces)
                        guard j < params.count, let n = params[j] else { return a }
                        return truncate(t, to: n)
                    }
                }
            }
            lines[i] = l
        }
        return lines.joined(separator: "\n")
    }

    /// Vertex/fragment declare the same varying with different widths (WE pads silently). Widen the
    /// vertex output and pad its assignments, as linux-wallpaperengine does for `vec2 → vec4`.
    public static func reconcileVaryings(vertex: String, fragment: String) -> (String, String) {
        let declRe = #"\bvarying\s+(float|vec2|vec3|vec4)\s+(\w+)\s*;"#
        var fragTypes: [String: String] = [:]
        for m in allMatches(declRe, fragment) { fragTypes[m[2]] = m[1] }
        var v = vertex
        for m in allMatches(declRe, vertex) {
            guard let ft = fragTypes[m[2]], let vn = components(m[1]), let fn = components(ft), fn > vn else { continue }
            let name = m[2]
            v = replace(#"\bvarying\s+"# + m[1] + #"\s+"# + name + #"\s*;"#, in: v, with: "varying \(ft) \(name);")
            let pad = Array(repeating: "0.0", count: fn - vn - 1) + ["1.0"]
            let re = try! NSRegularExpression(pattern: #"(?m)^(\s*)"# + name + #"\s*=\s*([^;]+);"#)
            let ns = v as NSString
            var out = v
            for match in re.matches(in: v, range: NSRange(location: 0, length: ns.length)).reversed() {
                let indent = ns.substring(with: match.range(at: 1)), expr = ns.substring(with: match.range(at: 2))
                let repl = "\(indent)\(name) = \(ft)(\(expr), \(pad.joined(separator: ", ")));"
                out = (out as NSString).replacingCharacters(in: match.range, with: repl)
            }
            v = out
        }
        return (v, fragment)
    }

    /// True when `call` is `name(...)` with the final `)` closing the first `(`.
    static func balancedCall(_ call: String) -> Bool {
        var depth = 0
        for (i, c) in call.enumerated() {
            if c == "(" { depth += 1 }
            if c == ")" {
                depth -= 1
                if depth == 0 { return i == call.count - 1 }
            }
        }
        return false
    }

    /// Rewrite the top-level argument lists of every `name(...)` call in `line`.
    static func rewriteCalls(of name: String, in line: String, _ transform: ([String]) -> [String]) -> String {
        var result = ""
        var rest = Substring(line)
        while let r = rest.range(of: name + "(") {
            // must be a whole identifier
            if r.lowerBound > rest.startIndex, let p = rest[rest.index(before: r.lowerBound)...].first,
               p.isLetter || p.isNumber || p == "_" {
                result += rest[..<r.upperBound]; rest = rest[r.upperBound...]; continue
            }
            result += rest[..<r.upperBound]
            var depth = 1, args: [String] = [], current = "", idx = r.upperBound
            while idx < rest.endIndex, depth > 0 {
                let c = rest[idx]
                if c == "(" { depth += 1 }
                if c == ")" { depth -= 1; if depth == 0 { break } }
                if c == ",", depth == 1 { args.append(current); current = "" } else { current.append(c) }
                idx = rest.index(after: idx)
            }
            guard idx < rest.endIndex else { result += rest[r.upperBound...]; return result }
            args.append(current)
            result += transform(args).joined(separator: ",")
            rest = rest[idx...]
        }
        return result + rest
    }
}
