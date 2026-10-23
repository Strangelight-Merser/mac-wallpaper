import AppKit
import Observation
import ServiceManagement
import WEAudio
import WELibrary

/// App preferences, saved in UserDefaults and applied to the running wallpaper as they change.
@MainActor
@Observable
final class AppSettings {
    private let defaults = UserDefaults.standard
    private let controller: WallpaperController

    var fps: Int { didSet { defaults.set(fps, forKey: "fps"); controller.fps = fps } }
    var mouseInput: Bool { didSet { defaults.set(mouseInput, forKey: "mouseInput"); controller.mouseInput = mouseInput } }
    var soundVolume: Float { didSet { defaults.set(soundVolume, forKey: "soundVolume"); controller.soundVolume = soundVolume } }
    var pauseOnBattery: Bool {
        didSet { defaults.set(pauseOnBattery, forKey: "pauseOnBattery"); controller.pauseOnBattery = pauseOnBattery }
    }
    var pauseInLowPowerMode: Bool {
        didSet { defaults.set(pauseInLowPowerMode, forKey: "pauseInLowPowerMode"); controller.pauseInLowPowerMode = pauseInLowPowerMode }
    }
    private(set) var audioEnabled: Bool
    private(set) var launchAtLogin: SMAppService.Status = SMAppService.mainApp.status

    init(controller: WallpaperController) {
        self.controller = controller
        fps = defaults.object(forKey: "fps") as? Int ?? 30
        mouseInput = defaults.object(forKey: "mouseInput") as? Bool ?? true
        soundVolume = defaults.object(forKey: "soundVolume") as? Float ?? 1
        pauseOnBattery = defaults.bool(forKey: "pauseOnBattery")
        pauseInLowPowerMode = defaults.bool(forKey: "pauseInLowPowerMode")
        // Only re-enable audio if the permission is still there (no prompt at launch).
        audioEnabled = defaults.bool(forKey: "audio") && SystemAudioCapture.hasPermission
        controller.fps = fps
        controller.mouseInput = mouseInput
        controller.soundVolume = soundVolume
        controller.pauseOnBattery = pauseOnBattery
        controller.pauseInLowPowerMode = pauseInLowPowerMode
        controller.audioEnabled = audioEnabled
    }

    // MARK: - launch at login

    var launchesAtLogin: Bool { launchAtLogin == .enabled }
    var launchAtLoginNeedsApproval: Bool { launchAtLogin == .requiresApproval }

    func setLaunchAtLogin(_ on: Bool) {
        do {
            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
        } catch { log("launch at login: \(error)") }
        launchAtLogin = SMAppService.mainApp.status
    }

    func refreshLaunchAtLogin() { launchAtLogin = SMAppService.mainApp.status }

    // MARK: - audio visualization

    /// Audio needs the Screen Recording permission (ScreenCaptureKit): the first request shows the system
    /// prompt; afterwards it can only be granted in System Settings (and macOS applies it after a relaunch).
    func setAudioEnabled(_ on: Bool) {
        if on {
            if !SystemAudioCapture.hasPermission { SystemAudioCapture.requestPermission() }
            guard SystemAudioCapture.hasPermission else {
                let alert = NSAlert()
                alert.messageText = String(localized: "Allow Screen Recording to visualize audio")
                alert.informativeText = String(localized: "Audio-reactive wallpapers read what your Mac is playing through ScreenCaptureKit, which macOS lists under Screen & System Audio Recording. Nothing is recorded or saved; only the audio spectrum is used.\n\nTurn on MacWallpaper in System Settings → Privacy & Security → Screen & System Audio Recording, quit and reopen MacWallpaper, then enable this item again.")
                alert.addButton(withTitle: String(localized: "Open System Settings"))
                alert.addButton(withTitle: String(localized: "Cancel"))
                NSApp.activate()
                if alert.runModal() == .alertFirstButtonReturn,
                   let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") {
                    NSWorkspace.shared.open(url)
                }
                return
            }
        }
        audioEnabled = on
        controller.audioEnabled = on
        defaults.set(on, forKey: "audio")
    }

    // MARK: - storage

    struct Usage: Equatable { var downloads: Int64 = 0; var caches: Int64 = 0 }
    private(set) var usage: Usage?

    static var cachesFolder: URL {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("MacWallpaper")
    }

    func measureStorage() async {
        let downloads = LibraryRoots.downloads.url, caches = Self.cachesFolder
        usage = await Task.detached { Usage(downloads: Self.size(of: downloads), caches: Self.size(of: caches)) }.value
    }

    /// Removes regenerable data (extracted package files, video texture copies, decoded sound links).
    func clearCaches() async {
        let caches = Self.cachesFolder
        await Task.detached {
            for item in (try? FileManager.default.contentsOfDirectory(at: caches, includingPropertiesForKeys: nil)) ?? [] {
                try? FileManager.default.removeItem(at: item)
            }
        }.value
        await measureStorage()
    }

    nonisolated static func size(of folder: URL) -> Int64 {
        guard let e = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: [.totalFileAllocatedSizeKey, .isSymbolicLinkKey]) else { return 0 }
        var total: Int64 = 0
        for case let url as URL in e {
            let v = try? url.resourceValues(forKeys: [.totalFileAllocatedSizeKey, .isSymbolicLinkKey])
            if v?.isSymbolicLink == true { continue }
            total += Int64(v?.totalFileAllocatedSize ?? 0)
        }
        return total
    }
}
