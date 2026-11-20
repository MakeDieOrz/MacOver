# PlayTools (5.0)

**English** · [简体中文](./README.zh-CN.md)

`PlayTools` is the injected Mac Catalyst (`arm64`) runtime framework of [PlayCover](../README.md). In PlayCover 5.0, it builds natively inside `PlayCover.xcworkspace` (no Carthage or external patch diffs required) alongside `AKInterface.bundle` to provide display scaling, input translation, system virtualization, Safe Mode recovery, and extensible user plugins.

## Core Capabilities

### Display Control & Sequoia Window Bridge

PlayTools allows per-app display customization:

- Resolution presets (`1080p`, `4K`, `1440p`, and custom dimensions)
- Aspect ratios (`16:9`, `16:10`, `4:3`, and custom ratios)
- Custom scale factors (`1.0`, `1.5`, `2.0`, etc.)
- Display orientation switching & rotation during gameplay
- Application category type (`LSApplicationCategoryType`, e.g., `game` for Screen Time integration)
- Custom Discord Rich Presence activity & spoofed device profiles

On macOS 15 Sequoia and newer, `AKInterface.bundle` works together with `PTCoordinateMath` to provide an explicit AppKit `NSWindow` geometry and orientation bridge when FrontBoard internals differ across macOS versions.

### Key Mapping & Input Translation

PlayTools maps desktop input events to simulated iOS multi-touch events (`PTFakeTouch` + `PTCoordinateMath`):

- **Supported input devices**: Keyboard, Mouse, Trackpad, Game Controller
- **Mappable actions**: Button, Joystick (e.g., WASD), Camera Control (mouse look), Draggable Button

### Runtime Virtualization & Subsystems

Runtime hooks live in modular translation units under `PlayTools/PlayTools/Subsystems/`:

- **`PTFSVirtualizer` / `PTFSVirtualizerObjC`**: Sandbox container path virtualization, lexical normalization, and hidden-path protection.
- **`PTDyldVirtualizer`**: Dyld image filtering, `dlopen`/`dlsym`/`objc_*` symbol & class hiding for anti-detection.
- **`PTSystemSpoofer` / `PTSystemSpooferObjC`**: Device model, `sysctl`/`uname`, environment variable, and runtime spoofing.
- **`PTEntitlements`**: Code-signing status (`csops`), `ptrace`, and entitlement query compatibility.
- **`PTNetworkVirtualizer`**: Per-app rule-based network filtering (`PTNetworkBlockProtocol`).
- **`PTGraphicsVirtualizer`**: Metal/graphics scaling hooks.
- **`PTRegistration`**: Thread-safe dynamic anti-detection registry decoupled from external plugins.
- **`PTDebugTrace`**: TLV-safe, recursion-safe C/ObjC syscall interposition tracing.

### PlayChain (`PlayedAppleDB`)

`PlayedAppleDB` provides a SQLite-backed keychain replacement for apps that experience login or keychain entitlement issues on macOS. Before applying schema migrations (e.g., v1/WAL upgrades), `PlayedAppleDBBackup` automatically creates an atomic pre-migration database backup to prevent credential loss.

---

## Safe Mode (`PTSafeMode`)

To prevent crash loops in misconfigured or incompatible apps:

1. PlayTools writes a `.launching_in_progress` breadcrumb under the app's PlayTools cache directory at startup and clears it after the process remains stable past the startup window.
2. If the app exits abnormally within the early startup window (< 3 seconds), the next launch activates **Safe Mode** and notifies the host app:
   - Skips loading third-party plugins in `UserPlugins/`.
   - Disables custom network rules.
   - Reverts display scaling (`customScaler`) to `1.0`.
3. A clean exit clears Safe Mode state so normal plugins and scaling resume on subsequent launches.

---

## User Plugins (`PTPluginContainer` & `PluginManifest.json`)

PlayCover syncs per-app plugins from:

```text
~/Library/Containers/io.playcover.PlayCover/PlayTools/UserPlugins/<bundleID>/
```

into the wrapped app's `Frameworks/UserPlugins/` directory during installation and launch synchronization (`PlayTools.syncUserPlugins`).

Each directory-style plugin or paired `<PluginName>.manifest.json` follows the `PTPluginManifest` schema:

- `manifestVersion`: Schema version string (e.g., `"1.0"`)
- `identifier`: Reverse-DNS plugin identifier
- `name`: Display name
- `version`: Plugin semantic version
- `minPlayToolsVersion`: Minimum compatible PlayTools version (`5.0.0` or `"0.0.0"`)
- `targetBundleIdentifiers`: Array of allowed bundle IDs (or `["*"]`)
- `loadPriority`: Integer load order priority (lower loads earlier, default `100`)
- `capabilities`: Array of declared plugin capability tags
- `entrypoint`: Entry dylib filename relative to the plugin bundle

Plugins can dynamically hide their own images and Objective-C classes from target app inspection using the C ABI declared in `PlayTools/PlayTools/Subsystems/PTRegistration.h`:

- `pt_register_hidden_module(const char *image_name_fragment)`
- `pt_register_hidden_class(const char *objc_class_name)`
- `pt_register_hidden_image_header(const void *mach_header)`

Note: `UserPlugins/` loading is automatically skipped whenever `PTSafeMode` is active.

---

## Diagnostics (`PLAYTOOLS_DEBUG_LOG=1`)

Set `PLAYTOOLS_DEBUG_LOG=1` in the target app's environment to emit TLV-safe, recursion-safe, `errno`-preserving interposition trace lines to `stderr` in the format:

```text
[PlayTools] [<subsystem>] <function>: <message>
```

For example, traces cover `spoofer`, `dyld`, `fs`, `entitlements`, `network`, `graphics`, and `reg` events without attaching a debugger.

---

## How It Works

During IPA installation, `PlayCoverMachO` validates Mach-O slices and inserts `PlayTools.framework` (`LC_LOAD_DYLIB`). When launched on macOS, `PlayLoader` initializes subsystems safely before Objective-C `+load` / dyld TLV teardown hazards, loads `AKInterface.bundle` for AppKit bridging, enforces `PTSafeMode` / `PTPluginContainer`, and translates desktop input and window events for the mobile target.

PlayTools localization files use `PlayTools.strings` to avoid colliding with the target app's own `Localizable.strings`.

---

## How to Build & Test (5.0)

`PlayTools` now builds directly as a **Mac Catalyst (`arm64`)** framework via `PlayCover.xcworkspace` (or standalone via `PlayTools/PlayTools.xcodeproj`). The legacy Carthage workflow and manual `Debug-iphoneos` + `vtool` conversion scripts are no longer used.

### Full Workspace Build & Install

Building the `PlayCover` scheme in `PlayCover.xcworkspace` automatically builds `PlayTools.framework` and `AKInterface.bundle` and embeds them into `PlayCover.app/Contents/Frameworks/PlayTools.framework`:

```sh
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild \
  -workspace PlayCover.xcworkspace \
  -scheme PlayCover \
  -configuration Release \
  CODE_SIGN_IDENTITY=- CODE_SIGNING_REQUIRED=NO CODE_SIGNING_ALLOWED=NO \
  build
```

### Standalone PlayTools Build & Unit Tests

```sh
# Build PlayTools (Mac Catalyst arm64)
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild \
  -project PlayTools/PlayTools.xcodeproj \
  -scheme PlayTools \
  -configuration Debug \
  -destination 'generic/platform=macOS,variant=Mac Catalyst' \
  ARCHS=arm64 ONLY_ACTIVE_ARCH=NO \
  CODE_SIGN_IDENTITY=- CODE_SIGNING_REQUIRED=NO CODE_SIGNING_ALLOWED=NO \
  build

# Run PlayToolsTests (via workspace scheme)
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild \
  -workspace PlayCover.xcworkspace \
  -scheme PlayCoverTests \
  -configuration Debug \
  -only-testing:PlayToolsTests \
  CODE_SIGN_IDENTITY=- CODE_SIGNING_REQUIRED=NO CODE_SIGNING_ALLOWED=NO \
  test
```

### Static Analysis & Live Runtime Harness

```sh
# Format check (.clang-format / .clang-tidy) + Clang Static Analyzer (0 findings target)
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer ./ci/run_static_analysis.sh --check-format

# Live Mac Catalyst injection, Safe Mode, PluginManifest, & PLAYTOOLS_DEBUG_LOG=1 harness
python3 Tests/RuntimeHarness/run_runtime_harness.py \
  --playtools-framework <path/to/PlayTools.framework> \
  --verbose
```

## Products

- **`PlayTools.framework`**: Main Mac Catalyst dynamic library injected into wrapped iOS apps.
- **`AKInterface.bundle`**: Native macOS AppKit bridge bundle inside `PlayTools.framework/PlugIns/AKInterface.bundle` handling cursor/input/window geometry integration (including macOS 15 Sequoia fallback bridges).
- **`PlayTools.strings`**: Localized resource bundles (`*.lproj/PlayTools.strings`) synced into wrapped apps alongside `PlayTools.framework`.
