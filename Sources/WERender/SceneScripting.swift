import Foundation
import simd
import WEFormat
import WEScript

/// Live object state shared by scripts and rendering: transforms and visibility come from
/// `scene.nodes`, so a script that moves or hides a parent moves or hides its children too.
extension SceneRenderer {
    /// World transform of an object (its parents' transforms times its own).
    func worldTransform(_ id: Int, depth: Int = 0) -> simd_float4x4 {
        if let m = worldCache[id] { return m }
        guard let node = scene.nodes[id], depth < 64 else { return matrix_identity_float4x4 }
        let parent = node.parent.map { worldTransform($0, depth: depth + 1) } ?? matrix_identity_float4x4
        let m = parent * translation(node.origin) * rotationZ(node.angles.z) * scaling(node.scale)
        worldCache[id] = m
        return m
    }

    func parentTransform(_ id: Int) -> simd_float4x4 {
        scene.nodes[id]?.parent.map { worldTransform($0) } ?? matrix_identity_float4x4
    }

    /// Whether the object and all its ancestors are visible.
    func isVisible(_ id: Int) -> Bool {
        var current: Int? = id, depth = 0
        while let c = current, let node = scene.nodes[c], depth < 64 {
            if !node.visible { return false }
            current = node.parent; depth += 1
        }
        return true
    }

    /// Runs every SceneScript once per frame (created on the first frame).
    func runScripts(projection: simd_float4x4) {
        guard !scene.scripts.isEmpty else { return }
        worldCache = [:]
        if scriptEngine == nil { startScripts() }
        let mouse = projection.inverse * SIMD4(pointer.position.x * 2 - 1, 1 - pointer.position.y * 2, 0, 1)
        let dt = max(0, Double(time) - (lastScriptTime ?? Double(time)))
        lastScriptTime = Double(time)
        let world = SIMD3(Double(mouse.x), Double(mouse.y), 0)
        dispatchCursorEvents(world: SIMD2(mouse.x, mouse.y))
        scriptEngine?.update(frameTime: dt, runtime: Double(time), date: scriptClock ?? Date(), cursorWorld: world)
        worldCache = [:]
    }

    /// Visible layers under a scene point, topmost first (by their quads; full-screen composition layers
    /// are skipped, they would cover everything). Transparent layers count: wallpapers use alpha-0 shapes
    /// as hover areas.
    func layerIDs(at point: SIMD2<Float>) -> [Int] {
        var hits: [Int] = []
        for object in renderOrder.reversed() {
            guard case .image(let i) = object else { continue }
            let layer = scene.layers[i]
            guard !layer.fullscreen, !layer.passthrough, isVisible(layer.id) else { continue }
            let size = layerSizes[i]
            guard size.x > 0, size.y > 0 else { continue }
            let local = layerModel(i).inverse * SIMD4(point.x, point.y, 0, 1)
            if abs(local.x) <= size.x / 2, abs(local.y) <= size.y / 2 { hits.append(layer.id) }
        }
        return hits
    }

    /// Turns the polled pointer into SceneScript cursor events. Like WE, every layer under the cursor gets
    /// them, not only the topmost (a music player stacks a transparent hover shape, a highlight and the
    /// clickable title): down/up on button changes, click when released over a layer it went down on,
    /// move, and enter/leave as layers come under or leave the cursor.
    private func dispatchCursorEvents(world point: SIMD2<Float>) {
        guard let engine = scriptEngine else { return }
        let down = pointer.state.x > 0
        let hits = layerIDs(at: point)
        let world = SIMD3(Double(point.x), Double(point.y), 0)
        for id in cursor.hover where !hits.contains(id) { engine.cursorEvent(.leave, object: id, world: world) }
        for id in hits where !cursor.hover.contains(id) { engine.cursorEvent(.enter, object: id, world: world) }
        cursor.hover = hits
        if point != cursor.last { for id in hits { engine.cursorEvent(.move, object: id, world: world) } }
        cursor.last = point
        if down, !cursor.down {
            cursor.pressed = hits
            for id in hits { engine.cursorEvent(.down, object: id, world: world) }
        } else if !down, cursor.down {
            for id in hits { engine.cursorEvent(.up, object: id, world: world) }
            for id in hits where cursor.pressed.contains(id) { engine.cursorEvent(.click, object: id, world: world) }
            cursor.pressed = []
        }
        cursor.down = down
    }

    private func startScripts() {
        // CLI/app overrides arrive as strings: give scripts booleans and numbers.
        let users = scene.properties.values.mapValues { v -> Any in
            guard let s = v as? String else { return v }
            if s == "true" || s == "false" { return s == "true" }
            return Double(s) ?? s
        }
        let engine = SceneScriptEngine(host: self, userProperties: users,
                                       canvasSize: SIMD2(Double(scene.canvas.x), Double(scene.canvas.y)),
                                       storageURL: scriptStorageURL, fixedClock: scriptClock)
        scriptEngine = engine
        for (object, properties) in scene.scripts {
            for p in properties {
                let initial = value(object: object, property: p.path)
                    ?? Self.scriptValue(p.staticValue, vectors: p.path != "text") ?? .null
                engine.addScript(object: object, path: p.path, source: p.source, scriptProperties: p.scriptProperties,
                                 initialValue: initial)
            }
            if let i = layerIndexByID[object] { scriptedLayers.insert(i) }
        }
    }

    /// scene.json values: "x y z" strings become vectors (except where a string is meant, like text).
    static func scriptValue(_ v: Any?, vectors: Bool) -> ScriptValue? {
        switch v {
        case let b as Bool: return .bool(b)
        case let n as NSNumber: return .number(n.doubleValue)
        case let s as String:
            guard vectors, let f = parseFloats(s), f.count >= 2, f.count <= 4,
                  s.split(separator: " ").count == f.count else { return .string(s) }
            let d = f.map(Double.init)
            switch d.count {
            case 2: return .vec2(SIMD2(d[0], d[1]))
            case 3: return .vec3(SIMD3(d[0], d[1], d[2]))
            default: return .vec4(SIMD4(d[0], d[1], d[2], d[3]))
            }
        default: return nil
        }
    }

    var layerIndexByID: [Int: Int] {
        if let m = cachedLayerIndexByID { return m }
        let m = Dictionary(scene.layers.enumerated().map { ($1.id, $0) }, uniquingKeysWith: { a, _ in a })
        cachedLayerIndexByID = m
        return m
    }

    /// `effects[k]` and `effects[k].passes[j].constantshadervalues.<name>` paths.
    private static func parseEffectPath(_ path: String) -> (slot: Int, rest: String)? {
        guard path.hasPrefix("effects["), let close = path.firstIndex(of: "]"),
              let slot = Int(path[path.index(path.startIndex, offsetBy: 8)..<close]) else { return nil }
        var rest = String(path[path.index(after: close)...])
        if rest.hasPrefix(".") { rest.removeFirst() }
        return (slot, rest)
    }

    private static func parseConstantPath(_ rest: String) -> (pass: Int, name: String)? {
        guard rest.hasPrefix("passes["), let close = rest.firstIndex(of: "]"),
              let pass = Int(rest[rest.index(rest.startIndex, offsetBy: 7)..<close]) else { return nil }
        let prefix = ".constantshadervalues."
        let tail = rest[rest.index(after: close)...]
        guard tail.hasPrefix(prefix) else { return nil }
        return (pass, String(tail.dropFirst(prefix.count)))
    }

    static func floats(_ v: ScriptValue) -> [Float]? {
        switch v {
        case .number(let n): [Float(n)]
        case .bool(let b): [b ? 1 : 0]
        case .vec2(let v): [Float(v.x), Float(v.y)]
        case .vec3(let v): [Float(v.x), Float(v.y), Float(v.z)]
        case .vec4(let v): [Float(v.x), Float(v.y), Float(v.z), Float(v.w)]
        case .string(let s): parseFloats(s)
        case .null: nil
        }
    }

    static func vec3(_ v: ScriptValue) -> SIMD3<Float>? {
        guard let f = floats(v), !f.isEmpty else { return nil }
        return SIMD3(f[0], f[safe: 1] ?? f[0], f[safe: 2] ?? (f.count == 1 ? f[0] : 0))
    }

    func warnOnce(_ message: String) {
        if scriptWarnings.insert(message).inserted { warn(message) }
    }
}

extension SceneRenderer: SceneScriptHost {
    public func objectID(named name: String) -> Int? { scene.nodeOrder.first { scene.nodes[$0]?.name == name } }
    public func objectName(_ id: Int) -> String? { scene.nodes[id]?.name }
    public func parentID(of id: Int) -> Int? { scene.nodes[id]?.parent }
    public var objectIDs: [Int] { scene.nodeOrder }

    public func value(object id: Int, property: String) -> ScriptValue? {
        let layerIndex = layerIndexByID[id]
        let layer = layerIndex.map { scene.layers[$0] }
        func v3(_ v: SIMD3<Float>) -> ScriptValue { .vec3(SIMD3(Double(v.x), Double(v.y), Double(v.z))) }
        switch property {
        case "origin": return scene.nodes[id].map { v3($0.origin) }
        case "scale": return scene.nodes[id].map { v3($0.scale) }
        case "angles": return scene.nodes[id].map { v3($0.angles) }
        case "visible": return scene.nodes[id].map { .bool($0.visible) }
        case "alpha": return layer.map { .number(Double($0.alpha)) }
        case "brightness": return layer.map { .number(Double($0.brightness)) }
        case "color": return layer.map { v3($0.color) }
        case "size":
            guard let i = layerIndex else { return nil }
            let s = layerSizes[i]
            return .vec2(SIMD2(Double(s.x), Double(s.y)))
        case "text": return layerIndex.flatMap(currentText).map { .string($0) }
        case "pointsize": return layerIndex.flatMap(textObject).map { .number(Double($0.pointSize)) }
        case "volume":
            if let v = sound?.volume(id) { return .number(Double(v)) }
            return scene.sounds.first { $0.id == id }.map { .number(Double($0.volume)) }
        case "horizontalalign", "verticalalign":
            guard let t = layerIndex.flatMap(textObject) else { return nil }
            let names = property == "horizontalalign" ? ["left", "center", "right"] : ["top", "center", "bottom"]
            let a = property == "horizontalalign" ? t.horizontal : t.vertical
            return .string(names[a == .start ? 0 : a == .center ? 1 : 2])
        default: break
        }
        guard let i = layerIndex, let (slot, rest) = Self.parseEffectPath(property),
              let effect = scene.layers[i].effectSlots[slot] else { return nil }
        if rest == "visible" { return .bool(!(hiddenEffects[i] ?? scene.layers[i].hiddenEffects).contains(effect)) }
        // `effects[k].passes[j].constantshadervalues.<name>`, or `effects[k].<name>` (an effect script's
        // `thisObject`): the constant of that pass, or of the effect's first pass that has it.
        let constant = Self.parseConstantPath(rest) ?? (rest.contains(".") ? nil : (pass: -1, name: rest))
        guard let (pass, name) = constant,
              let p = layerPasses[i].first(where: { $0.effect == effect && (pass < 0 ? $0.constants[name] != nil : $0.overrideIndex == pass) }),
              let f = parseFloats(scene.properties.resolve(p.constants[name])) else { return nil }
        switch f.count {
        case 1: return .number(Double(f[0]))
        case 2: return .vec2(SIMD2(Double(f[0]), Double(f[1])))
        case 3: return .vec3(SIMD3(Double(f[0]), Double(f[1]), Double(f[2])))
        default: return .vec4(SIMD4(Double(f[0]), Double(f[1]), Double(f[2]), Double(f[safe: 3] ?? 1)))
        }
    }

    public func setValue(_ value: ScriptValue, object id: Int, property: String) {
        let layerIndex = layerIndexByID[id]
        switch property {
        case "origin", "scale", "angles":
            guard var node = scene.nodes[id], let v = Self.vec3(value) else { return }
            switch property {
            case "origin": node.origin = v
            case "scale": node.scale = v
            default: node.angles = v
            }
            scene.nodes[id] = node
            worldCache = [:]
            return
        case "visible":
            guard var node = scene.nodes[id] else { return }
            if case .bool(let b) = value { node.visible = b } else if let f = Self.floats(value)?.first { node.visible = f != 0 }
            scene.nodes[id] = node
            return
        case "alpha", "brightness":
            guard let i = layerIndex, let f = Self.floats(value)?.first else { return }
            if property == "alpha" { scene.layers[i].alpha = f } else { scene.layers[i].brightness = f }
            uniformsDirty.insert(i)
            return
        case "color":
            guard let i = layerIndex, let v = Self.vec3(value) else { return }
            scene.layers[i].color = v
            uniformsDirty.insert(i)
            return
        case "volume":
            if let f = Self.floats(value)?.first { sound?.setVolume(id, f) }
            return
        case "horizontalalign", "verticalalign", "maxwidth", "pointsize", "padding":
            guard let i = layerIndex, var t = textObject(i) else { return }
            let f = Self.floats(value)?.first
            switch (property, value) {
            case ("horizontalalign", .string(let a)): t.horizontal = TextObject.align(a, start: "left", end: "right")
            case ("verticalalign", .string(let a)): t.vertical = TextObject.align(a, start: "top", end: "bottom")
            case ("maxwidth", _): if t.maxWidth != nil, let f { t.maxWidth = f }
            case ("pointsize", _): if let f { t.pointSize = f }
            case ("padding", _): if let f { t.padding = f }
            default: return
            }
            setTextObject(t, layer: i)
            return
        case "text":
            guard let i = layerIndex else { return }
            switch value {
            case .string(let s): textOverrides[i] = s
            case .number(let n): textOverrides[i] = n == n.rounded() && abs(n) < 1e15 ? String(Int(n)) : String(n)
            case .bool(let b): textOverrides[i] = String(b)
            default: textOverrides[i] = ""
            }
            return
        default: break
        }
        if property.hasPrefix("instanceoverride.") {
            warnOnce("SceneScript: particle instance overrides from scripts are not supported yet"); return
        }
        if let i = layerIndex, let (slot, rest) = Self.parseEffectPath(property) {
            // Effects hidden in scene.json (and not script-controlled) were never loaded: nothing to change.
            guard let effect = scene.layers[i].effectSlots[slot] else { return }
            if rest == "visible" {
                var hidden = hiddenEffects[i] ?? scene.layers[i].hiddenEffects
                let shown: Bool
                if case .bool(let b) = value { shown = b } else { shown = (Self.floats(value)?.first ?? 1) != 0 }
                if shown { hidden.remove(effect) } else { hidden.insert(effect) }
                hiddenEffects[i] = hidden
                return
            }
            if let (pass, name) = Self.parseConstantPath(rest) ?? (rest.contains(".") ? nil : (pass: -1, name: rest)) {
                let stored: Any = Self.floats(value).map { $0.count == 1 ? NSNumber(value: $0[0]) as Any : $0.map { "\($0)" }.joined(separator: " ") } ?? 0
                for j in layerPasses[i].indices where layerPasses[i][j].effect == effect && (pass < 0 || layerPasses[i][j].overrideIndex == pass) {
                    layerPasses[i][j].constants[name] = stored
                }
                uniformsDirty.insert(i)
                return
            }
        }
        warnOnce("SceneScript: setting \(property) is not supported yet")
    }

    public func transformMatrix(object id: Int) -> simd_double4x4 {
        let m = worldTransform(id)
        return simd_double4x4(columns: (SIMD4<Double>(m.columns.0), SIMD4<Double>(m.columns.1),
                                        SIMD4<Double>(m.columns.2), SIMD4<Double>(m.columns.3)))
    }
    /// Texture animations are not driven by scripts yet: a single-frame stand-in keeps scripts that
    /// call `getAnimation().stop()` and similar working.
    public func animation(object: Int) -> ScriptAnimationHost? {
        if let a = scriptAnimations[object] { return a }
        let a = StillAnimation()
        scriptAnimations[object] = a
        return a
    }
    public func log(_ level: ScriptLogLevel, _ message: String) {
        if level != .log { warnOnce("SceneScript \(level.rawValue): \(message)") }
    }
    public func soundCommand(object id: Int, _ command: String) -> Bool {
        guard let sound else { return false }
        switch command {
        case "play": sound.play(id)
        case "stop": sound.stop(id)
        case "pause": sound.pause(id)
        case "isPlaying": return sound.isPlaying(id)
        default: break
        }
        return false
    }
    public func sortLayer(object: Int, index: Int) { warnOnce("SceneScript: thisScene.sortLayer is not supported yet") }
    public func effectIndex(object id: Int, named name: String) -> Int? {
        guard let i = layerIndexByID[id], let e = scene.layers[i].effectNames.firstIndex(of: name) else { return nil }
        return scene.layers[i].effectSlots.first { $0.value == e }?.key
    }
    public func sceneValue(_ property: String) -> ScriptValue? {
        switch property {
        case "clearColor":
            let c = scene.clearColor
            return .vec3(SIMD3(Double(c.x), Double(c.y), Double(c.z)))
        default: return nil
        }
    }
    public func setSceneValue(_ value: ScriptValue, property: String) {
        warnOnce("SceneScript: setting scene \(property) is not supported yet")
    }
}

final class StillAnimation: ScriptAnimationHost {
    func play() {}
    func pause() {}
    func stop() {}
    var isPlaying: Bool { false }
    var frame: Double = 0
    var frameCount: Double { 1 }
    var rate: Double = 1
}
