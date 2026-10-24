# Lights, volumetric light and shape layers (implementation spec)

Status: spec for implementation (2026-10-24). Background: `docs/design.md` §6.33 (survey: lights are the only missing
feature for 2 of the top 100 trending scenes), §6.25–6.34 (renderer). The reviewer writes all UI; never touch
`Sources/WallpaperApp/`, docs or user-facing text. Another job is changing puppet animation layers and SceneScript at
the same time: stay out of `Sources/WEScript/`, `Sources/WEFormat/Puppet*.swift` and the puppet code paths.

## 1. What scenes contain

Light objects (scene.json `objects[]`), e.g.:

```json
{ "id": 209, "light": "lpoint", "origin": "1418.4 1723.1 260.0", "color": "1 1 1", "intensity": 0.72, "radius": 500.0,
  "exponent": 2.07, "castshadow": false, "castvolumetrics": true, "density": 1.21, "volumetricsexponent": 1.0,
  "cascadedistance0": 1100.0, "parallaxDepth": "0 0", "solid": true }
```

`light` kinds: `lpoint`, `lspot`, `ltube`, `ldirectional` (check WE's shaders for the fields each needs: spot cone
angles/direction from `angles`, tube end points, …). Scene `general` has `ambientcolor`, `skylightcolor` and
`lightconfig` (e.g. `{"point": 10}` → the `LIGHTS_POINT` combo count for lit shaders; also `spot`, `tube`,
`directional`).

Shape layers: objects with `"shape": "quad"` (no `image`), e.g. "Лучи света — линии" with the `lightshafts` effect
(`DIRECTDRAW: 1`), origin/scale, `visible` bound to a user property. Today we skip them; WE draws them (a beam of light
in the sample's preview).

## 2. Implement (`Sources/WERender/`, `Sources/WELibrary/CompatibilityChecker.swift` for the light rule)

1. **Light objects**: parse them (with parents, user-property bindings and script-driven origin/color/intensity the
   way other objects' fields are resolved) into a per-frame light list in scene space. No warning "light object not
   supported" any more.
2. **Lit materials**: fill the uniforms WE's shaders declare, in the spaces their code expects (read the math in
   `samples/wallpaper_engine/assets/shaders/` — `common*.h`, `genericimage2/3/4`, `generic2/3/4`, particles,
   `common_fog.h`):
   - legacy: `g_LightsPosition[4]`, `g_LightsColorRadius[4]`, `g_LightsColorPremultiplied[3]`, `g_LightAmbientColor`,
     `g_LightSkylightColor` (nearest/strongest lights first when there are more than 4);
   - typed: `g_LPoint_Origin/Color[LIGHTS_POINT]`, `g_LSpot_*`, `g_LTube_*`, `g_LDirectional_*`, with the `LIGHTS_*`
     combos from `lightconfig` (or the actual counts, whichever WE uses — check).
   Materials only light up with their `LIGHTING` combo; normal maps (`NORMALMAP`) and PBR masks as the shaders define.
3. **Volumetric light**: WE ships the pipeline: `samples/wallpaper_engine/assets/materials/util/volumetrics_*.json`
   (fullscreen, front, back, blur_h, blur_v, combine) and `shaders/volumetrics{front,back}.{vert,frag}`,
   `common_fog.h`. Work out from those files how lights with `castvolumetrics` (density, exponent,
   volumetricsexponent, radius, intensity, color) are rendered and composited, and implement it as a scene post
   pass. If parts can't be determined from the assets, implement the plausible version, keep it behind one switch
   in code, and say exactly what you guessed.
4. **Shape layers**: render `"shape": "quad"` objects as effect layers: a quad with the object's transform and size
   (check what size WE uses when there's none: probably the canvas, or `size`), running its effects (`DIRECTDRAW`
   means the effect draws straight onto the scene rather than onto an image; read the `lightshafts` shader/effect in
   the samples and WE's assets `effects/lightshafts/`). Other shape values: log once and skip.
5. **Compatibility**: `CompatibilityChecker` stops reporting `.light` for scenes the renderer now handles.

## 3. Samples (copyrighted: read locally, never copy into the repo)

- `<scratchpad>/youth/`
  ("Youth": 10 point lights with volumetrics + the light-shafts shape layer; unpacked in `x/`; WE's preview is
  `preview.gif`, a beam of light from the top).
- `…/scratchpad/silver/` ("Silver deadlock": 2 point lights with volumetrics, particles; unpacked in `x/`).
- Render with `wecli render <dir> --assets samples/wallpaper_engine/assets` (the project dir, not `x/`).
- No sample has a `LIGHTING` material; test lit materials with a synthetic scene.

## 4. Tests (offline, synthetic)

Light parsing (all kinds, defaults, bindings), uniform packing for both systems (ordering, >4 lights, combos), a lit
synthetic image brighter near a point light than far from it (skip without Metal), volumetrics on/off changes pixels
around a light (skip without Metal), shape-layer quad placement, and `scripts/regress.sh` unchanged for existing cases.

## 5. Done means

`swift build` / `swift test` pass, no new warnings; regressions unchanged. Do not commit; no prose files. Report: files,
how volumetrics work (what you derived vs guessed), the light-space conventions, what you couldn't verify (no Metal in
your sandbox: the reviewer renders the samples).
