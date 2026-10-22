import Foundation

public enum WEFormatError: Error, CustomStringConvertible {
    case truncated(at: Int)
    case badMagic(String, expected: String)
    case unsupported(String)
    case corrupt(String)

    public var description: String {
        switch self {
        case .truncated(let at): return "unexpected end of data at offset \(at)"
        case .badMagic(let m, let e): return "bad magic '\(m)', expected \(e)"
        case .unsupported(let s): return "unsupported: \(s)"
        case .corrupt(let s): return "corrupt: \(s)"
        }
    }
}

/// Little-endian cursor over a byte buffer.
struct BinaryReader {
    let data: [UInt8]
    var offset: Int

    init(_ data: [UInt8], offset: Int = 0) {
        self.data = data
        self.offset = offset
    }

    var remaining: Int { data.count - offset }

    mutating func bytes(_ n: Int) throws -> ArraySlice<UInt8> {
        guard n >= 0, n <= remaining else { throw WEFormatError.truncated(at: offset) }
        defer { offset += n }
        return data[offset..<offset + n]
    }

    mutating func u32() throws -> UInt32 {
        let b = try bytes(4)
        let i = b.startIndex
        return UInt32(b[i]) | UInt32(b[i + 1]) << 8 | UInt32(b[i + 2]) << 16 | UInt32(b[i + 3]) << 24
    }

    mutating func i32() throws -> Int32 { Int32(bitPattern: try u32()) }
    mutating func int() throws -> Int { Int(try i32()) }
    mutating func f32() throws -> Float { Float(bitPattern: try u32()) }

    /// Null-terminated string (WE "NString"), optionally bounded.
    mutating func cString(maxLength: Int = .max) throws -> String {
        var out: [UInt8] = []
        while true {
            guard offset < data.count else { throw WEFormatError.truncated(at: offset) }
            let c = data[offset]
            offset += 1
            if c == 0 { break }
            out.append(c)
            if out.count > maxLength { throw WEFormatError.corrupt("string too long at \(offset)") }
        }
        return String(decoding: out, as: UTF8.self)
    }

    /// Int32 length-prefixed string (used by PKG).
    mutating func sizedString(maxLength: Int = 4096) throws -> String {
        let n = try int()
        guard n >= 0, n <= maxLength else { throw WEFormatError.corrupt("string length \(n)") }
        return String(decoding: try bytes(n), as: UTF8.self)
    }
}
