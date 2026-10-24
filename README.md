<img src="docs/images/icon.png" width="128" alt="">

# MacWallpaper

**Your Wallpaper Engine wallpapers, on your Mac.** MacWallpaper is a native macOS app (Swift and Metal) that plays
Wallpaper Engine scene, video and web wallpapers on the desktop, using your own copy of Wallpaper Engine and your own
Steam Workshop subscriptions.

[简体中文](README.zh-CN.md)

![Dusk, the wallpaper that comes with MacWallpaper](docs/images/dusk.jpg)

> MacWallpaper is not affiliated with Wallpaper Engine Team or Valve. It ships no Wallpaper Engine content: you need
> to own Wallpaper Engine on Steam.

## Features

- **Plays the wallpapers you already have.** Log in to Steam with a QR code, and MacWallpaper downloads Wallpaper
  Engine's files and your subscriptions from your own account. Already have a Windows PC with Wallpaper Engine?
  Point it at the copied folders instead.
- **Browse the Workshop** inside the app: trending, popular, search, type filters. Subscribing downloads the
  wallpaper (its size is shown first). Previews are fetched small, for slow or metered connections.
- **Scenes** with effects, particles, text and clocks, sound, audio visualisation, scripts (SceneScript), puppet
  animation, lights and volumetric light, user textures and presets. **Videos** (H.264, HEVC, AV1, VP9, VP8) and
  **web wallpapers** with Wallpaper Engine's JavaScript API.
- **Each wallpaper's settings** (colours, sliders, pictures…) change live from the library.
- **Native and light**: a menu-bar app; wallpapers pause when the desktop is covered, the screen is locked or the
  displays sleep, and optionally on battery or in Low Power Mode. Typical scenes use a few milliseconds of GPU time
  per frame.
- **Keeps your library up to date**: updates of subscribed wallpapers are checked and installed safely (the old
  version stays until the new one has fully arrived).
- **Comes with "Dusk"**, a wallpaper of our own (shown above), so there is something to play right away.
- English and Simplified Chinese.

How far along is it? In a survey of the 100 trending scene wallpapers on the Workshop (October 2026), puppet
animation and lights were the features most often missing; both are supported now. 3D models are not supported yet.
Each wallpaper in your library shows whether it runs fully on your Mac.

## Requirements

- A Mac with Apple Silicon, macOS 14 Sonoma or later
- [Wallpaper Engine](https://store.steampowered.com/app/431960/) on your Steam account

## Install

Download `MacWallpaper-<version>.zip` from [Releases](../../releases), unzip it and move **MacWallpaper** to
Applications.

The app isn't notarized by Apple yet, so macOS asks for confirmation the first time: open it, then go to
**System Settings → Privacy & Security** and click **Open Anyway** (on macOS 14 you can also right-click the app and
choose **Open**).

On first launch, a short welcome guides you through logging in to Steam, getting Wallpaper Engine's files and
choosing wallpapers from your subscriptions.

## Privacy

- Your Steam login is kept in the macOS Keychain. MacWallpaper only talks to Steam (login, Workshop, downloads).
- Audio visualisation is off until you turn it on. It needs the Screen & System Audio Recording permission; nothing is
  recorded or saved, only the audio spectrum is used.

## Build from source

Needs Xcode 26.3 or later (Swift 6.2).

```bash
git clone --recurse-submodules https://github.com/OWNER/REPO.git
cd REPO
./scripts/build.sh
open .build/MacWallpaper.app
```

`scripts/build.sh` signs with your Apple Development certificate if you have one (free with an Apple ID in Xcode),
which keeps Keychain access working across rebuilds; otherwise it signs ad-hoc. `swift test` runs the tests.

The command-line tool `wecli` (built alongside) renders wallpapers to images, inspects Wallpaper Engine's file
formats, and talks to Steam: run it without arguments for help. `scripts/regress.sh` compares renders against
reference images; it needs Wallpaper Engine's files and sample wallpapers locally (`samples/`, not in the repository).

How it works, design decisions and findings are written up (in Chinese) in [docs/design.md](docs/design.md).

## License

GPL-3.0. See [LICENSE](LICENSE) and [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md).
