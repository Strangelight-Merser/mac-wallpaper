# Particle systems, part 2: event children, rope trails, overrides from scripts (implementation spec)

Status: implemented and merged (2026-10-23); results in `docs/design.md` §6.29. Background: `docs/specs/particles.md` (part 1, implemented),
`docs/design.md` §6.25–6.28.

## 1. What is missing (from the user's wallpapers)

The compatibility scan still reports, for the user's downloads:

- **Event children**: `eventfollow` (child system follows each parent particle, e.g. shooting-star trails,
  "Birds"), `eventspawn` (child emits once where a parent particle spawns: "Glowing Stars_01", "Spark"), and
  `eventdeath` (emits where a parent particle dies). Today `ParticleSystemDescription` records
  "particle event child … not supported".
- **`ropetrail` renderer** ("Shooting_Star_01"): a ribbon through a particle's recent positions.
- **Instance overrides changed by SceneScripts**: scripts set `instanceoverride.count`, `.rate`, `.alpha`,
  `.colorn` (and possibly `.size`, `.lifetime`, `.speed`) at runtime ("Persona 3 Reload [4K + Day/Night cycle]",
  "Demon Slayer - Shinobu Kocho": `instanceoverride.rate`). Today the script host warns "particle instance
  overrides from scripts are not supported yet" (`Sources/WERender/SceneScripting.swift`, `setValue`).

Wallpaper folders for reference (read-only, copyrighted: never copy their content into the repository):
`~/Library/Application Support/MacWallpaper/Workshop/{3151551777,3385540784,3265802028}` (scene.pkg; extract
with `.build/release/wecli pkg <scene.pkg> <outdir>` into a temp folder to read particle JSON).

## 2. Reference

linux-wallpaperengine (GPLv3, porting allowed with a header note):
`third_party_refs/linux-wallpaperengine/src/WallpaperEngine/Render/Objects/CParticle.{h,cpp}` (event children,
`renderRope`), `Data/Parsers/ObjectParser.cpp`, `Data/Model/Object.h`. Follow WE semantics and this renderer's
conventions where LWE is Linux/OpenGL-specific (see `docs/specs/particles.md` §2).

## 3. Implement (in `Sources/WERender/Particles/`)

- **Event children**: parse `type` `eventfollow` / `eventspawn` / `eventdeath` children (child definition path in
  `"name"` as for static children; `maxcount`, `probability` and per-child overrides as WE uses them). Child
  systems are simulated with the parent: spawn/death events from the parent's simulation step create emissions in
  the child at the parent particle's position (and velocity for follow, as WE does); `eventfollow` children track
  their parent particle while it lives. Keep the simulation deterministic (seeded from parent id / child index /
  event order) and allocation-free per particle (struct-of-arrays as today).
- **`ropetrail`**: render a ribbon per particle through its last N positions (`segments`/length parameters as
  defined by WE; port `renderRope` and the `genericropeparticle` shader path with `GS_ENABLED=0` / CPU-built
  vertices like the sprite path). Respect texture UV along the rope, colour/alpha per point.
- **Runtime overrides**: an API on the live particle state, e.g.
  `func setOverride(_ name: String, _ value: [Float])` for `count`, `rate`, `size`, `lifetime`, `speed`, `alpha`,
  `colorn`/`color`, taking effect from the next simulation step (count changes clamp/grow `maxcount`; children
  inherit as at load). Wire it into `SceneScripting.swift` `setValue` / `value` for paths
  `instanceoverride.<name>` (objects are particle systems found by scene object id; a particle object id maps to
  its top-level system and its children).
- **Compatibility checker** (`Sources/WELibrary/CompatibilityChecker.swift`): stop reporting what now works; bump
  `CompatibilityChecker.version`.

## 4. Tests (offline, no Metal)

Parsing of each child type; event spawn/death/follow counts and positions against hand-computed values with a
seeded RNG; determinism (re-simulating reproduces state); rope vertex building (vertex count per particle, UV
progression, skipping non-finite points); runtime overrides (rate change alters emission count over a second;
count override clamps live particles; alpha/colour reach vertices). Rendering checks need Metal (the reviewer
runs them): extend `regression/fixtures/particletest` or add `regression/fixtures/particletest2` with WE's stock
particle assets only (`samples/wallpaper_engine/assets/particles/**`) and add case lines; the reviewer blesses refs.

## 5. Done means

`swift build` / `swift test` pass, no new warnings; existing renders unchanged except where these features
appear (the reviewer runs `scripts/regress.sh`). Changes limited to `Sources/WERender/Particles/`,
`Sources/WERender/SceneScripting.swift` (instanceoverride paths only), `Sources/WELibrary/CompatibilityChecker.swift`,
`Tests/`, `regression/`. Do not touch texture loading, `VideoRenderer.swift`, `SceneRenderer.coverProjection`,
`Sources/WEFormat`, `Sources/WallpaperApp/`, or docs (other jobs run in parallel). Do not commit. Report: files,
tests, LWE behaviours changed and why, anything skipped (with the note it produces), what to check visually.
