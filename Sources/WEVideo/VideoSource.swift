import AVFoundation
import CoreVideo
import Foundation
import VideoToolbox

public enum VideoError: Error, CustomStringConvertible {
    case unsupported(String)
    case decode(String)
    public var description: String {
        switch self {
        case .unsupported(let s): return "unsupported video: \(s)"
        case .decode(let s): return "video decode failed: \(s)"
        }
    }
}

/// Decoded BGRA frames (Metal/IOSurface compatible) on demand, looping over the clip.
public class VideoSource {
    public let width: Int
    public let height: Int
    public let duration: Double
    public let codec: String

    private var current: (pts: Double, buffer: CVPixelBuffer)?
    private var pending: (pts: Double, buffer: CVPixelBuffer)?
    private var exhausted = false

    init(width: Int, height: Int, duration: Double, codec: String) {
        self.width = width
        self.height = height
        self.duration = duration
        self.codec = codec
    }

    /// Opens `url` with the right backend: WebM/Matroska → our demuxer + VideoToolbox, everything else
    /// (mp4, mov, m4v…) → AVAssetReader.
    public static func open(_ url: URL) throws -> VideoSource {
        switch url.pathExtension.lowercased() {
        case "webm", "mkv": return try WebMVideoSource(url: url)
        default: return try AssetVideoSource(url: url)
        }
    }

    /// The frame on screen at `time` seconds (looping): the last frame whose timestamp is ≤ time.
    public func frame(at time: Double) throws -> CVPixelBuffer? {
        let t = duration > 0 ? time.truncatingRemainder(dividingBy: duration) : time
        let epsilon = 1e-4
        // Time went backwards (loop or seek): decode again from the start.
        if let current, t < current.pts - epsilon {
            try restart()
            self.current = nil; pending = nil; exhausted = false
        }
        while true {
            if pending == nil && !exhausted {
                pending = try next()
                if pending == nil { exhausted = true }
            }
            guard let p = pending, p.pts <= t + epsilon else { break }
            current = p
            pending = nil
        }
        return current?.buffer ?? pending?.buffer
    }

    // Backend hooks.
    func restart() throws {}
    func next() throws -> (pts: Double, buffer: CVPixelBuffer)? { nil }

    static let outputAttributes: [CFString: Any] = [
        kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_32BGRA,
        kCVPixelBufferMetalCompatibilityKey: true,
        kCVPixelBufferIOSurfacePropertiesKey: [:] as [CFString: Any],
    ]
}

// MARK: - WebM → VideoToolbox

final class WebMVideoSource: VideoSource {
    let file: WebMFile
    let format: CMVideoFormatDescription
    var session: VTDecompressionSession?
    var cursor = 0
    var decoded: [(pts: Double, buffer: CVPixelBuffer)] = []

    init(url: URL) throws {
        let file = try WebMFile(url: url)
        self.file = file
        let codecType: CMVideoCodecType
        var atoms: [String: Any] = [:]
        switch file.codecID {
        case "V_VP9":
            VTRegisterSupplementalVideoDecoderIfAvailable(kCMVideoCodecType_VP9)
            codecType = kCMVideoCodecType_VP9
            atoms["vpcC"] = Self.vpcC(firstFrame: file.packets.first.map { file.bytes($0) } ?? Data())
        case "V_AV1":
            codecType = kCMVideoCodecType_AV1
            atoms["av1C"] = file.codecPrivate
        case "V_VP8":
            throw VideoError.unsupported("VP8 (no VP8 decoder on macOS; WebKit fallback not implemented yet)")
        default:
            throw VideoError.unsupported("WebM codec \(file.codecID)")
        }
        guard VTIsHardwareDecodeSupported(codecType) else {
            throw VideoError.unsupported("\(file.codecID): no hardware decoder on this Mac")
        }
        var desc: CMVideoFormatDescription?
        let status = CMVideoFormatDescriptionCreate(
            allocator: nil, codecType: codecType, width: Int32(file.width), height: Int32(file.height),
            extensions: [kCMFormatDescriptionExtension_SampleDescriptionExtensionAtoms: atoms] as CFDictionary,
            formatDescriptionOut: &desc)
        guard status == noErr, let desc else { throw VideoError.decode("format description (\(status))") }
        format = desc
        super.init(width: file.width, height: file.height, duration: file.duration,
                   codec: file.codecID.replacingOccurrences(of: "V_", with: "").lowercased())
        try restart()
    }

    deinit { if let session { VTDecompressionSessionInvalidate(session) } }

    /// VP9 codec configuration record (`vpcC`, FullBox version 1). WebM carries no such record, so it
    /// is derived from the first frame's uncompressed header (profile); bit depth / chroma assume the
    /// common 8-bit 4:2:0 case, colour description BT.709.
    static func vpcC(firstFrame: Data) -> Data {
        let b0 = firstFrame.first ?? 0
        // frame_marker(2) profile_low_bit profile_high_bit
        let profile: UInt8 = ((b0 >> 5) & 1) | (((b0 >> 4) & 1) << 1)
        let bitDepthChroma: UInt8 = (8 << 4) | (1 << 1) // 8-bit, 4:2:0 colocated, limited range
        return Data([1, 0, 0, 0, profile, 0, bitDepthChroma, 1, 1, 1, 0, 0])
    }

    override func restart() throws {
        if let session { VTDecompressionSessionInvalidate(session) }
        var s: VTDecompressionSession?
        let status = VTDecompressionSessionCreate(
            allocator: nil, formatDescription: format,
            decoderSpecification: [kVTVideoDecoderSpecification_EnableHardwareAcceleratedVideoDecoder: true] as CFDictionary,
            imageBufferAttributes: Self.outputAttributes as CFDictionary, outputCallback: nil, decompressionSessionOut: &s)
        guard status == noErr, let s else { throw VideoError.decode("decompression session (\(status))") }
        session = s
        cursor = 0
        decoded = []
    }

    override func next() throws -> (pts: Double, buffer: CVPixelBuffer)? {
        // Hidden frames (VP9 alt-ref, AV1 non-shown) produce no output: keep feeding until one appears.
        while decoded.isEmpty {
            guard cursor < file.packets.count, let session else { return nil }
            let packet = file.packets[cursor]
            cursor += 1
            try decode(packet, session: session)
        }
        return decoded.removeFirst()
    }

    func decode(_ packet: WebMFile.Packet, session: VTDecompressionSession) throws {
        let bytes = file.bytes(packet)
        var block: CMBlockBuffer?
        var status = CMBlockBufferCreateWithMemoryBlock(
            allocator: nil, memoryBlock: nil, blockLength: bytes.count, blockAllocator: nil, customBlockSource: nil,
            offsetToData: 0, dataLength: bytes.count, flags: kCMBlockBufferAssureMemoryNowFlag, blockBufferOut: &block)
        guard status == noErr, let block else { throw VideoError.decode("block buffer (\(status))") }
        bytes.withUnsafeBytes { _ = CMBlockBufferReplaceDataBytes(with: $0.baseAddress!, blockBuffer: block, offsetIntoDestination: 0, dataLength: bytes.count) }
        var sample: CMSampleBuffer?
        var timing = CMSampleTimingInfo(duration: .invalid, presentationTimeStamp: CMTime(seconds: packet.pts, preferredTimescale: 90_000),
                                        decodeTimeStamp: .invalid)
        var size = bytes.count
        status = CMSampleBufferCreateReady(allocator: nil, dataBuffer: block, formatDescription: format, sampleCount: 1,
                                           sampleTimingEntryCount: 1, sampleTimingArray: &timing, sampleSizeEntryCount: 1,
                                           sampleSizeArray: &size, sampleBufferOut: &sample)
        guard status == noErr, let sample else { throw VideoError.decode("sample buffer (\(status))") }
        var failure: OSStatus = noErr
        status = VTDecompressionSessionDecodeFrame(session, sampleBuffer: sample, flags: [], infoFlagsOut: nil) { [weak self] st, _, image, pts, _ in
            if st != noErr { failure = st; return }
            if let image { self?.decoded.append((pts.seconds, image)) }
        }
        VTDecompressionSessionWaitForAsynchronousFrames(session)
        if status != noErr || failure != noErr { throw VideoError.decode("frame at \(packet.pts)s (\(status != noErr ? status : failure))") }
        decoded.sort { $0.pts < $1.pts }
    }
}

// MARK: - AVAssetReader (mp4, mov…)

final class AssetVideoSource: VideoSource {
    let asset: AVURLAsset
    let track: AVAssetTrack
    var reader: AVAssetReader?
    var output: AVAssetReaderTrackOutput?

    init(url: URL) throws {
        let asset = AVURLAsset(url: url)
        self.asset = asset
        let (track, size, duration, codec) = try blocking {
            guard let track = try await asset.loadTracks(withMediaType: .video).first else {
                throw VideoError.unsupported("no video track in \(url.lastPathComponent)")
            }
            let (size, formats) = try await track.load(.naturalSize, .formatDescriptions)
            let duration = try await asset.load(.duration)
            let subtype = formats.first.map { CMFormatDescriptionGetMediaSubType($0) } ?? 0
            let codec = String(bytes: [24, 16, 8, 0].map { UInt8((subtype >> $0) & 0xFF) }, encoding: .ascii) ?? "?"
            return (track, size, duration.seconds, codec)
        }
        self.track = track
        super.init(width: Int(size.width), height: Int(size.height), duration: duration, codec: codec)
        try restart()
    }

    override func restart() throws {
        reader?.cancelReading()
        let r = try AVAssetReader(asset: asset)
        let o = AVAssetReaderTrackOutput(track: track, outputSettings: Self.outputAttributes as [String: Any])
        o.alwaysCopiesSampleData = false
        r.add(o)
        guard r.startReading() else { throw VideoError.decode(r.error.map { "\($0)" } ?? "reader failed to start") }
        reader = r
        output = o
    }

    override func next() throws -> (pts: Double, buffer: CVPixelBuffer)? {
        while let sample = output?.copyNextSampleBuffer() {
            if let image = CMSampleBufferGetImageBuffer(sample) {
                return (CMSampleBufferGetPresentationTimeStamp(sample).seconds, image)
            }
        }
        if let r = reader, r.status == .failed { throw VideoError.decode(r.error.map { "\($0)" } ?? "reader failed") }
        return nil
    }
}

/// Run async AVFoundation loading from synchronous code (called off the main thread when loading).
func blocking<T>(_ body: @escaping () async throws -> T) throws -> T {
    let semaphore = DispatchSemaphore(value: 0)
    nonisolated(unsafe) var result: Result<T, Error>!
    Task.detached {
        do { result = .success(try await body()) } catch { result = .failure(error) }
        semaphore.signal()
    }
    semaphore.wait()
    return try result.get()
}
