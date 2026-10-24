# Third-party notices

MacWallpaper is licensed under the GNU General Public License v3.0 (see [LICENSE](LICENSE)). It includes, links
against or learned from the following work. Thank you to everyone who made it.

## Included in the app

| Component | Used for | License |
|---|---|---|
| [glslang](https://github.com/KhronosGroup/glslang) 16.6.0 (`ThirdParty/glslang`) | Compiling Wallpaper Engine's GLSL to SPIR-V | BSD-3-Clause, MIT, Apache-2.0 and others; see its `LICENSE.txt` |
| [SPIRV-Cross](https://github.com/KhronosGroup/SPIRV-Cross) (`ThirdParty/SPIRV-Cross`) | Translating SPIR-V to Metal Shading Language | Apache-2.0; see its `LICENSE` |
| [Zstandard](https://github.com/facebook/zstd) 1.5.7 decoder (`ThirdParty/zstd`) | Decompressing Steam content chunks | BSD-3-Clause (dual-licensed with GPL-2.0); see `ThirdParty/zstd/LICENSE` |
| liblzma (XZ Utils) and zlib | Decompressing Steam content chunks; linked from macOS | 0BSD / public domain; zlib License |

## Code ported or adapted

| Project | What | License |
|---|---|---|
| [linux-wallpaperengine](https://github.com/Almamu/linux-wallpaperengine) | Parts of the shader preprocessing, particle system, audio spectrum and SceneScript behaviour follow its implementation (credited where it applies in the source) | GPL-3.0 |
| [RePKG](https://github.com/notscuffed/repkg) | Layout of Wallpaper Engine's `.pkg` and `.tex` files | MIT |

## References for file and network formats (no code copied)

| Project | What we learned | License |
|---|---|---|
| [node-steam-user](https://github.com/DoctorMcKay/node-steam-user) and [@doctormckay/steam-crypto](https://github.com/DoctorMcKay/node-steam-crypto) | Steam's login, CM protocol, protobuf field numbers, content chunk encryption and compression | MIT |
| [adm-zip](https://github.com/cthackers/adm-zip) | ZIP layout used by some Steam chunks | MIT |
| [wallpaper-scene-renderer](https://github.com/catsout/wallpaper-scene-renderer) | The puppet mesh format (`.mdl`) and how its animations are played | GPL-2.0 |

## Not included

MacWallpaper ships no Wallpaper Engine content. Wallpaper Engine's shaders, materials and other assets, and every
wallpaper, come from the user's own copy of Wallpaper Engine and their own Steam Workshop subscriptions. Wallpaper
Engine is a product of Wallpaper Engine Team; MacWallpaper is not affiliated with or endorsed by them or by Valve.
