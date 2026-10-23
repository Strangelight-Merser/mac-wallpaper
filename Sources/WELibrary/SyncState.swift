import Foundation

public struct SyncState: Codable, Sendable, Equatable {
    public struct HeldUpdate: Codable, Sendable, Equatable {
        public let itemID: UInt64
        public let manifestID: UInt64
        public let reason: HoldReason

        public init(itemID: UInt64, manifestID: UInt64, reason: HoldReason) {
            self.itemID = itemID; self.manifestID = manifestID; self.reason = reason
        }
    }

    public var lastSync: Date?
    public var declined: Set<UInt64>
    public var held: [UInt64: HeldUpdate]

    public init(lastSync: Date? = nil, declined: Set<UInt64> = [], held: [UInt64: HeldUpdate] = [:]) {
        self.lastSync = lastSync; self.declined = declined; self.held = held
    }

    /// A missing state file is a fresh state; corrupt or unreadable files are errors.
    public static func load(from url: URL) throws -> Self {
        guard FileManager.default.fileExists(atPath: url.path) else { return Self() }
        return try JSONDecoder().decode(Self.self, from: Data(contentsOf: url))
    }

    public func save(to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(self).write(to: url, options: .atomic)
    }

    public mutating func dismiss(_ id: UInt64) { held.removeValue(forKey: id) }
}
