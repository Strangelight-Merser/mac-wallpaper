<img src="docs/images/icon.png" width="128" alt="">

# MacWallpaper

**在 Mac 上用你的 Wallpaper Engine 壁纸。** MacWallpaper 是一款原生 macOS 应用（Swift + Metal），用你自己的
Wallpaper Engine 和你在 Steam 创意工坊的订阅，在桌面上播放场景、视频和网页壁纸。

[English](README.md)

![MacWallpaper 随附的壁纸“Dusk”](docs/images/dusk.jpg)

> MacWallpaper 与 Wallpaper Engine 开发团队及 Valve 没有任何关系，也不附带任何 Wallpaper Engine 的内容：你需要在
> Steam 上拥有 Wallpaper Engine。

## 功能

- **直接用你已有的壁纸。** 扫码登录 Steam 后，MacWallpaper 从你自己的账号下载 Wallpaper Engine 的文件和你订阅的
  壁纸。在 Windows 上用过 Wallpaper Engine？也可以直接选择拷过来的文件夹。
- **在应用里浏览创意工坊**：趋势、热门、搜索、按类型筛选。订阅即下载（先显示大小）。预览图只取小图，适合慢速或按流量
  计费的网络。
- **场景壁纸**：特效、粒子、文字和时钟、声音、随音乐律动、脚本（SceneScript）、木偶动画、灯光和体积光、自定义图片和
  预设。**视频壁纸**（H.264、HEVC、AV1、VP9、VP8）和带 Wallpaper Engine JavaScript 接口的**网页壁纸**。
- **每个壁纸的设置**（颜色、滑块、图片……）在壁纸库里改，实时生效。
- **原生、轻量**：菜单栏应用；桌面被遮挡、锁屏或显示器睡眠时自动暂停，也可以在用电池或低电量模式时暂停。常见场景每帧
  只占几毫秒 GPU。
- **自动更新壁纸**：检查并安全地安装已订阅壁纸的更新（新版本完整下载之前，旧版本一直可用）。
- **随附壁纸“Dusk”**（上图），是我们自己做的，装好就能用。
- 支持简体中文和英文。

完成度如何？2026 年 10 月对创意工坊趋势前 100 个场景壁纸做的统计里，最常缺的功能是木偶动画和灯光，现在都已支持；3D
模型暂不支持。壁纸库里每个壁纸都会显示能否在你的 Mac 上完整运行。

## 系统要求

- 搭载 Apple 芯片的 Mac，macOS 14 Sonoma 或更新版本
- Steam 账号里有 [Wallpaper Engine](https://store.steampowered.com/app/431960/)

## 安装

从 [Releases](../../releases) 下载 `MacWallpaper-<版本>.zip`，解压后把 **MacWallpaper** 拖进“应用程序”文件夹。

应用暂时没有经过 Apple 公证，所以第一次打开时 macOS 会要求确认：先打开一次，再到**系统设置 → 隐私与安全性**里点
**仍要打开**（macOS 14 上也可以右键点按应用，选择**打开**）。

第一次启动时，欢迎页会一步步带你登录 Steam、获取 Wallpaper Engine 的文件，并从你的订阅里挑选壁纸。

## 隐私

- Steam 登录信息保存在 macOS 钥匙串里。MacWallpaper 只和 Steam 通信（登录、创意工坊、下载）。
- 随音乐律动默认关闭，打开后才会使用。它需要“录屏与系统录音”权限；不会录制或保存任何内容，只用到音频频谱。

## 从源码构建

需要 Xcode 26.3 或更新版本（Swift 6.2）。

```bash
git clone --recurse-submodules https://github.com/OWNER/REPO.git
cd REPO
./scripts/build.sh
open .build/MacWallpaper.app
```

如果你有 Apple Development 证书（在 Xcode 里用 Apple ID 即可免费获得），`scripts/build.sh` 会用它签名，这样重新编译后
钥匙串仍然能正常访问；没有的话就用临时签名。运行 `swift test` 执行测试。

同时编译出的命令行工具 `wecli` 可以把壁纸渲染成图片、检查 Wallpaper Engine 的各种文件格式，以及和 Steam 交互：不带
参数运行即可查看帮助。`scripts/regress.sh` 会把渲染结果和参考图对比；它需要本地的 Wallpaper Engine 文件和示例壁纸
（`samples/`，不在仓库里）。

工作原理、设计取舍和各种发现都写在 [docs/design.md](docs/design.md) 里。

## 许可证

GPL-3.0。见 [LICENSE](LICENSE) 和 [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md)。
