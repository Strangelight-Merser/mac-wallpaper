import Metal
import WEFormat

struct PuppetGeometry {
    let model: PuppetModel
    let state: PuppetAnimationState
    let vertices: MTLBuffer
    let indices: MTLBuffer

    init(state: PuppetAnimationState, device: MTLDevice) throws {
        let model = state.model
        self.model = model
        self.state = state
        var words: [UInt32] = []
        for v in model.vertices {
            words += [v.position.x, v.position.y, v.position.z, v.uv.x, v.uv.y].map(\.bitPattern)
            words += [v.indices.x, v.indices.y, v.indices.z, v.indices.w]
            words += [v.weights.x, v.weights.y, v.weights.z, v.weights.w].map(\.bitPattern)
        }
        guard let vertices = device.makeBuffer(bytes: words, length: words.count * 4),
              !model.indices.isEmpty,
              let indices = device.makeBuffer(bytes: model.indices, length: model.indices.count * 2) else {
            throw WEFormatError.corrupt("puppet mesh buffer allocation")
        }
        self.vertices = vertices; self.indices = indices
    }
}
