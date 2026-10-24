# User textures in scenes (implementation spec)

Status: spec for implementation (2026-10-24). Background: `docs/design.md` §6.25–6.29 (renderer, live properties,
video textures). The reviewer writes all UI and the library/preset side; you write the renderer part. Never touch
`Sources/WallpaperApp/`, `Sources/WELibrary/`, docs or user-facing text.

## 1. Problem

Scene wallpapers let users replace a texture with their own picture through a `scenetexture` user property
(`project.json` → `general.properties.<name>.type == "scenetexture"`, value: a file path, empty by default).
Materials name the property in a `usertextures` array parallel to `textures`:

```json
{ "passes": [ { "shader": "genericimage3", "textures": ["Nightlife Vid"], "usertextures": ["customimageleft"] } ] }
```

When the property has a non-empty value, texture slot 0 shows that file instead of `materials/Nightlife Vid.tex`;
when it is empty, the original texture stays. Presets (workshop items that change another wallpaper's settings)
use this heavily: the test case sets three such properties to `files/*.png` and an animated `files/*.gif`.

Today `usertextures` is ignored. References (read-only): `third_party_refs/linux-wallpaperengine`
(`Data/Parsers/ObjectParser.cpp` around `usertextures`, `TextureParser::parseTextureMap`, `Render/Objects/Effects/CPass.cpp`
lines ~600–800) for where `usertextures` may appear (material passes, scene.json instance overrides
`effects[k].passes[j].usertextures`, image object `usertextures`?) and the entry forms (string, or an object; null /
empty entries for "no user texture in this slot"; a map keyed by slot index). Support every form they parse.

## 2. Implement (`Sources/WERender/`)

- **Parsing**: `Scene.Pass` gets `userTextures: [Int: String]` (slot → property name) from materials and pass
  overrides, like `textures`. Resolve at load time against `UserProperties`: a non-empty string value replaces
  `textures[slot]` with a marker the loader understands (e.g. a `$file:<absolute path>` name, like the existing
  `$text:` names), so a scene that doesn't use the property is unaffected.
- **Values**: absolute paths (the app passes absolute paths, since presets keep their files in their own folder)
  and paths relative to the project folder (resolve with `AssetLocator`; WE stores `files/x.png` relative to the
  folder that holds the value). `file://` URLs too. Missing or unreadable files: log once and keep the original
  texture; never throw for the whole scene.
- **Still images** (PNG, JPEG, BMP, TIFF, WebP, HEIC: whatever ImageIO decodes): reuse `TextureLoader.decodeImage`'s
  path (straight-alpha RGBA8, `formatCode` 0), `textureSize == imageSize ==` pixel size, mipmaps if the existing
  image path makes them, `clamp` as WE does for user textures (check the reference; default clamp).
- **Animated GIFs** (and APNG if ImageIO reports frames): a texture that changes with scene time, like
  `VideoTexture` (`Sources/WERender/VideoTexture.swift`, per-frame update in `SceneRenderer.encodeFrame`, passes look
  it up at draw time and are dynamic). Decode with `CGImageSource` (frames are composited by ImageIO), frame delays
  from `kCGImagePropertyGIFUnclampedDelayTime`/`DelayTime` with browser rules (delay ≤ 0.01 s counts as 0.1 s), loop
  forever. Decode lazily or upfront with a memory budget (e.g. ≤ 128 MB per GIF; above it, downscale frames); one
  decoder shared by all passes that use the same file. Offline `render(time:)` must be deterministic.
- **Videos** (`.mp4`, `.m4v`, `.mov`, `.webm` if `WEVideo.VideoSource` opens it): reuse `VideoTexture` directly with
  the file URL (no cache copy needed).
- **Live changes**: a user-property change to a `scenetexture` property must take effect. If the live-property
  binding layer (`Sources/WERender/UserBinding.swift`) can swap a texture cheaply, do that; otherwise report that the
  property needs a reload (find how other non-live properties do it) and document what you chose.
- **Plan cache**: whatever key the pass-plan cache uses must change when a slot switches between a user texture and
  the original (see `PassPlan` and its cache key).

## 3. `wecli`

`wecli render` already takes `--prop name=value`; make sure a `scenetexture` value given there works (absolute and
relative paths), so the reviewer can test offline.

## 4. Tests (offline, no network, no copyrighted content)

Synthetic only: build a tiny scene folder in a temp dir (project.json with a `scenetexture` property, a material with
`usertextures`, a small generated `.tex` or reuse an existing test fixture builder), plus generated PNG and a
3-frame GIF (write them with ImageIO in the test). Cover: parsing of every `usertextures` form, empty value keeps
the original texture, PNG replaces it (sample a pixel of an offline render if the test suite has a Metal device;
skip gracefully without one), GIF frame selection by time (pure function test), missing file falls back,
relative vs absolute paths. Keep `scripts/regress.sh` passing (renders must not change for scenes without user
textures).

## 5. Done means

`swift build` / `swift test` pass, no new warnings. Changes limited to `Sources/WERender/`, `Sources/wecli/` if
needed, `Tests/`. Do not commit; no prose files. Report: files, the forms of `usertextures` you found in the
references, what live changes do, memory behaviour for big GIFs, anything you couldn't verify (no Metal in your
sandbox: the reviewer renders the real test case).
