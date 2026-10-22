import Foundation

/// Resolves wallpaper-relative paths, falling back to the WE `assets/` directory
/// (directory-backed only for now; PKG roots come later).
public struct AssetLocator {
    public let roots: [URL]

    /// - Parameters:
    ///   - project: unpacked wallpaper directory (contains project.json)
    ///   - assets: Wallpaper Engine `assets` directory, if available
    public init(project: URL, assets: URL?) {
        roots = [project] + (assets.map { [$0] } ?? [])
    }

    public func url(_ relative: String) -> URL? {
        for r in roots {
            let u = r.appendingPathComponent(relative)
            if FileManager.default.fileExists(atPath: u.path) { return u }
        }
        return nil
    }

    public func data(_ relative: String) throws -> Data {
        guard let u = url(relative) else { throw WEFormatError.unsupported("asset not found: \(relative)") }
        return try Data(contentsOf: u)
    }

    public func json(_ relative: String) throws -> [String: Any] {
        // JSON5 mode tolerates the trailing commas some WE files contain (e.g. fluidsimulation).
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
