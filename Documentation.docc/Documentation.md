# ``MacOver``

Run iOS apps and games natively on Apple Silicon Macs (macOS 26.0 Tahoe and newer) with Liquid Glass UI, keyboard, mouse, trackpad, and controller mapping.

## Overview

MacOver 1.0 unifies the `MacOver.app` macOS host application (`app.makedie.MacOver`), privileged helper tool (`app.makedie.MacOver.Helper`), modular SwiftPM packages, and the Mac Catalyst `PlayTools` runtime (`app.makedie.PlayTools`) inside `PlayCover.xcworkspace`.

### Architecture Modules (`Packages/PlayCoverModules`)

- **`PlayCoverCore`**: Bundle metadata (`AppInfo`), IPA/signature verification (`AppIntegrity`), shell execution (`Shell`), network rule parsing (`NetworkRuleParser`, `PlayRules`), iTunes lookup, diagnostics (`PlayCoverDiagnostics`), and URL/file helpers.
- **`PlayCoverMachO`**: Direct Mach-O slice inspection, `LC_LOAD_DYLIB` injection, code-signing orchestration, and per-app `UserPlugins` syncing (`Macho`, `PlayTools`).
- **`PlayCoverKeymapping`**: Key code tables and keymap serialization (`KeyCodeNames`, `KeymapData`).
- **`PlayCoverSandbox`**: Dual-track privilege escalation (`DualTrackPrivilegeEscalator`), `PlayCoverHelper` XPC protocol (`PlayCoverHelperProtocol`), input/path validation (`HelperSecurityValidator`), and AMFI NVRAM setup (`SystemConfig`).
- **`PlayCoverUI`**: Async alert sheet presentation (`AlertPresenter`), Safe Mode startup alerts (`StartupAlertCenter`), toast notifications (`ToastVM`), progress/install state (`ProgressVM`, `InstallVM`), modifier tracking (`ModifierKeyObserver`), sound device preparation (`SoundDeviceService`), and notification helpers (`NotifyService`).

### Host Application & Helper

- **`MacOver.app` (`PlayCover` Swift module)**: SwiftUI macOS application using explicit dependency injection via `PlayCoverDependencies` (no global `static shared` singletons) and non-blocking async UI prompts.
- **`PlayCoverHelper`**: Privileged LaunchDaemon tool (`app.makedie.MacOver.Helper`) using `SMAppService` when signed with Developer ID with AppleScript admin fallback.
- **`PlayTools` & `AKInterface`**: Mac Catalyst `arm64` injection runtime (`app.makedie.PlayTools`, AGPL-3.0) and AppKit bridge featuring `PTSafeMode`, `PluginManifest.json`-validated `PTPluginContainer`, `PTRegistration` dynamic hiding, window geometry bridging, `PlayedAppleDBBackup`, and `PLAYTOOLS_DEBUG_LOG=1` tracing.
