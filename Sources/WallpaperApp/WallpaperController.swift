import AppKit
import MetalKit
import WERender

/// Owns the shared renderer and one desktop window per screen; decides when frames are drawn.
final class WallpaperController: NSObject, MTKViewDelegate {
    enum PauseReason: String, CaseIterable {
        case user = "paused by user"
        case screensAsleep = "displays asleep"
        case locked = "screen locked"
        case loading = "loading"
    }

    let device = MTLCreateSystemDefaultDevice()!
    private(set) var renderer: WallpaperRenderer?
    private(set) var windows: [DesktopWindow] = []
    private(set) var pauseReasons: Set<PauseReason> = [.loading]
    var onStateChange: (() -> Void)?
    private(set) var loadError: String?

    var fps: Int = 30 { didSet { applyState() } }

    // Animation clock that only advances while frames are being drawn.
    private var clock: Double = 0
    private var lastTick: CFTimeInterval?

    // Stats for the menu / log.
    private var frameCount = 0
    private var gpuTimeSum: Double = 0
    private var statsStart = CACurrentMediaTime()
    private(set) var measuredFPS: Double = 0
    private(set) var gpuMillis: Double = 0

    override init() {
        super.init()
        rebuildWindows()
        let nc = NotificationCenter.default
        nc.addObserver(self, selector: #selector(screensChanged), name: NSApplication.didChangeScreenParametersNotification, object: nil)
        let ws = NSWorkspace.shared.notificationCenter
        ws.addObserver(self, selector: #selector(screensSlept), name: NSWorkspace.screensDidSleepNotification, object: nil)
        ws.addObserver(self, selector: #selector(screensWoke), name: NSWorkspace.screensDidWakeNotification, object: nil)
        let dnc = DistributedNotificationCenter.default()
        dnc.addObserver(self, selector: #selector(locked), name: NSNotification.Name("com.apple.screenIsLocked"), object: nil)
        dnc.addObserver(self, selector: #selector(unlocked), name: NSNotification.Name("com.apple.screenIsUnlocked"), object: nil)
        nc.addObserver(self, selector: #selector(powerChanged), name: .NSProcessInfoPowerStateDidChange, object: nil)
    }

    // MARK: - loading

    /// Load a wallpaper off the main thread (shader compilation takes seconds), then start drawing.
    func load(wallpaper: URL, assets: URL?) {
        setPaused(.loading, true)
        loadError = nil
        let started = CACurrentMediaTime()
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                let r = try Wallpaper.open(project: wallpaper, assets: assets)
                // Hidden default for A/B measurements: `-disableLayerCache YES`.
                (r as? SceneRenderer)?.disableLayerCache = UserDefaults.standard.bool(forKey: "disableLayerCache")
                // Warm-up frame compiles every shader/pipeline before the first on-screen frame.
                _ = try r.render(width: 64, height: 36, time: 0)
                DispatchQueue.main.async {
                    self.renderer = r
                    self.clock = 0
                    for w in r.warnings { log("warning: \(w)") }
                    log(String(format: "ready in %.2fs (%@)", CACurrentMediaTime() - started, r.summary))
                    self.setPaused(.loading, false)
                }
            } catch {
                DispatchQueue.main.async {
                    self.loadError = "\(error)"
                    log("load failed: \(error)")
                    self.onStateChange?()
                }
            }
        }
    }

    // MARK: - windows

    @objc func screensChanged() { rebuildWindows() }

    func rebuildWindows() {
        let screens = NSScreen.screens
        windows.removeAll { w in
            let keep = screens.contains { $0.displayID == w.screenID }
            if !keep { w.close() }
            return !keep
        }
        for screen in screens {
            if let w = windows.first(where: { $0.screenID == screen.displayID }) {
                w.setFrame(screen.frame, display: true)
                continue
            }
            let w = DesktopWindow(screen: screen, device: device)
            w.metalView.delegate = self
            NotificationCenter.default.addObserver(self, selector: #selector(occlusionChanged(_:)),
                                                   name: NSWindow.didChangeOcclusionStateNotification, object: w)
            w.orderBack(nil)
            windows.append(w)
        }
        log("windows: \(windows.count) screen(s): " + screens.map { "\(Int($0.frame.width))x\(Int($0.frame.height))@\($0.backingScaleFactor)x" }.joined(separator: ", "))
        applyState()
    }

    // MARK: - power policy

    func setPaused(_ reason: PauseReason, _ paused: Bool) {
        if paused { pauseReasons.insert(reason) } else { pauseReasons.remove(reason) }
        applyState()
    }

    @objc func occlusionChanged(_ n: Notification) { applyState() }
    @objc func screensSlept() { setPaused(.screensAsleep, true) }
    @objc func screensWoke() { setPaused(.screensAsleep, false) }
    @objc func locked() { setPaused(.locked, true) }
    @objc func unlocked() { setPaused(.locked, false) }
    @objc func powerChanged() { DispatchQueue.main.async { self.applyState() } }

    /// Low Power Mode halves the frame rate.
    var effectiveFPS: Int { ProcessInfo.processInfo.isLowPowerModeEnabled ? max(10, fps / 2) : fps }

    func isVisible(_ w: DesktopWindow) -> Bool { w.occlusionState.contains(.visible) }

    func applyState() {
        let globallyPaused = !pauseReasons.isEmpty || renderer == nil
        for w in windows {
            w.metalView.preferredFramesPerSecond = effectiveFPS
            // Fully covered (e.g. a full-screen app on that display) → stop drawing that screen.
            w.metalView.isPaused = globallyPaused || !isVisible(w)
        }
        if globallyPaused || !windows.contains(where: { !$0.metalView.isPaused }) { lastTick = nil }
        onStateChange?()
    }

    var statusText: String {
        if let e = loadError { return "Error: \(e)" }
        if !pauseReasons.isEmpty { return "Paused (" + pauseReasons.map(\.rawValue).sorted().joined(separator: ", ") + ")" }
        let drawing = windows.filter { !$0.metalView.isPaused }.count
        if drawing == 0 { return "Paused (desktop covered)" }
        return String(format: "Drawing %d/%d screen(s) · %.0f fps · GPU %.1f ms", drawing, windows.count, measuredFPS, gpuMillis)
    }

    // MARK: - MTKViewDelegate

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}

    func draw(in view: MTKView) {
        guard let renderer, let drawable = view.currentDrawable else { return }
        // Advance the clock once per display refresh, not once per screen.
        let now = CACurrentMediaTime()
        if view === windows.first(where: { !$0.metalView.isPaused })?.metalView {
            if let last = lastTick { clock += min(now - last, 0.25) }
            lastTick = now
            frameCount += 1
        }
        guard let cb = renderer.queue.makeCommandBuffer() else { return }
        renderer.encodeFrame(into: drawable.texture, commandBuffer: cb, time: Float(clock))
        cb.present(drawable)
        cb.addCompletedHandler { [weak self] cb in
            let t = cb.gpuEndTime - cb.gpuStartTime
            DispatchQueue.main.async { self?.gpuTimeSum += t }
        }
        cb.commit()

        if now - statsStart >= 5 {
            measuredFPS = Double(frameCount) / (now - statsStart)
            gpuMillis = frameCount > 0 ? gpuTimeSum / Double(frameCount) * 1000 : 0
            log(String(format: "stats: %.1f fps, GPU %.2f ms/frame, drawable %dx%d", measuredFPS, gpuMillis,
                       Int(view.drawableSize.width), Int(view.drawableSize.height)))
            frameCount = 0; gpuTimeSum = 0; statsStart = now
            onStateChange?()
        }
    }
}

func log(_ s: String) {
    let line = "[\(ISO8601DateFormatter().string(from: Date()))] \(s)\n"
    FileHandle.standardError.write(Data(line.utf8))
}
