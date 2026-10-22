import AppKit
import WebKit
import WERender

/// Web wallpapers (Wallpaper Engine `type: "web"`) and the WebKit fallback for VP8 webm videos,
/// hosted in a WKWebView.
///
/// The page gets WE's JavaScript API through a bridge injected at document start:
/// `window.wallpaperPropertyListener` (`applyUserProperties`, `applyGeneralProperties`, `setPaused`),
/// `window.wallpaperRegisterAudioListener` and the media/plugin registration functions. Properties are
/// delivered as soon as the page assigns its listener, so pages that register late still get them.
@MainActor
public final class WebWallpaper: NSObject, WKNavigationDelegate, WKScriptMessageHandler {
    public enum Content {
        /// A web wallpaper: its index.html, the folder it may read, and its project.json properties
        /// as `{name: {type, value}}`.
        case page(index: URL, root: URL, properties: [String: [String: Any]])
        /// A video WebKit plays (VP8 webm): looped, muted, cover-fitted.
        case video(URL)
    }

    public let webView: WKWebView
    public let content: Content
    public private(set) var warnings: [String] = []
    public private(set) var loaded = false
    private var loadWaiters: [CheckedContinuation<Void, Error>] = []
    private var loadError: Error?
    public var onWarning: ((String) -> Void)?

    /// Content for what `Wallpaper.open` handed over (`WallpaperError.needsWebKit`).
    public convenience init(request: WebContentRequest, fps: Int = 30) {
        switch request {
        case .page(let index, let root, let properties): self.init(content: .page(index: index, root: root, properties: properties), fps: fps)
        case .video(let url): self.init(content: .video(url), fps: fps)
        }
    }

    public init(content: Content, fps: Int = 30) {
        self.content = content
        let config = WKWebViewConfiguration()
        config.mediaTypesRequiringUserActionForPlayback = []
        config.suppressesIncrementalRendering = true
        let controller = WKUserContentController()
        var initial: [String: Any] = ["general": ["fps": fps]]
        if case .page(_, _, let properties) = content { initial["user"] = properties }
        let initialJSON = (try? JSONSerialization.data(withJSONObject: initial)).map { String(decoding: $0, as: UTF8.self) } ?? "{}"
        controller.addUserScript(WKUserScript(source: Self.bridge(initial: initialJSON), injectionTime: .atDocumentStart, forMainFrameOnly: true))
        config.userContentController = controller
        if case .page(_, let root, _) = content {
            config.setURLSchemeHandler(WallpaperSchemeHandler(root: root), forURLScheme: WallpaperSchemeHandler.scheme)
        }
        webView = WKWebView(frame: .zero, configuration: config)
        super.init()
        controller.add(WeakHandler(self), name: "we")
        webView.navigationDelegate = self
        webView.autoresizingMask = [.width, .height]
        load()
    }

    func load() {
        switch content {
        case .page(let index, let root, _):
            // Served from our scheme so the page and its files share one origin (see WallpaperSchemeHandler).
            if let url = WallpaperSchemeHandler.url(for: index, root: root) {
                webView.load(URLRequest(url: url))
            } else {
                warn("page is outside its wallpaper folder; loading from file://")
                webView.loadFileURL(index, allowingReadAccessTo: root)
            }
        case .video(let url):
            // Our own generated page (no remote content), written to Caches. It must read the video from the
            // user's folder, and WebKit grants file access by common ancestor, hence "/".
            let dir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("MacWallpaper/web", isDirectory: true)
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let page = dir.appendingPathComponent("video-\(abs(url.path.hashValue)).html")
            try? Self.videoPage(url).write(to: page, atomically: true, encoding: .utf8)
            webView.loadFileURL(page, allowingReadAccessTo: URL(fileURLWithPath: "/"))
        }
    }

    // MARK: - control

    /// Pause/resume: tells the page (`setPaused`), suspends its media, and hides the view so WebKit
    /// treats the page as invisible (requestAnimationFrame stops, timers are throttled).
    public func setPaused(_ paused: Bool) {
        webView.evaluateJavaScript("window.__we && window.__we.setPaused(\(paused))")
        webView.setAllMediaPlaybackSuspended(paused)
        webView.isHidden = paused
    }

    public func setUserProperties(_ properties: [String: [String: Any]]) {
        guard let data = try? JSONSerialization.data(withJSONObject: properties) else { return }
        webView.evaluateJavaScript("window.__we.setUserProperties(\(String(decoding: data, as: UTF8.self)))")
    }

    public func setFPS(_ fps: Int) {
        webView.evaluateJavaScript("window.__we.setGeneralProperties({fps: \(fps)})")
    }

    // MARK: - offscreen capture (wecli / regression)

    public func waitUntilLoaded() async throws {
        if loaded { return }
        if let loadError { throw loadError }
        try await withCheckedThrowingContinuation { loadWaiters.append($0) }
    }

    /// Capture for wecli / regression. Pages: wait `settle` seconds after load, then snapshot (deterministic
    /// for property-driven content, not for time-based animation). Videos: deterministic.
    /// Videos: seek to `time` (looped), wait for `seeked`, read the frame through a canvas, cover-fit.
    public func capture(width: Int, height: Int, time: Double, settle: Double = 0.5) async throws -> CGImage {
        try await waitUntilLoaded()
        switch content {
        case .video:
            let result = try await webView.callAsyncJavaScript(
                "return await window.__weVideoFrame(t, w, h)", arguments: ["t": time, "w": width, "h": height], contentWorld: .page)
            guard let url = result as? String, let comma = url.firstIndex(of: ","),
                  let data = Data(base64Encoded: String(url[url.index(after: comma)...])),
                  let source = CGImageSourceCreateWithData(data as CFData, nil),
                  let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
                throw WebWallpaperError.capture("video frame")
            }
            return image
        case .page:
            // Let the page apply its properties and lay out. (Not requestAnimationFrame: WebKit does not
            // run it for an off-screen window, which is how wecli captures.)
            try await Task.sleep(nanoseconds: UInt64(settle * 1e9))
            // No snapshotWidth: the view is already sized for the output, and a scaled snapshot drops
            // composited layers (CSS masks disappeared in corsair_o_tron).
            let image = try await webView.takeSnapshot(configuration: nil)
            guard let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { throw WebWallpaperError.capture("snapshot") }
            return cg
        }
    }

    // MARK: - WKNavigationDelegate / messages

    public func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        loaded = true
        loadWaiters.forEach { $0.resume() }
        loadWaiters = []
    }

    public func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) { fail(error) }
    public func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) { fail(error) }

    func fail(_ error: Error) {
        loadError = error
        warn("page failed to load: \(error.localizedDescription)")
        loadWaiters.forEach { $0.resume(throwing: error) }
        loadWaiters = []
    }

    public func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        warn("web content process terminated; reloading")
        load()
    }

    public func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard let body = message.body as? [String: Any], let text = body["message"] as? String else { return }
        warn(text)
    }

    func warn(_ w: String) {
        guard !warnings.contains(w) else { return }
        warnings.append(w)
        onWarning?(w)
    }

    // MARK: - JavaScript

    static func bridge(initial: String) -> String {
        """
        (() => {
          const initial = \(initial);
          const state = { user: initial.user || null, general: initial.general || null, paused: false };
          const report = (message) => { try { window.webkit.messageHandlers.we.postMessage({ message: String(message) }); } catch (e) {} };
          let listener;
          const deliver = () => {
            if (!listener) return;
            try {
              if (state.general && listener.applyGeneralProperties) listener.applyGeneralProperties(state.general);
              if (state.user && listener.applyUserProperties) listener.applyUserProperties(state.user);
              if (state.paused && listener.setPaused) listener.setPaused(true);
            } catch (e) { report('wallpaperPropertyListener: ' + e); }
          };
          Object.defineProperty(window, 'wallpaperPropertyListener', {
            configurable: true,
            get: () => listener,
            set: (value) => { listener = value; setTimeout(deliver, 0); },
          });
          // Audio spectrum (128 values, left 0-63 / right 64-127): no capture yet, so listeners stay idle.
          const audioListeners = [];
          window.wallpaperRegisterAudioListener = (cb) => { if (typeof cb === 'function') audioListeners.push(cb); };
          for (const name of ['wallpaperRegisterMediaStatusListener', 'wallpaperRegisterMediaPropertiesListener',
                              'wallpaperRegisterMediaThumbnailListener', 'wallpaperRegisterMediaPlaybackListener',
                              'wallpaperRegisterMediaTimelineListener']) {
            window[name] = () => {};
          }
          window.wallpaperRequestRandomFileForProperty = () => {};
          window.__we = {
            setUserProperties: (p) => { state.user = Object.assign(state.user || {}, p); if (listener && listener.applyUserProperties) { try { listener.applyUserProperties(p); } catch (e) { report(e); } } },
            setGeneralProperties: (p) => { state.general = Object.assign(state.general || {}, p); if (listener && listener.applyGeneralProperties) { try { listener.applyGeneralProperties(p); } catch (e) { report(e); } } },
            setPaused: (p) => { state.paused = p; if (listener && listener.setPaused) { try { listener.setPaused(p); } catch (e) { report(e); } } },
            audioListenerCount: () => audioListeners.length,
          };
          window.addEventListener('error', (e) => report('page error: ' + e.message + (e.filename ? ' (' + e.filename.split('/').pop() + ':' + e.lineno + ')' : '')));
          window.addEventListener('unhandledrejection', (e) => report('unhandled rejection: ' + e.reason));
        })();
        """
    }

    static func videoPage(_ url: URL) -> String {
        let src = url.absoluteString.replacingOccurrences(of: "\"", with: "%22")
        return """
        <!doctype html><html><head><meta charset="utf-8"><style>
        html,body{margin:0;height:100%;background:#000;overflow:hidden}
        video{width:100%;height:100%;object-fit:cover;display:block}
        </style></head><body>
        <video id="v" src="\(src)" autoplay loop muted playsinline></video>
        <script>
        const v = document.getElementById('v');
        window.wallpaperPropertyListener = { setPaused: (p) => { if (p) v.pause(); else v.play(); } };
        // Capture: frame at time t (looped) drawn cover-fitted into w×h, as a PNG data URL.
        window.__weVideoFrame = (t, w, h) => new Promise((resolve, reject) => {
          const draw = () => {
            const c = document.createElement('canvas'); c.width = w; c.height = h;
            const g = c.getContext('2d');
            const s = Math.max(w / v.videoWidth, h / v.videoHeight);
            const dw = v.videoWidth * s, dh = v.videoHeight * s;
            g.fillStyle = '#000'; g.fillRect(0, 0, w, h);
            g.drawImage(v, (w - dw) / 2, (h - dh) / 2, dw, dh);
            resolve(c.toDataURL('image/png'));
          };
          const seek = () => {
            v.pause();
            v.onseeked = draw;
            v.onerror = () => reject('video error ' + (v.error && v.error.code));
            v.currentTime = v.duration > 0 ? t % v.duration : t;
          };
          if (v.readyState >= 1) seek(); else v.addEventListener('loadedmetadata', seek, { once: true });
        });
        </script></body></html>
        """
    }
}

public enum WebWallpaperError: Error, CustomStringConvertible {
    case capture(String)
    public var description: String {
        switch self { case .capture(let s): return "capture failed: \(s)" }
    }
}

/// WKUserContentController retains its handlers; break the cycle.
private final class WeakHandler: NSObject, WKScriptMessageHandler {
    weak var target: WebWallpaper?
    init(_ target: WebWallpaper) { self.target = target }
    func userContentController(_ c: WKUserContentController, didReceive message: WKScriptMessage) {
        MainActor.assumeIsolated { target?.userContentController(c, didReceive: message) }
    }
}
