// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "MacWallpaper",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "WEFormat", targets: ["WEFormat"]),
        .executable(name: "wecli", targets: ["wecli"]),
        .executable(name: "WallpaperApp", targets: ["WallpaperApp"]),
    ],
    targets: [
        .target(name: "WEFormat"),
        .target(name: "WEShader", dependencies: ["WEFormat"]),
        .target(name: "WERender", dependencies: ["WEFormat", "WEShader"]),
        .executableTarget(name: "wecli", dependencies: ["WEFormat", "WERender"]),
        .executableTarget(name: "WallpaperApp", dependencies: ["WERender"]),
        // Compiles .metal files through MTLDevice.makeLibrary (used by scripts/shader_batch.py).
        .executableTarget(name: "metalcheck", path: "tools", sources: ["metalcheck.swift"]),
    ]
)
