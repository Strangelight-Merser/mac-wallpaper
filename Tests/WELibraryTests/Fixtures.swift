import Foundation
import XCTest

class LibraryTestCase: XCTestCase {
    var temporary: URL!

    override func setUpWithError() throws {
        temporary = FileManager.default.temporaryDirectory.appendingPathComponent("WELibraryTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws { try FileManager.default.removeItem(at: temporary) }

    @discardableResult
    @nonobjc func write(_ relative: String, _ data: Data) throws -> URL {
        let url = temporary.appendingPathComponent(relative)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url)
        return url
    }

    @discardableResult
    @nonobjc func write(_ relative: String, _ text: String) throws -> URL { try write(relative, Data(text.utf8)) }

    @discardableResult
    func json(_ relative: String, _ value: [String: Any]) throws -> URL {
        try write(relative, JSONSerialization.data(withJSONObject: value, options: .sortedKeys))
    }

    func project(_ folder: String, type: String = "scene", extra: [String: Any] = [:]) throws -> URL {
        try json("\(folder)/project.json", ["title": "Fixture", "type": type, "file": type == "scene" ? "scene.json" : "main.html"].merging(extra) { _, value in value })
        return temporary.appendingPathComponent(folder)
    }

    func scene(_ folder: String = "project", objects: [[String: Any]]? = nil, packed: Bool = false) throws -> URL {
        let project = try project(folder)
        let files: [(String, Data)] = [
            ("scene.json", try JSONSerialization.data(withJSONObject: ["general": ["orthogonalprojection": ["width": 16, "height": 16]], "objects": objects ?? [["id": 1, "name": "image", "image": "models/test.json", "origin": "8 8 0"]]])),
            ("models/test.json", Data(#"{"material":"materials/test.json","width":16,"height":16}"#.utf8)),
            ("materials/test.json", Data(#"{"passes":[{"shader":"fixture","textures":["test"]}]}"#.utf8)),
            ("materials/test.tex", texture()),
            ("shaders/fixture.vert", Data("attribute vec3 a_Position;\nuniform mat4 g_ModelViewProjectionMatrix;\nvoid main()\n{ gl_Position = mul(vec4(a_Position, 1.0), g_ModelViewProjectionMatrix); }\n".utf8)),
            ("shaders/fixture.frag", Data("void main()\n{ gl_FragColor = vec4(1.0, 0.0, 0.0, 1.0); }\n".utf8))
        ]
        if packed { try write("\(folder)/scene.pkg", package(files)) }
        else { for (path, data) in files { try write("\(folder)/\(path)", data) } }
        return project
    }
}

func word(_ value: Int) -> Data {
    var bits = UInt32(truncatingIfNeeded: value).littleEndian
    return withUnsafeBytes(of: &bits) { Data($0) }
}

func sized(_ text: String) -> Data { word(text.utf8.count) + Data(text.utf8) }

func package(_ files: [(String, Data)]) -> Data {
    var table = sized("PKGV0018") + word(files.count), payload = Data()
    for (path, bytes) in files {
        table += sized(path) + word(payload.count) + word(bytes.count)
        payload += bytes
    }
    return table + payload
}

func texture(videoFlag: Bool = false, mp4: Bool = false) -> Data {
    var data = Data("TEXV0005\0TEXI0001\0".utf8)
    for value in [0, videoFlag ? 32 : 0, 1, 1, 1, 1, 0] { data += word(value) }
    data += Data((mp4 ? "TEXB0004\0" : "TEXB0001\0").utf8) + word(1)
    if mp4 { data += word(-1) + word(1) }
    data += word(1)
    if mp4 { data += word(0) + word(0) + Data([0]) + word(0) }
    data += word(1) + word(1)
    if mp4 { data += word(0) + word(4) }
    return data + word(4) + Data([255, 0, 0, 255])
}
