import AppKit
import SwiftUI

/// The library window. While it is open the app shows in the Dock and the app switcher; closing it
/// returns to a menu-bar-only app.
@MainActor
final class LibraryWindowController: NSWindowController, NSWindowDelegate {
    let model: LibraryModel

    init(model: LibraryModel) {
        self.model = model
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1180, height: 760),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                              backing: .buffered, defer: false)
        window.title = String(localized: "Wallpaper Library")
        window.minSize = NSSize(width: 820, height: 520)
        window.toolbarStyle = .unified
        window.isReleasedWhenClosed = false
        let hosting = NSHostingController(rootView: LibraryView(model: model))
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
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 7) { [weak self] in self?.snapshot(to: URL(fileURLWithPath: path)) }
        }
    }

    func snapshot(to url: URL) {
        guard let view = window?.contentView?.superview ?? window?.contentView,
              let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
        view.cacheDisplay(in: view.bounds, to: rep)
        try? rep.representation(using: .png, properties: [:])?.write(to: url)
    }

    func windowWillClose(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
    }
}
