import Foundation
import CryptoKit

/// Resolves project files, scene.pkg entries, WE assets, then stock effect folders.
public struct AssetLocator {
    public let roots: [URL]
    private let package: PKG?
    private let packageError: Error?
    private let cache: URL

    /// `cacheRoot` defaults to ~/Library/Caches/MacWallpaper/pkg.
    public init(project: URL, assets: URL?, cacheRoot: URL? = nil) {
        roots = [project] + (assets.map { [$0] } ?? [])
        let url = project.appendingPathComponent("scene.pkg")
        let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
        let fingerprint = "\(url.standardizedFileURL.path)\n\(attributes?[.size] ?? 0)\n\((attributes?[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0)"
        let hash = SHA256.hash(data: Data(fingerprint.utf8)).prefix(8).map { String(format: "%02x", $0) }.joined()
        cache = (cacheRoot ?? FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Caches/MacWallpaper/pkg")).appendingPathComponent(hash)
        if attributes != nil {
            do { package = try PKG(url: url); packageError = nil }
            catch { package = nil; packageError = error }
        } else { package = nil; packageError = nil }
    }

    private enum Source { case file(URL), package(String) }

    private func source(_ relative: String) -> Source? {
        guard let path = Self.normalized(relative) else { return nil }
        let projectFile = roots[0].appendingPathComponent(path)
        if Self.isFile(projectFile) { return .file(projectFile) }
        if let entry = package?.entry(path: path), Self.normalized(entry.path) != nil { return .package(entry.path) }
        guard roots.count > 1, let assets = roots.last else { return nil }
        let assetFile = assets.appendingPathComponent(path)
        if Self.isFile(assetFile) { return .file(assetFile) }
        for name in Self.effectNames(for: path) {
            let url = assets.appendingPathComponent("effects/\(name)/\(path)")
            if Self.isFile(url) { return .file(url) }
        }
        return nil
    }

    private static func isFile(_ url: URL) -> Bool {
        var directory: ObjCBool = false
        return FileManager.default.fileExists(atPath: url.path, isDirectory: &directory) && !directory.boolValue
    }

    private static func normalized(_ path: String) -> String? {
        guard !path.isEmpty, !path.hasPrefix("/"), !path.contains("\0"), !path.contains("\\") else { return nil }
        let value = (path as NSString).standardizingPath
        guard value != ".", value != "..", !value.hasPrefix("../"), !value.hasPrefix("/") else { return nil }
        return value
    }

    /// Whether an asset is present, without extracting package entries.
    public func exists(_ relative: String) -> Bool { source(relative) != nil }

    /// Canonical relative spelling for include deduplication, without extraction.
    public func resolvedPath(_ relative: String) -> String? {
        switch source(relative) {
        case .package(let path): return Self.normalized(path)
        case .file(let url):
            for root in roots where url.path.hasPrefix(root.standardizedFileURL.path + "/") {
                return String(url.path.dropFirst(root.standardizedFileURL.path.count + 1))
            }
            return Self.normalized(relative)
        case nil: return nil
        }
    }

    /// A real file URL; package entries are atomically extracted once into the cache.
    public func url(_ relative: String) -> URL? {
        switch source(relative) {
        case .file(let url): return url
        case .package(let path):
            guard let normalized = Self.normalized(path) else { return nil }
            let url = cache.appendingPathComponent(normalized)
            if Self.isFile(url) { return url }
            do {
                guard let data = package?.contents(path: path) else { return nil }
                try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                try data.write(to: url, options: .atomic)
                return url
            } catch { return nil }
        case nil: return nil
        }
    }

    /// Effect folder names a materials/shaders path may belong to, longest first.
    static func effectNames(for relative: String) -> [String] {
        guard relative.hasPrefix("materials/effects/") || relative.hasPrefix("shaders/effects/") else { return [] }
        let components = relative.split(separator: "/")
        guard components.count > 2 else { return [] }
        let parts = components[2].split(separator: ".")[0].split(separator: "_")
        return (1...max(1, parts.count)).reversed().map { parts.prefix($0).joined(separator: "_") }
    }

    /// Read an asset directly, keeping package payloads in mapped memory.
    public func data(_ relative: String) throws -> Data {
        switch source(relative) {
        case .file(let url): return try Data(contentsOf: url)
        case .package(let path): return package!.contents(path: path)!
        case nil:
            if let packageError { throw packageError }
            throw WEFormatError.unsupported("asset not found: \(relative)")
        }
    }

    public func json(_ relative: String) throws -> [String: Any] {
        guard let obj = try JSONSerialization.jsonObject(with: data(relative), options: .json5Allowed) as? [String: Any] else {
            throw WEFormatError.corrupt("\(relative) is not a JSON object")
        }
        return obj
    }

    public func string(_ relative: String) throws -> String {
        String(decoding: try data(relative), as: UTF8.self)
    }
}

/// WE stores vectors as space-separated strings ("0.5 1 0") or bare numbers.
public func parseFloats(_ v: Any?) -> [Float]? {
    switch v {
    case let n as NSNumber: return [n.floatValue]
    case let s as String:
        let parts = s.split(whereSeparator: { $0 == " " || $0 == "," }).compactMap { Float($0) }
        return parts.isEmpty ? nil : parts
    case let d as [String: Any]: return parseFloats(d["value"]) // {"user": ..., "value": ...}
    default: return nil
    }
}
