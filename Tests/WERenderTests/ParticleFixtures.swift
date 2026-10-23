import Foundation
import XCTest
import WEFormat
@testable import WERender

class ParticleTestCase: XCTestCase {
    var folder: URL!
    var locator: AssetLocator { AssetLocator(project: folder, assets: nil) }
    let properties = UserProperties(project: [:])

    override func setUpWithError() throws {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("Particles-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try json("material.json", ["passes": [["shader": "genericparticle", "textures": ["util/white"], "blending": "additive"]]])
    }

    override func tearDownWithError() throws { try FileManager.default.removeItem(at: folder) }

    func json(_ path: String, _ value: [String: Any]) throws {
        let url = folder.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONSerialization.data(withJSONObject: value, options: .sortedKeys).write(to: url)
    }

    func description(_ definition: [String: Any] = [:], object: [String: Any] = [:]) throws -> ParticleSystemDescription {
        var d = definition
        d["material"] = d["material"] ?? "material.json"
        let o: [String: Any] = ["id": 7, "name": "test", "particle": d]
        return try ParticleSystemDescription(object: o.merging(object) { _, b in b }, locator: locator, properties: properties)
    }

    func values(_ d: [String: Any]) -> ParticleValues { ParticleValues(d, properties) }

    func simulation(_ definition: [String: Any] = [:], overrides: [String: Any] = [:]) throws -> ParticleSimulation {
        let base: [String: Any] = ["maxcount": 1000, "emitter": [["name": "boxrandom", "rate": 10, "distancemax": 0]],
                                  "initializer": [["name": "lifetimerandom", "min": 10, "max": 10]]]
        return ParticleSimulation(try description(base.merging(definition) { _, b in b }, object: ["instanceoverride": overrides]))
    }
}

func particleWord(_ value: UInt32) -> Data {
    var word = value.littleEndian
    return withUnsafeBytes(of: &word) { Data($0) }
}

func particleTex(images: [[UInt8]], width: Int, height: Int,
                 frames: [(image: Int, duration: Float, rect: [Float])]) throws -> Tex {
    var data = Data("TEXV0005\0TEXI0001\0".utf8)
    for value in [0, 4, width, height, width, height, 0] { data += particleWord(UInt32(value)) }
    data += Data("TEXB0001\0".utf8) + particleWord(UInt32(images.count))
    for image in images {
        for value in [1, width, height, image.count] { data += particleWord(UInt32(value)) }
        data += Data(image)
    }
    data += Data("TEXS0002\0".utf8) + particleWord(UInt32(frames.count))
    for frame in frames {
        data += particleWord(UInt32(frame.image)) + particleWord(frame.duration.bitPattern)
        for value in frame.rect { data += particleWord(value.bitPattern) }
    }
    return try Tex(data: data)
}
