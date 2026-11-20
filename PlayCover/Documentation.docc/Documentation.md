# ``MacOver``

Run iOS apps and games natively on Apple Silicon Macs (macOS 26.0 Tahoe and newer) with Liquid Glass UI, keyboard, mouse, trackpad, and controller mapping.

## Overview

MacOver 1.0 unifies `MacOver.app` (`app.makedie.MacOver`), `PlayCoverHelper` (`app.makedie.MacOver.Helper`), modular SwiftPM packages, and the Mac Catalyst `PlayTools` runtime (`app.makedie.PlayTools`) inside `PlayCover.xcworkspace`.

### MacOver 1.0 Workspace Layout

- **`Packages/PlayCoverModules`**: Zero-dependency SwiftPM workspace packages (`PlayCoverCore`, `PlayCoverMachO`, `PlayCoverKeymapping`, `PlayCoverSandbox`, `PlayCoverUI`) with standalone offline test targets.
- **`MacOver.app` (`PlayCover` target)**: macOS SwiftUI host app wired through `PlayCoverDependencies` and async SwiftUI sheet prompts (`AlertPresenter`).
- **`PlayCoverHelper`**: Privileged XPC LaunchDaemon tool (`app.makedie.MacOver.Helper`) paired with `DualTrackPrivilegeEscalator` AppleScript fallback for ad-hoc/local builds.
- **`PlayTools`**: Modular Mac Catalyst runtime (`Subsystems/`), `AKInterface.bundle` AppKit window bridge, `PTSafeMode` early-crash recovery, `PluginManifest.json`-driven `UserPlugins`, `PlayedAppleDBBackup`, and `PLAYTOOLS_DEBUG_LOG=1` syscall tracing.

### Quick Verification Commands

```sh
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --package-path Packages/PlayCoverModules
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild -workspace PlayCover.xcworkspace -scheme PlayCoverTests -configuration Debug CODE_SIGN_IDENTITY=- CODE_SIGNING_REQUIRED=NO CODE_SIGNING_ALLOWED=NO test
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer ./ci/run_static_analysis.sh --check-format
```
