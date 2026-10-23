import Foundation

/// Lexical module lowering; never replaces words inside comments, literals or nested scopes.
/// Imports are restricted to the three built-in modules. Unsupported module forms fail at load.
enum ModuleTransform {
    struct Token { let text: String; let start: Int; let end: Int; let depth: Int }
    enum Failure: Error { case syntax(String) }

    static func wrap(_ source: String) throws -> String {
        let chars = Array(source)
        let tokens = lex(chars)
        var edits: [(Int, Int, String)] = []
        var exports: [String: String] = [:]
        var i = 0
        while i < tokens.count {
            let t = tokens[i]
            guard t.depth == 0, ["import", "export"].contains(t.text),
                  i == 0 || tokens[i - 1].text != "." else { i += 1; continue }
            if t.text == "import" {
                var end = i + 1
                while end < tokens.count && !tokens[end].text.hasPrefix("'") && !tokens[end].text.hasPrefix("\"") { end += 1 }
                guard end < tokens.count else { throw Failure.syntax("Missing import module") }
                let module = String(tokens[end].text.dropFirst().dropLast())
                guard ["WEMath", "WEColor", "WEVector"].contains(module) else {
                    throw Failure.syntax("Unsupported module: \(module)")
                }
                let clause = tokens[(i + 1)..<end].map(\.text)
                var binding: String
                if clause.isEmpty { binding = "" }
                else if clause.count == 4 && clause[0] == "*" && clause[1] == "as" && clause[3] == "from" {
                    binding = "const \(clause[2]) = __modules.\(module);"
                } else if clause.first == "{" && clause.suffix(2) == ["}", "from"] {
                    let list = clause.dropFirst().dropLast(2).joined(separator: " ").replacingOccurrences(of: " as ", with: ": ")
                    binding = "const { \(list) } = __modules.\(module);"
                } else { throw Failure.syntax("Unsupported import binding") }
                if end + 1 < tokens.count && tokens[end + 1].text == ";" { end += 1 }
                edits.append((t.start, tokens[end].end, binding)); i = end + 1
                continue
            }
            guard i + 1 < tokens.count else { throw Failure.syntax("Incomplete export") }
            let next = tokens[i + 1]
            if next.text == "{" {
                var j = i + 2
                while j < tokens.count && tokens[j].text != "}" {
                    let local = tokens[j].text
                    var name = local
                    j += 1
                    if j < tokens.count && tokens[j].text == "as" {
                        j += 1
                        guard j < tokens.count else { throw Failure.syntax("Incomplete export alias") }
                        name = tokens[j].text; j += 1
                    }
                    exports[name] = local
                    if j < tokens.count && tokens[j].text == "," { j += 1 }
                }
                guard j < tokens.count else { throw Failure.syntax("Unclosed export list") }
                if j + 1 < tokens.count && tokens[j + 1].text == "from" { throw Failure.syntax("Re-exports are unsupported") }
                edits.append((t.start, tokens[j].end, "")); i = j + 1; continue
            }
            if next.text == "default" {
                var declaration = i + 2
                if declaration < tokens.count && tokens[declaration].text == "async" { declaration += 1 }
                if declaration < tokens.count && ["function", "class"].contains(tokens[declaration].text) {
                    var name = declaration + 1
                    if name < tokens.count && tokens[name].text == "*" { name += 1 }
                    if name < tokens.count && !["(", "{", "extends"].contains(tokens[name].text) {
                        exports["default"] = tokens[name].text
                        edits.append((t.start, next.end, "")); i += 2; continue
                    }
                    if name < tokens.count {
                        exports["default"] = "__defaultExport"
                        edits.append((t.start, next.end, ""))
                        edits.append((tokens[name].start, tokens[name].start, " __defaultExport "))
                        i += 2; continue
                    }
                }
                exports["default"] = "__defaultExport"
                edits.append((t.start, next.end, "const __defaultExport =")); i += 2; continue
            }
            var j = i + 1
            if tokens[j].text == "async" { j += 1 }
            guard j + 1 < tokens.count else { throw Failure.syntax("Incomplete export declaration") }
            let kind = tokens[j].text
            guard ["function", "class", "let", "const", "var"].contains(kind) else { throw Failure.syntax("Unsupported export declaration") }
            j += 1
            if tokens[j].text == "*" { j += 1 }
            guard j < tokens.count, tokens[j].text != "{", tokens[j].text != "[" else {
                throw Failure.syntax("Export destructuring is unsupported; use an export list")
            }
            exports[tokens[j].text] = tokens[j].text
            if ["let", "const", "var"].contains(kind) {
                var k = j + 1
                while k < tokens.count && !(tokens[k].depth == 0 && [";", "export"].contains(tokens[k].text)) {
                    if tokens[k].depth == 0 && ["let", "const", "var", "function", "class"].contains(tokens[k].text),
                       chars[tokens[k - 1].end..<tokens[k].start].contains("\n") { break }
                    if tokens[k].depth == 0 && tokens[k].text == "," && k + 1 < tokens.count {
                        exports[tokens[k + 1].text] = tokens[k + 1].text
                    }
                    k += 1
                }
            }
            edits.append((t.start, t.end, "")); i += 1
        }
        var body = chars
        for edit in edits.reversed() { body.replaceSubrange(edit.0..<edit.1, with: Array(edit.2)) }
        let entries = exports.sorted { $0.key < $1.key }.map { "get \($0.key)(){return \($0.value)}" }.joined(separator: ",")
        return "(function(thisLayer,thisObject,createScriptProperties,__modules){'use strict';\n" + String(body) + "\n;return {\(entries)};\n})"
    }

    private static func lex(_ c: [Character]) -> [Token] {
        var out: [Token] = [], i = 0, depth = 0
        func at(_ n: Int) -> Character { n < c.count ? c[n] : "\0" }
        func word(_ ch: Character) -> Bool { ch.isLetter || ch.isNumber || ch == "_" || ch == "$" }
        func quoted(_ quote: Character) {
            i += 1
            while i < c.count {
                if c[i] == "\\" { i += 2; continue }
                if c[i] == quote { i += 1; break }
                // A complete template literal is opaque to the module scanner, including nested templates.
                if quote == "`" && c[i] == "$" && at(i + 1) == "{" {
                    i += 2
                    var nesting = 1
                    while i < c.count && nesting > 0 {
                        if ["'", "\"", "`"].contains(c[i]) { quoted(c[i]); continue }
                        if c[i] == "{" { nesting += 1 }
                        if c[i] == "}" { nesting -= 1 }
                        i += 1
                    }
                    continue
                }
                i += 1
            }
        }
        func startsRegex() -> Bool {
            guard let previous = out.last else { return true }
            if ["=", "(", ":", ",", "return", "throw", "[", "!", ";", "{", "else", "=>", "?", "&", "|"].contains(previous.text) { return true }
            if previous.text == ")" {
                var nesting = 0
                for j in out.indices.reversed() {
                    if out[j].text == ")" { nesting += 1 }
                    if out[j].text == "(" {
                        nesting -= 1
                        if nesting == 0 { return j > 0 && ["if", "while", "for", "with", "switch", "catch"].contains(out[j - 1].text) }
                    }
                }
            }
            return false
        }
        while i < c.count {
            if c[i].isWhitespace { i += 1; continue }
            if c[i] == "/" && at(i + 1) == "/" {
                while i < c.count && c[i] != "\n" { i += 1 }; continue
            }
            if c[i] == "/" && at(i + 1) == "*" {
                i += 2
                while i < c.count && !(c[i] == "*" && at(i + 1) == "/") { i += 1 }
                i = min(i + 2, c.count); continue
            }
            let start = i
            if ["'", "\"", "`"].contains(c[i]) { quoted(c[i]) }
            else if c[i] == "/" && startsRegex() {
                i += 1
                var inClass = false
                while i < c.count {
                    if c[i] == "\\" { i += 2; continue }
                    if c[i] == "[" { inClass = true }
                    if c[i] == "]" { inClass = false }
                    if c[i] == "/" && !inClass { i += 1; break }
                    i += 1
                }
                while i < c.count && c[i].isLetter { i += 1 }
            } else if c[i] == "=" && at(i + 1) == ">" { i += 2 }
            else if word(c[i]) { while i < c.count && word(c[i]) { i += 1 } }
            else { i += 1 }
            i = min(i, c.count)
            let text = String(c[start..<i])
            if ["}", ")", "]"].contains(text) { depth -= 1 }
            out.append(Token(text: text, start: start, end: i, depth: depth))
            if ["{", "(", "["].contains(text) { depth += 1 }
        }
        return out
    }
}
