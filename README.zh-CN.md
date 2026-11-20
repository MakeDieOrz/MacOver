<div id="top"></div>

<h1 align="center">

[![Contributors][contributors-shield]][contributors-url]
[![Forks][forks-shield]][forks-url]
[![Stargazers][stars-shield]][stars-url]
[![Issues][issues-shield]][issues-url]
[![GPLv3 + AGPLv3 License][license-shield]][license-url]

</h1>

<!-- PROJECT LOGO -->
<br />
<div align="center">
  <a href="https://github.com/MakeDieOrz/MacOver">
    <img src="images/logo.png" alt="MacOver Logo" width="96" height="96">
  </a>

  <h3 align="center">MacOver</h3>

  <p align="center">
    <em>Fake it till you Mac it.</em><br />
    在 Apple Silicon Mac（macOS 26 Tahoe+）上原生运行 iOS 应用与游戏，采用全新 Liquid Glass 界面、加固运行时虚拟化与键鼠/触控板/手柄映射。
    <br />
    <br />
    <a href="https://github.com/MakeDieOrz/MacOver/releases">版本发布 (Releases)</a>
    ·
    <a href="https://github.com/MakeDieOrz/MacOver/issues">问题反馈</a>
    ·
    <a href="./PlayTools/README.zh-CN.md">PlayTools 运行时文档</a>
    <br />
    <a href="./README.md">English</a>
    ·
    <strong>简体中文</strong>
  </p>
</div>

<!-- ABOUT THE PROJECT -->
## 项目简介

欢迎使用 **MacOver 1.0.0**！本项目基于 [PlayCover](https://github.com/PlayCover/PlayCover) 与 [PlayTools](https://github.com/PlayCover/PlayTools) 完成架构级重构，并面向 **macOS 26 Tahoe** 进行了全面视觉与运行时升级。

MacOver 通过 Mac Catalyst 封装层与注入式运行时 `PlayTools` 直接在 ARM64 芯片上原生执行 iOS 应用与游戏（无需传统指令集模拟器），在保留原生性能的同时带来完整桌面体验：Liquid Glass 工作区、显示与高刷帧率控制、键鼠/手柄映射、网络过滤规则、独立凭证存储（`PlayChain`）以及加固系统虚拟化。

### MacOver 1.0.0 核心特性

- **macOS 26 Tahoe Liquid Glass 全新界面**：围绕原生液态玻璃材质重构应用库视图、实时侧边检查器、一键场景预设与 GPU 像素预算指示。
- **统一工作区与零补丁原生构建**：`MacOver.app`（`PlayCover` scheme）、`PlayCoverHelper`、`PlayTools`（`PlayTools.framework` + `AKInterface.bundle`）与 `Packages/PlayCoverModules` 在 `PlayCover.xcworkspace` 中一体化原生构建，彻底告别 Carthage 与外部补丁流程。
- **零外部依赖 SwiftPM 模块化拆分**：核心工具、Mach-O/PlayTools 注入、键位映射、沙盒与特权助手安全校验以及异步 UI 组件抽离至 `Packages/PlayCoverModules`（`PlayCoverCore`、`PlayCoverMachO`、`PlayCoverKeymapping`、`PlayCoverSandbox`、`PlayCoverUI`），零第三方包依赖。
- **完全独立隔离共存（`app.makedie.MacOver`）**：采用独立 Bundle ID、独立容器路径（`~/Library/Containers/app.makedie.MacOver`）、独立 KeyCover 命名空间与双版本反检测隐藏，可与原版 PlayCover 无冲突共存。
- **显式依赖注入与双轨特权升级**：全面采用 `PlayCoverDependencies` 依赖注入与 SwiftUI 队列式非阻塞弹窗（`AlertPresenter`）；具备 Developer ID 签名时通过 `SMAppService` 启用 `PlayCoverHelper`（`app.makedie.MacOver.Helper`），本地/Ad-hoc 签名自动回退至 AppleScript 授权。
- **Safe Mode 安全模式、清单化插件与运行时追踪**：集成 `PTSafeMode` 启动崩溃自动恢复、`PluginManifest.json` 校验 `UserPlugins`（配合 `PTRegistration` 动态注册隐藏）、直触鼠标与多窗口命中路由、`PlayedAppleDBBackup` 自动迁移备份以及 `PLAYTOOLS_DEBUG_LOG=1` 系统调用追踪。

![MacOver 浅色展示](./images/light.png#gh-light-mode-only)
![MacOver 深色展示](./images/dark.png#gh-dark-mode-only)

<p align="right"><a href="#top">⬆️ 返回顶部</a></p>

<!-- GETTING STARTED -->
## 快速开始

### 运行与构建环境要求

- **运行环境**：搭载 **Apple Silicon（M 系列芯片）** 的 Mac，系统需 **macOS 26.0 Tahoe 及以上**。不支持 Intel Mac。
- **源码构建要求**：Xcode（macOS 26 SDK / Swift 工具链），以及可选安装的 Python 3（用于无头运行时测试套件）。

### 下载安装

可在 [GitHub Releases](https://github.com/MakeDieOrz/MacOver/releases) 下载构建版本，或按下方说明从源码编译。

### 使用文档

- `PlayTools` 运行时 Hook、安全模式、插件规范与 `PLAYTOOLS_DEBUG_LOG=1` 诊断说明：请参阅 [PlayTools/README.zh-CN.md](./PlayTools/README.zh-CN.md)（英文见 [PlayTools/README.md](./PlayTools/README.md)）。
- 宿主机与模块化架构说明：请参阅 [Documentation.docc/Documentation.md](./Documentation.docc/Documentation.md)。

### 源码构建与全量验证

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

# 3. 构建 Release 应用包 MacOver.app（自动内嵌 PlayCoverHelper 与 PlayTools.framework）
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
  --playtools-framework <path/to/MacOver.app/Contents/Frameworks/PlayTools.framework> \
  --verbose
```

<p align="right"><a href="#top">⬆️ 返回顶部</a></p>

<!-- LICENSE -->
## 开源协议

本项目整合了来自上游 PlayCover 的两个兼容 Copyleft 开源组件：

- **宿主机应用与模块化组件（`MacOver`，衍生自 [`PlayCover/PlayCover`](https://github.com/PlayCover/PlayCover)）**：遵循 **GNU General Public License v3.0（GPL-3.0）** 协议，详情见 [LICENSE](./LICENSE)。
- **注入运行时组件（`PlayTools/`，衍生自 [`PlayCover/PlayTools@e222ce0`](https://github.com/PlayCover/PlayTools)）**：遵循 **GNU Affero General Public License v3.0（AGPL-3.0）** 协议，详情见 [PlayTools/LICENSE](./PlayTools/LICENSE)。

当组合构建并以二进制包（如内嵌 `PlayTools.framework` 的 `MacOver.app`）形式对外分发时，整体分发需同时遵守 **AGPL-3.0 第 13 条** 与 **GPL-3.0 第 13 条** 的源码开放条款。

<!-- CONTACT & ACKNOWLEDGMENTS -->
## 上游致谢与联系方式

MacOver 站在 [PlayCover](https://github.com/PlayCover/PlayCover) 开源社区的肩膀上构建，保留原版核心维护者联系与致谢信息：

- Lucas Lee - playcover@lucas.icu
- Depal - depal@playcover.io
- 特别感谢 @iVoider 创造了 PlayCover 项目！

### 使用的开源库

* [PTFakeTouch](https://github.com/Ret70/PTFakeTouch)
* [DownloadManager](https://github.com/shapedbyiris/download-manager)
* [DataCache](https://github.com/huynguyencong/DataCache)
* [SwiftUI CachedAsyncImage](https://github.com/bullinnyc/CachedAsyncImage)
* [Yams](https://github.com/jpsim/Yams)
* [SwiftSoup](https://github.com/scinfu/SwiftSoup)
* [Sparkle](https://github.com/sparkle-project/Sparkle)
* [SwordRPC](https://github.com/spotlightishere/SwordRPC)
* [inject](https://github.com/paradiseduo/inject) *（早期 Mach-O 注入方案灵感来源；MacOver 已全面采用自研 `PlayCoverMachO`）*

<p align="right"><a href="#top">⬆️ 返回顶部</a></p>

<!-- MARKDOWN LINKS & IMAGES -->
[contributors-shield]: https://img.shields.io/github/contributors/MakeDieOrz/MacOver.svg?style=for-the-badge
[contributors-url]: https://github.com/MakeDieOrz/MacOver/graphs/contributors
[forks-shield]: https://img.shields.io/github/forks/MakeDieOrz/MacOver.svg?style=for-the-badge
[forks-url]: https://github.com/MakeDieOrz/MacOver/network/members
[stars-shield]: https://img.shields.io/github/stars/MakeDieOrz/MacOver.svg?style=for-the-badge
[stars-url]: https://github.com/MakeDieOrz/MacOver/stargazers
[issues-shield]: https://img.shields.io/github/issues/MakeDieOrz/MacOver.svg?style=for-the-badge
[issues-url]: https://github.com/MakeDieOrz/MacOver/issues
[license-shield]: https://img.shields.io/github/license/MakeDieOrz/MacOver.svg?style=for-the-badge
[license-url]: https://github.com/MakeDieOrz/MacOver/blob/master/LICENSE
