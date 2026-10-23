import AVFoundation
import Foundation

/// Entirely synthetic: red for one second, blue for one second, 16×16 H.264.
func makeVideoTextureMP4(at url: URL) async throws -> Data {
    let writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
    let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
        AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: 16, AVVideoHeightKey: 16,
        AVVideoCompressionPropertiesKey: [AVVideoMaxKeyFrameIntervalKey: 1]])
    let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
        kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
        kCVPixelBufferWidthKey as String: 16, kCVPixelBufferHeightKey as String: 16])
    writer.add(input)
    guard writer.startWriting() else { throw writer.error ?? NSError(domain: "VideoFixture", code: 1) }
    writer.startSession(atSourceTime: .zero)
    for index in 0..<4 {
        while !input.isReadyForMoreMediaData {
            if writer.status == .failed { throw writer.error! }
            try await Task.sleep(nanoseconds: 1_000_000)
        }
        var buffer: CVPixelBuffer?
        let status = CVPixelBufferPoolCreatePixelBuffer(nil, adaptor.pixelBufferPool!, &buffer)
        guard status == kCVReturnSuccess, let buffer else { throw NSError(domain: "VideoFixture", code: Int(status)) }
        CVPixelBufferLockBaseAddress(buffer, [])
        let base = CVPixelBufferGetBaseAddress(buffer)!.assumingMemoryBound(to: UInt8.self)
        for y in 0..<16 {
            for x in 0..<16 {
                let offset = y * CVPixelBufferGetBytesPerRow(buffer) + x * 4
                base[offset] = index < 2 ? 0 : 255
                base[offset + 1] = 0
                base[offset + 2] = index < 2 ? 255 : 0
                base[offset + 3] = 255
            }
        }
        CVPixelBufferUnlockBaseAddress(buffer, [])
        guard adaptor.append(buffer, withPresentationTime: CMTime(value: Int64(index), timescale: 2)) else {
            throw writer.error ?? NSError(domain: "VideoFixture", code: 2)
        }
    }
    writer.endSession(atSourceTime: CMTime(value: 2, timescale: 1))
    input.markAsFinished()
    await writer.finishWriting()
    guard writer.status == .completed else { throw writer.error ?? NSError(domain: "VideoFixture", code: 3) }
    return try Data(contentsOf: url)
}

func wrapVideoTexture(_ mp4: Data, version: Int, videoFlag: Bool = true, mp4Flag: Bool = true) -> Data {
    var data = Data("TEXV0005\0TEXI0001\0".utf8)
    func word(_ n: Int) {
        var value = Int32(n).littleEndian
        withUnsafeBytes(of: &value) { data.append(contentsOf: $0) }
    }
    for n in [0, videoFlag ? 34 : 2, 16, 16, 16, 16, 0] { word(n) }
    data.append(contentsOf: "TEXB000\(version)\0".utf8)
    word(1)
    if version >= 3 { word(-1) }
    if version == 4 { word(mp4Flag ? 1 : 0) }
    word(1)
    if version == 4 && mp4Flag {
        word(1); word(2); data.append(contentsOf: "{}\0".utf8); word(1)
    }
    word(16); word(16)
    if version >= 2 { word(0); word(0) }
    word(mp4.count); data.append(mp4)
    return data
}
