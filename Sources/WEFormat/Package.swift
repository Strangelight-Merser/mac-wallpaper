import Foundation

/// Wallpaper Engine `scene.pkg` archive (PKGV00xx). Layout ported from RePKG (MIT).
public struct PKG {
    public struct Entry {
        public let path: String
        public let offset: Int
        public let length: Int
    }

    public let magic: String
    public let entries: [Entry]
    private let data: Data
    private let dataStart: Int
    private let byPath: [String: Entry]
    private let foldedPaths: [String: Entry]

    /// Maps the archive without loading its payload into a byte array.
    public init(url: URL) throws {
        try self.init(data: Data(contentsOf: url, options: .alwaysMapped))
    }

    public init(bytes: [UInt8]) throws { try self.init(data: Data(bytes)) }

    private init(data: Data) throws {
        var offset = 0
        func integer() throws -> Int {
            guard data.count - offset >= 4 else { throw WEFormatError.truncated(at: offset) }
            defer { offset += 4 }
            return Int(Int32(bitPattern: (0..<4).reduce(UInt32(0)) { $0 | UInt32(data[offset + $1]) << ($1 * 8) }))
        }
        func string(max: Int) throws -> String {
            let count = try integer()
            guard count >= 0, count <= max, count <= data.count - offset else {
                throw WEFormatError.corrupt("PKG string at \(offset)")
            }
            defer { offset += count }
            return String(decoding: data[offset..<offset + count], as: UTF8.self)
        }
        magic = try string(max: 32)
        guard magic.hasPrefix("PKGV") else { throw WEFormatError.badMagic(magic, expected: "PKGV*") }
        let count = try integer()
        guard count >= 0, count <= (data.count - offset) / 12 else { throw WEFormatError.corrupt("entry count") }
        var es: [Entry] = []
        for _ in 0..<count {
            es.append(Entry(path: try string(max: 255), offset: try integer(), length: try integer()))
        }
        for e in es {
            guard e.offset >= 0, e.length >= 0, e.offset <= data.count - offset,
                  e.length <= data.count - offset - e.offset else {
                throw WEFormatError.corrupt("entry \(e.path) out of bounds")
            }
        }
        entries = es
        self.data = data
        dataStart = offset
        byPath = Dictionary(es.map { ($0.path, $0) }, uniquingKeysWith: { first, _ in first })
        foldedPaths = Dictionary(es.map { ($0.path.lowercased(), $0) }, uniquingKeysWith: { first, _ in first })
    }

    /// Exact spelling wins; Windows-style case-insensitive lookup is the fallback.
    public func entry(path: String) -> Entry? { byPath[path] ?? foldedPaths[path.lowercased()] }

    public func contents(of entry: Entry) -> [UInt8] {
        Array(data[(dataStart + entry.offset)..<(dataStart + entry.offset + entry.length)])
    }

    /// A slice backed by the archive, without copying the archive payload.
    public func contents(path: String) -> Data? {
        guard let entry = entry(path: path) else { return nil }
        return data[(dataStart + entry.offset)..<(dataStart + entry.offset + entry.length)]
    }
}
