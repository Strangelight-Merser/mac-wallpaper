import Foundation

/// Errors contain protocol status and local diagnostics, never response bodies or credentials.
public enum SteamError: Error, Sendable, Equatable, CustomStringConvertible {
    case malformed(String), result(Int), http(Int), transport, disconnected, timeout
    case expired, invalidToken, keychain(Int32), tooLarge(Int64), unsupportedCompression(String)
    public var description: String {
        switch self {
        case .malformed(let s): return "Steam: \(s)"
        case .result(let n):
            // steam-user/enums/EResult.js.
            return [5, 15, 27].contains(n) ? "Steam EResult \(n): token invalid, log in again" : "Steam EResult \(n)"
        case .http(let n): return "Steam HTTP \(n)"
        case .transport: return "Steam network request failed"
        case .disconnected: return "Steam disconnected"
        case .timeout: return "Steam request timed out"
        case .expired: return "Steam login expired"
        case .invalidToken: return "Steam token invalid, log in again"
        case .keychain(let n): return "Steam Keychain status \(n)"
        case .tooLarge(let n): return "Download exceeds byte limit (\(n) bytes)"
        case .unsupportedCompression(let s): return "Unsupported Steam compression: \(s)"
        }
    }
}

/// Minimal protobuf writer for Steam's varint, fixed-width and length-delimited fields.
public struct ProtoWriter: Sendable {
    public private(set) var data = Data()
    public init() {}
    public mutating func varint(_ value: UInt64) {
        var v = value
        while v >= 128 { data.append(UInt8(v & 127) | 128); v >>= 7 }
        data.append(UInt8(v))
    }
    public mutating func uint(_ field: Int, _ value: UInt64) {
        varint(UInt64(field) << 3); varint(value)
    }
    public mutating func fixed64(_ field: Int, _ value: UInt64) {
        varint(UInt64(field) << 3 | 1); data.appendLE(value)
    }
    public mutating func fixed32(_ field: Int, _ value: UInt32) {
        varint(UInt64(field) << 3 | 5); data.appendLE(value)
    }
    public mutating func bytes(_ field: Int, _ value: Data) {
        varint(UInt64(field) << 3 | 2); varint(UInt64(value.count)); data.append(value)
    }
    public mutating func string(_ field: Int, _ value: String) { bytes(field, Data(value.utf8)) }
}

/// Parsed fields retain unknown values so callers can simply ignore them.
public struct ProtoReader: Sendable {
    public struct Field: Sendable {
        public let number: Int
        public let wire: UInt8
        public let value: UInt64
        public let data: Data
        public var string: String { String(decoding: data, as: UTF8.self) }
    }
    public let fields: [Field]
    public init(_ data: Data) throws {
        var cursor = ByteCursor(data)
        var fields: [Field] = []
        while cursor.remaining > 0 {
            let key = try cursor.varint(), wire = UInt8(key & 7), number = Int(key >> 3)
            guard number > 0, number <= 0x1fffffff else { throw SteamError.malformed("protobuf field") }
            var value: UInt64 = 0, bytes = Data()
            switch wire {
            case 0: value = try cursor.varint()
            case 1: value = try cursor.integer(UInt64.self)
            case 2:
                let length = try cursor.varint()
                guard length <= UInt64(cursor.remaining) else { throw SteamError.malformed("protobuf length") }
                bytes = try cursor.read(Int(length))
            case 5: value = UInt64(try cursor.integer(UInt32.self))
            default: throw SteamError.malformed("protobuf wire type")
            }
            fields.append(Field(number: number, wire: wire, value: value, data: bytes))
        }
        self.fields = fields
    }
    public func uint(_ field: Int, default fallback: UInt64 = 0) -> UInt64 {
        fields.last { $0.number == field }?.value ?? fallback
    }
    public func bytes(_ field: Int) -> Data { fields.last { $0.number == field }?.data ?? Data() }
    public func string(_ field: Int) -> String { fields.last { $0.number == field }?.string ?? "" }
    public func repeated(_ field: Int) -> [Data] { fields.filter { $0.number == field }.map(\.data) }
    public func contains(_ field: Int) -> Bool { fields.contains { $0.number == field } }
}

struct ByteCursor {
    let data: Data
    var offset = 0
    init(_ data: Data) { self.data = Data(data) }
    var remaining: Int { data.count - offset }
    mutating func read(_ count: Int) throws -> Data {
        guard count >= 0, count <= remaining else { throw SteamError.malformed("truncated data") }
        defer { offset += count }
        return data.subdata(in: offset..<offset + count)
    }
    mutating func integer<T: FixedWidthInteger>(_ type: T.Type) throws -> T {
        let bytes = try read(MemoryLayout<T>.size)
        return bytes.enumerated().reduce(T(0)) { $0 | T($1.element) << ($1.offset * 8) }
    }
    mutating func varint() throws -> UInt64 {
        var value: UInt64 = 0
        for i in 0..<10 {
            let byte = try integer(UInt8.self)
            guard i < 9 || byte <= 1 else { throw SteamError.malformed("varint overflow") }
            value |= UInt64(byte & 127) << (i * 7)
            if byte & 128 == 0 { return value }
        }
        throw SteamError.malformed("varint overflow")
    }
}

extension Data {
    mutating func appendLE<T: FixedWidthInteger>(_ value: T) {
        for i in 0..<MemoryLayout<T>.size { append(UInt8(truncatingIfNeeded: value >> (i * 8))) }
    }
    var hex: String { map { String(format: "%02x", $0) }.joined() }
    func uint32(at offset: Int) throws -> UInt32 {
        var cursor = ByteCursor(self); _ = try cursor.read(offset)
        return try cursor.integer(UInt32.self)
    }
}
