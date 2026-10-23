import AppKit
import MetalKit
import WEAudio
import WERender
import WEWeb

/// Owns the shared renderer and one desktop window per screen; decides when frames are drawn.
/// Web wallpapers (and VP8 videos) instead get one WKWebView per screen, swapped in for the Metal view.
@MainActor
final class WallpaperController: NSObject, MTKViewDelegate {
    enum PauseReason: String, CaseIterable {
        case user = "paused by user"
        case screensAsleep = "displays asleep"
        case locked = "screen locked"
        case loading = "loading"
    }

    let device = MTLCreateSystemDefaultDevice()!
    private(set) var renderer: WallpaperRenderer?
    /// Set while a web wallpaper / WebKit video is shown.
    private(set) var webRequest: WebContentRequest?
    private var webViews: [CGDirectDisplayID: WebWallpaper] = [:]
    private var webPaused: [CGDirectDisplayID: Bool] = [:]
    private(set) var windows: [DesktopWindow] = []
    private(set) var pauseReasons: Set<PauseReason> = [.loading]
    var onStateChange: (() -> Void)?
    private(set) var loadError: String?

    /// Cursor input for scenes (`g_Pointer*`, parallax) and web pages.
    var mouseInput = true {
        didSet { updateMouseMonitor() }
    }
    private let tracker = PointerTracker()
    private var pointers: [CGDirectDisplayID: SceneRenderer.PointerInput] = [:]
    private var mouseMonitor: Any?
    /// Screen whose page got the last forwarded mouse-down (its mouse-up goes there too).
    private var mouseDownScreen: CGDirectDisplayID?
    private var pendingMove: (screen: CGDirectDisplayID, point: CGPoint, buttons: Int)?

    /// Audio spectrum for audio-reactive wallpapers (opt-in: Screen Recording permission).
    var audioEnabled = false {
        didSet { updateAudio() }
    }
    let audio = AudioFeed()
    private var audioTimer: Timer?
    /// This frame's spectrum, shared by all screens.
    private var frameAudio = AudioSpectrum()

    /// How the wallpaper maps onto screens of another shape (per wallpaper, set by the app delegate).
    var contentMode: ContentMode = .fill {
        didSet { renderer?.contentMode = contentMode }
    }

    /// Volume of the wallpaper's own sounds (music, effects); 0 = off.
    var soundVolume: Float = 1 {
        didSet { updateSound() }
    }

    var fps: Int = 30 {
        didSet {
            webViews.values.forEach { $0.setFPS(effectiveFPS) }
            applyState()
        }
    }

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
        audio.onStateChange = { [weak self] in self?.audioStateChanged() }
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
                // Before the warm-up frame: scripts may start sounds from init(). Nothing plays until active.
                do { try (r as? SceneRenderer)?.enableSound() } catch { log("sound: \(error)") }
                // Warm-up frame compiles every shader/pipeline before the first on-screen frame.
                _ = try r.render(width: 64, height: 36, time: 0)
                DispatchQueue.main.async {
                    self.detachWeb()
                    (self.renderer as? SceneRenderer)?.sound?.setActive(false)
                    r.contentMode = self.contentMode
                    self.renderer = r
                    self.clock = 0
                    self.pointers = [:]
                    self.updateMouseMonitor()
                    self.updateAudio()
                    for w in r.warnings { log("warning: \(w)") }
                    log(String(format: "ready in %.2fs (%@)", CACurrentMediaTime() - started, r.summary))
                    self.setPaused(.loading, false)
                }
            } catch WallpaperError.needsWebKit(let request) {
                DispatchQueue.main.async {
                    self.detachWeb()
                    (self.renderer as? SceneRenderer)?.sound?.setActive(false)
                    self.renderer = nil
                    self.webRequest = request
                    self.windows.forEach(self.attachWeb)
                    self.updateMouseMonitor()
                    self.updateAudio()
                    log(String(format: "ready in %.2fs (%@)", CACurrentMediaTime() - started, "\(WallpaperError.needsWebKit(request))"))
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

    // MARK: - web content

    func attachWeb(_ window: DesktopWindow) {
        guard let request = webRequest, webViews[window.screenID] == nil else { return }
        let web = WebWallpaper(request: request, fps: effectiveFPS)
        web.onWarning = { log("warning (web): \($0)") }
        web.onAudioListener = { [weak self] in self?.updateAudio() }
        web.webView.frame = window.contentLayoutRect
        window.contentView = web.webView
        webViews[window.screenID] = web
        webPaused[window.screenID] = nil
    }

    func detachWeb() {
        for w in windows where webViews[w.screenID] != nil { w.contentView = w.metalView }
        webViews = [:]
        webPaused = [:]
        webRequest = nil
    }

    // MARK: - mouse (web pages)

    /// Web pages get mouse events from a global monitor while the cursor is over the desktop.
    func updateMouseMonitor() {
        let want = mouseInput && { if case .page? = webRequest { return true } else { return false } }()
        if want, mouseMonitor == nil {
            mouseMonitor = NSEvent.addGlobalMonitorForEvents(
                matching: [.mouseMoved, .leftMouseDragged, .rightMouseDragged, .leftMouseDown, .leftMouseUp,
                           .rightMouseDown, .rightMouseUp]) { [weak self] event in
                let type = event.type
                MainActor.assumeIsolated { self?.forwardMouse(type) }
            }
        } else if !want, let m = mouseMonitor {
            NSEvent.removeMonitor(m)
            mouseMonitor = nil
            mouseDownScreen = nil
        }
    }

    func forwardMouse(_ type: NSEvent.EventType) {
        let m = NSEvent.mouseLocation
        let isUp = type == .leftMouseUp || type == .rightMouseUp
        guard let window = windows.first(where: { $0.frame.contains(m) }) ?? (isUp ? windows.first { $0.screenID == mouseDownScreen } : nil),
              let web = webViews[window.screenID], webPaused[window.screenID] == false else { return }
        // Page coordinates: CSS pixels from the window's top-left.
        let point = CGPoint(x: m.x - window.frame.minX, y: window.frame.maxY - m.y)
        switch type {
        case .leftMouseDown, .rightMouseDown:
            guard tracker.isOverDesktop(m) else { return }
            mouseDownScreen = window.screenID
            web.sendMouse(type, at: point)
        case .leftMouseUp, .rightMouseUp:
            // Only the up that ends a forwarded down (the press may have started over an app window).
            guard mouseDownScreen == window.screenID else { return }
            mouseDownScreen = nil
            web.sendMouse(type, at: point)
        default:
            guard tracker.isOverDesktop(m) else { return }
            // Coalesce moves (the mouse reports at 120 Hz+) to one page update per 1/60 s.
            let flush = pendingMove == nil
            pendingMove = (window.screenID, point, NSEvent.pressedMouseButtons & 3)
            if flush {
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.0 / 60) { [weak self] in
                    MainActor.assumeIsolated {
                        guard let self, let move = self.pendingMove else { return }
                        self.pendingMove = nil
                        self.webViews[move.screen]?.sendMouseMove(to: move.point, buttons: move.buttons)
                    }
                }
            }
        }
    }

    // MARK: - audio

    /// Capture only while enabled, not paused, and the wallpaper reads audio (a scene with
    /// g_AudioSpectrum uniforms, or a page that registered an audio listener).
    func updateAudio() {
        let used = (renderer as? SceneRenderer)?.usesAudio == true || webViews.values.contains { $0.hasAudioListeners }
        let active = audioEnabled && used && pauseReasons.isEmpty && windows.contains(where: isVisible)
        audio.setActive(active)
        // Web pages: push the spectrum at 30 Hz (scenes read it per frame in drawFrame).
        let pushWeb = active && webRequest != nil
        if pushWeb, audioTimer == nil {
            var last = CACurrentMediaTime()
            audioTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 30, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self, self.audio.isRunning else { return }
                    let now = CACurrentMediaTime()
                    let values = self.audio.analyzer.update(dt: now - last).web128
                    last = now
                    for (screen, web) in self.webViews where web.hasAudioListeners && self.webPaused[screen] == false {
                        web.sendAudio(values)
                    }
                }
            }
        } else if !pushWeb, let t = audioTimer {
            t.invalidate()
            audioTimer = nil
            // Leave listeners at silence rather than the last frame.
            for web in webViews.values where web.hasAudioListeners { web.sendAudio(AudioSpectrum().web128) }
        }
    }

    /// Wallpaper sounds play while the wallpaper runs and is visible on some screen.
    func updateSound() {
        guard let sound = (renderer as? SceneRenderer)?.sound else { return }
        sound.setMasterVolume(soundVolume)
        sound.setActive(soundVolume > 0 && pauseReasons.isEmpty && windows.contains(where: isVisible))
    }

    func audioStateChanged() {
        if !audio.isRunning { frameAudio = AudioSpectrum() }
        onStateChange?()
    }

    // MARK: - windows

    @objc func screensChanged() { rebuildWindows() }

    func rebuildWindows() {
        let screens = NSScreen.screens
        windows.removeAll { w in
            let keep = screens.contains { $0.displayID == w.screenID }
            if !keep { w.close(); webViews[w.screenID] = nil; webPaused[w.screenID] = nil }
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
            attachWeb(w)
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
        defer { updateAudio(); updateSound() }
        if webRequest != nil {
            // Web content: pause each screen's page while paused or fully covered (setPaused only on change).
            for w in windows {
                w.metalView.isPaused = true
                guard let web = webViews[w.screenID] else { continue }
                let paused = !pauseReasons.isEmpty || !isVisible(w)
                if webPaused[w.screenID] != paused {
                    web.setPaused(paused)
                    webPaused[w.screenID] = paused
                }
            }
            onStateChange?()
            return
        }
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
        let audioNote = audio.statusText.map { " · \($0)" } ?? ""
        if let request = webRequest {
            let showing = webPaused.values.filter { !$0 }.count
            let kind = if case .video = request { "Video (WebKit)" } else { "Web page" }
            return showing == 0 ? "\(kind) · paused (desktop covered)" : "\(kind) · showing on \(showing)/\(windows.count) screen(s)" + audioNote
        }
        let drawing = windows.filter { !$0.metalView.isPaused }.count
        if drawing == 0 { return "Paused (desktop covered)" }
        return String(format: "Drawing %d/%d screen(s) · %.0f fps · GPU %.1f ms", drawing, windows.count, measuredFPS, gpuMillis) + audioNote
    }

    // MARK: - MTKViewDelegate

    nonisolated func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}

    nonisolated func draw(in view: MTKView) {
        MainActor.assumeIsolated { drawFrame(in: view) }
    }

    func drawFrame(in view: MTKView) {
        guard let renderer, let drawable = view.currentDrawable else { return }
        // Advance the clock once per display refresh, not once per screen.
        let now = CACurrentMediaTime()
        if view === windows.first(where: { !$0.metalView.isPaused })?.metalView {
            let dt = lastTick.map { min(now - $0, 0.25) } ?? 0
            clock += dt
            lastTick = now
            if audio.isRunning { frameAudio = audio.analyzer.update(dt: dt) }
            frameCount += 1
        }
        guard let cb = renderer.queue.makeCommandBuffer() else { return }
        let scene = renderer as? SceneRenderer
        let window = windows.first { $0.metalView === view }
        if let scene, let window {
            // Per-screen cursor state; the position holds while the cursor is elsewhere.
            var input = pointers[window.screenID] ?? SceneRenderer.PointerInput()
            if mouseInput, let p = tracker.position(in: window.frame) {
                input.position = p
                input.state = PointerTracker.buttonState
            } else {
                input.state = .zero
            }
            scene.pointer = input
            scene.audio = frameAudio
        }
        renderer.encodeFrame(into: drawable.texture, commandBuffer: cb, time: Float(clock))
        if let scene, let window { pointers[window.screenID] = scene.pointer }
        cb.present(drawable)
        cb.addCompletedHandler { [weak self] cb in
            let t = cb.gpuEndTime - cb.gpuStartTime
            DispatchQueue.main.async { self?.gpuTimeSum += t }
        }
        cb.commit()

        if now - statsStart >= 5 {
            measuredFPS = Double(frameCount) / (now - statsStart)
            gpuMillis = frameCount > 0 ? gpuTimeSum / Double(frameCount) * 1000 : 0
            let p = window.flatMap { pointers[$0.screenID] }.map { String(format: ", pointer %.2f,%.2f", $0.position.x, $0.position.y) } ?? ""
            log(String(format: "stats: %.1f fps, GPU %.2f ms/frame, drawable %dx%d", measuredFPS, gpuMillis,
                       Int(view.drawableSize.width), Int(view.drawableSize.height)) + p)
            frameCount = 0; gpuTimeSum = 0; statsStart = now
            onStateChange?()
        }
    }
}

func log(_ s: String) {
    let line = "[\(ISO8601DateFormatter().string(from: Date()))] \(s)\n"
    FileHandle.standardError.write(Data(line.utf8))
}
