<div id="top"></div>

‎<h1 align="center">[![Contributors][contributors-shield]][contributors-url]
[![Forks][forks-shield]][forks-url]
[![Stargazers][stars-shield]][stars-url]
[![Issues][issues-shield]][issues-url]
[![GPLv3 License][license-shield]][license-url]
[![Weblate](https://img.shields.io/weblate/progress/playcover?style=for-the-badge)](https://hosted.weblate.org/projects/playcover/playcover/)
</h1>

<!-- PROJECT LOGO -->
<br />
<div align="center">
  <a href="https://github.com/PlayCover/PlayCover">
    <img src="images/logo.png" alt="Logo" width="80" height="80">
  </a>

  <h3 align="center">PlayCover</h3>

  <p align="center">
    在 Apple Silicon Mac 上原生运行 iOS 应用与游戏，支持键盘、鼠标、触控板与手柄映射。
    <br />
    <br />
    <a href="https://playcover.github.io/PlayBook">官方手册</a>
    ·
    <a href="https://discord.gg/RNCHsQHr3S">Discord</a>
    ·
    <a href="https://playcover.io/">官网</a>
    <br />
    <a href="./README.md">English</a>
    ·
    <strong>简体中文</strong>
  </p>
</div>

<!-- ABOUT THE PROJECT -->
## 项目简介

欢迎使用 PlayCover 5.0！PlayCover 致力于让运行 macOS 12.0 Monterey 至 macOS 15 Sequoia（及更新系统）的 Apple Silicon Mac 用户原生运行 iOS 应用与游戏。

PlayCover 通过 Mac Catalyst 封装层与注入式运行时 `PlayTools` 直接在 ARM64 芯片上原生执行移动应用（无需传统指令集模拟器），兼顾原生性能、分辨率缩放、键位映射与系统服务虚拟化。

除了鼠标、键盘、触控板与游戏手柄的通用映射（WASD 移动、视角控制、左右键、拖拽按键与独立按键），PlayCover 5.0 在架构与稳定性上完成了全面重构。

### PlayCover 5.0 核心特性

- **统一工作区与零补丁原生构建**：`PlayCover`、`PlayCoverHelper`、`PlayTools`（`PlayTools.framework` + `AKInterface.bundle`）与 `Packages/PlayCoverModules` 在 `PlayCover.xcworkspace` 中一体化原生构建，彻底移除 Carthage 与外部 patch 补丁流程。
- **SwiftPM 零三方依赖模块化拆分**：核心工具、Mach-O/PlayTools 注入、键位映射、沙盒与特权助手安全校验以及 UI 展示组件抽离至 `Packages/PlayCoverModules`（包含 `PlayCoverCore`、`PlayCoverMachO`、`PlayCoverKeymapping`、`PlayCoverSandbox`、`PlayCoverUI`），保持零外部第三方依赖。
- **显式依赖注入与非阻塞异步弹窗**：宿主机全面采用 `PlayCoverDependencies` 进行依赖注入（清零全局 `static shared` 单例），并通过 SwiftUI Sheet 队列式 `AlertPresenter` 取代阻塞主线程的 `NSAlert.runModal()`。
- **双轨特权升级机制**：在 macOS 13+ 且具备 Developer ID 签名的环境中通过 `SMAppService` 启用经安全校验的 `PlayCoverHelper` XPC 守护进程；在本地编译或 Ad-hoc 签名环境下自动回退至 AppleScript 管理员授权路径。
- **Safe Mode 安全模式、清单化插件与运行时追踪**：集成 `PTSafeMode` 启动崩溃自动恢复、`PluginManifest.json` 校验与按优先级加载 `UserPlugins`（配合 `PTRegistration` 动态反检测注册）、macOS 15 Sequoia `AKInterface` 窗口几何与旋转桥接、`PlayedAppleDBBackup` 自动迁移前备份，以及 `PLAYTOOLS_DEBUG_LOG=1` 系统调用级追踪日志。

界面多语言本地化由 [Weblate](https://hosted.weblate.org/projects/playcover/) 协作维护。

![Fancy logo](./images/dark.png#gh-dark-mode-only)
![Fancy logo](./images/light.png#gh-light-mode-only)

<p align="right"><a href="#top">⬆️ 返回顶部</a></p>

<!-- GETTING STARTED -->
## 快速开始

### 运行与构建环境要求

- **运行环境**：搭载 **Apple Silicon（M 系列芯片）** 的 Mac，系统需 **macOS 12.0 Monterey 及以上**（已在 macOS 14 Sonoma 与 macOS 15 Sequoia 验证）。不支持 Intel Mac。
- **源码构建要求**：Xcode（Swift 5.9+ 工具链）、Python 3（用于无头运行时测试套件），以及可选安装的 `swiftlint` 和 `clang-tidy`。

### 下载安装

可在 [GitHub Releases](https://github.com/PlayCover/PlayCover/releases) 下载稳定版本，或按下方说明从源码构建。

### 使用文档

- 常规使用指南：访问 [PlayBook 在线文档](https://playcover.github.io/PlayBook)。
- `PlayTools` 5.0 运行时、安全模式、插件机制与诊断说明：请参阅 [PlayTools/README.zh-CN.md](./PlayTools/README.zh-CN.md)（英文原版见 [PlayTools/README.md](./PlayTools/README.md)）。

### Homebrew Cask 安装

可通过官方 Tap 安装社区版：

```sh
brew install --cask PlayCover/playcover/playcover-community
```

卸载方式：
1. 执行 `brew uninstall --cask playcover-community` 移除应用；
2. 执行 `brew untap PlayCover/playcover` 取消 Tap。

### 源码构建与全量验证 (5.0)

直接在 Xcode 中打开 `PlayCover.xcworkspace`，或在仓库根目录执行以下命令（若系统 `xcode-select` 指向 CommandLineTools，请保留 `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer`）：

```sh
# 1. 运行离线模块化 SwiftPM 单元测试（PlayCoverCore / PlayCoverMachO / PlayCoverSandbox / PlayCoverUI）
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --package-path Packages/PlayCoverModules

# 2. 运行完整 Xcode 单元测试套件（PlayCoverMachOTests / PlayCoverCoreTests / PlayToolsTests）
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild \
  -workspace PlayCover.xcworkspace \
  -scheme PlayCoverTests \
  -configuration Debug \
  CODE_SIGN_IDENTITY=- CODE_SIGNING_REQUIRED=NO CODE_SIGNING_ALLOWED=NO \
  test

# 3. 构建 Release 应用包（自动内嵌 PlayCoverHelper 与 PlayTools.framework）
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild \
  -workspace PlayCover.xcworkspace \
  -scheme PlayCover \
  -configuration Release \
  CODE_SIGN_IDENTITY=- CODE_SIGNING_REQUIRED=NO CODE_SIGNING_ALLOWED=NO \
  build

# 4. 运行 PlayTools 格式化检查（.clang-format / .clang-tidy）与 Clang Static Analyzer 静态分析
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer ./ci/run_static_analysis.sh --check-format

# 5. 对构建好的 PlayTools.framework 执行真实 Mac Catalyst 进程注入与安全模式验证
python3 Tests/RuntimeHarness/run_runtime_harness.py \
  --playtools-framework <path/to/PlayTools.framework> \
  --verbose
```

<p align="right"><a href="#top">⬆️ 返回顶部</a></p>

<!-- LICENSE -->
## 开源协议

基于 **GPLv3** 协议开源，详情请参阅 `LICENSE`。

<!-- CONTACT -->
## 联系方式

Lucas Lee - playcover@lucas.icu

Depal - depal@playcover.io

<!-- ACKNOWLEDGMENTS -->
## 使用的开源库

PlayCover 5.0 依赖或致谢以下开源项目：

* [PTFakeTouch](https://github.com/Ret70/PTFakeTouch)
* [DownloadManager](https://github.com/shapedbyiris/download-manager)
* [DataCache](https://github.com/huynguyencong/DataCache)
* [SwiftUI CachedAsyncImage](https://github.com/bullinnyc/CachedAsyncImage)
* [Yams](https://github.com/jpsim/Yams)
* [SwiftSoup](https://github.com/scinfu/SwiftSoup)
* [Sparkle](https://github.com/sparkle-project/Sparkle)
* [SwordRPC](https://github.com/spotlightishere/SwordRPC)
* [inject](https://github.com/paradiseduo/inject) *（早期 Mach-O 注入方案灵感来源；PlayCover 5.0 已全面采用自研 `PlayCoverMachO`）*

* 特别感谢 @iVoider 创造了 PlayCover 项目！

<p align="right"><a href="#top">⬆️ 返回顶部</a></p>

<!-- MARKDOWN LINKS & IMAGES -->
[contributors-shield]: https://img.shields.io/github/contributors/PlayCover/PlayCover.svg?style=for-the-badge
[contributors-url]: https://github.com/PlayCover/PlayCover/graphs/contributors
[forks-shield]: https://img.shields.io/github/forks/PlayCover/PlayCover.svg?style=for-the-badge
[forks-url]: https://github.com/PlayCover/PlayCover/network/members
[stars-shield]: https://img.shields.io/github/stars/PlayCover/PlayCover.svg?style=for-the-badge
[stars-url]: https://github.com/PlayCover/PlayCover/stargazers
[issues-shield]: https://img.shields.io/github/issues/PlayCover/PlayCover.svg?style=for-the-badge
[issues-url]: https://github.com/PlayCover/PlayCover/issues
[license-shield]: https://img.shields.io/github/license/PlayCover/PlayCover.svg?style=for-the-badge
[license-url]: https://github.com/PlayCover/PlayCover/blob/master/LICENSE
