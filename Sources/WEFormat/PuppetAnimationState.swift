import simd

public final class PuppetAnimationState {
    public final class Track {
        public let token: Int
        public let animation: PuppetModel.Animation
        public private(set) var layer: PuppetModel.Layer
        public private(set) var playing = true
        public private(set) var time: Double = 0
        public private(set) var envelope: Double
        private var controlled: Bool
        private var fadeStart: Double = 0
        private var fadeTarget: Double = 1
        private var fadeElapsed: Double = 0

        init(token: Int, animation: PuppetModel.Animation, layer: PuppetModel.Layer, created: Bool) {
            self.token = token; self.animation = animation; self.layer = layer; controlled = created
            envelope = layer.blendin && layer.blendtime > 0 ? 0 : 1
            fadeStart = envelope
        }

        public var name: String { layer.name.isEmpty ? animation.name : layer.name }
        public var frame: Double {
            let raw = time * Double(animation.fps), n = Double(animation.length)
            if animation.mode == .single { return min(max(raw, 0), n - 1) }
            let period = animation.mode == .mirror ? n * 2 : n
            return (raw.truncatingRemainder(dividingBy: period) + period).truncatingRemainder(dividingBy: period)
        }
        public func setFrame(_ frame: Double) {
            guard frame.isFinite else { return }
            controlled = true; time = frame / Double(animation.fps)
        }
        public func setRate(_ rate: Float) {
            guard rate.isFinite else { return }
            controlled = true; layer.rate = rate
        }
        public func setBlend(_ blend: Float) {
            guard blend.isFinite else { return }
            layer.blend = blend
        }
        public func setVisible(_ visible: Bool) { layer.visible = visible }
        public func play() {
            guard !playing else { return }
            controlled = true; playing = true
            fade(to: 1, enabled: layer.blendin)
        }
        public func pause() { controlled = true; playing = false }
        public func stop() {
            if !playing && time == 0 && fadeTarget == 0 { return }
            controlled = true; playing = false; time = 0
            if layer.blendout { fade(to: 0, enabled: true) }
            else { fadeStart = envelope; fadeTarget = envelope; fadeElapsed = 0 }
        }
        private func fade(to target: Double, enabled: Bool) {
            fadeStart = envelope; fadeTarget = target; fadeElapsed = 0
            if !enabled || layer.blendtime <= 0 { envelope = target; fadeStart = target }
        }
        func advance(to sceneTime: Double, delta: Double) {
            if controlled {
                if playing { time += delta * Double(layer.rate) }
                if playing || fadeTarget == 0 { fadeElapsed += max(0, delta) }
                if layer.blendtime > 0 {
                    envelope = fadeStart + (fadeTarget - fadeStart) * min(1, fadeElapsed / layer.blendtime)
                }
            } else {
                time = sceneTime * Double(layer.rate)
                fadeElapsed = max(0, sceneTime)
                envelope = layer.blendin && layer.blendtime > 0 ? min(1, max(0, sceneTime) / layer.blendtime) : 1
            }
        }
        var sample: PuppetModel.Layer {
            var result = layer
            result.blend *= Float(envelope)
            return result
        }
    }

    public let model: PuppetModel
    public private(set) var tracks: [Track] = []
    public private(set) var matrices: [simd_float4x4] = []
    private var nextToken = 0
    private var lastTime: Double = 0

    public init(model: PuppetModel, layers: [PuppetModel.Layer]) {
        self.model = model
        for layer in layers { _ = append(layer, created: false) }
        prepare(time: 0)
    }
    @discardableResult
    private func append(_ layer: PuppetModel.Layer, created: Bool) -> Track? {
        guard let animation = model.animations.first(where: { $0.id == layer.animation }) else { return nil }
        let track = Track(token: nextToken, animation: animation, layer: layer, created: created)
        nextToken += 1; tracks.append(track)
        return track
    }
    public func create(_ layer: PuppetModel.Layer) -> Track? { append(layer, created: true) }
    public func destroy(token: Int) -> Bool {
        guard let index = tracks.firstIndex(where: { $0.token == token }) else { return false }
        tracks.remove(at: index)
        return true
    }
    public func prepare(time: Double) {
        guard time.isFinite else { return }
        let delta = max(0, time - lastTime)
        for track in tracks { track.advance(to: time, delta: delta) }
        lastTime = time
        matrices = model.matrices(layers: tracks.map(\.sample), times: tracks.map(\.time))
    }
}
