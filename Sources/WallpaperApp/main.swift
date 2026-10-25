import AppKit
import WEAudio

/// Renders Wallpaper Engine wallpapers behind the desktop icons. Lives in the Dock and/or the menu bar (Settings).
///
/// Settings live in UserDefaults (`wallpaper`, `assets`, `fps`); `--wallpaper <dir>` and
/// `--assets <dir>` on the command line override them (handy for `open MacWallpaper.app --args ...`).
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    let defaults = UserDefaults.standard
    var controller: WallpaperController!
    var statusItem: NSStatusItem!
    let statusLine = NSMenuItem(title: "", action: nil, keyEquivalent: "")
    let pauseItem = NSMenuItem(title: String(localized: "Pause"), action: #selector(togglePause), keyEquivalent: "p")
    var settings: AppSettings!
    lazy var settingsWindow = SettingsWindowController(settings: settings, steam: steamModel, assets: assetsModel) { [weak self] in
        self?.showLibrary()
    }
    lazy var libraryModel: LibraryModel = {
        let model = LibraryModel()
        model.apply = { [weak self] entry in
            self?.defaults.set(entry.folder.path, forKey: "wallpaper")
            self?.loadCurrent()
        }
        model.contentModeChanged = { [weak self] mode in self?.controller.contentMode = mode }
        model.propertiesChanged = { [weak self] values in self?.controller.applyProperties(values) }
        return model
    }()
    lazy var steamModel: SteamModel = {
        let steam = SteamModel(library: libraryModel)
        steam.afterLogin = { [weak self, weak steam] in
            guard let self, let steam else { return }
            if self.setupModel.continueAfterLogin { self.setupModel.welcomeShown = true } else { steam.showImport() }
        }
        return steam
    }()
    lazy var assetsModel: AssetsModel = {
        let assets = AssetsModel(connection: steamModel.connection)
        assets.locationChanged = { [weak self] in
            guard let self else { return }
            Task { await self.libraryModel.refresh() }
            self.loadCurrent()
        }
        libraryModel.showAssets = { [weak assets] in assets?.sheetShown = true }
        return assets
    }()
    let setupModel = SetupModel()
    lazy var browseModel = WorkshopBrowseModel(steam: steamModel, library: libraryModel)
    lazy var libraryWindow = LibraryWindowController(model: libraryModel, steam: steamModel, assets: assetsModel, setup: setupModel,
                                                     browse: browseModel)

    func applicationDidFinishLaunching(_ notification: Notification) {
        applyCommandLine()
        controller = WallpaperController()
        settings = AppSettings(controller: controller)
        settings.presenceChanged = { [weak self] in self?.applyPresence() }
        controller.onStateChange = { [weak self] in self?.refreshMenu() }
        buildMenu()
        applyPresence()
        loadCurrent()
        if let base = ProcessInfo.processInfo.environment["MW_SETTINGS_SNAPSHOT"] {
            settingsWindow.show()
            settingsWindow.snapshotPanes(base: base)
        }
        // First launch: nothing chosen yet, so start in the library.
        if defaults.string(forKey: "wallpaper") == nil || CommandLine.arguments.contains("--library") { showLibrary() }
    }

    @objc func showLibrary() { libraryWindow.show() }

    /// Opening the app again (Finder, Launchpad, Spotlight, a click on the Dock icon) shows the library: the
    /// menu-bar icon can be hidden behind the notch or other icons.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showLibrary()
        return true
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
            statusLine.title = String(localized: "No wallpaper — choose one…")
            return
        }
        controller.contentMode = LibraryModel.storedContentMode(path: path)
        let target = libraryModel.loadTarget(path: path)
        controller.load(wallpaper: target.folder, assets: AssetsModel.currentLocation, properties: target.properties)
        libraryModel.currentPath = path
        log("loading \(path)")
        refreshMenu()
    }

    // MARK: - menu

    /// Dock icon and menu-bar icon as chosen in Settings; windows keep the Dock icon while open either way.
    func applyPresence() {
        statusItem?.isVisible = settings.showInMenuBar
        let windowOpen = NSApp.windows.contains { $0.isVisible && $0.styleMask.contains(.titled) }
        NSApp.setActivationPolicy(settings.showInDock || windowOpen ? .regular : .accessory)
    }

    /// Right-click on the Dock icon: what's playing and the everyday actions.
    func applicationDockMenu(_ sender: NSApplication) -> NSMenu? {
        let menu = NSMenu()
        let title = NSMenuItem(title: currentTitle, action: nil, keyEquivalent: "")
        title.isEnabled = false
        menu.addItem(title)
        let state = NSMenuItem(title: friendlyStatus, action: nil, keyEquivalent: "")
        state.isEnabled = false
        menu.addItem(state)
        menu.addItem(.separator())
        let pause = item(controller.pauseReasons.contains(.user) ? String(localized: "Resume") : String(localized: "Pause"),
                         #selector(togglePause), "")
        menu.addItem(pause)
        menu.addItem(.separator())
        menu.addItem(item(String(localized: "Wallpaper Library…"), #selector(showLibrary), ""))
        menu.addItem(item(String(localized: "Settings…"), #selector(showSettings), ""))
        return menu
    }

    /// The current wallpaper's title (from the library, else its project.json), for menus.
    var currentTitle: String {
        guard let path = defaults.string(forKey: "wallpaper") else { return String(localized: "No wallpaper") }
        let url = URL(fileURLWithPath: path).standardizedFileURL
        if let entry = libraryModel.entries.first(where: { $0.folder.standardizedFileURL == url }) { return entry.title }
        let project = (try? JSONSerialization.jsonObject(with: Data(contentsOf: url.appendingPathComponent("project.json")))) as? [String: Any]
        return project?["title"] as? String ?? url.lastPathComponent
    }

    /// What the wallpaper is doing, in plain words.
    var friendlyStatus: String {
        if controller.loadError != nil { return String(localized: "Couldn’t play this wallpaper") }
        let reasons = controller.pauseReasons
        let because: [(WallpaperController.PauseReason, String)] = [
            (.user, String(localized: "Paused")),
            (.locked, String(localized: "Paused · Screen locked")),
            (.screensAsleep, String(localized: "Paused · Displays asleep")),
            (.battery, String(localized: "Paused · On battery")),
            (.lowPower, String(localized: "Paused · Low Power Mode")),
        ]
        if let reason = because.first(where: { reasons.contains($0.0) }) { return reason.1 }
        if reasons.contains(.loading) { return String(localized: "Loading…") }
        return String(localized: "Playing")
    }

    func buildMenu() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem.button?.image = Self.menuBarIcon
        statusItem.button?.toolTip = "MacWallpaper"
        let menu = NSMenu()
        menu.delegate = self
        statusLine.isEnabled = false
        menu.addItem(statusLine)
        menu.addItem(.separator())
        pauseItem.target = self
        menu.addItem(pauseItem)
        menu.addItem(.separator())
        menu.addItem(item(String(localized: "Wallpaper Library…"), #selector(showLibrary), "l"))
        menu.addItem(item(String(localized: "Settings…"), #selector(showSettings), ","))
        menu.addItem(.separator())
        menu.addItem(item(String(localized: "Quit"), #selector(NSApplication.terminate(_:)), "q", target: NSApp))
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
        statusLine.title = "\(currentTitle) — \(friendlyStatus)"
        pauseItem.title = controller.pauseReasons.contains(.user) ? String(localized: "Resume") : String(localized: "Pause")
    }

    @objc func togglePause() {
        controller.setPaused(.user, !controller.pauseReasons.contains(.user))
    }






    @objc func showAssets() {
        showLibrary()
        assetsModel.sheetShown = true
    }

    @objc func showSettings() { settingsWindow.show() }

    /// The menu-bar glyph: a screen with two flowing ribbons (the app icon's motif), drawn as a template image so
    /// it matches light and dark menu bars like the system's own icons.
    static let menuBarIcon: NSImage = {
        let image = NSImage(size: NSSize(width: 18, height: 18), flipped: false) { _ in
            NSColor.black.setStroke()
            let screen = NSBezierPath(roundedRect: NSRect(x: 1.5, y: 3, width: 15, height: 12), xRadius: 3, yRadius: 3)
            screen.lineWidth = 1.5
            screen.stroke()
            // Two parallel waves flowing across the screen, like the icon's ribbons.
            for (y, width) in [(CGFloat(6.4), CGFloat(1.6)), (CGFloat(10.0), CGFloat(1.2))] {
                let wave = NSBezierPath()
                wave.move(to: NSPoint(x: 4.2, y: y))
                wave.curve(to: NSPoint(x: 13.8, y: y + 1.6), controlPoint1: NSPoint(x: 7.6, y: y + 3.4),
                           controlPoint2: NSPoint(x: 10.4, y: y - 1.8))
                wave.lineWidth = width
                wave.lineCapStyle = .round
                wave.stroke()
            }
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = "MacWallpaper"
        return image
    }()

}

// Top-level code runs on the main thread.
MainActor.assumeIsolated {
    let app = NSApplication.shared
    app.setActivationPolicy(.accessory)
    let delegate = AppDelegate()
    app.delegate = delegate
    app.run()
}
