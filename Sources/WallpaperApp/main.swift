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
    lazy var libraryWindow = LibraryWindowController(model: libraryModel, steam: steamModel, assets: assetsModel, setup: setupModel)

    func applicationDidFinishLaunching(_ notification: Notification) {
        applyCommandLine()
        controller = WallpaperController()
        settings = AppSettings(controller: controller)
        controller.onStateChange = { [weak self] in self?.refreshMenu() }
        buildMenu()
        loadCurrent()
        if let base = ProcessInfo.processInfo.environment["MW_SETTINGS_SNAPSHOT"] {
            settingsWindow.show()
            settingsWindow.snapshotPanes(base: base)
        }
        // First launch: nothing chosen yet, so start in the library.
        if defaults.string(forKey: "wallpaper") == nil || CommandLine.arguments.contains("--library") { showLibrary() }
    }

    @objc func showLibrary() { libraryWindow.show() }

    /// Opening the app again (Finder, Launchpad, Spotlight) shows the library: the menu-bar icon can be
    /// hidden behind the notch or other icons, and there is no Dock icon.
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
        controller.load(wallpaper: URL(fileURLWithPath: path),
                        assets: AssetsModel.currentLocation, properties: libraryModel.propertyOverrides(path: path))
        libraryModel.currentPath = path
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
        let name = defaults.string(forKey: "wallpaper").map { ($0 as NSString).lastPathComponent } ?? "—"
        statusLine.title = "\(name): \(controller.statusText)"
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

}

// Top-level code runs on the main thread.
MainActor.assumeIsolated {
    let app = NSApplication.shared
    app.setActivationPolicy(.accessory)
    let delegate = AppDelegate()
    app.delegate = delegate
    app.run()
}
