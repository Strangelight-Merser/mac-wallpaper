import Foundation
import CoreFoundation

public struct WallpaperProperty: Sendable, Equatable, Identifiable {
    public struct Option: Sendable, Equatable {
        public let label: String
        public let value: String
    }
    public enum Kind: Sendable, Equatable {
        case bool
        case slider(min: Double, max: Double, step: Double?, precision: Int?, fraction: Bool)
        case color, combo(options: [Option]), textInput, label, group, file, directory, unknown(String)
    }
    public let id: String
    public let kind: Kind
    public let label: String
    public let order: Int
    public let defaultValue: String?
    public let condition: String?
}

public enum WallpaperProperties {
    static func string(_ value: Any?) -> String? {
        guard let value, !(value is NSNull) else { return nil }
        if let n = value as? NSNumber {
            return CFGetTypeID(n) == CFBooleanGetTypeID() ? (n.boolValue ? "true" : "false") : n.stringValue
        }
        return value as? String
    }
    public static func parse(project: [String: Any]) -> [WallpaperProperty] {
        let entries = (project["general"] as? [String: Any])?["properties"] as? [String: Any] ?? [:]
        var indices: [String: Int] = [:]
        return entries.compactMap { key, raw -> WallpaperProperty? in
            guard let p = raw as? [String: Any] else { return nil }
            let type = p["type"] as? String ?? ""
            func number(_ key: String) -> Double? { string(p[key]).flatMap(Double.init) }
            let kind: WallpaperProperty.Kind
            switch type.lowercased() {
            case "bool": kind = .bool
            case "slider": kind = .slider(min: number("min") ?? 0, max: number("max") ?? 1,
                                          step: number("step"), precision: number("precision").map(Int.init),
                                          fraction: string(p["fraction"]) == "true" || string(p["fraction"]) == "1")
            case "color": kind = .color
            case "combo": kind = .combo(options: (p["options"] as? [[String: Any]] ?? []).compactMap {
                guard let value = string($0["value"]) else { return nil }
                return .init(label: $0["label"] as? String ?? value, value: value)
            })
            case "textinput": kind = .textInput
            case "text": kind = .label
            case "group": kind = .group
            case "file": kind = .file
            case "directory": kind = .directory
            default: kind = .unknown(type)
            }
            var value = string(p["value"])
            if kind == .bool, let v = value { value = (v == "true" || (Double(v) ?? 0) != 0) ? "true" : "false" }
            if case .slider = kind, let v = value, let n = Double(v) { value = NSNumber(value: n).stringValue }
            if kind == .label || kind == .group { value = nil }
            indices[key] = number("index").map(Int.init) ?? 0
            return WallpaperProperty(id: key, kind: kind, label: p["text"] as? String ?? key,
                                     order: number("order").map(Int.init) ?? 0, defaultValue: value,
                                     condition: p["condition"] as? String)
        }.sorted { ($0.order, indices[$0.id] ?? 0, $0.id) < ($1.order, indices[$1.id] ?? 0, $1.id) }
    }
    public static func isVisible(_ property: WallpaperProperty, values: [String: String]) -> Bool {
        guard let source = property.condition, !source.isEmpty else { return true }
        var parser = PropertyCondition(source, values: values)
        return (try? parser.evaluate()) ?? true
    }
}

private struct PropertyCondition {
    enum Failure: Error { case invalid }
    enum Token: Equatable { case value(String), quoted(String), reference(String), op(String) }
    let source: String
    let values: [String: String]
    var tokens: [Token] = []
    var position = 0
    init(_ source: String, values: [String: String]) { self.source = source; self.values = values }
    mutating func evaluate() throws -> Bool {
        let chars = Array(source)
        var i = 0
        while i < chars.count {
            let c = chars[i]
            if c.isWhitespace { i += 1; continue }
            if c == "\"" || c == "'" {
                let quote = c
                i += 1
                var s = ""
                while i < chars.count && chars[i] != quote {
                    if chars[i] == "\\" { i += 1; guard i < chars.count else { throw Failure.invalid } }
                    s.append(chars[i]); i += 1
                }
                guard i < chars.count else { throw Failure.invalid }
                i += 1; tokens.append(.quoted(s)); continue
            }
            if "=!<>&|()".contains(c) {
                var op = String(c); i += 1
                if i < chars.count, ["==", "!=", "<=", ">=", "&&", "||"].contains(op + String(chars[i])) {
                    op.append(chars[i]); i += 1
                }
                tokens.append(.op(op)); continue
            }
            let start = i
            while i < chars.count && !chars[i].isWhitespace && !"=!<>&|()\"'".contains(chars[i]) { i += 1 }
            let word = String(chars[start..<i])
            if word.hasSuffix(".value") { tokens.append(.reference(String(word.dropLast(6)))) }
            else if Double(word) != nil || word == "true" || word == "false" { tokens.append(.value(word)) }
            else { throw Failure.invalid }
        }
        let result = try expression(0)
        guard position == tokens.count else { throw Failure.invalid }
        return truth(result)
    }
    struct Value {
        let text: String
        var quoted = false
        var number: Double? { Double(text) ?? (text == "true" ? 1 : text == "false" ? 0 : nil) }
    }
    func truth(_ v: Value) -> Bool {
        v.quoted ? !v.text.isEmpty : v.text != "false" && !v.text.isEmpty && Double(v.text) != 0
    }
    mutating func expression(_ minimum: Int) throws -> Value {
        var lhs = try atom()
        let ranks = ["||": 1, "&&": 2, "==": 3, "!=": 3, "<": 4, "<=": 4, ">": 4, ">=": 4]
        while position < tokens.count, case .op(let op) = tokens[position], let rank = ranks[op], rank >= minimum {
            position += 1
            let rhs = try expression(rank + 1)
            let result: Bool
            let a = lhs.number, b = rhs.number
            let numeric = !(lhs.quoted && rhs.quoted) && a != nil && b != nil
            let equal = numeric ? a == b : lhs.text == rhs.text
            switch op {
            case "||": result = truth(lhs) || truth(rhs)
            case "&&": result = truth(lhs) && truth(rhs)
            case "==": result = equal
            case "!=": result = !equal
            case "<": result = numeric ? a! < b! : lhs.text < rhs.text
            case "<=": result = numeric ? a! <= b! : lhs.text <= rhs.text
            case ">": result = numeric ? a! > b! : lhs.text > rhs.text
            default: result = numeric ? a! >= b! : lhs.text >= rhs.text
            }
            lhs = Value(text: String(result))
        }
        return lhs
    }
    mutating func atom() throws -> Value {
        guard position < tokens.count else { throw Failure.invalid }
        let token = tokens[position]; position += 1
        switch token {
        case .value(let v): return Value(text: v)
        case .quoted(let v): return Value(text: v, quoted: true)
        case .reference(let name): guard let v = values[name] else { throw Failure.invalid }; return Value(text: v)
        case .op("!"): return Value(text: String(!truth(try atom())))
        case .op("("):
            let v = try expression(0)
            guard position < tokens.count, tokens[position] == .op(")") else { throw Failure.invalid }
            position += 1; return v
        default: throw Failure.invalid
        }
    }
}
