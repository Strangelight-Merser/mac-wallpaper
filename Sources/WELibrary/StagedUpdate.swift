import Darwin
import Foundation
import WESteam

public enum UpdateOutcome: Sendable, Equatable {
    case installed(previousKept: Bool)
    case held(reason: HoldReason)
    case failed(String)
}

public enum HoldReason: Codable, Sendable, Equatable {
    case unsupported, lostFeatures([Feature]), missingAssets
}

/// The download queue must serialize update/rollback and state edits for a given root.
/// Failed or held downloads remain in staging for the injected downloader to verify/reuse.
public struct StagedUpdater: Sendable {
    private let root: URL
    private let checker: CompatibilityChecker
    private let deepCheck: Bool
    public let stateURL: URL
    private let download: @Sendable (WorkshopItem, URL) async throws -> Void

    public init(root: URL, checker: CompatibilityChecker, deepCheck: Bool,
                stateURL: URL? = nil,
                download: @escaping @Sendable (WorkshopItem, URL) async throws -> Void) {
        self.root = root; self.checker = checker; self.deepCheck = deepCheck
        self.stateURL = stateURL ?? root.appendingPathComponent(".sync-state.json")
        self.download = download
    }

    public func update(_ item: WorkshopItem, force: Bool = false) async -> UpdateOutcome {
        let fm = FileManager.default
        let current = root.appendingPathComponent(String(item.id))
        let staged = root.appendingPathComponent(".staging/\(item.id)")
        let previous = root.appendingPathComponent(".previous/\(item.id)")
        do {
            guard item.result == 1 else { throw UpdateError.invalidItem }
            var state = try SyncState.load(from: stateURL)
            try fm.createDirectory(at: staged.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Task.checkCancellation()
            try await download(item, staged)
            try Task.checkCancellation()
            let exists = fm.fileExists(atPath: current.path)
            let next = await checker.check(WallpaperEntry(folder: staged, root: .downloads), deep: deepCheck)
            if exists {
                let old = await checker.check(WallpaperEntry(folder: current, root: .downloads), deep: deepCheck)
                try Task.checkCancellation()
                if !force, let reason = Self.regression(from: old, to: next) {
                    state.held[item.id] = .init(itemID: item.id, manifestID: item.contentManifestID, reason: reason)
                    try state.save(to: stateURL)
                    return .held(reason: reason)
                }
            }
            try Task.checkCancellation()
            state.dismiss(item.id)
            if exists {
                try fm.createDirectory(at: previous.deletingLastPathComponent(), withIntermediateDirectories: true)
                if fm.fileExists(atPath: previous.path) { try fm.removeItem(at: previous) }
                try exchange(staged, current)
                do { try fm.moveItem(at: staged, to: previous) }
                catch { try exchange(staged, current); throw error }
                do { try state.save(to: stateURL) }
                catch {
                    try exchange(previous, current)
                    try fm.moveItem(at: previous, to: staged)
                    throw error
                }
            } else {
                try fm.moveItem(at: staged, to: current)
                do { try state.save(to: stateURL) }
                catch { try fm.moveItem(at: current, to: staged); throw error }
            }
            return .installed(previousKept: exists)
        } catch { return .failed(String(describing: error)) }
    }

    /// Exchanges the current and kept versions atomically; the replaced version remains kept.
    public func rollback(_ id: UInt64) throws {
        try exchange(root.appendingPathComponent(".previous/\(id)"), root.appendingPathComponent(String(id)))
    }

    static func regression(from old: Compatibility, to next: Compatibility) -> HoldReason? {
        let newMissing = Feature.allCases.filter { next.missing[$0, default: 0] > 0 && old.missing[$0, default: 0] == 0 }
        if newMissing.contains(.missingAsset) { return .missingAssets }
        if rank(next.status) < rank(old.status) {
            if next.status == .needsAssets { return .missingAssets }
            if next.status == .unsupported { return .unsupported }
        }
        if !newMissing.isEmpty { return .lostFeatures(newMissing) }
        return rank(next.status) < rank(old.status) ? .unsupported : nil
    }

    private static func rank(_ status: Compatibility.Status) -> Int {
        switch status {
        case .supported: return 3
        case .partial: return 2
        case .needsAssets: return 1
        case .unsupported: return 0
        }
    }
}

private enum UpdateError: Error { case invalidItem }

private func exchange(_ first: URL, _ second: URL) throws {
    guard renamex_np(first.path, second.path, UInt32(RENAME_SWAP)) == 0 else {
        throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
    }
}
