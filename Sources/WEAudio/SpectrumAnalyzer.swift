import Accelerate
import Foundation

/// Wallpaper Engine's audio spectrum: per channel 64, 32 and 16 bands, low to high frequencies,
/// each roughly 0…1. Scenes read `g_AudioSpectrum{16,32,64}{Left,Right}`; web pages get the 64-band
/// pair as one 128-value array (left 0–63, right 64–127).
public struct AudioSpectrum: Equatable, Sendable {
    public var left64 = [Float](repeating: 0, count: 64), right64 = [Float](repeating: 0, count: 64)
    public var left32 = [Float](repeating: 0, count: 32), right32 = [Float](repeating: 0, count: 32)
    public var left16 = [Float](repeating: 0, count: 16), right16 = [Float](repeating: 0, count: 16)
    public init() {}

    /// The array `wallpaperRegisterAudioListener` callbacks receive.
    public var web128: [Float] { left64 + right64 }

    public var isSilent: Bool { left64.allSatisfy { $0 == 0 } && right64.allSatisfy { $0 == 0 } }
}

/// Turns stereo PCM into an `AudioSpectrum`, following linux-wallpaperengine's analysis so values have
/// the scale wallpapers were tuned for: FFT of the latest 1024 samples, band b = the louder of bins
/// 2b+1…2b+2 (~47 Hz each at 48 kHz, so 64 bands span ~0–6 kHz), value = 0.35·log10(power) tilted towards the
/// highs by (2 − e^((1 − b/(n−1)) − 0.5)), clamped to 0…1. Values move towards their target by 0.3 per
/// 1/30 s. Unlike LWE: stereo, a Hann window (power scaled to match LWE's unwindowed tones), all bins
/// used, the 32/16-band sets from their own bins instead of every other band, no negative values.
public final class SpectrumAnalyzer: @unchecked Sendable {
    public static let fftSize = 1024
    private let log2n = vDSP_Length(10)
    private let setup: FFTSetup
    private let window: [Float]
    private let lock = NSLock()
    // Ring buffers of the latest samples per channel (guarded by `lock`).
    private var ring: [[Float]] = [[Float](repeating: 0, count: 1024), [Float](repeating: 0, count: 1024)]
    private var ringPos = 0
    private var fresh = false
    private var lastAppend: TimeInterval = 0
    private var target = AudioSpectrum()
    public private(set) var current = AudioSpectrum()

    public init() {
        setup = vDSP_create_fftsetup(10, FFTRadix(kFFTRadix2))!
        window = vDSP.window(ofType: Float.self, usingSequence: .hanningDenormalized, count: 1024, isHalfWindow: false)
    }

    deinit { vDSP_destroy_fftsetup(setup) }

    /// Append samples (any thread). `right` may be nil for mono.
    public func append(left: UnsafeBufferPointer<Float>, right: UnsafeBufferPointer<Float>?) {
        lock.lock(); defer { lock.unlock() }
        let n = Self.fftSize
        for i in 0..<left.count {
            ring[0][ringPos] = left[i]
            ring[1][ringPos] = right?[i] ?? left[i]
            ringPos = (ringPos + 1) % n
        }
        fresh = true
        lastAppend = ProcessInfo.processInfo.systemUptime
    }

    public func append(left: [Float], right: [Float]?) {
        left.withUnsafeBufferPointer { l in
            if let right { right.withUnsafeBufferPointer { append(left: l, right: $0) } } else { append(left: l, right: nil) }
        }
    }

    /// Analyse new audio (if any) and advance the smoothed values by `dt` seconds.
    @discardableResult
    public func update(dt: Double) -> AudioSpectrum {
        var samples: [[Float]]?
        lock.lock()
        // Capture may deliver nothing while nothing plays: fall back to silence instead of freezing.
        if !fresh, lastAppend > 0, ProcessInfo.processInfo.systemUptime - lastAppend > 0.25 {
            target = AudioSpectrum()
        }
        if fresh {
            let n = Self.fftSize
            samples = ring.map { Array($0[ringPos..<n] + $0[0..<ringPos]) }
            fresh = false
        }
        lock.unlock()
        if let samples {
            let (l, r) = (power(samples[0]), power(samples[1]))
            target.left64 = bands(l, 64); target.right64 = bands(r, 64)
            target.left32 = bands(l, 32); target.right32 = bands(r, 32)
            target.left16 = bands(l, 16); target.right16 = bands(r, 16)
        }
        let step = Float(0.3 * dt * 30)
        func move(_ c: inout [Float], _ t: [Float]) {
            for i in c.indices { c[i] += max(-step, min(step, t[i] - c[i])) }
        }
        move(&current.left64, target.left64); move(&current.right64, target.right64)
        move(&current.left32, target.left32); move(&current.right32, target.right32)
        move(&current.left16, target.left16); move(&current.right16, target.right16)
        return current
    }

    /// Forget all audio (capture stopped).
    public func reset() {
        lock.lock(); defer { lock.unlock() }
        for c in ring.indices { ring[c] = [Float](repeating: 0, count: Self.fftSize) }
        fresh = false
        lastAppend = 0
        target = AudioSpectrum()
        current = AudioSpectrum()
    }

    /// Jump straight to the analysed values (offline rendering).
    public func settle() -> AudioSpectrum {
        update(dt: 10)
    }

    /// Power spectrum of one 1024-sample block, bins 0…512, scaled like LWE's unwindowed kiss_fftr.
    func power(_ x: [Float]) -> [Float] {
        let n = Self.fftSize
        var windowed = vDSP.multiply(x, window)
        var re = [Float](repeating: 0, count: n / 2), im = [Float](repeating: 0, count: n / 2)
        var out = [Float](repeating: 0, count: n / 2 + 1)
        re.withUnsafeMutableBufferPointer { rp in
            im.withUnsafeMutableBufferPointer { ip in
                var split = DSPSplitComplex(realp: rp.baseAddress!, imagp: ip.baseAddress!)
                windowed.withUnsafeMutableBytes { raw in
                    vDSP_ctoz(raw.bindMemory(to: DSPComplex.self).baseAddress!, 2, &split, 1, vDSP_Length(n / 2))
                }
                vDSP_fft_zrip(setup, &split, 1, log2n, FFTDirection(FFT_FORWARD))
                // vDSP's real FFT is 2× the textbook DFT; the Hann window halves a tone's amplitude.
                // Net: textbook magnitude = |X| / 2, and ×2 to undo the window → |X|, i.e. power |X|².
                out[0] = rp[0] * rp[0]
                out[n / 2] = ip[0] * ip[0]
                for k in 1..<n / 2 { out[k] = rp[k] * rp[k] + ip[k] * ip[k] }
            }
        }
        return out
    }

    /// `count` bands over bins 1…128 (64 bands × 2 bins; 32 × 4; 16 × 8), each the loudest of its bins
    /// (a tone then reads the same in every band set, as LWE's single-bin bands do).
    func bands(_ power: [Float], _ count: Int) -> [Float] {
        let width = 128 / count
        return (0..<count).map { b in
            let p = power[(1 + b * width)...(b * width + width)].max()!
            guard p > 1 else { return 0 }
            let tilt = 2 - exp((1 - Float(b) / Float(count - 1)) - 0.5)
            return min(1, 0.35 * log10(p) * tilt)
        }
    }
}
