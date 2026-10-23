// Particle defaults and parsing ported from linux-wallpaperengine ObjectParser.cpp / CParticle.cpp.
import Foundation
import simd
import WEFormat

struct ParticleValues {
    let data: [String: Any]
    let properties: UserProperties
    init(_ data: [String: Any], _ properties: UserProperties) { self.data = data; self.properties = properties }
    func floats(_ key: String) -> [Float]? {
        let value = properties.resolve(data[key])
        return (value as? [NSNumber])?.map(\.floatValue) ?? parseFloats(value)
    }
    func f(_ key: String, _ fallback: Float) -> Float { floats(key)?.first ?? fallback }
    func v(_ key: String, _ fallback: SIMD3<Float>) -> SIMD3<Float> {
        guard let a = floats(key), let x = a.first else { return fallback }
        return a.count == 1 ? SIMD3(repeating: x) : SIMD3(x, a[safe: 1] ?? fallback.y, a[safe: 2] ?? fallback.z)
    }
    func color(_ key: String, _ fallback: SIMD3<Float>) -> SIMD3<Float> {
        let c = v(key, fallback)
        if let s = properties.resolve(data[key]) as? String, !s.contains("."), !s.contains("e") { return c / 255 }
        return c
    }
    func b(_ key: String, _ fallback: Bool = true) -> Bool { properties.bool(data[key], default: fallback) }
}

struct ParticleOverrides {
    var count: Float = 1, rate: Float = 1, size: Float = 1, lifetime: Float = 1, speed: Float = 1, alpha: Float = 1
    var color: SIMD3<Float>?
    var colorn = SIMD3<Float>(repeating: 1)
    init(_ v: ParticleValues) {
        guard v.b("enabled") else { return }
        count = max(0, v.f("count", 1)); rate = max(0, v.f("rate", 1))
        size = v.f("size", 1); lifetime = v.f("lifetime", 1); speed = v.f("speed", 1); alpha = v.f("alpha", 1)
        colorn = v.v("colorn", .one)
        if v.data["color"] != nil { color = v.v("color", .one) }
    }
}

struct ParticleControlPoint {
    var id: Int
    var flags: Int
    var offset: SIMD3<Float>
}

struct ParticleEmitter {
    enum Kind: String { case boxrandom, sphererandom }
    let kind: Kind
    let directions, distanceMin, distanceMax, origin, sign: SIMD3<Float>
    let instantaneous, controlPoint, flags: Int
    let speedMin, speedMax, rate, delay, duration: Float
    let periodicDelay, periodicDuration: SIMD2<Float>
    init(_ kind: Kind, _ v: ParticleValues) {
        self.kind = kind
        directions = v.v("directions", [1, 1, 0]); distanceMin = v.v("distancemin", .zero)
        distanceMax = v.v("distancemax", [256, 256, 0]); origin = v.v("origin", .zero); sign = v.v("sign", .zero)
        instantaneous = max(0, Int(v.f("instantaneous", 0))); controlPoint = Int(v.f("controlpoint", 0))
        flags = Int(v.f("flags", 0)); speedMin = v.f("speedmin", 0); speedMax = v.f("speedmax", 0)
        rate = max(0, v.f("rate", 10)); delay = max(0, v.f("delay", 0)); duration = v.f("duration", 0)
        periodicDelay = [v.f("minperiodicdelay", 1), v.f("maxperiodicdelay", 2)]
        periodicDuration = [v.f("minperiodicduration", 2), v.f("maxperiodicduration", 3)]
    }
}

struct ParticleTurbulence {
    let speed, phase: SIMD2<Float>
    let scale, timeScale, offset: Float
    let mask, forward, right: SIMD3<Float>
    init(_ v: ParticleValues, initializer: Bool = false) {
        speed = [v.f("speedmin", initializer ? 100 : 500), v.f("speedmax", initializer ? 250 : 1000)]
        phase = [v.f("phasemin", 0), v.f("phasemax", initializer ? 0.1 : 0)]
        scale = v.f("scale", initializer ? 1 : 0.005); timeScale = v.f("timescale", initializer ? 1 : 0.01)
        offset = v.f("offset", 0); mask = v.v("mask", [1, 1, 0])
        forward = v.v("forward", [0, 1, 0]); right = v.v("right", [0, 0, 1])
    }
}

struct ParticleInitializer {
    enum Kind: String {
        case lifetimerandom, sizerandom, colorrandom, velocityrandom, rotationrandom, alpharandom
        case turbulentvelocityrandom, angularvelocityrandom
    }
    let kind: Kind
    let min, max: SIMD3<Float>
    let exponent: Float
    let turbulence: ParticleTurbulence?
    init(_ kind: Kind, _ v: ParticleValues) {
        self.kind = kind
        let lo: SIMD3<Float>, hi: SIMD3<Float>
        switch kind {
        case .lifetimerandom: lo = .zero; hi = .one
        case .sizerandom: lo = .zero; hi = SIMD3(repeating: 20)
        case .colorrandom: lo = .zero; hi = .one
        case .velocityrandom: lo = SIMD3(repeating: -32); hi = SIMD3(repeating: 32)
        case .rotationrandom: lo = .zero; hi = [0, 0, 2 * .pi]
        case .alpharandom: lo = SIMD3(repeating: 0.05); hi = .one
        case .angularvelocityrandom: lo = [0, 0, -5]; hi = [0, 0, 5]
        case .turbulentvelocityrandom: lo = .zero; hi = .zero
        }
        min = kind == .colorrandom ? v.color("min", lo) : v.v("min", lo)
        max = kind == .colorrandom ? v.color("max", hi) : v.v("max", hi)
        exponent = v.f("exponent", 1)
        turbulence = kind == .turbulentvelocityrandom ? ParticleTurbulence(v, initializer: true) : nil
    }
}

struct ParticleOscillator {
    let frequency, scale, phase: SIMD2<Float>
    let mask: SIMD3<Float>
    init(_ v: ParticleValues, kind: String) {
        frequency = [v.f("frequencymin", 0), v.f("frequencymax", kind == "oscillateposition" ? 5 : 10)]
        scale = [v.f("scalemin", kind == "oscillatesize" ? 0.8 : 0),
                 v.f("scalemax", kind == "oscillatesize" ? 1.2 : kind == "oscillateposition" ? 10 : 1)]
        phase = [v.f("phasemin", 0), v.f("phasemax", 2 * .pi)]
        mask = v.v("mask", [1, 1, 0])
    }
}

struct ParticleVortex {
    let controlPoint, flags: Int
    let axis, offset: SIMD3<Float>
    let inner, outer, speedInner, speedOuter, centerForce, ringRadius, ringWidth, pullDistance, pullForce: Float
    init(_ v: ParticleValues) {
        controlPoint = Int(v.f("controlpoint", 0)); flags = Int(v.f("flags", 0))
        axis = v.v("axis", [0, 0, 1]); offset = v.v("offset", .zero)
        inner = v.f("distanceinner", 500); outer = v.f("distanceouter", 650)
        speedInner = v.f("speedinner", 2500); speedOuter = v.f("speedouter", 0); centerForce = v.f("centerforce", 1)
        ringRadius = v.f("ringradius", 300); ringWidth = v.f("ringwidth", 50)
        pullDistance = v.f("ringpulldistance", 50); pullForce = v.f("ringpullforce", 10)
    }
}

enum ParticleOperator {
    case movement(drag: Float, gravity: SIMD3<Float>)
    case angularMovement(drag: Float, force: SIMD3<Float>)
    case alphaFade(fadeIn: Float, fadeOut: Float)
    case sizeChange(start: Float, end: Float, from: Float, to: Float)
    case alphaChange(start: Float, end: Float, from: Float, to: Float)
    case colorChange(start: Float, end: Float, from: SIMD3<Float>, to: SIMD3<Float>)
    case attract(controlPoint: Int, origin: SIMD3<Float>, scale: Float, radius: Float)
    case oscillateAlpha(ParticleOscillator), oscillateSize(ParticleOscillator), oscillatePosition(ParticleOscillator)
    case turbulence(ParticleTurbulence), vortex(ParticleVortex)

    init?(_ name: String, _ v: ParticleValues) {
        switch name {
        case "movement": self = .movement(drag: v.f("drag", 0), gravity: v.v("gravity", .zero))
        case "angularmovement": self = .angularMovement(drag: v.f("drag", 0), force: v.v("force", .zero))
        case "alphafade": self = .alphaFade(fadeIn: v.f("fadeintime", 0.5), fadeOut: v.f("fadeouttime", 0.5))
        case "sizechange": self = .sizeChange(start: v.f("starttime", 0), end: v.f("endtime", 1), from: v.f("startvalue", 1), to: v.f("endvalue", 0))
        case "alphachange": self = .alphaChange(start: v.f("starttime", 0), end: v.f("endtime", 1), from: v.f("startvalue", 1), to: v.f("endvalue", 0))
        case "colorchange": self = .colorChange(start: v.f("starttime", 0), end: v.f("endtime", 1), from: v.v("startvalue", .one), to: v.v("endvalue", .one))
        case "controlpointattract": self = .attract(controlPoint: Int(v.f("controlpoint", 0)), origin: v.v("origin", .zero), scale: v.f("scale", 100), radius: v.f("threshold", 1000) / 2)
        case "oscillatealpha": self = .oscillateAlpha(ParticleOscillator(v, kind: name))
        case "oscillatesize": self = .oscillateSize(ParticleOscillator(v, kind: name))
        case "oscillateposition": self = .oscillatePosition(ParticleOscillator(v, kind: name))
        case "turbulence": self = .turbulence(ParticleTurbulence(v))
        case "vortex", "vortex_v2": self = .vortex(ParticleVortex(v))
        default: return nil
        }
    }
}

struct ParticleRenderStyle {
    let trail: Bool
    let rope: Bool
    let segments, subdivision: Int
    let uvScale: Float
    let uvScrolling, uvSmoothing, fadeAlpha, fadeSize: Bool
    let length, maxLength, minLength: Float
    init(_ v: ParticleValues) {
        trail = (v.data["name"] as? String) == "spritetrail"
        rope = (v.data["name"] as? String) == "ropetrail"
        segments = max(2, Int(v.f("segments", 4)))
        subdivision = max(1, Int(v.f("subdivision", 1)))
        uvScale = max(0.0001, v.f("uvscale", 1))
        uvScrolling = v.b("uvscrolling", false); uvSmoothing = v.b("uvsmoothing")
        fadeAlpha = v.b("fadealpha", false); fadeSize = v.b("fadesize", false)
        length = max(0.0001, v.f("length", rope ? 1 : 0.05)); maxLength = v.f("maxlength", 10); minLength = v.f("minlength", 0)
    }
}

/// A particle object and its static or event children, with resolved user properties and material passes.
public struct ParticleSystemDescription {
    public let id: Int
    public let name: String
    public let visible: Bool
    public let origin, angles, scale: SIMD3<Float>
    public let parallaxDepth: SIMD2<Float>
    public let maxCount: Int
    public let startTime: Float
    public let animationMode: String
    public let sequenceMultiplier: Float
    public let passes: [SceneDescription.Pass]
    public let children: [ParticleSystemDescription]
    /// Unsupported particle features, also reported by the compatibility checker.
    public let notes: [String]
    /// Whether this system has a supported renderer and material.
    public var canRender: Bool { !renderers.isEmpty && !passes.isEmpty }
    enum ChildType: String { case `static`, eventfollow, eventspawn, eventdeath }
    let childType: ChildType
    let eventMaxCount: Int
    let probability: Float
    let ownOverrideNames: Set<String>
    let baseMaxCount: Int
    let flags: Int
    let seed: UInt64
    let parentTransform: simd_float4x4
    let overrides: ParticleOverrides
    let emitters: [ParticleEmitter]
    let initializers: [ParticleInitializer]
    let operators: [ParticleOperator]
    let renderers: [ParticleRenderStyle]
    let controlPoints: [ParticleControlPoint]

    /// Load a path or inline `particle` definition from a scene object.
    /// `parent` is the world transform of the object's scene parent; `parentVisible` whether every ancestor is visible.
    public init(object: [String: Any], locator: AssetLocator, properties: UserProperties,
                parent: simd_float4x4 = matrix_identity_float4x4, parentVisible: Bool = true) throws {
        var childIndex = 0
        var object = object
        if !parentVisible { object["visible"] = false }
        try self.init(object: object, locator: locator, properties: properties, ancestors: [],
                      parent: parent, inheritedPoints: [], childIndex: &childIndex)
    }

    private init(object: [String: Any], locator: AssetLocator, properties: UserProperties, ancestors: Set<String>,
                 parent: simd_float4x4, inheritedPoints: [ParticleControlPoint], childIndex: inout Int) throws {
        let obj = ParticleValues(object, properties)
        let name = object["name"] as? String ?? "?"
        self.name = name
        childType = ChildType(rawValue: object["type"] as? String ?? "static") ?? .static
        eventMaxCount = max(0, Int(obj.f("maxcount", 20)))
        probability = max(0, min(1, obj.f("probability", 1)))
        ownOverrideNames = Set(object["_ownOverrideNames"] as? [String] ?? [])
        id = Int(obj.f("id", -1)); visible = obj.b("visible")
        origin = obj.v("origin", .zero); angles = obj.v("angles", .zero); scale = obj.v("scale", .one)
        let depth = obj.v("parallaxDepth", .zero); parallaxDepth = [depth.x, depth.y]
        parentTransform = parent
        seed = UInt64(bitPattern: Int64(id)) &* 0x9E3779B97F4A7C15 &+ UInt64(childIndex)
        childIndex += 1
        let definition: [String: Any]
        var ancestors = ancestors
        if let path = object["particle"] as? String {
            guard ancestors.insert(path).inserted else { throw WEFormatError.corrupt("cyclic particle child: \(path)") }
            definition = try locator.json(path)
        } else if let inline = object["particle"] as? [String: Any] {
            definition = inline
        } else { throw WEFormatError.corrupt("\(name): invalid particle definition") }
        let v = ParticleValues(definition, properties)
        let ov = ParticleValues(object["instanceoverride"] as? [String: Any] ?? [:], properties)
        overrides = ParticleOverrides(ov)
        baseMaxCount = max(0, Int(v.f("maxcount", 100)))
        maxCount = max(0, Int(Float(baseMaxCount) * overrides.count))
        startTime = max(0, v.f("starttime", 0)); flags = Int(v.f("flags", 0))
        animationMode = definition["animationmode"] as? String ?? "sequence"
        sequenceMultiplier = v.f("sequencemultiplier", 1)
        var notes: [String] = []
        func unsupported(_ kind: String, _ value: String) { notes.append("\(name): particle \(kind) \(value) not supported") }
        emitters = (definition["emitter"] as? [[String: Any]] ?? []).compactMap { d in
            let n = d["name"] as? String ?? "?"
            guard let kind = ParticleEmitter.Kind(rawValue: n) else { unsupported("emitter", n); return nil }
            return ParticleEmitter(kind, ParticleValues(d, properties))
        }
        initializers = (definition["initializer"] as? [[String: Any]] ?? []).compactMap { d in
            let n = d["name"] as? String ?? "?"
            guard let kind = ParticleInitializer.Kind(rawValue: n) else { unsupported("initializer", n); return nil }
            return ParticleInitializer(kind, ParticleValues(d, properties))
        }
        operators = (definition["operator"] as? [[String: Any]] ?? []).compactMap { d in
            let n = d["name"] as? String ?? "?"
            guard let op = ParticleOperator(n, ParticleValues(d, properties)) else { unsupported("operator", n); return nil }
            return op
        }
        let styles = definition["renderer"] as? [[String: Any]] ?? []
        renderers = (styles.isEmpty ? [["name": "sprite"]] : styles).compactMap { d in
            let n = d["name"] as? String ?? "sprite"
            guard n == "sprite" || n == "spritetrail" || n == "ropetrail" else { unsupported("renderer", n); return nil }
            return ParticleRenderStyle(ParticleValues(d, properties))
        }
        var points = (definition["controlpoint"] as? [[String: Any]] ?? []).map { d -> ParticleControlPoint in
            let cp = ParticleValues(d, properties)
            return ParticleControlPoint(id: Int(cp.f("id", -1)), flags: Int(cp.f("flags", 0)) | (cp.b("locktopointer", false) ? 1 : 0), offset: cp.v("offset", .zero))
        }
        for cp in inheritedPoints {
            if let i = points.firstIndex(where: { $0.id == cp.id }) { points[i] = cp }
            else { points.append(cp) }
        }
        if ov.b("enabled") {
            for i in 0..<8 where ov.data["controlpoint\(i)"] != nil {
                let offset = ov.v("controlpoint\(i)", .zero)
                if let j = points.firstIndex(where: { $0.id == i }) { points[j].offset = offset }
                else { points.append(ParticleControlPoint(id: i, flags: 0, offset: offset)) }
            }
        }
        controlPoints = points
        let ropeOnly = !renderers.isEmpty && renderers.allSatisfy { $0.rope }
        if let path = definition["material"] as? String {
            passes = (try locator.json(path)["passes"] as? [[String: Any]] ?? []).compactMap { d in
                var p = SceneDescription.Pass(material: d, label: name)
                guard p.shader == "genericparticle" || p.shader == "genericropeparticle" else { unsupported("shader", p.shader); return nil }
                if ropeOnly { p.shader = "genericropeparticle" }
                return p
            }
        } else { passes = []; notes.append("\(name): no material") }
        var children: [ParticleSystemDescription] = []
        let transform = parent * particleTransform(origin: origin, angles: angles, scale: scale)
        for var child in definition["children"] as? [[String: Any]] ?? [] {
            let type = child["type"] as? String ?? "static"
            guard ChildType(rawValue: type) != nil else { unsupported("event child", type); continue }
            child["id"] = id
            // WE child entries name their definition file in "name" (e.g. "particles/presets/emberglow.json").
            if child["particle"] == nil, let file = child["name"] as? String, file.lowercased().hasSuffix(".json") {
                child["particle"] = file
            }
            child["name"] = "\(name)/\(child["name"] as? String ?? "child")"
            child["visible"] = visible && properties.bool(child["visible"])
            child["parallaxDepth"] = object["parallaxDepth"]
            let inheritedOverrides = (object["instanceoverride"] as? [String: Any] ?? [:]).filter { !$0.key.hasPrefix("controlpoint") }
            child["_ownOverrideNames"] = Array((child["instanceoverride"] as? [String: Any] ?? [:]).keys)
            child["instanceoverride"] = inheritedOverrides.merging(child["instanceoverride"] as? [String: Any] ?? [:]) { _, value in value }
            let cv = ParticleValues(child, properties)
            let local = particleTransform(origin: cv.v("origin", .zero), angles: cv.v("angles", .zero), scale: cv.v("scale", .one))
            let start = Int(cv.f("controlpointstartindex", 0))
            let inherited = points.filter { $0.id >= start }.map { cp -> ParticleControlPoint in
                var cp = cp
                cp.id -= start
                if cp.flags & 3 == 0 {
                    let offset = local.inverse * SIMD4(cp.offset, 1)
                    cp.offset = SIMD3(offset.x, offset.y, offset.z)
                }
                return cp
            }
            children.append(try ParticleSystemDescription(object: child, locator: locator, properties: properties,
                            ancestors: ancestors, parent: transform, inheritedPoints: inherited, childIndex: &childIndex))
        }
        self.children = children
        self.notes = notes
    }
}

func particleTransform(origin: SIMD3<Float>, angles: SIMD3<Float>, scale: SIMD3<Float>) -> simd_float4x4 {
    let x = simd_float4x4(simd_quatf(angle: angles.x, axis: [1, 0, 0]))
    let y = simd_float4x4(simd_quatf(angle: angles.y, axis: [0, 1, 0]))
    return translation(origin) * rotationZ(angles.z) * y * x * scaling(scale)
}
