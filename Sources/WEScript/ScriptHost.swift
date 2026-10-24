import Foundation
import simd

public enum ScriptValue: Equatable, Sendable {
    case null, bool(Bool), number(Double), string(String)
    case vec2(SIMD2<Double>), vec3(SIMD3<Double>), vec4(SIMD4<Double>)
}

public enum ScriptLogLevel: String, Sendable { case log, warn, error }
public enum CursorEvent: String, Sendable {
    case down = "cursorDown", up = "cursorUp", click = "cursorClick"
    case move = "cursorMove", enter = "cursorEnter", leave = "cursorLeave"
}

public protocol ScriptAnimationHost: AnyObject {
    func play()
    func pause()
    func stop()
    var isPlaying: Bool { get }
    var frame: Double { get set }
    var frameCount: Double { get }
    var rate: Double { get set }
}

/// All calls occur synchronously on the engine's owning thread. Property paths use scene.json spelling.
public protocol SceneScriptHost: AnyObject {
    func objectID(named name: String) -> Int?
    func objectName(_ id: Int) -> String?
    func parentID(of id: Int) -> Int?
    /// nil means absent (JS undefined); .null means explicit JS null. Return current values on every read.
    /// Effect paths are effects[i].…; material constants are [effects[i].]passes[j].constantshadervalues.name.
    func value(object: Int, property: String) -> ScriptValue?
    func setValue(_ value: ScriptValue, object: Int, property: String)
    func transformMatrix(object: Int) -> simd_double4x4
    func animationLayerCommand(object: Int, command: String, arguments: [String: Any]) -> Any?
    func animation(object: Int) -> ScriptAnimationHost?
    func log(_ level: ScriptLogLevel, _ message: String)
    // Required scene/effect operations absent from the original API sketch.
    /// IDs in current scene order, used by getLayerCount/getLayerIndex.
    var objectIDs: [Int] { get }
    func sortLayer(object: Int, index: Int)
    func effectIndex(object: Int, named name: String) -> Int?
    func sceneValue(_ property: String) -> ScriptValue?
    func setSceneValue(_ value: ScriptValue, property: String)
    /// Sound layers: "play", "stop", "pause" (result ignored) and "isPlaying".
    func soundCommand(object: Int, _ command: String) -> Bool
}

public extension SceneScriptHost {
    func animationLayerCommand(object: Int, command: String, arguments: [String: Any]) -> Any? { nil }
    func soundCommand(object: Int, _ command: String) -> Bool { false }
}

/// A raw scripted property. Static values remain untyped JSON so the renderer can apply its property schema.
public struct ScriptedProperty {
    public let path: String
    public let source: String
    public let scriptProperties: [String: Any]
    public let staticValue: Any?

    public static func discover(in object: [String: Any]) -> [ScriptedProperty] {
        var result: [ScriptedProperty] = []
        func visit(_ value: Any, _ path: String) {
            if let dictionary = value as? [String: Any] {
                if let source = dictionary["script"] as? String {
                    result.append(.init(path: path, source: source,
                                        scriptProperties: dictionary["scriptproperties"] as? [String: Any] ?? [:],
                                        staticValue: dictionary["value"]))
                    return
                }
                for key in dictionary.keys.sorted() {
                    visit(dictionary[key]!, path.isEmpty ? key : "\(path).\(key)")
                }
            } else if let array = value as? [Any] {
                for (index, item) in array.enumerated() { visit(item, "\(path)[\(index)]") }
            }
        }
        visit(object, "")
        return result
    }
}
