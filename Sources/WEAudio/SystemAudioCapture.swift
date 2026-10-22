import CoreMedia
import CoreGraphics
import Foundation
import ScreenCaptureKit

/// Captures what the Mac is playing (all apps but this one) with ScreenCaptureKit and feeds it to a
/// `SpectrumAnalyzer`. Needs the Screen Recording permission (System Settings → Privacy & Security);
/// the stream asks for a tiny 1 fps video track that is ignored, since ScreenCaptureKit always
/// captures a display.
public final class SystemAudioCapture: NSObject, SCStreamOutput, SCStreamDelegate, @unchecked Sendable {
    public enum CaptureError: Error, CustomStringConvertible {
        case permissionDenied, noDisplay
        public var description: String {
            switch self {
            case .permissionDenied: return "Screen Recording permission is needed to capture system audio"
            case .noDisplay: return "no display to capture from"
            }
        }
    }

    public let analyzer: SpectrumAnalyzer
    private var stream: SCStream?
    private let queue = DispatchQueue(label: "SystemAudioCapture")
    /// Called (on an arbitrary queue) when the stream stops with an error, e.g. permission revoked.
    public var onStop: ((Error) -> Void)?
    public var isRunning: Bool { stream != nil }

    public init(analyzer: SpectrumAnalyzer = SpectrumAnalyzer()) {
        self.analyzer = analyzer
    }

    /// Whether the permission is granted, without prompting.
    public static var hasPermission: Bool { CGPreflightScreenCaptureAccess() }

    /// Show the system prompt (first time only); later calls just report the current state.
    @discardableResult
    public static func requestPermission() -> Bool { CGRequestScreenCaptureAccess() }

    public func start() async throws {
        guard stream == nil else { return }
        guard Self.hasPermission else { throw CaptureError.permissionDenied }
        let content = try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: true)
        guard let display = content.displays.first else { throw CaptureError.noDisplay }
        let filter = SCContentFilter(display: display, excludingApplications: [], exceptingWindows: [])
        let config = SCStreamConfiguration()
        config.capturesAudio = true
        config.excludesCurrentProcessAudio = true
        config.sampleRate = 48000
        config.channelCount = 2
        config.width = 2
        config.height = 2
        config.minimumFrameInterval = CMTime(value: 1, timescale: 1)
        config.queueDepth = 3
        config.showsCursor = false
        let stream = SCStream(filter: filter, configuration: config, delegate: self)
        try stream.addStreamOutput(self, type: .audio, sampleHandlerQueue: queue)
        // Without a screen output ScreenCaptureKit logs every dropped video frame.
        try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: queue)
        try await stream.startCapture()
        self.stream = stream
    }

    public func stop() {
        guard let stream else { return }
        self.stream = nil
        stream.stopCapture { _ in }
    }

    public func stream(_ stream: SCStream, didStopWithError error: Error) {
        if self.stream === stream { self.stream = nil }
        onStop?(error)
    }

    public func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .audio, sampleBuffer.isValid,
              let format = sampleBuffer.formatDescription?.audioStreamBasicDescription,
              format.mFormatID == kAudioFormatLinearPCM, format.mFormatFlags & kAudioFormatFlagIsFloat != 0,
              format.mBitsPerChannel == 32 else { return }
        let frames = sampleBuffer.numSamples
        let channels = Int(format.mChannelsPerFrame)
        let interleaved = format.mFormatFlags & kAudioFormatFlagIsNonInterleaved == 0
        try? sampleBuffer.withAudioBufferList { list, _ in
            if interleaved, let data = list.first?.mData {
                // L R L R … → split.
                let p = data.assumingMemoryBound(to: Float.self)
                var l = [Float](repeating: 0, count: frames), r = l
                for i in 0..<frames {
                    l[i] = p[i * channels]
                    r[i] = channels > 1 ? p[i * channels + 1] : l[i]
                }
                analyzer.append(left: l, right: r)
            } else if let left = list.first?.mData {
                let l = UnsafeBufferPointer(start: left.assumingMemoryBound(to: Float.self), count: frames)
                let r = list.count > 1 ? list[1].mData.map {
                    UnsafeBufferPointer(start: $0.assumingMemoryBound(to: Float.self), count: frames)
                } : nil
                analyzer.append(left: l, right: r)
            }
        }
    }
}
