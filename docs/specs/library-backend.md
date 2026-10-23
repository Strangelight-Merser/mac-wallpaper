# Library backend: `.pkg` asset roots, wallpaper index, compatibility check (implementation spec)

Status: implemented 2026-10-22 (review notes and results: `docs/design.md` §6.22). Background: `docs/design.md` §6.19 (library, compatibility
badges), §6.21 (Steam module). This is backend only; the SwiftUI library comes later and will consume these
APIs.

## 1. Goals

1. **Read wallpapers straight from `scene.pkg`** (no unpacking), with low memory use.
2. **Find and index** wallpapers on disk (workshop folders, our download folder, user folders) with the
   metadata the library UI needs, persisted and updated incrementally.
3. **Compatibility check**: decide per wallpaper "supported / partial (what is missing) / unsupported", fast
   and statically, with an optional deep check that actually renders a small frame.
4. `wecli library …` commands to run all of this on real folders.

## 2. Constraints

- No third-party dependencies, no network. Match the style of `Sources/WEVideo`, `Sources/WEWeb`,
  `Sources/WESteam`: doc comments on public API, sparse inline comments.
- Don't change rendering output: `scripts/regress.sh` must stay 131/131 (it needs a Metal device; if your
  sandbox has none, say so in the report — the reviewer runs it).
- `swift build`/`swift test` with no new warnings. Tests offline, using synthetic fixtures written by the
  tests themselves (never commit Wallpaper Engine content).

## 3. `.pkg` as an asset root (WEFormat + WEShader)

Today `AssetLocator(project:assets:)` searches `[project dir, assets dir]` (+ stock effect folders,
`effectNames(for:)`), and `PKG(bytes:)` copies the whole archive into memory.

Requirements:
- `PKG` gains a memory-mapped initializer: `PKG(url:)` using `Data(contentsOf:options: .alwaysMapped)`;
  entries are looked up through a dictionary (`[String: Entry]`); `contents(path:) -> Data?` returns a slice
  without copying the whole archive. Keep the old initializer working (wecli `pkg` uses it). Paths inside
  PKGs use `/`; match case-sensitively first, then case-insensitively (WE runs on Windows).
- Lookup order for a project folder: **files in the project folder → entries of `<project>/scene.pkg` (if
  present) → WE assets folder → stock effect folders** (existing rule). `project.json` normally sits outside
  the pkg but must also be found inside it.
- `AssetLocator` API: keep `data`, `json`, `string`; add `exists(_ relative:) -> Bool`. `url(_:)` keeps
  returning real file URLs; for an entry that lives only inside a pkg it **extracts that entry once** to
  `~/Library/Caches/MacWallpaper/pkg/<fingerprint>/<relative path>` (fingerprint = SHA-256 of pkg path +
  size + mtime, first 16 hex) and returns that URL. Extraction is atomic (write to temp, rename).
  Only video files and web pages need real URLs; everything else must go through `data`.
- `ShaderPreprocessor.readInclude` must stop requiring a URL: use `exists` + `string`, deduplicate includes by
  the resolved relative path. Keep shader output byte-identical for existing wallpapers (the shader cache is
  keyed by source, regression compares pixels).
- `Wallpaper.open` and `SceneDescription` must work for a folder containing only `project.json` +
  `scene.pkg` (+ preview). Verify with a synthetic pkg in tests (write a PKGV0018 file with a tiny
  `scene.json`, model, material, `.tex` — the PKG layout is in `Sources/WEFormat/Package.swift`; tests can
  reuse existing test-free fixtures if simpler, e.g. a solid-colour layer).

## 4. Library index (new target `WELibrary`, depends on WEFormat, WERender)

### 4.1 Discovery
```swift
public struct LibraryRoot: Codable, Sendable, Hashable {
    public enum Kind: String, Codable, Sendable { case steamWorkshop, downloads, userFolder }
    public var url: URL; public var kind: Kind
}
public enum LibraryRoots {
    /// Steam libraries from ~/Library/Application Support/Steam/steamapps/libraryfolders.vdf (+ the default
    /// library) → <library>/steamapps/workshop/content/431960, only those that exist.
    public static func steamWorkshopRoots() -> [LibraryRoot]
    /// ~/Library/Application Support/MacWallpaper/Workshop (where WESteam downloads go: <root>/<publishedFileID>/).
    public static var downloads: LibraryRoot
}
```
- Write a small Valve KeyValues text parser (`"key" "value"`, nested `{ }`, `//` comments, escapes `\\ \" \n \t`)
  in WEFormat (`VDF.swift`); use it for `libraryfolders.vdf`. Unit-test it.
- A wallpaper is a directory containing `project.json`. Scan each root one level deep (`<root>/<id>/project.json`)
  and the root itself; for `userFolder` roots also recurse up to 3 levels. Skip hidden directories and
  `*.partial` staging directories.

### 4.2 Entries
```swift
public struct WallpaperEntry: Codable, Sendable, Identifiable, Equatable {
    public var id: String               // "ws:<workshopid>" if project.json has workshopid, else "dir:<sha256(path) prefix>"
    public var folder: URL
    public var root: LibraryRoot.Kind
    public var title: String
    public var type: WallpaperType      // scene, video, web, application, unknown (from project.json "type"; a .json file means scene)
    public var file: String             // project.json "file"
    public var preview: URL?            // project.json "preview" if the file exists (gif/jpg/png/mp4)
    public var tags: [String]           // project.json "tags"
    public var contentRating: ContentRating   // Everyone / Questionable / Mature (default Everyone if missing)
    public var workshopID: UInt64?
    public var hasUserProperties: Bool  // general.properties not empty (ignore "schemecolor")
    public var audioResponsive: Bool    // general.supportsaudioprocessing == true
    public var sizeOnDisk: Int64        // sum of regular files (follow no symlinks)
    public var modified: Date           // newest mtime of project.json and the main file / scene.pkg
    public var compatibility: Compatibility?
}
```
Parse `project.json` leniently (JSON5-ish: the existing `AssetLocator.json` options); a broken or missing field
never drops the entry — record a `problem` string instead (add `public var problems: [String]`).

### 4.3 Persistence and incremental updates
```swift
public actor WallpaperLibrary {
    public init(indexURL: URL)          // default: ~/Library/Application Support/MacWallpaper/library.json
    public func entries() -> [WallpaperEntry]
    /// Rescans roots; entries whose folder fingerprint and checker version are unchanged keep their
    /// compatibility result; removed folders disappear; returns the diff (added/updated/removed ids).
    public func refresh(roots: [LibraryRoot], assets: URL?, deep: Bool) async -> LibraryDiff
}
```
- Folder fingerprint: size + mtime of `project.json`, the main file and `scene.pkg` (not a full hash).
- Store `checkerVersion` (an integer constant in `CompatibilityChecker`, bump it whenever detection changes)
  and an assets fingerprint (path + mtime of `assets/shaders` and `assets/materials` folders); either changing
  invalidates stored compatibility results.
- JSON file written atomically; schema version field; unreadable index → start empty (keep the bad file as
  `library.json.bad`).
- Duplicate `ws:` ids (same item in Steam's folder and ours): keep both entries but give the second an id
  suffix `#<n>` and mark `duplicateOf`.

## 5. Compatibility check

```swift
public struct Compatibility: Codable, Sendable, Equatable {
    public enum Status: String, Codable, Sendable { case supported, partial, unsupported, needsAssets }
    public var status: Status
    public var missing: [Feature: Int]   // feature → count of objects/effects using it
    public var notes: [String]           // human-readable details for logs (not UI text)
    public var checkedDeep: Bool
    public var checkerVersion: Int
}
public enum Feature: String, Codable, Sendable, CaseIterable {
    case particles, text, model3D, puppetWarp, sound, light, sceneScript, videoTexture,
         missingEffect, shaderError, missingAsset, unsupportedVideoCodec, applicationWallpaper, unknownObject
}
public struct CompatibilityChecker {
    public static let version = 1
    public init(assets: URL?)
    public func check(_ entry: WallpaperEntry, deep: Bool) async -> Compatibility
}
```

### 5.1 Static check (always)
- `application` → `unsupported` (`applicationWallpaper`).
- `video`: file exists; for `.webm` read the codec via `WebMFile` (VP9/AV1 native, VP8 via WebKit — all
  supported); for mp4/mov use `AVURLAsset` track format descriptions (H.264, HEVC, AV1, ProRes ok; anything
  else → `unsupportedVideoCodec`). Missing file → `missingAsset`.
- `web`: the `file` exists → supported.
- `scene`: needs WE assets for stock shaders/materials: if `assets == nil` → `needsAssets`. Parse the scene
  json (through `AssetLocator`, so pkg works). For each object in `objects`:
  - `image` → resolve its model json; model has `puppet` → `puppetWarp`; material/textures must resolve
    (`missingAsset` otherwise); textures whose `.tex` is a video container (`Tex` flag `isVideo` or TEXB0004
    with an mp4 payload — check `Sources/WEFormat/Tex.swift`) → `videoTexture`.
  - `particle` → `particles`; `text` → `text`; `model` (3D) → `model3D`; `sound` → `sound`; `light` → `light`;
    anything else non-empty → `unknownObject`.
  - Effects on images: effect json must resolve (project, pkg, assets, stock effect folders) else
    `missingEffect`.
  - Any dictionary anywhere in the object (or in `general`) with a `"script"` key → `sceneScript` (count once
    per object). Also `"scriptproperties"`.
  Match what `SceneDescription` already treats as unsupported (it records notes like "particle object not
  supported"); keep the two consistent — ideally reuse its parsing rather than duplicating it.
- Status: no missing features → `supported`; missing features but at least one renderable image layer →
  `partial`; nothing renderable or open fails → `unsupported`.

### 5.2 Deep check (`deep: true`)
Open with `Wallpaper.open` and render one 256×144 frame at t = 1 s (scenes: `SceneRenderer.render`; video:
first frame; web: skip — WebKit needs the main thread, treat static result as final). Map renderer warnings:
shader compile failures → `shaderError` (count distinct shaders), other "not supported" notes → the matching
feature; a thrown error → `unsupported` with the error in `notes`. Deep checks must run serially (Metal/shader
cache) and be cancellable between wallpapers.

## 6. wecli

```
wecli library scan [--root <dir>]... [--steam] [--downloads] --assets <dir> [--deep] [--json]
    lists entries: id, type, rating, status, missing features, title; then a summary:
    counts per type and per status, and per missing feature "N wallpapers would gain support"
wecli library show <folder>        one entry with all fields and notes
```
`--steam` adds `LibraryRoots.steamWorkshopRoots()`, `--downloads` adds `LibraryRoots.downloads`. Use a
temporary index unless `--index <file>` is given (don't touch the app's real index from wecli by default).

## 7. Tests (offline)

- VDF parser (nesting, comments, escapes, libraryfolders sample text written in the test).
- PKG: memory-mapped reading, dictionary lookup, case-insensitive fallback, bounds errors.
- AssetLocator precedence: project file beats pkg entry beats assets; `exists`; `url` extraction of a pkg
  entry (into a temp cache dir — make the cache root injectable) and reuse on second call.
- ShaderPreprocessor include resolution from a pkg (synthetic shader + include).
- Discovery: synthetic roots with nested folders, hidden and `.partial` dirs.
- Entry parsing: missing/garbled fields produce problems, not dropped entries; rating/tags/workshopid.
- Static compatibility on synthetic scene folders: image-only → supported; + particle + text + script →
  partial with counts; application → unsupported; no assets → needsAssets; missing effect → missingEffect.
- Index persistence: refresh twice without changes keeps results and doesn't re-check (count checks via an
  injected checker); touching project.json re-checks; bumping the version re-checks; removed folder removed.

## 8. Done means

Build/tests pass, regression unchanged (or reported as not runnable in the sandbox), no edits outside:
`Package.swift`, `Sources/WEFormat/` (PKG, AssetLocator, new VDF), `Sources/WEShader/ShaderPreprocessor.swift`
(include lookup only), `Sources/WERender/` (only if needed for pkg-based opening), new `Sources/WELibrary/`,
`Sources/wecli/main.swift` (library commands), `Tests/`. Do not commit. Finish with a short report: files,
what tests cover, deviations from this spec, and what the reviewer must verify live.
