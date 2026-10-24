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
    typealias Peek = @Sendable (ContentServer, UInt32, Data, Data, @escaping @Sendable (Data) throws -> Bool, Int) async throws -> (plaintext: Data, bytesRead: Int)
    private let peek: Peek
    private var inFlight: Int64 = 0
    private let http: SteamHTTP
    public init(maxBytes: Int64) {
        self.maxBytes = max(0, maxBytes); http = SteamHTTP()
        peek = { try await ChunkPeek().peek(server: $0, depot: $1, sha: $2, key: $3, enough: $4, maxBytes: $5) }
    }
    init(maxBytes: Int64, http: SteamHTTP, peek: @escaping Peek = {
        try await ChunkPeek().peek(server: $0, depot: $1, sha: $2, key: $3, enough: $4, maxBytes: $5)
    }) { self.maxBytes = max(0, maxBytes); self.http = http; self.peek = peek }

    /// First PKG chunk plus complete standalone JSON files up to 256 KiB. Later table chunks need new quotes.
    public static func initialBytes(_ plan: DownloadPlan) -> Int64 {
        plan.manifest.files.filter { !$0.isDirectory && !$0.isSymlink }.reduce(0) { sum, file in
            if file.path.lowercased().hasSuffix("scene.pkg"), !file.chunks.isEmpty {
                return sum + 64 * 1024
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
            if package {
                var found = false
                if let chunk = file.chunks.first {
                    let cap = Int(min(256 * 1024, maxBytes - reservedBytes - inFlight))
                    if cap <= 0 { notes.append("\(file.path): content budget exhausted") }
                    else {
                        quote(Int64(min(cap, 64 * 1024)))
                        inFlight += Int64(cap)
                        var read = 0
                        do {
                            for server in plan.servers where read < cap {
                                do {
                                    let result = try await peek(server, plan.manifest.depotID, chunk.sha, plan.key, {
                                        try WorkshopPackageHeader.names(in: $0, fileSize: file.size) != nil
                                    }, cap - read)
                                    read += result.bytesRead
                                    if let entries = try WorkshopPackageHeader.names(in: result.plaintext, fileSize: file.size) {
                                        names += entries; found = true
                                    }
                                    break
                                } catch let failure as ChunkPeekFailure {
                                    read += failure.bytesRead
                                    if failure.underlying is CancellationError { throw CancellationError() }
                                    if !failure.retryable { throw failure.underlying }
                                }
                            }
                        } catch {
                            reservedBytes += Int64(read); inFlight -= Int64(cap)
                            if error is CancellationError { throw error }
                            notes.append("\(file.path): \(error)")
                            complete = false
                            continue
                        }
                        reservedBytes += Int64(read); inFlight -= Int64(cap)
                        if !found { notes.append("\(file.path): package header unavailable within peek limit (\(read) bytes read)") }
                    }
                } else { notes.append("\(file.path): no package chunk") }
                complete = complete && found
                continue
            }
            var prefix = Data()
            for chunk in file.chunks {
                guard Int64(chunk.compressedSize) <= maxBytes - reservedBytes - inFlight else {
                    notes.append("\(file.path): content budget exhausted"); break
                }
                quote(Int64(chunk.compressedSize))
                reservedBytes += Int64(chunk.compressedSize)
                guard let server = plan.servers.first else { throw SteamError.malformed("probe content server") }
                let data = try await http.get(server.url("/depot/\(plan.manifest.depotID)/chunk/\(chunk.sha.hex)"),
                    headers: ["Host": server.vhost], limit: chunk.compressedSize)
                prefix.append(try ChunkCodec.decode(data, key: plan.key, sha: chunk.sha,
                    originalSize: chunk.originalSize, compressedSize: chunk.compressedSize))
            }
            if prefix.count == file.size { json[file.path.lowercased()] = prefix }
        }
        return WorkshopProbeResult(names: names, jsonFiles: json, packageHeadersComplete: complete, notes: notes)
    }
}
