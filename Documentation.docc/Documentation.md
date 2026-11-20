# ``PlayCover``

Run iOS apps and games natively on Apple Silicon Macs (macOS 12.0 through macOS 15 Sequoia and newer) with keyboard, mouse, trackpad, and controller mapping.

## Overview

PlayCover 5.0 unifies the macOS host application, privileged helper tool, modular SwiftPM packages, and the Mac Catalyst `PlayTools` runtime inside `PlayCover.xcworkspace`.

### Architecture Modules (`Packages/PlayCoverModules`)

- **`PlayCoverCore`**: Bundle metadata (`AppInfo`), IPA/signature verification (`AppIntegrity`), shell execution (`Shell`), network rule parsing (`NetworkRuleParser`, `PlayRules`), iTunes lookup, diagnostics (`PlayCoverDiagnostics`), and URL/file helpers.
- **`PlayCoverMachO`**: Direct Mach-O slice inspection, `LC_LOAD_DYLIB` injection, code-signing orchestration, and per-app `UserPlugins` syncing (`Macho`, `PlayTools`).
- **`PlayCoverKeymapping`**: Key code tables and keymap serialization (`KeyCodeNames`, `KeymapData`).
- **`PlayCoverSandbox`**: Dual-track privilege escalation (`DualTrackPrivilegeEscalator`), `PlayCoverHelper` XPC protocol (`PlayCoverHelperProtocol`), input/path validation (`HelperSecurityValidator`), and AMFI NVRAM setup (`SystemConfig`).
- **`PlayCoverUI`**: Async alert sheet presentation (`AlertPresenter`), Safe Mode startup alerts (`StartupAlertCenter`), toast notifications (`ToastVM`), progress/install state (`ProgressVM`, `InstallVM`), modifier tracking (`ModifierKeyObserver`), sound device preparation (`SoundDeviceService`), and notification helpers (`NotifyService`).

### Host Application & Helper

- **`PlayCover`**: SwiftUI macOS application using explicit dependency injection via `PlayCoverDependencies` (no global `static shared` singletons) and non-blocking async UI prompts.
- **`PlayCoverHelper`**: Privileged LaunchDaemon tool (`io.playcover.PlayCover.Helper`) using `SMAppService` on macOS 13+ (when signed with Developer ID) with AppleScript admin fallback.
- **`PlayTools` & `AKInterface`**: Mac Catalyst `arm64` injection runtime and AppKit bridge featuring `PTSafeMode`, `PluginManifest.json`-validated `PTPluginContainer`, `PTRegistration` dynamic hiding, macOS 15 Sequoia geometry bridging, `PlayedAppleDBBackup`, and `PLAYTOOLS_DEBUG_LOG=1` tracing.
