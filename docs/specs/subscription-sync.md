# Workshop subscription sync and safe updates (backend; implementation spec)

Status: implemented and merged (2026-10-23); results in `docs/design.md` §6.30. Background: `docs/design.md` §6.19 (product plan: subscriptions are
migrated as a pre-selected list with sizes; updates are staged and compatibility-checked before replacing a working
version), §6.21–6.24 (WESteam, library, import and download queue). The reviewer writes the UI and app wiring; you
write the backend. Never touch `Sources/WallpaperApp/` or user-facing text.

## 1. Existing pieces

- `WESteam.SteamWorkshop.subscriptions` / `details` (`Sources/WESteam/Workshop.swift`): subscribed ids and item details
  (`WorkshopItem.timeUpdated`, `contentManifestID`, `fileSize`, kind, rating).
- `WESteam.WorkshopDownloader` (plan → download with resume, SHA-1 checks, atomic replace) writes
  `<folder>/.steam-manifest.json` (`publishedFileID`, `timeUpdated`, `manifestID`, `files`, `bytes`).
- Downloads live in `WELibrary.LibraryRoots.downloads` (`~/Library/Application Support/MacWallpaper/Workshop/<id>`).
- `WELibrary.CompatibilityChecker` (static and deep checks) and `WallpaperLibrary` (index).
- The app's `DownloadQueue` (`Sources/WallpaperApp/Steam/DownloadQueue.swift`) runs downloads on a shared, auto-
  reconnecting Steam connection. You do not change it; the reviewer will move it onto your API.

## 2. Sync (`Sources/WELibrary/SubscriptionSync.swift`)

```swift
public struct SyncPlan: Sendable, Equatable {
    public var new: [WorkshopItem]          // subscribed, not downloaded (minus items the user declined)
    public var updated: [Update]            // downloaded, Steam has a newer manifest
    public var unsubscribed: [UInt64]       // downloaded by us but no longer subscribed (never auto-deleted)
    public var unchanged: Int
    public struct Update: Sendable, Equatable { public let item: WorkshopItem; public let localManifest: UInt64;
        public let localTimeUpdated: Date }
}
public enum SubscriptionSync {
    /// Pure: compare subscriptions + details with the local download folders' .steam-manifest.json files.
    public static func plan(subscribed: [WorkshopItem], downloads root: URL, declined: Set<UInt64>) throws -> SyncPlan
}
```

Only folders we downloaded (with `.steam-manifest.json`) count; Steam's own workshop folders and user folders are
left alone. Items that failed on Steam (`result != 1`) are skipped.

## 3. Safe updates (`Sources/WELibrary/StagedUpdate.swift`)

```swift
public enum UpdateOutcome: Sendable, Equatable {
    case installed(previousKept: Bool)
    case held(reason: HoldReason)            // new version checks worse than the current one: current kept
    case failed(String)
}
public enum HoldReason: Sendable, Equatable { case unsupported, lostFeatures([Feature]), missingAssets }
public struct StagedUpdater {
    public init(root: URL, checker: CompatibilityChecker, deepCheck: Bool,
                download: @Sendable (WorkshopItem, URL) async throws -> Void)   // injected: downloads into a folder
    public func update(_ item: WorkshopItem) async -> UpdateOutcome
    public func rollback(_ id: UInt64) throws    // restore the kept previous version
}
```

Flow: download the new version into `<root>/.staging/<id>` (resumable: the injected download reuses verified files),
run the compatibility check on the staged folder and on the current one; if the new status is not worse (supported ≥
partial ≥ needsAssets ≥ unsupported, and no feature that worked before is now missing) swap it in atomically (keep the
old one at `<root>/.previous/<id>`, one level; delete older), else keep the current version, record the held update
(item id, new manifest id, reason) in a small JSON state file (`<root>/.sync-state.json`, injectable) so the UI can
show "update held" and the user can force it (`force: true` variant) or dismiss it. Also record `lastSync` and the
set of declined ids there (`SyncState` Codable with load/save).

## 4. Tests (offline)

`plan` with temp folders and hand-written `.steam-manifest.json`s (new / updated by manifest id / same manifest but
newer timeUpdated — treat as updated / unsubscribed / declined / Steam error items / folders without manifest ignored).
`StagedUpdater` with fake downloads producing project folders: better/equal → installed with previous kept; worse →
held, current untouched; failure → current untouched, staging cleaned or resumable; rollback restores; force installs a
held update; state file round trip.

## 5. Done means

`swift build` / `swift test` pass, no new warnings. Changes limited to the new files in `Sources/WELibrary/`
(`SubscriptionSync.swift`, `StagedUpdate.swift`, helpers), minimal public-API additions in `Sources/WESteam/`
(e.g. making a type's fields public) and `Sources/WELibrary/CompatibilityChecker.swift` only if a comparison helper is
needed there, `Tests/`. Other Codex jobs work in parallel on `Sources/WERender/`, `Sources/WEWeb/`,
`Sources/WESteam/WEAssets.swift` and new `Sources/WELibrary/` files (`AssetsManager`, `WallpaperProperties`,
`PropertyStore`): do not touch those. Do not commit. Report: files, API, tests, what the app must do.
