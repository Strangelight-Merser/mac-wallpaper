import Foundation

/// Incremental PKG table parsing, without requiring any archive payload.
public enum WorkshopPackageHeader {
    /// nil means more prefix bytes are needed. Invalid tables throw rather than trigger further downloads.
    public static func names(in data: Data, fileSize: UInt64) throws -> [String]? {
        var offset = 0
        func integer() -> UInt32? {
            guard data.count - offset >= 4 else { return nil }
            defer { offset += 4 }
            return (0..<4).reduce(UInt32(0)) { $0 | UInt32(data[offset + $1]) << ($1 * 8) }
        }
        func string(max: Int) throws -> String? {
            guard let length = integer() else { return nil }
            guard length <= max else { throw SteamError.malformed("PKG string length") }
            guard Int(length) <= data.count - offset else { return nil }
            defer { offset += Int(length) }
            guard let value = String(data: data[offset..<offset + Int(length)], encoding: .utf8) else {
                throw SteamError.malformed("PKG UTF-8")
            }
            return value
        }
        guard let magic = try string(max: 32) else { return nil }
        guard magic.hasPrefix("PKGV") else { throw SteamError.malformed("PKG magic") }
        guard let count = integer() else { return nil }
        guard UInt64(count) <= fileSize / 12 else { throw SteamError.malformed("PKG entry count") }
        var entries: [(String, UInt64, UInt64)] = []
        for _ in 0..<count {
            guard let name = try string(max: 255), let start = integer(), let size = integer() else { return nil }
            guard start <= Int32.max, size <= Int32.max else { throw SteamError.malformed("PKG entry range") }
            entries.append((name, UInt64(start), UInt64(size)))
        }
        guard UInt64(offset) <= fileSize else { throw SteamError.malformed("PKG header range") }
        let payload = fileSize - UInt64(offset)
        guard entries.allSatisfy({ $0.1 <= payload && $0.2 <= payload - $0.1 }) else {
            throw SteamError.malformed("PKG entry range")
        }
        return entries.map(\.0)
    }
}

public struct WorkshopProbeResult: Sendable {
    public let names: [String]
    public let jsonFiles: [String: Data]
    public let packageHeadersComplete: Bool
    public let notes: [String]
}

/// A survey-wide content budget. No retries: a failed request still consumes its reserved bytes.
public actor WorkshopProbe {
    public let maxBytes: Int64
    public private(set) var reservedBytes: Int64 = 0
    private let http: SteamHTTP
    public init(maxBytes: Int64) { self.maxBytes = max(0, maxBytes); http = SteamHTTP() }
    init(maxBytes: Int64, http: SteamHTTP) { self.maxBytes = max(0, maxBytes); self.http = http }

    /// First PKG chunk plus complete standalone JSON files up to 256 KiB. Later table chunks need new quotes.
    public static func initialBytes(_ plan: DownloadPlan) -> Int64 {
        plan.manifest.files.filter { !$0.isDirectory && !$0.isSymlink }.reduce(0) { sum, file in
            if file.path.lowercased().hasSuffix("scene.pkg"), file.chunks.count > 1 {
                return sum + Int64(file.chunks.first?.compressedSize ?? 0)
            }
            if smallJSON(file) { return sum + file.chunks.reduce(0) { $0 + Int64($1.compressedSize) } }
            return sum
        }
    }
    private static func smallJSON(_ file: ContentManifest.File) -> Bool {
        ["project.json", "scene.json"].contains(file.path.lowercased()) && file.size <= 256 * 1024
    }
    public func inspect(_ plan: DownloadPlan, quote: @Sendable (Int64) -> Void = { _ in }) async throws -> WorkshopProbeResult {
        var names = plan.manifest.files.filter { !$0.isDirectory && !$0.isSymlink }.map(\.path)
        var json: [String: Data] = [:], notes: [String] = [], complete = true
        for file in plan.manifest.files where !file.isDirectory && !file.isSymlink {
            let package = file.path.lowercased().hasSuffix("scene.pkg")
            guard package || Self.smallJSON(file) else { continue }
            var prefix = Data(), found = false
            for chunk in file.chunks {
                // Do not turn a header inspection into a complete archive download.
                if package && chunk.offset + UInt64(chunk.originalSize) == file.size {
                    notes.append("\(file.path): final chunk skipped to avoid downloading the whole package")
                    break
                }
                guard Int64(chunk.compressedSize) <= maxBytes - reservedBytes else {
                    notes.append("\(file.path): content budget exhausted"); break
                }
                quote(Int64(chunk.compressedSize))
                reservedBytes += Int64(chunk.compressedSize)
                guard let server = plan.servers.first else { throw SteamError.malformed("probe content server") }
                let data = try await http.get(server.url("/depot/\(plan.manifest.depotID)/chunk/\(chunk.sha.hex)"),
                    headers: ["Host": server.vhost], limit: chunk.compressedSize)
                prefix.append(try ChunkCodec.decode(data, key: plan.key, sha: chunk.sha,
                    originalSize: chunk.originalSize, compressedSize: chunk.compressedSize))
                if package, let entries = try WorkshopPackageHeader.names(in: prefix, fileSize: file.size) {
                    names += entries; found = true; break
                }
            }
            if package { complete = complete && found }
            else if prefix.count == file.size { json[file.path.lowercased()] = prefix }
        }
        return WorkshopProbeResult(names: names, jsonFiles: json, packageHeadersComplete: complete, notes: notes)
    }
}
