import AVFoundation
import Foundation
import WEFormat
import WERender
import WEVideo

/// Renderer capabilities that a wallpaper uses but cannot fully reproduce.
public enum Feature: String, Codable, Sendable, CaseIterable, CodingKeyRepresentable {
    case particles, text, model3D, puppetWarp, sound, light, sceneScript, videoTexture,
         missingEffect, shaderError, missingAsset, unsupportedVideoCodec, applicationWallpaper, unknownObject
}

/// A static assessment, optionally supplemented by a small rendered frame.
public struct Compatibility: Codable, Sendable, Equatable {
    public enum Status: String, Codable, Sendable { case supported, partial, unsupported, needsAssets }
    public var status: Status
    public var missing: [Feature: Int]
    public var notes: [String]
    public var checkedDeep: Bool
    public var checkerVersion: Int

    public init(status: Status, missing: [Feature: Int] = [:], notes: [String] = [],
                checkedDeep: Bool = false, checkerVersion: Int = CompatibilityChecker.version) {
        self.status = status; self.missing = missing; self.notes = notes
        self.checkedDeep = checkedDeep; self.checkerVersion = checkerVersion
    }
}

/// Checks local assets and unsupported features without needing a GPU for static checks.
public struct CompatibilityChecker: Sendable {
    public static let version = 6
    private let assets: URL?

    public init(assets: URL?) { self.assets = assets }

    /// Deep rendering is serialized across checker instances; web content remains statically checked.
    public func check(_ entry: WallpaperEntry, deep: Bool) async -> Compatibility {
        var result = Compatibility(status: .supported)
        let locator = AssetLocator(project: entry.folder, assets: assets)
        do {
            switch entry.type {
            case .application:
                return Compatibility(status: .unsupported, missing: [.applicationWallpaper: 1])
            case .unknown:
                return Compatibility(status: .unsupported, notes: ["unknown wallpaper type"])
            case .web:
                return locator.exists(entry.file) ? result : Compatibility(status: .unsupported,
                    missing: [.missingAsset: 1], notes: ["missing web page: \(entry.file)"])
            case .video:
                guard let url = locator.url(entry.file) else {
                    return Compatibility(status: .unsupported, missing: [.missingAsset: 1], notes: ["missing video: \(entry.file)"])
                }
                let codec: String
                if ["webm", "mkv"].contains(url.pathExtension.lowercased()) {
                    codec = try WebMFile(url: url).codecID
                    guard ["V_VP9", "V_AV1", "V_VP8"].contains(codec) else {
                        return Compatibility(status: .unsupported, missing: [.unsupportedVideoCodec: 1], notes: [codec])
                    }
                    if codec == "V_VP8" {
                        result.notes.append("VP8 uses WebKit; deep check skipped")
                        return result
                    }
                } else {
                    let asset = AVURLAsset(url: url)
                    guard let track = try await asset.loadTracks(withMediaType: .video).first else {
                        throw WEFormatError.unsupported("no video track")
                    }
                    let formats = try await track.load(.formatDescriptions)
                    let codecs = formats.map { description -> String in
                        let subtype = CMFormatDescriptionGetMediaSubType(description)
                        return String(bytes: [24, 16, 8, 0].map { UInt8((subtype >> $0) & 255) }, encoding: .ascii) ?? "?"
                    }
                    let supported: Set<String> = ["avc1", "hvc1", "hev1", "av01", "apco", "apcs", "apcn", "apch", "ap4h", "ap4x"]
                    guard !codecs.isEmpty, codecs.allSatisfy({ supported.contains($0) }) else {
                        return Compatibility(status: .unsupported, missing: [.unsupportedVideoCodec: 1], notes: codecs)
                    }
                }
            case .scene:
                guard assets != nil else { return Compatibility(status: .needsAssets, notes: ["WE assets directory required"]) }
                result = try checkScene(entry, locator: locator)
            }
        } catch {
            result.status = .unsupported
            result.missing[entry.type == .video ? .unsupportedVideoCodec : .missingAsset, default: 0] += 1
            result.notes.append(String(describing: error))
        }
        guard deep, !Task.isCancelled else { return result }
        return await DeepCheck.shared.check(entry, assets: assets, result: result)
    }

    private func checkScene(_ entry: WallpaperEntry, locator: AssetLocator) throws -> Compatibility {
        let raw = try locator.json(entry.file)
        let project = try locator.json("project.json")
        let props = UserProperties(project: project)
        var result = Compatibility(status: .supported)
        func add(_ feature: Feature) { result.missing[feature, default: 0] += 1 }
        // Scripts run; only the parts they use that are not supported yet show up (deep check warnings).
        for case let object as [String: Any] in raw["objects"] as? [Any] ?? [] {
            if object["particle"] != nil || object["text"] != nil || object["sound"] != nil { continue }
            guard let image = object["image"] as? String else {
                let kinds: [(String, Feature)] = [("model", .model3D), ("light", .light)]
                if let kind = kinds.first(where: { object[$0.0] != nil }) { add(kind.1) }
                // Objects with only a transform group their children.
                else if !object.isEmpty, object["origin"] == nil, object["parent"] == nil { add(.unknownObject) }
                continue
            }
            if let model = try? locator.json(image), model["puppet"] != nil { add(.puppetWarp) }
            for effect in object["effects"] as? [[String: Any]] ?? [] where props.bool(effect["visible"]) {
                guard let file = effect["file"] as? String else { add(.missingEffect); continue }
                do {
                    let definition = try locator.json(file)
                    for pass in definition["passes"] as? [[String: Any]] ?? [] {
                        if let material = pass["material"] as? String {
                            if (try? locator.json(material)) == nil {
                                add(.missingAsset); result.notes.append("missing effect material: \(material)")
                            }
                        }
                    }
                } catch { add(.missingEffect); result.notes.append("\(file): \(error)") }
            }
        }
        let scene: SceneDescription
        do { scene = try SceneDescription(project: entry.folder, locator: locator) }
        catch {
            add(.missingAsset); result.status = .unsupported; result.notes.append(String(describing: error))
            return result
        }
        result.notes += scene.notes
        var renderable = 0
        func checkPasses(_ passes: [SceneDescription.Pass]) -> Set<Feature> {
            var features = Set<Feature>()
            for pass in passes where pass.copy == nil {
                for ext in ["vert", "frag"] where !locator.exists("shaders/\(pass.shader).\(ext)") {
                    features.insert(.missingAsset)
                    result.notes.append("missing shader: \(pass.shader).\(ext)")
                }
                for (slot, texture) in pass.textures.enumerated() {
                    guard let name = texture, pass.binds[slot] == nil else { continue }
                    // `$text:` textures are rendered from the text object, not loaded.
                    if name.hasPrefix("_rt_") || name.hasPrefix("$text:") || ["util/white", "util/black"].contains(name) { continue }
                    do {
                        if try Tex.isVideo(data: locator.data("materials/\(name).tex")) {
                            features.insert(.videoTexture)
                        }
                    } catch { features.insert(.missingAsset); result.notes.append("\(name): \(error)") }
                }
            }
            return features
        }
        for layer in scene.layers {
            let features = checkPasses(layer.passes)
            features.forEach(add)
            if !layer.passes.isEmpty, features.isEmpty { renderable += 1 }
        }
        for particle in scene.particles {
            let features = checkPasses(particle.passes)
            features.forEach(add)
            if particle.notes.contains(where: { $0.contains(": particle ") && $0.hasSuffix("not supported") }) { add(.particles) }
            if particle.canRender, features.isEmpty { renderable += 1 }
        }
        for note in scene.notes where note.contains(": particle asset:") { add(.missingAsset) }
        if scene.notes.contains(where: { $0.hasSuffix(": no material") }) {
            result.missing[.missingAsset, default: 0] += scene.notes.filter { $0.hasSuffix(": no material") }.count
        }
        result.status = renderable == 0 ? .unsupported : result.missing.isEmpty ? .supported : .partial
        if renderable == 0 { result.notes.append("no renderable scene objects") }
        return result
    }
}


private actor DeepCheck {
    static let shared = DeepCheck()

    func check(_ entry: WallpaperEntry, assets: URL?, result: Compatibility) -> Compatibility {
        guard !Task.isCancelled else { return result }
        var result = result
        result.checkedDeep = true
        do {
            let renderer = try Wallpaper.open(project: entry.folder, assets: assets)
            _ = try renderer.render(width: 256, height: 144, time: entry.type == .video ? 0 : 1)
            var diagnostics = Set<String>()
            var failedLayers = Set<String>()
            var warningFeatures: [Feature: Int] = [:]
            for warning in renderer.warnings {
                if !result.notes.contains(warning) { result.notes.append(warning) }
                let lower = warning.lowercased()
                if lower.contains("glslang failed:") || lower.contains("spirv-cross failed:")
                    || lower.contains("could not preprocess") || lower.contains("mtllibraryerrordomain") {
                    let diagnostic = warning.components(separatedBy: ": ").dropFirst().joined(separator: ": ")
                    diagnostics.insert(diagnostic.isEmpty ? warning : diagnostic)
                    if let scene = renderer as? SceneRenderer {
                        for layer in scene.scene.layers where warning.hasPrefix(layer.name + ": ") { failedLayers.insert(layer.name) }
                    }
                }
                let mappings: [(String, Feature)] = [("model object", .model3D), ("light object", .light),
                    ("other object", .unknownObject), ("video textures", .videoTexture), ("asset not found", .missingAsset)]
                if lower.contains(": particle "), lower.hasSuffix("not supported") { warningFeatures[.particles, default: 0] += 1 }
                if lower.hasPrefix("scenescript"), lower.contains("not supported") || lower.contains("unsupported") {
                    warningFeatures[.sceneScript, default: 0] += 1
                }
                for (text, feature) in mappings where lower.contains(text) { warningFeatures[feature, default: 0] += 1 }
            }
            if !diagnostics.isEmpty {
                result.missing[.shaderError] = diagnostics.count
                result.notes.append("Shader failures count distinct compiler diagnostics; renderer warnings do not identify failed shaders")
            }
            for (feature, count) in warningFeatures { result.missing[feature] = max(result.missing[feature] ?? 0, count) }
            if result.status == .supported, !result.missing.isEmpty { result.status = .partial }
            if let scene = renderer as? SceneRenderer, !failedLayers.isEmpty,
               scene.scene.particles.isEmpty, scene.scene.layers.allSatisfy({ failedLayers.contains($0.name) }) { result.status = .unsupported }
        } catch {
            result.status = .unsupported
            result.notes.append(String(describing: error))
        }
        return result
    }
}
