# SpektraCam

**v1.1 · iPhone · iPad · iOS 17+**

此 App 是基于 Andrea Volpato 的 [spektrafilm][upstream] 原生移植的 iPhone 与 iPad 照片编辑器与相机。免费、开源，支持简体中文与英文。

A free, open-source photo editor and camera for iPhone and iPad built on a native port of Andrea Volpato’s [spektrafilm][upstream], localized in English and Simplified Chinese.

## 功能 / Features

从“照片”或“文件”导入，保留原始文件并单独保存编辑。支持裁切、胶片与印相模拟、调整、颗粒、光晕、柔光、暗房装裱，以及 JPEG / PNG / 原始 RAW 导出。
编辑器与暗房界面随可用空间调整：竖向时控制面板位于照片下方；横向时（iPad、iPhone Duo 及 iPhone 横屏）控制面板位于照片右侧，工具栏纵向排列在最右侧。

Import from Photos or Files while keeping originals separate from edits. Crop, simulate film and prints, adjust color and tone, add grain, halation and diffusion, frame prints in Darkroom, and export JPEG, PNG or original RAW.
Editor and Darkroom workspaces adapt to available space: stacked vertically on narrow screens, or side by side with a trailing tool rail on wide screens.

内置相机：支持 DNG（Apple ProRAW / Bayer RAW）以及常规 HEIC / JPEG 拍摄。普通 iPhone 拍摄时锁定竖屏界面，iPad 与 iPhone Duo 支持自由旋转并保持统一的底部快门与曝光操控布局。
也可跳过 spektrafilm 管线，直接使用最多两个独立混合的 `.cube` 3D LUT（适用于编码后的 sRGB 图像）。

Built-in camera: captures DNG (`Apple ProRAW` / `Bayer RAW`) on RAW-capable lenses and `HEIC` / `JPEG` on non-RAW phones, iPads and secondary lenses. Standard iPhones lock the display to portrait while shooting; iPad and iPhone Duo rotate freely while keeping the same bottom control layout.
You can also bypass the spektrafilm pipeline and blend up to two `.cube` 3D LUT slots (for encoded sRGB input).

保存与管理配方，按个性化、曝光与暗房分别复制或应用；通过 `.rnformula` 文件、`#` 片段链接或二维码配方卡共享。

Save and manage Formulae with separate Look, Exposure and Darkroom parts, and share them via `.rnformula` files, `#`-fragment links, or QR Formula Cards.

### 相机与管线兼容性 / Camera and pipeline compatibility

镜头与拍摄格式按当前设备的 AVFoundation 实际能力动态检测：
- [Apple ProRAW][proraw] 适用于 iPhone 12 Pro 及后续 Pro 机型支持的镜头；[iPhone 11 Pro][iphone11-raw] 等机型在广角/长焦上提供 Bayer RAW。
- 不支持 RAW 的机型、iPad 或副摄镜头（如前置摄像头、旧款超广角）自动使用 `HEIC` / `JPEG` 拍摄。
- **渲染管线**（关于 → 设置）提供“自动 / 32 位浮点 / 16 位浮点”，在较小内存设备上默认采用 16 位半精度浮点以降低内存占用，同时保持内部 FFT 与递归滤波的 32 位精度。

Lenses and formats are queried dynamically from AVFoundation:
- [Apple ProRAW][proraw] is available on supported lenses of iPhone 12 Pro and later Pro models; devices such as [iPhone 11 Pro][iphone11-raw] offer Bayer RAW on wide and telephoto lenses.
- Non-RAW phones, iPads and secondary lenses (such as front cameras or older ultrawide lenses) capture `HEIC` / `JPEG` automatically.
- **Rendering pipeline** (About → Settings) offers `Automatic`, `32-bit float` and `16-bit float`, defaulting to 16-bit half-float working storage on lower-memory devices while keeping 32-bit internal FFT and recursive filter math.

## 模型说明 / Technical notes

胶片与印相配置源自 [spektrafilm][upstream]，基于公开的厂商技术资料与文献建模（使用 `F·` 与 `K·` 简写标识，独立于任何厂商）。输入为解码后的 RGB 图像而非实测场景光谱，实际效果会受相机传感器、RAW 解码、光照与参数设置影响；参考曲线代表特定测试条件下的典型表现（[数据来源][profile-data] · [模型说明][model-notes] · [资料示例][kodak]）。

LUT 模式中的颗粒、光晕与柔光为 RGB 适配。照片导出为 SDR sRGB 8 位（另支持直接导出原始 RAW 文件），全分辨率渲染受设备可用内存限制。

Film and print profiles come from [spektrafilm][upstream] (`F·` and `K·` labels, independent of any manufacturer), modeled from published datasheets and literature ([data sources][profile-data] · [model notes][model-notes] · [datasheet example][kodak]). Input is decoded RGB rather than measured scene spectra, so results vary with sensor response, RAW decoding and lighting.

Grain, halation and diffusion in LUT mode are RGB adaptations. Rendered photo exports are 8-bit SDR sRGB (alongside direct original RAW export), bounded by available device memory.

## 构建 / Build

使用 Xcode 打开 [SpektraCam.xcodeproj](SpektraCam.xcodeproj)，选择模拟器或真机运行。最低部署目标为 iOS / iPadOS 17.0。真机安装需配置开发团队签名；Python 3 用于运行本机校验脚本。

Open [SpektraCam.xcodeproj](SpektraCam.xcodeproj) in Xcode, select a Simulator or device, and run. Minimum deployment target is iOS / iPadOS 17.0. Configure your development team for device signing; Python 3 runs the native test suite.

```sh
python3 Scripts/core-checks.py
python3 Scripts/build-and-run.py --ui-tests
```

## 隐私 / Privacy

照片、编辑、配方与 LUT 保存在设备本地。可选定位权限用于写入相机拍摄坐标；查看带坐标的照片时，系统通过 Apple 地理编码服务解析地名。详见[隐私政策](PRIVACY.md)。

Photos, edits, formulae and LUTs stay on your device. Optional location access records capture coordinates in camera photos, and Apple’s geocoding service resolves place names when viewing geotagged photos. See [PRIVACY.md](PRIVACY.md).

## 许可与致谢 / License and credits

代码采用 [GPLv3](LICENSE)；spektrafilm 配置与 LUT 数据采用 [CC BY-SA 4.0](SPEKTRAFILM_LICENSE.txt)。保留 Andrea Volpato 的原始署名、许可及[第三方声明](ThirdPartyNotices.txt)。

Code: [GPLv3](LICENSE). spektrafilm profiles and LUT data: [CC BY-SA 4.0](SPEKTRAFILM_LICENSE.txt). Preserve Andrea Volpato’s attribution, the licenses and [third-party notices](ThirdPartyNotices.txt).

[upstream]: https://github.com/andreavolpato/spektrafilm/tree/3bb2c2d2801ff68b92019cf1dbcbb133d60832bc
[profile-data]: https://github.com/andreavolpato/spektrafilm/blob/3bb2c2d2801ff68b92019cf1dbcbb133d60832bc/src/spektrafilm/profiles/io.py
[model-notes]: https://github.com/andreavolpato/spektrafilm/blob/3bb2c2d2801ff68b92019cf1dbcbb133d60832bc/README.md#introduction
[kodak]: https://www.kodakprofessional.com/sites/default/files/wysiwyg/pro/resources/e4000_ektachrome_100.pdf
[proraw]: https://support.apple.com/en-us/119916
[iphone11-raw]: https://www.lux.camera/inside-the-iphone-11-camera-part-1-a-completely-new-camera/
