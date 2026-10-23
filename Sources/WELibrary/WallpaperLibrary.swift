import Foundation

/// Changes in entry identities and metadata from a completed refresh.
public struct LibraryDiff: Codable, Sendable, Equatable {
    public var added: [String]
    public var updated: [String]
    public var removed: [String]
    public var problems: [String] = []
    public var cancelled = false
}

/// Persistent local index. Refreshes and deep checks run serially and stop between wallpapers on cancellation.
public actor WallpaperLibrary {
    public typealias Check = @Sendable (WallpaperEntry, URL?, Bool) async -> Compatibility
    private let indexURL: URL
    private let checkerVersion: Int
    private let checker: Check?
    private var records: [Record]
    private var storedAssets: [FileStamp]
    private var indexProblem: String?
    private var refreshing = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    private struct Record: Codable {
        var entry: WallpaperEntry
        var fingerprint: [FileStamp]
        var deepRequested: Bool
    }
    private struct Index: Codable {
        var schemaVersion = 1
        var checkerVersion: Int
        var assets: [FileStamp]
        var records: [Record]
    }

    public static var defaultIndexURL: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/MacWallpaper/library.json")
    }

    /// `checker` and `checkerVersion` can be injected for offline validation of cache invalidation.
    public init(indexURL: URL = WallpaperLibrary.defaultIndexURL, checkerVersion: Int = CompatibilityChecker.version,
                checker: Check? = nil) {
        self.indexURL = indexURL
        self.checkerVersion = checkerVersion
        self.checker = checker
        records = []; storedAssets = []
        if FileManager.default.fileExists(atPath: indexURL.path) {
            do {
                let index = try JSONDecoder().decode(Index.self, from: Data(contentsOf: indexURL))
                guard index.schemaVersion == 1 else { throw CocoaError(.fileReadCorruptFile) }
                records = index.records
                storedAssets = index.assets
                if index.checkerVersion != checkerVersion {
                    for i in records.indices { records[i].entry.compatibility = nil }
                }
            } catch {
                let bad = indexURL.appendingPathExtension("bad")
                do {
                    if FileManager.default.fileExists(atPath: bad.path) {
                        _ = try FileManager.default.replaceItemAt(bad, withItemAt: indexURL)
                    } else { try FileManager.default.moveItem(at: indexURL, to: bad) }
                } catch { indexProblem = "could not preserve unreadable index: \(error)" }
            }
        }
    }

    public func entries() -> [WallpaperEntry] { records.map(\.entry) }

    /// Rescans roots and preserves results whose folder, assets, depth and checker version still match.
    public func refresh(roots: [LibraryRoot], assets: URL?, deep: Bool) async -> LibraryDiff {
        if refreshing { await withCheckedContinuation { waiters.append($0) } }
        refreshing = true
        defer {
            if waiters.isEmpty { refreshing = false }
            else { waiters.removeFirst().resume() }
        }
        let old = Dictionary(records.map { ($0.entry.folder.path, $0) }, uniquingKeysWith: { first, _ in first })
        let assetStamps = assets.map { root in [FileStamp(root.appendingPathComponent("shaders")), FileStamp(root.appendingPathComponent("materials"))] } ?? []
        var next: [Record] = []
        var identities: [String: Int] = [:]
        for (folder, kind) in LibraryRoots.discover(roots) {
            if Task.isCancelled { return LibraryDiff(added: [], updated: [], removed: [], cancelled: true) }
            var entry = WallpaperEntry(folder: folder, root: kind)
            let base = entry.id
            let occurrence = identities[base, default: 0]
            identities[base] = occurrence + 1
            if occurrence > 0 { entry.id += "#\(occurrence + 1)"; entry.duplicateOf = base }
            let fingerprint = folderStamps(folder: folder, file: entry.file)
            var deepRequested = deep
            if let previous = old[folder.path], previous.fingerprint == fingerprint, assetStamps == storedAssets,
               let compatibility = previous.entry.compatibility, compatibility.checkerVersion == checkerVersion,
               !deep || previous.deepRequested {
                entry.compatibility = compatibility
                deepRequested = previous.deepRequested
            } else {
                var compatibility: Compatibility
                if let checker { compatibility = await checker(entry, assets, deep) }
                else { compatibility = await CompatibilityChecker(assets: assets).check(entry, deep: deep) }
                compatibility.checkerVersion = checkerVersion
                entry.compatibility = compatibility
            }
            next.append(Record(entry: entry, fingerprint: fingerprint, deepRequested: deepRequested))
        }
        if Task.isCancelled { return LibraryDiff(added: [], updated: [], removed: [], cancelled: true) }
        let before = Dictionary(records.map { ($0.entry.id, $0.entry) }, uniquingKeysWith: { first, _ in first })
        let after = Dictionary(next.map { ($0.entry.id, $0.entry) }, uniquingKeysWith: { first, _ in first })
        var diff = LibraryDiff(added: after.keys.filter { before[$0] == nil }.sorted(),
            updated: next.filter { record in
                before[record.entry.id] != nil && (before[record.entry.id] != record.entry
                    || old[record.entry.folder.path]?.fingerprint != record.fingerprint)
            }.map { $0.entry.id }.sorted(),
            removed: before.keys.filter { after[$0] == nil }.sorted())
        records = next; storedAssets = assetStamps
        if let indexProblem { diff.problems.append(indexProblem); return diff }
        do {
            let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(Index(checkerVersion: checkerVersion, assets: assetStamps, records: next))
            try FileManager.default.createDirectory(at: indexURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: indexURL, options: .atomic)
        } catch { diff.problems.append("index write: \(error)") }
        return diff
    }
}
