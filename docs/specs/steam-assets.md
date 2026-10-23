# Download Wallpaper Engine's `assets` folder through Steam (implementation spec)

Status: spec for implementation (2026-10-23). Background: `docs/design.md` §6.19–6.21 and
`docs/specs/steam-module.md` (the WESteam module this builds on).

## 1. Goal

Scene wallpapers need WE's `assets` folder (stock shaders, materials, effects, particles, fonts). Users
without a Windows PC can't copy it, so the app downloads it from the user's own Steam account: only the
`assets/` directory of the Wallpaper Engine (app 431960) Windows depot, not the whole program. The download
only works if the account owns WE — Steam enforces that through the depot key.

The user has limited bandwidth: the size must be known and shown **before** any content is downloaded, and
the download must honour a byte limit (same rule as workshop downloads).

## 2. Steps (extend `Sources/WESteam`)

1. **App info (PICS)** over the existing `SteamCMClient` session: request an access token for app 431960
   (`ClientPICSAccessTokenRequest` → response), then product info (`ClientPICSProductInfoRequest` with the
   token → `ClientPICSProductInfoResponse`). The app info `buffer` is a text KeyValues document (possibly with
   a trailing NUL) — parse it with the existing `Sources/WEFormat/VDF.swift` parser (move/expose it as needed).
   Reference: `$REF/steam-user/components/apps.js` (`getProductInfo`, access tokens, the response handling)
   and the `.proto` files listed in `docs/specs/steam-module.md` §3
   (`steammessages_clientserver_appinfo.proto`). Verify every EMsg and field number against them.
   `REF=<scratchpad>/steamuser/node_modules`
2. **Pick the depot**: under `depots`, the depot(s) whose `config.oslist` contains `windows` (or that have no
   oslist) and that have `manifests.public.gid` (newer appinfo puts the gid under `manifests.public.gid`;
   older under `manifests.public`) — handle both. Skip depots marked `sharedinstall`/`depotfromapp` and DLC
   depots. Expose the build id (`depots.branches.public.buildid`) for update detection.
3. **Manifest**: `ContentServerDirectory.GetManifestRequestCode#1` with the app id, depot id, manifest gid and
   branch `public`; download and parse exactly as `WorkshopDownloader.plan` does for workshop items (factor
   the shared code so workshop items and app depots use one implementation; workshop behaviour must not
   change).
4. **Filter** the manifest to files under `assets/` (case-insensitive, `\` or `/` separators); strip that
   prefix so the result is a plain `assets` directory.
5. **Plan first**: return the filtered file count, network bytes (sum of chunk compressed sizes) and disk
   bytes before downloading anything.
6. **Download** with the existing machinery (parallel chunks, retries, resume from `<dest>.partial`, per-chunk
   and per-file SHA-1, atomic replacement, `maxBytes`). Destination chosen by the caller; the app will use
   `~/Library/Application Support/MacWallpaper/WEAssets/assets`. Write a receipt next to it (depot id,
   manifest gid, build id, file count, bytes) so a later run can tell whether an update exists without
   downloading content.
7. **Update check** API: given the receipt, report "up to date" or the new manifest gid and the sizes of what
   changed (files whose SHA-1 differs or that are new), so an update downloads only changed files (the resume
   logic already skips files whose SHA-1 matches — reuse it).

Chunk compression: app depots may use zstd (`VSZa`), which the module does not support yet
(`SteamError.unsupportedCompression("zstd")`). Do not vendor a decoder; if a depot needs it, the error must
surface clearly. The plan step can't know the compression without downloading a chunk — that's fine.

## 3. API sketch

```swift
public struct WEAssetsPlan: Sendable { public let depotID: UInt32; public let manifestID: UInt64
    public let buildID: UInt64; public let files: Int; public let networkBytes: Int64; public let diskBytes: Int64 }
public struct WEAssetsDownloader {
    public init(client: SteamCMClient, session: SteamSession)
    public func plan() async throws -> WEAssetsPlan
    public func download(_ plan: WEAssetsPlan, to assetsDir: URL, maxBytes: Int64,
                         progress: @Sendable (DownloadProgress) -> Void) async throws -> DownloadResult
    public func checkForUpdate(receiptAt assetsDir: URL) async throws -> WEAssetsUpdate   // upToDate / available(plan, changedBytes)
}
```

## 4. wecli

```
wecli steam assets --out <dir> [--max-mb N] [--yes] [--plan]
    --plan: print depot, build, files, download size and disk size, then stop (no content download)
    otherwise downloads; refuses anything over --max-mb (default 10) unless --yes
```

## 5. Tests (offline)

PICS response decoding (hand-built protobuf with a text-VDF buffer), depot selection (windows/no oslist,
both gid layouts, shared/DLC skipped, missing public branch → clear error), the `assets/` filter (separators,
case, prefix stripping, files outside are excluded), plan sizes, receipt round trip, update-diff computation
from two synthetic manifests. Existing WESteam tests must keep passing unchanged.

## 6. Done means

`swift build` / `swift test` pass with no new warnings; changes limited to `Sources/WESteam/`,
`Sources/WEFormat/VDF.swift` (only if exposing/moving the parser), `Sources/wecli/main.swift` (the `steam
assets` command), `Package.swift`, `Tests/`. No network access is available or needed — the reviewer does
the live `--plan` run (metadata only) and decides with the user whether to download. Do not commit. Report:
files, test coverage, deviations from the spec or the references, and what the reviewer should verify live.
