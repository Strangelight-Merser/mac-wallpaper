# macOS 原生动态壁纸（兼容 Wallpaper Engine 格式）架构设计

> 状态：草案 v0.1（2026-10-21） · 许可证：GPLv3（便于参考/移植 linux-wallpaperengine）

## 1. 目标与非目标

**目标**
- macOS 14+ 原生 App（Swift + AppKit/SwiftUI + Metal），在桌面层渲染动态壁纸，多屏、多 Space。
- 兼容 Wallpaper Engine（WE）壁纸：`video`、`web`、`scene` 三类；读取 `project.json` 用户属性并可调。
- 低功耗：遮挡/全屏/电池/锁屏时自动暂停或降帧。

**非目标**
- `application` 类型（Windows exe）。
- 内置创意工坊下载（用户自行用 steamcmd 或从 Windows 拷贝）。
- 分发 WE `assets/`（版权素材，运行时由用户指定 WE 目录导入）。

## 2. 素材调研结论（基于 WE 2.8.42 + 官方示例）

| 示例 | 类型 | 内容 |
|---|---|---|
| beach / deep_space / eagleflag / razer_vortex | scene | 纯 image 图层 + 特效（入门目标） |
| razer_bedroom | scene | 18 个 image 图层，scroll/tint/pulse 特效，bloom，SceneScript |
| dino_run | scene | 32 image + text + sound + 脚本（小游戏） |
| shimmering_particles | scene | 粒子 + 脚本 |
| arsenal / dna_fragment / fantasticcar / demon_core / ricepod | scene | **3D model（.mdl）**、灯光、粒子 |
| corsair_collection / corsair_o_tron | web | index.html |

关键发现：
1. 官方示例是**解包后的目录**；创意工坊条目多为 `scene.pkg`，需要 PKG 解析（缺测试样本，待补）。
2. 示例中 `.tex` 旁有同名 `.png`，可作为 TEX 解码器的黄金样本。
3. 着色器是 **GLSL 3.3 + HLSL 风格宏**（`float4`/`mul`/`texSample2D`/`saturate`…），配合 `// [COMBO]` 编译开关与 uniform 注释里的 JSON 元数据（material 绑定名、默认值、范围）。
4. linux-wallpaperengine 的做法：文本预处理（注入宏头 + COMBO define）→ glslang 编译为 SPIR-V → SPIRV-Cross 回 GLSL。**我们只需把最后一步换成 SPIRV-Cross → MSL**，路线已被验证。
5. 3D 模型在官方示例中占比不低，比预期更早需要 `.mdl` 解析与简单 3D 管线。

## 3. 总体架构

```
┌─────────────────────────── App (AppKit, LSUIElement) ───────────────────────────┐
│ MenuBar / SwiftUI 设置&壁纸库 │ LibraryStore(导入/缩略图/属性) │ PowerPolicy │
└───────────────┬───────────────────────────────────────────────────────────────┘
                │ 每屏一个
        DesktopWindowController (NSWindow @ desktopWindow level)
                │ 承载一个 WallpaperRenderer（协议）
   ┌────────────┼──────────────────────┬──────────────────────────┐
VideoRenderer   WebRenderer              SceneRenderer (MTKView)
AVPlayerLayer   WKWebView + WE JS 桥     │
(+VLCKit 兜底)  (属性/音频/暂停事件)      ├─ SceneGraph（图层/相机/后处理）
                                         ├─ MaterialSystem（pass/blend/纹理绑定）
                                         ├─ ShaderCompiler（预处理→glslang→SPIRV-Cross→MSL，磁盘缓存）
                                         ├─ ParticleSystem / ModelRenderer / TextRenderer
                                         ├─ Scripting（JavaScriptCore 实现 SceneScript）
                                         └─ AudioAnalyzer（ScreenCaptureKit 音频 → FFT）
                 ── WEFormat（纯 Swift 包，无 UI 依赖，可单测）──
                 PKG 读取 · TEX 解码 · project/scene/material/effect/model JSON 模型 · VFS
```

### 模块划分（SwiftPM 多 target）
| Target | 职责 | 依赖 |
|---|---|---|
| `WEFormat` | VFS（目录/PKG/assets 叠加查找）、PKG、TEX（RGBA8/DXT1/3/5/R8/RG88、LZ4、内嵌图像、GIF 帧表）、JSON 模型 | LZ4（C 源码内嵌） |
| `WEShader` | 预处理、COMBO 解析、uniform 元数据提取、编译到 MSL、缓存 | glslang + SPIRV-Cross（C/C++ 源码以 SwiftPM C target 引入） |
| `WERender` | Metal 场景渲染 | WEFormat, WEShader |
| `WEScript` | SceneScript 运行时 | JavaScriptCore |
| `App` | 窗口、菜单、库、属性面板、电源策略、开机自启 | 以上全部 |
| `wecli` | 命令行：解包、tex→png、离屏渲染一帧到 png | 调试与回归测试用 |

## 4. 关键设计点

### 4.1 桌面窗口
- 无边框 `NSWindow`，level = `kCGDesktopWindowLevel`，`collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]`，`ignoresMouseEvents = true`。
- 监听 `NSApplication.didChangeScreenParametersNotification` 重建窗口；每屏独立配置。
- 鼠标交互（视差、web 壁纸点击）：全局 `NSEvent` 监听鼠标位置注入渲染器，点击默认不拦截。

### 4.2 Shader 管线
1. 读 `.vert/.frag`，递归展开 `#include`（先查壁纸目录，再查 assets）。
2. 解析 `[COMBO]` 与 uniform 注释 JSON → 生成 define 集合与参数表。
3. 注入兼容宏头（同 linux-wallpaperengine），`varying/attribute` → `in/out`，`gl_FragColor` → 输出变量。
4. glslang → SPIR-V（自动 location/binding）→ SPIRV-Cross 反射得到 uniform/纹理绑定 → 生成 MSL。
5. 以「源码哈希 + define 集」为键做内存与磁盘缓存；运行期用 `MTLLibrary` 编译 MSL。
6. uniform 统一打成 argument buffer/普通 buffer；内置变量（`g_Time`、`g_ModelViewProjectionMatrix`、`g_Texture0Resolution`、`g_PointerPosition`、`g_AudioSpectrum16Left`…）由 `ShaderVariables` 统一提供。

### 4.3 场景渲染
- 坐标：`orthogonalprojection` 定义的画布（如 3840×2160），按屏幕 aspect 做 cover 适配。
- 每个 image 图层：自身纹理 → 依次执行 effect passes（ping-pong FBO，`copybackground` 时先抓取背景）→ 按 blending 合成到场景目标。
- 后处理：HDR + bloom（scene.general 中参数）。
- 色彩：遵守 `srgb` 标志选择 `.rgba8Unorm_srgb`；HDR 用 `.rgba16Float`。

### 4.4 Web 壁纸
- `WKWebView` 透明背景加载 `index.html`（`loadFileURL` 授权壁纸目录）。
- 注入 user script：在加载后调用 `window.wallpaperPropertyListener.applyUserProperties(...)`，提供 `wallpaperRegisterAudioListener`（每帧推 128 点频谱）、`setPaused` 等。

### 4.5 视频壁纸
- mp4/mov：`AVQueuePlayer + AVPlayerLooper`，静音，硬解。
- webm：首选导入时用系统内或内置 ffmpeg 转 HEVC（一次性），避免常驻 VLC 依赖；待定。

### 4.6 电源策略
- 窗口遮挡（`NSWindow.occlusionState`）、前台 App 全屏、电池模式（`ProcessInfo.isLowPowerModeEnabled` + IOPowerSources）、锁屏/睡眠通知 → 暂停或降至可配帧率。
- `MTKView.preferredFramesPerSecond` 默认 30，可调。

## 5. 里程碑

| 阶段 | 内容 | 验收样本 |
|---|---|---|
| M0 骨架 | SwiftPM 工程、桌面窗口、多屏、菜单栏、电源策略、`wecli` | 纯色/测试图 |
| M1 视频+Web | VideoRenderer、WebRenderer + JS 桥、project.json 属性面板 | 任一 video、corsair_* |
| M2 格式层 | VFS、PKG、TEX（与 .png 比对单测）、JSON 模型 | 所有示例 tex 解码一致 |
| M3 静态 scene | 图层、相机适配、genericimage 系列 shader、blending | beach、deep_space、eagleflag |
| M4 特效 | effect passes、FBO 链、用户属性绑定（`"user": ...`）、bloom | razer_bedroom、razer_vortex |
| M5 粒子/文本/音频 | 粒子系统、text、ScreenCaptureKit 音频频谱 | shimmering_particles、dino_run（不含脚本） |
| M6 脚本 | SceneScript（JavaScriptCore） | razer_bedroom 脚本、dino_run |
| M7 3D | `.mdl` 解析、简单光照、puppet warp | retro、neon_sunset、fantasticcar |

回归测试：`wecli render <dir> --time t --out x.png`，与参考截图做感知差异对比。

## 6. 风险

| 风险 | 缓解 |
|---|---|
| WE shader 方言边角语法 SPIR-V 编译失败 | 预处理补丁表 + 失败图层降级为直通渲染并记录 |
| `.mdl`/puppet 格式文档少 | 参考 linux-wallpaperengine；必要时再引入 REA 做行为确认 |
| glslang/SPIRV-Cross 体积与构建复杂度 | 作为 SwiftPM C++ target 一次性 vendoring；或预编译 xcframework |
| 系统音频采集需屏幕录制权限 | 音频响应设为可选功能，无权限时频谱为 0 |
| 版权 | 仓库不含任何 WE assets/示例；测试素材仅本地路径 |

## 6.5 可行性验证记录（2026-10-21）

**M2 格式层原型已完成**（`Sources/WEFormat` + `Sources/wecli`，纯 Swift、无第三方依赖）：
- 实现：TEX（TEXV0005/TEXI0001/TEXB0001–0004/TEXS0001–0003）、LZ4 块解压、DXT1/3/5 软解、R8/RG88、内嵌 PNG/JPEG（ImageIO）、PKG 读取。
- `wecli verify samples`：**484/484 个 .tex 全部解析成功**；有同名 .png 的 93 个中 61 个逐像素一致（max≤8），25 个为 DXT 有损级差异（mean<5，参考 PNG 是压缩前原图），3 个为法线贴图，4 个参考 PNG 本身不可读。耗时约 2s。
- 格式分布：rgba8888 240、dxt5 94、r8 60、rg88 51、内嵌 PNG 38、JPEG 1；GIF 动画帧表 61 个。

**新发现（RePKG 未覆盖）**
1. flags `0x40` = **3D 体积纹理**（`assets/materials/lut/*` 调色 LUT）：头部多一个 u32（疑似平均色），每个 mipmap 多一个 depth 字段；载荷是纵向堆叠切片的 PNG（32×1024 = 32³）。渲染时上传为 `MTLTextureType.type3D`。
2. 法线贴图为 **DXT5nm**：X 存 alpha、Y 存 G，Z 需重建——shader 已按此采样，渲染器直接上传 BC3 即可，无需转换。
3. 渲染器不应软解 DXT：Apple Silicon 支持 `.bc1/2/3_rgba`，直接上传；软解仅用于 wecli/测试。
4. 纹理按 2 的幂补齐（`textureWidth` ≥ `imageWidth`），UV 需按 `image/texture` 比例缩放。

**环境问题（已于 2026-10-22 解决，见 §6.11）**：当初本机只装了 Command Line Tools，`swift build` 崩溃，并且 SDK 与编译器版本不匹配，只能用 swiftc 手动编译绕过。

**Shader 转译已验证**（`scripts/shader_batch.py` + `tools/metalcheck.swift`；glslang 16.6、SPIRV-Cross 1.4.363）：
流程：预处理（同 LWE 宏头 + include 提升 + COMBO 默认值）→ `glslangValidator -V -R --sdub WEUniforms 0 0 --aml --amb` → `spirv-cross --msl --msl-version 20300` → MSL 小修 → **用 `MTLDevice.makeLibrary(source:)` 真编译**（与 App 运行期同一路径）。

| 范围（去重后，排除 6 个 DX11 HLSL 回退 shader） | 默认 combo | 全部 combo=1（压力） |
|---|---|---|
| 壁纸自带 shader（defaultprojects / 示例） | **81/81** | 80/81 |
| assets/effects（官方特效） | 230/235 | 227/235 |
| assets/shaders（核心：genericimage、粒子、模型…） | 100/106 | 97/106 |
| **合计** | **411/422 = 97.4%** | 404/422 = 95.7% |

凡是生成了 MSL 的，Metal 编译 100% 通过。

**必须的处理（已在脚本中实现，移植到 `WEShader` 时照搬）**
1. **uniform 必须打包成一个 block**：LWE 的 OpenGL 模式（`-G`）下每个散装 uniform 各占一个 Metal buffer，数组每个元素占一个槽，音频频谱 shader 会用到 `buffer(68)`，超出 Metal 31 个的上限。改用 `-R --sdub` 后所有 shader 都只用 `buffer(0)`，正好对应设计中的统一 uniform buffer。
2. SPIRV-Cross 把全局 uniform 作为 `thread const T&` 参数传给辅助函数，不能绑定 `constant` 地址空间 → 后处理改为按值传参。
3. include 要插在**第一个顶层函数定义之前**（而不是 LWE 的 main 之前），否则 main 之前的辅助函数找不到 `common.h` 中的函数。
4. WE 编译器接受 HLSL 式标量广播：`pow(vec3, float)`、`max(float, vec2)` → 用 `WE_pow/WE_min/WE_max` 全重载包装（不能直接重载内建函数，否则会屏蔽全部内建重载）。
5. 绑定贴图的 combo（如 `NORMALMAP`）默认**不定义**（shader 里用 `#ifdef`）；`TEXnFORMAT`、`INSTANCECOUNT`、`BLENDROWCOUNT` 由运行时提供；补 `CASTF`、`sampler2DBackBuffer`、`texSample2DBackBuffer`。

**剩余 11 个失败**
- 7 个是 HLSL 式**隐式向量截断**（`vec2 x = v_TexCoord;`，其中 v_TexCoord 是 vec4），涉及 shimmer、caustics、cloudmotion、glitter_combine 等。正则修不了，需要带类型的处理。方案：vendoring glslang 时给 GLSL 前端加隐式截断（它的 HLSL 前端已经实现了这套转换），或者按 LWE 方式逐个打补丁。
- 3 个 shadowcaster（`gl_ViewportIndex` 分层阴影）只在 3D 光照阴影中使用，归入 M7。
- 1 个 volumetricsfront（`texLoad2D`）：补宏即可。

**结论**：shader 路线可行，不再是阻塞性风险。M3/M4 需要的 genericimage 和官方特效几乎全部可用。注意以上统计只覆盖**编译**，渲染结果是否正确要等 M3 用 `wecli render` 和参考截图对比。

## 6.6 M3 原型（2026-10-21）

`wecli render <壁纸目录> --assets <WE assets> --time t --size WxH --out x.png` 可以离屏渲染静态 image 图层场景。
- 模块：`WEShader`（预处理 Swift 移植 + 调用 glslang/SPIRV-Cross CLI，用反射拿 uniform 偏移与纹理/属性槽位）、`WERender`（`SceneDescription` 解析 scene→model→material→pass；`SceneRenderer` 离屏 Metal 渲染）。
- **beach**（flowimage + genericimage additive + swayimage translucent）和 **deep_space**（genericimage + 4 纹理 flowimage）渲染结果与官方 preview 构图一致，没有警告；改变 `--time` 会让 flow/sway 动画逐帧变化。冷启动约 2.5s，主要花在调用外部 CLI 编译 shader 上。
- 已验证的约定：画布坐标 y 轴向上、原点在左下；纹理第 0 行是图像顶部；quad UV = `image/texture` 尺寸比（处理 2 的幂补齐）；`mul(v, M)` 等价于列主序矩阵 `M*v`，CPU 端用标准列主序 MVP 即可；BC1/2/3 直接上传。
- 渲染出的 shader 需要的内建 uniform：`g_ModelViewProjectionMatrix`、`g_Time`、`g_TextureNResolution`（texW, texH, imgW, imgH）、`g_Texture0Rotation/Translation`；带注释的 uniform 取 `constantshadervalues[material]`，没有则用默认值。

**待办 / 未验证**
- 旋转方向（`angles.z` 的正负）只在 deep_space 的 -0.064 rad 小角度上看过，还没有严格验证。
- 色彩空间：目前按 gamma 空间、`rgba8Unorm` 直通处理；preview 看起来更亮，可能是 preview 本身的后期效果，需要在 Windows 上截图对比确认。
- 还没有缓存：CLI 编译要改为进程内调用 glslang/SPIRV-Cross 库，再加上磁盘缓存。
- 新版场景格式（object 带 `size`、`effects`、`visible` 是带用户属性的对象）只做了基础解析；effect 归入 M4。

## 6.7 M4 原型：特效、用户属性、bloom（2026-10-21）

`wecli render ... [--prop name=value]... [--layers a,b] [--bloom off] [--target _rt_Bloom]`
- **razer_vortex**：rz/tint 特效（径向彩虹光环围绕 logo，HUEMODE、`{"user": ...}` 绑定）渲染正确；`--prop` 修改亮度和速度后结果可见变化。
- **razer_bedroom**（17 个图层、scroll/tint 特效、`colorBlendMode` 11/12、HDR + bloom）与官方 preview 一致：霓虹字、灯带、显示器、台灯、各种光晕的混合模式都对。霓虹字颜色不同是因为它由 SceneScript 彩虹脚本驱动，目前取的是脚本的静态 value。
- beach、deep_space 回归通过；shader 批量转译仍是 411/422。

**实现要点**（参照 LWE `CImage`）
- 每个图层的 pass 列表 = 材质 pass + 特效 pass，`colorBlendMode > 0` 时再追加 `materials/util/effectpassthrough.json`（带 `BLENDMODE` combo）。pass 数大于 1 时，把第一个 pass 的 blending 移给最后一个 pass，第一个改为 normal。
- 第一个 pass 把图像画进图层大小的 FBO；中间 pass 用全屏 quad 在两个 FBO 之间 ping-pong（贴图槽 0 为空表示上一个 pass 的输出）；最后一个 pass 按图层变换画进场景。
- uniform 取值优先级：引擎内建 > 材质 `constantshadervalues`（支持 user 绑定）> 对象的 brightness/alpha/color > shader 注释里的默认值。
- 贴图槽有贴图时，打开对应 sampler 注释里的 combo（如 `MASK`）。
- `_rt_FullFrameBuffer`：按需把场景目标 blit 一份副本，供混合模式和 bloom 使用。
- **Bloom 直接复用 WE 自带的 shader**：`downsample_quarter_bloom` → `downsample_eighth_blur_v` → `blur_h_bloom` → `combine`。HDR 场景使用 `bloomhdr*` 参数，场景和 FBO 都用 `rgba16Float`。

**本轮修掉的坑**
1. 内嵌 PNG/JPEG 的 tex 按 image 尺寸存储，不做补齐（header 写 4096² 但实际是 3840×2160）→ UV 比例要用解码后的尺寸。之前 vortex 和 bedroom 的 4K 底图因此错位。
2. 屏幕空间 UV：WE 的 `#ifdef HLSL v.y = -v.y; #endif` 在 Metal（纹理原点在左上）下必须生效，但不能全局 `#define HLSL`，否则会启用 `inverse(mat3)` 等 HLSL polyfill，导致 17 个 shader 编译失败。改为预处理时只展开这种 y 翻转块。
3. genericimage2 v2（定义了 `VERSION`）没有 `g_Brightness`；对象 brightness（HDR 过曝，例如灯带的 3–4）**假定**乘进 `g_Color4`，否则 bloom 阈值永远达不到。需要在 Windows 上对照确认。

**未完成**
- SceneScript（属性脚本、`applyUserProperties`）→ M6。vortex 的颜色模式和 bedroom 的彩虹色依赖它。
- 特效的 `fbos`、`target`/`bind`、command pass 目前只给出警告（本轮样本没有用到；blur 之类的特效需要）。
- 父子变换（`parent`）、`alignment`、puppet mesh 都未实现。

## 6.8 M0 原型：桌面实时 App（2026-10-21）

`scripts/build.sh` 会额外生成 `.build/manual/MacWallpaper.app`（菜单栏应用，没有 Dock 图标，ad-hoc 签名）。启动命令：
`MacWallpaper.app/Contents/MacOS/MacWallpaper --wallpaper samples/razer_bedroom --assets samples/wallpaper_engine/assets`
（这两个参数会写入 UserDefaults，之后直接打开 App 就会加载同一张壁纸。）

- **窗口**：每个屏幕一个无边框 `MTKView` 窗口，level 为 `kCGDesktopWindowLevel`（在 Finder 图标层之下），`canJoinAllSpaces + stationary + ignoresCycle`，不接收鼠标事件；屏幕参数变化时按 displayID 增删窗口。所有屏幕共用一个 `SceneRenderer`。
- **渲染器改造**：新增 `encodeFrame(into:commandBuffer:time:)`，可以直接画进 drawable。所有 render target 放进池子按尺寸复用，稳态下每帧不再分配；HDR 场景纹理通过一个 present pass（clamp）输出到 `bgra8Unorm`。警告去重，避免每帧累积。
- **加载**：在后台线程创建渲染器，并用 64×36 的预热帧把所有 shader 和 pipeline 编译好，再切回主线程开始绘制，主线程不会卡住。
- **菜单**：显示状态（实际 fps、GPU 毫秒数、暂停原因）、暂停/继续、帧率（15/24/30/60）、选择壁纸文件夹、选择 assets 文件夹、重新加载、退出。
- **电源策略**：用户暂停、显示器休眠、锁屏时全部暂停；某块屏幕的窗口被完全遮挡（`occlusionState`）时只暂停那块屏幕；低电量模式下帧率减半。动画时钟只在绘制时前进，暂停期间不跳帧。

**实测**（MacBook，1440×932@2x，drawable 2880×1864，razer_bedroom 共 17 个图层，带特效和 HDR bloom）：
- 用 `CGWindowListCopyWindowInfo` 确认窗口在屏、层级为 desktop，覆盖全屏。
- 稳定 30.0 fps，GPU 5.9–7.0 ms/帧，进程 CPU 约 10%，RSS 约 150 MB。
- 模拟锁屏（`com.apple.screenIsLocked` 分布式通知）后 CPU 降到 0.0%、停止出帧；解锁后恢复 30 fps。
- **没测到**：多显示器（本机只有一块屏）；遮挡暂停（需要把一个全屏 App 盖在上面，用户不在，没去操作）；没有拿到真实桌面截图，因为没有屏幕录制权限时 `screencapture` 只返回系统壁纸。

**CPU 优化（2026-10-22）**
- 用 `sample` 采样：主线程每帧的工作里，43% 花在**每帧从磁盘重读 JSON**（effectpassthrough 和 bloom 的材质），约 45% 花在按名字逐个求 uniform（字符串查找、`parseFloats`、字典），14% 花在创建 Metal render encoder（约 60 个/帧）。
- 改动：
  - 各图层的 pass 列表和 bloom 的 pass 只构建一次（`layerPasses`、`bloomPasses`）。
  - 每个 pass 首次绘制时生成一份 `PassPlan`：shader 变体、按像素格式缓存的 pipeline、贴图来源（固定贴图 / `_rt_*` / 上一个 pass 的输出）、MSL 绑定槽位，以及**预填好的 uniform 缓冲模板**；之后每帧只回填 MVP、时间、贴图分辨率、texel/屏幕尺寸。
  - 连续画到同一个 target 且不需要清屏时复用 render encoder。
- 正确性：beach、deep_space、razer_vortex、razer_bedroom 的离线渲染与改动前**逐像素一致**（max diff 0）。
- 实测：在同一系统负载下前后连续对比，同为 30 fps，进程 CPU 从 **19.3% 降到 10.7%**；主线程每帧的工作从 536 个采样降到 134 个（−75%）。剩下的主要是 Metal 自身开销：创建 encoder，以及驱动线程提交命令（`submitCommandBuffers`）。
- 注意：前后两次测量中系统负载变化很大（同一个旧版本先是 10%，后来变成 19%，GPU 6.5 ms 变成 21 ms），所以只能用前后连续测得的数值做对比。

**静态图层缓存（2026-10-22）**
- 判定：一个 pass 如果不读 `g_Time`、`g_Daytime`、指针、音频、`g_TexelSize`/`g_Screen`，也不读任何 `_rt_*` 渲染目标，就算**静态**。每个图层从头开始、不含最后一个合成 pass 的连续静态 pass，只在第一帧渲染一次，结果 blit 到图层专属纹理（`layerCaches`）；之后每帧从缓存往后接着画。缓存大小只和图层尺寸有关，与输出分辨率无关，所以窗口尺寸变化不影响。
  - 例：bedroom 的 wave 图层，静态的 genericimage2 基础 pass 被缓存，只有随时间变化的 scroll 特效每帧重画；glow 图层的 tint 特效颜色是固定值，整段被缓存，只剩混合模式合成。
- 新增 `wecli bench`（CPU 编码时间、GPU 时间、每帧 encoder 数、吞吐量，可用 `--fps 30` 按节奏提交）和 `wecli render --warm t`（先渲染一帧把缓存建好，再出图）。
- 正确性：4 个场景各取 t=3 和 t=7.5 两个时刻，开缓存与关缓存的结果**逐像素一致**；t=3 与 t=7.5 之间仍有变化，动画没有被冻结。
- 效果（2880×1864）：
  - bedroom：每帧 render encoder 从 41 个降到 13 个；CPU 编码 0.89 → 0.53 ms；GPU 跑满时每帧耗时 5.6 → 3.9 ms（约 −30%）；按 30 fps 节奏提交时 GPU 6.5 → 4.9 ms。
  - vortex：每帧 encoder 从 8 个降到 2 个，CPU 编码 0.22 → 0.05 ms。
  - **实际 App 里交替做了两轮 A/B**（隐藏开关 `-disableLayerCache YES`）：CPU 从 10.3%/10.8% 降到 7.7%/7.6%，约 −27%；GPU 从约 6.1 ms/帧降到约 5.3 ms/帧，约 −13%。
- 测量上踩过的坑：最初用单个 command buffer 的 `gpuEndTime - gpuStartTime` 做指标，结果显示开了缓存反而更慢。原因是同时有多帧在 GPU 上排队时，这个区间会把等待时间也算进去；改用吞吐量或按固定帧率提交来测之后才得到真实的结论。

**后续优化**
- 更进一步：把连续的静态图层（以及它们最后的合成 pass）合并缓存成"静态背景"，前提是中间不夹着动态图层，也没有读取场景的混合模式。
- 用 `MTLHeap` 或 memoryless 作为中间 FBO，进一步降低 GPU 带宽。
- 支持按屏幕设置渲染缩放（例如 0.75×），5K/6K 外接屏会需要。
- 用 `SMAppService` 实现开机自启；签名和 notarize 等装了 Xcode 之后再做。

## 6.9 多 FBO 特效与官方特效预览测试集（2026-10-22）

`scripts/render_effect_previews.sh` 会渲染 `assets/effects/*/preview` 下全部 45 个官方特效预览场景（每个取 t=1 和 t=2.5 两个时刻，并附上未加特效的原图），输出到 `out/effects/`，同时打印渲染器的警告。
- **结果：45 个里 44 个可以正常渲染，目视检查合理**。shine 依赖粒子系统，归入 M5。被 shader 兼容性改写挽救的有 6 个：cloudmotion、cursorripple、glitter、shimmer、shine 的部分 pass、watercaustics。
- 4 个主测试场景逐像素回归一致；开/关静态图层缓存的输出也逐像素一致。

**新增支持**
- `effect.json` 的 `fbos`：尺寸有三种写法，`scale`（图层尺寸 ÷ n）、`fit`（等比缩到 N 像素以内）、固定的 `width`/`height`；格式支持 `rgba_backbuffer`、`rgba8888`、`r8`、`rg88`、`r16f`、`rg1616f`；`uvs: repeat`。这些 FBO **按"图层 × 特效"持久保存**（运动模糊累积、水波纹模拟、流体模拟都依赖上一帧的结果），创建时清零。
- pass 的 `target` / `bind`，以及 `previous`（别名 `prev`）：按 LWE `CImage::setupPasses` 的状态机实现。带 target 的 pass 画进具名 FBO，并把它作为后续 pass 的输入；`previous` 指当前 target 序列开始时的输入。
- command pass：`copy`（blit）和 `swap`（交换两个持久 FBO）。
- 跨图层引用 `_rt_imageLayerComposite_<id>_a/_b`：每个图层有自己专属的 composite FBO，并在全局登记。**隐藏图层也照常渲染**，结果进自己的 composite，不画进场景。图层按 `dependencies` 做拓扑排序后渲染。
- `passthrough` / `fullscreen` 模型（composelayer、fullscreenlayer）：第一个 pass 画在图层的屏幕空间位置上，可以采样 `_rt_FullFrameBuffer`。
- 没有 `size` 的 autosize 图层，退回用贴图的 image 尺寸。
- 新增内建 uniform：`g_Frametime`、`g_PointerState`、`g_ParallaxPosition`。
- 最后一个**会画东西的** pass 才合成进场景；排在它后面的 swap/copy 命令照常执行。

**Shader 兼容性改写（`ShaderCompat.swift`，只在第一次编译失败时启用，保证不影响原本就能编译的 shader）**
- 隐式截断：`vecN x = 更宽的标识符;`、`x.rgb = vec4 标识符;`、`float x = texSample2D(...);`，以及给用户函数传入更宽向量的实参。
- 顶点和片元着色器里同一个 varying 宽度不一致时，加宽顶点端并补齐赋值（与 LWE 的做法相同）。
- Metal 层面：片元着色器读取了顶点着色器没有写的 `[[user(locnN)]]` 时，给顶点输出结构体补上这个成员（零初始化）。
- `#ifdef HLSL` 中只由 y 翻转语句组成的块（`v.y = -v.y` / `v.y = 1.0 - v.y`，可以有多行）都会展开。

**顺带修掉的 bug**
- `warn()` 自己调用自己（M0 重构时全局替换引入的）：**从 M0 以来所有警告都被悄悄丢掉了**。这次补上，并且发现了一系列此前被掩盖的问题。
- 新增调试工具：`wecli scene`（打印解析后的图层、pass、target、bind 和 FBO）、`WE_TRACE=1`（逐 pass 打印执行过程）、`--target` 可以导出特效 FBO 和图层 composite。

**未完成**
- 测试集没有参考图，只能目视判断"合理"。要和 WE 实际效果对比，需要在 Windows 上截图。
- 鼠标交互类特效（cursorripple、流体发射器的指针模式）在离线渲染里没有输入，App 也还没有接入鼠标位置。
- `scripts/shader_batch.py` 没有同步 Swift 版的兼容性改写；以 Swift 实现为准，Python 脚本只作历史统计。

## 6.11 工具链：Xcode 26.3（2026-10-22）

- 本机系统为 macOS 15.6，所以选了**支持 15.6 的最新版 Xcode 26.3**（17C529，附带 SDK 26.2，Swift 6.2.4）；26.4 及以后的版本要求 macOS 26.2。安装方式：用 Xcodes app，由用户自己登录 Apple ID、完成首次启动初始化；`xcode-select` 指向 `/Applications/Xcode.app`。
- 另外安装了 Metal Toolchain 组件（`xcodebuild -downloadComponent MetalToolchain`，17C7003j），可以离线 `xcrun metal` 编译 MSL，为以后预编译 metallib 做准备。
- `scripts/build.sh` 改为 `swift build -c release`，然后把产物打包成 `.build/MacWallpaper.app`（ad-hoc 签名）。可执行文件在 `.build/release/{wecli,WallpaperApp,metalcheck}`，`metalcheck` 也成为 package 的一个 target。旧的 `.build/manual` 不再使用。
- 验证：干净构建约 12 秒，0 警告；4 个主场景和 5 个特效预览的输出与手动构建版本逐像素一致；45 个特效预览全部渲染完成（shine 仍需要粒子系统）；App 启动后稳定 30 fps。
- 还没做：Developer ID 签名和公证（需要 Apple Developer 付费账号），以及用 `SMAppService` 实现开机自启。

## 6.12 后续路线图（2026-10-22 定）

**已定的决策**
- 定位：**开源发布，不上架 App Store**；许可证 GPLv3（部分代码移植自 linux-wallpaperengine（GPLv3）和 RePKG（MIT））。不做付费签名/公证，用户第一次打开时需要右键 → 打开。
- 测试素材：暂时没有 Windows 截图；用户机器上的壁纸也没有 `.pkg` 格式的 → `.pkg` 降为低优先级。视频测试素材用 ffmpeg 自己生成。
- 阶段二的顺序：先做视频壁纸（马上能覆盖大量真实壁纸），再做粒子系统。
- webm：**不转码、不内置 ffmpeg**。在进程内解析 webm 容器，VP9 用 VideoToolbox 的补充解码器（macOS 11+），AV1 在 M3 及以上的芯片上走硬件解码；只有硬件不支持时才回退软件解码。解出的帧直接作为 Metal 纹理。动工前先做可行性验证。

**阶段一：打牢基础**
1. 正确性：`TEX<n>FORMAT` 填实际格式；sRGB 贴图；pass `conditions`、fbo `clear`、`compose`。
2. shader 编译改为进程内调用 glslang/SPIRV-Cross，并加磁盘缓存（去掉对 Homebrew 的依赖，二次启动接近瞬时）。
3. 回归测试集：现有样本 + 特效预览 + 自己生成的视频；把逐像素回归脚本化。

**阶段一第 1 项进展（2026-10-22）**
- ✅ `TEX<n>FORMAT` 填为绑定贴图的实际格式（材质里显式写了的仍以材质为准）；已确认能传进 shader，例如 cloudmotion 的 R8 遮罩编译出 `TEX1FORMAT=9`。现有场景和预览的输出都没有变化，这是对的：会受格式影响的 shader 是粒子（genericparticle、ropeparticle）、fur4（模型）和 lightshafts（其预览里绑的都是 RGBA 贴图）。粒子做起来以后这一项才真正生效。
- ✅ sRGB：结论是**不需要改渲染**。WE 自己的 `combine_hdr.frag` 只在最终输出时用 `lin()` 转线性，说明场景缓冲始终在 gamma（sRGB 编码）空间里，贴图按存储值直接采样，这与我们的管线一致（也与报告说的"不要做二次 gamma"一致）。`IsSRGB` 只解析、不改变采样。
- ✅ pass `conditions` 和 bind 的 `conditions`：按"shader 默认 combo ← 特效实例上的 combo ← pass 自己的 combo"求值，不满足的 pass 去掉、不满足的 bind 不绑；fbo 的 `clear` 初始颜色和 fbo `conditions` 也已支持。fluidsimulation 在 `LIGHTING=0` 时会正确跳过法线 pass（输出不变，GPU 少做一个 pass）。
- `compose: true`（refraction）：它的 pass 本身就指定了 `effectcomposebackground` 材质，按普通 pass 执行即可，此前已经能正确渲染，无需额外处理。
- 验证：4 个主场景、44 个特效预览逐像素不变；在同一状态下与上一个 commit 做 A/B bench，CPU 差异在噪声范围内（约 0.03 ms）。

**阶段二：内容覆盖**
1. M1 视频壁纸（AVPlayer 播 mp4/mov；webm 走上面的方案），以及场景里的视频纹理（TEXB0004）。
2. M1 网页壁纸（WKWebView + `wallpaperPropertyListener` / 音频监听桥接）。
3. 鼠标交互：相机视差、`g_Pointer*`、光标类特效。
4. M5 粒子系统，以及文字图层、音频频谱（ScreenCaptureKit，需要用户授权）。
5. M6 SceneScript（JavaScriptCore，按官方 SceneScript 文档实现）。
6. M7 3D 模型 / puppet。

**阶段三：产品化**
1. 壁纸库：自动发现 Steam 创意工坊目录、缩略图、按 `project.json` 生成属性面板、每块屏幕单独选壁纸、播放列表。
2. 开机自启（SMAppService）；实测多显示器和遮挡暂停。
3. 开源发布：README、构建说明、release 包。

## 6.13 Shader 编译进程内化 + 磁盘缓存（2026-10-22，阶段一第 2 项）

- **集成方式**：glslang 16.6.0 和 SPIRV-Cross vulkan-sdk-1.4.363.0 以浅克隆的 git submodule 放在 `ThirdParty/`，固定在与当初 shader 批量测试相同的版本；SwiftPM C++ target `CShaderTools` 通过符号链接编译两者的源码（`ENABLE_SPIRV`、`GLSLANG_OSINCLUDE_UNIX`，不含 HLSL 前端和 SPIRV-Tools），对 Swift 只暴露一个 C 接口 `we_compile_glsl_pair()`。`build_info.h` 用 glslang 自带脚本生成后提交到仓库。
- **与 CLI 字节级一致**：glslang 端逐项复刻 StandAlone.cpp 对 `-V -R --sdub WEUniforms 0 0 --aml --amb -l` 的处理（含 `mapIO()`）；SPIRV-Cross 端直接 `#include` 它的 `main.cpp`，调用 CLI 自己的 `compile_iteration()`，选项默认值与命令行完全一致。确认 GLSL 输入在不加 `-O` 时不会跑优化器，所以不需要 SPIRV-Tools。`WE_SHADER_PARITY=1` 会对每个程序同时用两条路径编译并比较：**167 个程序（4 个场景 + 全部特效预览）0 差异**。
- **磁盘缓存**：`~/Library/Caches/MacWallpaper/shaders/<sha256>.json`，key = 流水线版本 + 编译器版本 + 两个阶段的源码；缓存的是后端的原始输出（MSL + 反射 JSON），我们自己的后处理（地址空间修正、顶点输出补齐）每次重新做，所以修改后处理不需要清缓存。编译失败的结果也会缓存（兼容性改写的重试路径不会每次启动都重编失败的版本）。写入方式是先写临时文件再改名，并发读取是安全的。`WE_SHADER_CACHE=off` 关闭缓存，填路径则改用该目录。
- **CLI 后端保留**（`WE_SHADER_BACKEND=cli`），只用于对照；默认路径不再依赖 Homebrew。

**实测（razer_bedroom，11 个程序）**

| | CLI 工具 | 进程内，冷启动 | 进程内，缓存命中 |
|---|---|---|---|
| App：开始加载 → 就绪 | 0.70–0.76 s | **0.26 s** | **0.22 s** |
| `wecli render`（单帧） | 4.6 s | **0.35 s** | **0.31 s** |
| 其中 shader 编译 | 4.16 s | 0.05 s | 0 |

- 每个程序的编译从约 400 ms（5 次子进程）降到约 4.5 ms。CLI 的成本主要是启动子进程，而且它随父进程的启动方式波动很大：从 App 里启动每次约 13 ms，从命令行工具里约 75 ms。进程内编译把这一波动也消除了。剩下的约 0.2 s 是贴图加载和渲染本身，以后如有需要再优化。
- 4 个场景、44 个特效预览与 CLI 时代的输出逐像素一致。
- 代价：干净构建多约 25 秒（编译这两个库），增量构建不受影响。

## 7. 待确认
1. 最低系统版本：建议 macOS 14（SMAppService、ScreenCaptureKit 音频成熟）。
2. 工程形态：目前采用 SwiftPM + 生成 .app 的脚本（§6.11）；到需要正式签名分发时，再考虑加一个 Xcode 工程来包装。
3. ~~webm 处理方式~~：已定，进程内解析 + VideoToolbox 硬件解码（见 §6.12）。
4. 补充测试素材：暂无（用户机器上没有 `.pkg` 壁纸）；视频素材用 ffmpeg 自己生成。
