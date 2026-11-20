# ``PlayCover``

Run iOS apps and games natively on Apple Silicon Macs (macOS 12.0 through macOS 15 Sequoia and newer) with keyboard, mouse, trackpad, and controller mapping.

## Overview

PlayCover 5.0 unifies the macOS host application, privileged helper tool, modular SwiftPM packages, and the Mac Catalyst `PlayTools` runtime inside `PlayCover.xcworkspace`.

### PlayCover 5.0 Workspace Layout

- **`Packages/PlayCoverModules`**: Zero-dependency SwiftPM workspace packages (`PlayCoverCore`, `PlayCoverMachO`, `PlayCoverKeymapping`, `PlayCoverSandbox`, `PlayCoverUI`) with standalone offline test targets.
- **`PlayCover`**: macOS SwiftUI host app wired through `PlayCoverDependencies` and async SwiftUI sheet prompts (`AlertPresenter`).
- **`PlayCoverHelper`**: Privileged XPC LaunchDaemon tool (`io.playcover.PlayCover.Helper`) paired with `DualTrackPrivilegeEscalator` AppleScript fallback for ad-hoc/local builds.
- **`PlayTools`**: Modular Mac Catalyst runtime (`Subsystems/`), `AKInterface.bundle` Sequoia window bridge, `PTSafeMode` early-crash recovery, `PluginManifest.json`-driven `UserPlugins`, `PlayedAppleDBBackup`, and `PLAYTOOLS_DEBUG_LOG=1` syscall tracing.

### Quick Verification Commands

```sh
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --package-path Packages/PlayCoverModules
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild -workspace PlayCover.xcworkspace -scheme PlayCoverTests -configuration Debug CODE_SIGN_IDENTITY=- CODE_SIGNING_REQUIRED=NO CODE_SIGNING_ALLOWED=NO test
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer ./ci/run_static_analysis.sh --check-format
```
