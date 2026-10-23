import Foundation

/// An eligible public-branch depot checked for assets.
public struct WEAssetsDepot: Codable, Sendable, Equatable {
    public let depotID: UInt32
    public let manifestID: UInt64
}

/// Filtered assets sizes, known before downloading any content chunks.
public struct WEAssetsPlan: Sendable {
    /// The first depot; `depots` contains every selected depot and manifest.
    public var depotID: UInt32 { depots[0].depotID }
    public var manifestID: UInt64 { depots[0].manifestID }
    public let buildID: UInt64
    public let depots: [WEAssetsDepot]
    public let files: Int
    public let networkBytes: Int64
    public let diskBytes: Int64
    let content: [ContentDepot]

    init(buildID: UInt64, content: [ContentDepot]) throws {
        var paths: [String: Bool] = [:]
        for file in content.flatMap({ $0.manifest.files }) {
            let path = file.path.precomposedStringWithCanonicalMapping.lowercased()
            let directory = file.isDirectory && !file.isSymlink
            if let previous = paths[path], !previous || !directory {
                throw SteamError.malformed("conflicting assets path across depots: \(file.path)")
            }
            paths[path] = directory
        }
        for path in paths.keys {
            var parts = path.split(separator: "/")
            while parts.count > 1 {
                parts.removeLast()
                if paths[parts.joined(separator: "/")] == false {
                    throw SteamError.malformed("conflicting assets directory across depots")
                }
            }
        }
        let regularFiles = content.flatMap { $0.manifest.files }.filter { !$0.isDirectory && !$0.isSymlink }
        guard !regularFiles.isEmpty else { throw SteamError.malformed("Wallpaper Engine depots contain no assets files") }
        let sizes = try ContentSizes(regularFiles)
        self.buildID = buildID; self.content = content
        depots = content.map { WEAssetsDepot(depotID: $0.manifest.depotID, manifestID: $0.manifest.manifestID) }
        files = regularFiles.count; networkBytes = sizes.networkBytes; diskBytes = sizes.diskBytes
    }
}

/// Update sizes include only new files and files with changed SHA-1 hashes.
public enum WEAssetsUpdate: Sendable {
    case upToDate
    case available(plan: WEAssetsPlan, changedBytes: Int64, changedDiskBytes: Int64)
}

public struct WEAssetsReceipt: Codable, Sendable, Equatable {
    struct File: Codable, Sendable, Equatable {
        let path: String
        let sha: Data
    }
    let depotID: UInt32
    let manifestID: UInt64
    public let buildID: UInt64
    public let depots: [WEAssetsDepot]
    let files: Int
    let bytes: Int64
    let networkBytes: Int64
    let entries: [File]

    init(_ plan: WEAssetsPlan) {
        depotID = plan.depotID; manifestID = plan.manifestID; buildID = plan.buildID; depots = plan.depots
        files = plan.files; bytes = plan.diskBytes; networkBytes = plan.networkBytes
        entries = plan.content.flatMap { $0.manifest.files }.filter { !$0.isDirectory && !$0.isSymlink }
            .map { File(path: $0.path, sha: $0.shaContent) }
    }
    func changes(in plan: WEAssetsPlan) throws -> ContentSizes {
        var hashes: [String: Data] = [:]
        for entry in entries { hashes[entry.path] = entry.sha }
        return try ContentSizes(plan.content.flatMap { $0.manifest.files }.filter {
            !$0.isDirectory && !$0.isSymlink && (!$0.hasHash || hashes[$0.path] != $0.shaContent)
        })
    }
}

/// Downloads Wallpaper Engine's stock assets through the owner's Steam session.
public struct WEAssetsDownloader: Sendable {
    private let client: SteamCMClient
    private let content: ContentDownloader

    public init(client: SteamCMClient, session: SteamSession) {
        self.init(client: client, session: session, http: SteamHTTP())
    }
    init(client: SteamCMClient, session: SteamSession, http: SteamHTTP) {
        self.client = client; content = ContentDownloader(client: client, session: session, http: http)
    }
    /// Fetches app information and filtered manifests without fetching content chunks.
    public func plan() async throws -> WEAssetsPlan {
        let info = try await client.appInfo(appID: 431960)
        return try await plan(AssetsAppInfo(info))
    }
    private func plan(_ info: AssetsAppInfo) async throws -> WEAssetsPlan {
        var depots: [ContentDepot] = []
        for depot in info.depots {
            let fetched = try await content.plan(appID: 431960, depotID: depot.depotID, manifestID: depot.manifestID)
            depots.append(ContentDepot(manifest: try fetched.manifest.assetsOnly(), key: fetched.key, servers: fetched.servers))
        }
        return try WEAssetsPlan(buildID: info.buildID, content: depots)
    }
    /// Reuses verified local files and enforces the byte limit before writing or fetching chunks.
    public func download(_ plan: WEAssetsPlan, to assetsDir: URL, maxBytes: Int64,
                         progress: @Sendable (DownloadProgress) -> Void) async throws -> DownloadResult {
        let receipt = try JSONEncoder().encode(WEAssetsReceipt(plan))
        let result = try await content.download(plan.content, to: assetsDir, maxBytes: maxBytes,
                                                reuseDestination: true, progress: progress)
        try receipt.write(to: Self.receiptURL(for: assetsDir), options: .atomic)
        return result
    }
    /// Compares public manifest IDs, fetching new manifests only when they have changed.
    public func checkForUpdate(receiptAt assetsDir: URL) async throws -> WEAssetsUpdate {
        let receipt = try JSONDecoder().decode(WEAssetsReceipt.self, from: Data(contentsOf: Self.receiptURL(for: assetsDir)))
        let info = try AssetsAppInfo(await client.appInfo(appID: 431960))
        if info.depots == receipt.depots { return .upToDate }
        let plan = try await plan(info)
        let changes = try receipt.changes(in: plan)
        return .available(plan: plan, changedBytes: changes.networkBytes, changedDiskBytes: changes.diskBytes)
    }
    /// The receipt is a sibling of the plain assets directory.
    public static func receiptURL(for assetsDir: URL) -> URL {
        URL(fileURLWithPath: assetsDir.standardizedFileURL.path + ".steam-assets.json")
    }
}
