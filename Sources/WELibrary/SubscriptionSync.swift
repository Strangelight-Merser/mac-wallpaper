import Foundation
import WESteam

public struct SyncPlan: Sendable, Equatable {
    public var new: [WorkshopItem] = []
    public var updated: [Update] = []
    public var unsubscribed: [UInt64] = []
    public var unchanged: Int = 0

    public struct Update: Sendable, Equatable {
        public let item: WorkshopItem
        public let localManifest: UInt64
        public let localTimeUpdated: Date
    }
}

public enum SubscriptionSync {
    /// Reads only immediate, non-symlink download folders with our download receipt.
    /// Failed detail lookups still count as subscribed, but are not planned for download.
    public static func plan(subscribed: [WorkshopItem], downloads root: URL,
                            declined: Set<UInt64>) throws -> SyncPlan {
        let fm = FileManager.default
        var local: [UInt64: DownloadReceipt] = [:]
        if fm.fileExists(atPath: root.path) {
            for folder in try fm.contentsOfDirectory(at: root, includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey],
                                                     options: [.skipsHiddenFiles]) {
                let values = try folder.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
                guard values.isDirectory == true, values.isSymbolicLink != true else { continue }
                let receiptURL = folder.appendingPathComponent(".steam-manifest.json")
                guard fm.fileExists(atPath: receiptURL.path) else { continue }
                let receipt = try DownloadReceipt.load(receiptURL)
                local[receipt.publishedFileID] = receipt
            }
        }
        var plan = SyncPlan()
        let ids = Set(subscribed.map(\.id))
        plan.unsubscribed = local.keys.filter { !ids.contains($0) }.sorted()
        var seen = Set<UInt64>()
        for item in subscribed where item.result == 1 && seen.insert(item.id).inserted {
            guard let receipt = local[item.id] else {
                if !declined.contains(item.id) { plan.new.append(item) }
                continue
            }
            let date = Date(timeIntervalSince1970: Double(receipt.timeUpdated))
            if receipt.manifestID != item.contentManifestID || item.timeUpdated > date {
                plan.updated.append(.init(item: item, localManifest: receipt.manifestID, localTimeUpdated: date))
            } else {
                plan.unchanged += 1
            }
        }
        return plan
    }
}

/// Matches WorkshopDownloader's on-disk receipt (dates are Unix seconds).
struct DownloadReceipt: Decodable {
    let publishedFileID: UInt64
    let manifestID: UInt64
    let timeUpdated: Int64

    static func load(_ url: URL) throws -> Self {
        try JSONDecoder().decode(Self.self, from: Data(contentsOf: url))
    }
}
