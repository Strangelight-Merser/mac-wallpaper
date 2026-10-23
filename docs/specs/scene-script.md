# SceneScript runtime (implementation spec)

Status: spec for implementation (2026-10-23). Background: `docs/design.md` §6.25 (feature survey of the user's
wallpapers: SceneScript is used by 9 of 16, and nearly every text object — clocks, dates, song titles — gets its
value from a script).

## 1. Goal

A new module `Sources/WEScript` that runs Wallpaper Engine **SceneScript** (JavaScript attached to scene
properties) on **JavaScriptCore** (system framework, no third-party engine). It is pure logic with no Metal and no
renderer dependency: the renderer talks to it through a small host protocol (§4). The reviewer integrates it into
`WERender` afterwards — do **not** modify `Sources/WERender`, `Sources/WallpaperApp` or `Sources/wecli`.

## 2. What scripts look like

A script is attached to one property of one object. In `scene.json` any property value can be
`{"script": "<source>", "scriptproperties": {...}, "value": <static value>}` — for example the object's
`text`, `visible`, `alpha`, `origin`, `scale`, `angles`, `color`, `maxwidth`, `instanceoverride.count`, an effect's
`visible`, or an effect pass constant (`effects[i].passes[j].constantshadervalues.<name>`). Example (a typical clock):

```js
'use strict';
import * as WEMath from 'WEMath';
export var scriptProperties = createScriptProperties()
    .addCheckbox({ name: 'use24hFormat', label: 'ui_editor_properties_use_24h_format', value: true })
    .addText({ name: 'delimiter', label: 'ui_editor_properties_delimiter', value: ':' })
    .finish();
export function init(value) { return value; }
export function update(value) {
    let t = new Date();
    return ("00" + t.getHours()).slice(-2) + scriptProperties.delimiter + ("00" + t.getMinutes()).slice(-2);
}
```

**Real scripts to study** (103 distinct scripts extracted from the user's downloaded wallpapers; read-only,
copyrighted — **never copy them or excerpts into the repository**, write your own test scripts):
`<scratchpad>/text/js/*.js`

Usage tally across those scripts (implement everything listed; stub with a one-time console warning anything
else you meet there):

- Exports: `update` (84), `init` (34), `scriptProperties` (34), `__workshopId` (57, ignore), `applyUserProperties`
  (8), `cursorDown/Up/Click/Enter/Leave/Move`, `mediaPlaybackChanged`, `mediaPropertiesChanged`,
  `mediaThumbnailChanged`, `mediaTimelineChanged`.
- Imports: `import * as WEMath from 'WEMath'`, `import * as WEColor from 'WEColor'` (also accept
  `import { a, b } from '...'` and `'WEVector'`).
- `engine`: `frametime`, `runtime`, `timeOfDay` (0…1 fraction of the local day), `canvasSize` (Vec2),
  `userProperties` (current user property values by name), `setTimeout`/`setInterval`/`clearTimeout`/
  `clearInterval` (driven by script time, not wall-clock timers), `registerAudioBuffers(resolution)` +
  `AUDIO_RESOLUTION_16/32/64` (returns an object with `left`, `right`, `average` arrays the host fills each frame),
  `registerAsset` (stub, returns null), `isDesktopDevice()/isWallpaper()/isScreensaver()/isRunningInEditor()`
  (true/true/false/false), `screenResolution`.
- `thisLayer` (the object owning the script): property get/set for `visible`, `origin`, `scale`, `angles`,
  `alpha`, `color`, `size`, `text`, `pointsize`, `horizontalalign`, `verticalalign`, plus `name`, `id`,
  `getParent()`, `getTransformMatrix()`, `getAnimation()`/`getTextureAnimation()` (object with
  `play/pause/stop/isPlaying/getFrame/setFrame/frameCount/rate` delegating to the host), `getEffect(name|index)`
  (object with `visible`), `getMaterial()`/`thisObject.getMaterial()` (pass constants by name).
- `thisObject`: the object the property belongs to (the layer, or for effect-pass constants the effect) —
  check the usages to get this right.
- `thisScene`: `getLayer(name)` (any layer by name; null if missing), `getLayerIndex`, `getLayerCount`,
  `sortLayer`, `createLayer`/`destroyLayer` (unsupported: return null / no-op with a one-time warning),
  `clearColor`, `bloom*` reads.
- `shared`: one plain object shared by every script in the scene (scripts communicate through it).
- `input.cursorWorldPosition` (Vec3, scene coordinates), cursor events receive
  `{ worldPosition: Vec3 }`.
- `localStorage`: `get/set/delete/clear`, `LOCATION_GLOBAL`/`LOCATION_SCREEN` second argument; persisted as one
  JSON file per wallpaper when the host gives a URL, in memory otherwise.
- `console.log/warn/error` → host log callback.
- `WEMath`: `mix`, `smoothStep`, `clamp`, `deg2rad`, `rad2deg`, `PI`, … ; `WEColor`: `hsv2rgb`, `rgb2hsv`,
  `normalizeColor`, `expandColor`, `hsv`… ; `Vec2`, `Vec3`, `Vec4` classes (global and via `WEVector`) with
  arithmetic, `length`, `normalize`, `dot`, `cross`, `copy`, `mix`, `toString`, component access `x/y/z/w` and
  `r/g/b/a`. Reference for exact names and semantics: linux-wallpaperengine
  `third_party_refs/linux-wallpaperengine/src/WallpaperEngine/Scripting/` (`Modules/MathModule.cpp`,
  `Modules/ColorModule.cpp`, `Adapters/VectorAdapter.cpp`, `EngineObject.cpp`, `SceneObject.cpp`,
  `ScriptPropertiesObject.cpp`, `ScriptEngine.cpp`, `resources/builtins.js`). It is GPLv3 like this project;
  porting is allowed (keep a "ported from linux-wallpaperengine" header note where you do).
- `createScriptProperties()` builder: `addCheckbox`, `addSlider`, `addCombo`, `addText`, `addTextInput`,
  `addColor`, `addFile`, `addDirectory`, `finish()`. Each `value` is the default; the object's
  `scriptproperties` override it, and an override may itself be user-bound:
  `{"user": "show12h1", "value": false}` → the current user property value (resolved by the host-supplied
  values, re-resolved and `applyUserProperties` called when they change).
- `MediaPlaybackEvent` constants (`PLAYBACK_STOPPED/PLAYING/PAUSED`).

## 3. Semantics

- **Module syntax**: scripts are ES modules. Use JavaScriptCore's module support only if you can get at the
  exports reliably on macOS 14; otherwise a careful source transform (strip `export` from declarations, record
  exported names, turn `import` lines into bindings to built-in module objects) wrapped in a per-script function
  scope. Either way each script has its own top-level scope; all scripts of a scene share one `JSContext`
  (so `shared` works) and globals.
- **Lifecycle**: on load, evaluate the script, then call `init(value)` if exported (its return value, when not
  `undefined`, replaces the property value). Each frame: advance timers, then call `update(value)` with the
  current value; a non-`undefined` return becomes the new value. Values cross the boundary as `ScriptValue`
  (§4): bool, number, string, Vec2/Vec3/Vec4 (JS class instances ↔ SIMD), `null`.
- **Errors**: a script that throws while loading is disabled (property keeps its static value); a script that
  throws in `update` is disabled after the first error. Every error goes to the log callback once with the object
  name and property path. Never crash, never stop other scripts.
- **Time**: the host passes frame time, runtime (seconds since start) and the wall-clock `Date` for the frame.
  When the host asks for a fixed clock (offline regression renders), `new Date()` / `Date.now()` inside scripts
  must return that fixed time (override the global `Date` constructor accordingly); otherwise real time.
  `engine.timeOfDay` follows the same clock.
- **Performance**: one update of 100 small scripts must stay well under 1 ms on Apple Silicon. Avoid per-call
  allocations of bridging objects where possible (cache `JSValue`s for `thisLayer` proxies, `Vec3` class, etc.).
- **Threading**: the engine is used from one thread (the render thread); it need not be thread-safe, but must not
  require the main thread.

## 4. API sketch (adapt names if you have good reasons, and say so in the report)

```swift
public enum ScriptValue: Equatable, Sendable { case null, bool(Bool), number(Double), string(String),
    vec2(SIMD2<Double>), vec3(SIMD3<Double>), vec4(SIMD4<Double>) }

/// Implemented by the renderer. Object ids are scene.json object ids.
public protocol SceneScriptHost: AnyObject {
    func objectID(named name: String) -> Int?
    func objectName(_ id: Int) -> String?
    func parentID(of id: Int) -> Int?
    func value(object: Int, property: String) -> ScriptValue?        // "origin", "visible", "text", …
    func setValue(_ value: ScriptValue, object: Int, property: String)
    func transformMatrix(object: Int) -> simd_double4x4
    func animation(object: Int) -> ScriptAnimationHost?             // nil if the object has none
    func log(_ level: ScriptLogLevel, _ message: String)
}

public final class SceneScriptEngine {
    public init(host: SceneScriptHost, userProperties: [String: Any], canvasSize: SIMD2<Double>,
                storageURL: URL?, fixedClock: Date? = nil)
    /// One property script. `path` is e.g. "text", "visible", "effects[1].visible",
    /// "effects[0].passes[0].constantshadervalues.alpha". Returns the property's value after init.
    @discardableResult
    public func addScript(object: Int, path: String, source: String, scriptProperties: [String: Any],
                          initialValue: ScriptValue) -> ScriptValue
    /// Runs timers and every update(); results go to host.setValue(_:object:property: path).
    public func update(frameTime: Double, runtime: Double, date: Date, cursorWorld: SIMD3<Double>,
                       audio: (left: [Float], right: [Float])?)
    public func userPropertiesChanged(_ values: [String: Any])
    public func cursorEvent(_ kind: CursorEvent, object: Int?, world: SIMD3<Double>)  // down/up/click/move/enter/leave
    public func mediaPropertiesChanged(title: String, artist: String, albumTitle: String, …)
    public func mediaPlaybackChanged(state: Int)
}
```

Also a parsing helper the renderer can use: given a `scene.json` object dictionary, list every scripted property
(`path`, source, scriptproperties, static value), recursing into `effects[i]`, `effects[i].passes[j].
constantshadervalues`, `instanceoverride` and nested dictionaries.

## 5. Tests (offline; JavaScriptCore works in your sandbox)

`Tests/WEScriptTests/` with your own small scripts and a fake host: module transform (export forms, both import
forms, `'use strict'`, comments/strings containing the word `export`), init/update return handling, user-bound
`scriptproperties` and `applyUserProperties`, `shared` across scripts, `thisScene.getLayer(...).visible = false`
reaching the host, Vec2/3/4 arithmetic and bridging, WEMath/WEColor values against hand-computed numbers,
timers firing in script time, fixed clock (`new Date()` and `Date.now()`), `timeOfDay`, localStorage
persistence round trip, errors (throw at load / in update → disabled, logged once, others keep running),
performance smoke test (100 scripts × 100 updates, generous bound). Also run every real script from the folder
above through load + init + 3 updates with a fake host in a **non-committed** local check, and report how many
load and run without errors (list failures with the reason).

## 6. Done means

`swift build` / `swift test` pass with no new warnings; changes limited to `Sources/WEScript/`,
`Tests/WEScriptTests/`, `Package.swift`. Do not commit. Report: files, public API, test coverage, results of the
real-script check, deviations from this spec, and anything stubbed.
