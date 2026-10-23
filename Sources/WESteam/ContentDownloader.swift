import CryptoKit
import Foundation
import Darwin

/// Manifest-backed sizes available before any content chunks are fetched.
public struct DownloadPlan: Sendable {
    public let item: WorkshopItem
    public let manifest: ContentManifest
    public let networkBytes: Int64
    public let diskBytes: Int64
    let key: Data
    let servers: [ContentServer]
    init(item: WorkshopItem, manifest: ContentManifest, key: Data, servers: [ContentServer]) throws {
        self.item = item; self.manifest = manifest; self.key = key; self.servers = servers
        let sizes = try ContentSizes(manifest.files)
        networkBytes = sizes.networkBytes; diskBytes = sizes.diskBytes
    }
    /// Applies the content network-byte limit before creating or writing the destination.
    public func checkLimit(_ maxBytes: Int64) throws {
        guard maxBytes >= 0, networkBytes <= maxBytes else { throw SteamError.tooLarge(networkBytes) }
    }
}

/// Completed network bytes and files; resumed files contribute no network bytes.
public struct DownloadProgress: Sendable, Equatable {
    public let networkBytesDone: Int64
    public let networkBytesTotal: Int64
    public let filesDone: Int
    public let filesTotal: Int
}

/// A verified content directory, including warnings for skipped symbolic links.
public struct DownloadResult: Sendable {
    public let destination: URL
    public let files: Int
    public let bytes: Int64
    public let warnings: [String]
}

struct ContentServer: Sendable {
    let host: String
    let vhost: String
    func url(_ path: String) throws -> URL {
        guard let url = URL(string: "https://\(host)\(path)"), url.host == host, url.user == nil else {
            throw SteamError.malformed("content server host")
        }
        return url
    }
    static func parse(_ response: JSONValue) -> [ContentServer] {
        response["servers"].array.filter {
            ["SteamCache", "CDN"].contains($0["type"].string) &&
            ["mandatory", "optional"].contains($0["https_support"].string) &&
            !$0["use_as_proxy"].bool && !$0["usetokenauth"].bool && $0["allowed_app_ids"].array.isEmpty
        }.sorted { $0["weighted_load"].double < $1["weighted_load"].double }.prefix(8).map {
            ContentServer(host: $0["host"].string, vhost: $0["vhost"].string.isEmpty ? $0["host"].string : $0["vhost"].string)
        }
    }
}

/// Workshop-only SteamPipe downloader with verified files, resume and bounded concurrency.
public struct WorkshopDownloader: Sendable {
    private let client: SteamCMClient
    private let session: SteamSession
    private let http: SteamHTTP
    public let concurrency: Int
    public init(client: SteamCMClient, session: SteamSession, concurrency: Int = 6) {
        self.client = client; self.session = session; self.concurrency = max(1, concurrency); http = SteamHTTP()
    }
    init(client: SteamCMClient, session: SteamSession, concurrency: Int = 6, http: SteamHTTP) {
        self.client = client; self.session = session; self.concurrency = max(1, concurrency); self.http = http
    }
    public func plan(_ item: WorkshopItem) async throws -> DownloadPlan {
        guard item.result == 1 else { throw SteamError.result(item.result) }
        guard item.appID == 431960, item.contentManifestID > 0 else { throw SteamError.malformed("not a Wallpaper Engine workshop item") }
        let depot = try await content.plan(appID: item.appID, depotID: item.appID, manifestID: item.contentManifestID)
        return try DownloadPlan(item: item, manifest: depot.manifest, key: depot.key, servers: depot.servers)
    }
    public func download(_ plan: DownloadPlan, to dest: URL, maxBytes: Int64,
                         progress: @Sendable (DownloadProgress) -> Void) async throws -> DownloadResult {
        try plan.checkLimit(maxBytes)
        struct Receipt: Encodable {
            let publishedFileID: UInt64; let manifestID: UInt64; let timeUpdated: Int64; let files: Int; let bytes: Int64
        }
        let receipt = Receipt(publishedFileID: plan.item.id, manifestID: plan.item.contentManifestID,
                              timeUpdated: Int64(plan.item.timeUpdated.timeIntervalSince1970),
                              files: plan.manifest.files.filter { !$0.isDirectory && !$0.isSymlink }.count, bytes: plan.diskBytes)
        return try await content.download([ContentDepot(manifest: plan.manifest, key: plan.key, servers: plan.servers)],
                                          to: dest, maxBytes: maxBytes, receipt: JSONEncoder().encode(receipt), progress: progress)
    }
    private var content: ContentDownloader {
        ContentDownloader(client: client, session: session, http: http, concurrency: concurrency)
    }
}

struct ContentDepot: Sendable {
    let manifest: ContentManifest
    let key: Data
    let servers: [ContentServer]
}

struct ContentSizes {
    let networkBytes: Int64
    let diskBytes: Int64
    init(_ files: [ContentManifest.File]) throws {
        var network: Int64 = 0, disk: Int64 = 0
        for file in files {
            guard file.size <= Int64.max else { throw SteamError.malformed("download size overflow") }
            let (next, overflow) = disk.addingReportingOverflow(Int64(file.size))
            guard !overflow else { throw SteamError.malformed("download size overflow") }; disk = next
            for chunk in file.chunks {
                let (next, overflow) = network.addingReportingOverflow(Int64(chunk.compressedSize))
                guard !overflow else { throw SteamError.malformed("download size overflow") }; network = next
            }
        }
        networkBytes = network; diskBytes = disk
    }
}

struct ContentDownloader: Sendable {
    let client: SteamCMClient
    let session: SteamSession
    let http: SteamHTTP
    var concurrency = 6

    func plan(appID: UInt32, depotID: UInt32, manifestID: UInt64) async throws -> ContentDepot {
        let response = try await http.api("IContentServerDirectoryService", "GetServersForSteamPipe",
                                          fields: ["cell_id": String(session.cellID)], get: true)
        let servers = ContentServer.parse(response)
        guard !servers.isEmpty else { throw SteamError.malformed("no HTTPS content servers without authentication restrictions") }
        let key = try await client.depotDecryptionKey(appID: appID, depotID: depotID)
        // steammessages_contentsystem.steamclient.proto: GetManifestRequestCode{_Request,_Response}.
        var request = ProtoWriter()
        request.uint(1, UInt64(appID)); request.uint(2, UInt64(depotID))
        request.uint(3, manifestID); request.string(4, "public")
        let code = try ProtoReader(await client.callService("ContentServerDirectory.GetManifestRequestCode#1", request.data)).uint(1)
        guard code != 0 else { throw SteamError.malformed("manifest request code") }
        // steam-user/components/cdn.js, getRawManifest: manifest serialization version 5.
        let path = "/depot/\(depotID)/manifest/\(manifestID)/5/\(code)"
        var last: Error = SteamError.transport
        for server in servers {
            do {
                let data = try await http.get(server.url(path), headers: ["Host": server.vhost], limit: 64 * 1024 * 1024)
                let manifest = try ContentManifest(data: ChunkCodec.decompress(data), key: key)
                guard manifest.depotID == depotID, manifest.manifestID == manifestID else {
                    throw SteamError.malformed("manifest identity")
                }
                return ContentDepot(manifest: manifest, key: key, servers: servers)
            } catch {
                if Task.isCancelled { throw CancellationError() }
                last = error
            }
        }
        throw last
    }
    func download(_ depots: [ContentDepot], to dest: URL, maxBytes: Int64, reuseDestination: Bool = false,
                  receipt: Data? = nil, progress: @Sendable (DownloadProgress) -> Void) async throws -> DownloadResult {
        let entries = depots.flatMap { depot in depot.manifest.files.map { (file: $0, depot: depot) } }
        let manifestFiles = entries.map(\.file)
        let files = entries.filter { !$0.file.isDirectory && !$0.file.isSymlink }
        let sizes = try ContentSizes(reuseDestination ? files.map(\.file) : manifestFiles)
        let partial = URL(fileURLWithPath: dest.standardizedFileURL.path + ".partial", isDirectory: true)
        var networkBytes = sizes.networkBytes
        if reuseDestination {
            let missing = try files.filter { entry in
                guard entry.file.hasHash else { return true }
                return try !reusableFile(partial, entry.file) && !reusableFile(dest.standardizedFileURL, entry.file)
            }
            networkBytes = try ContentSizes(missing.map(\.file)).networkBytes
        }
        guard maxBytes >= 0, networkBytes <= maxBytes else { throw SteamError.tooLarge(networkBytes) }
        try Task.checkCancellation()
        let fm = FileManager.default
        let dest = dest.standardizedFileURL
        guard dest.isFileURL, dest.path != "/", depots.allSatisfy({ !$0.servers.isEmpty }) else { throw SteamError.malformed("download destination or servers") }
        try safeDirectory(partial, root: partial)
        var warnings: [String] = []
        var completed = 0, networkDone: Int64 = 0
        let budget = DownloadBudget(maxBytes)
        progress(DownloadProgress(networkBytesDone: 0, networkBytesTotal: networkBytes, filesDone: 0, filesTotal: files.count))
        // A prior manifest may leave obsolete files in the staging directory.
        let expected = Set(manifestFiles.filter { !$0.isSymlink }.map(\.path))
        try prunePartial(partial, expected: expected)
        for file in manifestFiles {
            if file.isSymlink { warnings.append("Skipped symbolic link: \(file.path)") }
            else if file.isDirectory { try safeDirectory(partial.appendingPathComponent(file.path), root: partial) }
        }
        for entry in files {
            let file = entry.file
            try Task.checkCancellation()
            let output = partial.appendingPathComponent(file.path)
            try safeDirectory(output.deletingLastPathComponent(), root: partial)
            if reuseDestination, file.hasHash, try !fileMatches(output, file), try reusableFile(dest, file) {
                if fm.fileExists(atPath: output.path) { try fm.removeItem(at: output) }
                try fm.copyItem(at: dest.appendingPathComponent(file.path), to: output)
            }
            if file.hasHash, try fileMatches(output, file) {
                completed += 1
                progress(DownloadProgress(networkBytesDone: networkDone, networkBytesTotal: networkBytes,
                                          filesDone: completed, filesTotal: files.count))
                continue
            }
            if fm.fileExists(atPath: output.path) {
                let values = try output.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
                guard values.isRegularFile == true, values.isSymbolicLink != true else { throw SteamError.malformed("unsafe partial file") }
            } else {
                guard fm.createFile(atPath: output.path, contents: nil) else { throw SteamError.malformed("cannot create download file") }
            }
            let handle = try FileHandle(forWritingTo: output)
            do {
                try handle.truncate(atOffset: file.size)
                try await withThrowingTaskGroup(of: (ContentManifest.Chunk, Data).self) { group in
                    var next = 0
                    func enqueue(_ index: Int) {
                        let chunk = file.chunks[index]
                        group.addTask { (chunk, try await fetchChunk(chunk, depot: entry.depot, index: index, budget: budget)) }
                    }
                    while next < min(concurrency, file.chunks.count) { enqueue(next); next += 1 }
                    for try await (chunk, plain) in group {
                        try Task.checkCancellation()
                        try handle.seek(toOffset: chunk.offset); try handle.write(contentsOf: plain)
                        networkDone = await budget.used
                        progress(DownloadProgress(networkBytesDone: networkDone, networkBytesTotal: networkBytes,
                                                  filesDone: completed, filesTotal: files.count))
                        if next < file.chunks.count { enqueue(next); next += 1 }
                    }
                }
                try handle.synchronize(); try handle.close()
            } catch { try? handle.close(); throw error }
            guard try fileMatches(output, file) else { throw SteamError.malformed("file SHA-1 or size") }
            if file.flags & 32 != 0 { try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: output.path) }
            completed += 1
            progress(DownloadProgress(networkBytesDone: networkDone, networkBytesTotal: networkBytes,
                                      filesDone: completed, filesTotal: files.count))
        }
        // Recheck resumed files before publishing the staging directory.
        for entry in files {
            guard try fileMatches(partial.appendingPathComponent(entry.file.path), entry.file) else {
                throw SteamError.malformed("final file verification")
            }
        }
        if let receipt { try receipt.write(to: partial.appendingPathComponent(".steam-manifest.json"), options: .atomic) }
        try Task.checkCancellation()
        try publish(partial, to: dest)
        return DownloadResult(destination: dest, files: completed, bytes: sizes.diskBytes, warnings: warnings)
    }
    private func fetchChunk(_ chunk: ContentManifest.Chunk, depot: ContentDepot, index: Int,
                            budget: DownloadBudget) async throws -> Data {
        var last: Error = SteamError.transport
        // Initial attempt plus three retries, rotating content servers.
        for attempt in 0...3 {
            try Task.checkCancellation()
            try await budget.reserve(Int64(chunk.compressedSize))
            let server = depot.servers[(index + attempt) % depot.servers.count]
            do {
                let data = try await http.get(server.url("/depot/\(depot.manifest.depotID)/chunk/\(chunk.sha.hex)"),
                                              headers: ["Host": server.vhost], limit: chunk.compressedSize)
                await budget.received(Int64(data.count))
                return try ChunkCodec.decode(data, key: depot.key, sha: chunk.sha,
                                             originalSize: chunk.originalSize, compressedSize: chunk.compressedSize)
            } catch {
                if Task.isCancelled { throw CancellationError() }
                if case SteamError.unsupportedCompression = error { throw error }
                last = error
            }
        }
        throw last
    }
}

private actor DownloadBudget {
    let limit: Int64
    var reserved: Int64 = 0
    var used: Int64 = 0
    init(_ limit: Int64) { self.limit = limit }
    func reserve(_ bytes: Int64) throws {
        guard bytes <= limit - reserved else { throw SteamError.tooLarge(reserved > Int64.max - bytes ? Int64.max : reserved + bytes) }
        reserved += bytes
    }
    func received(_ bytes: Int64) { used += bytes }
}

private func prunePartial(_ partial: URL, expected: Set<String>) throws {
    let fm = FileManager.default
    guard let enumerator = fm.enumerator(atPath: partial.path) else {
        throw SteamError.malformed("cannot enumerate partial directory")
    }
    var obsolete: [URL] = []
    for case let relative as String in enumerator {
        let url = partial.appendingPathComponent(relative)
        let values = try url.resourceValues(forKeys: [.isSymbolicLinkKey, .isDirectoryKey])
        guard values.isSymbolicLink != true else { throw SteamError.malformed("symlink in partial directory") }
        if !expected.contains(relative) && !expected.contains(where: { $0.hasPrefix(relative + "/") }) {
            obsolete.append(url); if values.isDirectory == true { enumerator.skipDescendants() }
        }
    }
    for url in obsolete { try fm.removeItem(at: url) }
}

private func safeDirectory(_ url: URL, root: URL) throws {
    let fm = FileManager.default
    var ancestor = url
    while true {
        if let attributes = try? fm.attributesOfItem(atPath: ancestor.path) {
            guard attributes[.type] as? FileAttributeType == .typeDirectory else { throw SteamError.malformed("unsafe download directory") }
        }
        if ancestor.path == root.path { break }
        guard ancestor.path.hasPrefix(root.path + "/") else { throw SteamError.malformed("directory outside staging root") }
        ancestor.deleteLastPathComponent()
    }
    try fm.createDirectory(at: url, withIntermediateDirectories: true)
}

private func reusableFile(_ root: URL, _ file: ContentManifest.File) throws -> Bool {
    var directory = root.appendingPathComponent(file.path).deletingLastPathComponent()
    while true {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: directory.path),
              attrs[.type] as? FileAttributeType == .typeDirectory else { return false }
        if directory.path == root.path { break }
        directory.deleteLastPathComponent()
    }
    return try fileMatches(root.appendingPathComponent(file.path), file)
}

private func fileMatches(_ url: URL, _ file: ContentManifest.File) throws -> Bool {
    let fm = FileManager.default
    guard fm.fileExists(atPath: url.path) else { return false }
    let attrs = try fm.attributesOfItem(atPath: url.path)
    guard attrs[.type] as? FileAttributeType == .typeRegular,
          (attrs[.size] as? NSNumber)?.uint64Value == file.size else { return false }
    guard file.hasHash else { return true }
    let handle = try FileHandle(forReadingFrom: url)
    defer { try? handle.close() }
    var hash = Insecure.SHA1()
    while let data = try handle.read(upToCount: 1024 * 1024), !data.isEmpty { hash.update(data: data) }
    return Data(hash.finalize()) == file.shaContent
}

private func publish(_ partial: URL, to dest: URL) throws {
    let fm = FileManager.default
    if !fm.fileExists(atPath: dest.path) { try fm.moveItem(at: partial, to: dest); return }
    let attrs = try fm.attributesOfItem(atPath: dest.path)
    guard attrs[.type] as? FileAttributeType == .typeDirectory else { throw SteamError.malformed("destination is not a directory") }
    // Darwin's atomic directory exchange keeps either complete version visible at dest.
    guard renamex_np(partial.path, dest.path, UInt32(RENAME_SWAP)) == 0 else {
        throw SteamError.malformed("atomic destination replacement failed")
    }
    try fm.removeItem(at: partial)
}
