<div align="center">
  <a href="https://github.com/MakeDieOrz/MacOver">
    <img src="images/logo.png" alt="MacOver Logo" width="96" height="96">
  </a>

  <h1>MacOver</h1>

  <p>
    <em>Fake it till you Mac it.</em><br />
    Run decrypted ARM64 iOS apps and games natively on Apple Silicon Macs (macOS 26+).
  </p>

  <p>
    <a href="https://github.com/MakeDieOrz/MacOver/actions/workflows/ci.yml">
      <img src="https://github.com/MakeDieOrz/MacOver/actions/workflows/ci.yml/badge.svg" alt="CI">
    </a>
    <a href="https://github.com/MakeDieOrz/MacOver/releases">
      <img src="https://img.shields.io/github/v/release/MakeDieOrz/MacOver?include_prereleases&label=Release" alt="Release">
    </a>
    <a href="./LICENSE">
      <img src="https://img.shields.io/badge/License-GPLv3%20%2B%20AGPLv3-blue.svg" alt="License">
    </a>
    <img src="https://img.shields.io/badge/macOS-26%2B%20Apple%20Silicon-black.svg" alt="macOS 26+ Apple Silicon">
  </p>

  <p>
    <a href="https://github.com/MakeDieOrz/MacOver/releases">Releases</a>
    ·
    <a href="https://github.com/MakeDieOrz/MacOver/issues">Issues</a>
    ·
    <a href="./PlayTools/README.md">PlayTools Internals</a>
    <br />
    <strong>English</strong>
    ·
    <a href="./README.zh-CN.md">简体中文</a>
    ·
    <a href="./README.ja.md">日本語</a>
  </p>
</div>

MacOver is a heavily reworked fork of [PlayCover](https://github.com/PlayCover/PlayCover) and [PlayTools](https://github.com/PlayCover/PlayTools), built specifically for Apple Silicon Macs on **macOS 26 Tahoe and newer**.

It executes iOS ARM64 binaries directly through Mac Catalyst and an injected `PlayTools` runtime—no CPU emulation—and wraps them with keyboard/mouse/controller mapping, display and frame-rate control, per-app network rules, isolated keychain storage (`PlayChain`), and runtime virtualization.

![MacOver Light Showcase](./images/light.png#gh-light-mode-only)
![MacOver Dark Showcase](./images/dark.png#gh-dark-mode-only)

## Why MacOver? (vs. Upstream PlayCover)

| Area | Upstream PlayCover | MacOver |
| --- | --- | --- |
| **UI & macOS Target** | Older SwiftUI layout + blocking `NSAlert` popups | Native macOS 26+ Liquid Glass workspace (`GlassEffectContainer`), live config preview, scenario presets, GPU pixel-budget meter, and queued async sheets |
| **Coexistence & Isolation** | Global `io.playcover.PlayCover` container and shared `~/Library/Frameworks/PlayTools.framework` | Fully isolated under `app.makedie.MacOver`, including container-local `~/Library/Containers/app.makedie.MacOver/Frameworks/PlayTools.framework`, separate `KeyCover` / `PlayChain`, and `app.makedie.MacOver.Helper` |
| **Runtime & Anti-Detection** | Baseline `PlayTools` hooks | Hardened C/ObjC FS, dyld, and system-property virtualization (`PTFSVirtualizer`, `PTDyldVirtualizer`, `PTSystemSpoofer`), hides both MacOver and PlayCover traces, configurable `reportedIOSVersion` for macOS 26/27, direct-touch mouse & multi-window routing, per-app URL network rules |
| **Crash Recovery & Plugins** | Manual troubleshooting on startup crash; unmanaged dylib injection | `PTSafeMode` catches early crashes (<3s) and automatically boots the next launch in Safe Mode; `UserPlugins` validated via `PluginManifest.json` with dynamic hidden-module registration (`PTRegistration`); `PlayedAppleDBBackup` snapshots legacy DBs before migration; `PLAYTOOLS_DEBUG_LOG=1` syscall tracing |
| **Build & Codebase** | Split PlayCover / PlayTools repos with Carthage / external patches | Single `PlayCover.xcworkspace` builds `MacOver.app`, `PlayCoverHelper`, `PlayTools.framework`, `AKInterface.bundle`, and zero-dependency SwiftPM packages (`Packages/PlayCoverModules`) |
| **Privilege Helper & Testing** | Requires paid signing for helper workflows; limited automated coverage | Dual-track privilege escalation (`SMAppService` XPC helper when signed, AppleScript admin fallback for ad-hoc builds); 121 unit tests, Clang Static Analyzer (0 warnings), and a headless Mac Catalyst runtime test harness |

## Install

### Requirements

- **Apple Silicon Mac** (M1 or newer). Intel Macs are not supported.
- **macOS 26.0 Tahoe or newer**.

### Download

Grab the latest DMG from [GitHub Releases](https://github.com/MakeDieOrz/MacOver/releases), open it, and drag `MacOver.app` into `/Applications`.

> **Note on Ad-hoc Builds**: Prebuilt releases are ad-hoc signed rather than Apple notarized. If macOS flags the app on first launch, clear the quarantine attribute and open it again:
> ```sh
> xattr -cr /Applications/MacOver.app
> ```

### Coexisting with PlayCover

MacOver keeps its apps, settings, keymaps, `PlayChain`, and `PlayTools.framework` inside `~/Library/Containers/app.makedie.MacOver/`, so installing or opening MacOver will not overwrite an existing PlayCover installation or its `~/Library/Frameworks/PlayTools.framework`.

One macOS limit still applies: each iOS `CFBundleIdentifier` shares a single system sandbox directory (`~/Library/Containers/<BundleID>`) and LaunchServices entry, so avoid running the exact same app from both PlayCover and MacOver at the same time.

## Build & Test from Source

Requirements: Xcode (macOS 26 SDK or newer) and Python 3 (optional, for the headless runtime harness).

Open `PlayCover.xcworkspace` in Xcode, or run from the repository root (keep `DEVELOPER_DIR` if `xcode-select` points to CommandLineTools):

```sh
# 1. Offline SwiftPM module tests (PlayCoverCore, PlayCoverMachO, PlayCoverSandbox, PlayCoverUI)
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --package-path Packages/PlayCoverModules

# 2. Full Xcode test suite (PlayCoverMachOTests, PlayCoverCoreTests, PlayToolsTests)
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild \
  -workspace PlayCover.xcworkspace \
  -scheme PlayCoverTests \
  -configuration Debug \
  CODE_SIGN_IDENTITY=- CODE_SIGNING_REQUIRED=NO \
  test

# 3. Build Release MacOver.app (embeds PlayCoverHelper and PlayTools.framework)
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild \
  -workspace PlayCover.xcworkspace \
  -scheme PlayCover \
  -configuration Release \
  CODE_SIGN_IDENTITY=- CODE_SIGNING_REQUIRED=NO CODE_SIGN_STYLE=Manual \
  build

# 4. Format check + Clang Static Analyzer on PlayTools
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer ./ci/run_static_analysis.sh --check-format

# 5. Headless Mac Catalyst runtime harness against built PlayTools.framework
python3 Tests/RuntimeHarness/run_runtime_harness.py \
  --playtools-framework <path/to/MacOver.app/Contents/Frameworks/PlayTools.framework> \
  --verbose
```

### Further Reading

- Runtime hooks, Safe Mode, `PluginManifest.json` user plugins, and `PLAYTOOLS_DEBUG_LOG=1`: [PlayTools/README.md](./PlayTools/README.md) ([简体中文](./PlayTools/README.zh-CN.md))
- Host workspace & module layout: [PlayCover/Documentation.docc/Documentation.md](./PlayCover/Documentation.docc/Documentation.md)

## License

MacOver combines two copyleft-compatible upstream bases:

- **Host app & SwiftPM modules (`MacOver`, derived from [`PlayCover/PlayCover`](https://github.com/PlayCover/PlayCover))**: **GPL-3.0** — see [LICENSE](./LICENSE).
- **Injected runtime (`PlayTools/`, derived from [`PlayCover/PlayTools@e222ce0`](https://github.com/PlayCover/PlayTools))**: **AGPL-3.0** — see [PlayTools/LICENSE](./PlayTools/LICENSE).

Combined binary distributions (`MacOver.app` with embedded `PlayTools.framework`) are distributed under **GPL-3.0 / AGPL-3.0** in accordance with §13 of both licenses.

## Upstream Credits & Libraries

Built on top of the [PlayCover](https://github.com/PlayCover/PlayCover) community's work:

- Lucas Lee — playcover@lucas.icu
- Depal — depal@playcover.io
- Thanks to @iVoider for originally creating PlayCover.

Libraries used:

- [PTFakeTouch](https://github.com/Ret70/PTFakeTouch)
- [DownloadManager](https://github.com/shapedbyiris/download-manager)
- [DataCache](https://github.com/huynguyencong/DataCache)
- [SwiftUI CachedAsyncImage](https://github.com/bullinnyc/CachedAsyncImage)
- [Yams](https://github.com/jpsim/Yams)
- [SwiftSoup](https://github.com/scinfu/SwiftSoup)
- [Sparkle](https://github.com/sparkle-project/Sparkle)
- [inject](https://github.com/paradiseduo/inject) *(early Mach-O injection reference; MacOver uses its own `PlayCoverMachO` implementation)*
