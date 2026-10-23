// Sprite vertex packing and uniforms ported from linux-wallpaperengine CParticle.cpp.
import Foundation
import Metal
import simd
import WEFormat
import WEShader

/// The packed 17-float genericparticle layout; kept independent of Metal for CPU tests.
enum ParticleVertices {
    static let stride = 17
    static let attributes: [(name: String, offset: Int, components: Int)] = [
        ("a_Position", 0, 3), ("a_TexCoordVec4", 3, 4), ("a_Color", 7, 4),
        ("a_TexCoordVec4C1", 11, 4), ("a_TexCoordC2", 15, 2)]

    static func build(_ particles: [ParticleState], sheet: ParticleSpriteSheet?, mode: String, multiplier: Float,
                      trail: Bool, into vertices: inout [Float]) {
        vertices.removeAll(keepingCapacity: true)
        vertices.reserveCapacity(particles.count * 4 * stride)
        for p in particles {
            guard p.age < p.lifetime, p.size > 0, p.size.isFinite,
                  p.position.isFinite, p.velocity.isFinite, p.rotation.isFinite, p.color.isFinite,
                  p.alpha.isFinite, p.life.isFinite, !trail || simd_length_squared(p.velocity) > 0.000001 else { continue }
            let phase: Float
            if let sheet {
                let frame = sheet.frame(age: p.age, lifetime: p.lifetime, random: p.random, mode: mode, multiplier: multiplier)
                phase = (frame + (mode == "randomframe" ? 0.5 : 0)) / Float(sheet.count)
            } else { phase = p.life }
            for uv: SIMD2<Float> in [[0, 1], [1, 1], [1, 0], [0, 0]] {
                vertices.append(contentsOf: [p.position.x, p.position.y, p.position.z, uv.x, uv.y, p.rotation.z, p.size,
                    p.color.x, p.color.y, p.color.z, p.alpha, p.velocity.x, p.velocity.y, p.velocity.z, phase,
                    p.rotation.x, p.rotation.y])
            }
        }
    }
}

private extension SIMD3 where Scalar == Float {
    var isFinite: Bool { x.isFinite && y.isFinite && z.isFinite }
}

struct ParticleGeometry {
    let vertices: MTLBuffer
    let indices: MTLBuffer
    let count: Int
}

/// Each slot is owned until its command buffer completes, even with more than three frames queued.
final class ParticleFrameRing {
    private let slots = (0..<3).map { _ in DispatchSemaphore(value: 1) }
    private var next = 0
    func acquire(_ commandBuffer: MTLCommandBuffer) -> Int {
        let slot = next
        next = (next + 1) % slots.count
        let semaphore = slots[slot]
        semaphore.wait()
        commandBuffer.addCompletedHandler { _ in semaphore.signal() }
        return slot
    }
}

final class ParticleRenderState {
    let simulation: ParticleSimulation
    var vertices: [Float] = []
    var buffers: [[MTLBuffer?]] = []
    init(_ description: ParticleSystemDescription, simulation: ParticleSimulation? = nil) {
        self.simulation = simulation ?? ParticleSimulation(description)
        buffers = Array(repeating: Array(repeating: nil, count: 3), count: description.renderers.count * description.passes.count)
    }
}

extension SceneRenderer {
    /// Reuse the simulation tree for the scene's flattened draw list.
    func particleState(_ index: Int) -> ParticleRenderState {
        if let state = particleStates[index] { return state }
        let d = scene.particles[index]
        let parent = scene.particles.indices.first { i in scene.particles[i].children.contains { $0.seed == d.seed } }
        let simulation: ParticleSimulation
        if let parent {
            simulation = particleState(parent).simulation.children.first { $0.description.seed == d.seed }!
        } else { simulation = ParticleSimulation(d) }
        let state = ParticleRenderState(d, simulation: simulation)
        particleStates[index] = state
        return state
    }

    func advanceParticle(_ index: Int, projection: simd_float4x4) {
        let d = scene.particles[index]
        if d.childType != .static,
           let parent = scene.particles.indices.first(where: { i in scene.particles[i].children.contains { $0.seed == d.seed } }) {
            advanceParticle(parent, projection: projection)
            return
        }
        let state = particleState(index)
        let mouse = projection.inverse * SIMD4(pointer.position.x * 2 - 1, 1 - pointer.position.y * 2, 0, 1)
        func update(_ simulation: ParticleSimulation) {
            let d = simulation.description
            var model = d.parentTransform * particleTransform(origin: d.origin, angles: d.angles, scale: d.scale)
            if scene.parallax.enabled {
                let offset = (d.parallaxDepth + scene.parallax.amount) * pointer.parallax * scene.canvas.x
                model = translation([offset.x, offset.y, 0]) * model
            }
            simulation.updateControlPoints(model: model, pointer: [mouse.x, mouse.y, 0])
            simulation.children.forEach(update)
        }
        update(state.simulation)
        if offlineParticles { state.simulation.advance(to: time) }
        else { state.simulation.advanceLive(to: time) }
    }

    func renderParticle(_ index: Int, projection: simd_float4x4, slot: Int) throws {
        let d = scene.particles[index]
        guard d.visible, d.canRender, onlyLayers?.contains(d.name) ?? true,
              scene.nodes[d.id] == nil || isVisible(d.id) else { return }
        let state = particleState(index)
        advanceParticle(index, projection: projection)
        let viewProjection = d.flags & 4 == 0 ? projection : particlePerspective(canvas: scene.canvas, output: outputSize,
            fov: scene.particleCamera.fov, near: scene.particleCamera.near, far: scene.particleCamera.far)
        var model = d.parentTransform * particleTransform(origin: d.origin, angles: d.angles, scale: d.scale)
        if scene.parallax.enabled {
            let offset = (d.parallaxDepth + scene.parallax.amount) * pointer.parallax * scene.canvas.x
            model = translation([offset.x, offset.y, 0]) * model
        }
        for (r, style) in d.renderers.enumerated() {
            for (i, material) in d.passes.enumerated() {
                let bufferIndex = r * d.passes.count + i
                let textureName = material.textures.first ?? nil
                let sprite = try particleTexture(textureName)
                if let history = state.simulation.histories[r] {
                    ParticleRopeVertices.build(state.simulation.particles, history: history,
                                               time: Float(state.simulation.time), into: &state.vertices)
                } else {
                    ParticleVertices.build(state.simulation.particles, sheet: sprite.sheet, mode: d.animationMode,
                                       multiplier: d.sequenceMultiplier, trail: style.trail, into: &state.vertices)
                }
                let count = state.vertices.count / (4 * (style.rope ? ParticleRopeVertices.stride : ParticleVertices.stride))
                guard count > 0 else { continue }
                let bytes = state.vertices.count * MemoryLayout<Float>.stride
                if (state.buffers[bufferIndex][slot]?.length ?? 0) < bytes {
                    state.buffers[bufferIndex][slot] = device.makeBuffer(length: max(bytes, (state.buffers[bufferIndex][slot]?.length ?? 1024) * 2), options: .storageModeShared)
                }
                guard let buffer = state.buffers[bufferIndex][slot] else { throw WEFormatError.unsupported("particle vertex buffer allocation") }
                state.vertices.withUnsafeBytes { buffer.contents().copyMemory(from: $0.baseAddress!, byteCount: $0.count) }
                let indices = try particleIndices(count)
                var pass = material
                if style.rope { pass.shader = "genericropeparticle" }
                for name in ["GS_ENABLED", "LIGHTING", "DOUBLESIDEDLIGHTING", "FOG", "FOG_DIST", "FOG_HEIGHT", "REFRACT"] { pass.combos[name] = 0 }
                pass.combos["THICKFORMAT"] = 1
                pass.combos["TRAILRENDERER"] = style.trail ? 1 : 0
                pass.combos["SPRITESHEET"] = sprite.sheet == nil ? 0 : 1
                pass.combos["SPRITESHEETBLENDNPOT"] = 0
                if d.animationMode == "randomframe" { pass.combos["SPRITESHEETBLEND"] = 0 }
                if style.rope {
                    pass.combos["TRAILRENDERER"] = 0
                    pass.combos["TRAILSCROLLALPHA"] = 0
                    try prepareRopeProgram(pass, texture: sprite.texture)
                }
                let plan = try self.plan("P\(index).R\(r).\(i)", pass: pass, layer: nil, model: model,
                                         hasPrevious: false, particle: true, fixedTextures: [0: sprite.texture])
                let values: [String: [Float]] = [
                    "g_ModelMatrix": model.flat, "g_ModelMatrixInverse": model.inverse.flat,
                    "g_ViewProjectionMatrix": viewProjection.flat,
                    "g_OrientationUp": [0, 1, 0], "g_OrientationRight": [1, 0, 0], "g_OrientationForward": [0, 0, 1],
                    "g_ViewUp": [0, 1, 0], "g_ViewRight": [1, 0, 0], "g_EyePosition": [scene.canvas.x / 2, scene.canvas.y / 2, 1000],
                    "g_RenderVar0": [style.length, style.maxLength, style.minLength, 0],
                    "g_RenderVar1": [sprite.renderVar.x, sprite.renderVar.y, sprite.renderVar.z, sprite.renderVar.w]]
                try execute(plan, previous: nil, target: sceneTarget, clear: false, mvp: viewProjection * model,
                            half: [1, 1], first: false, particle: ParticleGeometry(vertices: buffer, indices: indices, count: count * 6),
                            particleValues: values)
                fullFrameValid = false
            }
        }
    }

    /// The stock GS-disabled rope shader has a missing pair of parentheses in its side offset.
    /// Compile the corrected particle-only source here, keeping shared shader loading untouched.
    func prepareRopeProgram(_ pass: SceneDescription.Pass, texture: LoadedTexture) throws {
        var combos = pass.combos.reduce(into: [String: Int]()) { $0[$1.key.uppercased()] = $1.value }
        for a in try rawAnnotations(pass.shader) where a.type.hasPrefix("sampler") {
            if let combo = a.combo, let slot = Int(a.name.dropFirst(9)), slot < pass.textures.count,
               (slot == 0 || pass.textures[slot] != nil), combos[combo.uppercased()] == nil {
                combos[combo.uppercased()] = 1
            }
        }
        combos["TEX0FORMAT"] = combos["TEX0FORMAT"] ?? texture.formatCode
        for (slot, name) in pass.textures.enumerated() where slot > 0 {
            if let name, !name.hasPrefix("_rt_"), combos["TEX\(slot)FORMAT"] == nil {
                combos["TEX\(slot)FORMAT"] = try resolveTexture(name).formatCode
            }
        }
        let key = programKey(pass.shader, combos)
        guard programs[key] == nil else { return }
        let vs = try locator.string("shaders/genericropeparticle.vert")
            .replacingOccurrences(of: "right * uvs.x * 2.0 - 1.0", with: "right * (uvs.x * 2.0 - 1.0)")
        let fs = try locator.string("shaders/genericropeparticle.frag")
        let declared = ShaderPreprocessor.scan(vs).combos.merging(ShaderPreprocessor.scan(fs).combos) { a, _ in a }
        let overrides = declared.merging(combos) { _, b in b }
        guard let v = ShaderPreprocessor.process(vs, stage: .vertex, fileDirectory: "shaders", locator: locator, overrides: overrides),
              let f = ShaderPreprocessor.process(fs, stage: .fragment, fileDirectory: "shaders", locator: locator, overrides: overrides) else {
            throw WEFormatError.unsupported("genericropeparticle: could not preprocess")
        }
        let compiled = try ShaderCompiler.compile(vertex: v.source, fragment: f.source)
        let options = MTLCompileOptions(); options.languageVersion = .version2_3
        guard let vertex = try device.makeLibrary(source: compiled.vertex.msl, options: options).makeFunction(name: "main0"),
              let fragment = try device.makeLibrary(source: compiled.fragment.msl, options: options).makeFunction(name: "main0") else {
            throw WEFormatError.unsupported("genericropeparticle: missing entry point")
        }
        programs[key] = Program(compiled: compiled, vertexFunction: vertex, fragmentFunction: fragment, annotations: v.uniforms + f.uniforms)
    }

    struct ParticleTexture {
        let texture: LoadedTexture
        let sheet: ParticleSpriteSheet?
        let renderVar: SIMD4<Float>
    }

    func particleTexture(_ name: String?) throws -> ParticleTexture {
        guard let name else { return ParticleTexture(texture: white, sheet: nil, renderVar: [0, 0, 0, 1]) }
        if let t = particleTextures[name] { return t }
        let texture: LoadedTexture, sheet: ParticleSpriteSheet?, renderVar: SIMD4<Float>
        if name == "util/white" || name == "util/black" {
            texture = try resolveTexture(name); sheet = nil; renderVar = [0, 0, 0, 1]
        } else {
            let tex = try Tex(data: locator.data("materials/\(name).tex"))
            if tex.frames.isEmpty {
                texture = try resolveTexture(name); sheet = nil
                renderVar = [0, 0, 0, texture.imageSize.y / texture.imageSize.x]
            } else {
                let atlas = try ParticleSpriteSheet.atlas(tex)
                let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba8Unorm, width: atlas.width, height: atlas.height, mipmapped: false)
                descriptor.usage = .shaderRead
                guard let t = device.makeTexture(descriptor: descriptor) else { throw WEFormatError.unsupported("particle atlas allocation") }
                atlas.pixels.withUnsafeBytes {
                    t.replace(region: MTLRegionMake2D(0, 0, atlas.width, atlas.height), mipmapLevel: 0, withBytes: $0.baseAddress!, bytesPerRow: atlas.width * 4)
                }
                texture = wrap(t)
                sheet = ParticleSpriteSheet(durations: tex.frames.map { max(0.0001, $0.frameTime) })
                renderVar = [1 / Float(atlas.columns), 1 / Float(atlas.rows), Float(tex.frames.count), Float(atlas.frameHeight) / Float(atlas.frameWidth)]
            }
        }
        let result = ParticleTexture(texture: texture, sheet: sheet, renderVar: renderVar)
        particleTextures[name] = result
        return result
    }

    func particleIndices(_ quads: Int) throws -> MTLBuffer {
        if let buffer = particleIndexBuffer, buffer.length >= quads * 6 * 4 { return buffer }
        let capacity = max(quads, (particleIndexBuffer?.length ?? 0) / 24 * 2)
        var indices: [UInt32] = []
        indices.reserveCapacity(capacity * 6)
        for i in 0..<capacity {
            let base = UInt32(i * 4)
            indices.append(contentsOf: [base, base + 1, base + 2, base + 2, base + 3, base])
        }
        guard let buffer = device.makeBuffer(bytes: indices, length: indices.count * 4, options: .storageModeShared) else {
            throw WEFormatError.unsupported("particle index buffer allocation")
        }
        particleIndexBuffer = buffer
        return buffer
    }

    static func particleVertexDescriptor(attributes: [String: Int]) -> MTLVertexDescriptor {
        let descriptor = MTLVertexDescriptor()
        let rope = attributes["a_PositionVec4"] != nil
        for item in rope ? ParticleRopeVertices.attributes : ParticleVertices.attributes {
            guard let index = attributes[item.name] else { continue }
            descriptor.attributes[index].format = item.components == 2 ? .float2 : item.components == 3 ? .float3 : .float4
            descriptor.attributes[index].offset = item.offset * 4
            descriptor.attributes[index].bufferIndex = vertexBufferIndex
        }
        descriptor.layouts[vertexBufferIndex].stride = (rope ? ParticleRopeVertices.stride : ParticleVertices.stride) * 4
        return descriptor
    }
}

/// Perspective billboards share the scene's y-up canvas and cover-fit viewport.
func particlePerspective(canvas: SIMD2<Float>, output: SIMD2<Float>, fov: Float, near: Float, far: Float) -> simd_float4x4 {
    let y = 1 / tan(fov * .pi / 360), x = y * canvas.y / canvas.x
    let z = far / (near - far)
    let projection = simd_float4x4(columns: (SIMD4(x, 0, 0, 0), SIMD4(0, y, 0, 0),
                                            SIMD4(0, 0, z, -1), SIMD4(0, 0, near * z, 0)))
    let cover = max(output.x / canvas.x, output.y / canvas.y)
    let fit = scaling([cover * canvas.x / output.x, cover * canvas.y / output.y, 1])
    return fit * projection * translation([-canvas.x / 2, -canvas.y / 2, -1000])
}
