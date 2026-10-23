# WE assets in the app: status, download, updates (backend; implementation spec)

Status: spec for implementation (2026-10-23). Background: `docs/design.md` §6.25 (WE assets download, verified live:
2,935 files, 38.2 MB download, 79.5 MB on disk; zstd chunks), `docs/specs/steam-assets.md`. The reviewer writes the
onboarding UI and app flow; you write the backend. Never touch `Sources/WallpaperApp/` or user-facing text.

## 1. Goal

Scene wallpapers need WE's `assets` folder. The app must know whether it has one, get it from the user's Steam
account in a few clicks (size shown first; the user has limited bandwidth), keep it current, and never surprise the
user with a download.

## 2. API (`Sources/WELibrary/AssetsManager.swift`, may depend on `WESteam`)

```swift
public enum AssetsStatus: Sendable, Equatable {
    case missing
    case installed(location: URL, source: Source, buildID: UInt64?)   // Source: .downloaded (ours) / .userFolder
    case checking
    case updateAvailable(location: URL, changedBytes: Int64, changedDiskBytes: Int64)
    case downloading(doneBytes: Int64, totalBytes: Int64, files: Int, totalFiles: Int)
    case failed(String)            // human-readable cause, e.g. zstd, network, not owned
}
@MainActor public final class AssetsManager {   // observable (Observation) so SwiftUI can bind
    public private(set) var status: AssetsStatus
    public var location: URL? { get }              // the folder scenes should use, if any
    public init(defaultLocation: URL = …/Application Support/MacWallpaper/WEAssets/assets,
                userFolder: URL?,                  // a folder the user chose earlier (kept, takes precedence)
                steam: AssetsSteamAccess)          // injectable: plan / download / update check
    public func refresh() async                    // detect installed / validate (structure check, receipt)
    public func plan() async throws -> WEAssetsPlan          // sizes, no content
    public func download(maxBytes: Int64) async throws        // progress via status; resumable; cancellable
    public func cancel()
    public func checkForUpdate() async                         // only manifest metadata (≈1–3 MB)
    public func installUpdate() async throws
}
public protocol AssetsSteamAccess: Sendable {   // the app adapts its shared Steam connection to this
    func plan() async throws -> WEAssetsPlan
    func download(_ plan: WEAssetsPlan, to: URL, maxBytes: Int64, progress: @Sendable (DownloadProgress) -> Void) async throws
    func checkForUpdate(receiptAt: URL) async throws -> WEAssetsUpdate
}
```

Build on `WESteam.WEAssetsDownloader` (`Sources/WESteam/WEAssets.swift`) and its receipt; adapt types where needed
(public initializers/properties) without changing their behaviour. A "valid assets folder" has at least `shaders/`,
`materials/`, `effects/` and a few known files (e.g. `shaders/genericimage2.frag`, `materials/util/composelayer.json`)
— the same check must accept the user's existing folder (`samples/wallpaper_engine/assets` in this repo is one).
Downloads go to a sibling staging folder and are swapped in atomically (the downloader already supports resume and
reuse); a failed or cancelled download leaves an existing installation untouched. Updates download only changed
files (the receipt/update API already computes them).

Also expose the size numbers for the UI (bytes, file counts) and a one-line cause for failures (map
`SteamError.unsupportedCompression`, not-owned/denied depot keys, network errors to distinct cases or messages; the
reviewer writes the user-facing wording, so return structured causes, not prose — e.g. an enum `AssetsFailure`).

## 3. Tests (offline)

With a fake `AssetsSteamAccess`: missing → plan → download (progress sequence, final installed, receipt written),
cancel mid-way (existing installation untouched), failure mapping, update check (up to date / available with sizes) and
install, user folder precedence and validation (accept a minimal fake assets tree, reject an empty or wrong folder).

## 4. Done means

`swift build` / `swift test` pass, no new warnings. Changes limited to the new `Sources/WELibrary/AssetsManager.swift`
(+ small helpers), minimal public-API additions in `Sources/WESteam/WEAssets.swift`, `Package.swift` if a dependency is
needed, `Tests/`. Other Codex jobs work in parallel on `Sources/WERender/`, `Sources/WEWeb/`, and new
`Sources/WELibrary/WallpaperProperties.swift`, `PropertyStore.swift`, `SubscriptionSync.swift`: do not touch those.
Do not commit. Report: files, API, tests, anything the app must do.
