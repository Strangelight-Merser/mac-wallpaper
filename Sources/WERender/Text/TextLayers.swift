import Metal
import WEFormat

/// Current text, rendered texture and box of one text layer.
struct TextLayerState {
    let rasterizer: TextRasterizer
    var string: String?
    var size = SIMD2<Float>(0, 0)
}

extension SceneRenderer {
    /// Text a layer shows this frame (its static value; scripts replace it through `setText`).
    func currentText(_ index: Int) -> String? {
        textOverrides[index] ?? scene.layers[index].text?.value
    }

    /// Re-renders text layers whose string changed and resizes their boxes. Call before any layer renders.
    func updateTextLayers() {
        for i in scene.layers.indices {
            guard let object = scene.layers[i].text, let string = currentText(i) else { continue }
            var state = textStates[i] ?? TextLayerState(rasterizer: TextRasterizer(object, locator: locator))
            guard state.string != string else { continue }
            let raster = state.rasterizer.render(string)
            state.string = string
            state.size = SIMD2(Float(raster.width), Float(raster.height))
            textStates[i] = state
            let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .r8Unorm, width: raster.width,
                                                             height: raster.height, mipmapped: true)
            d.usage = .shaderRead
            let texture = device.makeTexture(descriptor: d)!
            texture.label = "text \(scene.layers[i].name)"
            raster.coverage.withUnsafeBytes {
                texture.replace(region: MTLRegionMake2D(0, 0, raster.width, raster.height), mipmapLevel: 0,
                                withBytes: $0.baseAddress!, bytesPerRow: raster.width)
            }
            endEncoding()
            let blit = commandBuffer.makeBlitCommandEncoder()!
            blit.generateMipmaps(for: texture)
            blit.endEncoding()
            let name = SceneDescription.textTextureName(id: scene.layers[i].id)
            textures[name] = LoadedTexture(texture: texture, textureSize: state.size, imageSize: state.size,
                                           clamp: true, formatCode: 9)
            // The box size changed: drop everything sized or rendered from the old text.
            layerSizes[i] = state.size
            layerCaches[i] = nil
            effectTargets = effectTargets.filter { !$0.key.hasPrefix("L\(i).E") }
        }
    }

    /// Box centre relative to the text object's origin (object space).
    func textOffset(_ index: Int) -> SIMD3<Float> {
        guard let object = scene.layers[index].text, let state = textStates[index] else { return .zero }
        let o = object.boxOffset(state.size)
        return SIMD3(o.x, o.y, 0)
    }
}
