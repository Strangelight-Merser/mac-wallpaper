import Foundation

/// Per-library-entry overrides. Mutations persist atomically and surface write errors to the caller.
public final class PropertyStore {
    public let url: URL
    private var stored: [String: [String: String]]

    public init(url: URL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/MacWallpaper/properties.json")) throws {
        self.url = url
        stored = FileManager.default.fileExists(atPath: url.path)
            ? try JSONDecoder().decode([String: [String: String]].self, from: Data(contentsOf: url)) : [:]
    }
    public func values(for id: String) -> [String: String] { stored[id] ?? [:] }
    public func set(_ value: String, for id: String, key: String) throws {
        var next = stored
        next[id, default: [:]][key] = value
        try save(next)
    }
    public func reset(for id: String, key: String? = nil) throws {
        var next = stored
        if let key { next[id]?[key] = nil } else { next[id] = nil }
        try save(next)
    }
    public func overrides(for id: String, properties: [WallpaperProperty]) -> [String: String] {
        let values = values(for: id)
        return properties.reduce(into: [:]) { result, p in
            if let value = values[p.id], value != p.defaultValue { result[p.id] = value }
        }
    }
    private func save(_ next: [String: [String: String]]) throws {
        let data = try JSONEncoder().encode(next)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url, options: .atomic)
        stored = next
    }
}
