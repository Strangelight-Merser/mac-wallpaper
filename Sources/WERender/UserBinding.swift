import Foundation

/// A scene JSON binding retained before static resolution. Nil object identifies scene settings.
public struct UserBinding {
    public let object: Int?
    public let path: String
    public let name: String
    public let condition: Any?
    let raw: [String: Any]

    static func discover(_ value: Any, object: Int?, path: String = "") -> [UserBinding] {
        if let d = value as? [String: Any] {
            var result: [UserBinding] = []
            if let user = d["user"], let name = user as? String ?? (user as? [String: Any])?["name"] as? String {
                result.append(.init(object: object, path: path, name: name,
                                    condition: (user as? [String: Any])?["condition"], raw: d))
            }
            for key in d.keys.sorted() where key != "user" && key != "value" {
                result += discover(d[key]!, object: object, path: path.isEmpty ? key : "\(path).\(key)")
            }
            return result
        }
        if let array = value as? [Any] {
            return array.enumerated().flatMap { discover($0.element, object: object, path: "\(path)[\($0.offset)]") }
        }
        return []
    }

    var supportsLive: Bool {
        if path.contains(".scriptproperties.") { return true }
        if object == nil { return ["clearcolor", "bloom", "bloomstrength", "bloomhdrstrength", "bloomthreshold", "bloomhdrthreshold"].contains(path) }
        if ["visible", "alpha", "brightness", "color", "origin", "scale", "angles", "text", "volume",
            "pointsize", "horizontalalign", "verticalalign", "maxwidth", "padding"].contains(path) { return true }
        if path.hasPrefix("instanceoverride.") {
            return ["alpha", "size", "speed", "count", "rate", "lifetime", "colorn", "color"].contains(String(path.dropFirst("instanceoverride.".count)))
        }
        return path.hasPrefix("effects[") && (path.hasSuffix(".visible") || path.contains(".constantshadervalues."))
    }
}

extension SceneRenderer {
    public func setUserProperties(_ values: [String: String]) -> Bool {
        let changed = Set(values.keys.filter { String(describing: scene.properties.values[$0] ?? "") != values[$0] })
        guard changed.isDisjoint(with: scene.properties.textureNames),
              !scene.layers.flatMap(\.passes).contains(where: { !changed.isDisjoint(with: $0.userTextures.values) }) else { return false }
        let bindings = scene.userBindings.filter { changed.contains($0.name) }
        guard bindings.allSatisfy(\.supportsLive) else { return false }
        for (key, value) in values { scene.properties.values[key] = value }
        for binding in bindings {
            if binding.path.contains(".scriptproperties.") { continue }
            let resolved: Any? = binding.path == "visible" || binding.path.hasSuffix(".visible")
                ? scene.properties.bool(binding.raw) : scene.properties.resolve(binding.raw)
            guard let value = Self.scriptValue(resolved, vectors: binding.path != "text") else { continue }
            if let object = binding.object {
                setValue(value, object: object, property: binding.path)
                if let i = layerIndexByID[object] { uniformsDirty.insert(i) }
            } else {
                let number = Self.floats(value)?.first
                switch binding.path {
                case "clearcolor": if let color = Self.vec3(value) { scene.clearColor = color }
                case "bloom": scene.bloom.enabled = scene.properties.bool(binding.raw, default: false)
                case "bloomstrength" where !scene.hdr, "bloomhdrstrength" where scene.hdr:
                    if let number { scene.bloom.strength = number }
                case "bloomthreshold" where !scene.hdr, "bloomhdrthreshold" where scene.hdr:
                    if let number { scene.bloom.threshold = number }
                default: break
                }
            }
        }
        if !bindings.isEmpty {
            layerCaches.removeAll()
            worldCache.removeAll()
            for i in bloomPasses.indices {
                plans["bloom.\(i)"] = nil
                bloomPasses[i].pass.constants["bloomstrength"] = scene.bloom.strength
                bloomPasses[i].pass.constants["bloomthreshold"] = scene.bloom.threshold
            }
        }
        scriptEngine?.userPropertiesChanged(scriptUserValues)
        return true
    }
}
