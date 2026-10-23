import SwiftUI
import WELibrary

extension WallpaperType {
    var label: String {
        switch self {
        case .scene: String(localized: "Scene")
        case .video: String(localized: "Video")
        case .web: String(localized: "Web")
        case .application: String(localized: "Application")
        case .unknown: String(localized: "Unknown")
        }
    }

    var symbol: String {
        switch self {
        case .scene: "square.3.layers.3d"
        case .video: "play.rectangle"
        case .web: "globe"
        case .application: "app"
        case .unknown: "questionmark.square"
        }
    }
}

extension ContentRating {
    var label: String {
        switch self {
        case .everyone: String(localized: "Everyone")
        case .questionable: String(localized: "Questionable")
        case .mature: String(localized: "Mature")
        }
    }
}

extension Compatibility.Status {
    var label: String {
        switch self {
        case .supported: String(localized: "Fully supported")
        case .partial: String(localized: "Partly supported")
        case .unsupported: String(localized: "Not supported on Mac yet")
        case .needsAssets: String(localized: "Needs Wallpaper Engine assets")
        }
    }

    var symbol: String {
        switch self {
        case .supported: "checkmark.circle.fill"
        case .partial: "circle.lefthalf.filled"
        case .unsupported: "xmark.circle.fill"
        case .needsAssets: "exclamationmark.circle.fill"
        }
    }

    var tint: Color {
        switch self {
        case .supported: .green
        case .partial: .orange
        case .unsupported: .red
        case .needsAssets: .secondary
        }
    }
}

extension Feature {
    /// What the user would notice is missing, in plain words.
    var label: String {
        switch self {
        case .particles: String(localized: "Particles")
        case .text: String(localized: "Text and clocks")
        case .model3D: String(localized: "3D models")
        case .puppetWarp: String(localized: "Puppet animation")
        case .sound: String(localized: "Sound")
        case .light: String(localized: "Lights")
        case .sceneScript: String(localized: "Scripts")
        case .videoTexture: String(localized: "Video textures")
        case .missingEffect: String(localized: "Missing effects")
        case .shaderError: String(localized: "Effects that fail to compile")
        case .missingAsset: String(localized: "Missing files")
        case .unsupportedVideoCodec: String(localized: "Unsupported video format")
        case .applicationWallpaper: String(localized: "Windows program")
        case .unknownObject: String(localized: "Unknown objects")
        }
    }
}

/// Small coloured status mark used on cards and in the inspector.
struct CompatibilityBadge: View {
    let status: Compatibility.Status?
    var showsLabel = false

    var body: some View {
        if let status {
            Label {
                if showsLabel { Text(status.label) }
            } icon: {
                Image(systemName: status.symbol).foregroundStyle(status.tint)
            }
            .labelStyle(.titleAndIcon)
            .help(status.label)
        } else {
            ProgressView().controlSize(.mini).help(Text("Checking…"))
        }
    }
}

extension HoldReason {
    /// Why an update was not installed (the installed version is kept).
    var explanation: String {
        switch self {
        case .unsupported: String(localized: "Update held back: the new version doesn’t run on this Mac.")
        case .missingAssets: String(localized: "Update held back: the new version needs Wallpaper Engine files that are missing.")
        case .lostFeatures(let features):
            String(localized: "Update held back: the new version uses things this Mac can’t show yet (\(features.map(\.label).joined(separator: ", "))).")
        }
    }
}
