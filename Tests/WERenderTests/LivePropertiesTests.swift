import XCTest
import Metal
import WEFormat
@testable import WERender

final class LivePropertiesTests: XCTestCase {
    var root: URL { URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent() }
    var project: URL { root.appendingPathComponent("regression/fixtures/propertiestest") }
    var assets: URL { root.appendingPathComponent("samples/wallpaper_engine/assets") }

    func testBindingBookkeepingAndHiddenEffects() throws {
        // Minimal self-made effect keeps this test independent of installed WE assets and Metal.
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        func write(_ name: String, _ value: [String: Any]) throws {
            try JSONSerialization.data(withJSONObject: value).write(to: dir.appendingPathComponent(name))
        }
        try write("project.json", ["type": "scene", "file": "scene.json", "general": ["properties": ["mode": ["value": 0]]]])
        try write("effect.json", ["passes": [["material": "material.json"]]])
        try write("material.json", ["passes": [["shader": "genericimage"]]])
        try write("scene.json", ["general": ["clearcolor": ["user": "background", "value": "0 0 0"]], "objects": [
            ["id": 1, "text": ["user": "caption", "value": "Text"], "effects": [["file": "effect.json", "visible": ["user": ["name": "mode", "condition": 1], "value": false], "passes": [["constantshadervalues": ["alpha": ["user": "opacity", "value": 1]], "combos": ["MODE": ["user": "mode", "value": 0]]]]]]],
            ["id": 2, "sound": ["tone.wav"], "volume": ["user": "volume", "value": 0.5]],
            ["id": 3, "origin": ["user": "position", "value": "0 0 0"], "instanceoverride": ["rate": ["user": "rate", "value": 1]]]
        ]])
        let scene = try SceneDescription(project: dir, locator: AssetLocator(project: dir, assets: nil))
        XCTAssertEqual(scene.userBindings.count, 8)
        XCTAssertEqual(scene.layers[0].hiddenEffects, [0])
        XCTAssertEqual(scene.layers[0].effectSlots[0], 0)
        let binding = try XCTUnwrap(scene.userBindings.first { $0.path == "effects[0].visible" })
        XCTAssertEqual(binding.name, "mode"); XCTAssertEqual(binding.object, 1)
        XCTAssertEqual(binding.condition as? Int, 1)
        XCTAssertTrue(binding.supportsLive)
        XCTAssertFalse(try XCTUnwrap(scene.userBindings.first { $0.path.contains("combos") }).supportsLive)
        let overridden = try SceneDescription(project: dir, locator: AssetLocator(project: dir, assets: nil), overrides: ["mode": "1"])
        XCTAssertEqual(overridden.layers[0].passes.last?.combos["MODE"], 1)
        XCTAssertTrue(overridden.layers[0].hiddenEffects.isEmpty)
    }

    func testFixtureParsesWithStockAssets() throws {
        guard FileManager.default.fileExists(atPath: assets.path) else { throw XCTSkip("WE stock assets unavailable") }
        let scene = try SceneDescription(project: project, locator: AssetLocator(project: project, assets: assets))
        XCTAssertEqual(scene.layers.count, 3)
        XCTAssertTrue(scene.notes.isEmpty, scene.notes.joined(separator: "\n"))
        XCTAssertEqual(scene.layers[0].hiddenEffects, [0])
        XCTAssertTrue(scene.userBindings.contains { $0.name == "file" && !$0.supportsLive })
    }

    func testLiveMatchesReloadAndReset() throws {
        guard MTLCreateSystemDefaultDevice() != nil else { throw XCTSkip("Metal unavailable") }
        guard FileManager.default.fileExists(atPath: assets.path) else { throw XCTSkip("WE stock assets unavailable") }
        let renderer = try SceneRenderer(project: project, assets: assets)
        let baseline = try renderer.render(width: 512, height: 256, time: 1)
        XCTAssertFalse(renderer.setUserProperties(["file": "missing.json", "caption": "Ignored"]))
        XCTAssertEqual(renderer.scene.properties.values["caption"] as? String, "Properties")
        let changes = ["mode": "1", "opacity": "0.5", "caption": "Changed", "strength": "0.8", "tint": "0.3 0.7 1", "position": "200 160 0", "scale": "0.8 0.8 1", "angles": "0 0 15", "background": "0.1 0.2 0.3", "bloom": "true"]
        XCTAssertTrue(renderer.setUserProperties(changes))
        let live = try renderer.render(width: 512, height: 256, time: 1)
        let fresh = try SceneRenderer(project: project, assets: assets, properties: changes)
        let reloaded = try fresh.render(width: 512, height: 256, time: 1)
        XCTAssertEqual(live.dataProvider?.data as Data?, reloaded.dataProvider?.data as Data?)
        let defaults = ["mode": "0", "opacity": "1", "caption": "Properties", "strength": "0.4", "tint": "1 1 1", "position": "180 150 0", "scale": "1 1 1", "angles": "0 0 0", "background": "0.05 0.08 0.1", "bloom": "false"]
        XCTAssertTrue(renderer.setUserProperties(defaults))
        let reset = try renderer.render(width: 512, height: 256, time: 1)
        XCTAssertEqual(baseline.dataProvider?.data as Data?, reset.dataProvider?.data as Data?)
        XCTAssertTrue(renderer.warnings.isEmpty, renderer.warnings.joined(separator: "\n"))
    }

    func testWebValues() {
        let project: [String: Any] = ["general": ["properties": ["enabled": ["type": "bool", "value": false], "amount": ["type": "slider", "value": 1], "choice": ["type": "combo", "value": 2]]]]
        let page = Wallpaper.webProperties(project: project, values: ["enabled": "true", "amount": "0.5"])
        XCTAssertEqual(page["enabled"]?["value"] as? Bool, true)
        XCTAssertEqual(page["amount"]?["value"] as? Double, 0.5)
        XCTAssertEqual(page["choice"]?["value"] as? String, "2")
    }
}
