# Wallpaper properties: model, storage and live updates (backend; implementation spec)

Status: implemented and merged (2026-10-23); results in `docs/design.md` §6.30. Background: `docs/design.md` §6.19 (product plan), §6.26–6.29.
The reviewer writes the properties panel UI; you write everything below it. Never touch
`Sources/WallpaperApp/` or user-facing text.

## 1. Model (`Sources/WELibrary/WallpaperProperties.swift`)

Parse `project.json` → `general.properties` (a dictionary keyed by property name) into an ordered list:

```swift
public struct WallpaperProperty: Sendable, Equatable, Identifiable {
    public enum Kind: Sendable, Equatable {
        case bool
        case slider(min: Double, max: Double, step: Double?, precision: Int?, fraction: Bool)
        case color                       // "r g b" in 0…1
        case combo(options: [(label: String, value: String)])   // make it Equatable (struct)
        case textInput                   // free text value
        case label                       // "text"/"Text": display only, no value
        case group                       // section header
        case file, directory, unknown(String)   // shown read-only by the UI
    }
    public let id: String                // the property key
    public let kind: Kind
    public let label: String             // raw "text" (may be a ui_… localization key or contain HTML)
    public let order: Int                // sort by order, then index, then key
    public let defaultValue: String?     // normalized string ("true"/"false", numbers, "r g b")
    public let condition: String?        // e.g. "bgaudiobars.value==1 || bgaudiobars.value==3"
}
public enum WallpaperProperties {
    public static func parse(project: [String: Any]) -> [WallpaperProperty]
    /// WE's condition syntax: `name.value` references, numbers, quoted strings, true/false,
    /// == != < <= > >=, && || !, parentheses. Unknown names/malformed input → true (show the property).
    public static func isVisible(_ property: WallpaperProperty, values: [String: String]) -> Bool
}
```

Survey of the user's wallpapers (types and counts): color 80, slider 46, bool 36, combo 27, group 5, `Text` 5
(note the capitalised type). Property JSON examples are in the user's folders under
`~/Library/Application Support/MacWallpaper/Workshop/*/project.json` (read-only; never copy their content into
the repository: write your own test JSON). Values in project.json are mixed types (`true`, `0.7`, `"0"`, `"0 0.85 1"`):
normalize like `Sources/WERender/WallpaperRenderer.swift` `webProperties` does.

## 2. Storage (`Sources/WELibrary/PropertyStore.swift`)

Per-wallpaper user values, keyed by the wallpaper's library id (`WallpaperEntry.id`), in one JSON file
(`~/Library/Application Support/MacWallpaper/properties.json`, atomic writes; injectable URL for tests): `values(for:)`,
`set(_:for:key:)`, `reset(for:)` (one key or all), and `overrides(for:properties:)` → only values differing from the
defaults, as `[String: String]` (the format `Wallpaper.open(properties:)` already takes).

## 3. Live updates in renderers

Add to `WallpaperRenderer` (`Sources/WERender/WallpaperRenderer.swift`):

```swift
/// Apply changed user property values (same string format as `Wallpaper.open(properties:)`) without reloading.
/// Returns false if this change can only take effect by reloading (the app then reloads).
func setUserProperties(_ values: [String: String]) -> Bool
```

- **Scenes** (`SceneRenderer`): today `UserProperties.resolve` is applied once while parsing
  (`Sources/WERender/Scene.swift`, particles, text, sounds). Record every user-bound value at parse time (object id +
  property path + binding: name and optional `condition` for `{"user": {"name": …, "condition": …}}`) and re-apply them
  on change through the same live-state paths scripts use (`Sources/WERender/SceneScripting.swift`: `setValue` for
  `visible`, `alpha`, `color`, `origin`, `scale`, `angles`, `text`, effect `visible` and constants, `volume`,
  `instanceoverride.*`), plus scene-level values that are cheap to change (clear colour, bloom on/off/strength).
  Effects whose `visible` is user-bound must be kept at load like script-controlled ones (`hiddenEffects`). Script
  properties bound to user properties: call `SceneScriptEngine.userPropertiesChanged`. Values that select shader
  variants (user-bound `combos`), textures or files → return false (reload). Changed layers must refresh their
  uniform templates (`uniformsDirty`) and text layout.
- **Videos** (`VideoRenderer`): no properties apply; return true.
- **Web** (`WEWeb.WebWallpaper.setUserProperties` exists): the app calls it; nothing to add except a helper that
  turns `[String: String]` into the page format (reuse `webProperties`).

## 4. Tests (offline)

Parsing of every kind (incl. `Text`, groups, combos with numeric and string values, sliders with/without step),
ordering, normalization; the condition evaluator (precedence, parentheses, numbers vs strings, unknown names);
PropertyStore round trip and `overrides`. Scene live updates need Metal for rendering but the binding bookkeeping can
be tested on `SceneDescription` with a fixture: add `regression/fixtures/propertiestest` (self-made: a few stock-asset
layers, a text object, an effect, all bound to user properties of each kind) and regression cases rendered with
`--prop` overrides; plus, if feasible, a `wecli render --live-prop name=value` option that renders a frame, applies
the change live, renders again, so the reviewer can compare live vs `--prop` (they must match).

## 5. Done means

`swift build` / `swift test` pass, no new warnings, existing renders unchanged. Changes limited to
`Sources/WELibrary/` (new files + exports), `Sources/WERender/` (Scene parsing bookkeeping, `SceneScripting.swift`,
`WallpaperRenderer.swift`, `VideoRenderer.swift` stub, `SceneRenderer.swift` hooks), `Sources/WEWeb/` (helper only),
`Sources/wecli/main.swift`, `Tests/`, `regression/`. Other Codex jobs work in parallel on `Sources/WESteam/` and new
files in `Sources/WELibrary/` (`AssetsManager`, `SubscriptionSync`): do not touch those. Do not commit, never run
`scripts/regress.sh --update`. Report: files, API, tests, what cannot be applied live, what to check.
