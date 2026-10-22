import AppKit
import WEAudio

/// The system-audio spectrum for audio-reactive wallpapers. Opt-in (menu), since ScreenCaptureKit needs
/// the Screen Recording permission; the controller runs it only while the wallpaper uses audio and is
/// not paused.
@MainActor
final class AudioFeed {
    enum State: Equatable {
        case off, starting, running
        case failed(String)
    }

    let analyzer = SpectrumAnalyzer()
    private lazy var capture: SystemAudioCapture = {
        let c = SystemAudioCapture(analyzer: analyzer)
        c.onStop = { [weak self] error in
            DispatchQueue.main.async { self?.stopped(error) }
        }
        return c
    }()
    private(set) var state: State = .off
    private var wanted = false
    var onStateChange: (() -> Void)?

    var isRunning: Bool { state == .running }

    /// Start or stop capturing (idempotent).
    func setActive(_ active: Bool) {
        guard active != wanted else { return }
        wanted = active
        if active {
            state = .starting
            onStateChange?()
            Task { @MainActor in
                do {
                    try await capture.start()
                    // Turned off while starting.
                    if !wanted { capture.stop(); state = .off } else { state = .running; log("audio capture started") }
                } catch {
                    state = .failed("\(error)")
                    wanted = false
                    log("audio capture failed: \(error)")
                }
                onStateChange?()
            }
        } else {
            capture.stop()
            analyzer.reset()
            state = .off
            log("audio capture stopped")
            onStateChange?()
        }
    }

    private func stopped(_ error: Error) {
        guard wanted else { return }
        wanted = false
        analyzer.reset()
        state = .failed("\(error.localizedDescription)")
        log("audio capture stopped: \(error)")
        onStateChange?()
    }

    var statusText: String? {
        switch state {
        case .off: return nil
        case .starting: return "audio starting"
        case .running: return "audio on"
        case .failed(let e): return "audio: \(e)"
        }
    }
}
