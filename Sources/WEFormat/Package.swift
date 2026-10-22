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
    private let data: [UInt8]
    private let dataStart: Int

    public init(bytes: [UInt8]) throws {
        var r = BinaryReader(bytes)
        magic = try r.sizedString(maxLength: 32)
        guard magic.hasPrefix("PKGV") else { throw WEFormatError.badMagic(magic, expected: "PKGV*") }
        let count = try r.int()
        guard count >= 0 else { throw WEFormatError.corrupt("entry count") }
        var es: [Entry] = []
        for _ in 0..<count {
            let p = try r.sizedString(maxLength: 255)
            es.append(Entry(path: p, offset: try r.int(), length: try r.int()))
        }
        entries = es
        data = bytes
        dataStart = r.offset
        for e in es where e.offset < 0 || e.length < 0 || dataStart + e.offset + e.length > bytes.count {
            throw WEFormatError.corrupt("entry \(e.path) out of bounds")
        }
    }

    public func contents(of entry: Entry) -> [UInt8] {
        Array(data[(dataStart + entry.offset)..<(dataStart + entry.offset + entry.length)])
    }

    public func contents(path: String) -> [UInt8]? {
        entries.first { $0.path == path }.map(contents(of:))
    }
}
