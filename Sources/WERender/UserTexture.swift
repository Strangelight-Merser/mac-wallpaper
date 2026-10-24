import Foundation
import WEFormat

extension SceneDescription.Pass {
    static func textureMap(_ value: Any?) -> [Int: String] {
        func name(_ value: Any) -> String? {
            let name = value as? String ?? (value as? [String: Any])?["name"] as? String
            return name.flatMap { $0.isEmpty ? nil : $0 }
        }
        if let array = value as? [Any] {
            return Dictionary(uniqueKeysWithValues: array.enumerated().compactMap { index, value in
                name(value).map { (index, $0) }
            })
        }
        if let map = value as? [String: Any] {
            return map.reduce(into: [:]) { result, entry in
                if let slot = Int(entry.key), slot >= 0, let name = name(entry.value) { result[slot] = name }
            }
        }
        return [:]
    }

    mutating func resolveUserTextures(properties: UserProperties, locator: AssetLocator, warn: (String) -> Void) {
        originalTextures = textures
        for (slot, property) in userTextures {
            guard let path = properties.values[property] as? String, !path.isEmpty else { continue }
            let url: URL?
            if path.hasPrefix("file://") { url = URL(string: path) }
            else if path.hasPrefix("/") { url = URL(fileURLWithPath: path) }
            else { url = locator.url(path) }
            guard let url, url.isFileURL, FileManager.default.isReadableFile(atPath: url.path),
                  (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true else {
                warn("user texture \(path): file missing or unreadable")
                continue
            }
            while textures.count <= slot { textures.append(nil) }
            textures[slot] = "$file:" + url.standardizedFileURL.resolvingSymlinksInPath().path
        }
    }
}
