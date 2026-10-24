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
2. ✅ shader 编译改为进程内调用 glslang/SPIRV-Cross，并加磁盘缓存（§6.13）。
3. ✅ 回归测试集：`scripts/regress.sh`（§6.14）；视频用例等到 M1 做视频壁纸时再加。

**阶段一第 1 项进展（2026-10-22）**
- ✅ `TEX<n>FORMAT` 填为绑定贴图的实际格式（材质里显式写了的仍以材质为准）；已确认能传进 shader，例如 cloudmotion 的 R8 遮罩编译出 `TEX1FORMAT=9`。现有场景和预览的输出都没有变化，这是对的：会受格式影响的 shader 是粒子（genericparticle、ropeparticle）、fur4（模型）和 lightshafts（其预览里绑的都是 RGBA 贴图）。粒子做起来以后这一项才真正生效。
- ✅ sRGB：结论是**不需要改渲染**。WE 自己的 `combine_hdr.frag` 只在最终输出时用 `lin()` 转线性，说明场景缓冲始终在 gamma（sRGB 编码）空间里，贴图按存储值直接采样，这与我们的管线一致（也与报告说的"不要做二次 gamma"一致）。`IsSRGB` 只解析、不改变采样。
- ✅ pass `conditions` 和 bind 的 `conditions`：按"shader 默认 combo ← 特效实例上的 combo ← pass 自己的 combo"求值，不满足的 pass 去掉、不满足的 bind 不绑；fbo 的 `clear` 初始颜色和 fbo `conditions` 也已支持。fluidsimulation 在 `LIGHTING=0` 时会正确跳过法线 pass（输出不变，GPU 少做一个 pass）。
- `compose: true`（refraction）：它的 pass 本身就指定了 `effectcomposebackground` 材质，按普通 pass 执行即可，此前已经能正确渲染，无需额外处理。
- 验证：4 个主场景、44 个特效预览逐像素不变；在同一状态下与上一个 commit 做 A/B bench，CPU 差异在噪声范围内（约 0.03 ms）。

**阶段二：内容覆盖**
1. ✅ M1 视频壁纸（§6.15、§6.16；mp4/mov/webm-VP9/AV1）。场景里的视频纹理（TEXB0004）和 VP8 留到后面。
2. ✅ M1 网页壁纸 + VP8 的 WebKit 兜底（§6.17）。
3. ✅ 鼠标交互：相机视差、`g_Pointer*`、光标类特效、网页鼠标事件；✅ 音频频谱（ScreenCaptureKit，需要用户授权）（§6.18）。
4. M5 粒子系统，以及文字图层。
5. M6 SceneScript（JavaScriptCore，按官方 SceneScript 文档实现）。
6. M7 3D 模型 / puppet。

**阶段三：产品化**（2026-10-22 重新规划，提到粒子系统之前，详见 §6.19）
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

## 6.14 回归测试脚本（2026-10-22，阶段一第 3 项）

`scripts/regress.sh [--update] [--jobs N] [--no-build] [过滤正则]`
- 用例清单 `regression/cases.txt`（提交到仓库），共 99 个：4 个场景的 9 个变体（首帧、走静态图层缓存的帧、关闭 bloom、用户属性、竖屏 cover 适配等），加上 45 个官方特效预览各取 t=1、t=2.5 两个时刻。
- 每个用例比较两样东西：**像素**（新增的 `wecli compare`，默认要求完全一致，失败时输出放大后的差异图到 `regression/diff/`）和**排序后的警告列表**（新增警告也算回归——当初 `warn()` 吞掉所有警告的 bug 正是这类问题）。
- 参考图是用 WE 素材渲染出来的，属于衍生内容，**不提交**，放在被 gitignore 的 `regression/refs/`（或 `$REGRESSION_REFS` 指定的目录）。拿到仓库的人可以用自己的 WE 素材 `--update` 生成参考图。仓库里只提交用例清单和脚本。
- 用例并行执行（默认等于性能核心数），99 个用例约 5 秒跑完；最后输出一行汇总，失败、缺参考图或出错时退出码为 1。
- 当前这套参考图已经和此前人工目视确认过的输出做了核对：4 个场景、45 个特效预览全部逐像素一致。
- **验证过三条路径**：①正常全部通过 99/99；②临时故意改坏渲染器（改混合因子 + 删掉 `g_Frametime` 内建 uniform）→ 93 个用例失败，其中 cursorripple/fluidsimulation 准确报出新增的 `no value for g_Frametime` 警告，vortex 这种只有 0.49% 像素变化的也能抓到；还原后恢复 99/99；③参考图缺失 → 报 MISSING 并判定失败。
- `scripts/render_effect_previews.sh` 保留，用于生成供目视检查的拼图；`scripts/shader_batch.py` 仍走 CLI，只用于 shader 覆盖率统计。

## 6.15 视频壁纸：可行性验证（2026-10-22，阶段二第 1 项）

测试素材用 `scripts/make_test_videos.sh` 生成（ffmpeg testsrc2，1280×720，30 fps，4 秒，内容固定），每个都包装成最小的 WE video 工程，放在 gitignore 掉的 `regression/videos/`：h264_mp4、hevc_mp4、h264_mov、vp9_webm、vp8_webm、av1_webm、av1_mp4。

**系统能力探测（M4，macOS 15.6）**

| 编解码 | VideoToolbox 硬解 | AVFoundation 能否播放 |
|---|---|---|
| H.264 / HEVC | ✅ | ✅（mp4/mov） |
| AV1 | ✅（M3 起才有硬件） | ✅ mp4 / ❌ webm |
| VP9 | ✅（`VTRegisterSupplementalVideoDecoderIfAvailable`） | ❌ webm |
| VP8 | ❌ 苹果没有任何解码器 | ❌ |

**Spike**：自写最小 EBML/WebM 解析器，构造 `vpcC`（VP9）/`av1C`（AV1，直接取 CodecPrivate）格式描述，交给 VTDecompressionSession（强制硬件）→ VP9、AV1 都是 **120/120 帧、0 错误、每帧约 1.3–1.6 ms（720p）**，确认在用硬件解码器。第 30 帧与 ffmpeg 解码对比：ffmpeg 改用 BT.709 后平均差 1.2；剩下的差异只出现在色条硬边上，是两者色度上采样方式不同造成的，不是解码错误。注意 ffmpeg 导出 PNG 时默认用 BT.601，而 VideoToolbox 对 HD 内容用 BT.709。

**定案**
- mp4/mov 走 AVAssetReader，webm 走自写解析器 + VideoToolbox；两者都输出 BGRA `CVPixelBuffer`，经由同一套接口"按时间取帧"，实时播放与离线回归渲染走同一条解码路径。
- `VideoRenderer` 通过 `CVMetalTextureCache` 零拷贝转成 Metal 纹理，按 cover 方式铺满，复用 App 现有的 `encodeFrame` 接口（暂停策略、多屏、菜单都不用改）。
- VP8：苹果没有解码器 → 以后用 WebKit 内置的 VP8 解码器兜底（反正网页壁纸也要用 WKWebView），不为这个少见的编码单独引入 libvpx。本轮先不支持。
- 音频：本轮静音，以后加音量控制。

## 6.16 视频壁纸实现（2026-10-22）

- **`WEVideo` 模块**：`WebMFile`（EBML/Matroska 解析：未知长度元素、SimpleBlock、BlockGroup——没有 ReferenceBlock 才算关键帧、Duration/DefaultDuration、遇到 lacing 计数后跳过；文件内存映射，只保存帧的字节范围、不复制数据）；`VideoSource`（"取 t 时刻的帧"：循环播放、顺序解码并预读一帧、时间倒退时重新从头开始），两个后端：
  - `WebMVideoSource`：VP9（用首帧头信息构造 `vpcC`）/ AV1（`av1C` 直接取 CodecPrivate）→ VTDecompressionSession；没有对应硬件解码器时直接报错并说明原因。
  - `AssetVideoSource`：AVAssetReader（mp4/mov/m4v），输出同样是 BGRA、IOSurface、Metal 兼容的像素缓冲。
- **`VideoRenderer`**：通过 `CVMetalTextureCache` 零拷贝转成纹理，用一个全屏三角形按 cover 方式取 UV 窗口（居中裁切，不拉伸）；纹理与像素缓冲的生命周期一直保持到 GPU 完成。
- **`WallpaperRenderer` 协议 + `Wallpaper.open()`** 按 `project.json` 的 `type` 选择渲染器（video → VideoRenderer，web/application → 暂不支持并给出明确错误，其余 → SceneRenderer）；App 和 `wecli` 都改为走它，场景专用的调试选项通过类型转换设置。readback 提取成了共用函数。
- **正确性**：t=1 时 6 种格式都是第 30 帧；各编码之间只有有损压缩带来的差异（平均 < 0.6）；H.264 的 mov 与 mp4 完全一致；webm 路径与 spike 中直接调 VideoToolbox 的结果完全一致；t=5 与 t=1 完全一致（循环）；时间倒退后重新解码的结果也完全一致。
- **实时性能（4K30，App 中实测）**：HEVC CPU 6.3%、GPU 1.5–1.7 ms；VP9 4.4%、0.7–0.8 ms；AV1 4.4%、1.3–1.6 ms；均稳定 30 fps。（作为对比，razer_bedroom 约 7.6%。）
- **回归**：新增 17 个视频用例（6 种格式、循环、重启、竖屏 cover），测试视频缺失时由 `regress.sh` 自动生成；全套 116/116 通过，约 6.5 秒；新参考图已与上面人工核对过的输出逐一比对。

**后续**
- VP8：用 WebKit 兜底（与网页壁纸一起做）。
- 音频：现在静音；之后接 AVPlayer 或 AudioToolbox（webm 音轨是 Opus/Vorbis）并提供音量设置。
- 帧率：App 默认 30 fps，60 fps 的视频会被降帧；视频壁纸应自动匹配源帧率（或以显示器刷新率为上限）。
- 解码目前在主线程同步进行（4K 每帧约 1–2 ms）；如果遇到高码率 8K，再改成后台预解码队列。

## 6.17 网页壁纸 + VP8 的 WebKit 兜底（2026-10-22，阶段二第 2 项）

**JS 接口**（依据官方 corsair_o_tron / corsair_collection 的用法）：`window.wallpaperPropertyListener = {applyUserProperties({name: {value}}), applyGeneralProperties({fps}), setPaused(bool)}`；`window.wallpaperRegisterAudioListener(cb)` 会在**脚本加载时**就被调用。

**`WEWeb` 模块（`WebWallpaper`）**
- 桥接脚本在 document start 注入：定义所有 `wallpaperRegister*` 函数（音频监听已注册但暂时不推数据，媒体类为空实现）；拦截对 `wallpaperPropertyListener` 的**赋值**，赋值后立刻投递 general/user 属性和暂停状态（页面再晚注册也收得到）；页面里的 `error`/`unhandledrejection` 转成渲染器警告。
- **属性按声明类型转换**：project.json 里常把布尔值、数字写成字符串（例如 corsair_o_tron 的 `logorings: "true"`），而页面用 `=== true` 判断；bool → 布尔、slider → 数字、combo/color/text 保持字符串。JSON 布尔值要用 CFBoolean 来判断，因为 Swift 里任何值为 0/1 的 `NSNumber` 都能匹配 `is Bool`。
- **自定义 URL scheme `wewallpaper://`（`WallpaperSchemeHandler`）**：从 file:// 加载的页面 origin 是不透明的，WebKit 会把页面自己的文件当成跨域，于是 CSS `mask-image`、`fetch`/XHR 本地 JSON、canvas 读图都会失败（corsair_o_tron 的 logo 和光环就因此消失）。改为把壁纸目录作为同源站点提供：支持 Range 请求（`<video>`/`<audio>` 需要），路径不能越出壁纸目录，不需要依赖私有的 WebKit 偏好设置。
- **暂停**：`setPaused(true)` 会调用页面自己的 `setPaused`、挂起媒体播放、隐藏视图（页面变成 hidden，rAF 停止、定时器降频）。
- **VP8**：生成一个自有页面（`<video loop muted>`，object-fit: cover）。离线截帧方式是 seek 到 t → 等 `seeked` → 用 canvas 读帧，结果是确定性的。

**接入**：`Wallpaper.open` 对网页壁纸和 VP8 抛出类型化的 `WallpaperError.needsWebKit(.page/.video)`（WERender 本身不依赖 WebKit）；App 收到后为每块屏幕各建一个 `WebWallpaper`（一个视图只能挂在一个窗口里），替换掉 Metal 视图；暂停/遮挡策略按屏幕分别调用 `setPaused`，只在状态变化时调用。`wecli render` 用离屏窗口截图（窗口按点数设尺寸，让输出正好是要求的像素；不设 `snapshotWidth`，因为缩放截图会丢失合成层，比如 CSS mask）；`WE_WEB_EVAL` 可以在截图前对页面求值一个 JS 表达式用于调试。WallpaperController、AppDelegate 改为 `@MainActor`。

**实测（App + 它的 WebKit 进程合计 CPU）**

| | 运行 | 暂停（模拟锁屏） |
|---|---|---|
| corsair_o_tron | 6.0% | **0.0%**（恢复后 5.8%） |
| VP8 720p | 7.3% | 0.2% |
| VP8 4K30 | 27.4%（软件解码） | 0.2% |

**颜色（顺带修正测试视频）**：此前测试视频在 RGB→YUV 时用的是 BT.601 且没有打标签，VideoToolbox 对未打标签的 HD 视频按 BT.709 解释 → 颜色略有偏差。现在测试视频统一按 BT.709 转换并打标签（和真实 HD 视频一样），解码结果与原始图案相差只有 1–4 级。VP8 本身不能携带色彩信息，规范规定为 BT.601，所以 VP8 测试视频按 BT.601 编码；WebKit 还会额外把 BT.601（SMPTE-C）原色色彩管理到 sRGB，因此与 ffmpeg/VideoToolbox 的输出相差约 17——这是 WebKit 处理得更"正确"，不是解码错误。视频参考图已经按新素材重新生成，并与原始图案逐一核对过。

**回归**：新增 7 个用例——自写的桥接测试页（`regression/fixtures/webtest`，可以提交：覆盖属性类型、晚注册监听、fps、音频注册函数、同源 fetch、CSS mask）的默认/覆盖两种、corsair_o_tron 默认/覆盖两种、VP8 的 3 个用例。离屏状态下 CSS 动画和 rAF 不会推进，所以截图是确定的（连续三次逐像素一致）。全套 123/123，连续跑两次都通过。

**后续**：音频频谱采集（ScreenCaptureKit）→ 喂给 `wallpaperRegisterAudioListener` 和场景里的 `g_AudioSpectrum*`；鼠标事件转发给网页壁纸；`userDirectoryFiles*` 等不常用接口。

## 6.18 鼠标交互 + 音频频谱（2026-10-22，阶段二第 3 项）

**指针约定（用两个版本的 xray shader 实测确定）**
- `g_PointerPosition` / `g_PointerPositionLast`：光标在可见画面里的位置，0…1，**y 向下（顶部为 0）**，即屏幕坐标。shader 会先 `pointer.y = 1 - pointer.y` 再 `*2-1` 变成 y 向上的裁剪空间坐标。LWE 用的是 y 向上，但那是因为它在 OpenGL 里另有翻转；预览目录里旧版 xray 直接乘 `g_ModelViewProjectionMatrixInverse`，只有 y 向下的约定才能让光晕出现在光标处。
- `g_EffectTextureProjectionMatrix(+Inverse)` = 图层 MVP · scale(半宽, 半高)，即把图层四边形（-1…1，y 向上）映射到裁剪空间；光标类特效用它的逆矩阵求光标在图层里的 UV。LWE 传单位矩阵，只在图层铺满全屏时才对。实测新版 xray 的光晕中心与指定的光标位置误差 < 0.01。
- `g_PointerState` = (左键, 右键, 按下强度, 0)；cursorripple / fluidsimulation 只用 `.z`。
- `g_ParallaxPosition`：光标位置的平滑版本（depthparallax 用）。
- 相机视差（`general.cameraparallax*` + 图层 `parallaxDepth`）：位移 = 平滑后的 (光标 - 0.5)·amount·mouseinfluence，每个图层平移 (parallaxDepth + amount)·位移·场景宽度（与 LWE 相同）。平滑方面，LWE 的 `mix(d, 目标, clamp(delay·dt))` 在常见的 delay=0.1 下每帧只移动 0.3%，几乎不动，所以这里把 `delay` 当作秒级时间常数：k = 1 − e^(−dt/delay)。待有 Windows 对照时再校准。
- 这些值都做成了 PassPlan 的每帧 patch，并计入 `isDynamic`（读它们的 pass 不会被静态缓存）。

**App 里的光标跟踪**：壁纸窗口 `ignoresMouseEvents`（点击要落到 Finder 桌面上），所以：
- 场景：每帧轮询 `NSEvent.mouseLocation` 和 `pressedMouseButtons`，不需要任何权限。只有当光标下最上层的窗口是"桌面级"窗口（`NSWindow.windowNumber(at:)` 命中测试 + `CGWindowListCopyWindowInfo` 取 layer < 0，即我们的壁纸窗口或 Finder 的桌面图标窗口）时才算数；在 App 窗口、Dock、菜单栏上时，位置保持不动、按键视为松开。结果按位置缓存 0.25 秒。每块屏幕各有一份指针状态（含上一帧位置和视差平滑），绘制前换进共享的 renderer。
- 网页：用全局事件监听（鼠标事件不需要辅助功能权限）。点击转成真正的 NSEvent 交给 WKWebView（`mouseDown`/`mouseUp`），页面收到的是可信的 `mousedown`/`mouseup`/`click`。**WebKit 会丢掉非 key 窗口的 mouseMoved 事件**（桌面窗口永远不是 key 窗口），所以移动改为在页面里合成 `pointermove`/`mousemove`（元素变化时再发 over/out），合并到每 1/60 秒最多一次；这些事件 `isTrusted=false`，CSS `:hover` 不生效。只转发起始于桌面上的按下，以及与之配对的松开。
- 菜单里新增"Mouse Interaction"开关（默认开）。

**音频频谱**
- 采集：`WEAudio.SystemAudioCapture`，ScreenCaptureKit 的 `SCStream`，`capturesAudio`、排除本进程、48 kHz 立体声；同时要求一个 2×2、1 fps 的视频轨并直接丢弃（ScreenCaptureKit 总是要抓一块屏幕，不加 screen 输出会一直打日志）。需要**屏幕录制权限**（系统设置里显示为"屏幕与系统录音"），所以是菜单里可选开启的"Audio Visualization"，默认关；第一次开启时弹系统授权框，被拒时给出说明并可一键打开系统设置。只有在开启、未暂停、至少一块屏幕可见、且壁纸确实用到音频时才采集：场景要有读取 `g_AudioSpectrum*` 的 pass（第一帧预热后就知道），网页要注册了 `wallpaperRegisterAudioListener`（桥接脚本注册时会通知 App）。
- 分析：`WEAudio.SpectrumAnalyzer`，沿用 LWE 的刻度，这样数值范围和壁纸作者调参时一致：取最近 1024 个样本做 FFT（vDSP），第 b 个频段取 bin 2b+1…2b+2 中较响的一个（48 kHz 下每段约 47 Hz，64 段覆盖约 0–6 kHz），值 = 0.35·log10(功率)·(2 − e^((1 − b/(n−1)) − 0.5))，限制在 0…1；数值每 1/30 秒最多向目标移动 0.3。与 LWE 的不同之处：立体声（LWE 是单声道 8 位）、加 Hann 窗（功率按 LWE 无窗时的单音幅度换算，所以单音的读数相同）、用到全部 bin（LWE 跳着取）、32/16 段用各自的 bin（LWE 是后写覆盖）、不会出现负值、0.25 秒收不到音频就回落到静音（没有声音时 ScreenCaptureKit 可能不再送数据）。注意 LWE 的倾斜系数使最低频段最多只有约 0.66，pulse 默认的 audiobounds 0.5–1 只会被重低音轻微触发——与 WE 本体是否一致还需要 Windows 对照。
- 场景：`g_AudioSpectrum{16,32,64}{Left,Right}` 是 `float[n]` 数组，按数组步长写入每帧 patch。网页：`window.__we.audio(128 个值)` 以 30 Hz 推给所有监听者（左 0–63、右 64–127）；停止采集时推一次全零。

**顺带修复**
- 官方特效的 material/shader 放在 `assets/effects/<名>/` 下，WE 把每个这样的目录当作额外的资源根。`AssetLocator` 现在在找不到 `materials/effects/…`、`shaders/effects/…` 时会去对应的特效目录里找（"cursorripple_apply_force" → cursorripple）。现有样例都自带特效文件，所以只影响直接引用官方特效的场景（比如下面的测试场景）。
- 旧场景的 `constantshadervalues` 用的是 uniform 以前的英文标签（"Tint high"、"Pulse speed"），而现在的官方 shader 只认 material 名（`tinthigh`、`speed`）。这些旧标签保留在今天的本地化键里（`ui_editor_properties_tint_high`），所以在 material 名对不上时，忽略大小写、空格和下划线去匹配 material 名或标签。样例里有 124 处这种写法，都在特效预览里，但预览自带的旧 shader 本来就用旧标签当 material 名，所以输出不变。

**离线测试（wecli）**：`--pointer x,y[:x2,y2]`（y 向下）、`--press s`、`--frames N`（以 30 fps 渲染 N 帧，光标从第一个点移到第二个点，用来驱动 cursorripple 这类模拟）、`--audio 60,120:300`（左:右 的正弦音，各 0.25 幅度，经同一个分析器得到频谱）。网页同样支持：光标移动 + 点击、推一帧音频。
- 新增 8 个回归用例：xray / depthparallax 的光标位置、cursorripple / fluidsimulation 的拖动、网页 fixture 的鼠标 + 音频，以及自写的测试场景 `regression/fixtures/audiotest`（只引用官方资源：左声道 pulse 有声时变橙、右声道 pulse 变蓝、新版 xray 跟随光标；静音时两个 pulse 是黑的）。全套 131/131，连续两次都通过（模拟类用例是确定的）。

**实测**：3 个图层的 audiotest 场景在 App 里 3.7% CPU（音频关闭时）；网页 fixture 空闲时 0%。光标在别的 App 窗口上时被正确忽略。**未能实测**：桌面上真实的光标移动（没有替用户移动鼠标）、ScreenCaptureKit 的实时采集（本机这个进程环境没有屏幕录制权限，需要用户在系统设置里授权后再试）。另外 App 是临时（ad-hoc）签名，每次重新构建代码签名都会变，macOS 可能会要求重新授权——要等阶段三用固定的签名身份才能解决。

## 6.19 产品规划：壁纸库 + Steam 创意工坊（2026-10-22 讨论定稿）

**定位**：我们是"中间商"——让拥有 Wallpaper Engine 的用户在 Mac 上获得一致的体验，而不是让 WE 躺在库里。取舍标准是**便利、原生、与 WE 体验一致**；凡是让用户觉得"和在 WE 里不一样"的地方都算缺陷。
- 不运行 WE 本体（不用 Wine），不复用 WE 的界面代码；复用的是用户已购买的 WE 的**内容和授权**：用他自己的 Steam 账号下载 WE 的 `assets` 和创意工坊壁纸，由我们的引擎渲染。下载只有在账号拥有 WE 时才会成功，相当于天然的授权检查；我们不分发任何 WE 文件。
- 产品名沿用 mac-wallpaper，不用 WE 的商标，只写"兼容 Wallpaper Engine 壁纸"。没有 WE 的用户也能用视频和网页壁纸（不需要 WE 的资源）。

**Steam 登录**
- Steam 的新版登录接口（IAuthenticationService，客户端、手机 App、网页都在用）：程序发起登录会话并报上设备名 → 用户扫码（或输入账号密码后在手机上确认）→ 程序拿到长期有效的刷新令牌；Steam 会把它记为一台新的授权设备（"新设备登录"提醒），用户可以随时在 Steam 里移除。GameHub 这类软件内登录也只能是这套机制。
- App 内登录面板：默认显示二维码（用户平时就扫码登录），账号密码作为备选；设备名写清楚（如"mac-wallpaper on MacBook Pro"）；令牌存系统钥匙串，可随时退出。
- SteamCMD 不支持扫码，所以下载改用 DepotDownloader（基于 SteamKit2 的开源下载工具，GPLv2，作为独立程序调用）：支持 `-qr`、记住登录、按 ID 下载创意工坊内容、`-os windows` + `-filelist` 只下载 WE 的 `assets`。
- 目标是"扫一次码，全部打通"：同一个令牌既用于下载，也用来生成 steamcommunity 的网页登录状态（内嵌工坊页面、读取订阅列表）。需要验证令牌能否交给 DepotDownloader（可能要一个小补丁）以及网页 cookie 能否注入。

**订阅迁移**：读取用户的全部订阅（不下载即可拿到标题、预览、类型、大小、更新时间），显示成清单并给出汇总（"共 86 个，12.4 GB；视频 30、网页 8、场景 48"）和兼容性预测（视频/网页基本可用，场景下载后才能确定）。默认全选（WE 里订阅即安装），用户可以取消勾选或按"能用的"、"小于 1 GB"筛选。后台排队下载，小的和视频/网页优先，下完一个就能用一个。之后订阅、取消订阅自动同步。可选"从 WE 导入设置"（Windows 上 WE 的 `config.json`：每个壁纸调过的属性、每块屏幕的壁纸、播放列表、收藏）。

**更新**
- 壁纸：用公开接口批量查更新时间和内容版本号（启动时、之后每几个小时、打开壁纸库时），DepotDownloader 只下载变化的文件，默认自动更新。新版本先下载到暂存目录跑兼容性检查：不比旧版差就替换（旧版保留一段时间）；变差了（比如作者加了粒子）就继续用旧版并提示"有更新，但新版本在 Mac 上兼容性较差"，由用户决定。Steam 一般只提供最新版本，所以替换前必须在本地留一份。作者删除的壁纸保留本地副本并标记。
- WE 的 `assets`：记录本地版本，对比 Steam 上 WE 的最新版本，后台只更新变化的文件；先放暂存目录，用一批已安装的壁纸抽样检查，没问题再切换。shader 缓存按源码哈希，`assets` 变化会自动重新编译。
- 引擎：兼容性结果记录"壁纸版本 + `assets` 版本 + 引擎版本"，任何一个变化就重新检测；App 更新后可以提示"有 23 个壁纸现在可以用了"。

**前端**（风格待定，倾向原生 macOS；先做可交互原型再决定）
- SwiftUI（macOS 14+），个别地方桥接 AppKit；现在的 `WallpaperController` 是引擎，界面是外壳。先保持单进程：平时只有菜单栏图标，打开壁纸库窗口时出现在 Dock。索引用 SQLite，缩略图另有磁盘缓存。
- 布局参考"照片"和 App Store：侧边栏（已安装、收藏、播放列表、创意工坊、下载中、每块显示器）＋壁纸网格（悬停播放 `preview.gif`，兼容性角标）＋右侧检查器（用我们的渲染器实时预览、作者、标签、由 `project.json` 生成的属性面板、"应用到哪块屏幕"）。菜单栏：当前壁纸、快速切换、暂停。设置：开机自启、帧率、暂停规则（全屏 App、电池、遮挡）、鼠标、音频权限、Steam 账号和目录、缓存与存储位置。中英文界面。
- **兼容性角标**是我们特有、而且必须有的："完全支持 / 部分支持（缺粒子）/ 不支持"，默认筛选"能在 Mac 上运行"。
- 分类：复刻类型、题材标签、年龄分级（**默认隐藏成人内容**）、分辨率/宽高比、音频响应、可自定义、收藏、文件夹和常用排序；播放列表放第二批；预设、"官方认可"、Application 类型暂不做（后者只显示为不支持）。这些信息大多在本地 `project.json` 里，离线也能筛选。
- 首次引导：①"我在 Steam 上有 WE"（主推：登录 → 自动下载 `assets` → 订阅清单 → 进入壁纸库）；②"我在 Windows 上用过 WE"（选择拷过来的文件夹）；③"我只有视频/网页"（拖进来）。随时可以拖入文件夹、`.pkg`、视频、zip；权限按需申请；自带两三个我们自己做的演示壁纸，壁纸库不是空白页。

**其他**
- 把当前壁纸的一帧同步为 macOS 的桌面图片：调度中心、空间切换、截图里一致，菜单栏颜色协调，App 退出后桌面不突变。动态锁屏 macOS 不允许，只能用这张静态帧。
- 存储管理（视频壁纸动辄几 GB）：显示占用、清理、壁纸库可放到外接硬盘。
- App 更新用 Sparkle，另提供 Homebrew 安装；不付费公证时用户首次打开和更新可能需要右键 → 打开，这是便利性上最大的短板，有用户以后再评估。
- 可选的兼容性反馈：渲染异常时生成带工坊 ID、缺失功能和警告的 issue（不上传壁纸内容），用户越多测试样本越多。不收集使用数据。
- 开发分工：后端（解析、网络、下载/登录管道等）可以交给 Codex 实现，由我审查并跑回归；前端界面和所有文字（文档、界面文案、提交说明）不交给它。

**路线（取代阶段二的 M5–M7 顺序，渲染功能按兼容性统计排序）**
1. 可行性验证（需要用户扫一次码）：DepotDownloader 在 Mac 上运行、扫码登录、只下载 `assets`、下载几个壁纸（含 `.pkg`）、读取订阅列表、一次登录同时打通下载和网页、壁纸更新检查与增量下载、WE 本体版本检测。
2. 壁纸库基础：`.pkg` 作为资源根、本地扫描与索引、兼容性检查（`wecli survey`）、SwiftUI 壁纸库、按屏幕应用、设置、开机自启、同步系统桌面图片。
3. Steam 接入：扫码登录面板、订阅清单与迁移、后台下载队列、自动同步、内嵌工坊浏览、更新策略。
4. 体验一致：属性面板、播放列表、多显示器模式（每屏独立、复制、跨屏）、从 WE 导入设置、完整的筛选。
5. 渲染功能：按兼容性统计决定粒子、SceneScript、3D 模型的顺序。

## 6.20 Steam 接入可行性验证（2026-10-22）

**结论：一次扫码就能打通登录、网页、订阅读取和工坊内容下载。**

- **工坊元数据**：`ISteamRemoteStorage/GetPublishedFileDetails` 不需要 API key，一次批量查询即可拿到类型、分级、分辨率、功能标签（音频响应、可自定义、视频纹理、Puppet Warp、媒体集成）、大小、更新时间、预览图和内容版本号（`hcontent_file`）。`file_url` 为空，内容只能走 Steam 的 depot 下载。热门榜前 30：视频 17、场景 12、网页 1。
- **原生扫码登录**：直接用 HTTPS 调 `IAuthenticationService/BeginAuthSessionViaQR`（`platform_type=1`，即 SteamClient）→ 把 `challenge_url` 画成二维码 → 轮询 `PollAuthSessionStatus` → 用户手机确认后拿到刷新令牌（受众 `client, web, renew, derive`，约 7 个月有效）和访问令牌（`client, web`）。不依赖 SteamCMD/DepotDownloader，也不经过 Mac 上的 Steam 客户端。踩过的坑：二维码周围必须是不透明的白边（透明边在深色背景下显示成黑色，手机识别不了）。
- **网页登录状态**：`steamLoginSecure=<SteamID>%7C%7C<访问令牌>` 这个 cookie 能让 steamcommunity 认出是本人，成功读到"我的订阅"页面（22 项）。内嵌工坊页面同样用它注入 WKWebView 的 cookie 存储即可登录，不必在网页里再登录一次。
- **Web API 不认这种令牌**：带访问令牌调 `IPublishedFileService/GetUserFiles` 返回 401（Web API 只接受浏览器或手机 App 平台的令牌）。订阅列表因此改为：读社区页面，或者在 CM 连接上走同名的 unified 方法。
- **决定**：产品里做原生的 Steam 模块（Swift）：二维码/密码登录、令牌存钥匙串、CM WebSocket 连接 + 刷新令牌登录、unified 调用（订阅、工坊详情）、depot manifest 与分块下载（解密、解压、校验、续传）。这是纯后端，适合交给 Codex 按规格实现，由我审查。DepotDownloader、steam-user 只作为开发期的对照工具，不进产品。
- **工坊内容下载已走通**（用户同意下载一个 4 MB 的场景 2996321829）：同一个扫码令牌 → 连 CM 登录 → `PublishedFile` 详情拿到 `hcontent_file` → `ContentServerDirectory.GetManifestRequestCode` + 下载 manifest（工坊内容的 depot 就是 app 431960 本身）→ depot 密钥 → 从 CDN（`cacheN-<机房>.steamcontent.com/depot/431960/chunk/<sha1>`，HTTPS，这类缓存服务器不需要 CDN 令牌）下载分块 → 解密 → 解压 → 每块和每个文件的 SHA-1 都对得上。3 个文件 3.96 MB，约 20 秒（逐块串行，经用户当前的海外线路；Steam 认为出口 IP 在美国，分配的是美国机房）。产品里要并行下载多个分块。
  - 分块格式：先 AES-256-ECB 解出 16 字节 IV，其余 AES-256-CBC + PKCS#7 填充；解密后是 `VZa`（LZMA，结尾 `zv`）或 `VSZa`（zstd，结尾 `zsv`）。
  - 对照工具 steam-user 5.3 在 Node 26 上有两个问题，原生实现时要避开：自带的 HTTP 下载会截断响应；`@doctormckay/steam-crypto` 去填充时多删了字节，导致 `zv` 结尾被截掉。改为自己下载、自己解密后就正常了。
  - 下载的场景是 `scene.pkg`（PKGV0018）：用 `wecli pkg` 解包后能渲染出主体画面；缺两个粒子系统和一个文字图层——正好是兼容性检查要报告的内容。`.pkg` 直接作为资源根仍在路线图上。
- **测试样本规则**：只用分级为 Everyone 的壁纸；只下载测试真正需要的；下载前先告诉用户大小，由用户决定（也可以由用户从 Windows 电脑拷贝）。清单见 `regression/workshop/samples.txt`（21 项，已去掉 1 个 Questionable）。确认 WE 的 `assets` 能否只取 `assets/` 目录仍待验证（需要下载，先问用户）。

## 6.21 原生 Steam 模块 WESteam（2026-10-22）

按 `docs/specs/steam-module.md` 的规格由 Codex 实现（约 1,640 行代码 + 760 行测试），我审查、修 bug 并实测。没有第三方依赖：系统 zlib、liblzma（SDK 里只有 `liblzma.tbd` 没有头文件，`CSteamSupport` 里自己声明了用到的几个函数和结构体）、CommonCrypto、Security。

**内容**：扫码登录（二维码随 Steam 轮换自动更新）和账号密码 + Steam Guard 登录；令牌存钥匙串（服务名 `dev.macwallpaper.steam`）；访问令牌续期；网页 cookie；CM WebSocket 客户端（服务器目录、分包 `Multi`、作业编号与超时、心跳、刷新令牌登录、unified 服务调用、depot 密钥）；工坊详情、订阅列表（CM 优先，社区网页兜底）；工坊内容下载（manifest 请求码 → manifest → 解密文件名 → 分块并行下载、解密、解压、逐块与逐文件 SHA-1 校验、断点续传、暂存目录 + `renamex_np(RENAME_SWAP)` 原子替换、`.steam-manifest.json` 记录版本）；下载前报告大小并强制字节上限。`wecli steam login|whoami|logout|details|subs|download` 用于实测。

**实测（2026-10-22）**：扫码登录成功并存入钥匙串；订阅列表**直接通过 CM 的 `PublishedFile.GetUserFiles` 拿到**（22 项，类型和分级正确，不需要网页兜底）；下载 2996321829（3.96 MB 网络流量）得到的 3 个文件与昨天验证脚本下载的逐字节一致；`--max-mb 1` 时只读取 manifest 就按大小拒绝。单元测试 29/29，渲染回归 131/131。

**审查和实测中修掉的问题**
- 钥匙串读取报 `-50`：macOS 文件型钥匙串不允许 `kSecReturnData` 和 `kSecMatchLimitAll` 一起用，改为先列属性、再按条目取数据（Codex 的沙盒里这个测试被跳过，所以没发现）。
- `URLSessionWebSocketTask` 默认只收 1 MB 以内的消息，CM 的 `Multi` 包可能更大，会表现为随机断线；上限改为 64 MB。
- 扫码后登录被 Steam 结束（EResult 9）：扫码那一刻轮询结果会带 `new_client_id`，照 steam-session 改用它之后，下一次轮询就"找不到"。改为一直用最初的 `client_id`（与验证脚本一致）后登录成功。
- manifest 里加密文件名的 base64 带换行，Foundation 的严格解码会失败（Node 会跳过）；改为忽略未知字符，并像参考实现一样在第一个 NUL 处截断。测试数据已改成 Steam 的格式。

**对界面的要求（记下来，做登录面板时要满足）**
- 二维码约每 30 秒更换一次，旧码立即失效，手机上会显示"登录请求已失效"：面板必须实时显示最新的码，并在扫码后提示"请在手机上确认"。
- 开发版是临时签名，每次重新构建后 macOS 可能弹窗询问是否允许读取钥匙串条目；正式签名的 App 不会反复询问。

**尚未做**：~~zstd 分块~~（已支持，见 §6.25）；账号密码 + Steam Guard 登录只有离线测试，未实测；断线自动重连；WE `assets` 的下载（app 431960 本体 depot，需要先确认大小）。

## 6.22 壁纸库后端：直接读 .pkg、本地索引、兼容性检查（2026-10-22）

按 `docs/specs/library-backend.md` 由 Codex 实现（Codex 这次跑在 fast 档——用户的全局配置是 `service_tier = "priority"`；以后每次调用都在命令行改成标准档），我审查并实测。

- **直接读 `scene.pkg`**：查找顺序为项目文件夹 → `scene.pkg` 内的文件 → WE assets → 官方特效目录。pkg 用内存映射打开，读出的数据是映射区的切片，不会把整个包读进内存；大小写不匹配时按 Windows 习惯不区分大小写再找一次。只有确实需要真实文件的地方（视频、网页）才把单个条目解压到 `~/Library/Caches/MacWallpaper/pkg/<指纹>/`。shader 的 `#include` 不再依赖文件路径。实测：工坊壁纸 2996321829 直接从 pkg 渲染，结果与先解包再渲染**逐字节一致**；回归 131/131 不变。
- **本地索引**（新模块 `WELibrary`）：从 Mac 版 Steam 的 `libraryfolders.vdf`（自写 VDF 解析器）找工坊目录，加上我们自己的下载目录和用户文件夹；每个壁纸记录标题、类型、分级、标签、预览、大小、是否音频响应、是否有可调属性；索引以 JSON 原子写入，按文件夹指纹、检查器版本和 assets 指纹增量更新。没有 `type` 的旧项目按主文件扩展名推断（例：官方的 "Sheep" 是 Unity 的 `.exe`，归为应用）。
- **兼容性检查**：静态检查识别粒子、文字、3D 模型、Puppet Warp、声音、灯光、SceneScript、视频纹理、缺失的特效和资源；深度检查真正渲染一帧 256×144，捕捉 shader 编译失败。状态分"支持 / 部分支持 / 不支持 / 需要 WE assets"。`wecli library scan` 输出每个壁纸的结果和汇总，汇总里每个缺失功能给两个数："用到它的壁纸数 / 它是唯一缺口的壁纸数"（后者才是"补上它就能完全支持"的数量）。
- **样例上的结果**（WE 自带的演示壁纸 + 你的 1 个工坊壁纸 + 我们的测试场景，共 22 个，深度检查约 10 秒）：支持 7、部分支持 7、不支持 8。缺失功能（用到 / 唯一缺口）：3D 模型 9/4、粒子 7/0、SceneScript 5/2、文字 2/0。演示壁纸偏重 3D，代表性不足；决定先做粒子还是 3D 模型之前，需要用你真实的订阅再统计一次（下载前先报大小）。

## 6.23 壁纸库界面第一版（2026-10-22）

SwiftUI（macOS 14），原生 macOS 风格，作为风格讨论的基础；代码在 `Sources/WallpaperApp/Library/`，全部由我写（前端不交给 Codex）。

- **窗口**：菜单栏"壁纸库…"（⌘L）打开；还没设置过壁纸时启动就打开（`--library` 也会打开）。窗口打开时 App 出现在 Dock 和 ⌘Tab 里，关掉后回到只有菜单栏图标。`NSHostingController.sizingOptions = []`，否则窗口会被缩到内容的最小尺寸、工具栏按钮挤进溢出菜单。
- **布局**：侧边栏（全部 / 场景 / 视频 / 网页；来源：Steam 创意工坊、已下载、用户添加的文件夹，各带数量；底部"添加文件夹…"）＋ 16:9 卡片网格（预览、类型图标、标题、兼容性标记；悬停时 GIF 预览动起来；双击设为壁纸；右键菜单）＋ 右侧检查器（大预览、类型和分级、"设为壁纸"、"在这台 Mac 上"用白话列出缺什么及数量、标签、大小/修改日期/创意工坊 ID/位置）。工具栏：显示选项（排序；只显示能在 Mac 上运行的；显示"可疑""成人"分级）、刷新、检查器开关、搜索（标题、标签、创意工坊 ID）。
- **默认筛选**：隐藏"不支持"的壁纸和非"所有人"分级的壁纸，网格底部说明有多少被隐藏。
- **数据**：打开时先做快速的静态扫描让网格马上有内容，再在后台做渲染检查更新兼容性；索引存在 `~/Library/Application Support/MacWallpaper/library.json`。预览图用 ImageIO 缩成 480 像素缓存，不为小卡片解码整张大 GIF。
- **语言**：代码里是英文原文，`Resources/zh-Hans.lproj/Localizable.strings` 提供简体中文（包括菜单栏菜单和音频授权提示）；`scripts/build.sh` 把翻译拷进 .app，`Info.plist` 声明 en 和 zh-Hans。中文系统下显示中文。
- **检查方式**：用户拒绝了"电脑操控"权限，所以加了调试用的环境变量：`MW_LIBRARY_SNAPSHOT=<png>` 让窗口打开 7 秒后把自己画进 PNG，`MW_LIBRARY_SELECT=<标题>` 预先选中一个壁纸。不需要屏幕录制权限。

**还没做**：Steam 登录面板和订阅迁移、内嵌创意工坊浏览、每块屏幕分别选壁纸、属性面板、收藏和播放列表、首次引导、检查器里的实时预览、"设为壁纸"之后的加载状态和失败提示。

## 6.24 Steam 登录面板、订阅导入、下载队列（2026-10-22）

代码在 `Sources/WallpaperApp/Steam/`，全部由我写。

- **登录面板**：默认二维码（白色静区，每次轮换即时刷新，扫码后提示"请在手机上确认"），账号密码作为备选；登录后侧边栏出现 Steam 一节（账号、订阅数）。
- **订阅导入**：订阅清单默认全选，显示大小、类型和汇总；下载在后台排队，工具栏的下载按钮弹出进度，失败项可重试。
- **共享连接**：同一台 Mac 的所有 CM 登录共用一个机器身份，第二条连接会把第一条顶掉（EResult 34），表现为导入面板和下载队列互相踢下线（错误 5 / 34）。改为全 App 共用一个 `SteamConnection`，会话丢失（5/20/34/48、断线、超时）时自动重连并重试。
- **钥匙串**：临时签名的开发版每次重新构建后，系统可能拒绝读取之前保存的登录；此时显示原因和"重新登录"按钮，而不是一直转圈。用固定的自签名证书签名可以根治（需要用户输入密码信任证书，未做）。
- **实测**：扫码登录、订阅列表、两个场景壁纸的下载（约 49 MB）都成功。

## 6.25 粒子系统、真实壁纸里的 shader 问题、WE assets 下载（2026-10-23）

用户的 16 个工坊下载里：视频 3 个支持，场景 12 个部分支持、1 个不支持。缺的功能（用到它的壁纸数）：粒子 10、SceneScript 9、文字 7、声音 5、shader 编译失败 4、视频纹理 1。按这个顺序先做粒子和 shader，三件事按 `docs/specs/particles.md`、`shader-compat.md`、`steam-assets.md` 由 Codex 在三个 worktree 里并行实现（标准档，不开 fast），我审查、实测后合并。

**粒子**（`Sources/WERender/Particles/`，移植自 linux-wallpaperengine 的 CParticle，GPLv3）
- 球形/盒形发射器，全部常见的初始化器和运算器，sprite 与 spritetrail，精灵图动画，控制点（含跟随鼠标），每个对象的 `instanceoverride`，`starttime` 预模拟，静态子系统。
- 模拟在 CPU 上确定性运行（按对象 id 和子系统序号设种子；回到更早的时间就从 0 按 1/30 秒重算），离线渲染可以做回归；顶点在 CPU 上组装（每顶点 17 个 float），三缓冲 `MTLBuffer`，用 `genericparticle` 的 `GS_ENABLED=0` 路径。代价约每 1000 个粒子每步 0.2 ms。
- 审查实测时修的问题：子系统的文件路径写在 `"name"` 里而不是 `"particle"`；`R8`/`RG88` 精灵图要像 WE 的 `ConvertTexture0Format` 那样展开成 `(1,1,1,r)` / `(r,r,r,g)`，否则烟雾变成黑块。
- 未做（检查器会写明）：事件触发的子系统（eventfollow/eventspawn）、ropetrail、自定义粒子 shader（如演示壁纸 "Shimmering Particles"）。
- 回归：新增自己的测试场景 `regression/fixtures/particletest`（WE 自带的三个示例粒子：普通、湍流加实例覆盖、跟随鼠标），渲染 1 秒和 3 秒两帧，两次渲染逐像素一致。

**varying 对齐**（`ShaderCompiler.alignVaryingLocations`）：glslang 按各阶段自己的声明顺序给 varying 编号，顶点和片元声明顺序不同时，Metal 会因为位置不匹配拒绝建管线（粒子 shader 首先碰到），或者更糟：位置凑巧匹配但对应错了变量、片元读到 0。现在片元输入按同名变量取顶点阶段的位置，对不上的移到空闲位置并由顶点阶段补 0。副作用是修好了已有的三个回归用例：waterripple 特效以前读到的是 0（现在才真正生效），reflection、shine 两个场景里的雪粒子现在会画出来；逐一看过后更新了参考图。

**shader 兼容**（`Sources/WEShader/ShaderCompat.swift`）：只在第一次编译失败后才改写源码重试，原来能编译的 shader 保持逐字节不变。改写项：CRLF 和 COMBO 写法、bool 参与算术、非常量初始化的全局 const、float 的 `%`（按 fmod 语义）、`mix` 的标量广播。WE assets 加演示壁纸里的 shader 906 个能编译 897 个；Zero Two 等壁纸现在能正常渲染。

**WE assets 下载**（`Sources/WESteam/WEAssets.swift`，`wecli steam assets`）：没有 Windows 电脑的用户拿不到 WE 的 `assets` 文件夹，所以从用户自己的 Steam 账号下载 app 431960 的 Windows depot，只取其中的 `assets/`。先通过 PICS 读 app 信息、选 depot、取 manifest，下载内容前就给出文件数、下载大小和磁盘大小（`--plan`）；下载沿用工坊下载的机制（并行、断点续传、SHA-1 校验、原子替换、字节上限），完成后在旁边写一份收据，之后只比较 manifest 编号就能判断有没有更新，有更新只下改动的文件。实测（2026-10-23）：
- `--plan` 约 22 秒：两个 depot（431961、431966），2,935 个文件，下载 38.2 MB，解压后 79.5 MB；文件数与已有的 assets 完全一致。
- 真正下载时，下了 46 个文件就遇到 zstd 分块（`VSZa`）。macOS 自带的 Compression 框架没有 zstd，于是经用户同意，把官方 zstd v1.5.7 只含解压的部分（31 个文件，926 KB，压缩传输 227 KB，BSD 许可）原样放进 `ThirdParty/zstd`，由新的 `CZstd` 目标编译（`ZSTD_DISABLE_ASM`）。`VSZa` 的封装按 steam-user 处理：头部 4 字节 + CRC + zstd 帧 + CRC、原始大小、4 字节填充、`zsv`；解压后再核对 CRC 和大小。
- 之后断点续传完成全部 2,935 个文件（用户网速约 30 KB/s，用了 40 分钟），与用户从 Windows 拷来的 assets 用 `diff -r` 比较**完全相同**；用下载的 assets 渲染的回归用例与参考图逐像素一致。
- 下载位置就是 App 将来用的 `~/Library/Application Support/MacWallpaper/WEAssets/assets`，收据在旁边的 `assets.steam-assets.json`。更新检查只有离线测试（实测要再取一次 manifest，等 WE 真有更新时再做）。
- wecli 扫码登录第一次在扫码后报 EResult 27（过期），重来一次、扫完立即确认就成功了。

**下一步候选**：文字（时钟）、SceneScript、声音对象——都要改 `Scene.swift` 和 `SceneRenderer.swift`，所以放在粒子合并之后；App 里的 WE assets 下载和首次引导。

## 6.26 文字、对象层级、SceneScript（2026-10-23）

**调查**：用户 16 个下载里有 57 个文字对象，几乎全部由脚本给出内容（时钟、日期、歌名）；这些壁纸一共用了约 100 个不同的 SceneScript，除了文字，还控制可见性、颜色、位置、缩放和特效参数。另有 95 个对象挂在父对象下（图片、文字、粒子，以及只有变换的"组"对象），之前渲染器不支持层级。

**对象层级**（我做）：子对象的变换 = 父对象世界变换 × 自身变换，祖先隐藏则子对象也隐藏。WE 会省略等于默认值的字段：顶层对象没写 origin 时在画布中心，子对象没写时在父对象原点（"Girls Band Cry"的主图之前因此缩在左下角）。

**文字**（我做，`Sources/WERender/Text/`）：
- 用 CoreText 把字符串画成 8 位覆盖率纹理，交给 WE 自己的 `materials/fonts/basefont`（`font` shader，`g_Color4` = 颜色和透明度）画到刚好包住文字的框里；文字层上的特效和图片层一样工作。
- 尺寸规则从 49 个真实文字对象的 `size` 反推并完全吻合：WE 按 300 DPI 栅格化（1 pt = 300/72 像素），框 = 行数 × (ascent + descent + leading) 和最宽一行，四周加 `padding`。
- 支持项目字体、WE 自带字体、`systemfont_*`（中日文自动回退）、多行、`limitwidth` 换行、`limitrows` 行数限制和省略号、对齐。
- **未验证的推断**：对齐与原点的关系文档没写，按真实布局推断为 right = 文字在原点左侧结束、top = 文字在原点上方；居中（最常见）不受影响。`opaquebackground` 和 MSDF 字体效果还没做（遇到时记一条说明）。

**SceneScript**（Codex 按 `docs/specs/scene-script.md` 实现 `Sources/WEScript`，我审查并接入渲染器）：
- JavaScriptCore；ES module 由词法转换处理；`engine`、`thisLayer`、`thisObject`、`thisScene`、`shared`、`input`、`localStorage`、`console`、WEMath/WEColor/Vec2-4、脚本属性（可绑定用户属性）、按脚本时间运行的定时器、鼠标和媒体事件；单个脚本出错只停用它自己。
- 103 个真实脚本中 102 个能加载、101 个能跑完更新（失败的那个依赖 `createLayer`）；100 个脚本每帧约 0.28 ms。
- 审查时改的：`localStorage` 改为最多每秒写一次盘（有脚本每帧都写）；`WEColor` 的色相改为 0–1（WE 文档写"normalized"，真实脚本也这么用；参考实现用的是度数）。
- 接入：场景为每个对象保留可变的节点（变换、可见性），父对象被脚本移动时子对象跟着动；脚本可改文字及其排版、可见性、位置/缩放/角度、透明度、颜色、亮度、特效开关和特效常量（`thisObject` 即特效材质）。被改动的层只重写 uniform 模板（不重建管线），并跳过静态层缓存；被脚本隐藏的特效在渲染时跳过。
- 离线渲染：`wecli render --clock yyyy-MM-ddTHH:mm:ss` 固定脚本看到的时间；回归脚本统一用固定时间（razer_bedroom 的霓虹灯是按时间变色的彩虹，之前参考图里是静态颜色）。
- 还没做：粒子的 `instanceoverride`、`createLayer`/`destroyLayer`、`sortLayer`、纹理动画控制（现在给脚本一个单帧的替身）、媒体信息（现在没有"正在播放"事件，相关文字保持默认值）。

**回归**：新增 `texttest`（2 例）和 `scripttest`（4 例：时钟和日期、绑定用户属性的脚本属性、移动带子对象的组、通过 `shared` 控制可见性、特效常量和特效开关、定时器），共 139 例。

**结果**（深度检查，用户 16 个下载）：完全支持从 3 个（只有视频）增加到 10 个，场景 13 个里 7 个完全支持。剩下的缺口（用到 / 唯一缺口）：声音 5/2、粒子 2/0、SceneScript 2/1、视频纹理 1/0。"Persona 3 Reload 昼夜"画面整体放大的问题在脚本之前就存在，另查。


## 6.27 声音对象（2026-10-23）

**调查**：用户 5 个壁纸和自带的 dino_run 共有 31 个声音对象：音乐和音效，格式为 mp3、ogg、wav；`playbackmode` 有 loop（按顺序循环）、random（随机播放一首，结束后停 `mintime`–`maxtime` 秒）、single（脚本调用一次播一次）；`startsilent` 的声音等脚本 `play()`；音量常绑定用户属性（"音乐音量"）。

**实现**（我做，`Sources/WERender/Sound/SceneSound.swift`）：
- `SceneSoundPlayer` 用 AVAudioEngine，每个声音对象一个 player node，文件按需从磁盘流式读取（pkg 里的文件解出到缓存）。loop 在上一首读完时就排下一首（无缝），random 在播完后等随机时长，single 播完即停。所有状态在一个串行队列上，任意线程都能调用。
- macOS 15 的 AVFoundation 自带 Ogg Vorbis 解码，不需要第三方库（macOS 14 可能不支持，打不开时记一条说明）。
- 有些创意工坊壁纸把 Ogg 文件存成 ".mp3"，AVFoundation 按扩展名选解码器会失败：按文件头判断真实格式，扩展名不对时通过缓存里一个扩展名正确的符号链接打开。
- 脚本：`thisLayer.play()/stop()/pause()/isPlaying()` 和 `volume` 接到播放器（SceneScript 运行时里原来是警告桩）。
- App：菜单新增"壁纸声音"（关 / 25% / 50% / 100%，默认 100%，与 WE 一致）；只在壁纸运行且至少一块屏幕可见时播放，暂停、锁屏、被全屏应用盖住时停，切换壁纸时旧声音停止。顺带修了渲染器与脚本引擎的循环引用（否则换壁纸后旧渲染器和它的声音不会释放）。
- `wecli sound <壁纸> --assets <目录> [--seconds N]`：离线混音（AVAudioEngine 手动渲染模式），每秒打印电平和正在播放的对象，期间每秒跑一次脚本——不用扬声器就能验证。

**验证**：离线混音测试 6 项（循环、静默启动后 play、stop、音量、single 只播一次、扩展名错误的文件）。真实壁纸：Zero Two、Honkai、"Alone. and Sad." 的音乐正常；Persona 3 昼夜由脚本启动了歌单里的一首加列车环境音；Persona 3 音乐播放器的随机歌单在识别出伪装成 mp3 的 Ogg 后正常播放；dino_run 的跳跃、金币音效只在游戏脚本触发时播放。**还没在真实扬声器上听过**（没有在用户机器上自动启动会放音乐的 App）。

**结果**：用户 16 个下载中完全支持 12 个（上一节为 10 个）。剩余缺口：粒子 2/1、SceneScript 2/1、视频纹理 1/1。


## 6.28 用户实测后修的问题（2026-10-23）

- **特效遮罩全部失效**（Zero Two、Bronya 整张图在晃）：WE assets 里 273 个 shader 用 CRLF 换行，Swift 把 "\r\n" 当成一个字符，按 "\n" 切行时整个文件只算一行，编译路径以外读到的 uniform 注释全丢了，其中包括"有遮罩贴图就打开 MASK 组合"。修复后只在遮罩区域起作用；12 个官方特效预览的参考图随之更新（shake、cloudmotion、spin、shimmer、iris、shine，都比以前更合理）。Zero Two 之前的 varying 数组长度不一致的链接错误，根源也是它。
- **场景脚本收不到鼠标**：每帧对比轮询到的按键状态，生成 enter/leave/move/down/up/click。事件发给光标下**所有**可见图层（包括透明的），不只是最上面那层：P3R 音乐播放器每个按钮由透明悬停区、高光和歌名三层叠成，只发给最上层时点击全被透明层接走。全屏合成层不参与命中。`wecli sound --click x,y@s` 可以离线模拟点击；用户实测能点歌。
- **菜单栏图标被刘海挡住**：再次打开 App（访达、启动台、聚焦）会显示壁纸库。
- **"你的名字"左边被裁**：不是 bug，1440×932 屏比 16:9 视频更方，铺满时左右各裁约 6.5%（WE 默认也铺满）。待做：每个壁纸可选"完整显示 / 铺满"。
- 用户习惯开着"点按墙纸以显示桌面"，与壁纸点击不冲突：第一下推开窗口，桌面露出后再点。


## 6.29 视频纹理、显示方式、粒子第二部分（2026-10-23）

三项由 Codex 在三个 worktree 里并行实现（用户同意从这次起用 fast 模式），我审查、合并、实测；显示方式的界面由我做。

- **视频纹理**（`docs/specs/video-textures.md`）："Persona 3 reload 音乐播放器"的噪点背景是一个 60 MB 的 MP4：`TEXB0003` 容器、格式 -1、flags 带视频位，`Tex.isVideo` 认得，解码路径却按 RGBA 原始像素读。现在这类 payload 走 `VideoSource`（AVAssetReader / VideoToolbox），每个视频一个解码器、多处共享，每帧零拷贝换上，采样它的 pass 在绘制时按名字取纹理；payload 按内容哈希缓存到 `~/Library/Caches/MacWallpaper/video-textures/`。自制回归素材是 16×16 的红/蓝两秒视频。
- **显示方式**（`docs/specs/content-mode.md`）：渲染器有 `contentMode`（铺满 / 完整显示 / 拉伸）和黑边颜色；场景的投影、鼠标映射、粒子、脚本命中统一跟随，完整显示时黑边区域不响应鼠标。壁纸库检查器新增"显示方式"，按壁纸保存，当前壁纸改动立即生效（网页壁纸不显示）。SwiftUI 自带同名的 `ContentMode`，界面代码里写全模块名。
- **粒子第二部分**（`docs/specs/particles-2.md`）：事件子粒子（出生、死亡、跟随）、绳状拖尾（WE 自带 `genericropeparticle` 的非几何着色器路径少一对括号，加载时在内存里修正）、脚本读写 `instanceoverride`（数量、频率、透明度、颜色等）。"Alone. and Sad." 的流星现在带拖尾。
- 审查时：删掉 Codex 写进测试素材的两份 README（约定文档不由它写）；兼容性检查器版本合并后为 7。

**结果**：回归 153 例、单元测试 153 项全部通过；用户 16 个下载**全部完全支持**。


## 6.30 属性面板、首次设置与 WE 文件、订阅同步（2026-10-23）

后端三项由 Codex 在三个 worktree 里并行实现（`docs/specs/live-properties.md`、`assets-manager.md`、`subscription-sync.md`），界面和流程由我做。

- **属性**：解析 project.json 的属性（开关、滑块、颜色、下拉、文本、说明文字、分组）和 WE 的条件表达式；按壁纸保存用户的值（`~/Library/Application Support/MacWallpaper/properties.json`）；改动实时作用到正在运行的场景（可见性含条件、变换、颜色、透明度、文字、特效开关和常量、音量、粒子参数、背景色、bloom），需要换 shader 或纹理的改动整批不应用、由 App 重新加载；网页壁纸把新值推给页面。检查器新增"设置"一节：原生控件、按条件实时显隐、"恢复默认"；WE 的本地化键（如 `ui_browse_properties_scheme_color`）翻成中文，作者写的 HTML 去标签、链接可点。
- **审查中修的 bug**：图层的混合模式总在最后一个 pass 上，特效被（脚本或属性）隐藏再显示时，那个 pass 的混合模式变了，缓存的绘制计划却还是旧的，透明度被乘两次；绘制计划的缓存键现在包含混合模式。`scripttest.frames` 的旧参考图就是带着这个 bug 拍的，已更正（与一开始就开着特效的 t3 逐像素一致）。实时修改与重新加载现在逐像素一致。
- **WE 文件**：`AssetsManager` 检测用户选择的文件夹或我们下载的副本（结构校验 + 回执），先报大小再下载，装进临时目录后原子替换，更新只下改动部分，失败原因是结构化的，文案在 App 里。界面："Wallpaper Engine 文件"表单（菜单栏同名菜单项）、壁纸库缺文件时的提示条（"获取文件…"）、首次使用的"设置壁纸"清单（登录 Steam → 获取文件 → 选择订阅；登录完成后自动回到清单）。
- **订阅同步**：打开壁纸库、账号可用时读取订阅（只取元数据）与下载比对：新订阅、有更新、已取消订阅。更新**不自动下载**（用户流量有限），侧边栏显示"更新 N 个（大小）"；点了才走"暂存 → 新旧版本都做兼容检查 → 不变差才原子替换、保留上一版本"的流程，变差就暂缓。检查器"更新"一节：暂缓原因、"仍然安装"/"保留当前版本"、"恢复上一版本"、"已不在你的订阅中"。
- **结果**：回归 156 例、单元测试 177 项全部通过。界面截图这次没拍成：开发版重新编译后读取 Steam 登录会弹钥匙串授权，弹窗挡住了 App，等用户点允许。固定签名身份可以根治（需要用户输入一次密码信任证书）。


## 6.31 后续规划（2026-10-23 讨论）

**现状**：用户的 16 个下载全部完全支持；Steam 登录、WE 文件、订阅导入与安全更新、属性面板、显示方式、首次设置都已完成。开发版用用户的 Apple Development 证书签名（个人团队，2027-10-23 到期），重新编译不再弹钥匙串。

**用户的决定**
- 目标：**开源公开发布**。
- 日常功能先做：**App 内浏览创意工坊**、**设置窗口与开机自启**。（收藏/播放列表、"正在播放"、多显示器排在后面；用户目前只有一块屏幕。）
- 兼容性扩面：先读热门壁纸的元数据做统计（几 MB），再提出带大小的抽样下载清单，由用户决定。
- 流量：10 MB 以下的下载不用再问。

**第一批（并行）**
1. **创意工坊浏览**（后端 Codex，界面我）：原生界面，不嵌网页。通过已有的 CM 会话调用 `PublishedFile.QueryFiles`（排序：热门、最新、评分、趋势；关键词；类型和题材标签；分级默认只看"所有人"）、`Subscribe`/`Unsubscribe`；结果显示在和壁纸库同风格的网格里，附兼容性预测（视频/网页基本可用，场景看功能标签）；订阅后进入下载队列（先显示大小）。预览图走 Steam 的缩放参数只取小图，按需加载，省流量。
2. **设置窗口**（我为主，后端小件给 Codex）：开机自启（`SMAppService`）、暂停规则（全屏 App、使用电池、低电量模式、屏幕被遮挡）、帧率、鼠标、声音、音频可视化权限、Steam 账号、WE 文件、下载位置与存储占用/清理、缓存。现在分散在菜单栏里的选项收进来，菜单栏只留常用的。
3. **兼容性统计**（后端 Codex）：`wecli workshop survey`：按热门度读取前若干个场景壁纸的元数据和标签，汇总可能用到的功能；结合已有的兼容性检查，给出"补上哪个功能能多支持多少壁纸"的排序，以及一份带大小的抽样下载建议。

**第二批**：根据统计做渲染功能（大概率是 3D 模型）；收藏与播放列表；同步系统桌面图片；"正在播放"（先验证 macOS 15.4 以后的可行性）。

**发布准备（与第二批并行）**：README（中英文）、第三方许可证清单（glslang、SPIRV-Cross、zstd、linux-wallpaperengine 移植部分、steam-user 参考）、App 图标、自带演示壁纸（我们自己做）、GitHub Actions（编译和不需要 GPU 的测试）、Sparkle 自动更新、Homebrew。**待用户决定**：是否买 Apple Developer Program（每年 99 美元）做 Developer ID 签名和公证——不买的话，别人第一次打开要右键→打开，这是公开发布时便利性上最大的短板。


## 6.32 创意工坊浏览、预设与用户贴图（2026-10-24）

**浏览**：资料库侧栏「浏览创意工坊」，排序（趋势、热门等）、类型、搜索；搜索框和工具栏的刷新、显示选项跟随当前页面。订阅即下载（与 WE 一致），取消订阅只改 Steam 上的订阅，已下载的副本留在资料库。

**预览省流量**：Steam 的图片 CDN 只有带 `impolicy=Letterbox` 时才认 `imw`/`imh`（JPEG 307 KB → 30–75 KB）；GIF 从不缩放（0.5–1 MB）。预览按 64 KB 分段读取（CDN 支持 Range），GIF 只读到前几帧为止，自己解析 GIF 块找帧边界并补上结尾字节；首帧接近纯色（淡入）时用已到手的最后一帧。一页 30 个预览约 1 MB（原先 5–10 MB）。

**预设**：预设的 `project.json` 没有 `file`，用 `dependency` 指向底座壁纸，`preset` 存属性值，`files/` 放自己的图片；Steam 把底座列为子项（QueryFiles `return_children`）。
- 资料库按创意工坊 ID 找底座，预设沿用底座的类型、功能和兼容性检查；找不到底座时标为缺少「此预设所修改的壁纸」。预设没有 `workshopid`，ID 取自下载文件夹名。
- 播放时加载底座文件夹，属性 = 预设值（`files/…` 换成绝对路径）+ 用户改动；设置面板显示底座的属性，默认值为预设值。启动时资料库还没扫描，就按文件夹名在各个根目录里找底座。
- 订阅预设时同时订阅并下载底座（与 WE 一致），按钮显示两者合计大小。

**用户贴图**（`scenetexture` 属性，材质的 `usertextures`）：值为文件路径时替换对应槽位的贴图，支持静态图、GIF/APNG 动图（按场景时间循环，帧按顺序一次解码、总量限 128 MB）和视频；文件缺失时保留原贴图；改这个属性会重新加载场景。设置面板里这类属性可以「选择…」图片、动图或视频，也可以清除恢复原图。

## 6.33 兼容性统计结果（2026-10-24，创意工坊趋势前 100 个场景，仅"所有人"）

**读取方式**：Steam 内容服务器不认 Range，取消下载后服务器还会多推几百 KB；改用明文 HTTP（分块本身是加密的）+ 小接收缓冲区，边收边解密解压，读到 PKG 文件表和 `scene.json`（总在包里第一个）就断开。每个壁纸约 116 KB，100 个共读包内容 12 MB；加上清单和元数据，网卡上约 24 MB（事前只估了包内容的 12 MB，漏算了清单）。

**结果**（"唯一阻碍"＝只差这一项就能完整运行）：

| 功能 | 使用的壁纸 | 唯一阻碍 | 现状 |
|---|---|---|---|
| 木偶动画（puppet warp，`.mdl` 骨骼网格） | 10 | 10 | 不支持 |
| 灯光对象 | 3 | 2 | 不支持 |
| 3D 模型 | 1 | 0 | 不支持 |
| 自定义着色器 | 85 | — | 大多能编译，个别未知 |
| 粒子 / 文字 / 脚本 / 声音 / 字体 | 61 / 47 / 46 / 27 / 36 | — | 已支持 |

15 个未能判断：包里的 `scene.json` 太大，超出单次读取上限（都是复杂场景）。

**结论**：第二批渲染功能先做**木偶动画**（前 100 个场景里 10% 只差它），其次灯光；3D 模型很少见，往后放。

## 7. 待确认
1. 最低系统版本：建议 macOS 14（SMAppService、ScreenCaptureKit 音频成熟）。
2. 工程形态：目前采用 SwiftPM + 生成 .app 的脚本（§6.11）；到需要正式签名分发时，再考虑加一个 Xcode 工程来包装。
3. ~~webm 处理方式~~：已定，进程内解析 + VideoToolbox 硬件解码（见 §6.12）。
4. 补充测试素材：暂无（用户机器上没有 `.pkg` 壁纸）；视频素材用 ffmpeg 自己生成。
