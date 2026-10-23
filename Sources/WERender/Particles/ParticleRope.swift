// Rope packing and spline interpolation ported from linux-wallpaperengine CParticle.cpp.
import Foundation
import simd

struct ParticleTrailPoint: Equatable {
    var position: SIMD3<Float>
    var size: Float
    var color: SIMD4<Float>
    init(_ p: ParticleState) { position = p.position; size = p.size; color = SIMD4(p.color, p.alpha) }
    static func mix(_ a: Self, _ b: Self, _ t: Float) -> Self {
        var p = a
        p.position += (b.position - a.position) * t
        p.size += (b.size - a.size) * t
        p.color += (b.color - a.color) * t
        return p
    }
    var finite: Bool {
        position.x.isFinite && position.y.isFinite && position.z.isFinite && size.isFinite &&
        color.x.isFinite && color.y.isFinite && color.z.isFinite && color.w.isFinite
    }
}

/// Flat rows of history samples, moved with the simulation's order-preserving compaction.
final class ParticleHistory {
    let style: ParticleRenderStyle
    private var width: Int { style.segments + 1 }
    private var points: [ParticleTrailPoint] = []
    private var counts: [Int] = []
    private var elapsed: [Float] = []
    private var previous: [ParticleTrailPoint] = []
    init(style: ParticleRenderStyle) { self.style = style }
    func reserveCapacity(_ capacity: Int) {
        points.reserveCapacity(capacity * width)
        counts.reserveCapacity(capacity); elapsed.reserveCapacity(capacity); previous.reserveCapacity(capacity)
    }
    func reset() { counts.indices.forEach { counts[$0] = 0; elapsed[$0] = 0 } }
    func insert(_ p: ParticleState, at row: Int) {
        let point = ParticleTrailPoint(p)
        while counts.count <= row {
            counts.append(0); elapsed.append(0); previous.append(point)
            points.append(contentsOf: repeatElement(point, count: width))
        }
        points[row * width] = point
        counts[row] = 1; elapsed[row] = 0; previous[row] = point
    }
    func move(from: Int, to: Int) {
        for j in 0..<width { points[to * width + j] = points[from * width + j] }
        counts[to] = counts[from]; elapsed[to] = elapsed[from]; previous[to] = previous[from]
    }
    func record(_ particles: [ParticleState], dt: Float) {
        let interval = style.length / Float(style.segments)
        for row in particles.indices {
            let tip = ParticleTrailPoint(particles[row])
            var next = interval - elapsed[row]
            while next <= dt {
                let p = ParticleTrailPoint.mix(previous[row], tip, next / dt)
                if counts[row] == width {
                    for j in 1..<width { points[row * width + j - 1] = points[row * width + j] }
                    counts[row] -= 1
                }
                points[row * width + counts[row]] = p
                counts[row] += 1
                next += interval
            }
            elapsed[row] = (elapsed[row] + dt).truncatingRemainder(dividingBy: interval)
            previous[row] = tip
        }
    }
    private func hasTip(_ row: Int) -> Bool {
        previous[row].position != points[row * width + counts[row] - 1].position
    }
    func count(_ row: Int) -> Int { min(width, counts[row] + (hasTip(row) ? 1 : 0)) }
    func point(_ row: Int, _ index: Int) -> ParticleTrailPoint {
        let total = counts[row] + (hasTip(row) ? 1 : 0)
        let offset = max(0, total - width) + max(0, index)
        return offset >= counts[row] ? previous[row] : points[row * width + offset]
    }
}

enum ParticleRopeVertices {
    static let stride = 26
    static let attributes: [(name: String, offset: Int, components: Int)] = [
        ("a_PositionVec4", 0, 4), ("a_TexCoordVec4", 4, 4), ("a_TexCoordVec4C1", 8, 4),
        ("a_TexCoordVec4C2", 12, 4), ("a_TexCoordVec4C3", 16, 4), ("a_TexCoordC4", 20, 2), ("a_Color", 22, 4)]

    static func build(_ particles: [ParticleState], history: ParticleHistory, time: Float, into vertices: inout [Float]) {
        vertices.removeAll(keepingCapacity: true)
        let style = history.style, subdivision = style.subdivision
        vertices.reserveCapacity(particles.count * style.segments * subdivision * 4 * stride)
        for row in particles.indices where particles[row].age < particles[row].lifetime {
            let n = history.count(row), segments = (n - 1) * subdivision
            func sample(_ index: Int) -> ParticleTrailPoint {
                let index = max(0, min(segments, index))
                let k = min(n - 2, index / subdivision)
                let t = Float(index - k * subdivision) / Float(subdivision)
                let a = history.point(row, k), b = history.point(row, k + 1)
                let p0 = history.point(row, max(0, k - 1)).position
                let p3 = history.point(row, min(n - 1, k + 2)).position
                var p = ParticleTrailPoint.mix(a, b, t)
                let c0 = 2 * a.position
                let c1 = (-p0 + b.position) * t
                var c2: SIMD3<Float> = p0 * 2 - a.position * 5
                c2 += b.position * 4 - p3
                c2 *= t * t
                var c3: SIMD3<Float> = a.position * 3 - p0
                c3 += p3 - b.position * 3
                c3 *= t * t * t
                p.position = (c0 + c1 + c2 + c3) * 0.5
                let fade = sin(Float(index) / Float(max(1, segments)) * .pi)
                if style.fadeAlpha { p.color.w *= fade }
                if style.fadeSize { p.size *= fade }
                return p
            }
            var total: Float = 0
            if style.uvSmoothing {
                for j in 0..<segments {
                    let a = sample(j), b = sample(j + 1)
                    if a.finite && b.finite { total += simd_distance(a.position, b.position) }
                }
            }
            var arc: Float = 0
            for j in 0..<segments {
                let a = sample(j), b = sample(j + 1), before = sample(j - 1), after = sample(j + 2)
                guard a.finite, b.finite, before.finite, after.finite else { continue }
                let distance = simd_distance(a.position, b.position)
                guard distance > 0.00001, a.size > 0 || b.size > 0 else { continue }
                let u0 = (total > 0 ? arc / total : Float(j) / Float(segments)) * style.uvScale
                arc += distance
                let u1 = (total > 0 ? arc / total : Float(j + 1) / Float(segments)) * style.uvScale
                // Encode each UV interval exactly in the stock shader's non-scrolling rope path.
                let length = 1 / max(0.000001, u1 - u0)
                let scroll = style.uvScrolling ? time.truncatingRemainder(dividingBy: 10000) : 0
                let position = (u0 + scroll) * length
                for uv: SIMD2<Float> in [[0, 0], [1, 0], [1, 1], [0, 1]] {
                    vertices.append(contentsOf: [a.position.x, a.position.y, a.position.z, a.size,
                        b.position.x, b.position.y, b.position.z, length + 1,
                        before.position.x, before.position.y, before.position.z, position,
                        after.position.x, after.position.y, after.position.z, b.size,
                        b.color.x, b.color.y, b.color.z, b.color.w, uv.x, uv.y,
                        a.color.x, a.color.y, a.color.z, a.color.w])
                }
            }
        }
    }
}
