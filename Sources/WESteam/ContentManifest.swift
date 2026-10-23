import Foundation

/// Decrypted SteamPipe file and chunk mappings.
public struct ContentManifest: Sendable, Equatable {
    public struct Chunk: Sendable, Equatable {
        public let sha: Data
        public let crc: UInt32
        public let offset: UInt64
        public let originalSize: Int
        public let compressedSize: Int
    }
    public struct File: Sendable, Equatable {
        public let path: String
        public let size: UInt64
        public let flags: UInt32
        public let shaFilename: Data
        public let shaContent: Data
        public let chunks: [Chunk]
        public let linkTarget: String
        // steam-user/enums/EDepotFileFlag.js.
        public var isDirectory: Bool { flags & 64 != 0 }
        public var isSymlink: Bool { !linkTarget.isEmpty || flags & 512 != 0 }
        var hasHash: Bool { shaContent.count == 20 && shaContent.contains { $0 != 0 } }
    }
    public let depotID: UInt32
    public let manifestID: UInt64
    public let files: [File]

    public init(data: Data, key: Data) throws {
        var cursor = ByteCursor(data), payload: Data?, metadata: Data?, ended = false
        while cursor.remaining > 0 {
            // steam-user/components/content_manifest.js.
            let magic = try cursor.integer(UInt32.self)
            if magic == 0x32c415ab { ended = true; break }
            let length = Int(try cursor.integer(UInt32.self)), section = try cursor.read(length)
            switch magic {
            case 0x71f617d0:
                guard payload == nil else { throw SteamError.malformed("duplicate manifest payload") }
                payload = section
            case 0x1f4812be:
                guard metadata == nil else { throw SteamError.malformed("duplicate manifest metadata") }
                metadata = section
            case 0x1b81b817: break
            default: throw SteamError.malformed("manifest magic")
            }
        }
        guard ended, cursor.remaining == 0, let payload, let metadata else { throw SteamError.malformed("manifest container") }
        // All manifest field numbers: steam-user/protobufs/content_manifest.proto.
        let meta = try ProtoReader(metadata)
        guard meta.uint(1) <= UInt32.max else { throw SteamError.malformed("manifest depot") }
        depotID = UInt32(meta.uint(1)); manifestID = meta.uint(2)
        var files: [File] = [], seen = Set<String>()
        for mapping in try ProtoReader(payload).repeated(1) {
            let p = try ProtoReader(mapping)
            var name = p.string(1)
            if meta.uint(4) != 0 {
                // Steam's base64 contains line breaks (Node's decoder skips them); the name ends at the first NUL
                // (content_manifest.js, decryptFilenames).
                guard let encrypted = Data(base64Encoded: name, options: .ignoreUnknownCharacters) else {
                    throw SteamError.malformed("encrypted filename")
                }
                var plain = try ChunkCodec.decrypt(encrypted, key: key)
                if let end = plain.firstIndex(of: 0) { plain = plain[..<end] }
                guard let decoded = String(data: plain, encoding: .utf8) else { throw SteamError.malformed("filename UTF-8") }
                name = decoded
            }
            let path = try Self.normalizedPath(name)
            guard seen.insert(path.precomposedStringWithCanonicalMapping.lowercased()).inserted,
                  p.uint(2) <= Int64.max, p.uint(3) <= UInt32.max else { throw SteamError.malformed("duplicate path or file size") }
            let chunks = try p.repeated(6).map { bytes -> Chunk in
                let c = try ProtoReader(bytes)
                guard c.bytes(1).count == 20, c.uint(4) <= UInt32.max, c.uint(5) <= UInt32.max else {
                    throw SteamError.malformed("manifest chunk")
                }
                return Chunk(sha: c.bytes(1), crc: UInt32(truncatingIfNeeded: c.uint(2)), offset: c.uint(3),
                             originalSize: Int(c.uint(4)), compressedSize: Int(c.uint(5)))
            }.sorted { $0.offset < $1.offset }
            let file = File(path: path, size: p.uint(2), flags: UInt32(p.uint(3)), shaFilename: p.bytes(4),
                            shaContent: p.bytes(5), chunks: chunks, linkTarget: p.string(7))
            if !file.isDirectory && !file.isSymlink {
                var end: UInt64 = 0
                for chunk in chunks {
                    guard chunk.offset == end, chunk.originalSize > 0, chunk.compressedSize > 0,
                          UInt64(chunk.originalSize) <= file.size - min(end, file.size) else {
                        throw SteamError.malformed("manifest chunk coverage")
                    }
                    end += UInt64(chunk.originalSize)
                }
                guard end == file.size, file.shaContent.isEmpty || file.shaContent.count == 20 else {
                    throw SteamError.malformed("manifest file coverage or hash")
                }
            }
            files.append(file)
        }
        let nonDirectories = Set(files.filter { !$0.isDirectory || $0.isSymlink }
            .map { $0.path.precomposedStringWithCanonicalMapping.lowercased() })
        for file in files {
            var parts = file.path.precomposedStringWithCanonicalMapping.lowercased().split(separator: "/")
            while parts.count > 1 {
                parts.removeLast()
                guard !nonDirectories.contains(parts.joined(separator: "/")) else { throw SteamError.malformed("manifest path conflict") }
            }
        }
        self.files = files
    }
    static func normalizedPath(_ name: String) throws -> String {
        let path = name.replacingOccurrences(of: "\\", with: "/")
        let parts = path.split(separator: "/", omittingEmptySubsequences: false)
        guard !path.isEmpty, !path.hasPrefix("/"), !path.contains("\0"), !path.contains(":"),
              !parts.contains(".."), !parts.contains("."), !parts.contains(""),
              parts.first?.lowercased() != ".steam-manifest.json" else { throw SteamError.malformed("unsafe manifest path") }
        return path
    }
}
