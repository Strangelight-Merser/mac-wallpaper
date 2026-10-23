# Particle systems (implementation spec)

Status: spec for implementation (2026-10-23). Background: `docs/design.md` §6.19–6.23. Particles are the most
common missing feature in real wallpapers: 10 of the user's 13 downloaded scene wallpapers use them.

## 1. Scope

Render Wallpaper Engine particle objects in scenes, matching WE closely enough that wallpapers look right.

Feature set, from a survey of 76 particle systems (the user's workshop downloads + WE's default projects);
implement everything in **bold**, the rest as noted:

| Kind | Names (count of systems using it) |
|---|---|
| Emitters | **sphererandom** (37), **boxrandom** (30) |
| Initializers | **lifetimerandom** (67), **sizerandom** (67), **colorrandom** (54), **velocityrandom** (46), **rotationrandom** (30), **alpharandom** (14), **turbulentvelocityrandom** (14), **angularvelocityrandom** (14) |
| Operators | **alphafade** (61), **movement** (58), **oscillatealpha** (22), **sizechange** (19), **controlpointattract** (18), **oscillateposition** (15), **angularmovement** (15), **turbulence** (10), **alphachange** (1); also port the remaining LWE operators (colorchange, oscillatesize, vortex) since they are small |
| Renderers | **sprite** (54), **spritetrail** (11), ropetrail (1 — implement only if it falls out of the same code; otherwise record a note) |
| Other | **per-object `instanceoverride`** (count, rate, size, lifetime, speed, alpha, colorn/color, controlpoint overrides), **control points** (incl. mouse-linked), **sprite sheets** (15 systems: animated `.tex` frame tables), **starttime / pre-simulation**, **maxcount**, children (14 systems: implement `static` children as extra systems; record a note for event-driven children) |
| Shaders / blending | `genericparticle` only (67), blending additive (41) / translucent (26) |

Out of scope: geometry-shader paths (Metal has none), lighting/fog/refraction combos of genericparticle
(keep them 0), 3D model particles, audio-reactive particle properties unless trivial.

## 2. Reference implementation

linux-wallpaperengine (GPLv3, like this project — porting is allowed; keep a file-header note "ported from
linux-wallpaperengine CParticle.cpp"):

- `third_party_refs/linux-wallpaperengine/src/WallpaperEngine/Render/Objects/CParticle.{h,cpp}` (2,300 lines):
  emitters (`createBoxEmitter`, `createSphereEmitter`), every initializer and operator, control points
  (`flags & 1` = follow the mouse, `flags & 2` = world space), sprite-sheet frame selection, instance
  overrides, `renderSprites` (CPU-built quads, 17 floats per vertex), `renderRope`, uniforms
  (`setupParticleUniforms`, `updateParticleRenderVars`, `updateParticleViewProjection`), parallax
  (`applyParallaxToModelMatrix`).
- `.../Data/Parsers/ObjectParser.cpp` `parseParticle` / `parseParticleChild`, and `.../Data/Model/Object.h`
  for every field name and default. Note: the object's `"particle"` value is either a path **or an inline
  JSON object**.
- Shaders: `samples/wallpaper_engine/assets/shaders/genericparticle.{vert,frag}` + `common_particles.h`.
  Use the `GS_ENABLED == 0` path (quad corners come in through `a_TexCoordVec4.xy`), with combos
  `SPRITESHEET`, `TRAILRENDERER` (spritetrail), `THICKFORMAT` as the reference sets them.

Where LWE is clearly wrong or Linux-specific (OpenGL y-flip, framebuffer origin), follow WE semantics and
this renderer's conventions instead: scene space is y-up with the origin at the bottom-left of the canvas
(see `SceneRenderer.coverProjection`), Metal textures are top-left origin, pointer conventions are in
`SceneRenderer.PointerInput` (y down, 0…1).

## 3. Integration with the existing renderer

Read first: `Sources/WERender/Scene.swift` (`SceneDescription`, objects loop that currently records
"particle object not supported"), `SceneRenderer.swift` (render order, `renderLayer`, `PassPlan`, pipelines,
patches, layer caching, pointer/parallax), `TextureLoader.swift`, `Sources/WEFormat/Tex.swift` (frame tables /
sprite sheets), `Sources/WEShader/ShaderPreprocessor.swift` (combos).

- **Scene model**: keep `layers` (image layers) but add particle objects and a single ordered list of what
  to draw, in `scene.json` object order (WE draws objects in file order; image `dependencies` still apply
  to images). Suggested: `public enum SceneObject { case image(Int), particle(Int) }` +
  `public let particles: [ParticleSystemDescription]` + `public let drawOrder: [SceneObject]`. Keep every
  existing behaviour for images unchanged.
- **Files**: new `Sources/WERender/Particles/` — `ParticleDescription.swift` (parsing, defaults, overrides),
  `ParticleSimulation.swift` (state + emitters/initializers/operators, pure CPU, no Metal — unit-testable),
  `ParticleRenderer.swift` (vertex building, buffers, draw).
- **Coordinates**: particle object `origin`/`angles`/`scale` (with user-property bindings, like images),
  camera parallax with `parallaxDepth` (reuse the image path), `visible`.
- **Time and determinism**: simulation advances with the frame time. Offline `render(time:)` must be
  deterministic for regression: seed each system's RNG from (object id, child index); when asked for a time
  earlier than the current simulation time, reset and re-simulate from 0 in fixed 1/30 s steps; `starttime`
  pre-simulates likewise. Cap single steps at 1/10 s so a paused-then-resumed wallpaper doesn't explode.
- **Live rendering cost**: CPU simulation must stay well under 1 ms per 1,000 live particles on Apple
  Silicon (struct-of-arrays or contiguous `SIMD` arrays; no per-particle allocations or class instances).
  Vertex data goes into per-frame `MTLBuffer`s (triple-buffered ring, grown as needed — not
  `setVertexBytes`, which is limited to 4 KB) with a shared quad index buffer. Particle passes are dynamic
  (never part of the static-layer cache).
- **Pipeline**: the particle vertex layout (position 3, texcoordvec4 4, color 4, texcoordvec4c1 4,
  texcoordc2 2 = 17 floats) must be bound by attribute **name** through
  `program.compiled.vertex.attributes` (as image layers do for `a_Position`/`a_TexCoord`); add a second
  vertex-descriptor path rather than changing the image one. Blending: material `blending` (additive /
  translucent / normal), drawn into the scene target in draw order. Uniforms: everything genericparticle
  reads (`g_ModelViewProjectionMatrix`, orientation vectors, `g_RenderVar0/1` for sprite sheets, texture
  resolution, …) — fill them through the existing `PassPlan` patch mechanism where values change per frame.
- **Mouse**: control points with the mouse flag follow `SceneRenderer.pointer` (convert to scene space,
  through the cover projection).
- **Compatibility checker** (`Sources/WELibrary/CompatibilityChecker.swift`): particles are now supported;
  report only what remains unsupported (event children, rope trails if skipped, unknown
  emitters/initializers/operators/renderers) under the existing `particles` feature with a note naming
  them, and bump `CompatibilityChecker.version` to 2 so stored results are re-checked.
- Unknown emitter/initializer/operator names: skip them and add a renderer warning (they show up in
  `wecli render` warnings and the regression warning comparison).

## 4. Tests (offline, no Metal)

`Tests/WERenderTests/` (new target if needed):
- Parsing: path vs inline particle definitions, defaults when fields are missing, instance overrides
  (count/rate/size/alpha/colorn/lifetime/speed), control points, children.
- Simulation, with a seeded RNG: emission rate over time (e.g. rate 10 → ~10 per second, never above
  maxcount × count override), lifetime expiry, determinism (same seed → identical state; re-simulating to an
  earlier time reproduces the same state), each operator's effect on a single particle against hand-computed
  values (movement with gravity and drag, alphafade in/out windows, sizechange, oscillators, angular
  movement, controlpointattract within/outside its radius, turbulence stays bounded), sphere/box emitter
  distributions (inside bounds, direction flags).
- Sprite-sheet frame selection (sequential and `randomframe`, `sequencemultiplier`).
- Vertex building: 4 vertices per live particle, attribute packing matches §3, skipped non-finite particles.

## 5. Verification the reviewer will do (needs Metal; you can't in the sandbox)

- `wecli render` of WE's default project "Shimmering Particles" and of real workshop scenes; visual check.
- A regression fixture built from WE's stock particle examples (`assets/particles/example*.json`) — the
  reviewer adds the cases and references after checking them visually.
- `wecli bench` CPU cost on a particle-heavy scene.
- `scripts/regress.sh` must stay 131/131 for existing cases (no image-layer changes).

## 6. Done means

`swift build` / `swift test` pass with no new warnings; existing behaviour unchanged; changes limited to
`Sources/WERender/` (+ `Particles/`), `Sources/WEShader/` only if a combo/preprocessing fix is needed,
`Sources/WELibrary/CompatibilityChecker.swift`, `Package.swift`, `Tests/`. Do not commit. Report: files,
what tests cover, which LWE behaviours you changed and why, anything skipped (with the note it produces),
and what to check visually.
