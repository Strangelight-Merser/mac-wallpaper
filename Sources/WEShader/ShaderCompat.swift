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
    /// Also repairs bool arithmetic, floating remainder, scalar mix endpoints and runtime constants.
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
            // E) arithmetic with a narrower constructor, `v_TexCoord - CAST2(u_offset)` with a vec3 v_TexCoord:
            //    HLSL truncates the wider operand.
            l = replace(#"(?<![.\w])(\w+)(\s*[-+*/]\s*)((?:CAST|vec)([234])\s*\()"#, in: l) { (m: [String]) in
                "\(truncate(m[1], to: Int(m[4])!))\(m[2])\(m[3])"
            }
            l = replace(#"((?:CAST|vec)([234])\s*\([^()]*\))(\s*[-+*/]\s*)(\w+)\b(?!\s*[.\[(])"#, in: l) { (m: [String]) in
                "\(m[1])\(m[3])\(truncate(m[4], to: Int(m[2])!))"
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
        return fixHLSLLeniency(lines.joined(separator: "\n"))
    }

    /// Share effective combo definitions on retry, then match varying widths. Pad narrow vertex
    /// outputs; project widened fragment inputs back to the components their expressions expect.
    public static func reconcileVaryings(vertex: String, fragment: String) -> (String, String) {
        let (vertex, fragment) = sharedRetryCombos(vertex: vertex, fragment: fragment)
        let declRe = #"\bvarying\s+(float|vec2|vec3|vec4)\s+(\w+)\s*;"#
        var fragTypes: [String: String] = [:]
        for m in allMatches(declRe, fragment) { fragTypes[m[2]] = m[1] }
        var v = vertex, f = fragment
        for m in allMatches(declRe, vertex) {
            guard let ft = fragTypes[m[2]], let vn = components(m[1]), let fn = components(ft), fn != vn else { continue }
            let name = m[2]
            if vn > fn {
                let code = CompatSource(f)
                var edits: [(Range<Int>, String)] = []
                for i in code.tokens.indices where code.tokens[i].text == name {
                    if i >= 2, code.tokens[i - 2].text == "varying" {
                        edits.append(((i - 1)..<i, m[1]))
                    } else if i + 1 < code.tokens.count, ![".", "["].contains(code.tokens[i + 1].text) {
                        edits.append((i..<(i + 1), name + swizzles[fn]))
                    }
                }
                f = code.replacing(edits)
                continue
            }
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
        return (v, f)
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

/// Token ranges keep compatibility edits out of comments and preprocessor directives.
private struct CompatSource {
    struct Token {
        let text: String
        let range: NSRange
    }

    let source: NSString
    let tokens: [Token]
    var pairs: [Int: Int] = [:]
    var types: [String: String] = [:]
    var functions: [String: String] = [:]

    init(_ text: String) {
        let source = text as NSString
        self.source = source
        let pattern = #"(?m)^[ \t]*#(?:[^\n\\]|\\[^\n]|\\\n)*|//[^\n]*|/\*[\s\S]*?\*/|\b[A-Za-z_]\w*|(?:\d+\.?\d*|\.\d+)(?:[eE][+-]?\d+)?[fFuU]?|==|!=|<=|>=|&&|\|\||\+\+|--|\+=|-=|\*=|/=|%=|[^\s]"#
        let re = try! NSRegularExpression(pattern: pattern)
        tokens = re.matches(in: text, range: NSRange(location: 0, length: source.length)).compactMap { m in
            let s = source.substring(with: m.range)
            let trimmed = s.trimmingCharacters(in: .whitespaces)
            guard !trimmed.hasPrefix("#"), !s.hasPrefix("//"), !s.hasPrefix("/*") else { return nil }
            return Token(text: s, range: m.range)
        }
        for m in ShaderPreprocessor.allMatches(#"(?m)^[ \t]*#define[ \t]+(\w+)[ \t]+([+-]?(?:\d+\.?\d*|\.\d+)(?:[eE][+-]?\d+)?[fFuU]?)[ \t]*$"#, text) {
            let value = m[2].lowercased()
            types[m[1]] = value.contains(".") || value.contains("e") || value.hasSuffix("f") ? "float" : value.hasSuffix("u") ? "uint" : "int"
        }
        var stack: [Int] = []
        for i in tokens.indices {
            let t = tokens[i].text
            if ["(", "[", "{"].contains(t) { stack.append(i) }
            if [")", "]", "}"].contains(t), let start = stack.popLast() {
                pairs[start] = i; pairs[i] = start
            }
            if Self.width(t) != nil, i + 2 < tokens.count {
                let name = tokens[i + 1].text
                if tokens[i + 2].text == "(" { functions[name] = t }
                else { types[name] = t }
            }
        }
    }

    static func width(_ type: String) -> Int? {
        if ["float", "int", "uint", "bool"].contains(type) { return 1 }
        if ["vec2", "vec3", "vec4", "ivec2", "ivec3", "ivec4", "uvec2", "uvec3", "uvec4", "bvec2", "bvec3", "bvec4"].contains(type) {
            return Int(type.suffix(1))
        }
        return nil
    }

    func text(_ range: Range<Int>) -> String {
        guard !range.isEmpty else { return "" }
        let start = tokens[range.lowerBound].range.location
        let end = NSMaxRange(tokens[range.upperBound - 1].range)
        return source.substring(with: NSRange(location: start, length: end - start))
    }

    func replacing(_ edits: [(Range<Int>, String)]) -> String {
        var out = source as String
        for (range, replacement) in edits.sorted(by: { $0.0.lowerBound > $1.0.lowerBound }) {
            let start = tokens[range.lowerBound].range.location
            let end = NSMaxRange(tokens[range.upperBound - 1].range)
            out = (out as NSString).replacingCharacters(in: NSRange(location: start, length: end - start), with: replacement)
        }
        return out
    }

    func arguments(_ open: Int) -> [Range<Int>] {
        guard let close = pairs[open] else { return [] }
        var result: [Range<Int>] = [], start = open + 1, i = start
        while i < close {
            if let end = pairs[i], end > i { i = end + 1; continue }
            if tokens[i].text == "," { result.append(start..<i); start = i + 1 }
            i += 1
        }
        result.append(start..<close)
        return result
    }

    func type(_ range: Range<Int>) -> String? {
        guard !range.isEmpty else { return nil }
        let lo = range.lowerBound, hi = range.upperBound
        if tokens[lo].text == "(", pairs[lo] == hi - 1 { return type((lo + 1)..<(hi - 1)) }
        if hi == lo + 1 {
            let t = tokens[lo].text
            if t == "true" || t == "false" { return "bool" }
            if let known = types[t] { return known }
            if t.first?.isNumber == true || t.first == "." {
                return t.contains(".") || t.lowercased().contains("e") || t.lowercased().hasSuffix("f") ? "float" : t.lowercased().hasSuffix("u") ? "uint" : "int"
            }
            return nil
        }
        var top: [Int] = [], i = lo
        while i < hi {
            if let end = pairs[i], end > i { i = end + 1; continue }
            top.append(i); i += 1
        }
        if top.contains(where: { ["==", "!=", "<", ">", "<=", ">=", "&&", "||"].contains(tokens[$0].text) }) { return "bool" }
        for ops in [["+", "-"], ["*", "/", "%"]] {
            if let op = top.last(where: { $0 > lo && ops.contains(tokens[$0].text) && !["+", "-", "*", "/", "%"].contains(tokens[$0 - 1].text) }) {
                let a = type(lo..<op), b = type((op + 1)..<hi)
                if let a, let b {
                    if a == "bool" { return b }; if b == "bool" { return a }
                    if (Self.width(a) ?? 0) > 1 { return a }
                    if (Self.width(b) ?? 0) > 1 { return b }
                    return a == "float" || b == "float" ? "float" : a
                }
                return nil
            }
        }
        if ["+", "-", "!"].contains(tokens[lo].text) { return tokens[lo].text == "!" ? "bool" : type((lo + 1)..<hi) }
        if hi >= lo + 3, tokens[hi - 2].text == ".", let base = type(lo..<(hi - 2)) {
            let swizzle = tokens[hi - 1].text
            if swizzle.allSatisfy({ "xyzwrgbastpq".contains($0) }), (1...4).contains(swizzle.count) {
                if base.hasPrefix("vec") || base == "float" { return swizzle.count == 1 ? "float" : "vec\(swizzle.count)" }
                if base.hasPrefix("bvec") { return swizzle.count == 1 ? "bool" : "bvec\(swizzle.count)" }
            }
        }
        if tokens[hi - 1].text == "]", let open = pairs[hi - 1], open > lo {
            return type(lo..<open)
        }
        if lo + 1 < hi, tokens[lo + 1].text == "(", pairs[lo + 1] == hi - 1 {
            let name = tokens[lo].text
            if Self.width(name) != nil { return name }
            if let t = functions[name] { return t }
            if ["CASTF", "dot", "length", "distance"].contains(name) { return "float" }
            if ["CAST2", "CAST3", "CAST4"].contains(name) { return "vec" + name.suffix(1) }
            if ["texture", "texSample2D", "texSample2DLod", "textureLod"].contains(name) { return "vec4" }
            if ["WE_compatRemainder", "abs", "floor", "ceil", "trunc", "fract", "frac", "sin", "cos", "sqrt", "pow", "min", "max", "clamp", "saturate", "mix", "lerp"].contains(name), let first = arguments(lo + 1).first {
                return type(first)
            }
        }
        return nil
    }

    func leftOperand(_ op: Int) -> Range<Int>? {
        guard op > 0 else { return nil }
        var start = op - 1
        if let open = pairs[start], open < start {
            start = open
            if start > 0, tokens[start - 1].text.first?.isLetter == true,
               !["return", "if", "while", "switch"].contains(tokens[start - 1].text) { start -= 1 }
        }
        while start >= 2 && tokens[start - 1].text == "." { start -= 2 }
        if start > 0, ["+", "-", "!"].contains(tokens[start - 1].text),
           start == 1 || ["(", "=", ",", "+", "-", "*", "/", "%"].contains(tokens[start - 2].text) { start -= 1 }
        return start..<op
    }

    func rightOperand(_ op: Int) -> Range<Int>? {
        let start = op + 1
        guard start < tokens.count else { return nil }
        var end = start
        while end < tokens.count && ["+", "-", "!"].contains(tokens[end].text) { end += 1 }
        guard end < tokens.count else { return nil }
        if let close = pairs[end], close > end { end = close + 1 }
        else { end += 1 }
        while end < tokens.count {
            if ["(", "["].contains(tokens[end].text), let close = pairs[end] { end = close + 1 }
            else if tokens[end].text == ".", end + 1 < tokens.count { end += 2 }
            else { break }
        }
        return start..<end
    }
}

extension ShaderPreprocessor {
    private static func fixHLSLLeniency(_ source: String) -> String {
        var result = fixRuntimeConstants(source)
        // Re-tokenize after each edit so nested calls and chained operators keep their precedence.
        var remainderTypes = Set<String>()
        while true {
            let code = CompatSource(result)
            var edit: (Range<Int>, String)?
            for i in code.tokens.indices {
                let op = code.tokens[i].text
                if ["mix", "lerp"].contains(op), i + 1 < code.tokens.count, code.tokens[i + 1].text == "(" {
                    let args = code.arguments(i + 1)
                    guard args.count == 3, let a = code.type(args[0]), let b = code.type(args[1]) else { continue }
                    if ["float", "int", "uint"].contains(a), b.hasPrefix("vec") { edit = (args[0], "\(b)(\(code.text(args[0])))") }
                    else if ["float", "int", "uint"].contains(b), a.hasPrefix("vec") { edit = (args[1], "\(a)(\(code.text(args[1])))") }
                } else if ["+", "-", "*", "/", "%"].contains(op),
                          var left = code.leftOperand(i), let right = code.rightOperand(i) {
                    if op == "%" {
                        while left.lowerBound > 0, ["*", "/", "%"].contains(code.tokens[left.lowerBound - 1].text),
                              let earlier = code.leftOperand(left.lowerBound - 1) { left = earlier.lowerBound..<i }
                    }
                    guard let a = code.type(left), let b = code.type(right) else { continue }
                    if a == "bool", b != "bool", op != "%" {
                        let cast = b == "int" || b == "uint" ? b : "float"
                        edit = (left, "\(cast)(\(code.text(left)))")
                    } else if b == "bool", a != "bool", op != "%" {
                        let cast = a == "int" || a == "uint" ? a : "float"
                        edit = (right, "\(cast)(\(code.text(right)))")
                    } else if a == "uint", b == "int" {
                        edit = (right, "uint(\(code.text(right)))")
                    } else if a == "int", b == "uint" {
                        edit = (left, "uint(\(code.text(left)))")
                    } else if op == "%", a == "float" || b == "float" || a.hasPrefix("vec") || b.hasPrefix("vec") {
                        let width = max(CompatSource.width(a) ?? 1, CompatSource.width(b) ?? 1)
                        let t = width == 1 ? "float" : "vec\(width)"
                        let call = "WE_compatRemainder(\(t)(\(code.text(left))), \(t)(\(code.text(right))))"
                        edit = (left.lowerBound..<right.upperBound, call)
                        remainderTypes.insert(t)
                    }
                }
                if edit != nil { break }
            }
            guard let edit else { break }
            result = code.replacing([edit])
        }
        if !remainderTypes.isEmpty {
            result = castRemainderAssignments(result)
            let functions = remainderTypes.sorted().map {
                "\($0) WE_compatRemainder(\($0) x, \($0) y) { return x - y * trunc(x / y); }\n"
            }.joined()
            if let end = result.firstIndex(of: "\n"), result.hasPrefix("#version") { result.insert(contentsOf: functions, at: result.index(after: end)) }
            else { result = functions + result }
        }
        return result
    }

    private static func castRemainderAssignments(_ source: String) -> String {
        let code = CompatSource(source)
        var edits: [(Range<Int>, String)] = []
        for i in code.tokens.indices where code.tokens[i].text == "=" && i > 0 {
            guard let t = code.types[code.tokens[i - 1].text], ["int", "uint"].contains(t) else { continue }
            var end = i + 1
            while end < code.tokens.count && code.tokens[end].text != ";" { end += 1 }
            let rhs = (i + 1)..<end
            guard rhs.contains(where: { code.tokens[$0].text == "WE_compatRemainder" }) else { continue }
            edits.append((rhs, "\(t)(\(code.text(rhs)))"))
        }
        return code.replacing(edits)
    }

    private static func fixRuntimeConstants(_ source: String) -> String {
        let code = CompatSource(source)
        var runtime = Set(code.functions.keys)
        var macros: [String: Set<String>] = [:]
        for m in allMatches(#"(?m)^[ \t]*#define[ \t]+(\w+)([^\n]*)"#, source) {
            macros[m[1], default: []].formUnion(allMatches(#"\b[A-Za-z_]\w*"#, m[2]).map { $0[0] })
        }
        var depth = 0, edits: [(Range<Int>, String)] = []
        for i in code.tokens.indices {
            let token = code.tokens[i].text
            if token == "{" { depth += 1 }; if token == "}" { depth -= 1 }
            guard depth == 0 else { continue }
            if CompatSource.width(token) != nil, i + 2 < code.tokens.count,
               ["=", ";", "["].contains(code.tokens[i + 2].text), i == 0 || code.tokens[i - 1].text != "const" {
                runtime.insert(code.tokens[i + 1].text)
            }
            guard token == "const", i + 4 < code.tokens.count, code.tokens[i + 3].text == "=" else { continue }
            var end = i + 4
            while end < code.tokens.count && code.tokens[end].text != ";" { end += 1 }
            var dependencies = Set(code.tokens[(i + 4)..<end].map(\.text))
            var pending = Array(dependencies)
            while let name = pending.popLast() {
                for dependency in macros[name] ?? [] where dependencies.insert(dependency).inserted { pending.append(dependency) }
            }
            if !dependencies.isDisjoint(with: runtime) {
                edits.append((i..<(i + 1), ""))
                runtime.insert(code.tokens[i + 2].text)
            }
        }
        return code.replacing(edits)
    }

    // process() discovers CRLF annotations after normalization; share those effective defines on retry.
    private static func sharedRetryCombos(vertex: String, fragment: String) -> (String, String) {
        let names = Set(scan(vertex).combos.keys).union(scan(fragment).combos.keys)
        func definitions(_ source: String) -> [String: String] {
            Dictionary(allMatches(#"(?m)^#define (\w+) (-?\d+)[ \t]*$"#, source).map { ($0[1], $0[2]) }, uniquingKeysWith: { a, _ in a })
        }
        let vd = definitions(vertex), fd = definitions(fragment)
        let shared = fd.merging(vd) { _, v in v }
        func sync(_ source: String, _ own: [String: String]) -> String {
            var result = source
            for name in names.sorted() {
                guard let value = shared[name], own[name] != value else { continue }
                if own[name] != nil {
                    result = replace("(?m)^#define " + name + #" -?\d+[ \t]*$"#, in: result, with: "#define \(name) \(value)")
                } else if let end = result.firstIndex(of: "\n") {
                    result.insert(contentsOf: "#define \(name) \(value)\n", at: result.index(after: end))
                }
            }
            return result
        }
        return (sync(vertex, vd), sync(fragment, fd))
    }
}
