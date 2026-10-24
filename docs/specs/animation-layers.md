# Script control of puppet animation layers (implementation spec)

Status: spec for implementation (2026-10-24). Background: `docs/design.md` §6.34 (puppet animation), the SceneScript
runtime (`Sources/WEScript/`, `docs/specs/scene-script.md`). The reviewer writes all UI; never touch
`Sources/WallpaperApp/`, docs or user-facing text. Another job is adding lights, volumetrics and shape layers at the
same time: stay out of light/volumetric/shape code; keep your `SceneRenderer.swift` changes small and local.

## 1. What's missing

Puppet animation layers come from scene.json (`animationlayers`: `animation`, `rate`, `blend`, `visible`, plus
`additive`, `blendin`, `blendout`, `blendtime`, `id`, `name`) and play on scene time (`PuppetModel.Layer`,
`PuppetAnimation.swift`). Scripts can't touch them, and `additive`/`blendin`/`blendout`/`blendtime` are ignored. The
runtime already has texture animations (`Runtime.js`: `getAnimation()`/`getTextureAnimation()` with play/pause/stop/
isPlaying/getFrame/setFrame/frameCount/rate via `call('animation', …)`).

## 2. API (Wallpaper Engine SceneScript, `ILayer` / `IAnimationLayer`)

On image layers (`thisLayer`, `thisScene.getLayer(…)`):
- `getAnimationLayerCount(): Number`
- `getAnimationLayer(indexOrName): IAnimationLayer | undefined` (index into the layer's animation layers, or by name)
- `createAnimationLayer(animation): IAnimationLayer` (`animation`: the puppet animation's id, name, or an object
  `{ animation, rate, blend, visible, … }`); new layers start playing.
- `destroyAnimationLayer(layerOrIndex): Boolean`

`IAnimationLayer`:
- properties: `name` (read-only), `rate`, `blend`, `visible` (read/write), `frameCount`, `fps`, `duration`
  (read-only, from the animation);
- methods: `play()`, `pause()`, `stop()` (pause and rewind to frame 0), `isPlaying()`, `getFrame()`,
  `setFrame(frame)` (fractional frames allowed).

Where WE's behaviour is unclear (e.g. index base, name lookup when names repeat, what `stop` does to blend), choose
the obvious behaviour, keep it consistent, and list your choices in the report.

## 3. Implement

- **State** (`Sources/WEFormat/PuppetAnimation.swift` or a new runtime type in `Sources/WERender/`): per image layer, a
  mutable list of animation-layer states: animation, rate, blend, visible, playing, current time (advanced by frame
  delta × rate while playing, instead of being derived from absolute scene time), plus `additive` and
  blend-in/out over `blendtime` seconds when a layer starts/stops if `blendin`/`blendout` are set (check how the
  reference treats `additive`: `third_party_refs/wallpaper-scene-renderer/src/WPPuppet.cpp`, GPL-2.0: learn, don't copy).
  Offline `render(time:)` must stay deterministic: with no script changes, state at time t equals today's result.
- **Bridge**: extend the runtime's native call surface (`Sources/WEScript/`, the same pattern as `call('animation', …)`)
  and `Runtime.js` with the API above. Values set by scripts take effect from the next frame.
- **Renderer**: the puppet pass reads bone matrices from that state.

## 4. Tests (offline, synthetic)

A synthetic puppet scene with two animations; scripts that: read the count and a layer's properties; pause (pose stays
fixed over time); setFrame (pose equals that frame); change rate (time advances proportionally); create and destroy a
layer; set blend/visible. Unit tests for blend-in/out and additive on the pure state type. Determinism without
scripts (same matrices as before for the same times). `scripts/regress.sh` unchanged.

## 5. Done means

`swift build` / `swift test` pass, no new warnings; regressions unchanged. Changes limited to `Sources/WEFormat/`,
`Sources/WERender/`, `Sources/WEScript/`, `Tests/`. Do not commit; no prose files. Report: files, the API as
implemented, the behaviour choices, what you couldn't verify (no Metal in your sandbox).
