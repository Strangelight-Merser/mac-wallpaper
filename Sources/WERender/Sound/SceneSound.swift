import AVFoundation
import Foundation
import WEFormat

/// A scene sound object (`"sound": [files]`): music or effects the wallpaper plays.
public struct SoundObject {
    public enum Mode: String {
        /// Play the files in order, over and over.
        case loop
        /// Play a random file, then wait `minTime`…`maxTime` seconds, and again.
        case random
        /// Play once each time a script calls `play()`.
        case single
    }

    public let id: Int
    public let name: String
    public let files: [String]
    public let mode: Mode
    public let volume: Float
    /// Silent until a script starts it.
    public let startSilent: Bool
    public let minTime: Double
    public let maxTime: Double

    init?(object o: [String: Any], properties: UserProperties) {
        guard let files = o["sound"] as? [String], !files.isEmpty else { return nil }
        id = (o["id"] as? NSNumber)?.intValue ?? -1
        name = o["name"] as? String ?? "sound"
        self.files = files
        mode = Mode(rawValue: (properties.resolve(o["playbackmode"]) as? String)?.lowercased() ?? "loop") ?? .loop
        func f(_ k: String, _ d: Float) -> Float { parseFloats(properties.resolve(o[k]))?.first ?? d }
        volume = max(0, f("volume", 1))
        startSilent = properties.bool(o["startsilent"], default: false)
        minTime = Double(max(0, f("mintime", 1)))
        maxTime = Double(max(f("mintime", 1), f("maxtime", 5)))
    }
}

/// Plays a scene's sound objects through AVAudioEngine, one player node per object. All state lives on
/// a private serial queue; calls are safe from any thread.
public final class SceneSoundPlayer: @unchecked Sendable {
    private final class Track {
        let sound: SoundObject
        let node = AVAudioPlayerNode()
        var urls: [URL?]
        var volume: Float
        var playing = false
        var paused = false
        /// Bumped by stop/restart so completions of earlier schedules are ignored.
        var generation = 0
        var next = 0
        init(_ sound: SoundObject, urls: [URL?]) {
            self.sound = sound; self.urls = urls; volume = sound.volume
        }
    }

    private let engine = AVAudioEngine()
    private let queue = DispatchQueue(label: "SceneSoundPlayer")
    private var tracks: [Int: Track] = [:]
    private var active = false
    private var started = false
    private var masterVolume: Float = 1
    private var random = SystemRandomNumberGenerator()
    private let log: (String) -> Void
    private var logged = Set<String>()

    /// `offlineFrames`: render manually (tests and `wecli`) instead of to the output device.
    public init(sounds: [SoundObject], locator: AssetLocator, offlineFrames: AVAudioFrameCount? = nil,
                log: @escaping (String) -> Void = { _ in }) throws {
        self.log = log
        if let frames = offlineFrames {
            let format = AVAudioFormat(standardFormatWithSampleRate: 48000, channels: 2)!
            try engine.enableManualRenderingMode(.offline, format: format, maximumFrameCount: frames)
        }
        for sound in sounds {
            let track = Track(sound, urls: sound.files.map { locator.url($0) })
            engine.attach(track.node)
            engine.connect(track.node, to: engine.mainMixerNode, format: nil)
            track.node.volume = sound.volume
            tracks[sound.id] = track
        }
    }

    public var soundIDs: Set<Int> { Set(tracks.keys) }

    /// Plays while active (wallpaper visible and sound enabled); pausing keeps every track's position.
    public func setActive(_ on: Bool) {
        queue.async { [self] in
            guard on != active else { return }
            active = on
            if on {
                do { try engine.start() } catch { report("sound: audio engine: \(error.localizedDescription)"); return }
                if !started {
                    started = true
                    for t in tracks.values where !t.sound.startSilent && t.sound.mode != .single { start(t) }
                } else {
                    for t in tracks.values where t.playing && !t.paused { t.node.play() }
                }
            } else {
                engine.pause()
            }
        }
    }

    public func setMasterVolume(_ v: Float) {
        queue.async { [self] in masterVolume = max(0, v); engine.mainMixerNode.outputVolume = masterVolume }
    }

    public func play(_ id: Int) {
        queue.async { [self] in
            guard let t = tracks[id] else { return }
            if t.paused, t.sound.mode != .single { t.paused = false; if active { t.node.play() }; return }
            start(t)
        }
    }

    public func stop(_ id: Int) {
        queue.async { [self] in
            guard let t = tracks[id] else { return }
            t.generation += 1; t.playing = false; t.paused = false; t.next = 0
            t.node.stop()
        }
    }

    public func pause(_ id: Int) {
        queue.async { [self] in
            guard let t = tracks[id], t.playing, !t.paused else { return }
            t.paused = true
            t.node.pause()
        }
    }

    public func isPlaying(_ id: Int) -> Bool {
        queue.sync { tracks[id].map { $0.playing && !$0.paused } ?? false }
    }

    public func volume(_ id: Int) -> Float? { queue.sync { tracks[id]?.volume } }

    public func setVolume(_ id: Int, _ v: Float) {
        queue.async { [self] in
            guard let t = tracks[id] else { return }
            t.volume = max(0, v); t.node.volume = t.volume
        }
    }

    /// Offline mode: render `frames` frames of the mix (after letting queued commands run).
    public func renderOffline(frames: AVAudioFrameCount) throws -> AVAudioPCMBuffer {
        try queue.sync {
            let buffer = AVAudioPCMBuffer(pcmFormat: engine.manualRenderingFormat, frameCapacity: frames)!
            let status = try engine.renderOffline(frames, to: buffer)
            guard status == .success else { throw WEFormatError.unsupported("offline audio render: \(status.rawValue)") }
            return buffer
        }
    }

    // MARK: - on `queue`

    private func start(_ t: Track) {
        t.generation += 1
        t.node.stop()
        t.playing = true; t.paused = false
        t.next = t.sound.mode == .random ? Int.random(in: 0..<t.urls.count, using: &random) : 0
        schedule(t, generation: t.generation)
        if active { t.node.play() }
    }

    /// Schedules the track's next file; loops schedule the following one as soon as this one has been
    /// read (gapless), random waits `minTime`…`maxTime` after it finished, single stops.
    private func schedule(_ t: Track, generation: Int, attempts: Int = 0) {
        guard t.generation == generation, t.playing, attempts < t.urls.count else {
            if attempts >= t.urls.count { t.playing = false; report("sound: \(t.sound.name): no playable file") }
            return
        }
        let index = t.next
        let file: AVAudioFile
        do {
            guard let url = t.urls[index] else { throw WEFormatError.corrupt("file not found") }
            file = try AVAudioFile(forReading: Self.withTrueExtension(url))
        } catch {
            report("sound: \(t.sound.name): \(t.sound.files[index]): \(error.localizedDescription)")
            t.urls[index] = nil
            t.next = (index + 1) % t.urls.count
            schedule(t, generation: generation, attempts: attempts + 1)
            return
        }
        switch t.sound.mode {
        case .loop:
            t.next = (index + 1) % t.urls.count
            t.node.scheduleFile(file, at: nil, completionCallbackType: .dataConsumed) { [weak self] _ in
                self?.queue.async { self?.schedule(t, generation: generation) }
            }
        case .random:
            t.node.scheduleFile(file, at: nil, completionCallbackType: .dataPlayedBack) { [weak self] _ in
                self?.queue.async {
                    guard let self, t.generation == generation, t.playing else { return }
                    let wait = Double.random(in: t.sound.minTime...t.sound.maxTime, using: &self.random)
                    self.queue.asyncAfter(deadline: .now() + wait) {
                        guard t.generation == generation, t.playing else { return }
                        t.next = Int.random(in: 0..<t.urls.count, using: &self.random)
                        self.schedule(t, generation: generation)
                    }
                }
            }
        case .single:
            t.node.scheduleFile(file, at: nil, completionCallbackType: .dataPlayedBack) { [weak self] _ in
                self?.queue.async { if t.generation == generation { t.playing = false } }
            }
        }
    }

    /// AVFoundation picks the decoder by file extension, and workshop files are sometimes misnamed (Ogg
    /// Vorbis saved as ".mp3"). If the content says otherwise, open it through a correctly named symlink.
    static func withTrueExtension(_ url: URL) -> URL {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return url }
        defer { try? handle.close() }
        let head = [UInt8]((try? handle.read(upToCount: 12)) ?? Data())
        func starts(_ s: String, at offset: Int = 0) -> Bool {
            let b = Array(s.utf8)
            return head.count >= offset + b.count && Array(head[offset..<offset + b.count]) == b
        }
        let ext: String? = starts("OggS") ? "ogg" : starts("fLaC") ? "flac" : starts("RIFF") ? "wav"
            : starts("ID3") || (head.count > 1 && head[0] == 0xFF && head[1] & 0xE0 == 0xE0) ? "mp3"
            : starts("ftyp", at: 4) ? "m4a" : nil
        guard let ext, url.pathExtension.lowercased() != ext else { return url }
        let dir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("MacWallpaper/sound")
        // FNV-1a of the path: stable across launches, so links are reused rather than piling up.
        let name = String(format: "%016llx", url.standardizedFileURL.path.utf8.reduce(UInt64(0xcbf29ce484222325)) {
            ($0 ^ UInt64($1)) &* 0x100000001b3
        })
        let link = dir.appendingPathComponent(name).appendingPathExtension(ext)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try? FileManager.default.removeItem(at: link)
        do { try FileManager.default.createSymbolicLink(at: link, withDestinationURL: url) } catch { return url }
        return link
    }

    private func report(_ message: String) {
        if logged.insert(message).inserted { log(message) }
    }
}
