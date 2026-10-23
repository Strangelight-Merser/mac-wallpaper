import AppKit
import SwiftUI
import WELibrary

/// The standard macOS settings window: a toolbar of panes.
@MainActor
final class SettingsWindowController: NSWindowController, NSWindowDelegate {
    init(settings: AppSettings, steam: SteamModel, assets: AssetsModel, openLibrary: @escaping () -> Void) {
        let tabs = NSTabViewController()
        tabs.tabStyle = .toolbar
        // The window takes the selected pane's title and resizes to its height.
        tabs.canPropagateSelectedChildViewControllerTitle = true
        func pane<V: View>(_ title: String, _ symbol: String, _ view: V) {
            let hosting = NSHostingController(rootView: view.scrollDisabled(true).frame(width: 500).fixedSize(horizontal: false, vertical: true))
            hosting.sizingOptions = [.preferredContentSize]
            hosting.title = title
            let item = NSTabViewItem(viewController: hosting)
            item.label = title
            item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: title)
            tabs.addTabViewItem(item)
        }
        pane(String(localized: "General"), "gearshape", GeneralPane(settings: settings))
        pane(String(localized: "Playback"), "play.rectangle", PlaybackPane(settings: settings))
        pane(String(localized: "Sound"), "speaker.wave.2", SoundPane(settings: settings))
        pane(String(localized: "Account & Storage"), "internaldrive",
             StoragePane(settings: settings, steam: steam, assets: assets, openLibrary: openLibrary))
        let window = NSWindow(contentViewController: tabs)
        window.styleMask = [.titled, .closable]
        window.isReleasedWhenClosed = false
        super.init(window: window)
        window.delegate = self
    }

    func windowWillClose(_ notification: Notification) { returnToMenuBarIfNoWindows(closing: window) }

    required init?(coder: NSCoder) { fatalError("not used") }

    func show() {
        NSApp.setActivationPolicy(.regular)
        window?.center()
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate()
    }

    /// Debug: writes each pane to `<base>-<n>.png` (MW_SETTINGS_SNAPSHOT=<base>), for checking the UI
    /// without screen-recording permission.
    func snapshotPanes(base: String) {
        guard let tabs = contentViewController as? NSTabViewController else { return }
        for i in tabs.tabViewItems.indices {
            DispatchQueue.main.asyncAfter(deadline: .now() + Double(i) * 1.5 + 1) { [weak self] in
                tabs.selectedTabViewItemIndex = i
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
                    guard let view = self?.window?.contentView?.superview,
                          let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
                    view.cacheDisplay(in: view.bounds, to: rep)
                    try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: "\(base)-\(i).png"))
                }
            }
        }
    }
}

private struct GeneralPane: View {
    @Bindable var settings: AppSettings

    var body: some View {
        Form {
            Section {
                Toggle(isOn: Binding(get: { settings.launchesAtLogin }, set: { settings.setLaunchAtLogin($0) })) {
                    Text("Open at Login")
                    Text("Shows your wallpaper as soon as you log in.")
                }
                if settings.launchAtLoginNeedsApproval {
                    HStack {
                        Text("Allow MacWallpaper in System Settings → General → Login Items.")
                            .font(.callout).foregroundStyle(.secondary)
                        Spacer()
                        Button { SMAppServiceSettings.open() } label: { Text("Open…") }
                    }
                }
            }
            Section {
                Toggle(isOn: $settings.mouseInput) {
                    Text("Mouse Interaction")
                    Text("Wallpapers react to the pointer and clicks on the desktop.")
                }
            }
        }
        .formStyle(.grouped)
        .onAppear { settings.refreshLaunchAtLogin() }
    }
}

private enum SMAppServiceSettings {
    static func open() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.LoginItems-Settings.extension") { NSWorkspace.shared.open(url) }
    }
}

private struct PlaybackPane: View {
    @Bindable var settings: AppSettings

    var body: some View {
        Form {
            Section {
                Picker(selection: $settings.fps) {
                    ForEach([15, 24, 30, 60], id: \.self) { fps in Text("\(fps) fps").tag(fps) }
                } label: { Text("Frame Rate") }
            } footer: {
                Text("Higher frame rates look smoother and use more energy.").font(.callout).foregroundStyle(.secondary)
            }
            Section {
                Toggle(isOn: $settings.pauseOnBattery) { Text("Pause on Battery Power") }
                Picker(selection: $settings.pauseInLowPowerMode) {
                    Text("Lower the Frame Rate").tag(false)
                    Text("Pause").tag(true)
                } label: { Text("In Low Power Mode") }
            } footer: {
                Text("Wallpapers also pause on their own while the desktop is covered, the screen is locked or the displays sleep.")
                    .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
        .formStyle(.grouped)
    }
}

private struct SoundPane: View {
    @Bindable var settings: AppSettings

    var body: some View {
        Form {
            Section {
                LabeledContent {
                    HStack {
                        Image(systemName: "speaker.fill").foregroundStyle(.secondary)
                        Slider(value: $settings.soundVolume, in: 0...1)
                        Image(systemName: "speaker.wave.3.fill").foregroundStyle(.secondary)
                    }
                } label: {
                    Text("Wallpaper Sound")
                    Text("Music and effects that wallpapers play.")
                }
            }
            Section {
                Toggle(isOn: Binding(get: { settings.audioEnabled }, set: { settings.setAudioEnabled($0) })) {
                    Text("Audio Visualization")
                    Text("Audio-reactive wallpapers follow what your Mac is playing. Needs Screen & System Audio Recording permission; nothing is recorded.")
                }
            }
        }
        .formStyle(.grouped)
    }
}

private struct StoragePane: View {
    let settings: AppSettings
    let steam: SteamModel
    let assets: AssetsModel
    let openLibrary: () -> Void
    @State private var confirmClear = false

    var body: some View {
        Form {
            Section {
                if let account = steam.account {
                    LabeledContent { Button { steam.signOut() } label: { Text("Log Out") } } label: {
                        Text("Steam"); Text("Logged in as \(account.accountName)")
                    }
                } else {
                    LabeledContent { Button { openLibrary(); steam.showLogin() } label: { Text("Log In…") } } label: {
                        Text("Steam"); Text("Not logged in")
                    }
                }
                LabeledContent {
                    Button { openLibrary(); assets.sheetShown = true } label: { Text("Manage…") }
                } label: {
                    Text("Wallpaper Engine Files")
                    assets.isInstalled ? Text("Installed") : Text("Not installed")
                }
            }
            Section {
                LabeledContent {
                    Button { NSWorkspace.shared.open(LibraryRoots.downloads.url) } label: { Text("Show in Finder") }
                } label: {
                    Text("Downloaded Wallpapers")
                    if let usage = settings.usage { Text(usage.downloads.formatted(.byteCount(style: .file))) } else { Text("Measuring…") }
                }
                LabeledContent {
                    Button { confirmClear = true } label: { Text("Clear…") }
                        .confirmationDialog(Text("Clear caches?"), isPresented: $confirmClear) {
                            Button(role: .destructive) { Task { await settings.clearCaches() } } label: { Text("Clear Caches") }
                        } message: {
                            Text("Files unpacked from wallpapers are removed and recreated when needed. Downloads and settings are kept.")
                        }
                } label: {
                    Text("Caches")
                    if let usage = settings.usage { Text(usage.caches.formatted(.byteCount(style: .file))) } else { Text("Measuring…") }
                }
            }
        }
        .formStyle(.grouped)
        .task {
            steam.loadAccount()
            await assets.refresh()
            await settings.measureStorage()
        }
    }
}
