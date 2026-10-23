# Workshop browsing and compatibility survey (backend; implementation spec)

Status: spec for implementation (2026-10-23). Background: `docs/design.md` §6.19 (product plan), §6.21 (WESteam),
§6.31 (roadmap). The reviewer writes all UI; you write the backend and a `wecli` command. Never touch
`Sources/WallpaperApp/` or user-facing text.

## 1. Workshop queries (`Sources/WESteam/WorkshopQuery.swift`)

Over the existing authenticated `SteamCMClient` (unified service calls, see `PublishedFile.GetUserFiles#1` in
`Sources/WESteam/Workshop.swift`), implement Wallpaper Engine (app 431960) workshop browsing:

```swift
public struct WorkshopQuery: Sendable, Equatable {
    public enum Sort: Sendable { case trend(days: Int), popular /* all-time votes */, recent, updated, mostSubscribed, textRelevance }
    public var sort: Sort
    public var searchText: String?
    public var requiredTags: [String]          // e.g. ["Scene"], ["Anime"]; all must match
    public var excludedTags: [String]          // e.g. ["Mature", "Questionable"] by default (reviewer decides)
    public var pageSize: Int                   // ≤ 100
}
public struct WorkshopPage: Sendable { public let items: [WorkshopItem]; public let total: Int; public let nextCursor: String? }
public struct WorkshopBrowser: Sendable {
    public init(client: SteamCMClient)
    public func query(_ q: WorkshopQuery, cursor: String = "*") async throws -> WorkshopPage
    public func subscribe(_ id: UInt64) async throws
    public func unsubscribe(_ id: UInt64) async throws
}
```

- `PublishedFile.QueryFiles#1`: field numbers and the `EPublishedFileQueryType` values from the references below;
  `appid`/`creator_appid` 431960, `return_tags`, `return_previews`, `return_metadata` (if cheap), `return_vote_data`,
  `return_short_description`, `strip_description_bbcode`, cursor paging. Map results into `WorkshopItem`
  (`Sources/WESteam/Workshop.swift`; extend it with optional fields the UI needs: creator id, short description,
  subscriptions/favorites/votes score, `previewURL`, file size, time created/updated, tags; keep existing fields and
  JSON coding compatible). WE's tag vocabulary: type tags (`Scene`, `Video`, `Web`, `Application`, `Preset`), age rating
  (`Everyone`, `Questionable`, `Mature`), genre tags (e.g. `Anime`, `Landscape`…), resolution tags (`1920 x 1080`, …),
  and misc (`Audio responsive`, `Customizable`, `Approved`): derive `kind` and `rating` from tags as the existing
  details code does.
- `PublishedFile.Subscribe#1` / `Unsubscribe#1` with `publishedfileid`, `list_type` 1 (subscribed), `appid` 431960
  (check the proto for `notify_client`). Map EResult failures to `SteamError`.
- **Preview images**: Steam UGC image URLs accept resize parameters (`?imw=W&imh=H&ima=fit`, plus `impolicy=Letterbox`
  variants). Add `WorkshopItem.previewURL(width:height:)` returning a small rendition (the user has limited data:
  the grid will request ~320×180). Verify the parameter names against the references or Steam's own pages' markup
  examples you can find in the references; if unsure, document what you used.
- Errors: a query without a session, network failures, malformed responses → `SteamError` (no crashes on missing
  fields).

References (local, read-only): `$REF/steam-user/protobufs/steammessages_publishedfile.steamclient.proto`,
`$REF/steam-user/components/` (service call patterns), `$REF/steam-user/enums/` (EPublishedFileQueryType, EResult)
with `REF=<scratchpad>/steamuser/node_modules`.

## 2. Compatibility survey (`Sources/WELibrary/WorkshopSurvey.swift` + `wecli workshop survey`)

Goal: estimate which missing renderer features block the most popular scene wallpapers, **spending as little data
as possible** (the user's bandwidth is limited).

- Step 1, metadata only (a few MB): query the top N scene wallpapers (`--top N`, default 200; `--sort trend|popular`;
  only `Everyone`), record id, title, size, tags, time updated, subscriptions.
- Step 2, file lists (small): for each item, fetch its depot **manifest only** (`WorkshopDownloader.plan` already does
  this without content chunks) and list the file names. Unpacked projects reveal their files directly; most scenes
  ship a single `scene.pkg`.
- Step 3, optional and size-gated (`--pkg-headers --max-mb N`, default off): for items with `scene.pkg`, download
  only the chunk(s) covering the PKG header (the file table at the start; see `Sources/WEFormat` PKG reader) to get
  their entry names, never whole files. Print the total bytes this would cost before downloading (`--plan` prints
  sizes only).
- Classification from file names (and `project.json`/`scene.json` when they are available as separate small files
  in the manifest and the user allowed step 3 / a byte budget): 3D models (`models/*.mdl`, `.mdla`), puppet warp
  (`.mdl` with puppet data — note if undecidable), particles (`particles/`), scripts can't be seen from names (count
  as unknown), sounds (`sounds/`), video textures (`.tex` whose name hints video can't be known: unknown), shaders
  (`shaders/` custom), fonts, light objects (unknown from names). Combine with the CompatibilityChecker feature list
  (`Sources/WELibrary/CompatibilityChecker.swift`) for what is already supported today.
- Output: a table "feature → wallpapers using it / wallpapers where it is the only known blocker", the share of
  items whose features couldn't be determined, and a **download suggestion**: the smallest set of items that covers
  each unsupported feature (with sizes and total), so the reviewer can ask the user. `--json` for machine output.

## 3. Tests (offline)

Hand-built protobuf responses: QueryFiles parsing (tags → kind/rating, previews, cursor, missing fields), request
encoding (sort → query type, tags, search text, paging), Subscribe/Unsubscribe request encoding and EResult mapping,
preview URL building. Survey classification from synthetic manifests and PKG headers, the "only blocker" logic,
and the download-suggestion set cover. No network in tests.

## 4. Done means

`swift build` / `swift test` pass, no new warnings. Changes limited to `Sources/WESteam/` (new file + small
extensions of `Workshop.swift`), `Sources/WELibrary/WorkshopSurvey.swift`, `Sources/wecli/main.swift`
(`wecli workshop query|subscribe|unsubscribe|survey`), `Tests/`. Do not commit; no README/prose files. Report: files,
API, tests, data cost of each survey step, anything you couldn't verify offline (the reviewer runs it live).
