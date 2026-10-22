import CoreGraphics
import Foundation
import ImageIO
import AppKit
import Metal
import WEWeb
import UniformTypeIdentifiers
import WEFormat
import WERender
import WEShader
import WEAudio

func usage() -> Never {
    print("""
    usage:
      wecli texinfo <file.tex>...
      wecli tex2png <file.tex> <out.png>
      wecli verify  <dir>            decode every .tex and compare with sibling .png
      wecli pkg     <scene.pkg> [outdir]
      wecli scene   <wallpaper dir> [--assets <dir>]   dump layers / passes / effect FBOs
      wecli compare <a.png> <b.png> [--tolerance N] [--diff out.png]   exit 0 = match, 1 = differ
      wecli bench   <wallpaper dir> --assets <dir> [--size WxH] [--frames N] [--cache off] [--layers a,b] [--bloom off] [--fps N]
      wecli render  <wallpaper dir> --assets <WE assets dir> [--time t] [--size WxH] [--prop name=value]...
                    [--layers a,b] [--bloom off] [--cache off] [--warm t] [--target _rt_name] --out <out.png>
                    [--pointer x,y[:x2,y2]] [--press s] [--frames N] [--audio hz,hz[:hz,hz]]
                    pointer: 0…1, y down; with --frames, N frames at 30 fps ending at --time, the pointer
                    moving from x,y to x2,y2 (for simulations such as cursor ripples)
                    audio: spectrum of sine tones (left[:right], amplitude 0.25 each) for g_AudioSpectrum*
                    and web audio listeners
    """)
    exit(2)
}

func rgbaImage(_ px: [UInt8], _ w: Int, _ h: Int) -> CGImage? {
    let provider = CGDataProvider(data: Data(px) as CFData)!
    return CGImage(width: w, height: h, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: w * 4,
                   space: CGColorSpaceCreateDeviceRGB(),
                   bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.last.rawValue),
                   provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)
}

/// Decode an image file to RGBA8 (non-premultiplied as far as CG allows: we draw into premultiplied
/// and compare only where alpha is high, see `verify`).
func loadRGBA(_ url: URL) -> (px: [UInt8], w: Int, h: Int)? {
    guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
          let img = CGImageSourceCreateImageAtIndex(src, 0, nil) else { return nil }
    return draw(img)
}

func loadRGBA(data: [UInt8]) -> (px: [UInt8], w: Int, h: Int)? {
    guard let src = CGImageSourceCreateWithData(Data(data) as CFData, nil),
          let img = CGImageSourceCreateImageAtIndex(src, 0, nil) else { return nil }
    return draw(img)
}

func draw(_ img: CGImage) -> (px: [UInt8], w: Int, h: Int)? {
    let w = img.width, h = img.height
    var px = [UInt8](repeating: 0, count: w * h * 4)
    guard let ctx = CGContext(data: &px, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                              space: CGColorSpaceCreateDeviceRGB(),
                              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
    ctx.draw(img, in: CGRect(x: 0, y: 0, width: w, height: h))
    return (px, w, h)
}

func writePNG(_ img: CGImage, to url: URL) throws {
    guard let dst = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else {
        throw WEFormatError.corrupt("cannot create \(url.path)")
    }
    CGImageDestinationAddImage(dst, img, nil)
    guard CGImageDestinationFinalize(dst) else { throw WEFormatError.corrupt("write failed") }
}

/// First mipmap of first image as RGBA8 (decoding embedded PNG/JPEG via ImageIO).
func decodeTop(_ tex: Tex) throws -> (px: [UInt8], w: Int, h: Int) {
    guard let m = tex.images.first?.first else { throw WEFormatError.corrupt("no images") }
    switch m.payload {
    case .raw: return (try Tex.rgba(m), m.width, m.height)
    case .encodedImage:
        guard let r = loadRGBA(data: m.bytes) else { throw WEFormatError.corrupt("embedded image") }
        return r
    case .mp4: throw WEFormatError.unsupported("mp4 texture")
    }
}

func describe(_ tex: Tex) -> String {
    let m = tex.images.first?.first
    let payload: String
    switch m?.payload {
    case .raw(let f)?: payload = "\(f)"
    case .encodedImage(let fi)?: payload = "image(fif=\(fi))"
    case .mp4?: payload = "mp4"
    case nil: payload = "-"
    }
    return "fmt=\(tex.format) v\(tex.containerVersion) flags=\(tex.flags.rawValue) tex=\(tex.textureWidth)x\(tex.textureHeight) img=\(tex.imageWidth)x\(tex.imageHeight) images=\(tex.images.count) mips=\(tex.images.first?.count ?? 0) top=\(m.map { "\($0.width)x\($0.height)" } ?? "-") payload=\(payload) frames=\(tex.frames.count)"
}

/// Offscreen WebKit capture for web wallpapers and VP8 videos: an off-screen window sized so the
/// snapshot comes out at exactly width×height pixels; the run loop spins until the capture is done.
@MainActor
func renderWithWebKit(_ request: WebContentRequest, width: Int, height: Int, time: Double,
                      pointer: SIMD2<Float>? = nil, press: Bool = false, audio: AudioSpectrum? = nil,
                      settle: Double = Double(ProcessInfo.processInfo.environment["WE_WEB_SETTLE"] ?? "") ?? 0.5) throws -> (CGImage, [String]) {
    let app = NSApplication.shared
    app.setActivationPolicy(.prohibited)
    let web = WebWallpaper(request: request)
    let scale = NSScreen.main?.backingScaleFactor ?? 1
    let window = NSWindow(contentRect: NSRect(x: -30000, y: -30000, width: CGFloat(width) / scale, height: CGFloat(height) / scale),
                          styleMask: .borderless, backing: .buffered, defer: false)
    window.contentView = web.webView
    window.orderFrontRegardless()
    var result: Result<CGImage, Error>?
    // --pointer x,y [--press 1]: move the mouse there (and click) once the page has loaded.
    if let pointer {
        var done = false
        Task { @MainActor in
            try? await web.waitUntilLoaded()
            try? await Task.sleep(nanoseconds: UInt64(settle * 1e9))
            let size = window.contentLayoutRect.size
            let p = CGPoint(x: CGFloat(pointer.x) * size.width, y: CGFloat(pointer.y) * size.height)
            web.sendMouseMove(to: p)
            if press { web.sendMouse(.leftMouseDown, at: p); web.sendMouse(.leftMouseUp, at: p) }
            done = true
        }
        while !done { RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.02)) }
    }
    if let audio {
        var done = false
        Task { @MainActor in
            try? await web.waitUntilLoaded()
            try? await Task.sleep(nanoseconds: UInt64(settle * 1e9))
            web.sendAudio(audio.web128)
            done = true
        }
        while !done { RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.02)) }
    }
    // Debug: WE_WEB_EVAL="<js expression>" is evaluated in the page just before the capture.
    if let js = ProcessInfo.processInfo.environment["WE_WEB_EVAL"] {
        var done = false
        Task { @MainActor in
            try? await web.waitUntilLoaded()
            try? await Task.sleep(nanoseconds: UInt64(settle * 1e9))
            let value = try? await web.webView.evaluateJavaScript("JSON.stringify(\(js))")
            print("  eval: \(value ?? "nil")")
            done = true
        }
        while !done { RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.02)) }
    }
    Task { @MainActor in
        do { result = .success(try await web.capture(width: width, height: height, time: time, settle: settle)) } catch { result = .failure(error) }
    }
    let deadline = Date().addingTimeInterval(30)
    while result == nil && Date() < deadline { RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.02)) }
    window.orderOut(nil)
    guard let result else { throw WebWallpaperError.capture("timed out") }
    // Normalise to exactly width×height, opaque.
    let image = try result.get()
    var px = [UInt8](repeating: 0, count: width * height * 4)
    let ctx = CGContext(data: &px, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                        space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
    ctx.interpolationQuality = .high
    ctx.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
    return (ctx.makeImage()!, web.warnings)
}

let args = CommandLine.arguments
guard args.count >= 3 else { usage() }

switch args[1] {
case "texinfo":
    for p in args.dropFirst(2) {
        do { print("\(p): \(describe(try Tex(data: Data(contentsOf: URL(fileURLWithPath: p)))))") }
        catch { print("\(p): ERROR \(error)") }
    }

case "tex2png":
    guard args.count == 4 else { usage() }
    let tex = try Tex(data: Data(contentsOf: URL(fileURLWithPath: args[2])))
    let (px, w, h) = try decodeTop(tex)
    try writePNG(rgbaImage(px, w, h)!, to: URL(fileURLWithPath: args[3]))

case "verify":
    // Compare against sibling PNGs. The PNG is cropped to imageWidth x imageHeight; our top mip is
    // the padded texture size, so compare the overlapping region, skipping near-transparent pixels
    // (premultiplication makes their color undefined).
    let root = URL(fileURLWithPath: args[2])
    let files = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil)!
        .compactMap { $0 as? URL }.filter { $0.pathExtension == "tex" }.sorted { $0.path < $1.path }
    var stats: [String: Int] = [:]
    var formats: [String: Int] = [:]
    for url in files {
        let rel = url.path.replacingOccurrences(of: root.path + "/", with: "")
        do {
            let tex = try Tex(data: Data(contentsOf: url))
            var key = "\(tex.format)"
            if case .encodedImage(let f)? = tex.images.first?.first?.payload { key = "image(fif=\(f))" }
            if tex.flags.contains(.isGif) { key += "+gif" }
            formats[key, default: 0] += 1
            let (px, w, h) = try decodeTop(tex)
            let pngURL = url.deletingPathExtension().appendingPathExtension("png")
            guard FileManager.default.fileExists(atPath: pngURL.path) else { stats["decoded (no png)", default: 0] += 1; continue }
            guard let ref = loadRGBA(pngURL) else { stats["png unreadable", default: 0] += 1; print("UNREADABLE \(rel)"); continue }
            // Premultiply ours the same way CG does for a fair comparison.
            let cw = min(w, ref.w), ch = min(h, ref.h)
            var maxDiff = 0, sum = 0, count = 0
            for y in 0..<ch {
                for x in 0..<cw {
                    let i = (y * w + x) * 4, j = (y * ref.w + x) * 4
                    let a = Int(px[i + 3])
                    let da = abs(a - Int(ref.px[j + 3]))
                    maxDiff = max(maxDiff, da); sum += da; count += 1
                    if a < 16 { continue }
                    for c in 0..<3 {
                        let ours = (Int(px[i + c]) * a + 127) / 255
                        let d = abs(ours - Int(ref.px[j + c]))
                        maxDiff = max(maxDiff, d); sum += d; count += 1
                    }
                }
            }
            let mean = count > 0 ? Double(sum) / Double(count) : 0
            let sizeNote = (ref.w == tex.imageWidth && ref.h == tex.imageHeight) ? "" : " png=\(ref.w)x\(ref.h)"
            let exact = maxDiff <= 8, close = mean < 5
            stats[exact ? "match" : close ? "close (lossy)" : "MISMATCH", default: 0] += 1
            if !close { print(String(format: "MISMATCH %@ mean=%.2f max=%d %@%@", rel, mean, maxDiff, describe(tex), sizeNote)) }
        } catch {
            stats["ERROR", default: 0] += 1
            print("ERROR \(rel): \(error)")
        }
    }
    print("textures: \(files.count)")
    print("formats:", formats.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: " "))
    print("results:", stats.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: " "))

case "pkg":
    let pkg = try PKG(bytes: [UInt8](Data(contentsOf: URL(fileURLWithPath: args[2]))))
    print("\(pkg.magic): \(pkg.entries.count) entries")
    for e in pkg.entries { print("  \(e.length)\t\(e.path)") }
    if args.count >= 4 {
        let out = URL(fileURLWithPath: args[3])
        for e in pkg.entries {
            let dst = out.appendingPathComponent(e.path)
            try FileManager.default.createDirectory(at: dst.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(pkg.contents(of: e)).write(to: dst)
        }
    }

case "render":
    var opts: [String: String] = [:]
    var props: [String: String] = [:]
    var i = 3
    while i + 1 < args.count {
        if args[i] == "--prop", let eq = args[i + 1].firstIndex(of: "=") {
            props[String(args[i + 1][..<eq])] = String(args[i + 1][args[i + 1].index(after: eq)...])
        } else { opts[args[i]] = args[i + 1] }
        i += 2
    }
    guard let out = opts["--out"] else { usage() }
    let size = (opts["--size"] ?? "1920x1080").split(separator: "x").compactMap { Int($0) }
    guard size.count == 2 else { usage() }
    let time = Float(opts["--time"] ?? "0") ?? 0
    var start = Date()
    let path = (opts["--pointer"] ?? "").split(separator: ":").map {
        $0.split(separator: ",").compactMap { Float($0) }
    }.filter { $0.count == 2 }.map { SIMD2<Float>($0[0], $0[1]) }
    // --audio 110,2000[:880]: tones (Hz) per channel → analysed like captured audio.
    let audio: AudioSpectrum? = opts["--audio"].map { spec in
        let channels = spec.split(separator: ":").map { $0.split(separator: ",").compactMap { Double($0) } }
        func signal(_ tones: [Double]) -> [Float] {
            (0..<SpectrumAnalyzer.fftSize).map { i in
                Float(tones.reduce(0) { $0 + 0.25 * sin(2 * .pi * $1 * Double(i) / 48000) })
            }
        }
        let analyzer = SpectrumAnalyzer()
        analyzer.append(left: signal(channels.first ?? []), right: signal(channels.last ?? []))
        return analyzer.settle()
    }
    let img: CGImage
    let summary: String
    let warnings: [String]
    do {
        let renderer = try Wallpaper.open(project: URL(fileURLWithPath: args[2]),
                                          assets: opts["--assets"].map { URL(fileURLWithPath: $0) }, properties: props)
        if let scene = renderer as? SceneRenderer { // scene-only debug options
            scene.disableBloom = opts["--bloom"] == "off"
            scene.debugTarget = opts["--target"]
            scene.onlyLayers = opts["--layers"].map { Set($0.split(separator: ",").map(String.init)) }
            scene.disableLayerCache = opts["--cache"] == "off"
            if let audio { scene.audio = audio }
        }
        // --warm t: render a frame at time t first, so the measured frame uses the layer caches.
        if let warm = opts["--warm"].flatMap(Float.init) { _ = try renderer.render(width: size[0], height: size[1], time: warm) }
        start = Date()
        let frames = max(1, Int(opts["--frames"] ?? "1") ?? 1)
        if let scene = renderer as? SceneRenderer, let from = path.first {
            let to = path.last!
            scene.pointer.state.z = Float(opts["--press"] ?? "0") ?? 0
            scene.pointer.state.x = scene.pointer.state.z > 0 ? 1 : 0
            for f in 0..<frames - 1 {
                scene.pointer.position = from + (to - from) * Float(f) / Float(frames - 1)
                _ = try renderer.render(width: size[0], height: size[1], time: time - Float(frames - 1 - f) / 30)
            }
            scene.pointer.position = to
        } else {
            for f in 0..<frames - 1 {
                _ = try renderer.render(width: size[0], height: size[1], time: time - Float(frames - 1 - f) / 30)
            }
        }
        img = try renderer.render(width: size[0], height: size[1], time: time)
        summary = renderer.summary
        warnings = renderer.warnings
    } catch WallpaperError.needsWebKit(let request) {
        start = Date()
        (img, warnings) = try MainActor.assumeIsolated {
            try renderWithWebKit(request, width: size[0], height: size[1], time: Double(time),
                                 pointer: path.last, press: (Float(opts["--press"] ?? "0") ?? 0) > 0, audio: audio)
        }
        if case .video = request { summary = "web video (WebKit)" } else { summary = "web page (WebKit)" }
    }
    try writePNG(img, to: URL(fileURLWithPath: out))
    print(String(format: "rendered %@ in %.2fs -> %@", summary, Date().timeIntervalSince(start), out))
    for w in Set(warnings).sorted() { print("  warning: \(w)") }
    if ProcessInfo.processInfo.environment["WE_SHADER_PARITY"] != nil {
        print("  shader parity: \(ShaderCompiler.programsCompiled) program(s), \(ShaderCompiler.parityMismatches.count) mismatch(es)")
        ShaderCompiler.parityMismatches.forEach { print("    \($0)") }
    }
    if ProcessInfo.processInfo.environment["WE_TIMING"] != nil {
        print("  programs compiled: \(ShaderCompiler.programsCompiled)")
        for (k, v) in ShaderCompiler.timings.sorted(by: { $0.key < $1.key }) { print(String(format: "  %@: %.2fs", k, v)) }
    }

case "scene":
    // Dump the parsed scene: layers, passes, targets, binds and effect FBOs.
    let assets = args.firstIndex(of: "--assets").map { URL(fileURLWithPath: args[$0 + 1]) }
    let project = URL(fileURLWithPath: args[2])
    let scene = try SceneDescription(project: project, locator: AssetLocator(project: project, assets: assets))
    for l in scene.layers {
        print("layer \(l.id) '\(l.name)' size \(l.size) effects \(l.effectNames)")
        for (i, p) in l.passes.enumerated() {
            var d = "  [\(i)] \(p.copy.map { "copy \($0.source) -> \($0.target)" } ?? p.shader) blend=\(p.blending)"
            if let e = p.effect { d += " effect=\(e)" }
            if let t = p.target { d += " target=\(t)" }
            if !p.binds.isEmpty { d += " binds=\(p.binds.sorted { $0.key < $1.key })" }
            if !p.combos.isEmpty { d += " combos=\(p.combos)" }
            d += " textures=\(p.textures.map { $0 ?? "-" })"
            print(d)
        }
        for (e, f) in l.effectFBOs.enumerated() where !f.isEmpty {
            print("  fbos[\(e)]: " + f.map { "\($0.name) \($0.pixelSize(layerSize: l.size)) \($0.format)" }.joined(separator: ", "))
        }
    }
    scene.notes.forEach { print("note: \($0)") }

case "compare":
    // Pixel comparison for regression tests: exit 0 = within tolerance, 1 = different, 2 = unreadable.
    guard args.count >= 4 else { usage() }
    var opts: [String: String] = [:]
    var i = 4
    while i + 1 < args.count { opts[args[i]] = args[i + 1]; i += 2 }
    let tolerance = Int(opts["--tolerance"] ?? "0") ?? 0
    guard let a = loadRGBA(URL(fileURLWithPath: args[2])), let b = loadRGBA(URL(fileURLWithPath: args[3])) else {
        print("unreadable image"); exit(2)
    }
    guard a.w == b.w, a.h == b.h else { print("size differs: \(a.w)x\(a.h) vs \(b.w)x\(b.h)"); exit(1) }
    var maxDiff = 0, sum = 0, over = 0
    var diff = [UInt8](repeating: 255, count: a.px.count)
    for p in stride(from: 0, to: a.px.count, by: 4) {
        var pixelMax = 0
        for c in 0..<3 {
            let d = abs(Int(a.px[p + c]) - Int(b.px[p + c]))
            pixelMax = max(pixelMax, d); sum += d
        }
        maxDiff = max(maxDiff, pixelMax)
        if pixelMax > tolerance { over += 1 }
        // Amplified difference image: black = equal, brighter = larger difference.
        let v = UInt8(min(255, pixelMax * 8))
        diff[p] = v; diff[p + 1] = v; diff[p + 2] = v
    }
    let pixels = a.px.count / 4
    print(String(format: "max %d, mean %.4f, pixels over tolerance: %d (%.3f%%)", maxDiff,
                 Double(sum) / Double(pixels * 3), over, 100 * Double(over) / Double(pixels)))
    if over > 0, let path = opts["--diff"], let img = rgbaImage(diff, a.w, a.h) {
        try writePNG(img, to: URL(fileURLWithPath: path))
    }
    exit(over == 0 ? 0 : 1)

case "bench":
    // Encode N frames as the app would (≤3 in flight), reporting CPU encode time and GPU time per frame.
    var opts: [String: String] = [:]
    var i = 3
    while i + 1 < args.count { opts[args[i]] = args[i + 1]; i += 2 }
    let size = (opts["--size"] ?? "2880x1864").split(separator: "x").compactMap { Int($0) }
    let frames = Int(opts["--frames"] ?? "300") ?? 300
    let renderer = try SceneRenderer(project: URL(fileURLWithPath: args[2]),
                                     assets: opts["--assets"].map { URL(fileURLWithPath: $0) })
    renderer.disableLayerCache = opts["--cache"] == "off"
    renderer.onlyLayers = opts["--layers"].map { Set($0.split(separator: ",").map(String.init)) }
    renderer.disableBloom = opts["--bloom"] == "off"
    let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: size[0], height: size[1], mipmapped: false)
    d.usage = [.renderTarget]
    d.storageMode = .private
    let output = renderer.device.makeTexture(descriptor: d)!
    let inFlight = DispatchSemaphore(value: 3)
    let lock = NSLock()
    var gpu: [Double] = []
    var cpu: [Double] = []
    func threadCPU() -> Double {
        var ts = timespec()
        clock_gettime(CLOCK_THREAD_CPUTIME_ID, &ts)
        return Double(ts.tv_sec) + Double(ts.tv_nsec) / 1e9
    }
    let warmup = 10
    // --fps N paces submission like the app (GPU clocks behave as in real use); default: as fast as possible.
    let pace = opts["--fps"].flatMap(Double.init).map { 1 / $0 }
    var wallStart = Date()
    for f in 0..<(frames + warmup) {
        if f == warmup { wallStart = Date() }
        if let pace { Thread.sleep(until: wallStart.addingTimeInterval(Double(max(0, f - warmup)) * pace)) }
        inFlight.wait()
        let t0 = threadCPU()
        let cb = renderer.queue.makeCommandBuffer()!
        renderer.encodeFrame(into: output, commandBuffer: cb, time: Float(f) / 30)
        let measured = f >= warmup
        cb.addCompletedHandler { cb in
            if measured { lock.lock(); gpu.append(cb.gpuEndTime - cb.gpuStartTime); lock.unlock() }
            inFlight.signal()
        }
        cb.commit()
        if measured { cpu.append(threadCPU() - t0) }
    }
    for _ in 0..<3 { inFlight.wait() }
    let wall = Date().timeIntervalSince(wallStart) / Double(frames)
    for _ in 0..<3 { inFlight.signal() } // a semaphore must be back at its initial value when freed
    func stats(_ v: [Double]) -> String {
        let s = v.sorted()
        return String(format: "mean %.2f ms, p50 %.2f, p95 %.2f", s.reduce(0, +) / Double(s.count) * 1000,
                      s[s.count / 2] * 1000, s[Int(Double(s.count) * 0.95)] * 1000)
    }
    print("\(args[2]) \(size[0])x\(size[1]), \(frames) frames, cache \(renderer.disableLayerCache ? "off" : "on")")
    print("  CPU encode: " + stats(cpu))
    print("  GPU:        " + stats(gpu))
    print("  render encoders/frame: \(renderer.lastFrameEncoders)")
    print(String(format: "  wall time/frame: %.2f ms%@", wall * 1000, pace == nil ? " (GPU-bound throughput)" : " (paced)"))

default:
    usage()
}
