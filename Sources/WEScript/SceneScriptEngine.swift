import Foundation
import JavaScriptCore
import simd

/// One scene, one JSContext. Create and use this object on a single thread (no main-thread requirement).
public final class SceneScriptEngine {
    /// Unowned: the host (the renderer) owns the engine.
    private unowned let host: SceneScriptHost
    private let context: JSContext
    private var runtime: JSValue!
    private var vectors: [Int: JSValue] = [:]
    private let storageURL: URL?
    private var storageErrorLogged = false
    /// localStorage contents waiting to be written; scripts may set values every frame, so writes are batched.
    private var pendingStorage: String?
    private var lastStorageWrite = Date.distantPast

    public init(host: SceneScriptHost, userProperties: [String: Any], canvasSize: SIMD2<Double>,
                storageURL: URL?, fixedClock: Date? = nil, screenResolution: SIMD2<Double>? = nil) {
        self.host = host
        self.storageURL = storageURL
        context = JSContext()!
        let bridge: @convention(block) (String, Int, String, JSValue) -> JSValue? = { [weak self] op, id, key, value in
            self?.bridge(op, id: id, key: key, value: value)
        }
        context.setObject(bridge, forKeyedSubscript: "__weBridge" as NSString)
        context.exceptionHandler = { [weak self] _, exception in
            self?.host.log(.error, "SceneScript runtime: \(exception?.toString() ?? "Unknown JavaScript exception")")
        }
        // This is a packaged, trusted resource, not wallpaper source.
        let url = Bundle.module.url(forResource: "Runtime", withExtension: "js")!
        runtime = context.evaluateScript(try! String(contentsOf: url), withSourceURL: url)
        for n in 2...4 { vectors[n] = context.objectForKeyedSubscript("Vec\(n)") }
        var saved = "{}"
        if let storageURL, FileManager.default.fileExists(atPath: storageURL.path) {
            do {
                let data = try Data(contentsOf: storageURL)
                guard (try JSONSerialization.jsonObject(with: data)) is [String: Any],
                      let string = String(data: data, encoding: .utf8) else {
                    throw CocoaError(.fileReadCorruptFile)
                }
                saved = string
            } catch { host.log(.warn, "SceneScript storage read: \(error.localizedDescription)") }
        }
        runtime.invokeMethod("configure", withArguments: [userProperties, encode(.vec2(canvasSize)),
            fixedClock.map { $0.timeIntervalSince1970 * 1000 } as Any? ?? NSNull(), saved, encode(.vec2(screenResolution ?? canvasSize))])
    }

    @discardableResult
    public func addScript(object: Int, path: String, source: String, scriptProperties: [String: Any] = [:],
                          initialValue: ScriptValue) -> ScriptValue {
        let label = "\(host.objectName(object) ?? String(object)).\(path)"
        do {
            let transformed = try ModuleTransform.wrap(source)
            // Syntax errors are handled here with the same object/path attribution as runtime errors.
            context.exceptionHandler = { _, _ in }
            context.exception = nil
            let factory = context.evaluateScript(transformed)
            let exception = context.exception
            context.exception = nil
            context.exceptionHandler = { [weak self] _, error in
                self?.host.log(.error, "SceneScript runtime: \(error?.toString() ?? "Unknown exception")")
            }
            if let exception { host.log(.error, "\(label): \(exception.toString() ?? "Syntax error")"); return initialValue }
            guard let factory, !factory.isUndefined else { return initialValue }
            let result = runtime.invokeMethod("add", withArguments: [object, path, factory, scriptProperties, encode(initialValue), label])
            return result.flatMap(decode) ?? initialValue
        } catch { host.log(.error, "\(label): \(error)"); return initialValue }
    }

    public func update(frameTime: Double, runtime time: Double, date: Date, cursorWorld: SIMD3<Double>,
                       audio: (left: [Float], right: [Float])? = nil) {
        runtime.invokeMethod("tick", withArguments: [frameTime, time, date.timeIntervalSince1970 * 1000,
            encode(.vec3(cursorWorld)), audio?.left ?? [], audio?.right ?? []])
        if pendingStorage != nil, Date().timeIntervalSince(lastStorageWrite) >= 1 { flushStorage() }
    }

    /// Writes pending localStorage changes (at most once a second during updates, and on deinit).
    public func flushStorage() {
        guard let contents = pendingStorage, let storageURL else { return }
        pendingStorage = nil
        lastStorageWrite = Date()
        do { try Data(contents.utf8).write(to: storageURL, options: .atomic) }
        catch {
            if !storageErrorLogged { storageErrorLogged = true; host.log(.warn, "SceneScript storage write: \(error.localizedDescription)") }
        }
    }

    deinit { flushStorage() }

    /// A patch of changed user values; unchanged values are retained in engine.userProperties.
    public func userPropertiesChanged(_ values: [String: Any]) { runtime.invokeMethod("users", withArguments: [values]) }

    /// nil broadcasts to all property scripts; an object ID dispatches only to that layer's scripts.
    public func cursorEvent(_ kind: CursorEvent, object: Int?, world: SIMD3<Double>) {
        event(kind.rawValue, object: object, values: ["worldPosition": encode(.vec3(world))])
    }

    public func mediaPropertiesChanged(title: String, artist: String, albumTitle: String,
                                       albumArtist: String = "", genre: String = "", trackNumber: Int = 0) {
        event("mediaPropertiesChanged", values: ["title": title, "artist": artist, "albumTitle": albumTitle,
              "albumArtist": albumArtist, "genre": genre, "trackNumber": trackNumber])
    }
    public func mediaPlaybackChanged(state: Int) { event("mediaPlaybackChanged", values: ["state": state]) }
    public func mediaTimelineChanged(position: Double, duration: Double) {
        event("mediaTimelineChanged", values: ["position": position, "duration": duration])
    }
    public func mediaThumbnailChanged(hasThumbnail: Bool, thumbnail: String = "",
                                      primaryColor: SIMD3<Double>, secondaryColor: SIMD3<Double>,
                                      tertiaryColor: SIMD3<Double>, textColor: SIMD3<Double>,
                                      highContrastColor: SIMD3<Double>) {
        event("mediaThumbnailChanged", values: ["hasThumbnail": hasThumbnail, "thumbnail": thumbnail,
            "primaryColor": encode(.vec3(primaryColor)), "secondaryColor": encode(.vec3(secondaryColor)),
            "tertiaryColor": encode(.vec3(tertiaryColor)), "textColor": encode(.vec3(textColor)),
            "highContrastColor": encode(.vec3(highContrastColor))])
    }
    private func event(_ name: String, object: Int? = nil, values: [String: Any]) {
        runtime.invokeMethod("event", withArguments: [name, object as Any? ?? NSNull(), values])
    }

    private func encode(_ value: ScriptValue) -> JSValue {
        switch value {
        case .null: return JSValue(nullIn: context)
        case let .bool(v): return JSValue(bool: v, in: context)
        case let .number(v): return JSValue(double: v, in: context)
        case let .string(v): return JSValue(object: v, in: context)
        case let .vec2(v): return vectors[2]!.construct(withArguments: [v.x, v.y])
        case let .vec3(v): return vectors[3]!.construct(withArguments: [v.x, v.y, v.z])
        case let .vec4(v): return vectors[4]!.construct(withArguments: [v.x, v.y, v.z, v.w])
        }
    }
    private func decode(_ value: JSValue) -> ScriptValue? {
        if value.isUndefined { return nil }
        if value.isNull { return .null }
        if value.isBoolean { return .bool(value.toBool()) }
        if value.isNumber { return .number(value.toDouble()) }
        if value.isString { return .string(value.toString()) }
        guard value.isObject, let x = value.forProperty("x"), x.isNumber,
              let y = value.forProperty("y"), y.isNumber else { return nil }
        guard let z = value.forProperty("z"), z.isNumber else { return .vec2(.init(x.toDouble(), y.toDouble())) }
        guard let w = value.forProperty("w"), w.isNumber else { return .vec3(.init(x.toDouble(), y.toDouble(), z.toDouble())) }
        return .vec4(.init(x.toDouble(), y.toDouble(), z.toDouble(), w.toDouble()))
    }

    private func bridge(_ op: String, id: Int, key: String, value: JSValue) -> JSValue {
        func js(_ object: Any?) -> JSValue { JSValue(object: object ?? NSNull(), in: context) }
        switch op {
        case "get": return host.value(object: id, property: key).map(encode) ?? JSValue(undefinedIn: context)
        case "set":
            if let decoded = decode(value) { host.setValue(decoded, object: id, property: key) }
            else { context.exception = JSValue(newErrorFromMessage: "Unsupported property value for \(key)", in: context) }
        case "name": return js(host.objectName(id))
        case "find": return js(host.objectID(named: key))
        case "parent": return js(host.parentID(of: id))
        case "count": return js(host.objectIDs.count)
        case "index": return js(host.objectIDs.firstIndex(of: id) ?? -1)
        case "sort": host.sortLayer(object: id, index: Int(value.toInt32()))
        case "effect": return js(host.effectIndex(object: id, named: key))
        case "sceneGet": return host.sceneValue(key).map(encode) ?? JSValue(undefinedIn: context)
        case "sceneSet": if let decoded = decode(value) { host.setSceneValue(decoded, property: key) }
        case "matrix":
            let m = host.transformMatrix(object: id)
            return js((0..<4).flatMap { col in (0..<4).map { row in m[col][row] } })
        case "hasAnimation": return js(host.animation(object: id) != nil)
        case "animation":
            guard let animation = host.animation(object: id) else { return js(nil) }
            switch key {
            case "play": animation.play()
            case "pause": animation.pause()
            case "stop": animation.stop()
            case "isPlaying": return js(animation.isPlaying)
            case "frameCount": return js(animation.frameCount)
            case "frame": if value.isNull { return js(animation.frame) }; animation.frame = value.toDouble()
            case "rate": if value.isNull { return js(animation.rate) }; animation.rate = value.toDouble()
            default: break
            }
        case "sound": return js(host.soundCommand(object: id, key))
        case "log": host.log(ScriptLogLevel(rawValue: key) ?? .log, value.toString())
        case "storage": if storageURL != nil { pendingStorage = value.toString() }
        default: break
        }
        return JSValue(undefinedIn: context)
    }
}
