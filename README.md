# MacWallpaper

A native macOS live-wallpaper app (Swift + Metal) that renders **Wallpaper Engine** scene wallpapers
directly on the desktop. Status: early but working — see the progress table below.

This project does not ship any Wallpaper Engine content. You need your own copy of Wallpaper Engine's
`assets` folder and the wallpapers you want to use (e.g. from your Steam Workshop folder).

## What works

| Area | Status |
|---|---|
| Desktop app | Menu-bar app, one desktop-level window per screen, pauses on lock / display sleep / fully covered screens, Low Power Mode halves the frame rate |
| Formats | `.tex` textures (LZ4, DXT1/3/5, R8/RG88, embedded PNG/JPEG, 3D LUTs, GIF frame tables) |
| Shaders | WE's GLSL dialect → SPIR-V (glslang) → MSL (SPIRV-Cross), in-process with a disk cache; 97% of the shipped shaders compile |
| Scenes | Image layers, effect chains incl. multi-FBO effects (blur, god rays, motion blur, fluid simulation…), blend modes, HDR + bloom, user properties, hidden/cross-layer composites, static-layer caching |
| Official effect previews | 44 of 45 render (the remaining one needs particles) |
| Video wallpapers | mp4/mov (H.264, HEVC, AV1) and webm (VP9, AV1), hardware-decoded and drawn zero-copy through Metal; VP8 webm through WebKit; looping, cover-fit. Muted for now |
| Web wallpapers | WKWebView with Wallpaper Engine's JavaScript API (`wallpaperPropertyListener`: user/general properties, `setPaused`; audio/media listener registration), pages served same-origin; paused pages use no CPU |
| Not yet | Video audio, audio spectrum for web/scene wallpapers, mouse interaction, particles, text, SceneScript, 3D models, a wallpaper library UI |

The full design, findings and roadmap (in Chinese) are in [docs/design.md](docs/design.md).

## Requirements

- macOS 14+ on Apple Silicon (developed on macOS 15.6)
- Xcode 26.3+ (Swift 6.2)

glslang and SPIRV-Cross are compiled into the app from pinned git submodules (`ThirdParty/`); compiled
shaders are cached in `~/Library/Caches/MacWallpaper/shaders`.

## Build and run

```bash
git submodule update --init --depth 1
./scripts/build.sh
.build/MacWallpaper.app/Contents/MacOS/MacWallpaper --wallpaper <wallpaper folder> --assets <Wallpaper Engine assets folder>
```

The `--wallpaper`/`--assets` paths are remembered; afterwards you can open `.build/MacWallpaper.app`
directly and change them from the menu-bar icon.

## Regression tests

```bash
./scripts/regress.sh --update   # once: render references from your own Wallpaper Engine assets
./scripts/regress.sh            # render all cases, compare pixels + warnings, one PASS/FAIL summary
./scripts/regress.sh 'beach'    # only cases whose name matches the regex
```

Cases are listed in [regression/cases.txt](regression/cases.txt) (4 scenes in several variants, every
official effect preview at two moments, self-generated test videos — `scripts/make_test_videos.sh`,
run automatically when needed; requires ffmpeg — and web wallpapers including our own bridge fixture
in `regression/fixtures/webtest`). References are renders of Wallpaper Engine assets, so they are
not committed; they are stored in `regression/refs/` (or `$REGRESSION_REFS`). Failing cases get an
amplified difference image in `regression/diff/`.

## Command-line tool

`wecli` (in `.build/release/`) is used for development and testing:

```bash
wecli render <wallpaper> --assets <assets> --time 3 --out frame.png   # offline render of one frame
wecli bench  <wallpaper> --assets <assets> --fps 30                   # CPU/GPU cost per frame
wecli scene  <wallpaper> --assets <assets>                            # dump layers, passes, effect FBOs
wecli verify <folder>                                                 # decode every .tex, compare with sibling .png
wecli compare a.png b.png [--diff d.png]                              # exact pixel comparison (exit 0 = equal)
```

## License

GPLv3 — see [LICENSE](LICENSE). Parts of the shader preprocessing and pass logic follow
[linux-wallpaperengine](https://github.com/Almamu/linux-wallpaperengine) (GPLv3); the `.tex`/`.pkg`
layouts follow [RePKG](https://github.com/notscuffed/repkg) (MIT). Bundled as submodules:
[glslang](https://github.com/KhronosGroup/glslang) (BSD-3-Clause and others) and
[SPIRV-Cross](https://github.com/KhronosGroup/SPIRV-Cross) (Apache-2.0). Wallpaper Engine is a product of
Wallpaper Engine Team / Skutta Software GmbH; this project is not affiliated with it.
