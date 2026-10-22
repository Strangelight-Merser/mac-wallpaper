import Foundation
import WEFormat

/// User-adjustable properties from project.json (`general.properties`), plus CLI/app overrides.
public struct UserProperties {
    public var values: [String: Any]

    public init(project: [String: Any], overrides: [String: String] = [:]) {
        var v: [String: Any] = [:]
        let props = (project["general"] as? [String: Any])?["properties"] as? [String: Any] ?? [:]
        for (k, p) in props { if let p = p as? [String: Any], let value = p["value"] { v[k] = value } }
        for (k, s) in overrides { v[k] = s }
        values = v
    }

    /// Resolve a scene value that may be bound to a user property:
    /// plain value, `{"user": "name", "value": default}`, `{"user": {"name": ...}, "value": ...}`
    /// or `{"script": ..., "value": ...}` (scripts are not run yet: their static value is used).
    public func resolve(_ v: Any?) -> Any? {
        guard let d = v as? [String: Any] else { return v }
        if let user = d["user"] {
            let name = (user as? String) ?? ((user as? [String: Any])?["name"] as? String)
            if let n = name, let value = values[n] {
                // {"user": {"name": "x", "condition": "y"}}: compare against the condition when present
                if let cond = (user as? [String: Any])?["condition"] {
                    return String(describing: value) == String(describing: cond)
                }
                return value
            }
        }
        return d["value"] ?? (d["user"] == nil && d["script"] == nil ? v : nil)
    }

    public func bool(_ v: Any?, default def: Bool = true) -> Bool {
        switch resolve(v) {
        case let b as Bool: return b
        case let n as NSNumber: return n.boolValue
        case let s as String: return !(s == "0" || s == "false")
        default: return def
        }
    }
}

/// The subset of scene.json needed for image layers with effects (milestones M3/M4).
public struct SceneDescription {
    public struct Pass {
        public var shader: String
        /// Texture per slot; nil = engine-provided (previous pass output for effects).
        public var textures: [String?]
        public var blending: String
        public var constants: [String: Any]
        public var combos: [String: Int]
        public var label: String
        /// Index into the layer's `effects` (nil for material passes).
        public var effect: Int?
        /// Named FBO this pass renders into instead of the layer ping-pong chain.
        public var target: String?
        /// Slot → FBO name, or "previous" (the input at the start of the current target sequence).
        public var binds: [Int: String] = [:]
        /// `{"command": "copy"}` pass: copy one FBO into another, no shader.
        public var copy: (source: String, target: String)?
        /// `{"command": "swap"}`: exchange two FBOs (ping-pong simulations); uses `copy` for the names.
        public var swap = false

        init(material: [String: Any], label: String) {
            shader = material["shader"] as? String ?? "genericimage"
            textures = (material["textures"] as? [Any] ?? []).map { $0 as? String }
            blending = material["blending"] as? String ?? "normal"
            constants = material["constantshadervalues"] as? [String: Any] ?? [:]
            combos = Self.intCombos(material["combos"])
            self.label = label
        }

        init(copyFrom source: String, to target: String, label: String) {
            self.init(shader: "", label: label)
            copy = (source, target)
            self.target = target
        }

        init(shader: String, label: String, combos: [String: Int] = [:]) {
            self.shader = shader; textures = []; blending = "normal"; constants = [:]
            self.combos = combos; self.label = label
        }

        static func intCombos(_ v: Any?) -> [String: Int] {
            (v as? [String: Any] ?? [:]).compactMapValues { ($0 as? NSNumber)?.intValue }
        }

        /// Apply an effect instance's per-pass override (from scene.json).
        mutating func apply(override o: [String: Any], properties: UserProperties) {
            for (k, v) in Self.intCombos(o["combos"]) { combos[k] = v }
            for (k, v) in o["constantshadervalues"] as? [String: Any] ?? [:] { constants[k] = properties.resolve(v) }
            for (i, t) in (o["textures"] as? [Any] ?? []).enumerated() {
                guard let name = t as? String else { continue }
                while textures.count <= i { textures.append(nil) }
                textures[i] = name
            }
        }
    }

    /// An effect-local render target (`effect.json` → `fbos`).
    public struct EffectFBO {
        public let name: String
        public let scale: Float
        public let fit: Int?
        public let size: (width: Int, height: Int)?
        public let format: String
        public let clamp: Bool

        init(_ d: [String: Any]) {
            name = d["name"] as? String ?? ""
            scale = (d["scale"] as? NSNumber)?.floatValue ?? 1
            fit = (d["fit"] as? NSNumber)?.intValue
            if let w = (d["width"] as? NSNumber)?.intValue, let h = (d["height"] as? NSNumber)?.intValue {
                size = (w, h)
            } else {
                size = nil
            }
            format = d["format"] as? String ?? "rgba_backbuffer"
            clamp = (d["uvs"] as? String) != "repeat"
        }

        /// Pixel size for a layer of `layerSize`.
        public func pixelSize(layerSize: SIMD2<Float>) -> (Int, Int) {
            if let size { return size }
            var s = layerSize / max(scale, 0.0001)
            if let fit, max(s.x, s.y) > Float(fit) { s *= Float(fit) / max(s.x, s.y) }
            return (max(1, Int(s.x.rounded())), max(1, Int(s.y.rounded())))
        }
    }

    public struct ImageLayer {
        public let id: Int
        public let name: String
        public let origin: SIMD3<Float>
        public let scale: SIMD3<Float>
        public let angles: SIMD3<Float>
        public let size: SIMD2<Float>
        public let alpha: Float
        public let brightness: Float
        public let color: SIMD3<Float>
        public let colorBlendMode: Int
        /// `passthrough` models: the first pass draws the layer's screen-space quad (e.g. to sample the
        /// frame buffer behind it); `fullscreen` ones cover the whole canvas.
        public let passthrough: Bool
        public let fullscreen: Bool
        /// Ids of objects whose output this layer reads (rendered first).
        public let dependencies: [Int]
        /// Hidden layers still render (into their own composite FBO) but are not drawn into the scene.
        public let visible: Bool
        /// Material passes followed by effect passes, in render order.
        public let passes: [Pass]
        public let effectNames: [String]
        /// FBOs declared by each effect, indexed like `Pass.effect`.
        public let effectFBOs: [[EffectFBO]]
    }

    public let canvas: SIMD2<Float>
    public let clearColor: SIMD3<Float>
    public let hdr: Bool
    public let bloom: (enabled: Bool, strength: Float, threshold: Float)
    public let layers: [ImageLayer]
    public let properties: UserProperties
    /// Objects/effects skipped or approximated, for reporting.
    public let notes: [String]

    public init(project: URL, locator: AssetLocator, overrides: [String: String] = [:]) throws {
        let proj = try locator.json("project.json")
        // Some projects (e.g. effect previews) omit "type"; a .json entry file means a scene.
        let type = (proj["type"] as? String)?.lowercased()
        guard let file = proj["file"] as? String, type == "scene" || (type == nil && file.hasSuffix(".json")) else {
            throw WEFormatError.unsupported("not a scene wallpaper")
        }
        let props = UserProperties(project: proj, overrides: overrides)
        properties = props
        let scene = try locator.json(file)
        let general = scene["general"] as? [String: Any] ?? [:]
        func f(_ k: String, _ d: Float) -> Float { parseFloats(props.resolve(general[k]))?.first ?? d }
        let ortho = general["orthogonalprojection"] as? [String: Any]
        canvas = SIMD2(Float((ortho?["width"] as? NSNumber)?.floatValue ?? 1920),
                       Float((ortho?["height"] as? NSNumber)?.floatValue ?? 1080))
        let cc = parseFloats(props.resolve(general["clearcolor"])) ?? [0, 0, 0]
        clearColor = SIMD3(cc[0], cc[safe: 1] ?? cc[0], cc[safe: 2] ?? cc[0])
        hdr = props.bool(general["hdr"], default: false)
        // HDR scenes use the bloomhdr* parameters.
        bloom = (props.bool(general["bloom"], default: false),
                 hdr ? f("bloomhdrstrength", 2) : f("bloomstrength", 2),
                 hdr ? f("bloomhdrthreshold", 1) : f("bloomthreshold", 0.65))

        var layers: [ImageLayer] = []
        var notes: [String] = []
        for case let obj as [String: Any] in scene["objects"] as? [Any] ?? [] {
            let name = obj["name"] as? String ?? "?"
            // Hidden image layers are kept: other layers may read their composite FBO.
            let visible = props.bool(obj["visible"])
            guard let image = obj["image"] as? String else {
                let kind = ["particle", "sound", "text", "model", "light"].first { obj[$0] != nil } ?? "other"
                notes.append("\(name): \(kind) object not supported"); continue
            }
            let model = try locator.json(image)
            guard let matPath = model["material"] as? String else { notes.append("\(name): no material"); continue }
            let material = try locator.json(matPath)
            var passes = (material["passes"] as? [[String: Any]] ?? []).map { Pass(material: $0, label: "base") }

            var effectNames: [String] = []
            var effectFBOs: [[EffectFBO]] = []
            for case let eff as [String: Any] in obj["effects"] as? [Any] ?? [] {
                guard let file = eff["file"] as? String else { continue }
                let ename = (file as NSString).deletingLastPathComponent.components(separatedBy: "/").last ?? file
                guard props.bool(eff["visible"]) else { continue }
                do {
                    let def = try locator.json(file)
                    let effectIndex = effectNames.count
                    var overrides = (eff["passes"] as? [[String: Any]] ?? [])[...]
                    var effectPasses: [Pass] = []
                    for p in def["passes"] as? [[String: Any]] ?? [] {
                        guard let mp = p["material"] as? String else {
                            let command = p["command"] as? String
                            if command == "copy" || command == "swap", let src = p["source"] as? String,
                               let dst = p["target"] as? String {
                                var pass = Pass(copyFrom: src, to: dst, label: ename)
                                pass.effect = effectIndex
                                pass.swap = command == "swap"
                                effectPasses.append(pass)
                            } else {
                                notes.append("\(name): effect \(ename): unsupported command pass \(p["command"] ?? "?")")
                            }
                            continue
                        }
                        let o = overrides.popFirst() ?? [:]
                        var binds: [Int: String] = [:]
                        for case let b as [String: Any] in p["bind"] as? [Any] ?? [] {
                            if let n = b["name"] as? String, let i = (b["index"] as? NSNumber)?.intValue { binds[i] = n }
                        }
                        for mpass in (try locator.json(mp))["passes"] as? [[String: Any]] ?? [] {
                            var pass = Pass(material: mpass, label: ename)
                            pass.apply(override: o, properties: props)
                            pass.effect = effectIndex
                            pass.target = p["target"] as? String
                            pass.binds = binds
                            effectPasses.append(pass)
                        }
                    }
                    passes += effectPasses
                    effectNames.append(ename)
                    effectFBOs.append((def["fbos"] as? [[String: Any]] ?? []).map(EffectFBO.init))
                } catch {
                    notes.append("\(name): effect \(ename): \(error)")
                }
            }

            func v3(_ k: String, _ d: Float) -> SIMD3<Float> {
                let f = parseFloats(props.resolve(obj[k])) ?? [d, d, d]
                return SIMD3(f[0], f[safe: 1] ?? d, f[safe: 2] ?? d)
            }
            // Newer scenes put the size on the object; legacy ones on the model.
            let size = parseFloats(props.resolve(obj["size"])) ?? [
                (model["width"] as? NSNumber)?.floatValue ?? 0, (model["height"] as? NSNumber)?.floatValue ?? 0]
            let col = parseFloats(props.resolve(obj["color"])) ?? [1, 1, 1]
            let fullscreen = (model["fullscreen"] as? Bool) == true
            layers.append(ImageLayer(
                id: (obj["id"] as? NSNumber)?.intValue ?? -1, name: name,
                origin: fullscreen ? SIMD3(canvas.x / 2, canvas.y / 2, 0) : v3("origin", 0),
                scale: fullscreen ? SIMD3(1, 1, 1) : v3("scale", 1),
                angles: fullscreen ? SIMD3(0, 0, 0) : v3("angles", 0),
                size: fullscreen ? canvas : SIMD2(size[0], size[safe: 1] ?? size[0]),
                alpha: parseFloats(props.resolve(obj["alpha"]))?.first ?? 1,
                brightness: parseFloats(props.resolve(obj["brightness"]))?.first ?? 1,
                color: SIMD3(col[0], col[safe: 1] ?? 1, col[safe: 2] ?? 1),
                colorBlendMode: Int(parseFloats(props.resolve(obj["colorBlendMode"]))?.first ?? 0),
                passthrough: (model["passthrough"] as? Bool) == true, fullscreen: fullscreen,
                dependencies: (obj["dependencies"] as? [Any] ?? []).compactMap { ($0 as? NSNumber)?.intValue },
                visible: visible,
                passes: passes, effectNames: effectNames, effectFBOs: effectFBOs))
        }
        self.layers = layers
        self.notes = notes
    }
}

extension Array {
    subscript(safe i: Int) -> Element? { indices.contains(i) ? self[i] : nil }
}
