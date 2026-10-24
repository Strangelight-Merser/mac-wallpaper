# Puppet animation (implementation spec)

Status: spec for implementation (2026-10-24). Background: `docs/design.md` §6.33 (survey: puppet animation is the
only missing feature for ~9 of the top 100 trending scenes), §6.25–6.29 (renderer). The reviewer writes all UI;
never touch `Sources/WallpaperApp/`, docs or user-facing text.

## 1. What it is

An image object's model JSON (`models/x.json`, the object's `image`) may name a puppet mesh:

```json
{ "autosize": true, "material": "materials/x.json", "puppet": "models/x_puppet.mdl" }
```

The `.mdl` holds a 2D mesh skinned to a skeleton, and animations of that skeleton. The image is drawn through that
mesh with the bones deforming it (hair swaying, blinking, breathing). Scene objects pick and mix animations:

```json
{ "image": "models/x.json", "animationlayers": [ { "animation": 1, "rate": 1.0, "blend": 1.0, "visible": true } ] }
```

Without `animationlayers` (check what WE does then; the reference plays nothing → rest pose), and a puppet without
skeleton/animations (only an `MDLV` section) is a static mesh that looks like the plain image (already handled:
`CompatibilityChecker.puppetIsAnimated`).

## 2. References (read-only; GPL-2.0 — learn the format, write our own code, don't copy)

- `third_party_refs/wallpaper-scene-renderer/src/`: `WPMdlParser.cpp/.hpp` (MDLV/MDLS/MDLA parsing, mesh and
  shader/material setup: `GenPuppetMesh`, `AddPuppetShaderInfo`, `AddPuppetMatInfo`), `WPPuppet.cpp/.hpp` (bone
  hierarchy, animation sampling, play modes Loop/Mirror/Single, layer blending, final bone matrices),
  `WPSceneParser.cpp` (~lines 540–700: how a puppet image is set up, `BONECOUNT`, the extra puppet pass/effect),
  `WPShaderValueUpdater.cpp` (~line 120: `g_Bones` upload per frame), `wpscene/WPImageObject.cpp` (`animationlayers`).
- `third_party_refs/linux-wallpaperengine/docs/rendering/MDL_FILES.md` (older partial layout).
- WE's own shaders already implement skinning: `samples/wallpaper_engine/assets/shaders/genericimage2.vert` (and
  genericimage3/4, passthroughblend, clippingmaskimage4…): combo `SKINNING`, `BONECOUNT`, `uniform mat4x3
  g_Bones[BONECOUNT]`, `attribute uvec4 a_BlendIndices`, `attribute vec4 a_BlendWeights`, optional `SKINNING_ALPHA`
  with `g_BonesAlpha[BONECOUNT]`. Our shader pipeline (`Sources/WEShader`) must compile these paths (mat4x3 arrays,
  uvec4 attributes); check it does.
- Real files for checking the parser (copyrighted: read them locally, never copy them or their bytes into the repo or
  tests): `<scratchpad>/mdl/*/*.mdl`
  (17 files, all `MDLV0023` + `MDLS0004` + `MDLA0006`, 25 KB–600 KB) and
  `…/scratchpad/dva/x/models/*_puppet.mdl` (MDLV only). Observed: MDLV0023 vertices are 48 bytes here
  (position 3×f32, then bone data, then UV 2×f32) — verify against the reference for every version you see.

## 3. Implement

- **Parsing** (`Sources/WEFormat/` or `Sources/WERender/`, your call; pure, no Metal): `PuppetModel` with vertices
  (position, UV, up to 4 bone indices + weights), triangle indices, bones (rest transform, parent), animations (id,
  name, fps, length, play mode, per-bone frames: position, rotation angles, scale). Handle the MDLV/MDLS/MDLA versions
  in the samples and in the reference; unknown versions → a clear error, and the object falls back to the plain image
  (log once) instead of failing the scene.
- **Animation** (pure, testable): given the layers (`animation`, `rate`, `blend`, `visible`) and scene time, compute
  one matrix per bone: sample each layer's animation (interpolate between frames; play modes), blend layers as the
  reference does, compose with parents, multiply by the inverse bind pose. Deterministic for offline `render(time:)`.
- **Rendering** (`Sources/WERender/`): an image object with an animated puppet draws its first pass (and the effect
  chain, as the reference arranges it) with the puppet mesh instead of the quad: vertex buffer with position, UV,
  `a_BlendIndices` (uint ×4), `a_BlendWeights` (float ×4); combos `SKINNING=1`, `BONECOUNT=<bones>`; `g_Bones` updated
  every frame (dynamic pass, not cached as static). Mesh coordinates are in the object's space (check the reference
  for the transform from mesh units to the object's size/origin; the dva sample's MDLV-only mesh spans about
  ±1920×±1080 for a 3840×2160 image). Keep the existing quad path for everything else.
- **Live properties / scripts**: if SceneScript can control animation layers (check `Sources/WEScript/Runtime.js` and
  WE's SceneScript docs in the references for `getAnimationLayer`/`animationLayers` style APIs), wire the basics
  (play/pause/rate/blend) or leave a clear TODO; don't block on it.
- **Compatibility**: `CompatibilityChecker` stops reporting `.puppetWarp` for puppets the renderer now handles
  (keep reporting versions it can't parse).

## 4. `wecli`

`wecli render` handles puppet scenes (no new flags needed). Add `wecli mdl <file.mdl>`: prints versions, vertex /
triangle / bone counts, animations (id, name, fps, frames, mode) — the reviewer uses it on the real samples.

## 5. Tests (offline, synthetic only)

Build small `.mdl` byte streams in the tests (a few bones, two animations) matching the layouts you implemented:
parsing every section/version you support; bone hierarchy composition; frame interpolation at exact frames and
between; Loop/Mirror/Single; two blended layers; rate; invisible layer; time determinism. Shader: the genericimage2
vertex shader compiles with `SKINNING=1`, `BONECOUNT=4` (skip without Metal). A render test of a synthetic puppet
scene (skip without Metal): a bone rotating moves pixels between t=0 and t=0.5. `scripts/regress.sh` must keep passing.

## 6. Done means

`swift build` / `swift test` pass, no new warnings; regressions unchanged. Changes limited to `Sources/WEFormat/`,
`Sources/WERender/`, `Sources/WEShader/` if needed, `Sources/WELibrary/CompatibilityChecker.swift` (puppet rule only),
`Sources/wecli/main.swift`, `Tests/`. Do not commit; no prose files. Report: files, the format details you
determined (vertex layouts per version, MDLS/MDLA layouts), what the parser says about each real sample, what you
couldn't verify (no Metal in your sandbox: the reviewer renders a real puppet scene).
