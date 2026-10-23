import AppKit
import SwiftUI

/// The library window. While it is open the app shows in the Dock and the app switcher; closing it
/// returns to a menu-bar-only app.
@MainActor
final class LibraryWindowController: NSWindowController, NSWindowDelegate {
    let model: LibraryModel
    let steam: SteamModel

    init(model: LibraryModel, steam: SteamModel, assets: AssetsModel, setup: SetupModel) {
        self.model = model
        self.steam = steam
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1180, height: 760),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                              backing: .buffered, defer: false)
        window.title = String(localized: "Wallpaper Library")
        window.minSize = NSSize(width: 820, height: 520)
        window.toolbarStyle = .unified
        window.isReleasedWhenClosed = false
        let hosting = NSHostingController(rootView: LibraryView(model: model, steam: steam, assets: assets, setup: setup))
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
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 7) { [weak self] in self?.snapshot(to: URL(fileURLWithPath: path)) }
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
