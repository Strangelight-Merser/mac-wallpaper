import Foundation

/// Valve KeyValues text, preserving nested objects and repeated keys.
public enum VDF {
    public indirect enum Value: Equatable, Sendable {
        case string(String)
        case object([Pair])

        public var string: String? { if case .string(let value) = self { return value }; return nil }
        public var pairs: [Pair] { if case .object(let pairs) = self { return pairs }; return [] }
        public subscript(_ key: String) -> Value? { pairs.first { $0.key == key }?.value }
    }

    public struct Pair: Equatable, Sendable {
        public let key: String
        public let value: Value
    }

    /// Parses quoted or bare tokens, braces, comments and escaped strings.
    public static func parse(_ text: String) throws -> Value {
        var parser = Parser(characters: Array(text))
        return .object(try parser.object(nested: false))
    }

    private struct Parser {
        let characters: [Character]
        var position = 0

        mutating func whitespace() {
            while position < characters.count {
                if characters[position].isWhitespace { position += 1 }
                else if characters[position] == "/", position + 1 < characters.count, characters[position + 1] == "/" {
                    while position < characters.count, characters[position] != "\n" { position += 1 }
                } else { break }
            }
        }

        mutating func token() throws -> String {
            whitespace()
            guard position < characters.count else { throw WEFormatError.corrupt("VDF: expected token") }
            var result = ""
            if characters[position] == "\"" {
                position += 1
                while position < characters.count {
                    let c = characters[position]; position += 1
                    if c == "\"" { return result }
                    if c == "\\" {
                        guard position < characters.count else { break }
                        let escaped = characters[position]; position += 1
                        switch escaped {
                        case "n": result.append("\n")
                        case "t": result.append("\t")
                        case "\\", "\"": result.append(escaped)
                        default: result.append("\\"); result.append(escaped)
                        }
                    } else { result.append(c) }
                }
                throw WEFormatError.corrupt("VDF: unterminated string")
            }
            while position < characters.count, !characters[position].isWhitespace,
                  !["{", "}", "\""].contains(characters[position]) {
                if characters[position] == "/", position + 1 < characters.count, characters[position + 1] == "/" { break }
                result.append(characters[position]); position += 1
            }
            guard !result.isEmpty else { throw WEFormatError.corrupt("VDF: expected token at \(position)") }
            return result
        }

        mutating func object(nested: Bool) throws -> [Pair] {
            var pairs: [Pair] = []
            while true {
                whitespace()
                guard position < characters.count else {
                    if nested { throw WEFormatError.corrupt("VDF: missing closing brace") }
                    return pairs
                }
                if characters[position] == "}" {
                    guard nested else { throw WEFormatError.corrupt("VDF: unexpected closing brace") }
                    position += 1
                    return pairs
                }
                let key = try token()
                whitespace()
                let value: Value
                if position < characters.count, characters[position] == "{" {
                    position += 1
                    value = .object(try object(nested: true))
                } else { value = .string(try token()) }
                pairs.append(Pair(key: key, value: value))
            }
        }
    }
}
