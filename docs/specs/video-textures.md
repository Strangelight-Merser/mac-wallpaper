# Video textures in scenes (implementation spec)

Status: implemented and merged (2026-10-23); results in `docs/design.md` §6.29. Background: `docs/design.md` §6.25–6.28.

## 1. Problem

WE scene textures can be videos: a `.tex` whose payload is an MP4 file. The user's "Persona 3 reload 音乐播放器"
(`~/Library/Application Support/MacWallpaper/Workshop/3146703458`, read-only, copyrighted: never copy it or its
contents into the repository) has a 3840×2160 background `materials/Persona 3 Reload.tex` (60 MB) that is an MP4.
Today the scene shows noise there.

Two bugs:
1. **Parsing** (`Sources/WEFormat/Tex.swift`): that file is `TEXV0005`/`TEXI0001`, flags = 34 (`isVideo` = 32
   set), container `TEXB0003` with `freeImage = -1`. `Tex.isVideo(data:)` already returns true (it checks the flag
   first), but `Tex.init(bytes:)` maps `freeImage == -1` to `.raw(format)` and shows the MP4 bytes as RGBA pixels.
   When `flags.contains(.isVideo)` (or the TEXB0004 mp4 flag), the payload must be `.mp4`, for every container
   version. Check the mipmap record layout for this case against the file (the MP4 starts right after the
   mipmap header, `ftyp` at offset 0x5b in this file) and against linux-wallpaperengine
   (`third_party_refs/linux-wallpaperengine`, search "mp4"/"Video" in its texture code) and RePKG
   (`third_party_refs/repkg`).
2. **Rendering** (`Sources/WERender/TextureLoader.swift` throws "video textures" for `.mp4`).

## 2. Implement

- **Decode** with the existing `WEVideo.VideoSource` (AVAssetReader for MP4, VideoToolbox; BGRA `CVPixelBuffer`s).
  It needs a file URL: write the MP4 payload once to the cache, e.g.
  `~/Library/Caches/MacWallpaper/video-textures/<sha1 of payload prefix+size>.mp4` (atomic write; reuse if present).
  Never keep a second full copy of the payload in memory longer than needed.
- **Texture**: import frames zero-copy through a `CVMetalTextureCache` as `VideoRenderer` does. A video texture is
  a `LoadedTexture` that changes every frame: add a per-frame update in `SceneRenderer.encodeFrame` (before layers
  render) that, for each video texture in use, asks its `VideoSource` for `frame(at: time)` (looping) and replaces
  the entry. Passes that sample a video texture must look it up at draw time (like `$text:` textures, see
  `PassPlan.Input.named` in `SceneRenderer.plan`) and are dynamic (no static-layer cache).
- **Sizes**: `textureSize`/`imageSize` = the video's pixel size (or the `.tex` image size if WE pads; check), so
  `g_Texture0Resolution` and UV scaling match image textures. Format code 0 (RGBA8888): BGRA frames read as
  `.bgra8Unorm` give correct RGBA in shaders.
- **Time**: scene time drives the video (loops at its duration); offline `render(time:)` must be deterministic
  (the frame at `time`).
- **Memory/CPU**: one decoder per distinct video texture, shared by every pass that uses it; release with the
  renderer.
- **Compatibility checker** (`Sources/WELibrary/CompatibilityChecker.swift`): video textures are now supported;
  stop reporting `.videoTexture` when the MP4 decodes (keep it for videos AVFoundation cannot open, with a note).
  Bump `CompatibilityChecker.version`.

## 3. Tests

- `Tests/` (offline): Tex parsing of a hand-built `.tex` wrapping a tiny MP4 (generate the MP4 in the test with
  AVAssetWriter, a few 16×16 frames of solid colours) in both `TEXB0003`+isVideo-flag and `TEXB0004` mp4 layouts →
  `.mp4` payload with the exact MP4 bytes; `isVideo` agrees.
- Rendering (needs Metal; skipped in your sandbox, the reviewer runs it): a regression fixture
  `regression/fixtures/videotexturetest` (project.json, scene.json, a model + material + a small generated `.tex`
  video, all self-made, no WE or workshop content) with frames of different colours, so `wecli render --time 0`
  and `--time 1` differ. Add the case lines to `regression/cases.txt`; the reviewer blesses references.

## 4. Done means

`swift build` / `swift test` pass with no new warnings; changes limited to `Sources/WEFormat/Tex.swift`,
`Sources/WERender/` (texture loading, a new file for video textures, minimal `SceneRenderer` hooks),
`Sources/WEVideo/` if needed, `Sources/WELibrary/CompatibilityChecker.swift`, `Tests/`, `regression/`. Do not touch
`Sources/WERender/Particles/`, `Sources/WERender/VideoRenderer.swift`, `SceneRenderer.coverProjection` (other jobs
work there in parallel), `Sources/WallpaperApp/`, or docs. Do not commit. Report: files, what tests cover, what the
reviewer should verify visually.
