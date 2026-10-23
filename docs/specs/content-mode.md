# Fit / fill / stretch for wallpapers (renderer part; implementation spec)

Status: implemented and merged (2026-10-23); results in `docs/design.md` §6.29. Background: `docs/design.md` §6.28 ("你的名字" is cropped on the
user's 1440×932 screen because a 16:9 video is cover-fitted).

## 1. Goal

Each wallpaper can be shown three ways on a screen whose aspect differs from the content's:

- **fill** (today's behaviour, default): scale to cover the screen, crop the overflow, centred.
- **fit**: scale to fit inside the screen, centred, the rest filled with a bar colour (default black).
- **stretch**: fill the screen exactly, ignoring aspect.

The app (written by the reviewer, not you) will store the choice per wallpaper and set it on the renderer; you
provide the renderer API and behaviour.

## 2. API

In `Sources/WERender/WallpaperRenderer.swift`:

```swift
public enum ContentMode: String, CaseIterable, Sendable { case fill, fit, stretch }
public protocol WallpaperRenderer: AnyObject {
    ...
    /// How content of another aspect maps onto the output (default .fill). Takes effect on the next frame.
    var contentMode: ContentMode { get set }
    /// Bars around `.fit` content.
    var barColor: SIMD3<Float> { get set }
}
```

Implement for `VideoRenderer` (UV window in its fragment path; for fit, draw the frame into the centred rect and
clear the rest to `barColor`) and `SceneRenderer` (`coverProjection` becomes a projection that honours the mode:
fit = the whole canvas visible with bars, stretch = canvas mapped to the full output). In scenes everything that
depends on the projection must stay consistent: pointer → scene mapping (particles' mouse control points,
SceneScript `input.cursorWorldPosition` and cursor hit testing in `Sources/WERender/SceneScripting.swift`,
`g_PointerPosition` semantics: keep it relative to the output as today), parallax, bloom/full-frame copies
(`_rt_FullFrameBuffer` is the output-sized target; bars are just cleared output). In fit mode the bars must be
`barColor`, not the scene's clear colour. Web wallpapers (`WEWeb`) are out of scope (CSS decides).

`wecli render` gets `--mode fill|fit|stretch` (and `wecli bench` if trivial).

## 3. Tests

- Offline (no Metal): the projection math as a pure function (`contentProjection(canvas:output:mode:)` or
  similar): for 16:9 content on 16:10 and 21:9 outputs, which canvas rectangle is visible / where bars are, and
  pointer mapping round trips (output point → scene point → output point).
- Regression cases (reviewer blesses): add to `regression/cases.txt` a scene and a video case each in `fit` and
  `stretch` at a non-16:9 size (e.g. 1440x932), using existing samples/fixtures that are already in the case list.

## 4. Done means

`swift build` / `swift test` pass, no new warnings; existing renders in fill mode unchanged (the reviewer runs
`scripts/regress.sh`). Changes limited to `Sources/WERender/WallpaperRenderer.swift`,
`Sources/WERender/VideoRenderer.swift`, the projection/pointer code in `SceneRenderer.swift` and
`SceneScripting.swift`, `Sources/wecli/main.swift`, `Tests/`, `regression/cases.txt`. Do not touch
`Sources/WERender/Particles/` beyond the pointer mapping call site if unavoidable, texture loading, `Sources/WEFormat`,
`Sources/WallpaperApp/`, or docs (other jobs run in parallel). Do not commit. Report: files, API, tests, what to check.
