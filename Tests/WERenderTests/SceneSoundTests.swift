import AVFoundation
import WEFormat
import XCTest
@testable import WERender

final class SceneSoundTests: XCTestCase {
    var folder: URL!

    override func setUpWithError() throws {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("sound-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder.appendingPathComponent("sounds"), withIntermediateDirectories: true)
        try tone("sounds/a.wav", seconds: 0.5)
        try tone("sounds/b.wav", seconds: 0.5)
        // A WAV file saved with the wrong extension, like the Ogg files named ".mp3" in real wallpapers.
        try tone("sounds/c.wav", seconds: 0.5)
        try FileManager.default.moveItem(at: folder.appendingPathComponent("sounds/c.wav"),
                                         to: folder.appendingPathComponent("sounds/misnamed.mp3"))
    }

    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: folder) }

    func tone(_ path: String, seconds: Double) throws {
        let format = AVAudioFormat(standardFormatWithSampleRate: 48000, channels: 2)!
        let frames = AVAudioFrameCount(48000 * seconds)
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames)!
        buffer.frameLength = frames
        for c in 0..<2 { for i in 0..<Int(frames) { buffer.floatChannelData![c][i] = 0.5 * sin(Float(i) * 0.05) } }
        let file = try AVAudioFile(forWriting: folder.appendingPathComponent(path), settings: format.settings)
        try file.write(from: buffer)
    }

    func sound(_ id: Int, _ files: [String], mode: String = "loop", silent: Bool = false, volume: Double = 1) -> SoundObject {
        SoundObject(object: ["id": id, "sound": files, "playbackmode": mode, "startsilent": silent, "volume": volume],
                    properties: UserProperties(project: [:]))!
    }

    func player(_ sounds: [SoundObject]) throws -> SceneSoundPlayer {
        try SceneSoundPlayer(sounds: sounds, locator: AssetLocator(project: folder, assets: nil), offlineFrames: 4800)
    }

    /// Lets a change reach the mixer (it applies on the next render slice) before measuring silence.
    func settle(_ p: SceneSoundPlayer) throws { _ = try level(p, seconds: 0.1) }

    /// RMS of the next `seconds` of the mix.
    func level(_ p: SceneSoundPlayer, seconds: Double) throws -> Float {
        var sum: Float = 0, count = 0
        for _ in 0..<Int(seconds * 10) {
            let b = try p.renderOffline(frames: 4800)
            for i in 0..<Int(b.frameLength) { sum += b.floatChannelData![0][i] * b.floatChannelData![0][i] }
            count += Int(b.frameLength)
        }
        return (sum / Float(max(count, 1))).squareRoot()
    }

    func testParsing() {
        let s = SoundObject(object: ["id": 3, "sound": ["x.mp3"], "playbackmode": "random", "mintime": 2, "maxtime": 4,
                                     "startsilent": true, "volume": ["user": "music", "value": 0.7]],
                            properties: UserProperties(project: [:], overrides: ["music": "0.25"]))!
        XCTAssertEqual(s.mode, .random); XCTAssertEqual(s.volume, 0.25); XCTAssertTrue(s.startSilent)
        XCTAssertEqual(s.minTime, 2); XCTAssertEqual(s.maxTime, 4)
        XCTAssertNil(SoundObject(object: ["sound": []], properties: UserProperties(project: [:])))
    }

    func testLoopPlaysAndKeepsPlaying() throws {
        let p = try player([sound(1, ["sounds/a.wav", "sounds/b.wav"])])
        p.setActive(true)
        XCTAssertGreaterThan(try level(p, seconds: 0.5), 0.2)
        // Past both files: the list loops.
        XCTAssertGreaterThan(try level(p, seconds: 2), 0.2)
        XCTAssertTrue(p.isPlaying(1))
    }

    func testStartSilentWaitsForPlayAndStopSilences() throws {
        let p = try player([sound(1, ["sounds/a.wav"], silent: true)])
        p.setActive(true)
        XCTAssertEqual(try level(p, seconds: 0.3), 0, accuracy: 1e-4)
        XCTAssertFalse(p.isPlaying(1))
        p.play(1)
        XCTAssertGreaterThan(try level(p, seconds: 0.3), 0.2)
        p.stop(1)
        try settle(p)
        XCTAssertEqual(try level(p, seconds: 0.3), 0, accuracy: 1e-4)
    }

    func testVolumeAndSingleShot() throws {
        let p = try player([sound(1, ["sounds/a.wav"], volume: 0.5), sound(2, ["sounds/b.wav"], mode: "single", silent: true)])
        p.setActive(true)
        let half = try level(p, seconds: 0.3)
        p.setVolume(1, 0)
        try settle(p)
        XCTAssertEqual(try level(p, seconds: 0.3), 0, accuracy: 1e-4)
        XCTAssertGreaterThan(half, 0.1)
        p.play(2)
        XCTAssertGreaterThan(try level(p, seconds: 0.3), 0.2)
        // The 0.5 s file ends and is not repeated.
        _ = try level(p, seconds: 0.5)
        XCTAssertEqual(try level(p, seconds: 0.3), 0, accuracy: 1e-4)
    }

    func testMisnamedFileIsSniffed() throws {
        let p = try player([sound(1, ["sounds/misnamed.mp3"])])
        p.setActive(true)
        XCTAssertGreaterThan(try level(p, seconds: 0.3), 0.2)
    }

    func testInactivePlayerIsSilentUntilActivated() throws {
        let p = try player([sound(1, ["sounds/a.wav"])])
        p.setActive(true); p.setActive(false)
        p.setActive(true)
        XCTAssertGreaterThan(try level(p, seconds: 0.3), 0.2)
    }
}
