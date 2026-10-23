// Perlin curl noise ported from linux-wallpaperengine NoiseUtils.h (used by CParticle.cpp).
import simd
import Foundation

/// Analytic Perlin derivatives avoid eighteen finite-difference noise evaluations per particle.
enum ParticleNoise {
    static let permutation = [
        151,160,137,91,90,15,131,13,201,95,96,53,194,233,7,225,140,36,103,30,69,142,8,99,37,240,21,10,23,190,6,148,
        247,120,234,75,0,26,197,62,94,252,219,203,117,35,11,32,57,177,33,88,237,149,56,87,174,20,125,136,171,168,
        68,175,74,165,71,134,139,48,27,166,77,146,158,231,83,111,229,122,60,211,133,230,220,105,92,41,55,46,245,
        40,244,102,143,54,65,25,63,161,1,216,80,73,209,76,132,187,208,89,18,169,200,196,135,130,116,188,159,86,
        164,100,109,198,173,186,3,64,52,217,226,250,124,123,5,202,38,147,118,126,255,82,85,212,207,206,59,227,47,
        16,58,17,182,189,28,42,223,183,170,213,119,248,152,2,44,154,163,70,221,153,101,155,167,43,172,9,129,22,
        39,253,19,98,108,110,79,113,224,232,178,185,112,104,218,246,97,228,251,34,242,193,238,210,144,12,191,179,
        162,241,81,51,145,235,249,14,239,107,49,192,214,31,181,199,106,157,184,84,204,176,115,121,50,45,127,4,
        150,254,138,236,205,93,222,114,67,29,24,72,243,141,128,195,78,66,215,61,156,180]
    static let gradients: [SIMD3<Float>] = [
        [1,1,0],[-1,1,0],[1,-1,0],[-1,-1,0],[1,0,1],[-1,0,1],[1,0,-1],[-1,0,-1],
        [0,1,1],[0,-1,1],[0,1,-1],[0,-1,-1],[1,1,0],[0,-1,1],[-1,1,0],[0,-1,-1]]

    static func derivative(_ position: SIMD3<Float>) -> SIMD3<Float> {
        guard position.x.isFinite, position.y.isFinite, position.z.isFinite else { return .zero }
        let floorP = floor(position)
        let p = position - floorP
        let cell = SIMD3<Int>(Int(floorP.x.truncatingRemainder(dividingBy: 256)) & 255,
                             Int(floorP.y.truncatingRemainder(dividingBy: 256)) & 255,
                             Int(floorP.z.truncatingRemainder(dividingBy: 256)) & 255)
        let polynomial: SIMD3<Float> = p * (p * 6 - 15) + 10
        let fade: SIMD3<Float> = (p * p * p) * polynomial
        let slope: SIMD3<Float> = (30 * p * p) * ((p - 1) * (p - 1))
        var derivative = SIMD3<Float>.zero
        for z in 0...1 { for y in 0...1 { for x in 0...1 {
            let hash = permutation[(permutation[(permutation[(cell.x + x) & 255] + cell.y + y) & 255] + cell.z + z) & 255]
            let gradient = gradients[hash & 15]
            let corner = SIMD3<Float>(Float(x), Float(y), Float(z))
            let sign = corner * 2 - 1
            let weights = SIMD3<Float>(x == 0 ? 1 - fade.x : fade.x, y == 0 ? 1 - fade.y : fade.y, z == 0 ? 1 - fade.z : fade.z)
            let products = SIMD3<Float>(weights.y * weights.z, weights.x * weights.z, weights.x * weights.y)
            let dWeight = sign * slope * products
            let weightedGradient = gradient * (weights.x * weights.y * weights.z)
            derivative += weightedGradient + simd_dot(gradient, p - corner) * dWeight
        } } }
        return derivative
    }

    static func curl(_ p: SIMD3<Float>) -> SIMD3<Float> {
        let x = derivative(p), y = derivative(p + [89.2, 33.1, 57.3]), z = derivative(p + [100.3, 120.1, 142.2])
        return [z.y - y.z, x.z - z.x, y.x - x.y]
    }
}
