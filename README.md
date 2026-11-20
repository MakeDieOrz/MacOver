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
    Run iOS apps and games natively on Apple Silicon Macs (macOS 26 Tahoe+) with Liquid Glass UI, hardened runtime virtualization, and mouse, keyboard &amp; controller support.
    <br />
    <br />
    <a href="https://github.com/MakeDieOrz/MacOver/releases">Releases</a>
    ·
    <a href="https://github.com/MakeDieOrz/MacOver/issues">Report Bug / Request Feature</a>
    ·
    <a href="./PlayTools/README.md">PlayTools Internals</a>
    <br />
    <strong>English</strong>
    ·
    <a href="./README.zh-CN.md">简体中文</a>
  </p>
</div>

<!-- ABOUT THE PROJECT -->
## About The Project

Welcome to **MacOver 1.0.0** — a clean-room architectural continuation and macOS 26 Tahoe makeover derived from [PlayCover](https://github.com/PlayCover/PlayCover) and [PlayTools](https://github.com/PlayCover/PlayTools).

MacOver runs iOS binaries directly on Apple Silicon ARM64 hardware via Mac Catalyst and the injected `PlayTools` runtime—preserving native performance without CPU instruction emulation while giving iOS apps a full macOS desktop makeover: Liquid Glass workspace UI, display & ProMotion frame-rate controls, input mapping, network rules, isolated credential storage (`PlayChain`), and hardened runtime virtualization.

### Key Highlights in MacOver 1.0.0

- **macOS 26 Tahoe Liquid Glass UI**: Redesigned navigation, library cards/table, live inspector preview, scenario presets, and GPU pixel budget meter built natively on macOS 26.0+ materials.
- **Unified Monorepo & Zero-Patch Native Build**: `MacOver.app` (`PlayCover` scheme), `PlayCoverHelper`, `PlayTools` (`PlayTools.framework` + `AKInterface.bundle`), and `Packages/PlayCoverModules` build natively inside `PlayCover.xcworkspace` without Carthage or external patch diffs.
- **Zero-Dependency SwiftPM Architecture**: Core logic, Mach-O/PlayTools injection, keymapping, sandbox/helper validation, and async UI primitives live cleanly in `Packages/PlayCoverModules` (`PlayCoverCore`, `PlayCoverMachO`, `PlayCoverKeymapping`, `PlayCoverSandbox`, `PlayCoverUI`).
- **Isolated Coexistence (`app.makedie.MacOver`)**: Dedicated Bundle ID, container (`~/Library/Containers/app.makedie.MacOver`), KeyCover namespace, and dual-hiding anti-detection so MacOver runs cleanly alongside legacy PlayCover installs.
- **Structured DI & Dual-Track Privilege Escalation**: Explicit dependency wiring (`PlayCoverDependencies`), non-blocking async SwiftUI alert sheets (`AlertPresenter`), and `SMAppService` privileged XPC `PlayCoverHelper` (`app.makedie.MacOver.Helper`) with AppleScript admin fallback for ad-hoc builds.
- **Safe Mode, Manifest Plugins & Syscall Tracing**: Automatic early-crash recovery (`PTSafeMode`), `PluginManifest.json`-validated `UserPlugins` with dynamic registration (`PTRegistration`), direct-touch mouse/multi-window routing, pre-migration `PlayedAppleDBBackup`, and `PLAYTOOLS_DEBUG_LOG=1` tracing.

![MacOver Light Showcase](./images/light.png#gh-light-mode-only)
![MacOver Dark Showcase](./images/dark.png#gh-dark-mode-only)

<p align="right"><a href="#top">⬆️ Back to top</a></p>

<!-- GETTING STARTED -->
## Getting Started

### Prerequisites

- **Apple Silicon Mac** (M-series SoC) running **macOS 26.0 Tahoe or newer**. Intel Macs are not supported.
- **Building from source**: Xcode (macOS 26 SDK / Swift toolchain) and Python 3 (optional, for the headless runtime harness).

### Download

Download prebuilt releases from [GitHub Releases](https://github.com/MakeDieOrz/MacOver/releases), or build from source using the commands below.

### Documentation

- Runtime hooks, Safe Mode, `PluginManifest.json` user plugins, and `PLAYTOOLS_DEBUG_LOG=1` diagnostics: see [PlayTools/README.md](./PlayTools/README.md) ([简体中文](./PlayTools/README.zh-CN.md)).
- Host & module overview: see [Documentation.docc/Documentation.md](./Documentation.docc/Documentation.md).

### Building & Testing from Source

Open `PlayCover.xcworkspace` in Xcode, or run the full verification suite from the repository root (if `xcode-select` points to CommandLineTools, keep `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer`):

```sh
# 1. Run offline modular SwiftPM tests (PlayCoverCore, PlayCoverMachO, PlayCoverSandbox, PlayCoverUI)
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --package-path Packages/PlayCoverModules

# 2. Run full Xcode test suite (PlayCoverMachOTests, PlayCoverCoreTests, PlayToolsTests)
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild \
  -workspace PlayCover.xcworkspace \
  -scheme PlayCoverTests \
  -configuration Debug \
  CODE_SIGN_IDENTITY=- CODE_SIGNING_REQUIRED=NO CODE_SIGNING_ALLOWED=NO \
  test

# 3. Build Release MacOver.app bundle (embeds PlayCoverHelper & PlayTools.framework)
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild \
  -workspace PlayCover.xcworkspace \
  -scheme PlayCover \
  -configuration Release \
  CODE_SIGN_IDENTITY=- CODE_SIGNING_REQUIRED=NO CODE_SIGNING_ALLOWED=NO \
  build

# 4. Run clang-format / .clang-tidy config check + Clang Static Analyzer on PlayTools
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer ./ci/run_static_analysis.sh --check-format

# 5. Run live Mac Catalyst runtime harness against built PlayTools.framework
python3 Tests/RuntimeHarness/run_runtime_harness.py \
  --playtools-framework <path/to/MacOver.app/Contents/Frameworks/PlayTools.framework> \
  --verbose
```

<p align="right"><a href="#top">⬆️ Back to top</a></p>

<!-- LICENSE -->
## License

This repository combines two copyleft-compatible components derived from upstream PlayCover:

- **Host Application & Modules (`MacOver`, derived from [`PlayCover/PlayCover`](https://github.com/PlayCover/PlayCover))**: Licensed under the **GNU General Public License v3.0 (GPL-3.0)**. See [LICENSE](./LICENSE).
- **Injected Runtime (`PlayTools/`, derived from [`PlayCover/PlayTools@e222ce0`](https://github.com/PlayCover/PlayTools))**: Licensed under the **GNU Affero General Public License v3.0 (AGPL-3.0)**. See [PlayTools/LICENSE](./PlayTools/LICENSE).

Combined binary distributions (such as `MacOver.app`, which embeds `PlayTools.framework`) are distributed under **GPL-3.0 / AGPL-3.0** (subject to AGPL-3.0 §13 and GPL-3.0 §13 terms).

<!-- ACKNOWLEDGMENTS & UPSTREAM CREDITS -->
## Upstream Credits & Contact

MacOver builds upon the work of the [PlayCover](https://github.com/PlayCover/PlayCover) community:

- Lucas Lee - playcover@lucas.icu
- Depal - depal@playcover.io
- Thanks to @iVoider for creating PlayCover!

### Libraries Used

* [PTFakeTouch](https://github.com/Ret70/PTFakeTouch)
* [DownloadManager](https://github.com/shapedbyiris/download-manager)
* [DataCache](https://github.com/huynguyencong/DataCache)
* [SwiftUI CachedAsyncImage](https://github.com/bullinnyc/CachedAsyncImage)
* [Yams](https://github.com/jpsim/Yams)
* [SwiftSoup](https://github.com/scinfu/SwiftSoup)
* [Sparkle](https://github.com/sparkle-project/Sparkle)
* [SwordRPC](https://github.com/spotlightishere/SwordRPC)
* [inject](https://github.com/paradiseduo/inject) *(original Mach-O injection inspiration; MacOver uses native `PlayCoverMachO`)*

<p align="right"><a href="#top">⬆️ Back to top</a></p>

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
