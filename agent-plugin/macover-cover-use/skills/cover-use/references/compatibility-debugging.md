# Compatibility Debugging with MacOver MCP

## Quick Diagnostic Matrix

1. **Startup Crash (< 3s) & Safe Mode**:
   - Query `macover_diagnostics(bundleID: ..., sections: ["safemode", "crash", "logs"])`.
   - Reproduce cleanly with `macover_apps(op: "restart", bundleID: ..., safeMode: true)` vs normal `safeMode: false`.
2. **Environment Detection / Anti-Cheat Suspicions**:
   - Compare behavior with `strictEmulationMode`, `reportedIOSVersion` (`compat13_7`, `compat18_3`, `automatic`), and `interceptInlineSyscalls`.
   - Patch via `macover_settings(op: "patch", bundleID: ..., patch: {...})` and check `restartRequiredChanges` before restarting.
   - Use `debugTrace: true` on `launch`/`restart` only during active diagnosis so `PLAYTOOLS_DEBUG_LOG=1` output is captured.
3. **Network & Certificate Pinning Issues**:
   - Inspect live requests via `macover_network(op: "list", host: ..., disposition: "error")`.
   - Adjust host decryption filters (`mitmAllHosts`, `mitmHostPatterns`) or URL blocks live with `macover_network_rules`.
   - Verify app Sandboxed Mach-O & `PlayTools.framework` integrity via `macover_diagnostics(sections: ["macho", "runtime"])`.
