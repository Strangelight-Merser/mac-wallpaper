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
| Shaders | WE's GLSL dialect → SPIR-V (glslang) → MSL (SPIRV-Cross); 97% of the shipped shaders compile |
| Scenes | Image layers, effect chains incl. multi-FBO effects (blur, god rays, motion blur, fluid simulation…), blend modes, HDR + bloom, user properties, hidden/cross-layer composites, static-layer caching |
| Official effect previews | 44 of 45 render (the remaining one needs particles) |
| Not yet | Video and web wallpapers, particles, text, audio response, SceneScript, 3D models, mouse interaction, a wallpaper library UI |

The full design, findings and roadmap (in Chinese) are in [docs/design.md](docs/design.md).

## Requirements

- macOS 14+ on Apple Silicon (developed on macOS 15.6)
- Xcode 26.3+ (Swift 6.2)
- For now: `glslang` and `spirv-cross` on the PATH (`brew install glslang spirv-cross`); these will be
  linked in-process later

## Build and run

```bash
./scripts/build.sh
.build/MacWallpaper.app/Contents/MacOS/MacWallpaper --wallpaper <wallpaper folder> --assets <Wallpaper Engine assets folder>
```

The `--wallpaper`/`--assets` paths are remembered; afterwards you can open `.build/MacWallpaper.app`
directly and change them from the menu-bar icon.

## Command-line tool

`wecli` (in `.build/release/`) is used for development and testing:

```bash
wecli render <wallpaper> --assets <assets> --time 3 --out frame.png   # offline render of one frame
wecli bench  <wallpaper> --assets <assets> --fps 30                   # CPU/GPU cost per frame
wecli scene  <wallpaper> --assets <assets>                            # dump layers, passes, effect FBOs
wecli verify <folder>                                                 # decode every .tex, compare with sibling .png
```

## License

GPLv3 — see [LICENSE](LICENSE). Parts of the shader preprocessing and pass logic follow
[linux-wallpaperengine](https://github.com/Almamu/linux-wallpaperengine) (GPLv3); the `.tex`/`.pkg`
layouts follow [RePKG](https://github.com/notscuffed/repkg) (MIT). Wallpaper Engine is a product of
Wallpaper Engine Team / Skutta Software GmbH; this project is not affiliated with it.
