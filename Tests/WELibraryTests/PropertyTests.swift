import XCTest
@testable import WELibrary

final class PropertyTests: XCTestCase {
    func parse(_ entries: [String: Any]) -> [WallpaperProperty] {
        WallpaperProperties.parse(project: ["general": ["properties": entries]])
    }
    func testKindsOrderingAndNormalization() {
        let p = parse([
            "bool": ["type": "bool", "value": 1, "order": -1],
            "slider": ["type": "slider", "value": "0.70", "min": -2, "max": 3, "step": 0.1, "precision": 2, "fraction": true],
            "slider2": ["type": "slider", "value": 2],
            "combo": ["type": "combo", "value": 2, "options": [["label": "Two", "value": 2], ["label": "Word", "value": "word"]]],
            "color": ["type": "color", "value": "0 0.85 1"],
            "text": ["type": "Text", "value": "ignored", "text": "<b>Title</b>"],
            "group": ["type": "group", "index": -1], "input": ["type": "textinput", "value": "hello"],
            "file": ["type": "file"], "dir": ["type": "directory"], "unknown": ["type": "future"]])
        XCTAssertEqual(p.map(\.id), ["bool", "group", "color", "combo", "dir", "file", "input", "slider", "slider2", "text", "unknown"])
        let d = Dictionary(uniqueKeysWithValues: p.map { ($0.id, $0) })
        XCTAssertEqual(d["bool"]?.defaultValue, "true")
        XCTAssertEqual(d["slider"]?.defaultValue, "0.7")
        XCTAssertEqual(d["slider"]?.kind, .slider(min: -2, max: 3, step: 0.1, precision: 2, fraction: true))
        XCTAssertEqual(d["slider2"]?.kind, .slider(min: 0, max: 1, step: nil, precision: nil, fraction: false))
        XCTAssertEqual(d["combo"]?.kind, .combo(options: [.init(label: "Two", value: "2"), .init(label: "Word", value: "word")]))
        XCTAssertEqual(d["combo"]?.defaultValue, "2")
        XCTAssertEqual(d["color"]?.defaultValue, "0 0.85 1")
        XCTAssertEqual(d["text"]?.kind, .label); XCTAssertNil(d["text"]?.defaultValue)
        XCTAssertEqual(d["text"]?.label, "<b>Title</b>")
        XCTAssertEqual(d["group"]?.kind, .group); XCTAssertEqual(d["input"]?.kind, .textInput)
        XCTAssertEqual(d["file"]?.kind, .file); XCTAssertEqual(d["dir"]?.kind, .directory)
        XCTAssertEqual(d["unknown"]?.kind, .unknown("future"))
    }
    func testConditions() {
        let values = ["x": "3", "word": "hello", "enabled": "true"]
        for (condition, expected) in [
            ("false || true && false", false), ("(false || true) && !false", true),
            ("x.value >= 3 && x.value < 4", true), ("x.value != 3", false),
            ("word.value == 'hello' && enabled.value == 1", true),
            ("x.value == '3'", true), ("'01' == '1'", false), ("!'false'", false), ("x.value <= 2 || x.value > 4", false),
            ("missing.value == 1", true), ("false && missing.value", true),
            ("x.value ==", true), ("(false", true), ("false garbage", true), ("'unterminated", true)
        ] {
            let p = parse(["p": ["type": "bool", "condition": condition]])[0]
            XCTAssertEqual(WallpaperProperties.isVisible(p, values: values), expected, condition)
        }
    }
    func testStoreRoundTripOverridesReset() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("properties.json")
        let store = try PropertyStore(url: url)
        let properties = parse(["a": ["type": "slider", "value": 1], "b": ["type": "bool", "value": false]])
        try store.set("1", for: "wall", key: "a")
        try store.set("true", for: "wall", key: "b")
        try store.set("other", for: "second", key: "a")
        XCTAssertEqual(store.overrides(for: "wall", properties: properties), ["b": "true"])
        let loaded = try PropertyStore(url: url)
        XCTAssertEqual(loaded.values(for: "wall"), ["a": "1", "b": "true"])
        try loaded.reset(for: "wall", key: "b")
        XCTAssertEqual(loaded.values(for: "wall"), ["a": "1"])
        try loaded.reset(for: "wall")
        XCTAssertEqual(try PropertyStore(url: url).values(for: "wall"), [:])
        XCTAssertEqual(loaded.values(for: "second"), ["a": "other"])
    }
}
