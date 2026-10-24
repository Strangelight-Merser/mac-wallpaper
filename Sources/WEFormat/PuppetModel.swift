import Foundation
import simd

public struct PuppetModel {
    public struct Vertex {
        public let position: SIMD3<Float>
        public let uv: SIMD2<Float>
        public let indices: SIMD4<UInt32>
        public let weights: SIMD4<Float>
    }
    public struct Bone {
        public let name: String
        public let parent: Int?
        public let rest: simd_float4x4
    }
    public struct Frame {
        public let position: SIMD3<Float>
        public let angles: SIMD3<Float>
        public let scale: SIMD3<Float>
        public var rotation: simd_quatf {
            simd_quatf(angle: angles.z, axis: [0, 0, 1]) *
            simd_quatf(angle: angles.y, axis: [0, 1, 0]) * simd_quatf(angle: angles.x, axis: [1, 0, 0])
        }
    }
    public enum PlayMode: String { case loop, mirror, single }
    public struct Animation {
        public let id: Int
        public let name: String
        public let fps: Float
        public let length: Int
        public let mode: PlayMode
        public let frames: [[Frame]]
    }
    public struct Layer {
        public var animation: Int
        public var rate: Float
        public var blend: Float
        public var visible: Bool
        public var id: Int?
        public var name: String
        public var additive: Bool
        public var blendin: Bool
        public var blendout: Bool
        public var blendtime: Double
        public init(animation: Int, rate: Float = 1, blend: Float = 1, visible: Bool = true,
                    id: Int? = nil, name: String = "", additive: Bool = false,
                    blendin: Bool = false, blendout: Bool = false, blendtime: Double = 0) {
            self.animation = animation; self.rate = rate; self.blend = blend; self.visible = visible
            self.id = id; self.name = name; self.additive = additive
            self.blendin = blendin; self.blendout = blendout; self.blendtime = blendtime
        }
    }
    public let vertexVersion: Int
    public private(set) var skeletonVersion: Int?
    public private(set) var animationVersion: Int?
    public let vertexStride: Int
    public let material: String
    public let vertices: [Vertex]
    public let indices: [UInt16]
    public private(set) var bones: [Bone] = []
    public private(set) var animations: [Animation] = []

    public init(data: Data) throws {
        var r = BinaryReader(Array(data))
        vertexVersion = try r.puppetVersion("MDLV", supported: [13, 23])
        let flags = try r.u32()
        _ = try r.bytes(8)
        material = try r.cString()
        _ = try r.u32()
        var size = try r.u32()
        var extended = false
        if size == 0 {
            extended = true
            // Seven reserved words precede the extended vertex declaration.
            for _ in 0..<5 { guard try r.u32() == 0 else { throw WEFormatError.corrupt("MDLV reserved field") } }
            let declaration = try r.u32()
            guard declaration == 0x0180000f || declaration == 15 else {
                throw WEFormatError.unsupported("MDLV vertex declaration \(declaration)")
            }
            size = try r.u32()
        } else if size == 0x01800009 { size = try r.u32() }
        let skinned = flags != 9
        vertexStride = extended ? (skinned ? 80 : 48) : (skinned ? 52 : 20)
        guard size > 0, Int(size) % vertexStride == 0, Int(size) <= r.remaining else {
            throw WEFormatError.corrupt("MDLV vertex byte count \(size)")
        }
        var verts: [Vertex] = []
        for _ in 0..<(Int(size) / vertexStride) {
            let position = try r.puppetVec3()
            if extended { _ = try r.bytes(28) }
            let ids = skinned ? try SIMD4(r.u32(), r.u32(), r.u32(), r.u32()) : .zero
            let weights = skinned ? try SIMD4(r.puppetFloat(), r.puppetFloat(), r.puppetFloat(), r.puppetFloat()) : SIMD4<Float>(1, 0, 0, 0)
            let uv = try SIMD2(r.puppetFloat(), r.puppetFloat())
            verts.append(Vertex(position: position, uv: uv, indices: ids, weights: weights))
        }
        vertices = verts
        let indexBytes = Int(try r.u32())
        guard indexBytes % 6 == 0, indexBytes <= r.remaining else { throw WEFormatError.corrupt("MDLV triangle byte count") }
        var ids: [UInt16] = []
        for _ in 0..<(indexBytes / 2) {
            let i = try r.puppetU16()
            guard Int(i) < vertices.count else { throw WEFormatError.corrupt("MDLV vertex index") }
            ids.append(i)
        }
        indices = ids
        if vertexVersion == 23, extended, r.remaining > 0 {
            if try r.puppetByte() != 0 {
                let shapes = Int(try r.u32())
                guard shapes <= r.remaining / 4 else { throw WEFormatError.corrupt("MDLV shape count") }
                for _ in 0..<shapes {
                    let length = Int(try r.u32())
                    guard length == vertices.count * 12 else { throw WEFormatError.corrupt("MDLV shape size") }
                    _ = try r.bytes(length)
                }
            }
            if try r.puppetByte() != 0 {
                let length = Int(try r.u32())
                guard length % 16 == 0 else { throw WEFormatError.corrupt("MDLV draw ranges") }
                _ = try r.bytes(length)
            }
        }
        while r.remaining > 0, r.data[r.offset] == 0 { _ = try r.puppetByte() }
        if r.remaining == 0 { return }
        skeletonVersion = try r.puppetVersion("MDLS", supported: [1, 2, 3, 4])
        let skeletonEnd = Int(try r.u32())
        let count = Int(try r.puppetU16())
        _ = try r.puppetU16()
        for i in 0..<count {
            let name = try r.cString()
            _ = try r.u32()
            let parent = try r.u32()
            guard parent == UInt32.max || parent < i else { throw WEFormatError.corrupt("MDLS bone parent") }
            guard try r.u32() == 64 else { throw WEFormatError.unsupported("MDLS bone matrix size") }
            let columns = try (0..<4).map { _ in try SIMD4(r.puppetFloat(), r.puppetFloat(), r.puppetFloat(), r.puppetFloat()) }
            let rest = simd_float4x4(columns)
            guard abs(simd_determinant(rest)) > 1e-12 else { throw WEFormatError.corrupt("MDLS singular bind pose") }
            _ = try r.cString()
            bones.append(Bone(name: name, parent: parent == UInt32.max ? nil : Int(parent), rest: rest))
        }
        if skeletonVersion! > 1 {
            _ = try r.puppetU16()
            if try r.puppetByte() != 0 { _ = try r.bytes(count * 64) }
            let entries = Int(try r.u32())
            _ = try r.bytes(entries * 12)
            _ = try r.u32()
            if try r.puppetByte() != 0 { _ = try r.bytes(count * 76) }
            if try r.puppetByte() != 0 { _ = try r.bytes(count * 4) }
        }
        if skeletonEnd != 0 {
            guard skeletonEnd >= r.offset, skeletonEnd <= r.data.count else { throw WEFormatError.corrupt("MDLS section end") }
            _ = try r.bytes(skeletonEnd - r.offset)
        }
        for vertex in vertices where !bones.isEmpty {
            guard (0..<4).allSatisfy({ vertex.indices[$0] < bones.count }) else {
                throw WEFormatError.corrupt("MDLV bone index")
            }
        }
        while r.remaining > 0 {
            if r.data[r.offset] == 0 { _ = try r.puppetByte(); continue }
            if r.data[r.offset...].starts(with: Array("MDAT".utf8)) {
                _ = try r.puppetVersion("MDAT", supported: [1])
                _ = try r.u32()
                let attachments = Int(try r.puppetU16())
                for _ in 0..<attachments { _ = try r.puppetU16(); _ = try r.cString(); _ = try r.bytes(64) }
                continue
            }
            if r.data[r.offset...].starts(with: Array("MDLA".utf8)) { break }
            // The skeleton trailer contains null-terminated auxiliary records.
            let record = try r.cString()
            if record.hasPrefix("MD") { throw WEFormatError.unsupported("puppet section \(record)") }
        }
        if r.remaining == 0 { return }
        animationVersion = try r.puppetVersion("MDLA", supported: [0, 1, 2, 3, 4, 5, 6])
        if animationVersion == 0 { return }
        _ = try r.u32()
        let animationCount = Int(try r.u32())
        guard animationCount <= r.remaining / 24 else { throw WEFormatError.corrupt("MDLA animation count") }
        for _ in 0..<animationCount {
            var id = try r.u32()
            while id == 0 { id = try r.u32() }
            guard id <= Int32.max else { throw WEFormatError.corrupt("MDLA animation id") }
            _ = try r.u32()
            var name = try r.cString()
            if name.isEmpty { name = try r.cString() }
            let modeName = try r.cString()
            guard let mode = PlayMode(rawValue: modeName.isEmpty ? "loop" : modeName) else {
                throw WEFormatError.unsupported("MDLA play mode \(modeName)")
            }
            let fps = try r.puppetFloat(), length = Int(try r.u32())
            _ = try r.u32()
            let tracks = Int(try r.u32())
            guard fps > 0, length > 0, tracks == bones.count else { throw WEFormatError.corrupt("MDLA animation dimensions") }
            var frames: [[Frame]] = []
            for _ in 0..<tracks {
                _ = try r.u32()
                let bytes = Int(try r.u32())
                guard bytes % 36 == 0, bytes / 36 >= length, bytes <= r.remaining else {
                    throw WEFormatError.corrupt("MDLA frame byte count")
                }
                frames.append(try (0..<(bytes / 36)).map { _ in
                    try Frame(position: r.puppetVec3(), angles: r.puppetVec3(), scale: r.puppetVec3())
                })
            }
            animations.append(Animation(id: Int(id), name: name, fps: fps, length: length, mode: mode, frames: frames))
            if extended { _ = try r.bytes(2) }
            else if animationVersion == 3 { _ = try r.puppetByte() }
            else {
                let events = Int(try r.u32())
                guard events <= r.remaining / 5 else { throw WEFormatError.corrupt("MDLA event count") }
                for _ in 0..<events { _ = try r.puppetFloat(); _ = try r.cString() }
            }
        }
    }
}

private extension BinaryReader {
    mutating func puppetByte() throws -> UInt8 { try bytes(1).first! }
    mutating func puppetU16() throws -> UInt16 { let b = try bytes(2); return UInt16(b[b.startIndex]) | UInt16(b[b.startIndex + 1]) << 8 }
    mutating func puppetFloat() throws -> Float {
        let f = try f32()
        guard f.isFinite else { throw WEFormatError.corrupt("non-finite puppet value") }
        return f
    }
    mutating func puppetVec3() throws -> SIMD3<Float> { try SIMD3(puppetFloat(), puppetFloat(), puppetFloat()) }
    mutating func puppetVersion(_ section: String, supported: [Int]) throws -> Int {
        let tag = try cString(maxLength: 8)
        guard tag.count == 8, tag.hasPrefix(section), let version = Int(tag.suffix(4)) else {
            throw WEFormatError.badMagic(tag, expected: section)
        }
        guard supported.contains(version) else { throw WEFormatError.unsupported("puppet \(tag)") }
        return version
    }
}
