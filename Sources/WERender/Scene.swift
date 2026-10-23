import Foundation
import simd
import WEFormat
import WEScript

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

/// An object in scene file order; indices refer to the corresponding scene arrays.
public enum SceneObject: Equatable {
    case image(Int), particle(Int)
}

/// Image layers, particle systems and scene camera settings.
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
        /// Combo requirements (`conditions`): the pass is skipped unless all match.
        public var conditions: [[String: Int]] = []
        /// Per-slot bind requirements; a bind whose conditions fail is not applied.
        public var bindConditions: [Int: [[String: Int]]] = [:]
        /// Combos set anywhere in the same effect instance (conditions are evaluated against them).
        public var effectCombos: [String: Int] = [:]
        /// `{"command": "copy"}` pass: copy one FBO into another, no shader.
        public var copy: (source: String, target: String)?
        /// `{"command": "swap"}`: exchange two FBOs (ping-pong simulations); uses `copy` for the names.
        public var swap = false
        /// Effect passes: index of the scene.json pass override (`effects[k].passes[j]`) this pass came from.
        public var overrideIndex: Int?

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
        public let clearColor: SIMD4<Float>
        public let conditions: [[String: Int]]
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
            let c = parseFloats(d["clear"]) ?? [0, 0, 0, 0]
            clearColor = SIMD4(c[safe: 0] ?? 0, c[safe: 1] ?? 0, c[safe: 2] ?? 0, c[safe: 3] ?? 0)
            conditions = SceneDescription.parseConditions(d["conditions"])
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
        public internal(set) var alpha: Float
        public internal(set) var brightness: Float
        public internal(set) var color: SIMD3<Float>
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
        /// How far the layer moves with camera parallax (added to the scene's `amount`).
        public let parallaxDepth: SIMD2<Float>
        /// Text objects: the layer's base texture is the rendered text (`textTextureName`).
        public let text: TextObject?
        /// scene.json effect index (`effects[k]`) → index into `effectNames`.
        public let effectSlots: [Int: Int]
        /// Effects kept only because a script controls their visibility, hidden at load.
        public let hiddenEffects: Set<Int>
    }

    /// Any scene object's place in the hierarchy and its transform, which scripts may change.
    public struct SceneNode {
        public let name: String
        public let parent: Int?
        public internal(set) var origin: SIMD3<Float>
        public internal(set) var scale: SIMD3<Float>
        public internal(set) var angles: SIMD3<Float>
        /// The object's own visibility; it is shown only if its ancestors are visible too.
        public internal(set) var visible: Bool
    }

    /// Base texture name of a text layer, provided by the renderer.
    static func textTextureName(id: Int) -> String { "$text:\(id)" }

    /// Camera parallax: layers follow the cursor (`general.cameraparallax*`).
    public struct Parallax {
        public let enabled: Bool
        public let amount: Float
        public let delay: Float
        public let mouseInfluence: Float
    }

    public let canvas: SIMD2<Float>
    public let clearColor: SIMD3<Float>
    public let hdr: Bool
    public let bloom: (enabled: Bool, strength: Float, threshold: Float)
    public let parallax: Parallax
    let particleCamera: (fov: Float, near: Float, far: Float)
    public internal(set) var layers: [ImageLayer]
    /// Every object with an id, and the ids in scene.json order.
    public internal(set) var nodes: [Int: SceneNode]
    public let nodeOrder: [Int]
    /// SceneScript-driven properties per object id.
    public let scripts: [(object: Int, properties: [ScriptedProperty])]
    public let particles: [ParticleSystemDescription]
    public let sounds: [SoundObject]
    public let drawOrder: [SceneObject]
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
        particleCamera = (f("fov", 50), f("nearz", 0.01), f("farz", 10000))
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
        parallax = Parallax(enabled: props.bool(general["cameraparallax"], default: false),
                            amount: f("cameraparallaxamount", 0.5), delay: f("cameraparallaxdelay", 0.1),
                            mouseInfluence: f("cameraparallaxmouseinfluence", 0))

        var layers: [ImageLayer] = []
        var particles: [ParticleSystemDescription] = []
        var sounds: [SoundObject] = []
        var drawOrder: [SceneObject] = []
        var notes: [String] = []
        // WE leaves out values equal to their default. A missing origin is the canvas centre for top-level
        // objects (e.g. a full-canvas image) and the parent's origin for children.
        let center = "\(canvas.x / 2) \(canvas.y / 2) 0"
        let objects = (scene["objects"] as? [Any] ?? []).compactMap { $0 as? [String: Any] }.map { o in
            guard o["origin"] == nil, o["parent"] == nil else { return o }
            var o = o
            o["origin"] = center
            return o
        }
        let hierarchy = ObjectHierarchy(objects, properties: props)
        var nodes: [Int: SceneNode] = [:], nodeOrder: [Int] = []
        var scripts: [(object: Int, properties: [ScriptedProperty])] = []
        for o in objects {
            guard let id = (o["id"] as? NSNumber)?.intValue, nodes[id] == nil else { continue }
            func v3(_ k: String, _ d: Float) -> SIMD3<Float> {
                let f = parseFloats(props.resolve(o[k])) ?? [d, d, d]
                return SIMD3(f[0], f[safe: 1] ?? d, f[safe: 2] ?? d)
            }
            nodes[id] = SceneNode(name: o["name"] as? String ?? "", parent: (o["parent"] as? NSNumber)?.intValue,
                                  origin: v3("origin", 0), scale: v3("scale", 1), angles: v3("angles", 0),
                                  visible: props.bool(o["visible"]))
            nodeOrder.append(id)
            let scripted = ScriptedProperty.discover(in: o)
            if !scripted.isEmpty { scripts.append((id, scripted)) }
        }
        self.nodes = nodes
        self.nodeOrder = nodeOrder
        self.scripts = scripts
        for obj in objects {
            let name = obj["name"] as? String ?? "?"
            let parent = hierarchy.parent(of: obj)
            // Hidden image layers are kept: other layers may read their composite FBO.
            let visible = props.bool(obj["visible"]) && parent.visible
            if obj["particle"] != nil {
                do {
                    let particle = try ParticleSystemDescription(object: obj, locator: locator, properties: props,
                                                                 parent: parent.transform, parentVisible: parent.visible)
                    func append(_ p: ParticleSystemDescription) {
                        drawOrder.append(.particle(particles.count))
                        particles.append(p)
                        notes += p.notes
                        p.children.forEach(append)
                    }
                    append(particle)
                } catch { notes.append("\(name): particle asset: \(error)") }
                continue
            }
            var model: [String: Any] = [:]
            var passes: [Pass]
            var text: TextObject?
            if let image = obj["image"] as? String {
                model = try locator.json(image)
                guard let matPath = model["material"] as? String else { notes.append("\(name): no material"); continue }
                let material = try locator.json(matPath)
                passes = (material["passes"] as? [[String: Any]] ?? []).map { Pass(material: $0, label: "base") }
            } else if obj["text"] != nil {
                // WE draws glyph coverage with the `font` shader (g_Color4 = colour, alpha) into the text box.
                let t = TextObject(object: obj, properties: props)
                let mp = ((try? locator.json("materials/fonts/basefont.json"))?["passes"] as? [[String: Any]])?.first
                var pass = Pass(material: mp ?? ["shader": "font", "blending": "translucent"], label: "text")
                pass.textures = [Self.textTextureName(id: (obj["id"] as? NSNumber)?.intValue ?? -1)]
                passes = [pass]
                text = t
                if props.bool(obj["opaquebackground"], default: false) { notes.append("\(name): text background not supported") }
            } else if obj["sound"] != nil {
                if let sound = SoundObject(object: obj, properties: props) { sounds.append(sound) }
                else { notes.append("\(name): sound object without files") }
                continue
            } else {
                let kind = ["model", "light"].first { obj[$0] != nil } ?? "other"
                if kind != "other" || obj["origin"] == nil { notes.append("\(name): \(kind) object not supported") }
                continue
            }

            var effectNames: [String] = []
            var effectFBOs: [[EffectFBO]] = []
            var effectSlots: [Int: Int] = [:], hiddenEffects = Set<Int>()
            for (slot, eff) in (obj["effects"] as? [Any] ?? []).enumerated() {
                guard let eff = eff as? [String: Any], let file = eff["file"] as? String else { continue }
                let ename = (file as NSString).deletingLastPathComponent.components(separatedBy: "/").last ?? file
                let shown = props.bool(eff["visible"])
                // Hidden effects are dropped unless a script may show them.
                guard shown || (eff["visible"] as? [String: Any])?["script"] != nil else { continue }
                do {
                    let def = try locator.json(file)
                    let effectIndex = effectNames.count
                    var overrides = (eff["passes"] as? [[String: Any]] ?? [])[...]
                    var overrideIndex = 0
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
                        defer { overrideIndex += 1 }
                        var binds: [Int: String] = [:]
                        var bindConditions: [Int: [[String: Int]]] = [:]
                        for case let b as [String: Any] in p["bind"] as? [Any] ?? [] {
                            if let n = b["name"] as? String, let i = (b["index"] as? NSNumber)?.intValue {
                                binds[i] = n
                                let c = Self.parseConditions(b["conditions"])
                                if !c.isEmpty { bindConditions[i] = c }
                            }
                        }
                        for mpass in (try locator.json(mp))["passes"] as? [[String: Any]] ?? [] {
                            var pass = Pass(material: mpass, label: ename)
                            pass.apply(override: o, properties: props)
                            pass.effect = effectIndex
                            pass.overrideIndex = overrideIndex
                            pass.target = p["target"] as? String
                            pass.binds = binds
                            pass.bindConditions = bindConditions
                            pass.conditions = Self.parseConditions(p["conditions"])
                            effectPasses.append(pass)
                        }
                    }
                    let effectCombos = effectPasses.reduce(into: [String: Int]()) { acc, p in
                        for (k, v) in p.combos { acc[k.uppercased()] = v }
                    }
                    for i in effectPasses.indices { effectPasses[i].effectCombos = effectCombos }
                    passes += effectPasses
                    effectSlots[slot] = effectIndex
                    if !shown { hiddenEffects.insert(effectIndex) }
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
            let depth = parseFloats(props.resolve(obj["parallaxDepth"])) ?? [0, 0]
            drawOrder.append(.image(layers.count))
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
                passes: passes, effectNames: effectNames, effectFBOs: effectFBOs,
                parallaxDepth: SIMD2(depth[0], depth[safe: 1] ?? depth[0]),
                text: text,
                effectSlots: effectSlots, hiddenEffects: hiddenEffects))
        }
        self.layers = layers
        self.particles = particles
        self.sounds = sounds
        self.drawOrder = drawOrder
        self.notes = notes
    }
}

/// Scene object parenting (`"parent": <object id>`): children are placed in their parent's space and hidden
/// with it. Any object kind can be a parent, including plain group objects that only have a transform.
struct ObjectHierarchy {
    private var byID: [Int: [String: Any]] = [:]
    private let properties: UserProperties
    private var cache: [Int: (transform: simd_float4x4, visible: Bool)] = [:]

    init(_ objects: [[String: Any]], properties: UserProperties) {
        self.properties = properties
        for o in objects { if let id = (o["id"] as? NSNumber)?.intValue { byID[id] = o } }
        for id in byID.keys { _ = world(id, depth: 0) }
    }

    /// World transform and effective visibility of the object's parent chain.
    func parent(of object: [String: Any]) -> (transform: simd_float4x4, visible: Bool) {
        guard let id = (object["parent"] as? NSNumber)?.intValue, let w = cache[id] else {
            return (matrix_identity_float4x4, true)
        }
        return w
    }

    private mutating func world(_ id: Int, depth: Int) -> (transform: simd_float4x4, visible: Bool) {
        if let w = cache[id] { return w }
        guard let o = byID[id], depth < 64 else { return (matrix_identity_float4x4, true) }
        var up = (transform: matrix_identity_float4x4, visible: true)
        if let p = (o["parent"] as? NSNumber)?.intValue, p != id { up = world(p, depth: depth + 1) }
        func v3(_ k: String, _ d: Float) -> SIMD3<Float> {
            let f = parseFloats(properties.resolve(o[k])) ?? [d, d, d]
            return SIMD3(f[0], f[safe: 1] ?? d, f[safe: 2] ?? d)
        }
        let local = translation(v3("origin", 0)) * rotationZ(v3("angles", 0).z) * scaling(v3("scale", 1))
        let w = (up.transform * local, up.visible && properties.bool(o["visible"]))
        cache[id] = w
        return w
    }
}

extension SceneDescription {
    /// File order, with image dependencies visited before their consumers.
    func orderedObjects() -> [SceneObject] {
        var order: [SceneObject] = [], done = Set<Int>(), visiting = Set<Int>()
        let byID = Dictionary(layers.enumerated().map { ($1.id, $0) }, uniquingKeysWith: { a, _ in a })
        func visit(_ i: Int) {
            guard !done.contains(i), visiting.insert(i).inserted else { return }
            for dep in layers[i].dependencies { if let j = byID[dep] { visit(j) } }
            done.insert(i)
            order.append(.image(i))
        }
        for object in drawOrder {
            switch object {
            case .image(let i): visit(i)
            case .particle: order.append(object)
            }
        }
        return order
    }

    /// `"conditions": [{"LIGHTING": 1}, ...]` → combo requirements (all must hold).
    static func parseConditions(_ v: Any?) -> [[String: Int]] {
        (v as? [Any] ?? []).compactMap { c in
            (c as? [String: Any])?.reduce(into: [String: Int]()) { acc, kv in
                if let n = (kv.value as? NSNumber)?.intValue { acc[kv.key.uppercased()] = n }
            }
        }
    }

    /// Whether every condition matches `combos` (missing combos count as 0).
    public static func conditionsHold(_ conditions: [[String: Int]], combos: [String: Int]) -> Bool {
        conditions.allSatisfy { c in c.allSatisfy { (combos[$0.key] ?? 0) == $0.value } }
    }
}

extension Array {
    subscript(safe i: Int) -> Element? { indices.contains(i) ? self[i] : nil }
}
