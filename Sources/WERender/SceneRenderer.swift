import AVFoundation
import CoreGraphics
import Foundation
import Metal
import simd
import WEAudio
import WEFormat
import WEScript
import WEShader

/// Offscreen Metal renderer for image-layer scenes with effects (milestones M3/M4).
///
/// Per layer (following linux-wallpaperengine's CImage):
/// - pass list = material passes + effect passes (+ an `effectpassthrough` pass when the object has a
///   `colorBlendMode`); with more than one pass the first pass's blending moves to the last pass;
/// - the first pass draws the image into a layer-sized FBO, each further pass is a fullscreen quad
///   ping-ponging between two FBOs (an empty texture slot 0 = previous output), and the last pass draws
///   the layer quad into the scene target.
/// Scene bloom reuses WE's own bloom shaders on `_rt_FullFrameBuffer`.
public final class SceneRenderer: WallpaperRenderer {
    public var contentMode: ContentMode = .fill
    public var barColor = SIMD3<Float>(repeating: 0)
    public let device: MTLDevice
    public let queue: MTLCommandQueue
    let locator: AssetLocator
    public internal(set) var scene: SceneDescription
    /// SceneScript: the engine (created on the first frame), the wall clock scripts see (nil = now; fixed
    /// for reproducible offline renders) and where `localStorage` persists (nil = memory only).
    var scriptEngine: SceneScriptEngine?
    public var scriptClock: Date?
    public var scriptStorageURL: URL?
    var lastScriptTime: Double?
    var scriptedLayers = Set<Int>()
    var scriptWarnings = Set<String>()
    var cachedLayerIndexByID: [Int: Int]?
    /// Per frame: world transforms by object id.
    var worldCache: [Int: simd_float4x4] = [:]
    /// Per layer: effects currently hidden by scripts (initially `ImageLayer.hiddenEffects`).
    var hiddenEffects: [Int: Set<Int>] = [:]
    /// Cursor state behind SceneScript cursor events (see `dispatchCursorEvents`).
    var cursor: (down: Bool, pressed: [Int], hover: [Int], last: SIMD2<Float>?) = (false, [], [], nil)
    /// Layers whose uniform templates scripts changed since their last draw.
    var uniformsDirty = Set<Int>()
    /// Sound objects play only after `enableSound` (the app); offline renders stay silent.
    public private(set) var sound: SceneSoundPlayer?

    /// Creates the player for the scene's sound objects (nil if it has none). `offlineFrames` renders the
    /// mix manually instead of to the output device (tests, `wecli sound`).
    @discardableResult
    public func enableSound(offlineFrames: AVAudioFrameCount? = nil) throws -> SceneSoundPlayer? {
        guard sound == nil, !scene.sounds.isEmpty else { return sound }
        sound = try SceneSoundPlayer(sounds: scene.sounds, locator: locator, offlineFrames: offlineFrames) { [weak self] in
            self?.warn($0)
        }
        return sound
    }
    /// Human-readable notes about anything skipped or approximated.
    public private(set) var warnings: [String] = []
    private var warningSet = Set<String>()

    func warn(_ w: String) {
        if warningSet.insert(w).inserted { warnings.append(w) }
    }

    struct Program {
        let compiled: CompiledProgram
        let vertexFunction: MTLFunction
        let fragmentFunction: MTLFunction
        let annotations: [UniformAnnotation]
        var pipelines: [String: MTLRenderPipelineState] = [:]
    }

    /// Cursor state for one output (the app keeps one per screen and swaps it in before each frame).
    public struct PointerInput {
        /// Cursor in the visible frame, 0…1, y = 0 at the top (WE's `g_PointerPosition`: shaders flip
        /// it to y-up clip space, e.g. `mul(vec4(p * 2 - 1, 0, 1), g_ModelViewProjectionMatrixInverse)`).
        public var position = SIMD2<Float>(0.5, 0.5)
        /// (left button, right button, press strength, 0) → `g_PointerState`.
        public var state = SIMD4<Float>(0, 0, 0, 0)
        /// Position at the previous frame (set by the renderer after each frame).
        public internal(set) var last: SIMD2<Float>?
        /// Smoothed camera-parallax displacement and the cursor-following `g_ParallaxPosition`.
        public internal(set) var parallax = SIMD2<Float>(0, 0)
        public internal(set) var parallaxPosition = SIMD2<Float>(0.5, 0.5)
        var lastTime: Float?
        public init() {}
    }

    public var pointer = PointerInput()
    /// Audio spectrum for `g_AudioSpectrum{16,32,64}{Left,Right}` (silence by default).
    public var audio = AudioSpectrum()
    /// Whether any pass built so far reads the audio spectrum (known after the first frame), so the
    /// app only captures audio when it is used.
    public var usesAudio: Bool { plans.values.contains { $0.usesAudio } }

    /// Per-draw state needed to fill uniforms.
    struct DrawContext {
        let layer: SceneDescription.ImageLayer?
        let pass: SceneDescription.Pass
        let mvp: simd_float4x4
        let model: simd_float4x4
        let textures: [Int: LoadedTexture]
    }

    /// `g_EffectTextureProjectionMatrix`: maps the layer's quad (-1…1, y up) to clip space; cursor
    /// effects invert it to find the pointer's UV within the layer. (LWE passes identity.)
    static func effectTextureProjection(_ layerMVP: simd_float4x4, half: SIMD2<Float>) -> simd_float4x4 {
        layerMVP * scaling([half.x, half.y, 1])
    }

    var programs: [String: Program] = [:]
    var textures: [String: LoadedTexture] = [:]
    var failedUserTextures = Set<String>()
    var videoTextures: [URL: VideoTexture] = [:]
    /// Text layers by layer index, and text set by scripts (overriding the static value).
    var textStates: [Int: TextLayerState] = [:]
    var textOverrides: [Int: String] = [:]
    var textObjectOverrides: [Int: TextObject] = [:]
    var scriptAnimations: [Int: StillAnimation] = [:]
    var samplers: [Bool: MTLSamplerState] = [:]
    var time: Float = 0
    var outputSize = SIMD2<Float>(1, 1)
    var colorFormat: MTLPixelFormat
    /// Named render targets for the current frame (`_rt_FullFrameBuffer`, bloom buffers...).
    var renderTargets: [String: LoadedTexture] = [:]
    var sceneTarget: MTLTexture!
    var commandBuffer: MTLCommandBuffer!
    /// Whether `_rt_FullFrameBuffer` still matches the scene target.
    var fullFrameValid = false
    /// Debug: render only layers whose name is listed (nil = all).
    public var onlyLayers: Set<String>?
    /// Debug: skip the camera bloom pass.
    public var disableBloom = false
    /// Debug: return this named render target (e.g. `_rt_Bloom`) instead of the final frame.
    public var debugTarget: String?
    /// Debug/benchmark: disable static-layer caching.
    public var disableLayerCache = false
    /// Render encoders created by the last encoded frame (stats).
    public private(set) var lastFrameEncoders = 0
    var frameEncoders = 0
    var particleStates: [Int: ParticleRenderState] = [:]
    var particleTextures: [String: ParticleTexture] = [:]
    var particleIndexBuffer: MTLBuffer?
    let particleRing = ParticleFrameRing()
    var offlineParticles = false

    lazy var white = solid([255, 255, 255, 255])
    lazy var black = solid([0, 0, 0, 255])

    static let vertexBufferIndex = 30

    public init(project: URL, assets: URL?, properties: [String: String] = [:]) throws {
        guard let device = MTLCreateSystemDefaultDevice(), let queue = device.makeCommandQueue() else {
            throw WEFormatError.unsupported("no Metal device")
        }
        self.device = device
        self.queue = queue
        locator = AssetLocator(project: project, assets: assets)
        scene = try SceneDescription(project: project, locator: locator, overrides: properties)
        colorFormat = scene.hdr ? .rgba16Float : .rgba8Unorm
        scene.notes.forEach(warn)
    }

    public var summary: String {
        "scene, \(scene.layers.count) layers" + (scene.particles.isEmpty ? "" : ", \(scene.particles.count) particle systems")
    }

    // MARK: - frame

    /// Render one frame at `time` seconds into a `width`×`height` image using `contentMode`.
    public func render(width: Int, height: Int, time: Float) throws -> CGImage {
        let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba8Unorm, width: width, height: height, mipmapped: false)
        d.usage = [.renderTarget, .shaderRead]
        d.storageMode = .private
        let output = device.makeTexture(descriptor: d)!
        let cb = queue.makeCommandBuffer()!
        offlineParticles = true
        encodeFrame(into: output, commandBuffer: cb, time: time)
        offlineParticles = false
        cb.commit()
        cb.waitUntilCompleted()
        if let e = cb.error { throw e }
        if let name = debugTarget {
            // Global targets, effect FBOs (by FBO name) or pooled layer FBOs ("fboA", "fboB").
            let t = renderTargets[name]?.texture
                ?? effectTargets.first(where: { $0.key.hasSuffix("." + name) })?.value.texture
                ?? targetPool.first(where: { $0.key.hasPrefix(name + "|") })?.value
            guard let t else { throw WEFormatError.unsupported("no render target \(name)") }
            return try readback(t)
        }
        return try readback(output)
    }

    /// Encode one frame into `output` (any size / 8-bit format, e.g. a window drawable).
    /// Render targets are pooled, so steady-state frames allocate nothing; Metal's hazard
    /// tracking orders reuse across in-flight frames on the same queue.
    public func encodeFrame(into output: MTLTexture, commandBuffer: MTLCommandBuffer, time: Float) {
        self.time = time
        updateParallax()
        defer { pointer.last = pointer.position; pointer.lastTime = time }
        outputSize = SIMD2(Float(output.width), Float(output.height))
        sceneTarget = pooledTarget("scene", output.width, output.height)
        renderTargets = [:]
        fullFrameValid = false
        self.commandBuffer = commandBuffer
        for (name, texture) in textures where texture.video != nil {
            do {
                textures[name] = try texture.video!.frame(at: Double(time), clamp: texture.clamp, commandBuffer: commandBuffer)
            } catch { warn("\(name): video textures: \(error)") }
        }

        for (name, texture) in textures {
            guard let animation = texture.animation else { continue }
            do { textures[name] = try animation.frame(at: Double(time), device: device) }
            catch { warn("\(name): user texture: \(error)") }
        }

        let projection = contentProjection(canvas: scene.canvas, output: outputSize, mode: contentMode)
        worldCache = [:]
        // Text boxes are laid out before scripts (cursor hit tests need their size) and again after
        // (scripts may change the text); unchanged text is not laid out twice.
        updateTextLayers()
        runScripts(projection: projection)
        updateTextLayers()
        let c = scene.clearColor
        _ = encoder(for: sceneTarget, clear: MTLClearColor(red: Double(c.x), green: Double(c.y), blue: Double(c.z), alpha: 1))
        if contentMode == .fit {
            do { try clearFitBars() } catch { warn("fit bars: \(error)") }
        }
        let particleSlot = scene.particles.isEmpty ? 0 : particleRing.acquire(commandBuffer)
        for object in renderOrder {
            switch object {
            case .image(let i):
                let layer = scene.layers[i]
                guard onlyLayers?.contains(layer.name) ?? true else { continue }
                do { try renderLayer(i, projection: projection) } catch { warn("\(layer.name): \(error)") }
            case .particle(let i):
                // Perspective particles construct their own cover projection. Apply the same
                // clip-space correction to their MVP and view-projection uniforms at submission.
                if contentMode != .fill, scene.particles[i].flags & 4 != 0 {
                    let fill = contentProjection(canvas: scene.canvas, output: outputSize, mode: .fill)
                    particleProjectionAdjustment = scaling([projection.columns.0.x / fill.columns.0.x,
                                                            projection.columns.1.y / fill.columns.1.y, 1])
                }
                defer { particleProjectionAdjustment = nil }
                do { try renderParticle(i, projection: projection, slot: particleSlot) }
                catch { warn("\(scene.particles[i].name): \(error)") }
            }
        }
        if scene.bloom.enabled && !disableBloom {
            do { try renderBloom() } catch { warn("bloom: \(error)") }
        }
        do { try present(sceneTarget, to: output) } catch { warn("present: \(error)") }
        endEncoding()
        lastFrameEncoders = frameEncoders
        frameEncoders = 0
        self.commandBuffer = nil
    }

    /// Camera parallax follows the cursor with a lag. LWE uses `mix(d, target, clamp(delay·dt))`, which
    /// with the usual delay of 0.1 barely moves (0.3% per frame); here `delay` is treated as a time
    /// constant in seconds instead. TODO: compare with WE on Windows.
    func updateParallax() {
        let dt = pointer.lastTime.map { max(0, min(0.25, time - $0)) } ?? 0
        let p = scene.parallax
        let k = dt == 0 ? (pointer.lastTime == nil ? 1 : 0) : 1 - exp(-dt / max(0.001, p.delay))
        let centered = SIMD2(pointer.position.x - 0.5, 0.5 - pointer.position.y) // scene space is y-up
        pointer.parallaxPosition += (pointer.position - pointer.parallaxPosition) * k
        if p.enabled { pointer.parallax += (centered * p.amount * p.mouseInfluence - pointer.parallax) * k }
    }

    /// Copy the (possibly HDR) scene target into the output, clamping to [0, 1].
    var presentPipelines: [MTLPixelFormat: MTLRenderPipelineState] = [:]
    func present(_ source: MTLTexture, to output: MTLTexture) throws {
        let pipeline: MTLRenderPipelineState
        if let p = presentPipelines[output.pixelFormat] {
            pipeline = p
        } else {
            let src = """
            #include <metal_stdlib>
            using namespace metal;
            struct V { float4 pos [[position]]; float2 uv; };
            vertex V present_vs(uint id [[vertex_id]]) {
                float2 p = float2((id << 1) & 2, id & 2);
                return { float4(p * 2 - 1, 0, 1), float2(p.x, 1 - p.y) };
            }
            fragment float4 present_fs(V in [[stage_in]], texture2d<float> t [[texture(0)]]) {
                constexpr sampler s(filter::linear);
                return float4(saturate(t.sample(s, in.uv).rgb), 1);
            }
            """
            let lib = try device.makeLibrary(source: src, options: nil)
            let pd = MTLRenderPipelineDescriptor()
            pd.vertexFunction = lib.makeFunction(name: "present_vs")
            pd.fragmentFunction = lib.makeFunction(name: "present_fs")
            pd.colorAttachments[0].pixelFormat = output.pixelFormat
            pipeline = try device.makeRenderPipelineState(descriptor: pd)
            presentPipelines[output.pixelFormat] = pipeline
        }
        let enc = encoder(for: output, clear: MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1))
        enc.setRenderPipelineState(pipeline)
        enc.setFragmentTexture(source, index: 0)
        enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
    }

    // MARK: - pass lists (built once)

    /// Per-layer pass lists with the effectpassthrough pass appended and blending moved to the last
    /// pass — computed once, not per frame (it reads JSON from disk).
    lazy var layerPasses: [[SceneDescription.Pass]] = scene.layers.map { layer in
        // Passes whose `conditions` fail are dropped; failing binds are removed.
        var passes = layer.passes.compactMap { pass -> SceneDescription.Pass? in
            guard let combos = try? effectiveCombos(pass),
                  SceneDescription.conditionsHold(pass.conditions, combos: combos) else { return nil }
            var p = pass
            for (slot, c) in pass.bindConditions where !SceneDescription.conditionsHold(c, combos: combos) {
                p.binds[slot] = nil
            }
            return p
        }
        if layer.colorBlendMode > 0 {
            let mps = (try? locator.json("materials/util/effectpassthrough.json"))?["passes"] as? [[String: Any]] ?? []
            for mp in mps {
                var p = SceneDescription.Pass(material: mp, label: "colorBlendMode")
                p.combos["BLENDMODE"] = layer.colorBlendMode
                passes.append(p)
            }
        }
        if passes.count > 1 {
            passes[passes.count - 1].blending = passes[0].blending
            passes[0].blending = "normal"
        }
        return passes
    }

    /// materials/util/effectpassthrough: draws a layer's FBO into the scene at the layer's quad.
    lazy var passthroughPass: SceneDescription.Pass? = {
        guard let mp = ((try? locator.json("materials/util/effectpassthrough.json"))?["passes"] as? [[String: Any]])?.first
        else { return nil }
        return SceneDescription.Pass(material: mp, label: "passthrough")
    }()

    lazy var bloomPasses: [(pass: SceneDescription.Pass, inputs: [String], target: String)] = {
        let constants: [String: Any] = ["bloomstrength": scene.bloom.strength, "bloomthreshold": scene.bloom.threshold]
        var out: [(SceneDescription.Pass, [String], String)] = []
        for (material, inputs, target) in [
            ("materials/util/downsample_quarter_bloom.json", ["_rt_FullFrameBuffer"], "_rt_4FrameBuffer"),
            ("materials/util/downsample_eighth_blur_v.json", ["_rt_4FrameBuffer"], "_rt_8FrameBuffer"),
            ("materials/util/blur_h_bloom.json", ["_rt_8FrameBuffer"], "_rt_Bloom"),
        ] {
            let mp = ((try? locator.json(material))?["passes"] as? [[String: Any]])?.first ?? [:]
            var pass = SceneDescription.Pass(material: mp, label: "bloom")
            pass.constants = constants
            out.append((pass, inputs, target))
        }
        out.append((SceneDescription.Pass(material: ["shader": "combine"], label: "bloom"),
                    ["_rt_FullFrameBuffer", "_rt_Bloom"], "scene"))
        return out
    }()

    /// Per layer: the output of its leading static passes, rendered once (see `renderLayer`).
    var layerCaches: [Int: (texture: LoadedTexture, passes: Int)] = [:]
    /// Each layer's two composite FBOs, registered as `_rt_imageLayerComposite_<id>_a/_b` so other
    /// layers (and the layer's own effects) can read them.
    var layerComposites: [String: LoadedTexture] = [:]

    func compositeTargets(_ index: Int, _ w: Int, _ h: Int) -> [LoadedTexture] {
        let id = scene.layers[index].id
        let names = ["_rt_imageLayerComposite_\(id)_a", "_rt_imageLayerComposite_\(id)_b"]
        return names.map { name in
            if let t = layerComposites[name], t.texture.width == w, t.texture.height == h { return t }
            let t = wrap(makeTarget(w, h))
            t.texture.label = name
            layerComposites[name] = t
            return t
        }
    }

    /// Effect FBOs persist across frames (motion blur / ripple simulations feed back on themselves).
    var effectTargets: [String: LoadedTexture] = [:]
    /// Names visible to the pass being drawn: the layer's `_rt_imageLayerComposite_<id>_a/_b` and its
    /// effect's FBOs; global targets (`_rt_FullFrameBuffer`...) are looked up after these.
    var scopedTargets: [String: LoadedTexture] = [:]

    func effectTarget(_ layerIndex: Int, _ effect: Int, _ def: SceneDescription.EffectFBO, layerSize: SIMD2<Float>) -> LoadedTexture {
        let key = "L\(layerIndex).E\(effect).\(def.name)"
        if let t = effectTargets[key] { return t }
        let (w, h) = def.pixelSize(layerSize: layerSize)
        let format: MTLPixelFormat = switch def.format {
            case "r8": .r8Unorm
            case "rg88": .rg8Unorm
            case "rgba8888": .rgba8Unorm
            case "r16f": .r16Float
            case "rg1616f": .rg16Float
            case "rgba16161616f": .rgba16Float
            default: colorFormat // rgba_backbuffer
        }
        let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: format, width: w, height: h, mipmapped: false)
        d.usage = [.renderTarget, .shaderRead]
        d.storageMode = .private
        let t = device.makeTexture(descriptor: d)!
        t.label = key
        var lt = wrap(t, clamp: def.clamp)
        lt.formatCode = ["rg88": 8, "r8": 9, "rg1616f": 10, "r16f": 11][def.format] ?? 0
        effectTargets[key] = lt
        // New GPU memory is undefined; feedback effects (ripples, motion blur) read it before writing.
        let c = def.clearColor
        _ = encoder(for: t, clear: MTLClearColor(red: Double(c.x), green: Double(c.y), blue: Double(c.z), alpha: Double(c.w)))
        endEncoding()
        return lt
    }

    /// Runs a layer's passes like linux-wallpaperengine's `CImage::setupPasses`:
    /// - a pass with a `target` renders into that FBO, which becomes the input of the next pass;
    ///   `previous` binds refer to the input at the start of such a target sequence;
    /// - other passes ping-pong between the layer's two composite FBOs; the last one draws into the scene.
    /// Combos a pass's `conditions` are evaluated against: the shader's declared defaults, then the
    /// effect instance's combos, then the pass's own.
    var shaderDefaultCombos: [String: [String: Int]] = [:]
    var activeEffectFBOs: [String: [SceneDescription.EffectFBO]] = [:]

    func effectiveCombos(_ pass: SceneDescription.Pass) throws -> [String: Int] {
        guard pass.copy == nil, !pass.shader.isEmpty else { return pass.effectCombos }
        if shaderDefaultCombos[pass.shader] == nil {
            shaderDefaultCombos[pass.shader] = ShaderPreprocessor.scan(try locator.string("shaders/\(pass.shader).vert")).combos
                .merging(ShaderPreprocessor.scan(try locator.string("shaders/\(pass.shader).frag")).combos) { a, _ in a }
        }
        var c = shaderDefaultCombos[pass.shader]!
        for (k, v) in pass.effectCombos { c[k] = v }
        for (k, v) in pass.combos { c[k.uppercased()] = v }
        return c
    }

    /// File order, except that a layer's `dependencies` are rendered before it.
    lazy var renderOrder = scene.orderedObjects()

    /// Layer size: from the object/model, or (autosize without either) the base texture's image size.
    lazy var layerSizes: [SIMD2<Float>] = scene.layers.indices.map { i in
        let layer = scene.layers[i]
        if layer.size.x > 0, layer.size.y > 0 { return layer.size }
        if layer.text != nil { return layer.size } // sized by `updateTextLayers`
        if let name = layer.passes.first?.textures.first ?? nil, let t = try? resolveTexture(name) { return t.imageSize }
        warn("\(layer.name): no size")
        return layer.size
    }

    /// Object → scene transform of a layer's quad (centred, `layerSizes` in object units).
    func layerModel(_ index: Int) -> simd_float4x4 {
        let layer = scene.layers[index]
        var model: simd_float4x4
        if let node = scene.nodes[layer.id], !layer.fullscreen {
            model = parentTransform(layer.id) * translation(node.origin) * rotationZ(node.angles.z) * scaling(node.scale)
        } else {
            model = translation(layer.origin) * rotationZ(layer.angles.z) * scaling(layer.scale)
        }
        model *= translation(textOffset(index))
        if scene.parallax.enabled {
            let d = (layer.parallaxDepth + scene.parallax.amount) * pointer.parallax * scene.canvas.x
            model = translation(SIMD3(d.x, d.y, 0)) * model
        }
        return model
    }

    func renderLayer(_ index: Int, projection: simd_float4x4) throws {
        let layer = scene.layers[index]
        // Passes of effects hidden by scripts are skipped; plan keys keep the pass's original index and
        // include the blending, which moves to whichever pass is last (plans bake it in).
        let hidden = hiddenEffects[index] ?? layer.hiddenEffects
        var kept = Array(layerPasses[index].enumerated())
        if !hidden.isEmpty {
            let blending = kept.last?.element.blending ?? "normal"
            kept = kept.filter { $0.element.effect.map { !hidden.contains($0) } ?? true }
            // The layer's blending sits on its last pass (see `layerPasses`); move it to the new last pass.
            if !kept.isEmpty { kept[kept.count - 1].element.blending = blending }
        }
        // A passthrough layer's first pass (composelayer) fills the whole target with what lies behind the
        // quad, so it must go into the layer's FBO and be drawn back by a later pass. With every effect
        // hidden only that pass is left: add WE's effectpassthrough to draw the FBO back in place, or the
        // region behind the quad would be stretched over the whole scene.
        if layer.passthrough, kept.count == 1, let pass = passthroughPass {
            var back = pass
            back.blending = kept[0].element.blending
            kept[0].element.blending = "normal"
            kept.append((offset: layerPasses[index].count, element: back))
        }
        let passes = kept.map(\.element)
        let size = layerSizes[index]
        guard !passes.isEmpty, size.x > 0, size.y > 0 else { return }

        let w = max(1, Int(size.x.rounded())), h = max(1, Int(size.y.rounded()))
        // Hidden layers render into their composite FBO instead of the scene, for other layers to read.
        let toScene = scene.nodes[layer.id] == nil ? layer.visible : isVisible(layer.id)
        let fbo = (passes.count > 1 || !toScene) ? compositeTargets(index, w, h) : []
        let model = layerModel(index)
        effectProjection = Self.effectTextureProjection(projection * model, half: size / 2)
        defer { effectProjection = matrix_identity_float4x4 }
        let refresh = uniformsDirty.remove(index) != nil
        let plans = try passes.enumerated().map { i, pass -> PassPlan? in
            pass.copy != nil ? nil : try self.plan("L\(index).\(kept[i].offset)|\(pass.blending)", pass: pass, layer: layer, model: model,
                                                   hasPrevious: i > 0, refreshUniforms: refresh)
        }
        // Effect FBOs visible to a pass (layer composites are looked up globally).
        func scope(for pass: SceneDescription.Pass) -> [String: LoadedTexture] {
            guard let e = pass.effect, e < layer.effectFBOs.count else { return [:] }
            var s: [String: LoadedTexture] = [:]
            let key = "L\(index).E\(e)"
            if activeEffectFBOs[key] == nil {
                // FBO `conditions` never change at runtime: evaluate once per layer × effect.
                let combos = (try? effectiveCombos(pass)) ?? pass.effectCombos
                activeEffectFBOs[key] = layer.effectFBOs[e].filter {
                    SceneDescription.conditionsHold($0.conditions, combos: combos)
                }
            }
            for def in activeEffectFBOs[key]! { s[def.name] = effectTarget(index, e, def, layerSize: size) }
            return s
        }

        // Static-layer caching: the leading plain passes (no targets/binds) before the final composite
        // whose output never changes are rendered once into a dedicated texture.
        let lastDrawingPass = passes.lastIndex { $0.copy == nil } ?? passes.count - 1
        var staticPrefix = 0
        if !disableLayerCache, !scriptedLayers.contains(index) {
            while staticPrefix < lastDrawingPass, let p = plans[staticPrefix], !p.isDynamic,
                  passes[staticPrefix].target == nil, passes[staticPrefix].binds.isEmpty {
                staticPrefix += 1
            }
        }
        var drawTo = 0                     // index into `fbo`
        var input: LoadedTexture? = nil    // current input (slot 0 default for effect passes)
        var sequenceInput: LoadedTexture? = nil // input when the current target sequence started
        var start = 0
        if staticPrefix > 0, let cache = layerCaches[index], cache.passes == staticPrefix {
            input = cache.texture
            drawTo = staticPrefix % 2
            start = staticPrefix
        }

        for i in start..<passes.count {
            let pass = passes[i]
            // Trailing commands (e.g. swaps after a simulation's combine) don't draw: the composite into
            // the scene is the last drawing pass.
            let first = i == 0, last = i == lastDrawingPass
            scopedTargets = scope(for: pass)
            defer { scopedTargets = [:] }

            if let copy = pass.copy, pass.swap, let e = pass.effect {
                // Exchange the two persistent FBOs; later passes see each under the other's name.
                let a = "L\(index).E\(e).\(copy.source)", b = "L\(index).E\(e).\(copy.target)"
                if let ta = effectTargets[a], let tb = effectTargets[b] {
                    effectTargets[a] = tb
                    effectTargets[b] = ta
                } else {
                    warn("\(layer.name): swap of unknown FBOs \(copy.source)/\(copy.target)")
                }
                continue
            }
            if let copy = pass.copy {
                let src = try resolveTexture(copy.source), dst = try resolveTexture(copy.target)
                guard src.texture.width == dst.texture.width, src.texture.height == dst.texture.height,
                      src.texture.pixelFormat == dst.texture.pixelFormat else {
                    warn("\(layer.name): copy \(copy.source) → \(copy.target) needs matching size/format"); continue
                }
                endEncoding()
                let blit = commandBuffer.makeBlitCommandEncoder()!
                blit.copy(from: src.texture, to: dst.texture)
                blit.endEncoding()
                continue
            }
            guard let plan = plans[i] else { continue }

            if let targetName = pass.target {
                if sequenceInput == nil { sequenceInput = input }
                let target = try resolveTexture(targetName)
                try execute(plan, previous: input, bindPrevious: sequenceInput ?? input, target: target.texture,
                            clear: pass.blending.lowercased() == "normal", mvp: matrix_identity_float4x4,
                            half: [1, 1], first: false)
                input = target
                continue
            }

            let target: MTLTexture, mvp: simd_float4x4
            if last && toScene {
                target = sceneTarget; mvp = projection * model
                fullFrameValid = false
            } else if first {
                target = fbo[0].texture
                mvp = layer.passthrough
                    ? (layer.fullscreen ? matrix_identity_float4x4 : projection * model)
                    : ortho(left: 0, right: Float(w), bottom: 0, top: Float(h)) * translation([Float(w) / 2, Float(h) / 2, 0])
            } else {
                target = fbo[drawTo].texture; mvp = matrix_identity_float4x4
            }
            let intoScene = last && toScene
            let fullscreenQuad = first && !intoScene && layer.fullscreen
            let half = fullscreenQuad ? SIMD2<Float>(1, 1) : (first || intoScene) ? size / 2 : SIMD2<Float>(1, 1)
            // Passthrough layers sample render targets, not a padded source texture: UVs stay 0…1.
            try execute(plan, previous: input, bindPrevious: sequenceInput ?? input, target: target,
                        clear: !intoScene, mvp: mvp, half: half, first: first && !layer.passthrough)
            sequenceInput = nil
            if !intoScene {
                input = fbo[drawTo]
                drawTo = 1 - drawTo
            }

            if i + 1 == staticPrefix, let out = input {
                // First frame: keep a private copy of the static prefix output.
                endEncoding()
                let cache = wrap(makeTarget(w, h))
                cache.texture.label = "layerCache \(layer.name)"
                let blit = commandBuffer.makeBlitCommandEncoder()!
                blit.copy(from: out.texture, to: cache.texture)
                blit.endEncoding()
                layerCaches[index] = (cache, staticPrefix)
            }
        }
    }

    /// WE's camera bloom: quarter-res bright pass → eighth-res separable blur → combine.
    func renderBloom() throws {
        let w = Int(outputSize.x), h = Int(outputSize.y)
        renderTargets["_rt_4FrameBuffer"] = wrap(pooledTarget("_rt_4FrameBuffer", max(1, w / 4), max(1, h / 4)))
        renderTargets["_rt_8FrameBuffer"] = wrap(pooledTarget("_rt_8FrameBuffer", max(1, w / 8), max(1, h / 8)))
        renderTargets["_rt_Bloom"] = wrap(pooledTarget("_rt_Bloom", max(1, w / 8), max(1, h / 8)))
        for (i, step) in bloomPasses.enumerated() {
            let plan = try self.plan("bloom.\(i)", pass: step.pass, layer: nil, model: matrix_identity_float4x4,
                                     hasPrevious: false, fixedInputs: step.inputs)
            let toScene = step.target == "scene"
            try execute(plan, previous: nil, target: toScene ? sceneTarget : renderTargets[step.target]!.texture,
                        clear: !toScene, mvp: matrix_identity_float4x4, half: [1, 1], first: false)
        }
        fullFrameValid = false
    }

    // MARK: - draw plans

    /// Everything about a pass that does not change between frames, resolved once: shader variant,
    /// pipelines, texture bindings and a uniform buffer template with only per-frame values patched.
    final class PassPlan {
        enum Input { case fixed(LoadedTexture), named(String), previous, bindPrevious }
        enum Patch {
            case mvp, mvpInverse, time, resolution(Int), texelSize, texelSizeHalf, screen
            case pointer, pointerLast, pointerState, parallaxPosition, effectProjection, effectProjectionInverse
            case audio(bands: Int, right: Bool)
            case particle(String)
        }
        struct UniformPlan {
            let bufferIndex: Int
            var template: [UInt8]
            var patches: [(patch: Patch, offset: Int, type: String, stride: Int)]
        }

        let label: String
        let program: Program
        let programKey: String
        let blend: String
        var pipelines: [MTLPixelFormat: MTLRenderPipelineState] = [:]
        /// slot → where its texture comes from
        let inputs: [Int: Input]
        /// (isVertex, slot, MSL texture index, MSL sampler index)
        let bindings: [(isVertex: Bool, slot: Int, texture: Int, sampler: Int)]
        var vertexUniforms: UniformPlan?
        var fragmentUniforms: UniformPlan?
        /// Output can change from frame to frame (time, pointer, audio, screen size or scene reads).
        /// Static passes are candidates for layer caching.
        var isDynamic = false
        var usesAudio = false
        var particle = false
        var textureKey: [String?] = []

        init(label: String, program: Program, programKey: String, blend: String, inputs: [Int: Input],
             bindings: [(isVertex: Bool, slot: Int, texture: Int, sampler: Int)]) {
            self.label = label; self.program = program; self.programKey = programKey; self.blend = blend
            self.inputs = inputs; self.bindings = bindings
        }
    }

    var plans: [String: PassPlan] = [:]

    /// Uniform buffer template for a stage: static values written, per-frame values recorded as patches.
    func uniformPlan(_ stage: CompiledStage, program: Program, ctx: DrawContext, particle: Bool) -> PassPlan.UniformPlan? {
        guard let index = stage.uniformBufferIndex else { return nil }
        var buf = [UInt8](repeating: 0, count: max(stage.uniformBlockSize, 16))
        var patches: [(patch: PassPlan.Patch, offset: Int, type: String, stride: Int)] = []
        for m in stage.uniforms {
            let patch: PassPlan.Patch? = {
                if particle, ["g_ModelMatrix", "g_ModelMatrixInverse", "g_ViewProjectionMatrix", "g_OrientationUp",
                              "g_OrientationRight", "g_OrientationForward", "g_ViewUp", "g_ViewRight", "g_EyePosition",
                              "g_RenderVar0", "g_RenderVar1"].contains(m.name) { return .particle(m.name) }
                switch m.name {
                case "g_ModelViewProjectionMatrix", "g_EffectModelViewProjectionMatrix": return .mvp
                case "g_ModelViewProjectionMatrixInverse": return .mvpInverse
                case "g_Time": return .time
                case "g_TexelSize": return .texelSize
                case "g_TexelSizeHalf": return .texelSizeHalf
                case "g_Screen": return .screen
                case "g_PointerPosition": return .pointer
                case "g_PointerPositionLast": return .pointerLast
                case "g_PointerState": return .pointerState
                case "g_ParallaxPosition": return .parallaxPosition
                case "g_EffectTextureProjectionMatrix": return .effectProjection
                case "g_EffectTextureProjectionMatrixInverse": return .effectProjectionInverse
                default:
                    if m.name.hasPrefix("g_AudioSpectrum"), let bands = Int(m.name.dropFirst(15).prefix(2)) {
                        return .audio(bands: bands, right: m.name.hasSuffix("Right"))
                    }
                    if m.name.hasPrefix("g_Texture"), m.name.hasSuffix("Resolution"),
                       let i = Int(m.name.dropFirst(9).dropLast(10)) { return .resolution(i) }
                    return nil
                }
            }()
            if let patch { patches.append((patch, m.offset, m.type, m.arrayStride)); continue }
            guard let v = value(for: m.name, program: program, ctx: ctx) else {
                warn("\(ctx.pass.shader): no value for \(m.name)")
                continue
            }
            if m.arrayCount > 1 {
                let per = max(1, v.count / m.arrayCount)
                for k in 0..<m.arrayCount {
                    write(Array(v.dropFirst(k * per).prefix(per)), type: m.type, at: m.offset + k * m.arrayStride, into: &buf)
                }
            } else {
                write(v, type: m.type, at: m.offset, into: &buf)
            }
        }
        return PassPlan.UniformPlan(bufferIndex: index, template: buf, patches: patches)
    }
    /// The current layer's `g_EffectTextureProjectionMatrix` (identity outside layers).
    var effectProjection = matrix_identity_float4x4

    func plan(_ key: String, pass: SceneDescription.Pass, layer: SceneDescription.ImageLayer?, model: simd_float4x4,
              hasPrevious: Bool, fixedInputs: [String] = [], particle: Bool = false,
              fixedTextures: [Int: LoadedTexture] = [:], refreshUniforms: Bool = false) throws -> PassPlan {
        let textureKey = fixedInputs.isEmpty ? pass.textures : fixedInputs.map { Optional($0) }
        if let p = plans[key], p.textureKey == textureKey {
            // Scripts changed values baked into the uniform templates (alpha, colour, constants).
            if refreshUniforms {
                let textures = p.inputs.compactMapValues { if case .fixed(let t) = $0 { return t } else { return nil } }
                let ctx = DrawContext(layer: layer, pass: pass, mvp: matrix_identity_float4x4, model: model, textures: textures)
                p.vertexUniforms = uniformPlan(p.program.compiled.vertex, program: p.program, ctx: ctx, particle: p.particle)
                p.fragmentUniforms = uniformPlan(p.program.compiled.fragment, program: p.program, ctx: ctx, particle: p.particle)
            }
            return p
        }

        if plans[key] != nil { layerCaches.removeAll() }

        // Slot sources: explicit textures, else (effects) slot 0 = previous pass output.
        var sources: [Int: PassPlan.Input] = [:]
        for (slot, name) in (fixedInputs.isEmpty ? pass.textures : fixedInputs.map { Optional($0) }).enumerated() {
            guard let name else { continue }
            if fixedTextures[slot] == nil {
                // Text and video textures are replaced: look them up at draw time.
                if name.hasPrefix("$file:") {
                    do { sources[slot] = try textureInput(name) }
                    catch {
                        warn("\(name): user texture unavailable")
                        if let original = pass.originalTextures[safe: slot] ?? nil {
                            sources[slot] = try textureInput(original)
                        }
                    }
                } else { sources[slot] = try textureInput(name) }
            }
        }
        for (slot, texture) in fixedTextures { sources[slot] = .fixed(texture) }
        if hasPrevious, sources[0] == nil { sources[0] = .previous }
        // Binds win over everything else.
        for (slot, name) in pass.binds {
            sources[slot] = (name == "previous" || name == "prev") ? .bindPrevious : .named(name)
        }

        // Sampler-linked combos (e.g. MASK) turn on when their slot has a texture.
        var combos = pass.combos.reduce(into: [String: Int]()) { $0[$1.key.uppercased()] = $1.value }
        for a in try rawAnnotations(pass.shader) where a.type.hasPrefix("sampler") {
            if let combo = a.combo, let i = Int(a.name.dropFirst(9)), sources[i] != nil,
               i < max(pass.textures.count, fixedInputs.count), combos[combo.uppercased()] == nil {
                combos[combo.uppercased()] = 1
            }
        }
        // TEX<n>FORMAT = the bound texture's real format, so ConvertTextureFormat()/DecompressNormal()
        // expand R8/RG88 and decode DXT normal maps as WE does (materials may still override).
        for (slot, src) in sources {
            if case .fixed(let t) = src, combos["TEX\(slot)FORMAT"] == nil { combos["TEX\(slot)FORMAT"] = t.formatCode }
            if case .named(let name) = src, (textures[name]?.video != nil || textures[name]?.animation != nil), combos["TEX\(slot)FORMAT"] == nil {
                combos["TEX\(slot)FORMAT"] = 0
            }
        }
        let program = try self.program(shader: pass.shader, combos: combos)
        let pkey = programKey(pass.shader, combos)

        // Remaining sampled slots: annotation default ("util/white", "_rt_FullFrameBuffer"...) or white.
        var bindings: [(isVertex: Bool, slot: Int, texture: Int, sampler: Int)] = []
        for (stage, isVertex) in [(program.compiled.vertex, true), (program.compiled.fragment, false)] {
            for (name, idx) in stage.textures {
                guard name.hasPrefix("g_Texture"), let i = Int(name.dropFirst(9)) else { continue }
                bindings.append((isVertex, i, idx.texture, idx.sampler))
                guard sources[i] == nil else { continue }
                if let def = program.annotations.first(where: { $0.name == name })?.defaultValue as? String {
                    sources[i] = try? textureInput(def)
                }
                if sources[i] == nil { sources[i] = .fixed(white) }
            }
        }

        let plan = PassPlan(label: "\(key) \(pass.shader)", program: program, programKey: pkey,
                            blend: pass.blending.lowercased(), inputs: sources, bindings: bindings)
        // Uniform templates: static values written once; per-frame values recorded as patches.
        let staticTextures = sources.compactMapValues { if case .fixed(let t) = $0 { return t } else { return nil } }
        let ctx = DrawContext(layer: layer, pass: pass, mvp: matrix_identity_float4x4, model: model, textures: staticTextures)
        plan.vertexUniforms = uniformPlan(program.compiled.vertex, program: program, ctx: ctx, particle: particle)
        plan.fragmentUniforms = uniformPlan(program.compiled.fragment, program: program, ctx: ctx, particle: particle)
        let frameVarying: Set<String> = ["g_Time", "g_Daytime", "g_TexelSize", "g_TexelSizeHalf", "g_Screen",
                                         "g_PointerPosition", "g_PointerPositionLast", "g_PointerState",
                                         "g_ParallaxPosition", "g_EffectTextureProjectionMatrix",
                                         "g_EffectTextureProjectionMatrixInverse"]
        let uniformNames = (program.compiled.vertex.uniforms + program.compiled.fragment.uniforms).map(\.name)
        plan.usesAudio = uniformNames.contains { $0.hasPrefix("g_AudioSpectrum") }
        plan.particle = particle
        plan.isDynamic = particle || plan.usesAudio || uniformNames.contains { frameVarying.contains($0) }
            || sources.values.contains { if case .named = $0 { return true } else { return false } }
        plan.textureKey = textureKey
        plans[key] = plan
        return plan
    }

    var particleProjectionAdjustment: simd_float4x4?

    static let trace = ProcessInfo.processInfo.environment["WE_TRACE"] != nil

    func execute(_ plan: PassPlan, previous: LoadedTexture?, bindPrevious: LoadedTexture? = nil, target: MTLTexture, clear: Bool,
                 mvp: simd_float4x4, half: SIMD2<Float>, first: Bool,
                 particle: ParticleGeometry? = nil, particleValues: [String: [Float]] = [:]) throws {
        var mvp = mvp
        var particleValues = particleValues
        if let adjustment = particleProjectionAdjustment, particle != nil {
            mvp = adjustment * mvp
            if let values = particleValues["g_ViewProjectionMatrix"] {
                let columns = stride(from: 0, to: 16, by: 4).map { SIMD4(values[$0], values[$0 + 1], values[$0 + 2], values[$0 + 3]) }
                particleValues["g_ViewProjectionMatrix"] = (adjustment * simd_float4x4(columns)).flat
            }
        }
        if Self.trace {
            print("  pass \(plan.label) [\(plan.programKey)] -> \(target.label ?? "?") \(target.width)x\(target.height) clear=\(clear) inputs=\(plan.inputs.sorted { $0.key < $1.key }.map { "\($0.key):\($0.value)" })")
        }
        // Resolve this frame's inputs (render targets may be re-created on resize).
        var inputs: [Int: LoadedTexture] = [:]
        for (slot, src) in plan.inputs {
            switch src {
            case .fixed(let t): inputs[slot] = t
            case .previous: inputs[slot] = previous ?? white
            case .bindPrevious: inputs[slot] = bindPrevious ?? previous ?? white
            case .named(let n): inputs[slot] = try resolveTexture(n)
            }
        }
        let pipeline: MTLRenderPipelineState
        if let p = plan.pipelines[target.pixelFormat] {
            pipeline = p
        } else {
            var program = plan.program
            pipeline = try pipelineState(&program, blend: plan.blend, format: target.pixelFormat, key: plan.programKey, particle: plan.particle)
            plan.pipelines[target.pixelFormat] = pipeline
        }

        let tex0 = inputs[0] ?? white
        // Only the first pass samples the (padded) source texture; FBOs are exact-size.
        let uv = first ? tex0.imageSize / tex0.textureSize : SIMD2<Float>(1, 1)
        let verts: [Float] = [
            -half.x, half.y, 0, 0, 0,
            half.x, half.y, 0, uv.x, 0,
            -half.x, -half.y, 0, 0, uv.y,
            half.x, -half.y, 0, uv.x, uv.y,
        ]

        let enc = encoder(for: target, clear: clear ? MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0) : nil)
        enc.setRenderPipelineState(pipeline)
        if let particle {
            enc.setVertexBuffer(particle.vertices, offset: 0, index: Self.vertexBufferIndex)
            enc.setDepthClipMode(.clamp)
        } else { enc.setVertexBytes(verts, length: verts.count * 4, index: Self.vertexBufferIndex) }
        for (u, isVertex) in [(plan.vertexUniforms, true), (plan.fragmentUniforms, false)] {
            guard var u else { continue }
            for p in u.patches {
                let v: [Float]
                switch p.patch {
                case .particle(let name): v = particleValues[name] ?? []
                case .mvp: v = mvp.flat
                case .mvpInverse: v = mvp.inverse.flat
                case .time: v = [time]
                case .texelSize: v = [1 / outputSize.x, 1 / outputSize.y]
                case .texelSizeHalf: v = [0.5 / outputSize.x, 0.5 / outputSize.y]
                case .screen: v = [outputSize.x, outputSize.y, outputSize.x / outputSize.y]
                case .pointer: v = [pointer.position.x, pointer.position.y]
                case .pointerLast: let l = pointer.last ?? pointer.position; v = [l.x, l.y]
                case .pointerState: v = [pointer.state.x, pointer.state.y, pointer.state.z, pointer.state.w]
                case .parallaxPosition: v = [pointer.parallaxPosition.x, pointer.parallaxPosition.y]
                case .effectProjection: v = effectProjection.flat
                case .effectProjectionInverse: v = effectProjection.inverse.flat
                case .audio(let bands, let right):
                    let a = switch (bands, right) {
                        case (16, false): audio.left16
                        case (16, true): audio.right16
                        case (32, false): audio.left32
                        case (32, true): audio.right32
                        case (_, false): audio.left64
                        case (_, true): audio.right64
                    }
                    // float[n] arrays: one value per element at the array stride.
                    for (k, x) in a.enumerated() { write([x], type: p.type, at: p.offset + k * p.stride, into: &u.template) }
                    continue
                case .resolution(let i):
                    let t = inputs[i] ?? white
                    v = [t.textureSize.x, t.textureSize.y, t.imageSize.x, t.imageSize.y]
                }
                write(v, type: p.type, at: p.offset, into: &u.template)
            }
            u.template.withUnsafeBytes { b in
                if isVertex { enc.setVertexBytes(b.baseAddress!, length: b.count, index: u.bufferIndex) }
                else { enc.setFragmentBytes(b.baseAddress!, length: b.count, index: u.bufferIndex) }
            }
        }
        for b in plan.bindings {
            let t = inputs[b.slot] ?? white
            if t.texture === target { warn("\(plan.label): reads its own target") }
            if b.isVertex {
                enc.setVertexTexture(t.texture, index: b.texture)
                enc.setVertexSamplerState(sampler(clamp: t.clamp), index: b.sampler)
            } else {
                enc.setFragmentTexture(t.texture, index: b.texture)
                enc.setFragmentSamplerState(sampler(clamp: t.clamp), index: b.sampler)
            }
        }
        if let particle {
            enc.drawIndexedPrimitives(type: .triangle, indexCount: particle.count, indexType: .uint32,
                                      indexBuffer: particle.indices, indexBufferOffset: 0)
            enc.setDepthClipMode(.clip)
        } else { enc.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4) }
    }

    // MARK: - encoders

    /// The open render encoder is reused while consecutive draws load (not clear) the same target.
    var currentEncoder: MTLRenderCommandEncoder?
    weak var currentTarget: MTLTexture?

    func encoder(for target: MTLTexture, clear: MTLClearColor?) -> MTLRenderCommandEncoder {
        if clear == nil, let enc = currentEncoder, currentTarget === target { return enc }
        endEncoding()
        let rp = MTLRenderPassDescriptor()
        rp.colorAttachments[0].texture = target
        rp.colorAttachments[0].loadAction = clear == nil ? .load : .clear
        if let clear { rp.colorAttachments[0].clearColor = clear }
        rp.colorAttachments[0].storeAction = .store
        let enc = commandBuffer.makeRenderCommandEncoder(descriptor: rp)!
        frameEncoders += 1
        if contentMode == .fit, target === sceneTarget { enc.setScissorRect(contentScissor) }
        currentEncoder = enc
        currentTarget = target
        return enc
    }

    func endEncoding() {
        currentEncoder?.endEncoding()
        currentEncoder = nil
        currentTarget = nil
    }

    /// Order: engine built-ins, then material constants, then object values, then annotation defaults.
    func value(for name: String, program: Program, ctx: DrawContext) -> [Float]? {
        switch name {
        case "g_ModelViewProjectionMatrix", "g_EffectModelViewProjectionMatrix": return ctx.mvp.flat
        case "g_ModelViewProjectionMatrixInverse": return ctx.mvp.inverse.flat
        case "g_ModelMatrix", "g_EffectModelMatrix": return ctx.model.flat
        case "g_ViewProjectionMatrix", "g_EffectTextureProjectionMatrix", "g_EffectTextureProjectionMatrixInverse":
            return matrix_identity_float4x4.flat
        case "g_NormalModelMatrix": return [1, 0, 0, 0, 1, 0, 0, 0, 1]
        case "g_Time": return [time]
        case "g_Daytime": return [0.5]
        case "g_PointerPosition", "g_PointerPositionLast": return [0.5, 0.5]
        case "g_Texture0Rotation": return [1, 0, 0, 1]
        case "g_Texture0Translation": return [0, 0]
        case "g_TexelSize": return [1 / outputSize.x, 1 / outputSize.y]
        case "g_TexelSizeHalf": return [0.5 / outputSize.x, 0.5 / outputSize.y]
        case "g_Screen": return [outputSize.x, outputSize.y, outputSize.x / outputSize.y]
        case "g_TextureReductionScale": return [1]
        case "g_EyePosition": return [0, 0, 1]
        case "g_Frametime": return [1.0 / 30]
        case "g_PointerState": return [0]
        case "g_ParallaxPosition": return [0.5, 0.5]
        case "g_LightAmbientColor", "g_LightSkylightColor": return [0.3, 0.3, 0.3]
        case "g_RenderVar0": return [1, 0, 0, 0]
        // The font shader's MSDF outline / shadow parameters (unused by plain rasterized text).
        case "g_RenderVar1", "g_RenderVar2", "g_RenderVar3": return [0, 0, 0, 0]
        default: break
        }
        if name.hasPrefix("g_Texture"), name.hasSuffix("Resolution"), let i = Int(name.dropFirst(9).dropLast(10)) {
            let t = ctx.textures[i] ?? white
            return [t.textureSize.x, t.textureSize.y, t.imageSize.x, t.imageSize.y]
        }
        if name.hasPrefix("g_Texture"), name.hasSuffix("MipMapInfo") { return [0] }
        if name.hasPrefix("g_AudioSpectrum") { return [Float](repeating: 0, count: 64) }

        let annotation = program.annotations.first { $0.name == name }
        if let key = annotation?.material, let v = parseFloats(scene.properties.resolve(ctx.pass.constants[key])) {
            return v
        }
        if let annotation, let v = parseFloats(scene.properties.resolve(Self.legacyConstant(annotation, ctx.pass.constants))) {
            return v
        }
        if let l = ctx.layer {
            switch name {
            case "g_Brightness": return [l.brightness]
            case "g_UserAlpha", "g_Alpha": return [l.alpha]
            case "g_Color": return [l.color.x, l.color.y, l.color.z]
            // genericimage2 v2 (`#ifdef VERSION`) has no g_Brightness; object brightness (HDR overbright)
            // is assumed to be folded into the color. TODO: confirm against WE on Windows.
            case "g_Color4": return [l.color.x * l.brightness, l.color.y * l.brightness, l.color.z * l.brightness, l.alpha]
            default: break
            }
        }
        if let v = parseFloats(annotation?.defaultValue) { return v }
        switch name {
        case "g_Brightness", "g_UserAlpha", "g_Alpha": return [1]
        case "g_Color", "g_Color4", "g_CompositeColor": return [1, 1, 1, 1]
        default: return nil
        }
    }

    /// Older scenes key `constantshadervalues` by the uniform's former English label ("Tint high",
    /// "Pulse speed") instead of its material name; those labels survive in today's localization keys
    /// (`ui_editor_properties_tint_high`), so compare both ignoring case, spaces and underscores.
    static func legacyConstant(_ a: UniformAnnotation, _ constants: [String: Any]) -> Any? {
        func norm(_ s: String) -> String { s.lowercased().filter { $0.isLetter || $0.isNumber } }
        let names = Set([a.material, a.label.map { $0.replacingOccurrences(of: "ui_editor_properties_", with: "") }]
            .compactMap { $0 }.map(norm))
        return constants.first { names.contains(norm($0.key)) }?.value
    }

    func write(_ v: [Float], type: String, at offset: Int, into buf: inout [UInt8]) {
        let isInt = type.hasPrefix("int") || type.hasPrefix("ivec") || type.hasPrefix("uint")
        let count: Int = {
            switch type {
            case "mat4": return 16
            case "mat3": return 12 // 3 columns padded to vec4
            default: return Int(type.last.flatMap { Int(String($0)) } ?? 1)
            }
        }()
        var vals = v
        if type == "mat3", v.count == 9 { vals = [v[0], v[1], v[2], 0, v[3], v[4], v[5], 0, v[6], v[7], v[8], 0] }
        if vals.count == 1, count > 1 { vals = [Float](repeating: vals[0], count: count) }
        // vec4 given as color "r g b": alpha defaults to 1
        if type == "vec4", vals.count == 3 { vals.append(1) }
        for i in 0..<min(count, vals.count) {
            let o = offset + i * 4
            guard o + 4 <= buf.count else { return }
            var bits = isInt ? UInt32(bitPattern: Int32(vals[i])) : vals[i].bitPattern
            withUnsafeBytes(of: &bits) { for k in 0..<4 { buf[o + k] = $0[k] } }
        }
    }

    // MARK: - resources

    private func textureInput(_ name: String) throws -> PassPlan.Input {
        if name.hasPrefix("_rt_") || name.hasPrefix("$text:") { return .named(name) }
        let texture = try resolveTexture(name)
        return texture.video == nil && texture.animation == nil ? .fixed(texture) : .named(name)
    }

    func resolveTexture(_ name: String) throws -> LoadedTexture {
        switch name {
        case "_rt_FullFrameBuffer", "_rt_MipMappedFrameBuffer":
            return fullFrameCopy()
        case "util/white": return white
        case "util/black": return black
        default:
            if let t = scopedTargets[name] ?? layerComposites[name] { return t }
            if name.hasPrefix("_rt_") {
                guard let t = renderTargets[name] else { throw WEFormatError.unsupported("render target \(name)") }
                return t
            }
            if let t = textures[name] { return t }
            if name.hasPrefix("$file:") {
                guard !failedUserTextures.contains(name) else { throw WEFormatError.corrupt("user texture") }
                let url = URL(fileURLWithPath: String(name.dropFirst(6)))
                do {
                    let loaded: LoadedTexture
                    if ["mp4", "m4v", "mov", "webm"].contains(url.pathExtension.lowercased()) {
                        let video = try videoTextures[url] ?? VideoTexture(url: url, device: device)
                        loaded = try video.frame(at: Double(time), clamp: true, commandBuffer: commandBuffer)
                        videoTextures[url] = video
                    } else {
                        loaded = try AnimatedImageTexture(url: url).frame(at: Double(time), device: device)
                    }
                    textures[name] = loaded
                    return loaded
                } catch {
                    failedUserTextures.insert(name)
                    throw error
                }
            }
            let t = try TextureLoader.load(name, locator: locator, device: device,
                                           videos: &videoTextures, time: Double(time), commandBuffer: commandBuffer)
            textures[name] = t
            return t
        }
    }

    /// Copy of the scene target as rendered so far (WE's `_rt_FullFrameBuffer`).
    func fullFrameCopy() -> LoadedTexture {
        let existing = renderTargets["_rt_FullFrameBuffer"]
        if let existing, fullFrameValid { return existing }
        let copy = existing ?? wrap(pooledTarget("_rt_FullFrameBuffer", sceneTarget.width, sceneTarget.height), clamp: true)
        endEncoding()
        let blit = commandBuffer.makeBlitCommandEncoder()!
        blit.copy(from: sceneTarget, to: copy.texture)
        blit.endEncoding()
        renderTargets["_rt_FullFrameBuffer"] = copy
        fullFrameValid = true
        return copy
    }

    var targetPool: [String: MTLTexture] = [:]
    func pooledTarget(_ tag: String, _ w: Int, _ h: Int) -> MTLTexture {
        let key = "\(tag)|\(w)x\(h)"
        if let t = targetPool[key] { return t }
        let t = makeTarget(w, h)
        t.label = key
        targetPool[key] = t
        return t
    }

    func makeTarget(_ w: Int, _ h: Int) -> MTLTexture {
        let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: colorFormat, width: w, height: h, mipmapped: false)
        d.usage = [.renderTarget, .shaderRead]
        d.storageMode = .private
        return device.makeTexture(descriptor: d)!
    }

    func wrap(_ t: MTLTexture, clamp: Bool = true) -> LoadedTexture {
        let s = SIMD2(Float(t.width), Float(t.height))
        return LoadedTexture(texture: t, textureSize: s, imageSize: s, clamp: clamp)
    }

    func solid(_ px: [UInt8]) -> LoadedTexture {
        let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba8Unorm, width: 1, height: 1, mipmapped: false)
        let t = device.makeTexture(descriptor: d)!
        t.replace(region: MTLRegionMake2D(0, 0, 1, 1), mipmapLevel: 0, withBytes: px, bytesPerRow: 4)
        return LoadedTexture(texture: t, textureSize: [1, 1], imageSize: [1, 1], clamp: false)
    }

    func sampler(clamp: Bool) -> MTLSamplerState {
        if let s = samplers[clamp] { return s }
        let d = MTLSamplerDescriptor()
        d.minFilter = .linear; d.magFilter = .linear; d.mipFilter = .linear
        d.sAddressMode = clamp ? .clampToEdge : .repeat
        d.tAddressMode = d.sAddressMode
        let s = device.makeSamplerState(descriptor: d)!
        samplers[clamp] = s
        return s
    }

    // MARK: - programs

    var rawAnnotationCache: [String: [UniformAnnotation]] = [:]
    func rawAnnotations(_ shader: String) throws -> [UniformAnnotation] {
        if let a = rawAnnotationCache[shader] { return a }
        let a = ShaderPreprocessor.scan(try locator.string("shaders/\(shader).vert")).uniforms
            + ShaderPreprocessor.scan(try locator.string("shaders/\(shader).frag")).uniforms
        rawAnnotationCache[shader] = a
        return a
    }

    func programKey(_ shader: String, _ combos: [String: Int]) -> String {
        shader + "|" + combos.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: ",")
    }

    func program(shader: String, combos: [String: Int]) throws -> Program {
        let key = programKey(shader, combos)
        if let p = programs[key] { return p }

        func source(_ ext: String) throws -> (String, String) {
            let rel = "shaders/\(shader).\(ext)"
            return (try locator.string(rel), (rel as NSString).deletingLastPathComponent)
        }
        let (vs, vdir) = try source("vert"), (fs, fdir) = try source("frag")
        // Combos are shared between stages: a combo declared in one applies to the other.
        let declared = ShaderPreprocessor.scan(vs).combos.merging(ShaderPreprocessor.scan(fs).combos) { a, _ in a }
        let overrides = declared.merging(combos) { _, b in b }
        guard let v = ShaderPreprocessor.process(vs, stage: .vertex, fileDirectory: vdir, locator: locator, overrides: overrides),
              let f = ShaderPreprocessor.process(fs, stage: .fragment, fileDirectory: fdir, locator: locator, overrides: overrides) else {
            throw WEFormatError.unsupported("\(shader): could not preprocess")
        }
        let compiled: CompiledProgram
        do {
            compiled = try ShaderCompiler.compile(vertex: v.source, fragment: f.source)
        } catch {
            // Retry with HLSL-leniency rewrites (implicit truncation, mismatched varying widths). Only on
            // failure, so shaders that already compile are never touched by the heuristics.
            let (vs2, fs2) = ShaderPreprocessor.reconcileVaryings(
                vertex: ShaderPreprocessor.fixImplicitTruncation(v.source),
                fragment: ShaderPreprocessor.fixImplicitTruncation(f.source))
            compiled = try ShaderCompiler.compile(vertex: vs2, fragment: fs2)
            warn("\(shader): compiled after compatibility rewrites")
        }
        let lib = { (msl: String) throws -> MTLFunction in
            let o = MTLCompileOptions()
            o.languageVersion = .version2_3
            return try self.device.makeLibrary(source: msl, options: o).makeFunction(name: "main0")!
        }
        for (n, _) in compiled.vertex.attributes where n != "a_Position" && n != "a_TexCoord" {
            if shader != "genericparticle" || !ParticleVertices.attributes.contains(where: { $0.name == n }) {
                warn("\(shader): vertex attribute \(n) not supplied")
            }
        }
        let t0 = CFAbsoluteTimeGetCurrent()
        let p = Program(compiled: compiled, vertexFunction: try lib(compiled.vertex.msl),
                        fragmentFunction: try lib(compiled.fragment.msl), annotations: v.uniforms + f.uniforms)
        ShaderCompiler.timings["metal makeLibrary", default: 0] += CFAbsoluteTimeGetCurrent() - t0
        programs[key] = p
        return p
    }

    func pipelineState(_ program: inout Program, blend: String, format: MTLPixelFormat, key: String, particle: Bool = false) throws -> MTLRenderPipelineState {
        let mode = ["translucent", "additive"].contains(blend) ? blend : "normal"
        if !["normal", "translucent", "additive", "disabled"].contains(blend) {
            warn("blending '\(blend)' treated as normal")
        }
        let pkey = "\(mode)|\(format.rawValue)" + (particle ? "|particle" : "")
        if let p = program.pipelines[pkey] { return p }

        let pd = MTLRenderPipelineDescriptor()
        pd.vertexFunction = program.vertexFunction
        pd.fragmentFunction = program.fragmentFunction
        pd.colorAttachments[0].pixelFormat = format
        let vd = MTLVertexDescriptor()
        if let a = program.compiled.vertex.attributes["a_Position"] {
            vd.attributes[a].format = .float3; vd.attributes[a].offset = 0; vd.attributes[a].bufferIndex = Self.vertexBufferIndex
        }
        if let a = program.compiled.vertex.attributes["a_TexCoord"] {
            vd.attributes[a].format = .float2; vd.attributes[a].offset = 12; vd.attributes[a].bufferIndex = Self.vertexBufferIndex
        }
        vd.layouts[Self.vertexBufferIndex].stride = 20
        pd.vertexDescriptor = particle ? Self.particleVertexDescriptor(attributes: program.compiled.vertex.attributes) : vd

        let a = pd.colorAttachments[0]!
        a.isBlendingEnabled = mode != "normal"
        switch mode {
        case "translucent":
            a.sourceRGBBlendFactor = .sourceAlpha; a.destinationRGBBlendFactor = .oneMinusSourceAlpha
            a.sourceAlphaBlendFactor = .one; a.destinationAlphaBlendFactor = .oneMinusSourceAlpha
        case "additive":
            a.sourceRGBBlendFactor = .sourceAlpha; a.destinationRGBBlendFactor = .one
            a.sourceAlphaBlendFactor = .zero; a.destinationAlphaBlendFactor = .one
        default: break
        }
        let state = try device.makeRenderPipelineState(descriptor: pd)
        program.pipelines[pkey] = state
        programs[key] = program
        return state
    }

    // MARK: - output

    /// Pixel-centre coverage of the projected canvas, shared by scene draws and bar clears.
    var contentScissor: MTLScissorRect {
        let visible = contentVisibleSize(canvas: scene.canvas, output: outputSize, mode: .fit)
        let inset = (outputSize - scene.canvas / visible * outputSize) / 2
        let x = max(0, Int(ceil(inset.x - 0.5))), y = max(0, Int(ceil(inset.y - 0.5)))
        let right = min(Int(outputSize.x), Int(ceil(outputSize.x - inset.x - 0.5)))
        let bottom = min(Int(outputSize.y), Int(ceil(outputSize.y - inset.y - 0.5)))
        return MTLScissorRect(x: x, y: y, width: right - x, height: bottom - y)
    }

    var barPipeline: MTLRenderPipelineState?
    func clearFitBars() throws {
        if barPipeline == nil {
            let source = """
            #include <metal_stdlib>
            using namespace metal;
            vertex float4 bar_vs(uint id [[vertex_id]]) {
                float2 p = float2((id << 1) & 2, id & 2);
                return float4(p * 2 - 1, 0, 1);
            }
            fragment float4 bar_fs(constant float3 &color [[buffer(0)]]) { return float4(color, 1); }
            """
            let library = try device.makeLibrary(source: source, options: nil)
            let descriptor = MTLRenderPipelineDescriptor()
            descriptor.vertexFunction = library.makeFunction(name: "bar_vs")
            descriptor.fragmentFunction = library.makeFunction(name: "bar_fs")
            descriptor.colorAttachments[0].pixelFormat = sceneTarget.pixelFormat
            barPipeline = try device.makeRenderPipelineState(descriptor: descriptor)
        }
        let enc = encoder(for: sceneTarget, clear: nil)
        enc.setRenderPipelineState(barPipeline!)
        var color = barColor
        enc.setFragmentBytes(&color, length: MemoryLayout<SIMD3<Float>>.stride, index: 0)
        let r = contentScissor, w = Int(outputSize.x), h = Int(outputSize.y)
        let bars = [MTLScissorRect(x: 0, y: 0, width: w, height: r.y),
                    MTLScissorRect(x: 0, y: r.y + r.height, width: w, height: h - r.y - r.height),
                    MTLScissorRect(x: 0, y: r.y, width: r.x, height: r.height),
                    MTLScissorRect(x: r.x + r.width, y: r.y, width: w - r.x - r.width, height: r.height)]
        for bar in bars where bar.width > 0 && bar.height > 0 {
            enc.setScissorRect(bar)
            enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        }
        enc.setScissorRect(r)
    }

    func readback(_ t: MTLTexture) throws -> CGImage { try readbackImage(t, device: device, queue: queue) }
}

// MARK: - math

/// Canvas-space extent visible through the output, including bars for fit.
func contentVisibleSize(canvas: SIMD2<Float>, output: SIMD2<Float>, mode: ContentMode) -> SIMD2<Float> {
    if mode == .stretch { return canvas }
    let ratios = output / canvas
    let scale = mode == .fill ? max(ratios.x, ratios.y) : min(ratios.x, ratios.y)
    return output / scale
}

/// Pure projection math: canvas coordinates are y-up; output clip coordinates span -1...1.
func contentProjection(canvas: SIMD2<Float>, output: SIMD2<Float>, mode: ContentMode) -> simd_float4x4 {
    let visible = contentVisibleSize(canvas: canvas, output: output, mode: mode)
    let lo = (canvas - visible) / 2, hi = lo + visible
    return ortho(left: lo.x, right: hi.x, bottom: lo.y, top: hi.y)
}

func ortho(left l: Float, right r: Float, bottom b: Float, top t: Float) -> simd_float4x4 {
    simd_float4x4(columns: (SIMD4(2 / (r - l), 0, 0, 0), SIMD4(0, 2 / (t - b), 0, 0), SIMD4(0, 0, -1, 0),
                            SIMD4(-(r + l) / (r - l), -(t + b) / (t - b), 0, 1)))
}

func translation(_ v: SIMD3<Float>) -> simd_float4x4 {
    var m = matrix_identity_float4x4
    m.columns.3 = SIMD4(v.x, v.y, v.z, 1)
    return m
}

func scaling(_ v: SIMD3<Float>) -> simd_float4x4 { simd_float4x4(diagonal: SIMD4(v.x, v.y, v.z, 1)) }

func rotationZ(_ a: Float) -> simd_float4x4 {
    let c = cos(a), s = sin(a)
    return simd_float4x4(columns: (SIMD4(c, s, 0, 0), SIMD4(-s, c, 0, 0), SIMD4(0, 0, 1, 0), SIMD4(0, 0, 0, 1)))
}

extension simd_float4x4 {
    /// Column-major floats, matching the MSL float4x4 layout.
    var flat: [Float] { [columns.0, columns.1, columns.2, columns.3].flatMap { [$0.x, $0.y, $0.z, $0.w] } }
}
