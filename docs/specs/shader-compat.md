# Shader compatibility fixes for real workshop wallpapers (implementation spec)

Status: implemented and merged (2026-10-23); results in `docs/design.md` §6.25. Background: `docs/design.md` §4.2, §6.13 (in-process
glslang + SPIRV-Cross), the existing compatibility rewrites in `Sources/WEShader/ShaderCompat.swift`.

## 1. Problem

Wallpaper Engine shaders are written for HLSL-like leniency; our pipeline preprocesses them into GLSL for
glslang (`Sources/WEShader/ShaderPreprocessor.swift`), then SPIRV-Cross → MSL. The compatibility checker
found these failures in the user's real wallpapers (one pass each; the rest of each wallpaper renders):

| # | Wallpaper (folder) | Layer | glslang error |
|---|---|---|---|
| 1 | Zero Two (`2005884365`), Dino Run (WE default project `dino_run`) | blur/postprocess | link error: `vec2 v_TexCoord[7]` in the vertex stage vs `[13]` in the fragment stage |
| 2 | Persona 3 Reload day/night (`3151551777`) | Full Composition Layer | `s.frag:432: '*' : no operation ... ' temp bool' and ' const float'` |
| 3 | Demon Slayer – Shinobu Kocho (`3265802028`) | Audio Visualizer | `s.vert:120: '=' : global const initializers must be constant` |
| 4 | nina (`3310370498`) | Green | `s.frag:552: '%' : no operation ... ' temp highp float' and ' const int'` |
| 5 | Alone. and Sad. (`3385540784`) | post-processing layer | `s.frag:555: 'mix' : no matching overloaded function found` |

Wallpaper folders (read-only, **do not copy any of their content into the repository**):
- workshop items: `~/Library/Application Support/MacWallpaper/Workshop/<id>/` (shaders are inside
  `scene.pkg`; `wecli pkg <scene.pkg> <outdir>` extracts it — extract into `$TMPDIR`, not the repo)
- WE default projects and the WE assets folder (stock shaders, materials, effects):
  `<repo>/samples/wallpaper_engine/projects/defaultprojects/` and
  `<repo>/samples/wallpaper_engine/assets/`

## 2. What to do

1. **Reproduce each failure without Metal.** The glslang/SPIRV-Cross stage runs on the CPU
   (`ShaderCompiler.compile(vertex:fragment:)`). Work out the exact combos each failing pass is compiled with
   (material `combos`, effect pass combos, shader `[COMBO]` defaults, `TEX<n>FORMAT`, sampler-linked combos —
   see how `SceneRenderer.plan` / `effectiveCombos` builds them, without changing those files) and reproduce
   the error from `ShaderPreprocessor.process` + `ShaderCompiler.compile`. A small compile-only helper in
   `Sources/WEShader` or a `wecli shaders <wallpaper> --assets <dir>` command (compile every pass of every
   image layer, print failures; no Metal needed — add it only if it doesn't require editing
   `Sources/WERender/SceneRenderer.swift` or `Scene.swift`, which another change is rewriting right now) is
   welcome.
2. **Fix the root cause of each**, generally:
   - #1 is likely a combo that differs between stages (e.g. a kernel-size combo with different defaults in
     the .vert and .frag, or a combo defined in only one stage): the two stages of a pass must be compiled
     with one shared combo set, as WE does. Find the real cause before changing anything.
   - #2, #3, #4, #5 are HLSL leniencies: implicit bool→float conversion in arithmetic, non-constant global
     `const` initializers (make them non-const globals or move into `main`), `%` on floats (→ `mod`/`fmod`
     semantics — HLSL `%` on floats is `fmod`, which differs from GLSL `mod` for negative operands), and a
     `mix` whose arguments need an implicit conversion (find which).
   - Prefer the existing pattern: compatibility rewrites in `ShaderCompat.swift`, applied **only when the
     first compile fails** (see the retry in `SceneRenderer.program` → `fixImplicitTruncation` /
     `reconcileVaryings`), so shaders that already compile are byte-identical and the shader cache and
     regression references stay valid. If a fix must apply to every shader (e.g. the shared combo set for
     #1), it must provably not change the output of any shader that compiles today — check by compiling every
     shader of the WE assets folder and the default projects before/after and comparing the MSL (a small test
     or script; report the counts).
   - Rewrites must be targeted (regex or a light tokenizer over the preprocessed source), never blanket
     textual changes that could alter correct code.
3. If a rewrite needs a hook in `SceneRenderer.program` (it currently calls `fixImplicitTruncation` and
   `reconcileVaryings` on retry), add new rewrites inside those existing functions or a new function in
   `ShaderCompat.swift` that the same retry calls — prefer changing only `Sources/WEShader/`. If you
   absolutely must touch `SceneRenderer.swift`, keep it to that single retry call and say so in the report.

## 3. Tests

`Tests/WEShaderTests/` (new test target if needed), offline, **with synthetic shader snippets written by the
tests** that reproduce each error class (not copies of the wallpapers' shaders): each case fails to compile
before the rewrite and compiles after it; plus checks that the rewrites leave already-valid code unchanged
(e.g. `%` on ints, `const` with literal initializers, bool used in conditions, `mix` with matching types).

## 4. Done means

- All 5 failures compile (report each pass: before/after), and the compile-everything comparison shows no
  output change for shaders that compiled before.
- `swift build` / `swift test` pass with no new warnings. `scripts/regress.sh` needs a Metal device; if your
  sandbox has none, say so (the reviewer runs it).
- Changes limited to `Sources/WEShader/`, `Sources/wecli/main.swift` (optional command), `Package.swift`
  (test target), `Tests/`. Do not commit. Report: root cause of each failure, the fix, test coverage, and
  anything the reviewer should look at in the rendered wallpapers.
