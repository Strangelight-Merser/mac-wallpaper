import AppKit
import SwiftUI

/// The library window. While it is open the app shows in the Dock and the app switcher; closing it
/// returns to a menu-bar-only app.
@MainActor
final class LibraryWindowController: NSWindowController, NSWindowDelegate {
    let model: LibraryModel
    let steam: SteamModel
    let browse: WorkshopBrowseModel

    init(model: LibraryModel, steam: SteamModel, assets: AssetsModel, setup: SetupModel, browse: WorkshopBrowseModel) {
        self.model = model
        self.steam = steam
        self.browse = browse
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1180, height: 760),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                              backing: .buffered, defer: false)
        window.title = String(localized: "Wallpaper Library")
        window.minSize = NSSize(width: 820, height: 520)
        window.toolbarStyle = .unified
        window.isReleasedWhenClosed = false
        let hosting = NSHostingController(rootView: LibraryView(model: model, steam: steam, assets: assets, setup: setup, browse: browse))
        // Otherwise the hosting controller shrinks the window to the content's minimum size.
        hosting.sizingOptions = []
        window.contentViewController = hosting
        window.setContentSize(NSSize(width: 1180, height: 760))
        window.setFrameAutosaveName("LibraryWindow")
        if !window.setFrameUsingName("LibraryWindow") { window.center() }
        super.init(window: window)
        window.delegate = self
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    func show() {
        NSApp.setActivationPolicy(.regular)
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate()
        Task { await model.refresh() }
        // Debug: MW_LIBRARY_SNAPSHOT=<file.png> writes the window to an image once the library has loaded
        // (for checking the UI without screen-recording permission).
        // MW_LIBRARY_SELECT=<title text> preselects a wallpaper for the snapshot.
        let env = ProcessInfo.processInfo.environment
        if let path = env["MW_LIBRARY_SNAPSHOT"] {
            DispatchQueue.main.asyncAfter(deadline: .now() + 5) { [weak self] in
                if let title = env["MW_LIBRARY_SELECT"] {
                    self?.model.selection = self?.model.entries.first { $0.title.localizedCaseInsensitiveContains(title) }?.id
                }
                // MW_LIBRARY_SHOW=login opens the Steam login sheet (captured as <file>-sheet.png).
                if env["MW_LIBRARY_SHOW"] == "login" { self?.steam.showLogin() }
                // MW_LIBRARY_SHOW=included shows the wallpapers that come with the app (screenshots without others' art).
                if env["MW_LIBRARY_SHOW"] == "included" {
                    self?.model.section = .bundled
                    self?.model.selection = self?.model.entries.first { $0.root == .bundled }?.id
                }
                // MW_LIBRARY_SHOW=browse opens Browse the Workshop (MW_LIBRARY_SELECT then picks the first result).
                if env["MW_LIBRARY_SHOW"] == "browse" {
                    self?.model.section = .workshopBrowse
                    // MW_BROWSE_SEARCH=<text> runs a Workshop search.
                    if let text = env["MW_BROWSE_SEARCH"] { self?.browse.search = text; self?.browse.reload() }
                }
            }
            // MW_BROWSE_SUBSCRIBE / MW_BROWSE_UNSUBSCRIBE=<id>: the inspector's buttons, for an item on the first page.
            for (key, subscribe) in [("MW_BROWSE_SUBSCRIBE", true), ("MW_BROWSE_UNSUBSCRIBE", false)] {
                guard let id = env[key].flatMap(UInt64.init) else { continue }
                DispatchQueue.main.asyncAfter(deadline: .now() + 12) { [weak self] in
                    guard let browse = self?.browse, let item = browse.items.first(where: { $0.id == id }) else {
                        return log("\(key): \(id) is not on the first page")
                    }
                    browse.selection = id
                    if subscribe { browse.subscribe(item) } else { browse.unsubscribe(item) }
                }
            }
            if env["MW_LIBRARY_SHOW"] == "browse", env["MW_LIBRARY_SELECT"] != nil {
                DispatchQueue.main.asyncAfter(deadline: .now() + 12) { [weak self] in self?.browse.selection = self?.browse.items.first?.id }
            }
            let delay: Double = env["MW_LIBRARY_SHOW"] == "browse" ? 16 : 7
            // Snapshots look like a focused window: macOS may not have let this launch take focus.
            DispatchQueue.main.asyncAfter(deadline: .now() + delay - 1) { [weak self] in
                NSApp.activate(ignoringOtherApps: true)
                self?.window?.makeKeyAndOrderFront(nil)
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in self?.snapshot(to: URL(fileURLWithPath: path)) }
        }
    }

    func snapshot(to url: URL) {
        func write(_ window: NSWindow?, _ url: URL) {
            guard let view = window?.contentView?.superview ?? window?.contentView,
                  let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
            view.cacheDisplay(in: view.bounds, to: rep)
            try? rep.representation(using: .png, properties: [:])?.write(to: url)
        }
        if let sheet = window?.attachedSheet {
            write(sheet, url.deletingPathExtension().appendingPathExtension("sheet.png"))
        }
        write(window, url)
    }

    func windowWillClose(_ notification: Notification) {
        returnToMenuBarIfNoWindows(closing: window)
    }
}

/// Back to a menu-bar-only app (no Dock icon) once no library or settings window is open.
@MainActor
func returnToMenuBarIfNoWindows(closing: NSWindow?) {
    let others = NSApp.windows.filter { $0 !== closing && $0.isVisible && $0.styleMask.contains(.titled) }
    if others.isEmpty { NSApp.setActivationPolicy(.accessory) }
}

/// The Steam account name as shown in the window. MW_DISPLAY_ACCOUNT=<name> replaces it (screenshots for the README
/// without the user's real account name).
func displayedAccountName(_ name: String) -> String {
    ProcessInfo.processInfo.environment["MW_DISPLAY_ACCOUNT"] ?? name
}
