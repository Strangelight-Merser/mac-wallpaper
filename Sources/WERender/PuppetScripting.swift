import Foundation
import WEFormat

extension PuppetAnimationState {
    func command(_ command: String, arguments: [String: Any]) -> Any? {
        func index(_ value: Any?) -> Int? {
            guard let n = value as? NSNumber, CFGetTypeID(n) != CFBooleanGetTypeID(),
                  n.doubleValue.isFinite, n.doubleValue >= 0, n.doubleValue < Double(Int.max),
                  n.doubleValue.rounded(.towardZero) == n.doubleValue else { return nil }
            return n.intValue
        }
        func at(_ value: Any?) -> Track? {
            guard let i = index(value), tracks.indices.contains(i) else { return nil }
            return tracks[i]
        }
        switch command {
        case "count": return tracks.count
        case "find":
            if let name = arguments["selector"] as? String { return tracks.first { $0.name == name }?.token }
            return at(arguments["selector"])?.token
        case "create":
            let value = arguments["animation"]
            let options = value as? [String: Any] ?? [:]
            let selector = options["animation"] ?? value
            let animation = model.animations.first { animation in
                if let name = selector as? String { return animation.name == name }
                return index(selector) == animation.id
            }
            guard let animation else { return nil }
            func number(_ key: String, _ fallback: Double) -> Double {
                guard let n = options[key] as? NSNumber, n.doubleValue.isFinite,
                      Float(n.doubleValue).isFinite else { return fallback }
                return n.doubleValue
            }
            return create(.init(animation: animation.id, rate: Float(number("rate", 1)),
                                blend: Float(number("blend", 1)), visible: options["visible"] as? Bool ?? true,
                                id: index(options["id"]), name: options["name"] as? String ?? "",
                                additive: options["additive"] as? Bool ?? false,
                                blendin: options["blendin"] as? Bool ?? false,
                                blendout: options["blendout"] as? Bool ?? false,
                                blendtime: max(0, number("blendtime", 0))))?.token
        case "destroy":
            guard let token = index(arguments["token"]) ?? at(arguments["index"])?.token else { return false }
            return destroy(token: token)
        default: break
        }
        guard let token = index(arguments["token"]), let track = tracks.first(where: { $0.token == token }) else { return nil }
        let value = arguments["value"]
        switch command {
        case "name": return track.name
        case "frameCount": return track.animation.length
        case "fps": return track.animation.fps
        case "duration": return Double(track.animation.length) / Double(track.animation.fps)
        case "play": track.play()
        case "pause": track.pause()
        case "stop": track.stop()
        case "isPlaying": return track.playing
        case "frame":
            if let n = value as? NSNumber { track.setFrame(n.doubleValue) }
            else { return track.frame }
        case "rate":
            if let n = value as? NSNumber { track.setRate(n.floatValue) }
            else { return track.layer.rate }
        case "blend":
            if let n = value as? NSNumber { track.setBlend(n.floatValue) }
            else { return track.layer.blend }
        case "visible":
            if let b = value as? Bool { track.setVisible(b) }
            else { return track.layer.visible }
        default: break
        }
        return nil
    }
}

extension SceneRenderer {
    func preparePuppetAnimations() {
        for layer in scene.layers {
            guard let model = layer.puppet else { continue }
            if puppetAnimations[layer.id] == nil {
                puppetAnimations[layer.id] = PuppetAnimationState(model: model, layers: layer.animationLayers)
            }
            puppetAnimations[layer.id]?.prepare(time: Double(time))
        }
    }

    public func animationLayerCommand(object: Int, command: String, arguments: [String: Any]) -> Any? {
        puppetAnimations[object]?.command(command, arguments: arguments)
    }
}
