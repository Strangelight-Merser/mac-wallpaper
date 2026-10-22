import AppKit
import WEAudio

/// Menu-bar app (no Dock icon) that renders a Wallpaper Engine scene behind the desktop icons.
///
/// Settings live in UserDefaults (`wallpaper`, `assets`, `fps`); `--wallpaper <dir>` and
/// `--assets <dir>` on the command line override them (handy for `open MacWallpaper.app --args ...`).
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    let defaults = UserDefaults.standard
    var controller: WallpaperController!
    var statusItem: NSStatusItem!
    let statusLine = NSMenuItem(title: "", action: nil, keyEquivalent: "")
    let pauseItem = NSMenuItem(title: "Pause", action: #selector(togglePause), keyEquivalent: "p")
    let mouseItem = NSMenuItem(title: "Mouse Interaction", action: #selector(toggleMouse), keyEquivalent: "")
    let audioItem = NSMenuItem(title: "Audio Visualization (System Audio)", action: #selector(toggleAudio), keyEquivalent: "")
    let fpsMenu = NSMenu()

    func applicationDidFinishLaunching(_ notification: Notification) {
        applyCommandLine()
        controller = WallpaperController()
        controller.fps = defaults.object(forKey: "fps") as? Int ?? 30
        controller.mouseInput = defaults.object(forKey: "mouseInput") as? Bool ?? true
        // Only re-enable audio if the permission is still there (no prompt at launch).
        controller.audioEnabled = defaults.bool(forKey: "audio") && SystemAudioCapture.hasPermission
        controller.onStateChange = { [weak self] in self?.refreshMenu() }
        buildMenu()
        loadCurrent()
    }

    func applyCommandLine() {
        let args = CommandLine.arguments
        for (flag, key) in [("--wallpaper", "wallpaper"), ("--assets", "assets")] {
            if let i = args.firstIndex(of: flag), i + 1 < args.count {
                defaults.set(URL(fileURLWithPath: args[i + 1]).standardizedFileURL.path, forKey: key)
            }
        }
    }

    func loadCurrent() {
        guard let path = defaults.string(forKey: "wallpaper") else {
            statusLine.title = "No wallpaper — choose one…"
            return
        }
        controller.load(wallpaper: URL(fileURLWithPath: path),
                        assets: defaults.string(forKey: "assets").map { URL(fileURLWithPath: $0) })
        log("loading \(path)")
        refreshMenu()
    }

    // MARK: - menu

    func buildMenu() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem.button?.image = NSImage(systemSymbolName: "sparkles.tv", accessibilityDescription: "Wallpaper")
        let menu = NSMenu()
        menu.delegate = self
        statusLine.isEnabled = false
        menu.addItem(statusLine)
        menu.addItem(.separator())
        pauseItem.target = self
        menu.addItem(pauseItem)
        let fpsItem = NSMenuItem(title: "Frame Rate", action: nil, keyEquivalent: "")
        for f in [15, 24, 30, 60] {
            let i = NSMenuItem(title: "\(f) fps", action: #selector(setFPS(_:)), keyEquivalent: "")
            i.tag = f; i.target = self
            fpsMenu.addItem(i)
        }
        fpsItem.submenu = fpsMenu
        menu.addItem(fpsItem)
        mouseItem.target = self
        menu.addItem(mouseItem)
        audioItem.target = self
        menu.addItem(audioItem)
        menu.addItem(.separator())
        menu.addItem(item("Open Wallpaper Folder…", #selector(chooseWallpaper), "o"))
        menu.addItem(item("Set Wallpaper Engine Assets Folder…", #selector(chooseAssets), ""))
        menu.addItem(item("Reload", #selector(reload), "r"))
        menu.addItem(.separator())
        menu.addItem(item("Quit", #selector(NSApplication.terminate(_:)), "q", target: NSApp))
        statusItem.menu = menu
        refreshMenu()
    }

    func item(_ title: String, _ action: Selector, _ key: String, target: AnyObject? = nil) -> NSMenuItem {
        let i = NSMenuItem(title: title, action: action, keyEquivalent: key)
        i.target = target ?? self
        return i
    }

    func menuWillOpen(_ menu: NSMenu) { refreshMenu() }

    func refreshMenu() {
        guard statusItem != nil else { return }
        let name = defaults.string(forKey: "wallpaper").map { ($0 as NSString).lastPathComponent } ?? "—"
        statusLine.title = "\(name): \(controller.statusText)"
        pauseItem.title = controller.pauseReasons.contains(.user) ? "Resume" : "Pause"
        for i in fpsMenu.items { i.state = i.tag == controller.fps ? .on : .off }
        mouseItem.state = controller.mouseInput ? .on : .off
        audioItem.state = controller.audioEnabled ? .on : .off
    }

    @objc func togglePause() {
        controller.setPaused(.user, !controller.pauseReasons.contains(.user))
    }

    @objc func toggleMouse() {
        controller.mouseInput.toggle()
        defaults.set(controller.mouseInput, forKey: "mouseInput")
        refreshMenu()
    }

    /// Audio needs the Screen Recording permission (ScreenCaptureKit): the first request shows the
    /// system prompt; afterwards it can only be granted in System Settings (and macOS applies it after
    /// a relaunch).
    @objc func toggleAudio() {
        if controller.audioEnabled {
            controller.audioEnabled = false
        } else {
            if !SystemAudioCapture.hasPermission { SystemAudioCapture.requestPermission() }
            guard SystemAudioCapture.hasPermission else {
                let alert = NSAlert()
                alert.messageText = "Allow Screen Recording to visualize audio"
                alert.informativeText = "Audio-reactive wallpapers read what your Mac is playing through ScreenCaptureKit, which macOS lists under Screen & System Audio Recording. Nothing is recorded or saved; only the audio spectrum is used.\n\nTurn on MacWallpaper in System Settings → Privacy & Security → Screen & System Audio Recording, quit and reopen MacWallpaper, then enable this item again."
                alert.addButton(withTitle: "Open System Settings")
                alert.addButton(withTitle: "Cancel")
                NSApp.activate(ignoringOtherApps: true)
                if alert.runModal() == .alertFirstButtonReturn,
                   let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") {
                    NSWorkspace.shared.open(url)
                }
                return
            }
            controller.audioEnabled = true
        }
        defaults.set(controller.audioEnabled, forKey: "audio")
        refreshMenu()
    }

    @objc func setFPS(_ sender: NSMenuItem) {
        controller.fps = sender.tag
        defaults.set(sender.tag, forKey: "fps")
        refreshMenu()
    }

    @objc func chooseWallpaper() {
        if let url = pickFolder("Choose an unpacked Wallpaper Engine scene (folder with project.json)") {
            defaults.set(url.path, forKey: "wallpaper")
            loadCurrent()
        }
    }

    @objc func chooseAssets() {
        if let url = pickFolder("Choose Wallpaper Engine's “assets” folder") {
            defaults.set(url.path, forKey: "assets")
            loadCurrent()
        }
    }

    @objc func reload() { loadCurrent() }

    func pickFolder(_ message: String) -> URL? {
        let p = NSOpenPanel()
        p.canChooseDirectories = true
        p.canChooseFiles = false
        p.message = message
        NSApp.activate(ignoringOtherApps: true)
        return p.runModal() == .OK ? p.url : nil
    }
}

// Top-level code runs on the main thread.
MainActor.assumeIsolated {
    let app = NSApplication.shared
    app.setActivationPolicy(.accessory)
    let delegate = AppDelegate()
    app.delegate = delegate
    app.run()
}
